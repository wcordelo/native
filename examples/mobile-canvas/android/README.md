# Android shim for mobile embed libraries

A minimal NativeActivity shim (no Gradle, no Java — `android:hasCode="false"`) that links any `native_sdk.addMobileLib` static library into a single shared object and shows its canvas scene on an Android device or emulator. Presentation: `AChoreographer` pumps `native_sdk_app_frame` (the CADisplayLink twin), and each frame whose canvas revision changed is rendered over the ABI (`native_sdk_app_render_pixels`, CPU reference renderer, RGBA8) and row-copied into the locked `ANativeWindow` buffer — `WINDOW_FORMAT_RGBA_8888` matches the renderer's byte order, so unlike the iOS Metal path there is no swizzle, only stride-aware copies. Input: `AMotionEvent` sequences forward through the same touch-slop state machine as the iOS shim (under-slop tap = pointer_down+up, over-slop on an overflowing scrollable widget = wheel deltas through the scroll reconciliation, over-slop elsewhere = pointer drag), with coordinates converted from device pixels to view points by the density scale. Safe-area insets are approximated from `onContentRectChanged` and reported through `native_sdk_app_viewport`. Not wired (deliberately, this shim ships zero Java): the soft keyboard / IME path — Android IME needs an `InputConnection` on the Java side, which is future work — and platform text metrics (layout uses the deterministic estimator; the `native_sdk_app_set_text_measure` seam is exported and ready).

The C ABI header is shared with the iOS shim (`../ios/native_sdk_app.h`); `run.sh` adds it to the include path so the two shims cannot drift.

## Run

```sh
# mobile-canvas on the attached device / first emulator AVD, arm64-v8a
./run.sh

# ui-inbox through the same shim
./run.sh --example-dir ../../ui-inbox --build-arg -Dmobile=true

# options
./run.sh --abi x86_64        # x86_64 emulator image
./run.sh --lib-only          # stop after the zig static lib + nm symbol check
./run.sh --build-only        # stop after the signed APK
```

The script cross-compiles the example's embed library (`zig build lib -Dtarget=aarch64-linux-android` — plain Zig, no NDK sysroot: the static lib links no libc), verifies the shim-required ABI symbols with `nm`, compiles + links `main.c` with the NDK's clang into `libnative_sdk_shim.so`, assembles and signs an APK with `aapt2`/`zipalign`/`apksigner` (no Gradle), installs it with adb, and then verifies three rungs: a non-blank screenshot, an automation `snapshot.txt` published into the app's files dir (`adb shell setprop debug.native_sdk.automation 1` before launch; read back with `adb shell run-as`), and an injected `adb shell input tap` on the first button that must change the snapshot.

Requirements past the `--lib-only` rung: Android SDK (build-tools, platform-tools, a `platforms/android-*` jar), NDK r23+, and Java for signing. `minSdkVersion` is 29 — the embed library is built PIC and its thread-locals use TLSDESC relocations, which bionic supports on arm64 from API 29 (also the floor for `AChoreographer_postFrameCallback64`).

## Files

- `main.c` — NativeActivity callbacks + AChoreographer frame pump + ANativeWindow presenter + touch-slop forwarding + automation dir wiring.
- `AndroidManifest.xml.in` — manifest template (`__APP_NAME__`/`__PACKAGE__`/`__LIB_NAME__` substituted by `run.sh`).
- `run.sh` — build, link, package, sign, install, launch, screenshot, snapshot, injected tap.
