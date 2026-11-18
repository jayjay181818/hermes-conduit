#!/usr/bin/env python3
"""Produce the fork's macOS Installer package from an optimized Catalyst Release."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET


def run(*command):
    subprocess.run([str(arg) for arg in command], check=True)


def read(*command):
    return subprocess.check_output([str(arg) for arg in command])


def package(args, work):
    match = re.fullmatch(r"macos/v((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))-build-([1-9][0-9]*)", args.tag)
    if not match:
        raise ValueError("Expected macos/vX.Y.Z-build-N")
    version, build = match.groups()
    identifier = "com.milim.relay.catalyst"
    src = args.app.resolve()
    info = plistlib.loads((src / "Contents/Info.plist").read_bytes())
    if (src.name, info["CFBundleIdentifier"], info["CFBundleShortVersionString"], info["CFBundleVersion"]) != ("Conduit.app", identifier, version, build):
        raise ValueError("App identity or version does not match the requested Mac release")
    run("codesign", "--verify", "--strict", "--deep", src)
    # Swift source locations can reach optimized binaries. Scan the actual
    # payload (including resources and frameworks) without printing matches.
    home_path = re.compile(rb"/Users/[^/\x00\r\n]+/|/CloudStorage/GoogleDrive-")
    for item in src.rglob("*"):
        if item.is_symlink() or not item.is_file():
            continue
        if item.name == "credentials.plist" or home_path.search(item.read_bytes()):
            raise ValueError(f"Personal data or a home-directory path in {item.relative_to(src)}")
    exe = src / "Contents/MacOS" / info["CFBundleExecutable"]
    if read("lipo", "-archs", exe).strip() != b"arm64" or b"MACCATALYST" not in read("xcrun", "vtool", "-show-build", exe):
        raise ValueError("Expected an arm64 Catalyst executable")
    minimum = info.get("LSMinimumSystemVersion", "")
    if not re.fullmatch(r"14\.0(?:\.0)?", minimum):
        raise ValueError(f"Unexpected minimum macOS: {minimum}")
    ent = plistlib.loads(read("codesign", "-d", "--entitlements", ":-", src))
    if ent.get("com.apple.security.app-sandbox") is not True or ent.get("com.apple.security.get-task-allow"):
        raise ValueError("Expected a sandboxed Release build")
    output = args.output_dir.resolve() / ("Conduit-macOS-arm64-local-test.pkg" if args.local_test else "Conduit-macOS-arm64.pkg")
    if output.exists():
        raise FileExistsError(output)
    root = work / "payload"
    root.mkdir()
    app = root / src.name
    run("ditto", src, app)
    if not args.local_test:
        # Sign the bundled framework first so the distributed app can use normal library validation.
        framework_dir = app / "Contents/Frameworks"
        if {p.name for p in framework_dir.iterdir()} != {"WebRTC.framework"}:
            raise ValueError("Review signing order for changed framework inventory")
        ent.pop("com.apple.security.cs.disable-library-validation", None)
        ent_path = work / "release.entitlements"
        ent_path.write_bytes(plistlib.dumps(ent))
        sign = ["codesign", "--force", "--options", "runtime", "--timestamp", "--sign", args.application_identity]
        run(*sign, framework_dir / "WebRTC.framework")
        run(*sign, "--entitlements", ent_path, app)
        run("codesign", "--verify", "--strict", "--deep", app)
    components = work / "components.plist"
    run("pkgbuild", "--analyze", "--root", root, components)
    bundles = plistlib.loads(components.read_bytes())
    main = next(item for item in bundles if item["RootRelativeBundlePath"] == "Conduit.app")
    main.update(BundleIsRelocatable=False, BundleIsVersionChecked=True, BundleOverwriteAction="upgrade")
    components.write_bytes(plistlib.dumps(bundles))
    component = work / "component.pkg"
    pkg_id = f"{identifier}.installer"
    run("pkgbuild", "--root", root, "--component-plist", components, "--identifier", pkg_id,
        "--version", build, "--install-location", "/Applications", component)
    dist = work / "distribution.xml"
    run("productbuild", "--synthesize", "--package", component, dist)
    doc = ET.parse(dist)
    d = doc.getroot()
    d.find("options").set("hostArchitectures", "arm64")
    volumes = ET.SubElement(d, "volume-check")
    ET.SubElement(ET.SubElement(volumes, "allowed-os-versions"), "os-version", min="14.0")
    # Keep the package URL as text in its own reference. Distribution
    # definitions with the same identifier are combined by Installer.
    close_ref = ET.SubElement(d, "pkg-ref", id=pkg_id)
    ET.SubElement(ET.SubElement(close_ref, "must-close"), "app", id=identifier)
    doc.write(dist, encoding="utf-8", xml_declaration=True)
    pkg = work / output.name
    signing = [] if args.local_test else ["--sign", args.installer_identity, "--timestamp"]
    run("productbuild", "--distribution", dist, "--package-path", work, *signing, pkg)
    if not args.local_test:
        report = json.loads(read("xcrun", "notarytool", "submit", pkg, "--keychain-profile", args.notary_profile, "--wait", "--output-format", "json"))
        if report.get("status") != "Accepted":
            raise ValueError("Apple did not accept the package for notarization")
        run("xcrun", "stapler", "staple", pkg)
        run("xcrun", "stapler", "validate", pkg)
        run("pkgutil", "--check-signature", pkg)
        run("spctl", "--assess", "--type", "install", pkg)
    # Temp and final files share a volume. Never overwrite an earlier release.
    os.link(pkg, output)
    print(output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--local-test", action="store_true", help="Build a locally testable unsigned package under a separate filename")
    parser.add_argument("--application-identity")
    parser.add_argument("--installer-identity")
    parser.add_argument("--notary-profile")
    args = parser.parse_args()
    if not args.local_test:
        application = re.fullmatch(r"Developer ID Application: .+ \(([A-Z0-9]{10})\)", args.application_identity or "")
        installer = re.fullmatch(r"Developer ID Installer: .+ \(([A-Z0-9]{10})\)", args.installer_identity or "")
        if not (application and installer and application[1] == installer[1] and args.notary_profile):
            parser.error("Distribution requires Developer ID Application and Installer identities from the same team and a notarytool keychain profile")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=args.output_dir) as staging:
        package(args, Path(staging))
