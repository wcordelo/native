//! Provenance capture through the interpreter engine: the markup view
//! stamps each built node's authored source, and `finalize` pairs it with
//! the structural id it assigns — one record per markup-authored widget,
//! template definition site plus use-site chain, iteration keys included.

const std = @import("std");
const canvas = @import("root.zig");
const markup = @import("ui_markup.zig");
const ui_provenance = @import("ui_provenance.zig");

const Task = struct { id: u32, title: []const u8 };
const Model = struct {
    tasks: []const Task = &.{},
};
const Msg = union(enum) { noop };
const Ui = canvas.Ui(Msg);
const View = canvas.MarkupView(Model, Msg);

const board_source =
    "<import src=\"components/pill.native\"/>\n" ++
    "<column gap=\"8\">\n" ++
    "  <text>Board</text>\n" ++
    "  <for each=\"tasks\" as=\"task\" key=\"id\">\n" ++
    "    <use template=\"pill\" label=\"{task.title}\"/>\n" ++
    "  </for>\n" ++
    "</column>\n";

const pill_source =
    "<template name=\"pill\" args=\"label\">\n" ++
    "  <badge>{label}</badge>\n" ++
    "</template>\n";

const CapturedRecord = struct {
    id: u64,
    src_path: []const u8,
    span: markup.Span,
    line: usize,
    chain_len: usize,
    chain_first_path: []const u8 = "",
    chain_first_span: markup.Span = .{},
    key_count: usize,
    first_key_int: ?u64 = null,
};

const Capture = struct {
    arena: std.mem.Allocator,
    records: std.ArrayListUnmanaged(CapturedRecord) = .empty,

    fn sink(self: *Capture) ui_provenance.Sink {
        return .{ .context = @ptrCast(self), .record_fn = record };
    }

    fn record(context: *anyopaque, id: u64, source: *const ui_provenance.NodeSource, keys: []const ui_provenance.Key, keys_truncated: bool) void {
        _ = keys_truncated;
        const self: *Capture = @ptrCast(@alignCast(context));
        var captured = CapturedRecord{
            .id = id,
            .src_path = self.arena.dupe(u8, source.src_path) catch return,
            .span = source.span,
            .line = source.line,
            .chain_len = source.chain.len,
            .key_count = keys.len,
        };
        if (source.chain.len > 0) {
            captured.chain_first_path = self.arena.dupe(u8, source.chain[0].src_path) catch return;
            captured.chain_first_span = source.chain[0].span;
        }
        if (keys.len > 0 and keys[0] == .int) captured.first_key_int = keys[0].int;
        self.records.append(self.arena, captured) catch {};
    }
};

fn resolvedDocument(arena: std.mem.Allocator) !markup.MarkupDocument {
    const sources = [_]markup.SourceFile{
        .{ .path = "board.native", .source = board_source },
        .{ .path = "components/pill.native", .source = pill_source },
    };
    var set_loader = markup.SourceSetLoader{ .set = &sources };
    var diagnostic: markup.MarkupErrorInfo = .{};
    const document = try markup.resolveImports(arena, "board.native", board_source, set_loader.loader(), &diagnostic);
    return try markup.canonicalize(arena, document);
}

fn widgetIds(widget: canvas.Widget, out: *std.ArrayListUnmanaged(u64), arena: std.mem.Allocator) !void {
    try out.append(arena, widget.id);
    for (widget.children) |child| try widgetIds(child, out, arena);
}

