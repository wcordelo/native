# Hello Example

A minimal Native SDK app that displays inline HTML in the system WebView.

## Run

```bash
zig build run
```

## Using outside the repo

This example references the Native SDK via relative path (`../../`). To use it standalone, override the path:

```bash
zig build run -Dnative-sdk-path=/path/to/native-sdk
```

Or, when a published Zig package is available, replace `default_native_sdk_path` in `build.zig` with the package URL and add it to `build.zig.zon` dependencies.
