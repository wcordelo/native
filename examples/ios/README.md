# iOS Example

A minimal iOS mobile shell that embeds a Native SDK static library from Swift. The example keeps a native UIKit header above a WKWebView workspace and routes native header actions through the Native SDK command path.

UIKit owns the mobile shell layout: safe-area placement, Dynamic Type text, orientation relayout, and the `WKWebView` workspace. The Native SDK runtime is driven through the C ABI from the host controller.

## Build the native library

Build or package an iOS static library from the repository root, then copy it into this example:

```bash
zig build lib -Dtarget=aarch64-ios
mkdir -p examples/ios/Libraries
cp zig-out/lib/libnative-sdk.a examples/ios/Libraries/libnative-sdk.a
```

The Xcode project expects the library at `Libraries/libnative-sdk.a` and the C header at `NativeSdkIOSExample/native_sdk.h`.

## Run

Open the project in Xcode:

```bash
open examples/ios/NativeSdkIOSExample.xcodeproj
```

Select a simulator or device and run the `NativeSdkIOSExample` scheme.

## Files

- `NativeSdkIOSExample/NativeSdkHostViewController.swift` hosts native UIKit chrome, a `WKWebView` workspace, and the Native SDK C ABI.
- `NativeSdkIOSExample/native_sdk.h` declares the C ABI expected from `libnative-sdk.a`.
- `NativeSdkIOSExample/NativeSdkDyldShim.c` supplies `_dyld_get_image_header_containing_address` (unavailable in the iOS SDK) via `dladdr` so the static library's panic symbolication links.
- `app.zon` records the mobile example metadata for Native SDK tooling.

## Host lifecycle

- `viewDidLoad` creates and starts the Native SDK app.
- `SceneDelegate` forwards activation and resignation with `native_sdk_app_activate` and `native_sdk_app_deactivate`.
- `viewDidLayoutSubviews` forwards the current WebView size, screen scale, safe-area insets, and keyboard inset with `native_sdk_app_viewport`, then requests a frame.
- Keyboard frame changes adjust the `WKWebView` bottom constraint while also forwarding the keyboard inset to the Native SDK.
- The embedded C ABI exposes hardware key, committed text, and IME composition entry points for GPU/widget text fields.
- The embedded C ABI can expose retained GPU/widget accessibility semantics by indexed snapshot and dispatch widget accessibility actions for UIKit accessibility elements.
- The native Back and Refresh buttons call `native_sdk_app_command` with stable mobile command IDs, update status from `native_sdk_app_last_command_count`, and request a frame.
- Controller teardown stops and destroys the app.

The `app.zon` shell view tree describes this header and WebView workspace. Native mobile layout is still implemented in Swift so UIKit owns safe areas, keyboard avoidance, and scene lifecycle while the Native SDK receives the viewport metrics needed for GPU/widget layout.
