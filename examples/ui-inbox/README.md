# ui-inbox

A native-rendered task inbox written entirely with the experimental `canvas.Ui` declarative builder. The whole app is one elm-style loop — `Model` → `Msg` → `update` → `view` — with no hand-assigned widget ids, no absolute frames, and no string command dispatch:

- Widget identity is structural (tree path + keys), so keyed rows keep their ids across rebuilds, reorders, and filtering.
- Layout is flex (`gap`, `padding`, `grow`, alignment) resolved by the canvas engine.
- Pointer and keyboard events resolve to typed `Msg` values through the tree's handler table (`tree.msgForPointer` / `tree.msgForKeyboard`).

Run it (macOS):

```bash
zig build run
```

Run the model/view tests on any platform:

```bash
zig build test
```
