const std = @import("std");
const native_sdk = @import("native_sdk");
const model = @import("model.zig");
const scene = @import("scene.zig");

const canvas = native_sdk.canvas;
const canvas_width = model.window_width;
const geometry = native_sdk.geometry;

const canvas_label = model.canvas_label;
const canvas_sidebar_width = model.canvas_sidebar_width;
const canvas_content_y = model.canvas_content_y;
const canvas_content_height = model.canvas_content_height;
const content_scroll_id = model.content_scroll_id;
const canvas_status_text_id = model.canvas_status_text_id;
const componentCommandPartId = model.componentCommandPartId;
const rect = model.rect;

const componentFrameStatus = scene.componentFrameStatus;

pub fn componentSnapshotWidget(snapshot: native_sdk.automation.snapshot.Input, id: u64) ?native_sdk.automation.snapshot.Widget {
    for (snapshot.widgets) |widget| {
        if (widget.id == id and std.mem.eql(u8, widget.view_label, canvas_label)) return widget;
    }
    return null;
}

pub fn componentStatusText(runtime: *const native_sdk.Runtime) ![]const u8 {
    const layout = try runtime.canvasWidgetLayout(1, canvas_label);
    const node = layout.findById(canvas_status_text_id) orelse return error.TestUnexpectedResult;
    return node.widget.text;
}

pub fn expectComponentStatusContains(runtime: *const native_sdk.Runtime, text: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, try componentStatusText(runtime), text) != null);
}

pub fn resetComponentDirty(runtime: *native_sdk.Runtime) void {
    runtime.invalidated = false;
    runtime.dirty_region_count = 0;
}

pub fn componentWidgetCenter(runtime: *const native_sdk.Runtime, id: canvas.ObjectId) !geometry.PointF {
    const layout = try runtime.canvasWidgetLayout(1, canvas_label);
    const node = layout.findById(id) orelse return error.TestUnexpectedResult;
    return node.frame.center();
}

pub fn dispatchComponentPointerClick(runtime: *native_sdk.Runtime, app: native_sdk.App, id: canvas.ObjectId) !void {
    try dispatchComponentPointerClickAtTimestamp(runtime, app, id, 0);
}

pub fn dispatchComponentPointerClickAtTimestamp(runtime: *native_sdk.Runtime, app: native_sdk.App, id: canvas.ObjectId, timestamp_ns: u64) !void {
    const point = try componentWidgetCenter(runtime, id);
    try runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pointer_down,
        .timestamp_ns = timestamp_ns,
        .x = point.x,
        .y = point.y,
        .button = 0,
    } });
    try runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pointer_up,
        .timestamp_ns = timestamp_ns,
        .x = point.x,
        .y = point.y,
        .button = 0,
    } });
}

pub fn dispatchComponentPointerWheel(runtime: *native_sdk.Runtime, app: native_sdk.App, id: canvas.ObjectId, delta_y: f32) !void {
    const point = try componentWidgetCenter(runtime, id);
    try runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .scroll,
        .x = point.x,
        .y = point.y,
        .delta_y = delta_y,
    } });
}

pub fn dispatchComponentPointerDrag(runtime: *native_sdk.Runtime, app: native_sdk.App, id: canvas.ObjectId, start_ratio: f32, end_ratio: f32) !void {
    const layout = try runtime.canvasWidgetLayout(1, canvas_label);
    const node = layout.findById(id) orelse return error.TestUnexpectedResult;
    const start = geometry.PointF.init(node.frame.x + node.frame.width * start_ratio, node.frame.center().y);
    const end = geometry.PointF.init(node.frame.x + node.frame.width * end_ratio, node.frame.center().y);
    try dispatchComponentPointerDragPoints(runtime, app, start, end);
}

pub fn dispatchComponentPointerDragByDelta(runtime: *native_sdk.Runtime, app: native_sdk.App, id: canvas.ObjectId, delta_x: f32) !void {
    const point = try componentWidgetCenter(runtime, id);
    try dispatchComponentPointerDragPoints(runtime, app, point, geometry.PointF.init(point.x + delta_x, point.y));
}

