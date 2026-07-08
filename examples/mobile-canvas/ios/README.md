# iOS simulator shim for mobile embed libraries

A minimal ObjC shim (no `.xcodeproj`) that links any `native_sdk.addMobileLib` static library and shows its canvas scene on the iOS simulator. Presentation: a `CADisplayLink` pumps `native_sdk_app_frame`, and each frame whose canvas revision changed is rendered over the ABI (`native_sdk_app_render_pixels`, CPU reference renderer, RGBA8), swizzled to BGRA, uploaded with `MTLTexture replaceRegion`, and blit-copied to the `CAMetalLayer` drawable — mirroring the macOS raster path in `src/platform/macos/appkit_host.m`. Input: UITouch sequences forward through the ABI touch/scroll exports (tap presses widgets, over-slop pans scroll through the existing scroll reconciliation), the system keyboard shows/hides off `native_sdk_app_text_input_state` (textbox focus = first responder), and UITextInput marked text maps onto the `native_sdk_app_ime` composition path desktop hosts use. Layout: the shim reports the view's safe-area insets through `native_sdk_app_viewport` and the runtime insets widget layout by them (the canvas still paints edge to edge), so content stays clear of the Dynamic Island / home indicator and relayouts on rotation. Text metrics: a CoreText measure callback registered via `native_sdk_app_set_text_measure` gives layout real typographic widths (glyph rendering stays the reference renderer's shapes); launch with `--estimator-text-metrics` to keep the deterministic estimator.

## Run

```sh
# mobile-canvas on an "iPhone 15" simulator, screenshot + non-blank check
./run.sh

# ui-inbox through the same shim
./run.sh --example-dir ../../ui-inbox --build-arg -Dmobile=true

# options
./run.sh --device "iPhone 15 Pro"   # pick a simulator
./run.sh --build-only               # stop after the .app bundle
./run.sh --shutdown                 # shut the simulator down afterwards
```

The script cross-compiles the example's embed library (`zig build lib -Dtarget=aarch64-ios-simulator`), compiles `main.m` with the simulator SDK, assembles `build/<name>/<name>.app`, installs + launches it, and fails unless a screenshot samples as non-blank.

## Verify input (hardware-true)

```sh
# ui-inbox: injected tap grows the list, textbox focus raises the system
# keyboard, typed text lands in the model, drag-scroll moves the offset
./verify_input.sh
./verify_input.sh --device "iPhone 15 Pro" --shutdown
```

`verify_input.sh` launches the app with `NATIVE_SDK_AUTOMATION=1` (the shim points the runtime's automation snapshots into the app's data container via `native_sdk_app_set_automation_dir`), compiles `InputUITests.m` into an XCUITest bundle hosted by the stock `XCTRunner.app` (generated `.xctestrun`, `xcodebuild test-without-building` — still no `.xcodeproj`), injects real system touch/keyboard events, and asserts model state between steps against `snapshot.txt`.

## Verify layout (safe areas, rotation, scale)

```sh
# ui-inbox: widgets lie inside the portrait safe areas, a real rotation
# (XCUITest, no simctl rotate exists) relayouts against the landscape
# insets, and the screenshot pixel/point ratio equals the device scale
./verify_layout.sh
./verify_layout.sh --device "iPhone 15 Pro" --shutdown
```

## Files

- `main.m` — UIWindow + CAMetalLayer view + display link + blit presenter + touch forwarding + UIKeyInput/UITextInput keyboard and IME bridge + CoreText measure callback.
- `native_sdk_app.h` — the ABI subset the shim drives (layouts mirror `src/embed/types.zig`).
- `Info.plist.in` — bundle plist template (`__APP_NAME__`/`__BUNDLE_ID__` substituted by `run.sh`).
- `run.sh` — build, bundle, install, launch, screenshot, verify.
- `InputUITests.m` / `verify_input.sh` — real input injection + snapshot-asserted M3 verification.
- `verify_layout.sh` — snapshot-asserted M4 verification (safe-area insets, rotation relayout, device scale).
