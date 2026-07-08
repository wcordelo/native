# Native SDK native-panels example

This example shows native panels composed around WebView content:

- A native `split` body with a fixed sidebar and fill WebView pane.
- A native `stack` of search, segmented, checkbox, toggle, and button controls.
- A WebView bridge call that lists the composed native view tree.

Run with the system backend:

```sh
zig build run -Dplatform=macos -Dweb-engine=system
```

Run the headless test path:

```sh
zig build test -Dplatform=null
```
