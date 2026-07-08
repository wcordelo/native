//! Widget-identity proofs for the ejectable components.
//!
//! `native eject component <name>` copies the canonical sources next to
//! this file into an app. These tests are what keeps those copies
//! honest: each builds the ejected form and the library form against
//! the same inputs and requires the two widget trees to be IDENTICAL —
//! every id, every field, every handler — so ejecting is never a visual
//! or behavioral change, only an ownership change. A library refactor
//! that drifts a composite's tree fails here until the canonical source
//! is updated to match.
//!
//! This file is its own test module (wired in build.zig as
//! `test-eject-components`, part of `zig build test`) because the
//! canonical Zig sources import `native_sdk` exactly as they will
//! inside an app — compiling them verbatim is half the proof.

const std = @import("std");
const testing = std.testing;
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;

const stepper_component = @import("stepper.zig");
const timeline_item_component = @import("timeline_item.zig");
const timeline_template = @embedFile("timeline.native");

/// A stand-in app model/message pair: the composites under test bind no
/// model state themselves (their inputs arrive as options/args), so an
/// empty model and one payload-carrying message tag cover the surface.
const Model = struct {};
const Msg = union(enum) { open: u32 };
const Ui = canvas.Ui(Msg);

test "ejected stepper builds the library stepper's exact tree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const labels = [_][]const u8{ "Plan", "Work", "Ship" };
    // Every derived step state in one sweep: active in range (mixed
    // completed/active/pending), zero (nothing completed), and past the
    // end (everything completed).
    for ([_]usize{ 1, 0, labels.len }) |active| {
        var library_ui = Ui.init(arena);
        const library_steps = [_]Ui.StepperStep{
            .{ .label = labels[0] }, .{ .label = labels[1] }, .{ .label = labels[2] },
        };
        const library_tree = try library_ui.finalize(library_ui.stepper(.{ .active = active }, &library_steps));

        var ejected_ui = Ui.init(arena);
        const ejected_steps = [_]stepper_component.Step{
            .{ .label = labels[0] }, .{ .label = labels[1] }, .{ .label = labels[2] },
        };
        const ejected_tree = try ejected_ui.finalize(stepper_component.build(&ejected_ui, .{ .active = active }, &ejected_steps));

        try testing.expectEqualDeep(library_tree.root, ejected_tree.root);
        try testing.expectEqualDeep(library_tree.handlers, ejected_tree.handlers);
    }
}

test "ejected timeline item builds the library item's exact tree, press handler included" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const TimelineItem = timeline_item_component.TimelineItem(Msg);

    // The full shape: indicator variant, description, meta, connector,
    // selection, and a whole-item press (which grows the chevron and
    // binds the handler on the item root).
    var library_ui = Ui.init(arena);
    const library_tree = try library_ui.finalize(library_ui.timelineItem(.{
        .key = .{ .int = 7 },
        .icon = "check",
        .variant = .primary,
        .title = "Build the release",
        .description = "Compile, test, and package the app",
        .meta = "2m 14s",
        .selected = true,
        .on_press = .{ .open = 7 },
    }));

    var ejected_ui = Ui.init(arena);
    const ejected_tree = try ejected_ui.finalize(TimelineItem.build(&ejected_ui, .{
        .key = .{ .int = 7 },
        .icon = "check",
        .variant = .primary,
        .title = "Build the release",
        .description = "Compile, test, and package the app",
        .meta = "2m 14s",
        .selected = true,
        .on_press = .{ .open = 7 },
    }));

    try testing.expectEqualDeep(library_tree.root, ejected_tree.root);
    try testing.expectEqualDeep(library_tree.handlers, ejected_tree.handlers);
    // The press is real in both forms, not just structurally equal.
    try testing.expectEqual(Msg{ .open = 7 }, ejected_tree.msgForPointer(ejected_tree.root.id, .up).?);

    // The minimal shape: dot indicator (no badge content), title only,
    // no connector, no press — the other half of every conditional.
    var minimal_library_ui = Ui.init(arena);
    const minimal_library = try minimal_library_ui.finalize(minimal_library_ui.timelineItem(.{
        .title = "Queued",
        .connector = false,
    }));
    var minimal_ejected_ui = Ui.init(arena);
    const minimal_ejected = try minimal_ejected_ui.finalize(TimelineItem.build(&minimal_ejected_ui, .{
        .title = "Queued",
        .connector = false,
    }));
    try testing.expectEqualDeep(minimal_library.root, minimal_ejected.root);
    try testing.expectEqualDeep(minimal_library.handlers, minimal_ejected.handlers);
}

