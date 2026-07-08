#!/usr/bin/env bash
# M4 layout-correctness verification on the iOS simulator: safe-area
# insets, rotation, and device scale.
#
#   1. Build the example's mobile embed lib + shim .app (run.sh
#      --build-only) and launch it with NATIVE_SDK_AUTOMATION=1 so the
#      embedded runtime publishes automation snapshots into the app's data
#      container.
#   2. Portrait: assert from the snapshot that every widget lies at or
#      below the top safe-area inset (nothing under the status bar /
#      Dynamic Island) and capture a screenshot.
#   3. Device scale: the screenshot's pixel width divided by the widget
#      tree's point width must equal the device scale (3x on iPhone 15).
#   4. Rotate to landscape through a minimal XCUITest (XCUIDevice
#      orientation — there is no simctl rotation command), then assert the
#      relayout: widgets start at or right of the left safe-area inset and
#      the tree is wider than portrait. Screenshot again.
#   5. Rotate back to portrait and re-assert the portrait layout.
#
# Usage:
#   ./verify_layout.sh                       # ui-inbox on "iPhone 15"
#   ./verify_layout.sh --device "iPhone 15 Pro" --shutdown
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$SCRIPT_DIR/../../ui-inbox"
DEVICE="iPhone 15"
SHUTDOWN=0
# Portrait status bar / Dynamic Island is >= 44pt on every notched iPhone;
# landscape moves the sensor housing to the sides (>= 44pt left inset).
MIN_TOP_INSET=44
MIN_LEFT_INSET=44

while [[ $# -gt 0 ]]; do
  case "$1" in
    --example-dir) EXAMPLE_DIR="$2"; shift 2 ;;
    --device) DEVICE="$2"; shift 2 ;;
    --shutdown) SHUTDOWN=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

EXAMPLE_DIR="$(cd "$EXAMPLE_DIR" && pwd)"

echo "== build shim app (run.sh --build-only)"
"$SCRIPT_DIR/run.sh" --example-dir "$EXAMPLE_DIR" --build-arg -Dmobile=true --build-only

LIB="$(ls "$EXAMPLE_DIR"/zig-out/lib/*.a | head -1)"
APP_NAME="$(basename "$LIB")"
APP_NAME="${APP_NAME#lib}"
APP_NAME="${APP_NAME%.a}"
BUNDLE_ID="dev.native-sdk.${APP_NAME}"
APP_BUNDLE="$SCRIPT_DIR/build/$APP_NAME/$APP_NAME.app"
WORK_DIR="$SCRIPT_DIR/build/$APP_NAME/layout-verify"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

echo "== boot simulator: $DEVICE"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null
UDID="$(xcrun simctl list devices booted -j | python3 -c '
import json, sys
for devices in json.load(sys.stdin)["devices"].values():
    for device in devices:
        if device["state"] == "Booted":
            print(device["udid"])
            raise SystemExit
')"
[[ -n "$UDID" ]] || { echo "no booted simulator" >&2; exit 1; }

echo "== install + launch $BUNDLE_ID with automation enabled"
xcrun simctl install "$UDID" "$APP_BUNDLE"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
SIMCTL_CHILD_NATIVE_SDK_AUTOMATION=1 xcrun simctl launch "$UDID" "$BUNDLE_ID"

CONTAINER="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)"
SNAPSHOT="$CONTAINER/Documents/native-sdk-automation/snapshot.txt"
echo "== automation snapshot: $SNAPSHOT"

wait_for_widgets() {
  for _ in $(seq 1 60); do
    grep -q 'widget @' "$SNAPSHOT" 2>/dev/null && return 0
    sleep 0.5
  done
  echo "snapshot.txt never contained the widget tree" >&2
  exit 1
}
wait_for_widgets

# Widget-tree extents from the snapshot: min x/y over every widget's
# bounds plus the union width. Emits shell-evalable NAME=VALUE lines.
layout_facts() {
  python3 - "$SNAPSHOT" <<'PY'
import re, sys

# Widget lines only: the window/view lines also carry a bounds=(...) that
# always starts at the surface origin.
lines = [
    line for line in open(sys.argv[1], encoding="utf-8").read().splitlines()
    if line.strip().startswith("widget @")
]
bounds = [
    tuple(float(v) for v in m.groups())
    for line in lines
    for m in re.finditer(r"bounds=\(([-\d.]+),([-\d.]+) ([-\d.]+)x([-\d.]+)\)", line)
]
if not bounds:
    raise SystemExit("snapshot has no widget bounds")
min_x = min(b[0] for b in bounds)
min_y = min(b[1] for b in bounds)
max_r = max(b[0] + b[2] for b in bounds)
print(f"MIN_X={min_x:.1f}")
print(f"MIN_Y={min_y:.1f}")
print(f"TREE_WIDTH={max_r - min_x:.1f}")
print(f"TREE_RIGHT={max_r:.1f}")
PY
}

