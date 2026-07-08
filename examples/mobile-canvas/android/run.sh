#!/usr/bin/env bash
# Build a native-sdk mobile embed static library for Android, link it into
# the minimal NativeActivity presentation shim (main.c), assemble an APK
# without Gradle, then install + launch it on a device/emulator and verify:
#   1. a non-blank screenshot (presentation),
#   2. an automation snapshot published into the app's files dir,
#   3. an injected tap (adb shell input tap) that changes the snapshot.
#
# The Android twin of examples/mobile-canvas/ios/run.sh.
#
# Requirements (fails early, per tool, if missing):
#   - Android SDK (ANDROID_HOME / ANDROID_SDK_ROOT / ~/Library/Android/sdk)
#     with build-tools (aapt2, zipalign, apksigner), platform-tools (adb),
#     and a platforms/android-* android.jar
#   - Android NDK r23+ (ANDROID_NDK_ROOT or <sdk>/ndk/<version>)
#   - java (keytool/apksigner) for APK signing
#   - a running emulator or attached device for the install/verify rungs
#
# Usage:
#   ./run.sh                                   # mobile-canvas, arm64-v8a
#   ./run.sh --abi x86_64                      # x86_64 emulator image
#   ./run.sh --example-dir ../../ui-inbox --build-arg -Dmobile=true
#   ./run.sh --build-only                      # stop after the APK
#   ./run.sh --lib-only                        # stop after the zig static lib
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$SCRIPT_DIR/.."
ABI="arm64-v8a"
API_LEVEL=29   # floor for arm64 TLSDESC relocations + AChoreographer_postFrameCallback64
LIB_ONLY=0
BUILD_ONLY=0
SCREENSHOT=""
BUILD_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --example-dir) EXAMPLE_DIR="$2"; shift 2 ;;
    --abi) ABI="$2"; shift 2 ;;
    --build-arg) BUILD_ARGS+=("$2"); shift 2 ;;
    --screenshot) SCREENSHOT="$2"; shift 2 ;;
    --lib-only) LIB_ONLY=1; shift ;;
    --build-only) BUILD_ONLY=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

EXAMPLE_DIR="$(cd "$EXAMPLE_DIR" && pwd)"

case "$ABI" in
  arm64-v8a) ZIG_TARGET="aarch64-linux-android"; CLANG_TRIPLE="aarch64-linux-android" ;;
  x86_64)    ZIG_TARGET="x86_64-linux-android";  CLANG_TRIPLE="x86_64-linux-android" ;;
  *) echo "unsupported --abi $ABI (arm64-v8a or x86_64)" >&2; exit 2 ;;
esac

# ---------------------------------------------------------- rung 1: zig lib

echo "== zig build lib -Dtarget=$ZIG_TARGET (${EXAMPLE_DIR})"
(cd "$EXAMPLE_DIR" && zig build lib "-Dtarget=$ZIG_TARGET" "${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}")

LIB="$(ls "$EXAMPLE_DIR"/zig-out/lib/*.a | head -1)"
[[ -f "$LIB" ]] || { echo "no static library under $EXAMPLE_DIR/zig-out/lib" >&2; exit 1; }
APP_NAME="$(basename "$LIB")"
APP_NAME="${APP_NAME#lib}"
APP_NAME="${APP_NAME%.a}"
PACKAGE="dev.native_sdk.${APP_NAME//-/_}"
SO_NAME="native_sdk_shim"

MISSING=()
for symbol in create destroy start viewport frame render_pixel_size render_pixels \
              touch scroll gpu_frame_state widget_semantics_count set_automation_dir; do
  nm -g --defined-only "$LIB" 2>/dev/null | grep -q " T native_sdk_app_${symbol}\$" \
    || MISSING+=("native_sdk_app_${symbol}")
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "static lib is missing ABI symbols: ${MISSING[*]}" >&2
  exit 1
fi
echo "== static lib OK: $LIB (shim-required ABI symbols present)"