test "interpreter stamps provenance: definition site, use-site chain, iteration keys" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tasks = [_]Task{ .{ .id = 1, .title = "one" }, .{ .id = 2, .title = "two" } };
    const model = Model{ .tasks = &tasks };

    var view = View.fromDocument(try resolvedDocument(arena));
    var capture = Capture{ .arena = arena };
    var ui = Ui.init(arena);
    ui.provenance_sink = capture.sink();
    const node = try view.build(&ui, &model);
    const tree = try ui.finalize(node);

    // Every markup widget got a record: column + text + 2 badges.
    try std.testing.expectEqual(@as(usize, 4), capture.records.items.len);

    // Records key by ids that exist in the finalized tree.
    var ids: std.ArrayListUnmanaged(u64) = .empty;
    try widgetIds(tree.root, &ids, arena);
    for (capture.records.items) |record| {
        try std.testing.expect(std.mem.indexOfScalar(u64, ids.items, record.id) != null);
    }

    // The root column: authored in the root file, no template chain, and
    // its span starts at the `<column` byte of the root source. Finalize
    // records parents before children, so it is the first record.
    const column_record = capture.records.items[0];
    try std.testing.expectEqualStrings("board.native", column_record.src_path);
    try std.testing.expectEqual(std.mem.indexOf(u8, board_source, "<column").?, column_record.span.start);
    try std.testing.expectEqual(@as(usize, 0), column_record.chain_len);
    try std.testing.expectEqual(@as(usize, 0), column_record.key_count);

    // The badges: definition site in the COMPONENT file, one use site in
    // the root file (the <use> element's span), and the loop's item key.
    var badge_count: usize = 0;
    for (capture.records.items) |record| {
        if (!std.mem.eql(u8, record.src_path, "components/pill.native")) continue;
        badge_count += 1;
        try std.testing.expectEqual(std.mem.indexOf(u8, pill_source, "<badge").?, record.span.start);
        try std.testing.expectEqual(@as(usize, 2), record.line);
        try std.testing.expectEqual(@as(usize, 1), record.chain_len);
        try std.testing.expectEqualStrings("board.native", record.chain_first_path);
        try std.testing.expectEqual(std.mem.indexOf(u8, board_source, "<use").?, record.chain_first_span.start);
        try std.testing.expectEqual(@as(usize, 1), record.key_count);
        try std.testing.expectEqual(record.first_key_int.?, badge_count);
    }
    try std.testing.expectEqual(@as(usize, 2), badge_count);
}

test "provenance capture changes no structural ids and costs nothing when off" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tasks = [_]Task{.{ .id = 7, .title = "only" }};
    const model = Model{ .tasks = &tasks };
    const document = try resolvedDocument(arena);

    var plain_view = View.fromDocument(document);
    var plain_ui = Ui.init(arena);
    const plain_tree = try plain_ui.finalize(try plain_view.build(&plain_ui, &model));

    var capture = Capture{ .arena = arena };
    var sink_view = View.fromDocument(document);
    var sink_ui = Ui.init(arena);
    sink_ui.provenance_sink = capture.sink();
    const sink_node = try sink_view.build(&sink_ui, &model);
    try std.testing.expect(sink_node.source != null);
    const sink_tree = try sink_ui.finalize(sink_node);

    var plain_ids: std.ArrayListUnmanaged(u64) = .empty;
    var sink_ids: std.ArrayListUnmanaged(u64) = .empty;
    try widgetIds(plain_tree.root, &plain_ids, arena);
    try widgetIds(sink_tree.root, &sink_ids, arena);
    try std.testing.expectEqualSlices(u64, plain_ids.items, sink_ids.items);

    // Without a sink the engine stamps nothing (the null branch is the
    // whole cost for non-automation runs).
    var probe_view = View.fromDocument(document);
    var probe_ui = Ui.init(arena);
    const probe_node = try probe_view.build(&probe_ui, &model);
    try std.testing.expect(probe_node.source == null);
}

test "zig-authored nodes carry no provenance" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var capture = Capture{ .arena = arena };
    var ui = Ui.init(arena);
    ui.provenance_sink = capture.sink();
    const node = ui.el(.column, .{}, .{ui.el(.text, .{ .text = "hand built" }, .{})});
    _ = try ui.finalize(node);
    try std.testing.expectEqual(@as(usize, 0), capture.records.items.len);
}
