# @native-sdk/cli

The command line for [Native SDK](https://zero-native.dev): the complete toolkit for building native desktop applications.

Views are declarative markup in `.native` files, logic is plain Zig, and Native SDK's own engine draws every pixel into real OS windows — no browser, no WebView, no interpreter in the binary.

## Install

```bash
npm install -g @native-sdk/cli
```

The install runs no scripts: the `native` binary arrives as a per-platform optional dependency (`@native-sdk/cli-<platform>`), and this package carries the SDK source your apps build against, so `native init` and `native dev` work offline after install. The pinned Zig toolchain is fetched into `~/.native/toolchains/` on first build unless a compatible `zig` is already on your PATH.

## Use

```bash
native init my_app
cd my_app
native dev
```

A native window opens with a working counter. The scaffold is a native-rendered markup app with no build files — `native dev|build|test` own the build — and `src/app.native` hot-reloads while the app runs, keeping your state. `native check` validates every view in milliseconds without building.

When part of your product is the web, WebView surfaces coexist with the native canvas; web-frontend scaffolds (`--frontend next`, `--frontend vite`, and more) install their generated frontend dependencies automatically on first run.

Read the full guide at [zero-native.dev/quick-start](https://zero-native.dev/quick-start).

## Commands

| Command | Description |
|---------|-------------|
| `native init [path] [--frontend <native\|next\|vite\|react\|svelte\|vue>] [--full]` | Scaffold a new Native SDK app |
| `native dev [dir]` | Build and run the app (markup hot reload; managed frontend dev server when configured) |
| `native build [dir]` | Build a ReleaseFast binary into `zig-out/bin/` |
| `native test [dir]` | Run the app's test suite |
| `native check [dir]` | Validate `src/**.native` markup and `app.zon` against the model contract |
| `native markup check\|lsp` | Check individual markup files, or serve diagnostics, completion, and hover to your editor |
| `native eject [dir]` | Write an owned build.zig/build.zig.zon into the app |
| `native doctor` | Check host environment, WebView, manifest, and CEF |
| `native validate` | Validate `app.zon` against the manifest schema |
| `native package` | Package the app for distribution |
| `native bundle-assets` | Copy frontend assets into the build output |
| `native automate` | Drive a running app: snapshots, widgets, assertions, screenshots, record/replay |
| `native skills list\|get <name>` | List or print the built-in AI agent skills |
| `native version` | Print the native version |

## More

The full documentation is at [zero-native.dev](https://zero-native.dev) — the [app model](https://zero-native.dev/app-model), [native UI authoring](https://zero-native.dev/native-ui), [components](https://zero-native.dev/components), [testing](https://zero-native.dev/testing), [automation](https://zero-native.dev/automation), [capabilities](https://zero-native.dev/capabilities), [packaging](https://zero-native.dev/packaging), and [platform support](https://zero-native.dev/platform-support).

Native SDK is pre-1.0 and Apache-2.0 licensed; the source lives at [github.com/vercel-labs/zero-native](https://github.com/vercel-labs/zero-native).
