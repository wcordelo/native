//! The toolkit-owned Android host sources as embedded bytes — the
//! `android_host` module the CLI tooling imports. The host lives here
//! (next to the other platform hosts) and the CLI carries the bytes, so
//! `native dev --target android` and `native package --target android`
//! emit the same host wherever the binary runs.

pub const activity_java = @embedFile("NativeSdkActivity.java");
pub const android_host_c = @embedFile("android_host.c");
pub const native_sdk_app_h = @embedFile("native_sdk_app.h");
