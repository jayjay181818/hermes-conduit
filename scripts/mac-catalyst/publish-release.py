#!/usr/bin/env python3
"""Publish an already signed and notarized Mac package to the Mac fork only."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

REPO = "jayjay181818/hermes-conduit"
ASSET = "Conduit-macOS-arm64.pkg"
BUNDLE = "com.milim.relay.catalyst"


def read(*args):
    return subprocess.check_output(args, text=True).strip()


def run(*args):
    subprocess.run(args, check=True)


def sha256(package):
    with package.open("rb") as stream:
        digest = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return "sha256:" + digest.hexdigest()


def verify(package, tag):
    match = re.fullmatch(r"macos/v((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))-build-([1-9][0-9]*)", tag)
    if not match or package.name != ASSET:
        raise ValueError("Expected a canonical macos/vX.Y.Z-build-N tag and the arm64 Mac package")
    if not package.is_file():
        raise FileNotFoundError(package)
    run("pkgutil", "--check-signature", str(package))
    run("xcrun", "stapler", "validate", str(package))
    run("spctl", "--assess", "--type", "install", str(package))
    with tempfile.TemporaryDirectory() as tmp:
        contents = Path(tmp) / "expanded"
        run("pkgutil", "--expand-full", str(package), str(contents))
        component = contents / "component.pkg"
        if {item.name for item in contents.iterdir()} != {"Distribution", component.name}:
            raise ValueError("Unexpected installer component")
        payload = component / "Payload"
        if {item.name for item in payload.iterdir()} != {"Conduit.app"} or (component / "Scripts").exists():
            raise ValueError("Expected a single app and no installation scripts")
        receipt = ET.parse(component / "PackageInfo").getroot()
        if (receipt.get("identifier"), receipt.get("version"), receipt.get("install-location")) != (
            BUNDLE + ".installer", match[2], "/Applications"
        ):
            raise ValueError("Unexpected installer receipt or destination")
        app = payload / "Conduit.app"
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        if (info["CFBundleIdentifier"], info["CFBundleShortVersionString"], info["CFBundleVersion"]) != (BUNDLE, *match.groups()):
            raise ValueError("Installer does not match the requested release")
        run("codesign", "--verify", "--deep", "--strict", str(app))
    return sha256(package)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--publish", action="store_true", help="Create and verify a draft, then publish it")
    args = parser.parse_args()
    digest = verify(args.package, args.tag)
    if not args.publish:
        print("Package passed local preflight.")
        return
    tag = args.tag
    # Explicit release action only. The reviewed source and its tag must already be on the fork.
    head = read("git", "rev-parse", "HEAD")
    if read("git", "status", "--porcelain"):
        raise ValueError("Build releases from a clean tagged checkout")
    refs = read("git", "ls-remote", "https://github.com/" + REPO + ".git", "refs/tags/" + tag, "refs/tags/" + tag + "^{}").splitlines()
    if not refs or head != refs[-1].split()[0]:
        raise ValueError("The fork's tag must resolve to this checkout's commit")
    run("gh", "release", "create", tag, str(args.package), "--repo", REPO, "--verify-tag", "--draft", "--title", "Conduit for Mac " + tag.removeprefix("macos/v"), "--notes", "Download the Mac installer to update Conduit.")
    release = json.loads(read("gh", "release", "view", tag, "--repo", REPO, "--json", "databaseId,isDraft"))
    if not release["isDraft"]:
        raise ValueError("Expected draft release")
    assets = json.loads(read("gh", "api", f"repos/{REPO}/releases/{release['databaseId']}/assets"))
    if len(assets) != 1 or (assets[0]["name"], assets[0]["digest"], assets[0]["size"]) != (ASSET, digest, args.package.stat().st_size):
        raise ValueError("Uploaded artifact verification failed; release remains a draft")
    with tempfile.TemporaryDirectory() as tmp:
        uploaded = Path(tmp) / ASSET
        run("gh", "release", "download", tag, "--repo", REPO, "--pattern", ASSET, "--dir", tmp)
        if sha256(uploaded) != digest:
            raise ValueError("Downloaded asset differs from the verified local package; release remains a draft")
    run("gh", "release", "edit", tag, "--repo", REPO, "--draft=false", "--latest=false")


if __name__ == "__main__":
    main()