assert_ge() { # value threshold description
  python3 -c "import sys; sys.exit(0 if float('$1') >= float('$2') else 1)" \
    && echo "OK: $3 ($1 >= $2)" \
    || { echo "FAIL: $3 ($1 < $2)" >&2; exit 1; }
}

# Snapshot re-reads retry a few seconds: relayout publishes on the app's
# next pumped frame.
refresh_facts() {
  local predicate="$1"
  for _ in $(seq 1 30); do
    eval "$(layout_facts)"
    if eval "$predicate" >/dev/null 2>&1; then return 0; fi
    sleep 0.5
  done
  return 0
}

# ------------------------------------------------------- portrait insets
# The first published snapshot can predate the shim's viewport push (the
# install happens on the first pumped frame); poll until the inset layout
# lands.
refresh_facts '[ "$(python3 -c "print(float(\"$MIN_Y\") >= $MIN_TOP_INSET)")" == "True" ]'
cp "$SNAPSHOT" "$WORK_DIR/snapshot-portrait.txt"
assert_ge "$MIN_Y" "$MIN_TOP_INSET" "portrait: first widget y is below the top safe-area inset"
PORTRAIT_WIDTH="$TREE_WIDTH"
PORTRAIT_SHOT="$WORK_DIR/$APP_NAME-portrait.png"
xcrun simctl io "$UDID" screenshot "$PORTRAIT_SHOT" >/dev/null
echo "== portrait screenshot: $PORTRAIT_SHOT"

# --------------------------------------------------------- device scale
PIXEL_WIDTH="$(sips -g pixelWidth "$PORTRAIT_SHOT" | awk '/pixelWidth/ {print $2}')"
SCALE="$(python3 -c "
# The widget tree spans the surface width in portrait (left/right insets
# are zero), so pixel width / point width is the device scale.
print(round($PIXEL_WIDTH / $TREE_RIGHT))
")"
echo "== screenshot ${PIXEL_WIDTH}px wide over ${TREE_RIGHT}pt -> scale ${SCALE}x"
EXACT="$(python3 -c "print(abs($PIXEL_WIDTH / $TREE_RIGHT - $SCALE) < 0.01)")"
[[ "$EXACT" == "True" && "$SCALE" -ge 2 ]] \
  && echo "OK: device scale $SCALE is honored end to end" \
  || { echo "FAIL: pixel/point ratio $PIXEL_WIDTH/$TREE_RIGHT is not an integer device scale" >&2; exit 1; }

# ------------------------------------------- XCUITest rotation harness
echo "== build XCUITest runner (no .xcodeproj)"
DEVELOPER_DIR="$(xcode-select -p)"
SIM_PLATFORM="$DEVELOPER_DIR/Platforms/iPhoneSimulator.platform/Developer"
AGENTS="$SIM_PLATFORM/Library/Xcode/Agents"
PUBLIC_FW="$SIM_PLATFORM/Library/Frameworks"
PRIVATE_FW="$SIM_PLATFORM/Library/PrivateFrameworks"
USR_LIB="$SIM_PLATFORM/usr/lib"

TEST_NAME="InputUITests"
RUNNER="$WORK_DIR/$TEST_NAME-Runner.app"
XCTEST_BUNDLE="$RUNNER/PlugIns/$TEST_NAME.xctest"

cp -R "$AGENTS/XCTRunner.app" "$RUNNER"
mv "$RUNNER/XCTRunner" "$RUNNER/$TEST_NAME-Runner"
plutil -replace CFBundleExecutable -string "$TEST_NAME-Runner" "$RUNNER/Info.plist"
plutil -replace CFBundleIdentifier -string "dev.native-sdk.$TEST_NAME.xctrunner" "$RUNNER/Info.plist"
plutil -replace CFBundleName -string "$TEST_NAME-Runner" "$RUNNER/Info.plist"

mkdir -p "$RUNNER/Frameworks" "$XCTEST_BUNDLE"
for framework in XCTest XCUIAutomation; do
  cp -R "$PUBLIC_FW/$framework.framework" "$RUNNER/Frameworks/"
done
for framework in XCTestCore XCTestSupport XCTAutomationSupport; do
  cp -R "$PRIVATE_FW/$framework.framework" "$RUNNER/Frameworks/"
done
cp "$USR_LIB/libXCTestSwiftSupport.dylib" "$RUNNER/Frameworks/"