/// Build a markup view over the test Model through the interpreter,
/// resolving imports from an embedded source set (the same loader shape
/// apps use for their import closures).
fn buildMarkupTree(arena: std.mem.Allocator, ui: *Ui, root_source: []const u8, files: []const canvas.ui_markup.SourceFile) !Ui.Tree {
    var set_loader = canvas.ui_markup.SourceSetLoader{ .set = files };
    var diagnostic: canvas.ui_markup.MarkupErrorInfo = .{};
    const document = canvas.ui_markup.resolveImports(arena, "app.native", root_source, set_loader.loader(), &diagnostic) catch |err| {
        std.debug.print("markup resolve failed: {s} ({s}:{d}:{d})\n", .{ diagnostic.message, diagnostic.path, diagnostic.line, diagnostic.column });
        return err;
    };
    var interpreter = canvas.MarkupView(Model, Msg).fromDocument(try canvas.ui_markup.canonicalize(arena, document));
    var model = Model{};
    return ui.finalize(try interpreter.build(ui, &model));
}

test "the ejected timeline template builds the library <timeline> element's exact tree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Identical item children on both sides; only the container differs:
    // the built-in element versus the ejected template reached through
    // <use> (which inlines its body, so ids hash as if written in place).
    const items =
        \\  <timeline-item title="Cloned" description="Fetched the sources" icon="check" variant="primary" />
        \\  <timeline-item title="Building" meta="just now" connector="false" />
        \\
    ;
    const element_source = "<timeline gap=\"4\" label=\"Activity\">\n" ++ items ++ "</timeline>\n";
    const template_source = "<import src=\"components/timeline.native\"/>\n" ++
        "<use template=\"timeline\" gap=\"4\" label=\"Activity\">\n" ++ items ++ "</use>\n";
    const files = [_]canvas.ui_markup.SourceFile{
        .{ .path = "components/timeline.native", .source = timeline_template },
    };

    var element_ui = Ui.init(arena);
    const element_tree = try buildMarkupTree(arena, &element_ui, element_source, &files);
    var template_ui = Ui.init(arena);
    const template_tree = try buildMarkupTree(arena, &template_ui, template_source, &files);

    try testing.expectEqualDeep(element_tree.root, template_tree.root);
    try testing.expectEqualDeep(element_tree.handlers.len, template_tree.handlers.len);
    // Spot-check the facts the deep compare rests on: the container is
    // the list-role column the library builds, at the declared gap.
    try testing.expectEqual(canvas.WidgetKind.column, template_tree.root.kind);
    try testing.expectEqual(canvas.WidgetRole.list, template_tree.root.semantics.role);
    try testing.expectEqual(@as(f32, 4), template_tree.root.layout.gap);
    try testing.expectEqualStrings("Activity", template_tree.root.semantics.label);
    try testing.expectEqual(@as(usize, 2), template_tree.root.children.len);
}

test "the ejected timeline template's defaults match the library element's defaults" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const items = "<timeline-item title=\"Only\" connector=\"false\" />";
    const element_source = "<timeline>" ++ items ++ "</timeline>";
    const template_source = "<import src=\"components/timeline.native\"/>\n" ++
        "<use template=\"timeline\">" ++ items ++ "</use>";
    const files = [_]canvas.ui_markup.SourceFile{
        .{ .path = "components/timeline.native", .source = timeline_template },
    };

    var element_ui = Ui.init(arena);
    const element_tree = try buildMarkupTree(arena, &element_ui, element_source, &files);
    var template_ui = Ui.init(arena);
    const template_tree = try buildMarkupTree(arena, &template_ui, template_source, &files);

    try testing.expectEqualDeep(element_tree.root, template_tree.root);
}
