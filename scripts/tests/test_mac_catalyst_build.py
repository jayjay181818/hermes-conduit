"""Exercise Metal prerequisite selection without building or installing an app."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from _util import SCRIPTS_DIR

SCRIPT = Path(SCRIPTS_DIR) / "mac-catalyst-build.sh"


class MacCatalystBuildTests(unittest.TestCase):
    def run_prerequisites(self, *, default_metal=False, component_metal=True, selected=None):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tools = root / "bin"
            tools.mkdir()
            xcrun = tools / "xcrun"
            xcrun.write_text(
                '#!/bin/bash\n'
                'if [ "$*" = "-sdk macosx metal --version" ]; then exit '
                + ("0" if default_metal else "1") + '; fi\n'
                'if [ "$*" = "--toolchain com.apple.dt.toolchain.Metal metal --version" ]; then exit '
                + ("0" if component_metal else "1") + '; fi\n'
                'exit 1\n'
            )
            generate = tools / "xcodegen"
            generate.write_text('#!/bin/bash\nprintf "toolchain=%s\\n" "${TOOLCHAINS:-default}"\nexit 42\n')
            xcrun.chmod(0o755)
            generate.chmod(0o755)
            environment = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
                               CONDUIT_MAC_DERIVED_DATA=str(root / "derived"))
            environment.pop("TOOLCHAINS", None)
            if selected is not None:
                environment["TOOLCHAINS"] = selected
            return subprocess.run(
                ["bash", str(SCRIPT), "--no-install", "--no-open"],
                env=environment, capture_output=True, text=True, timeout=10,
            )

    def test_separate_component_is_selected_for_the_build(self):
        result = self.run_prerequisites()
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertIn("toolchain=com.apple.dt.toolchain.Metal", result.stdout)

    def test_default_metal_needs_no_toolchain_override(self):
        result = self.run_prerequisites(default_metal=True)
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertIn("toolchain=default", result.stdout)

    def test_missing_metal_stops_before_project_generation(self):
        result = self.run_prerequisites(component_metal=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Metal Toolchain is required", result.stderr)
        self.assertNotIn("toolchain=", result.stdout)

    def test_an_explicit_toolchain_is_never_replaced(self):
        result = self.run_prerequisites(selected="chosen-toolchain")
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("toolchain=", result.stdout)
        result = self.run_prerequisites(default_metal=True, selected="chosen-toolchain")
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertIn("toolchain=chosen-toolchain", result.stdout)


if __name__ == "__main__":
    unittest.main()
