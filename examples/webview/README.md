# WebView Example

A Native SDK app with inline HTML, a native bridge command (`native.ping`), and builtin window management commands.

## Run

```bash
zig build run
```

With Chromium/CEF:

```bash
zig build run -Dweb-engine=chromium -Dcef-auto-install=true
```

With automation enabled (for testing):

```bash
zig build run -Dautomation=true
```

## Using outside the repo

This example references the Native SDK via relative path (`../../`). To use it standalone, override the path:

```bash
zig build run -Dnative-sdk-path=/path/to/native-sdk
```

Or, when a published Zig package is available, replace `default_native_sdk_path` in `build.zig` with the package URL and add it to `build.zig.zon` dependencies.
