const std = @import("std");
const geometry = @import("geometry");
const drawing_model = @import("drawing.zig");

const Affine = drawing_model.Affine;
const PathElement = drawing_model.PathElement;
const reference_curve_segments: usize = 12;

pub fn referenceDistanceToSegment(point: geometry.PointF, from: geometry.PointF, to: geometry.PointF) f32 {
    const dx = to.x - from.x;
    const dy = to.y - from.y;
    const length_sq = dx * dx + dy * dy;
    if (length_sq <= 0.000001) {
        const px = point.x - from.x;
        const py = point.y - from.y;
        return @sqrt(px * px + py * py);
    }

    const t = std.math.clamp(((point.x - from.x) * dx + (point.y - from.y) * dy) / length_sq, 0, 1);
    const closest = geometry.PointF.init(from.x + dx * t, from.y + dy * t);
    const px = point.x - closest.x;
    const py = point.y - closest.y;
    return @sqrt(px * px + py * py);
}

pub fn referencePathContainsPoint(point: geometry.PointF, elements: []const PathElement, transform: Affine) bool {
    var inside = false;
    var has_current = false;
    var current = geometry.PointF.zero();
    var subpath_start = geometry.PointF.zero();

    for (elements) |element| {
        switch (element.verb) {
            .move_to => {
                current = transform.transformPoint(element.points[0]);
                subpath_start = current;
                has_current = true;
            },
            .line_to => {
                if (!has_current) {
                    current = transform.transformPoint(element.points[0]);
                    subpath_start = current;
                    has_current = true;
                    continue;
                }
                const next = transform.transformPoint(element.points[0]);
                if (referenceSegmentCrossesRay(point, current, next)) inside = !inside;
                current = next;
            },
            .quad_to => {
                if (!has_current) continue;
                const control = transform.transformPoint(element.points[0]);
                const end = transform.transformPoint(element.points[1]);
                var previous = current;
                var index: usize = 1;
                while (index <= reference_curve_segments) : (index += 1) {
                    const t = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(reference_curve_segments));
                    const next = referenceQuadPoint(current, control, end, t);
                    if (referenceSegmentCrossesRay(point, previous, next)) inside = !inside;
                    previous = next;
                }
                current = end;
            },
            .cubic_to => {
                if (!has_current) continue;
                const control_a = transform.transformPoint(element.points[0]);
                const control_b = transform.transformPoint(element.points[1]);
                const end = transform.transformPoint(element.points[2]);
                var previous = current;
                var index: usize = 1;
                while (index <= reference_curve_segments) : (index += 1) {
                    const t = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(reference_curve_segments));
                    const next = referenceCubicPoint(current, control_a, control_b, end, t);
                    if (referenceSegmentCrossesRay(point, previous, next)) inside = !inside;
                    previous = next;
                }
                current = end;
            },
            .close => {
                if (has_current) {
                    if (referenceSegmentCrossesRay(point, current, subpath_start)) inside = !inside;
                    current = subpath_start;
                }
            },
        }
    }

    return inside;
}

pub fn referenceDistanceToPath(point: geometry.PointF, elements: []const PathElement, transform: Affine) ?f32 {
    var has_distance = false;
    var min_distance: f32 = 0;
    var has_current = false;
    var current = geometry.PointF.zero();
    var subpath_start = geometry.PointF.zero();

    for (elements) |element| {
        switch (element.verb) {
            .move_to => {
                current = transform.transformPoint(element.points[0]);
                subpath_start = current;
                has_current = true;
            },
            .line_to => {
                if (!has_current) {
                    current = transform.transformPoint(element.points[0]);
                    subpath_start = current;
                    has_current = true;
                    continue;
                }
                const next = transform.transformPoint(element.points[0]);
                referenceMinDistance(&has_distance, &min_distance, referenceDistanceToSegment(point, current, next));
                current = next;
            },
            .quad_to => {
                if (!has_current) continue;
                const control = transform.transformPoint(element.points[0]);
                const end = transform.transformPoint(element.points[1]);
                var previous = current;
                var index: usize = 1;
                while (index <= reference_curve_segments) : (index += 1) {
                    const t = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(reference_curve_segments));
                    const next = referenceQuadPoint(current, control, end, t);
                    referenceMinDistance(&has_distance, &min_distance, referenceDistanceToSegment(point, previous, next));
                    previous = next;
                }
                current = end;
            },
            .cubic_to => {
                if (!has_current) continue;
                const control_a = transform.transformPoint(element.points[0]);
                const control_b = transform.transformPoint(element.points[1]);
                const end = transform.transformPoint(element.points[2]);
                var previous = current;
                var index: usize = 1;
                while (index <= reference_curve_segments) : (index += 1) {
                    const t = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(reference_curve_segments));
                    const next = referenceCubicPoint(current, control_a, control_b, end, t);
                    referenceMinDistance(&has_distance, &min_distance, referenceDistanceToSegment(point, previous, next));
                    previous = next;
                }
                current = end;
            },
            .close => {
                if (has_current) {
                    referenceMinDistance(&has_distance, &min_distance, referenceDistanceToSegment(point, current, subpath_start));
                    current = subpath_start;
                }
            },
        }
    }

    return if (has_distance) min_distance else null;
}

fn referenceMinDistance(has_distance: *bool, min_distance: *f32, distance: f32) void {
    if (!has_distance.* or distance < min_distance.*) {
        has_distance.* = true;
        min_distance.* = distance;
    }
}

fn referenceSegmentCrossesRay(point: geometry.PointF, a: geometry.PointF, b: geometry.PointF) bool {
    if ((a.y > point.y) == (b.y > point.y)) return false;
    const x = a.x + (point.y - a.y) * (b.x - a.x) / (b.y - a.y);
    return x > point.x;
}

fn referenceQuadPoint(a: geometry.PointF, b: geometry.PointF, c: geometry.PointF, t: f32) geometry.PointF {
    const u = 1 - t;
    return geometry.PointF.init(
        u * u * a.x + 2 * u * t * b.x + t * t * c.x,
        u * u * a.y + 2 * u * t * b.y + t * t * c.y,
    );
}

fn referenceCubicPoint(a: geometry.PointF, b: geometry.PointF, c: geometry.PointF, d: geometry.PointF, t: f32) geometry.PointF {
    const u = 1 - t;
    return geometry.PointF.init(
        u * u * u * a.x + 3 * u * u * t * b.x + 3 * u * t * t * c.x + t * t * t * d.x,
        u * u * u * a.y + 3 * u * u * t * b.y + 3 * u * t * t * c.y + t * t * t * d.y,
    );
}
