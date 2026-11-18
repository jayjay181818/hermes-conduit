"""Exercise fork release promotion with local fixtures and a fake GitHub CLI."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "mac-catalyst/publish-release.py"
spec = importlib.util.spec_from_file_location("publish_mac_release", SCRIPT)
publish = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publish)


class MacReleasePublicationTests(unittest.TestCase):
    tag = "macos/v2.4.1-build-278"

    def test_local_test_filename_and_noncanonical_tags_cannot_be_published(self):
        for name, tag in [
            ("Conduit-macOS-arm64-local-test.pkg", self.tag),
            (publish.ASSET, "macos/v02.4.1-build-278"),
            (publish.ASSET, "ios/v2.4.1-build-278"),
        ]:
            with self.subTest(name=name, tag=tag), patch.object(publish, "run") as cli:
                with self.assertRaises(ValueError):
                    publish.verify(Path(name), tag)
                cli.assert_not_called()

    def test_only_the_verified_download_can_promote_a_draft(self):
        package_bytes = b"local package fixture"
        digest = "sha256:" + hashlib.sha256(package_bytes).hexdigest()
        fake_head = "1" * 40

        def read(*args):
            if args[:2] == ("git", "rev-parse"):
                return fake_head
            if args[:2] == ("git", "status"):
                return ""
            if args[:2] == ("git", "ls-remote"):
                self.assertEqual(args[2], "https://github.com/" + publish.REPO + ".git")
                return fake_head + "\trefs/tags/" + self.tag
            if args[:3] == ("gh", "release", "view"):
                self.assertIn(publish.REPO, args)
                return json.dumps({"databaseId": 8, "isDraft": True})
            self.assertEqual(args, ("gh", "api", "repos/" + publish.REPO + "/releases/8/assets"))
            return json.dumps([{"name": publish.ASSET, "size": len(package_bytes), "digest": digest}])

        with tempfile.TemporaryDirectory() as tmp:
            package = Path(tmp) / publish.ASSET
            package.write_bytes(package_bytes)
            for received in [b"different bytes", package_bytes]:
                actions = []

                def run(*args):
                    self.assertEqual(args[:2], ("gh", "release"))
                    self.assertEqual(args[args.index("--repo") + 1], publish.REPO)
                    actions.append(args[2])
                    if args[2] == "download":
                        (Path(args[args.index("--dir") + 1]) / publish.ASSET).write_bytes(received)

                argv = [str(SCRIPT), "--tag", self.tag, "--package", str(package), "--publish"]
                with self.subTest(received=received), patch("sys.argv", argv), \
                     patch.object(publish, "verify", return_value=digest), \
                     patch.object(publish, "read", side_effect=read), \
                     patch.object(publish, "run", side_effect=run):
                    if received == package_bytes:
                        publish.main()
                        self.assertEqual(actions, ["create", "download", "edit"])
                    else:
                        with self.assertRaisesRegex(ValueError, "remains a draft"):
                            publish.main()
                        self.assertEqual(actions, ["create", "download"])
