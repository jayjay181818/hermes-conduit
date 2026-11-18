# Conduit for Mac releases

The Mac app checks GitHub Releases in `jayjay181818/hermes-conduit` when the user chooses **Check for Updates** in the application menu. It selects stable tags of the form `macos/v2.4.1-build-278`, with a strictly increasing numeric build. Keep the marketing version at the corresponding Conduit version. Use a higher build for a Mac-only fix. Record the exact upstream source separately in `docs/UPSTREAM_REVISION`.

The installer downloads only on request. Conduit checks the package size and digest against the fork's GitHub release metadata, then lets the user save the package and open it with Apple Installer. GitHub is the distribution host. Apple's Developer ID signature and notarization provide the distribution trust. The existing 0.1.15 app requires one manual install of the first update-aware build.

## Upgrade continuity

Install over the existing app in Applications using the same macOS user account. The sole payload is Conduit.app. Existing dashboards, custom request headers, saved credentials and preferences belong to the user's sandbox. Keep the Release bundle ID `com.milim.relay.catalyst`, URL scheme, and storage paths stable across versions. Leave login credentials out of installers, update requests and release notes.

Before promoting the first Developer ID build, try the transition from the old ad hoc build in a disposable account on a Mac. Seed a synthetic dashboard, headers, and authentication. Quit the old app, install the candidate, then verify the saved address, active dashboard, and authorized request to its original HTTPS origin before and after a relaunch. Confirm a different origin receives none of the headers. Check any macOS container authorization prompt normally. Test the same sequence from one signed Mac release to the next. A unit test cannot establish how macOS will handle a change of signing identity.

For rollback, keep the prior app and back up its container with the app closed before the first upgrade. Quit the new app before restoring a backup. Restore an earlier app with its matching state if a data-format change prevents it reading the new state. Do not republish an old release as a newer build solely to bypass downgrade checks.

## Build a local test package

Generate an optimized Release using `scripts/mac-catalyst-build.sh --no-install --no-open`. Then run:

```sh
python3 scripts/mac-catalyst/package-release.py \
  --app "$RELEASE_APP" --tag macos/v2.4.1-build-278 \
  --output-dir "$TEST_OUTPUT" --local-test
```

The output has the suffix `-local-test.pkg`. Inspect with `pkgutil --expand-full` or run Installer in the disposable account. Keep unsigned test installers out of Releases.

## Produce and publish a distribution package

Build from the reviewed, clean, tagged fork checkout with Apple Silicon and a suitable Xcode and Metal toolchain. Use Developer ID Application and Developer ID Installer identities for the same team, plus a configured notarytool keychain profile. Build at a neutral filesystem path. The packager scans the payload for home-directory paths and credential files before packaging. Keep the dSYM private. The release packager signs the embedded WebRTC framework and the app, requires normal library validation, signs the installer, waits for Apple to accept it, staples the ticket, and assesses the finished installer.

```sh
python3 scripts/mac-catalyst/package-release.py \
  --app "$RELEASE_APP" --tag "$MAC_TAG" --output-dir "$RELEASE_OUTPUT" \
  --application-identity "$APPLICATION_IDENTITY" \
  --installer-identity "$INSTALLER_IDENTITY" --notary-profile "$NOTARY_PROFILE"
python3 scripts/mac-catalyst/publish-release.py \
  --tag "$MAC_TAG" --package "$RELEASE_OUTPUT/Conduit-macOS-arm64.pkg"
```

The second command runs local preflight. After testing and release approval, run it again with `--publish`. It requires the tag on the fork, creates a draft release there, checks the asset digest and size, downloads the staged package and compares its SHA-256, then publishes it. If an upload/check fails, inspect the draft and reconcile it before retrying. Keep signing identities and notarization credentials in the release operator's keychain. In particular they are never needed by a pull request or the installed app.
