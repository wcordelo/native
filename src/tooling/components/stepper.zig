//! Your app's stepper.
//! Ejected from the Native SDK component library.
//!
//! This file now belongs to your app: edit it freely, and SDK updates
//! never touch it. It builds the same widget tree `ui.stepper` produced
//! at the moment it was ejected, so migrating a call site is a rename:
//!
//!     const stepper = @import("components/stepper.zig");
//!
//!     // before: ui.stepper(.{ .active = model.stage }, &steps)
//!     // after:  stepper.build(&ui, .{ .active = model.stage }, &steps)
//!
//! The library form stays available — call sites you have not migrated
//! keep rendering the stock stepper, and deleting this file costs
//! nothing (`native eject component stepper` writes it again).
//!
//! The composition, in one glance: a horizontal row of steps whose
//! completed/active/pending states derive from `Options.active`.
//! Indicators are badges — a vector check icon for completed steps, the
//! step number otherwise — and hairline separators connect the steps.
//! Display-only: driving `active` belongs to the app model.

const std = @import("std");
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;

/// Visual state of a step, derived from its index against
/// `Options.active`.
pub const StepState = enum { completed, active, pending };

pub const Step = struct {
    /// Step label ("Work", "Review · round 2").
    label: []const u8,
};

pub const Options = struct {
    /// Index of the active step: earlier steps render completed (check
    /// indicator), later ones pending. An index past the last step
    /// renders every step completed.
    active: usize = 0,
    key: ?canvas.UiKey = null,
    global_key: ?canvas.UiKey = null,
    grow: f32 = 0,
    /// Row semantics; role defaults to `list` (each step is a `listitem`
    /// carrying its label, state, and position).
    semantics: canvas.WidgetSemantics = .{},
};

pub fn stepState(active: usize, index: usize) StepState {
    if (index < active) return .completed;
    if (index == active) return .active;
    return .pending;
}

/// Build the stepper into the app's view. `ui` is the app's typed view
/// builder (`*canvas.Ui(Msg)`); taking it generically keeps this file
/// independent of your app's message type.
pub fn build(ui: anytype, options: Options, steps: []const Step) @TypeOf(ui.*).Node {
    var semantics = options.semantics;
    if (semantics.role == .none) semantics.role = .list;
    const node_count = if (steps.len == 0) 0 else steps.len * 2 - 1;
    const nodes = ui.arena.alloc(@TypeOf(ui.*).Node, node_count) catch {
        ui.failed = true;
        return ui.el(.row, .{ .semantics = semantics }, .{});
    };
    for (steps, 0..) |step, index| {
        nodes[index * 2] = stepNode(ui, options.active, index, steps.len, step);
        if (index + 1 < steps.len) {
            // The connector between steps: a bare separator inside a row
            // renders as a hairline across the space it grows into.
            nodes[index * 2 + 1] = ui.el(.separator, .{ .grow = 1 }, .{});
        }
    }
    return ui.el(.row, .{
        .key = options.key,
        .global_key = options.global_key,
        .gap = 8,
        .cross = .center,
        .grow = options.grow,
        .semantics = semantics,
    }, .{nodes});
}

fn stepNode(ui: anytype, active: usize, index: usize, count: usize, step: Step) @TypeOf(ui.*).Node {
    const state = stepState(active, index);
    // Completed steps wear the vector `check` icon — a check text glyph
    // is outside the bundled font's coverage and would render as a tofu
    // box on the reference/screenshot paths.
    const indicator = ui.el(.badge, .{
        .variant = if (state == .pending) canvas.WidgetVariant.outline else .primary,
        .icon = if (state == .completed) "check" else "",
        .text = if (state == .completed) "" else ui.fmt("{d}", .{index + 1}),
    }, .{});
    const label = switch (state) {
        // The active step reads bold; a single bold span is the wrapped
        // text machinery, so the emphasis costs no second text pipeline.
        .active => ui.paragraph(.{}, &.{.{ .text = step.label, .weight = .bold }}),
        .completed => ui.text(.{}, step.label),
        .pending => ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, step.label),
    };
    return ui.el(.row, .{
        .key = .{ .int = @intCast(index) },
        .gap = 6,
        .cross = .center,
        .selected = state == .active,
        .semantics = .{
            .role = .listitem,
            .label = ui.fmt("{s} ({s})", .{ step.label, @tagName(state) }),
            .list_item_index = @intCast(index),
            .list_item_count = @intCast(count),
        },
    }, .{ indicator, label });
}
