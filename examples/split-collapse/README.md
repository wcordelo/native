# Native SDK split-collapse example

The smallest honest pane-collapse animation harness: a two-pane split whose sidebar collapses and expands over 180 ms, built to measure frame pacing during a layout tween and to demonstrate the runtime layout-tween primitive against the manual idiom it replaces.

Three driving modes, selected by environment variable:

- Default (runtime tween): the model owns only the resting `collapsed` flag; the `layout_tweens` hook declares the split's target fraction and the runtime eases the rendered fraction toward it, one step per presented frame — no per-frame Msgs, and reduced-motion appearances snap.
- `SPLIT_COLLAPSE_MARKUP=1` (markup tween): the same primitive declared entirely in markup — `resize-duration="180"` (and `resize-easing`) on the `split` element in `src/split_collapse.native` makes the bound `value` a tween target, so the view file is the whole animation and no Zig hook exists.
- `SPLIT_COLLAPSE_MANUAL=1` (manual ticks): the historical idiom — `on_frame` returns a tick Msg carrying the presented frame's timestamp, `update` eases the fraction, and every tick is a full rebuild.

Every tween step logs its arrival cadence on stderr (`tween-frame dt_ms=...` in manual mode, `tween-echo fraction=...` in the runtime and markup modes), so a driver can count the visible steps of the 180 ms collapse and read the real deltas between frames.

Extra knobs:

- `SPLIT_COLLAPSE_AUTO_MS=<interval>` arms a repeating auto-toggle so the tween runs without automation.
- `SPLIT_COLLAPSE_WEB=1` snaps a live webview to the content pane, so the tween reflows real web content beside the collapsing sidebar.

Run with the macOS system backend:

```sh
native dev
```

Run the model-contract tests headless:

```sh
native test -Dplatform=null
```
