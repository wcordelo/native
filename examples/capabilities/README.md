# Native SDK capabilities example

This example shows guarded OS capabilities from trusted WebView code:

- Platform support discovery.
- Open URL, reveal path, and recent document OS services.
- Notifications.
- Clipboard text read and write.
- Message dialogs.
- Credential set, get, and delete.
- File-drop events delivered to Zig and the WebView event bridge.
- File association and custom URL scheme packaging metadata.
- App activation and deactivation events.

Run with the system backend:

```sh
zig build run -Dplatform=macos -Dweb-engine=system
```

Run the headless test path:

```sh
zig build test -Dplatform=null
```

Run all native-first example tests from the repository root:

```sh
zig build test-examples-native
```
