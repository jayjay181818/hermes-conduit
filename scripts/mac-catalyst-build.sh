#!/usr/bin/env bash
# Builds Conduit for Mac from this checkout with Mac Catalyst and installs it
# in /Applications (~/Applications when /Applications isn't writable).
#
# No Apple developer account is needed: the app is signed to run locally,
# sandboxed, with its own bundle id (com.milim.relay.catalyst), sign-in and
# settings. It has no push notifications, Live Activities, widgets,
# extensions, Watch app, CarPlay, HealthKit or location push
# (scripts/mac-catalyst/project.yml).
#
# Usage: scripts/mac-catalyst-build.sh [--debug] [--no-install] [--no-open]
#   --debug       build the Debug configuration (default: Release), installed
#                 as "Conduit Debug" with its own bundle id and settings
#   --no-install  build only; prints where Conduit.app is
#   --no-open     install without opening Conduit afterwards
#
# Build products go to ~/Library/Developer/Xcode/DerivedData/ConduitMac
# (CONDUIT_MAC_DERIVED_DATA overrides it), never into the checkout.
set -euo pipefail

configuration=Release
install=1
open_app=1
for arg in "$@"; do
  case "$arg" in
    --debug) configuration=Debug ;;
    --no-install) install=0 ;;
    --no-open) open_app=0 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

bundle_id=com.milim.relay.catalyst
app_name=Conduit.app
if [ "$configuration" = Debug ]; then
  # Debug's own bundle id (scripts/mac-catalyst/project.yml), so it never
  # shares the installed Conduit's sign-in or settings.
  bundle_id=com.milim.relay.catalyst.debug
  app_name="Conduit Debug.app"
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
derived="${CONDUIT_MAC_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/ConduitMac}"
log="$derived/build-$configuration.log"
cd "$root"

command -v xcodegen >/dev/null || { echo "xcodegen is required (brew install xcodegen)" >&2; exit 1; }
# The live voice orb is a Metal shader; Xcode ships the Metal compiler as a
# separate download.
xcrun -sdk macosx metal --version >/dev/null 2>&1 || {
  echo "Xcode's Metal Toolchain is required: xcodebuild -downloadComponent metaltoolchain" >&2
  exit 1
}

mkdir -p "$derived"
xcodegen generate --quiet --spec scripts/mac-catalyst/project.yml --project-root . --project .

echo "Building Conduit for Mac ($configuration; log: $log)..."
if ! xcodebuild build \
    -project ConduitMac.xcodeproj \
    -scheme ConduitMac \
    -configuration "$configuration" \
    -destination 'platform=macOS,variant=Mac Catalyst' \
    -derivedDataPath "$derived" \
    >"$log" 2>&1; then
  grep -E 'error:|BUILD FAILED' "$log" | tail -20 >&2 || true
  echo "Build failed; see $log" >&2
  exit 1
fi

app="$derived/Build/Products/$configuration-maccatalyst/Conduit.app"
[ -d "$app" ] || { echo "No Conduit.app at $app" >&2; exit 1; }
codesign --verify --strict "$app" || { echo "Conduit.app's signature doesn't verify" >&2; exit 1; }
echo "Built $app"
[ "$install" = 1 ] || exit 0

apps=/Applications
[ -w "$apps" ] || { apps="$HOME/Applications"; mkdir -p "$apps"; }
dest="$apps/$app_name"

if [ -e "$dest" ]; then
  # Only ever replace this build: an App Store or TestFlight Conduit (an iOS
  # app, its Info.plist under Wrapper/) stays where it is.
  existing=""
  if [ -f "$dest/Contents/Info.plist" ]; then
    existing="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$dest/Contents/Info.plist" 2>/dev/null || true)"
  fi
  if [ "$existing" != "$bundle_id" ]; then
    echo "$dest is another app (${existing:-unknown bundle id}); not replacing it." >&2
    echo "Move it aside, or copy $app wherever you like." >&2
    exit 1
  fi
  if pgrep -f "$dest/Contents/MacOS/Conduit" >/dev/null; then
    osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      pgrep -f "$dest/Contents/MacOS/Conduit" >/dev/null || break
      sleep 1
    done
    if pgrep -f "$dest/Contents/MacOS/Conduit" >/dev/null; then
      echo "Conduit is still running; quit it and run this again." >&2
      exit 1
    fi
  fi
  rm -rf "$dest"
fi

ditto "$app" "$dest"
echo "Installed $dest"
if [ "$open_app" = 1 ]; then
  open "$dest"
fi
