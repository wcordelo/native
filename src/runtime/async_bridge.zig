const bridge = @import("../bridge/root.zig");
const platform = @import("../platform/root.zig");

pub const max_async_bridge_responses: usize = 64;
pub const max_bridge_origin_bytes: usize = 512;

pub fn AsyncBridgeResponseSlot(comptime Runtime: type) type {
    return struct {
        const Self = @This();

        in_use: bool = false,
        runtime: ?*Runtime = null,
        source: bridge.Source = .{},
        origin_storage: [max_bridge_origin_bytes]u8 = undefined,
        webview_label_storage: [platform.max_webview_label_bytes]u8 = undefined,

        pub fn init(self: *Self, runtime: *Runtime, source: bridge.Source) !void {
            if (source.origin.len > self.origin_storage.len) return error.BridgeOriginTooLarge;
            if (source.webview_label.len > self.webview_label_storage.len) return error.WebViewLabelTooLarge;
            self.runtime = runtime;
            self.source = .{
                .origin = try copyInto(&self.origin_storage, source.origin),
                .window_id = source.window_id,
                .webview_label = try copyInto(&self.webview_label_storage, source.webview_label),
            };
            self.in_use = true;
        }

        pub fn release(self: *Self) void {
            self.in_use = false;
            self.runtime = null;
            self.source = .{};
        }

        pub fn respond(self: *Self, response: []const u8) anyerror!void {
            if (!self.in_use) return error.AsyncBridgeResponseAlreadyCompleted;
            const runtime = self.runtime orelse return error.AsyncBridgeResponseAlreadyCompleted;
            const source = self.source;
            defer self.release();
            try runtime.respondToBridge(source, response);
        }
    };
}

fn copyInto(buffer: []u8, value: []const u8) ![]const u8 {
    if (value.len > buffer.len) return error.NoSpaceLeft;
    @memcpy(buffer[0..value.len], value);
    return buffer[0..value.len];
}
