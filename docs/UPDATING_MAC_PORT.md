# Updating the Mac port

`macos-port` is the fork's Mac Catalyst branch. Keep upstream's `main` separate and bring its changes into a new update branch through a pull request into `macos-port`.

## Integration plan

1. Start with a clean working tree and retain the existing Mac branch. Fetch upstream and record the exact commit being integrated.
2. Merge upstream into a new update branch. Resolve each overlap by retaining both upstream fixes and the desktop behavior; never replace the Mac branch with upstream's iOS tree.
3. Review new Mac checks and framework APIs even when Git merges them automatically. `ProcessInfo.runsOnMac` includes Catalyst; `isiOSAppOnMac` alone does not.
4. Preserve single-window behavior, Return and focus rules, pointer handling, System Settings links, sandboxed credential storage, local notifications, Dock badges, and the optimized Release settings. Avoid reconnecting or uploading again on each app switch.
5. Run source/tooling checks, the selected Catalyst regression suites, and a Release build. Inspect the isolated Debug app for desktop layout, keyboard/focus, app switching, and permission links. Test any account-dependent behavior separately without publishing personal data.
6. Audit the final diff and new commit metadata for personal identifiers, local paths, credentials and generated artifacts. Push only the update branch and open a PR into `macos-port`.

## Local verification

Generate and build the isolated Debug app without installing it:

```sh
scripts/mac-catalyst-build.sh --debug --no-install --no-open
```

The script writes builds outside the checkout. `CONDUIT_MAC_DERIVED_DATA` can select a separate build directory. If a downloaded Metal compiler is registered separately, the script selects it for that build only, preserving an explicitly selected toolchain.

Use `xcodebuild test` with the generated `ConduitMac` project and scheme, the `platform=macOS,variant=Mac Catalyst` destination, and focused `-only-testing:ConduitTests/SuiteName` selections. Debug's bundle ID is separate from Release, so tests must not use the installed app's sign-in or data. The fork's Catalyst workflow records the selected suites and runs the portable source/tooling checks on Linux, whose Bash supports the upstream review-runner tests.

Build Release without installing or opening it:

```sh
scripts/mac-catalyst-build.sh --no-install --no-open
```

A PR is ready only when its reported checks match the final source state. Label blocked, skipped and unperformed GUI or authenticated checks explicitly. A successful iOS CI build is not Catalyst build evidence.

## Fork checks

The fork adds its own Catalyst and Linux source checks. The upstream maintainer's provider-backed review chain is restricted to the upstream repository, so opening a fork PR does not start additional model reviewers or require their secrets.