if [[ "$LIB_ONLY" -eq 1 ]]; then
  exit 0
fi

# ------------------------------------------------------- toolchain discovery

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
[[ -d "$SDK" ]] || {
  echo "Android SDK not found (checked ANDROID_HOME, ANDROID_SDK_ROOT, ~/Library/Android/sdk)." >&2
  echo "Install via Android Studio or: brew install --cask android-commandlinetools" >&2
  exit 1
}

NDK="${ANDROID_NDK_ROOT:-}"
if [[ -z "$NDK" && -d "$SDK/ndk" ]]; then
  NDK="$(ls -d "$SDK"/ndk/* 2>/dev/null | sort -V | tail -1)"
fi
[[ -n "$NDK" && -d "$NDK" ]] || {
  echo "Android NDK not found (ANDROID_NDK_ROOT or $SDK/ndk/<version>)." >&2
  echo "Install via: sdkmanager 'ndk;26.3.11579264'" >&2
  exit 1
}

HOST_TAG="$(uname -s | tr '[:upper:]' '[:lower:]')-x86_64"   # NDK ships darwin-x86_64 (Rosetta) on all Macs
CLANG="$NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin/clang"
[[ -x "$CLANG" ]] || { echo "NDK clang not found at $CLANG" >&2; exit 1; }

BUILD_TOOLS="$(ls -d "$SDK"/build-tools/* 2>/dev/null | sort -V | tail -1)"
[[ -n "$BUILD_TOOLS" ]] || { echo "no build-tools under $SDK (sdkmanager 'build-tools;34.0.0')" >&2; exit 1; }
AAPT2="$BUILD_TOOLS/aapt2"
ZIPALIGN="$BUILD_TOOLS/zipalign"
APKSIGNER="$BUILD_TOOLS/apksigner"
for tool in "$AAPT2" "$ZIPALIGN" "$APKSIGNER"; do
  [[ -x "$tool" ]] || { echo "missing build tool: $tool" >&2; exit 1; }
done

PLATFORM_JAR="$(ls "$SDK"/platforms/android-*/android.jar 2>/dev/null | sort -V | tail -1)"
[[ -n "$PLATFORM_JAR" ]] || { echo "no platforms/android-*/android.jar under $SDK (sdkmanager 'platforms;android-34')" >&2; exit 1; }

ADB="$SDK/platform-tools/adb"
[[ -x "$ADB" ]] || ADB="$(command -v adb || true)"

# --------------------------------------------------------- rung 2: shim .so

BUILD_DIR="$SCRIPT_DIR/build/$APP_NAME"
STAGING="$BUILD_DIR/staging"
rm -rf "$STAGING"
mkdir -p "$STAGING/lib/$ABI"

echo "== NDK clang: main.c + $(basename "$LIB") -> lib$SO_NAME.so ($ABI, API $API_LEVEL)"
"$CLANG" \
  --target="$CLANG_TRIPLE$API_LEVEL" \
  -shared -fPIC -O2 -Wall \
  -I"$SCRIPT_DIR/../ios" \
  "$SCRIPT_DIR/main.c" "$LIB" \
  -landroid -llog \
  -Wl,--no-undefined \
  -o "$STAGING/lib/$ABI/lib$SO_NAME.so"

# ------------------------------------------------------------- rung 2b: APK

sed -e "s/__APP_NAME__/$APP_NAME/g" -e "s/__PACKAGE__/$PACKAGE/g" -e "s/__LIB_NAME__/$SO_NAME/g" \
  "$SCRIPT_DIR/AndroidManifest.xml.in" > "$BUILD_DIR/AndroidManifest.xml"

UNSIGNED="$BUILD_DIR/$APP_NAME-unsigned.apk"
ALIGNED="$BUILD_DIR/$APP_NAME-aligned.apk"
APK="$BUILD_DIR/$APP_NAME.apk"
rm -f "$UNSIGNED" "$ALIGNED" "$APK"

