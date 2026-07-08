const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const drawing_model = @import("drawing.zig");
const token_model = @import("tokens.zig");
const widget_model = @import("widgets.zig");
const event_model = @import("events.zig");
const widget_layout = @import("widget_layout.zig");
const widget_metrics = @import("widget_metrics.zig");
const widget_render_style = @import("widget_render_style.zig");

const Error = canvas.Error;
const ObjectId = canvas.ObjectId;
const Builder = canvas.Builder;
const Radius = drawing_model.Radius;
const DesignTokens = token_model.DesignTokens;
const Widget = widget_model.Widget;
const WidgetScrollMetrics = event_model.WidgetScrollMetrics;

const colorFill = widget_render_style.colorFill;
const colorWithAlpha = widget_render_style.colorWithAlpha;
const densityValue = widget_metrics.densityValue;

pub const ScrollbarGeometry = struct {
    track: geometry.RectF,
    thumb: geometry.RectF,
};

pub fn emitScrollViewScrollbar(builder: *Builder, frame: geometry.RectF, metrics: WidgetScrollMetrics, tokens: DesignTokens, id: ObjectId) Error!void {
    const scrollbar = scrollViewScrollbarGeometry(frame, metrics, tokens) orelse return;
    const track = pixelSnapGeometryRect(tokens, scrollbar.track);
    const thumb = pixelSnapGeometryRect(tokens, scrollbar.thumb);
    const visual = tokens.controls.scrollbar;
    const radius = Radius.all(if (visual.radius) |value| nonNegative(value) else track.width * 0.5);
    const track_fill = visual.background orelse colorWithAlpha(tokens.colors.border, @min(tokens.colors.border.a, 0.22));
    const thumb_fill = visual.foreground orelse visual.active_background orelse colorWithAlpha(tokens.colors.text_muted, 0.55);
    try builder.fillRoundedRect(.{
        .id = widgetPartId(id, 2),
        .rect = track,
        .radius = radius,
        .fill = colorFill(track_fill),
    });
    try builder.fillRoundedRect(.{
        .id = widgetPartId(id, 3),
        .rect = thumb,
        .radius = radius,
        .fill = colorFill(thumb_fill),
    });
}

pub fn scrollViewScrollbarGeometry(frame: geometry.RectF, metrics: WidgetScrollMetrics, tokens: DesignTokens) ?ScrollbarGeometry {
    if (!metrics.present) return null;
    const viewport = nonNegative(metrics.viewport_extent);
    const content = nonNegative(metrics.content_extent);
    const max_offset = @max(0, content - viewport);
    if (frame.isEmpty() or viewport <= 0 or content <= viewport or max_offset <= 0) return null;

    const inset = densityValue(tokens, 3);
    const thickness = @min(@max(densityValue(tokens, 3), frame.width * 0.0125), densityValue(tokens, 6));
    const track_height = @max(0, frame.height - inset * 2);
    if (track_height <= 0 or thickness <= 0) return null;

    const track = geometry.RectF.init(
        frame.x + frame.width - inset - thickness,
        frame.y + inset,
        thickness,
        track_height,
    );
    const thumb_ratio = std.math.clamp(viewport / content, 0, 1);
    const min_thumb = @min(track_height, densityValue(tokens, 18));
    const thumb_height = @min(track_height, @max(min_thumb, track_height * thumb_ratio));
    const travel = @max(0, track_height - thumb_height);
    const offset_ratio = std.math.clamp(nonNegative(metrics.offset) / max_offset, 0, 1);
    return .{
        .track = track,
        .thumb = geometry.RectF.init(track.x, track.y + travel * offset_ratio, track.width, thumb_height),
    };
}

pub fn widgetScrollMetricsForWidget(widget: Widget, tokens: DesignTokens) WidgetScrollMetrics {
    if (widget.kind != .scroll_view) return .{};

    const viewport = widget.frame.inset(widget.layout.padding).normalized();
    if (viewport.isEmpty()) return .{};

    const content_extent = widgetScrollContentExtentForWidget(widget, viewport, tokens);
    const max_offset = @max(0, content_extent - viewport.height);
    return .{
        .present = true,
        .offset = std.math.clamp(nonNegative(widget.value), 0, max_offset),
        .viewport_extent = viewport.height,
        .content_extent = content_extent,
    };
}

fn widgetScrollContentExtentForWidget(widget: Widget, viewport: geometry.RectF, tokens: DesignTokens) f32 {
    if (widget.layout.virtualized) {
        return @max(viewport.height, widget_layout.virtualWidgetScrollContentExtentWithTokens(widget, viewport.height, tokens));
    }

    const offset = widget.value;
    var bottom = viewport.maxY();
    for (widget.children) |child| {
        bottom = @max(bottom, child.frame.maxY() + offset);
    }
    return @max(0, bottom - viewport.y);
}

fn pixelSnapGeometryRect(tokens: DesignTokens, rect: geometry.RectF) geometry.RectF {
    const scale = pixelSnapScale(tokens) orelse return rect;
    return geometry.RectF.init(
        pixelSnapValueWithScale(rect.x, scale),
        pixelSnapValueWithScale(rect.y, scale),
        pixelSnapValueWithScale(rect.width, scale),
        pixelSnapValueWithScale(rect.height, scale),
    );
}

fn pixelSnapScale(tokens: DesignTokens) ?f32 {
    if (!tokens.pixel_snap.geometry) return null;
    const scale = tokens.pixel_snap.scale;
    if (!std.math.isFinite(scale) or scale <= 0) return null;
    return scale;
}

fn pixelSnapValueWithScale(value: f32, scale: f32) f32 {
    return @round(value * scale) / scale;
}

fn widgetPartId(id: ObjectId, slot: ObjectId) ObjectId {
    return widget_model.widgetCommandPartId(.{ .widget_id = id, .slot = slot });
}

fn nonNegative(value: f32) f32 {
    return @max(0, value);
}
