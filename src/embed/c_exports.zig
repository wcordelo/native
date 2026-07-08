//! Root module of the default embeddable static library (`zig build lib`):
//! exports the `native_sdk_app_*` C ABI answered by the fixed WebView
//! shell host. Libraries compiled with a user app use
//! `app_exports.zig` (via `native_sdk.addMobileLib`) instead.

const native_sdk = @import("native_sdk");

comptime {
    native_sdk.embed.exportMobileCApi(native_sdk.embed.MobileHostApp);
}