echo "== aapt2 link + zipalign + apksigner -> $APK"
"$AAPT2" link -o "$UNSIGNED" \
  --manifest "$BUILD_DIR/AndroidManifest.xml" \
  -I "$PLATFORM_JAR" \
  --min-sdk-version "$API_LEVEL" \
  --target-sdk-version 34 \
  --version-code 1 --version-name 1.0
(cd "$STAGING" && zip -qr "$UNSIGNED" lib)
"$ZIPALIGN" -f 4 "$UNSIGNED" "$ALIGNED"

KEYSTORE="$HOME/.android/debug.keystore"
if [[ ! -f "$KEYSTORE" ]]; then
  KEYSTORE="$BUILD_DIR/debug.keystore"
  if [[ ! -f "$KEYSTORE" ]]; then
    command -v keytool >/dev/null || { echo "keytool (JDK) required to create a debug keystore" >&2; exit 1; }
    keytool -genkeypair -keystore "$KEYSTORE" -storepass android -keypass android \
      -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 \
      -dname "CN=Android Debug,O=Android,C=US" >/dev/null 2>&1
  fi
fi
"$APKSIGNER" sign --ks "$KEYSTORE" --ks-pass pass:android --key-pass pass:android \
  --out "$APK" "$ALIGNED"

if [[ "$BUILD_ONLY" -eq 1 ]]; then
  echo "== built $APK (skipping device)"
  exit 0
fi

# ------------------------------------------------- rung 3: device / emulator

[[ -n "$ADB" && -x "$ADB" ]] || { echo "adb not found (sdkmanager 'platform-tools')" >&2; exit 1; }

DEVICE_COUNT="$("$ADB" devices | awk 'NR>1 && $2=="device"' | wc -l | tr -d ' ')"
if [[ "$DEVICE_COUNT" -eq 0 ]]; then
  EMULATOR="$SDK/emulator/emulator"
  AVD="$([[ -x "$EMULATOR" ]] && "$EMULATOR" -list-avds 2>/dev/null | head -1 || true)"
  if [[ -z "$AVD" ]]; then
    echo "no device attached and no emulator AVD available" >&2
    echo "create one with: avdmanager create avd -n native-sdk -k 'system-images;android-34;google_apis;arm64-v8a'" >&2
    exit 1
  fi
  echo "== booting emulator AVD: $AVD"
  "$EMULATOR" -avd "$AVD" -no-snapshot -no-audio -no-boot-anim >/dev/null 2>&1 &
  "$ADB" wait-for-device
  for _ in $(seq 1 120); do
    [[ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]] && break
    sleep 1
  done
fi

echo "== install + launch $PACKAGE (automation enabled)"
"$ADB" shell setprop debug.native_sdk.automation 1
"$ADB" install -r "$APK" >/dev/null
"$ADB" shell am force-stop "$PACKAGE" || true
"$ADB" shell am start -n "$PACKAGE/android.app.NativeActivity" >/dev/null

# ------------------------------------------------ rung 3a: non-blank screen

sleep 4
SCREENSHOT="${SCREENSHOT:-$BUILD_DIR/$APP_NAME-android.png}"
"$ADB" exec-out screencap -p > "$SCREENSHOT"
echo "== screenshot: $SCREENSHOT"