xcrun --sdk iphonesimulator clang \
  -target arm64-apple-ios15.0-simulator \
  -fobjc-arc -bundle \
  -F "$PUBLIC_FW" \
  -framework XCTest -framework Foundation -framework CoreGraphics \
  "$SCRIPT_DIR/InputUITests.m" \
  -o "$XCTEST_BUNDLE/$TEST_NAME"
cat > "$XCTEST_BUNDLE/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$TEST_NAME</string>
  <key>CFBundleIdentifier</key><string>dev.native-sdk.$TEST_NAME</string>
  <key>CFBundleName</key><string>$TEST_NAME</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
</dict>
</plist>
PLIST

find "$RUNNER/Frameworks" -maxdepth 1 \( -name "*.framework" -o -name "*.dylib" \) \
  -exec codesign --force --sign - {} \; 2>/dev/null
codesign --force --sign - "$XCTEST_BUNDLE" >/dev/null 2>&1
codesign --force --sign - "$RUNNER" >/dev/null 2>&1

rotate_to() {
  local orientation="$1"
  cat > "$WORK_DIR/rotate.xctestrun" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>__xctestrun_metadata__</key>
  <dict>
    <key>FormatVersion</key><integer>1</integer>
  </dict>
  <key>$TEST_NAME</key>
  <dict>
    <key>TestBundlePath</key><string>__TESTHOST__/PlugIns/$TEST_NAME.xctest</string>
    <key>TestHostPath</key><string>__TESTROOT__/$TEST_NAME-Runner.app</string>
    <key>TestHostBundleIdentifier</key><string>dev.native-sdk.$TEST_NAME.xctrunner</string>
    <key>UITargetAppPath</key><string>$APP_BUNDLE</string>
    <key>UITargetAppBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>IsUITestBundle</key><true/>
    <key>IsXCTRunnerHostedTestBundle</key><true/>
    <key>TestingEnvironmentVariables</key>
    <dict>
      <key>NATIVE_SDK_TARGET_BUNDLE_ID</key><string>$BUNDLE_ID</string>
      <key>NATIVE_SDK_ORIENTATION</key><string>$orientation</string>
    </dict>
  </dict>
</dict>
</plist>
PLIST
  echo "== xcodebuild test-without-building: testRotate -> $orientation"
  xcodebuild test-without-building \
    -xctestrun "$WORK_DIR/rotate.xctestrun" \
    -destination "platform=iOS Simulator,id=$UDID" \
    -only-testing:"$TEST_NAME/NativeSdkInputUITests/testRotate" \
    >"$WORK_DIR/xcodebuild-rotate-$orientation.log" 2>&1 || {
      tail -50 "$WORK_DIR/xcodebuild-rotate-$orientation.log" >&2
      echo "FAIL: rotate to $orientation" >&2
      exit 1
    }
}

# ------------------------------------------------------------ landscape
rotate_to landscape
refresh_facts '[ "$(python3 -c "print(float(\"$MIN_X\") >= $MIN_LEFT_INSET)")" == "True" ]'
cp "$SNAPSHOT" "$WORK_DIR/snapshot-landscape.txt"
assert_ge "$MIN_X" "$MIN_LEFT_INSET" "landscape: first widget x is right of the left safe-area inset"
WIDER="$(python3 -c "print(float('$TREE_WIDTH') > float('$PORTRAIT_WIDTH'))")"
[[ "$WIDER" == "True" ]] \
  && echo "OK: landscape relayout widened the widget tree ($PORTRAIT_WIDTH -> $TREE_WIDTH)" \
  || { echo "FAIL: landscape tree width $TREE_WIDTH did not grow past portrait $PORTRAIT_WIDTH" >&2; exit 1; }
LANDSCAPE_SHOT="$WORK_DIR/$APP_NAME-landscape.png"
xcrun simctl io "$UDID" screenshot "$LANDSCAPE_SHOT" >/dev/null
echo "== landscape screenshot: $LANDSCAPE_SHOT"

# ----------------------------------------------------- back to portrait
rotate_to portrait
refresh_facts '[ "$(python3 -c "print(float(\"$MIN_Y\") >= $MIN_TOP_INSET and float(\"$TREE_WIDTH\") <= float(\"$PORTRAIT_WIDTH\") + 0.5)")" == "True" ]'
cp "$SNAPSHOT" "$WORK_DIR/snapshot-portrait-restored.txt"
assert_ge "$MIN_Y" "$MIN_TOP_INSET" "restored portrait: first widget y is below the top safe-area inset"

if [[ "$SHUTDOWN" -eq 1 ]]; then
  xcrun simctl shutdown "$UDID" || true
fi

echo "PASS: safe-area insets, rotation relayout, and device scale verified on the simulator"