pub fn dispatchComponentPointerDragPoints(runtime: *native_sdk.Runtime, app: native_sdk.App, start: geometry.PointF, end: geometry.PointF) !void {
    try runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pointer_down,
        .x = start.x,
        .y = start.y,
        .button = 0,
    } });
    try runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pointer_drag,
        .x = end.x,
        .y = end.y,
        .delta_x = end.x - start.x,
        .delta_y = end.y - start.y,
        .button = 0,
    } });
    try runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pointer_up,
        .x = end.x,
        .y = end.y,
        .button = 0,
    } });
}

pub fn expectComponentTextCommand(display_list: canvas.DisplayList, id: canvas.ObjectId, text: []const u8) !void {
    const command_ref = display_list.findCommandById(id) orelse return error.TestUnexpectedResult;
    switch (command_ref.command) {
        .draw_text => |draw| try std.testing.expectEqualStrings(text, draw.text),
        else => return error.TestUnexpectedResult,
    }
}

pub fn expectComponentFillRoundedRectColor(display_list: canvas.DisplayList, id: canvas.ObjectId, expected: canvas.Color) !void {
    const command_ref = display_list.findCommandById(id) orelse return error.TestUnexpectedResult;
    switch (command_ref.command) {
        .fill_rounded_rect => |fill| switch (fill.fill) {
            .color => |actual| try std.testing.expectEqualDeep(expected, actual),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

pub fn expectSemanticRole(semantics: []const canvas.WidgetSemanticsNode, id: canvas.ObjectId, role: canvas.WidgetRole) !void {
    const semantic = expectSemantic(semantics, id);
    try std.testing.expectEqual(role, semantic.role);
}

pub fn expectComponentWidgetFrame(layout: canvas.WidgetLayoutTree, id: canvas.ObjectId, expected: geometry.RectF) !void {
    const node = layout.findById(id) orelse return error.TestUnexpectedResult;
    try expectComponentRect(node.frame, expected);
}

pub fn referenceSurfaceSignature(pixels: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (pixels) |byte| {
        hash = (hash ^ byte) *% 1099511628211;
    }
    return hash;
}

pub fn expectSemantic(semantics: []const canvas.WidgetSemanticsNode, id: canvas.ObjectId) canvas.WidgetSemanticsNode {
    for (semantics) |semantic| {
        if (semantic.id == id) return semantic;
    }
    @panic("missing semantic node");
}

pub fn expectComponentRect(actual: geometry.RectF, expected: geometry.RectF) !void {
    try std.testing.expectApproxEqAbs(expected.x, actual.x, 0.001);
    try std.testing.expectApproxEqAbs(expected.y, actual.y, 0.001);
    try std.testing.expectApproxEqAbs(expected.width, actual.width, 0.001);
    try std.testing.expectApproxEqAbs(expected.height, actual.height, 0.001);
}

pub fn expectNoContentScrollContainerChrome(display_list: canvas.DisplayList) !void {
    const clip_ref = display_list.findCommandById(componentCommandPartId(content_scroll_id, 1)) orelse return error.TestUnexpectedResult;
    if (clip_ref.command != .push_clip) return error.TestUnexpectedResult;
    try std.testing.expect(display_list.findCommandById(componentCommandPartId(content_scroll_id, 4)) == null);
    const content_frame = rect(canvas_sidebar_width, canvas_content_y, canvas_width - canvas_sidebar_width, canvas_content_height);
    for (display_list.commands) |command| {
        switch (command) {
            .fill_rounded_rect => |fill| if (rectLooksLikeMainContentContainer(fill.rect, content_frame)) return error.TestUnexpectedResult,
            .stroke_rect => |stroke| if (rectLooksLikeMainContentContainer(stroke.rect, content_frame)) return error.TestUnexpectedResult,
            .shadow => |shadow| if (rectLooksLikeMainContentContainer(shadow.rect, content_frame)) return error.TestUnexpectedResult,
            else => {},
        }
    }
}

pub fn expectVisiblePixel(pixel: [4]u8) !void {
    try std.testing.expect(pixel[3] > 0);
    try std.testing.expect(pixel[0] != 0 or pixel[1] != 0 or pixel[2] != 0);
}

pub fn expectNoSurfaceAnimation(animations: []const canvas.CanvasRenderAnimation, id: canvas.ObjectId) !void {
    for (animations) |animation| {
        if (animation.id == id) return error.TestUnexpectedResult;
    }
}

pub fn expectComponentWidgetIndex(layout: canvas.WidgetLayoutTree, id: canvas.ObjectId) !usize {
    for (layout.nodes, 0..) |node, index| {
        if (node.widget.id == id) return index;
    }
    return error.TestUnexpectedResult;
}

pub fn expectComponentRoundedRectFrame(display_list: canvas.DisplayList, id: canvas.ObjectId, expected: geometry.RectF) !void {
    const command_ref = display_list.findCommandById(id) orelse return error.TestUnexpectedResult;
    switch (command_ref.command) {
        .fill_rounded_rect => |rounded| try expectComponentRect(rounded.rect, expected),
        else => return error.TestUnexpectedResult,
    }
}

pub fn expectComponentFillRectFrame(display_list: canvas.DisplayList, id: canvas.ObjectId, expected: geometry.RectF) !void {
    const command_ref = display_list.findCommandById(id) orelse return error.TestUnexpectedResult;
    switch (command_ref.command) {
        .fill_rect => |fill| try expectComponentRect(fill.rect, expected),
        else => return error.TestUnexpectedResult,
    }
}

pub fn expectComponentWidgetsDoNotOverlap(layout: canvas.WidgetLayoutTree, a_id: canvas.ObjectId, b_id: canvas.ObjectId) !void {
    const a = layout.findById(a_id) orelse return error.TestUnexpectedResult;
    const b = layout.findById(b_id) orelse return error.TestUnexpectedResult;
    try std.testing.expect(geometry.RectF.intersection(a.frame.normalized(), b.frame.normalized()).isEmpty());
}

pub fn rectLooksLikeMainContentContainer(actual: geometry.RectF, content_frame: geometry.RectF) bool {
    const normalized = actual.normalized();
    if (!content_frame.containsRect(normalized)) return false;
    return normalized.width >= content_frame.width - 160 and normalized.height >= content_frame.height - 160;
}

pub fn expectNoSurfaceChrome(display_list: canvas.DisplayList, id: canvas.ObjectId) !void {
    for (display_list.commands) |command| {
        const command_id = command.objectId() orelse continue;
        if (command_id < id * 16 or command_id >= (id + 1) * 16) continue;
        switch (command) {
            .fill_rect, .fill_rounded_rect, .stroke_rect, .shadow => return error.TestUnexpectedResult,
            else => {},
        }
    }
}

pub fn expectSurfaceTransformAnimation(animations: []const canvas.CanvasRenderAnimation, id: canvas.ObjectId, tx: f32, ty: f32) !void {
    for (animations) |animation| {
        if (animation.id != id) continue;
        try std.testing.expectEqualDeep(canvas.Affine.identity(), animation.to_transform.?);
        try std.testing.expectApproxEqAbs(tx, animation.from_transform.?.tx, 0.001);
        try std.testing.expectApproxEqAbs(ty, animation.from_transform.?.ty, 0.001);
        return;
    }
    return error.TestUnexpectedResult;
}

pub fn expectSurfaceOpacityAnimation(animations: []const canvas.CanvasRenderAnimation, id: canvas.ObjectId) !void {
    for (animations) |animation| {
        if (animation.id != id) continue;
        try std.testing.expectEqual(@as(f32, 0), animation.from_opacity.?);
        try std.testing.expectEqual(@as(f32, 1), animation.to_opacity.?);
        try std.testing.expect(animation.from_transform == null);
        try std.testing.expect(animation.to_transform == null);
        return;
    }
    return error.TestUnexpectedResult;
}

pub fn expectSurfaceAnimationStart(animations: []const canvas.CanvasRenderAnimation, id: canvas.ObjectId, start_ns: u64) !void {
    for (animations) |animation| {
        if (animation.id != id) continue;
        try std.testing.expectEqual(start_ns, animation.start_ns);
        return;
    }
    return error.TestUnexpectedResult;
}