# Non-blank verification: decode via sips -> BMP, sample a grid, count
# distinct colors (same check as the iOS run.sh).
BMP="$BUILD_DIR/$APP_NAME-android.bmp"
sips -s format bmp "$SCREENSHOT" --out "$BMP" >/dev/null
DISTINCT="$(python3 - "$BMP" <<'PY'
import struct, sys
data = open(sys.argv[1], "rb").read()
offset = struct.unpack("<I", data[10:14])[0]
width = struct.unpack("<i", data[18:22])[0]
height = abs(struct.unpack("<i", data[22:26])[0])
bpp = struct.unpack("<H", data[28:30])[0]
assert bpp in (24, 32), f"unexpected bmp bpp {bpp}"
step = bpp // 8
row_size = ((width * step + 3) // 4) * 4
colors = set()
for y in range(0, height, max(1, height // 240)):
    row = offset + y * row_size
    for x in range(0, width, max(1, width // 240)):
        p = row + x * step
        colors.add(data[p:p + 3])
print(len(colors))
PY
)"
echo "== distinct sampled colors: $DISTINCT"
if [[ "$DISTINCT" -lt 10 ]]; then
  echo "FAIL: screenshot looks blank ($DISTINCT distinct colors)" >&2
  exit 1
fi
echo "OK: non-blank frame ($DISTINCT distinct colors)"

# --------------------------------------- rung 3b: automation snapshot + tap

SNAPSHOT_REMOTE="files/native-sdk-automation/snapshot.txt"
read_snapshot() {
  "$ADB" shell run-as "$PACKAGE" cat "$SNAPSHOT_REMOTE" 2>/dev/null | tr -d '\r'
}

echo "== waiting for automation snapshot (run-as $PACKAGE $SNAPSHOT_REMOTE)"
SNAP_BEFORE=""
for _ in $(seq 1 40); do
  SNAP_BEFORE="$(read_snapshot)"
  grep -q 'widget @' <<<"$SNAP_BEFORE" && break
  sleep 0.5
done
grep -q 'widget @' <<<"$SNAP_BEFORE" || {
  echo "FAIL: snapshot never contained the widget tree" >&2
  exit 1
}
printf '%s\n' "$SNAP_BEFORE" > "$BUILD_DIR/snapshot-0-initial.txt"
echo "OK: snapshot published ($(grep -c 'widget @' <<<"$SNAP_BEFORE") widgets) -> $BUILD_DIR/snapshot-0-initial.txt"

# Injected tap: center of the first pressable button in the snapshot,
# converted from view points to device pixels via the reported density.
DENSITY="$("$ADB" shell wm density | awk '/density/{d=$NF} END{print d}' | tr -d '\r')"
[[ -n "$DENSITY" ]] || DENSITY=160
TAP_XY="$(python3 - "$DENSITY" "$BUILD_DIR/snapshot-0-initial.txt" <<'PY'
import re, sys
density = float(sys.argv[1])
text = open(sys.argv[2], encoding="utf-8").read()
for line in text.splitlines():
    line = line.strip()
    if not line.startswith("widget @") or "role=button" not in line:
        continue
    m = re.search(r"bounds=\(([-\d.]+),([-\d.]+) ([-\d.]+)x([-\d.]+)\)", line)
    if not m:
        continue
    x, y, w, h = (float(v) for v in m.groups())
    scale = density / 160.0
    print(int((x + w / 2) * scale), int((y + h / 2) * scale))
    break
PY
)"
[[ -n "$TAP_XY" ]] || { echo "FAIL: no button with bounds in snapshot" >&2; exit 1; }
echo "== adb shell input tap $TAP_XY (density $DENSITY)"
# shellcheck disable=SC2086
"$ADB" shell input tap $TAP_XY

SNAP_AFTER=""
for _ in $(seq 1 20); do
  sleep 0.5
  SNAP_AFTER="$(read_snapshot)"
  [[ -n "$SNAP_AFTER" && "$SNAP_AFTER" != "$SNAP_BEFORE" ]] && break
done
printf '%s\n' "$SNAP_AFTER" > "$BUILD_DIR/snapshot-1-after-tap.txt"
if [[ -z "$SNAP_AFTER" || "$SNAP_AFTER" == "$SNAP_BEFORE" ]]; then
  echo "FAIL: injected tap did not change the automation snapshot" >&2
  exit 1
fi
echo "OK: injected tap changed the snapshot -> $BUILD_DIR/snapshot-1-after-tap.txt"

echo "PASS: lib + shim + APK + non-blank frame + snapshot + injected tap"
