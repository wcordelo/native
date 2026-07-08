# linux-truth

The Linux live-truth loop: drives the toolkit's showcase apps in real X11 windows under Xvfb inside a container, capturing what Linux actually does — layout, input, IME, resize clamps, screenshots — instead of trusting the null platform.

Prerequisites: a container runtime on the host (the image bundles Zig, GTK4, WebKitGTK dev headers, and Xvfb). The repo mounts read-only at `/src`, builds happen in the container-local `/work` volume, and artifacts land in the container's `/out` (`docker cp native-sdk-linux-truth:/out <dest>` copies them home).

One command runs everything, or one named step, from the repo root on the host:

```sh
tools/linux-truth/run-all.sh [image|up|sync|recon|drive|suites|all]
```

Steps: `image` builds the container image and `up` starts the long-lived container; `sync.sh` rsyncs `/src` into `/work` after local edits (never writing back); `recon.sh` builds and launches every showcase app, dumping snapshots, widget inventories, and both screenshot channels; `drive.sh` replays per-app interaction scenarios (clicks, text input, wheel, resize including the min-size clamp); `suites` runs the engine and example test suites plus the webview link check on real Linux. `lib.sh` holds the shared helpers and `send-wm-delete.c` closes windows the way a window manager would.
