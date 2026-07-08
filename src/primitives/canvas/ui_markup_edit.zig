//! Minimal-diff edit operations over parsed markup — the write-back op
//! layer. Tools never splice text themselves: they speak typed operations
//! on a parsed document (set or remove an attribute, change literal text
//! content), and this module turns one operation into new source text
//! where the only bytes that differ sit inside (or insert at) the target
//! node's span. Whitespace, comments, attribute order, and quoting outside
//! the edit survive byte for byte, so diffs stay reviewable and concurrent
//! edits elsewhere in the file never conflict.
//!
//! Operations validate before any caller writes a file: `applyChecked`
//! reparses the edited source, runs the structural validator, and diffs
//! the two parse trees — every node OTHER than the edited one must be
//! structurally identical (kind, name, attributes, text, child shape), and
//! the edited node must reflect exactly the requested operation. A failed
//! check returns a teaching error and the caller writes nothing.
//!
//! Node addressing is span identity: the caller names the target by the
//! byte offset its node starts at in THIS file's current bytes (the
//! within-session identity write-back provenance hands out). A stale
//! offset — the file changed since the span was captured — fails with a
//! specific message instead of editing the wrong node.

const std = @import("std");
const markup = @import("ui_markup.zig");

pub const EditOp = union(enum) {
    /// Set an attribute: replaces the value bytes of an existing valued
    /// attribute, adds `="value"` to a value-less one, or appends
    /// ` name="value"` after the last attribute (or the element name)
    /// when the attribute is absent.
    set_attr: struct { name: []const u8, value: []const u8 },
    /// Remove an attribute and the whitespace run before it.
    remove_attr: struct { name: []const u8 },
    /// Replace the element's literal text content (its single text run).
    /// A childless paired element gains the run; a self-closing element
    /// is rewritten to the paired form — still entirely inside its span.
    set_text: struct { text: []const u8 },
};

pub const ApplyError = error{
    OutOfMemory,
    /// The source did not parse (before the edit) or the target offset
    /// names no node — see the diagnostic for which.
    MarkupSyntax,
    /// The operation cannot be expressed on this node (see diagnostic).
    MarkupEdit,
    /// The edited source failed reparse, validation, or the
    /// structure-preservation diff (see diagnostic); nothing was written.
    MarkupValidation,
};

pub const edit_value_quote_message = "attribute values cannot contain '\"' - the markup grammar has no escape sequence; keep quoted text in model data and bind it";
pub const edit_value_newline_message = "attribute values cannot contain newlines";
pub const edit_attr_name_message = "attribute names are lowercase kebab-case ([a-z0-9-_]) - the edit refuses a name the parser could not read back";
pub const edit_attr_missing_message = "the attribute is not present on the target node - remove-attr edits existing attributes only";
pub const edit_attr_target_message = "this node kind takes no attributes - set-attr and remove-attr target elements and structure tags";
pub const edit_text_children_message = "set-text targets a text-bearing element - this node has element children, so its content is structure, not text";
pub const edit_text_lt_message = "text content cannot contain '<' - it would open an element and change the document's structure";
pub const edit_text_trim_message = "text content is stored trimmed - leading or trailing whitespace would not survive a reparse, so the edit refuses it";
pub const edit_text_empty_message = "set-text takes non-empty text - removing a text run is a structural edit outside this op set";
pub const edit_span_stale_message = "no markup node starts at the target byte offset - the file changed since provenance was captured; re-query provenance and retry";
pub const edit_reparse_message = "the edited source no longer parses - the operation is refused and nothing was written";
pub const edit_structure_message = "the edit changed nodes outside the target span - the operation is refused and nothing was written";
pub const edit_target_shape_message = "the edited node does not reflect the requested operation after reparse - the operation is refused and nothing was written";

/// Apply one operation and return the full checked pipeline's result: new
/// source bytes whose only differences from `source` sit inside the target
/// node's span. `span_start` is the byte offset the target node starts at
/// (its `span.start` in a parse of these exact bytes). On any error,
/// `diagnostic` carries the teaching message (and position when the
/// underlying parser produced one).
pub fn applyChecked(
    arena: std.mem.Allocator,
    source: []const u8,
    span_start: usize,
    op: EditOp,
    diagnostic: *markup.MarkupErrorInfo,
) ApplyError![]const u8 {
    diagnostic.* = .{};
    var parser = markup.Parser.init(arena, source);
    const document = parser.parse() catch |err| {
        if (err == error.MarkupSyntax) diagnostic.* = parser.diagnostic;
        return err;
    };
    const node = findBySpanStart(document, span_start) orelse {
        diagnostic.* = .{ .message = edit_span_stale_message };
        return error.MarkupSyntax;
    };
    const edited = apply(arena, source, node, op, diagnostic) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.MarkupEdit => return error.MarkupEdit,
    };
    var reparse = markup.Parser.init(arena, edited);
    const new_document = reparse.parse() catch |err| {
        if (err == error.MarkupSyntax) {
            diagnostic.* = reparse.diagnostic;
            diagnostic.message = edit_reparse_message;
        }
        return if (err == error.OutOfMemory) error.OutOfMemory else error.MarkupValidation;
    };
    if (markup.validate(new_document)) |info| {
        diagnostic.* = info;
        return error.MarkupValidation;
    }
    if (!documentsMatchExcept(document, new_document, span_start, op, diagnostic)) {
        return error.MarkupValidation;
    }
    return edited;
}

/// The raw span edit: no reparse, no validation — `applyChecked` is the
/// pipeline callers writing files use. Exposed for tests and for callers
/// that batch their own validation.
pub fn apply(
    arena: std.mem.Allocator,
    source: []const u8,
    node: markup.MarkupNode,
    op: EditOp,
    diagnostic: *markup.MarkupErrorInfo,
) error{ OutOfMemory, MarkupEdit }![]const u8 {
    switch (op) {
        .set_attr => |edit| {
            try checkAttrName(node, edit.name, diagnostic);
            try checkAttrValue(node, edit.value, diagnostic);
            if (node.kind == .text) return failEdit(node, edit_attr_target_message, diagnostic);
            if (node.attrEntry(edit.name)) |attribute| {
                if (attrIsValueless(attribute)) {
                    // `flag` -> `flag="value"`: insert at the name's end
                    // (the parser's documented insertion point).
                    const inserted = try std.fmt.allocPrint(arena, "=\"{s}\"", .{edit.value});
                    return replaceRange(arena, source, attribute.name_span.end, attribute.name_span.end, inserted);
                }
                return replaceRange(arena, source, attribute.value_span.start, attribute.value_span.end, edit.value);
            }
            const at = lastOpenTagTokenEnd(node);
            const inserted = try std.fmt.allocPrint(arena, " {s}=\"{s}\"", .{ edit.name, edit.value });
            return replaceRange(arena, source, at, at, inserted);
        },
        .remove_attr => |edit| {
            if (node.kind == .text) return failEdit(node, edit_attr_target_message, diagnostic);
            const attribute = node.attrEntry(edit.name) orelse
                return failEdit(node, edit_attr_missing_message, diagnostic);
            // Delete the whitespace run before the attribute too, back to
            // the previous token (an earlier attribute or the name).
            var from = attribute.name_span.start;
            const floor = previousOpenTagTokenEnd(node, attribute);
            while (from > floor and isSpace(source[from - 1])) from -= 1;
            return replaceRange(arena, source, from, attrEnd(attribute), "");
        },
        .set_text => |edit| {
            try checkText(node, edit.text, diagnostic);
            if (node.kind == .text) {
                return replaceRange(arena, source, node.span.start, node.span.end, edit.text);
            }
            var element_children: usize = 0;
            var text_run: ?markup.MarkupNode = null;
            for (node.children) |child| {
                if (child.kind == .text) text_run = child else element_children += 1;
            }
            if (element_children > 0) return failEdit(node, edit_text_children_message, diagnostic);
            if (text_run) |run| {
                return replaceRange(arena, source, run.span.start, run.span.end, edit.text);
            }
            if (isSelfClosing(source, node)) {
                // `<text/>` -> `<text>new</text>`: rewrite the tail, still
                // entirely inside the node's own span.
                const tail = try std.fmt.allocPrint(arena, ">{s}</{s}>", .{ edit.text, node.name });
                return replaceRange(arena, source, node.span.end - 2, node.span.end, tail);
            }
            // Paired but empty (or whitespace-only) content: replace the
            // whole content region between the tags.
            const open_end = openTagEnd(source, node);
            const close_start = closingTagStart(source, node);
            return replaceRange(arena, source, open_end + 1, close_start, edit.text);
        },
    }
}

/// The node starting at `span_start`, anywhere in the document (root,
/// templates, imports). Span identity is the write-back session contract:
/// provenance hands out a node's span against specific file bytes, and a
/// lookup in a reparse of those SAME bytes finds the same node.
pub fn findBySpanStart(document: markup.MarkupDocument, span_start: usize) ?markup.MarkupNode {
    for (document.imports) |node| {
        if (findInNode(node, span_start)) |found| return found;
    }
    for (document.templates) |node| {
        if (findInNode(node, span_start)) |found| return found;
    }
    if (document.root) |root| {
        if (findInNode(root, span_start)) |found| return found;
    }
    return null;
}

fn findInNode(node: markup.MarkupNode, span_start: usize) ?markup.MarkupNode {
    if (node.span.start == span_start) return node;
    if (span_start < node.span.start or span_start >= node.span.end) return null;
    for (node.children) |child| {
        if (findInNode(child, span_start)) |found| return found;
    }
    return null;
}

// ----------------------------------------------------------- span helpers

/// A value-less attribute's value span is the empty range at the name's
/// end; any valued attribute (even `x=""`) has at least `="` between.
fn attrIsValueless(attribute: markup.MarkupAttr) bool {
    return attribute.value_span.start == attribute.name_span.end;
}

/// One past the attribute's last byte: the closing quote for valued
/// attributes, the name itself for value-less ones.
fn attrEnd(attribute: markup.MarkupAttr) usize {
    if (attrIsValueless(attribute)) return attribute.name_span.end;
    return attribute.value_span.end + 1;
}

/// End of the token before `attribute` in the open tag: the previous
/// attribute's end, or the element name's end for the first one.
fn previousOpenTagTokenEnd(node: markup.MarkupNode, attribute: markup.MarkupAttr) usize {
    var end = node.span.start + 1 + node.name.len;
    for (node.attrs) |candidate| {
        if (candidate.name_span.start == attribute.name_span.start) break;
        end = attrEnd(candidate);
    }
    return end;
}

/// End of the last token in the open tag (last attribute, or the name):
/// where an appended attribute inserts, keeping ` />` spacing intact.
fn lastOpenTagTokenEnd(node: markup.MarkupNode) usize {
    var end = node.span.start + 1 + node.name.len;
    for (node.attrs) |attribute| end = attrEnd(attribute);
    return end;
}

/// The parser emits self-closing tags as exactly `/>` (whitespace before
/// the slash is consumed by the attribute loop), so the last two bytes of
/// the span are the witness.
fn isSelfClosing(source: []const u8, node: markup.MarkupNode) bool {
    return node.span.end >= 2 and source[node.span.end - 2] == '/';
}

/// Index of the `>` closing the open tag. Scans from the last open-tag
/// token, so quoted `>` inside attribute values can never mislead it.
fn openTagEnd(source: []const u8, node: markup.MarkupNode) usize {
    var index = lastOpenTagTokenEnd(node);
    while (source[index] != '>') index += 1;
    return index;
}

/// Start of the closing `</name>` tag. The closing tag is the last `</` in
/// the node's span: nested closers end earlier, and text content can never
/// contain `<`.
fn closingTagStart(source: []const u8, node: markup.MarkupNode) usize {
    return std.mem.lastIndexOf(u8, source[0..node.span.end], "</") orelse node.span.end;
}

fn replaceRange(arena: std.mem.Allocator, source: []const u8, from: usize, to: usize, with: []const u8) error{OutOfMemory}![]const u8 {
    const out = try arena.alloc(u8, source.len - (to - from) + with.len);
    @memcpy(out[0..from], source[0..from]);
    @memcpy(out[from .. from + with.len], with);
    @memcpy(out[from + with.len ..], source[to..]);
    return out;
}

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

// ------------------------------------------------------ input validation

fn checkAttrName(node: markup.MarkupNode, name: []const u8, diagnostic: *markup.MarkupErrorInfo) error{MarkupEdit}!void {
    if (name.len == 0) return failEdit(node, edit_attr_name_message, diagnostic);
    for (name) |byte| {
        const valid = (byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or byte == '-' or byte == '_';
        if (!valid) return failEdit(node, edit_attr_name_message, diagnostic);
    }
}

fn checkAttrValue(node: markup.MarkupNode, value: []const u8, diagnostic: *markup.MarkupErrorInfo) error{MarkupEdit}!void {
    if (std.mem.indexOfScalar(u8, value, '"') != null) return failEdit(node, edit_value_quote_message, diagnostic);
    if (std.mem.indexOfScalar(u8, value, '\n') != null) return failEdit(node, edit_value_newline_message, diagnostic);
}

fn checkText(node: markup.MarkupNode, text: []const u8, diagnostic: *markup.MarkupErrorInfo) error{MarkupEdit}!void {
    if (text.len == 0) return failEdit(node, edit_text_empty_message, diagnostic);
    if (std.mem.indexOfScalar(u8, text, '<') != null) return failEdit(node, edit_text_lt_message, diagnostic);
    if (!std.mem.eql(u8, text, std.mem.trim(u8, text, " \t\r\n"))) {
        return failEdit(node, edit_text_trim_message, diagnostic);
    }
}

fn failEdit(node: markup.MarkupNode, message: []const u8, diagnostic: *markup.MarkupErrorInfo) error{MarkupEdit} {
    diagnostic.* = .{ .line = node.line, .column = node.column, .message = message, .path = node.src_path };
    return error.MarkupEdit;
}

// -------------------------------------------- structure-preservation diff

/// Every node outside the edited one must be structurally identical
/// (kind, name, text, attribute names AND values, child shape), and the
/// edited node must reflect exactly the requested operation. Spans are
/// deliberately excluded: bytes after the edit shift by design.
fn documentsMatchExcept(
    before: markup.MarkupDocument,
    after: markup.MarkupDocument,
    edited_start: usize,
    op: EditOp,
    diagnostic: *markup.MarkupErrorInfo,
) bool {
    if (before.imports.len != after.imports.len or
        before.templates.len != after.templates.len or
        (before.root == null) != (after.root == null))
    {
        diagnostic.* = .{ .message = edit_structure_message };
        return false;
    }
    for (before.imports, after.imports) |a, b| {
        if (!nodesMatchExcept(a, b, edited_start, op, diagnostic)) return false;
    }
    for (before.templates, after.templates) |a, b| {
        if (!nodesMatchExcept(a, b, edited_start, op, diagnostic)) return false;
    }
    if (before.root) |a| {
        if (!nodesMatchExcept(a, after.root.?, edited_start, op, diagnostic)) return false;
    }
    return true;
}

fn nodesMatchExcept(a: markup.MarkupNode, b: markup.MarkupNode, edited_start: usize, op: EditOp, diagnostic: *markup.MarkupErrorInfo) bool {
    if (a.span.start == edited_start) return editedNodeMatches(a, b, op, diagnostic);
    if (!nodesEqualShallow(a, b) or a.children.len != b.children.len) {
        diagnostic.* = .{ .line = b.line, .column = b.column, .message = edit_structure_message, .path = b.src_path };
        return false;
    }
    for (a.children, b.children) |ac, bc| {
        if (!nodesMatchExcept(ac, bc, edited_start, op, diagnostic)) return false;
    }
    return true;
}

fn nodesEqualShallow(a: markup.MarkupNode, b: markup.MarkupNode) bool {
    if (a.kind != b.kind or !std.mem.eql(u8, a.name, b.name) or !std.mem.eql(u8, a.text, b.text)) return false;
    if (a.attrs.len != b.attrs.len) return false;
    for (a.attrs, b.attrs) |aa, ba| {
        if (!std.mem.eql(u8, aa.name, ba.name) or !std.mem.eql(u8, aa.value, ba.value)) return false;
    }
    return true;
}

fn editedNodeMatches(a: markup.MarkupNode, b: markup.MarkupNode, op: EditOp, diagnostic: *markup.MarkupErrorInfo) bool {
    const shape_ok = switch (op) {
        .set_attr => |edit| editedSetAttrMatches(a, b, edit.name, edit.value),
        .remove_attr => |edit| editedRemoveAttrMatches(a, b, edit.name),
        .set_text => |edit| editedSetTextMatches(a, b, edit.text),
    };
    if (!shape_ok) {
        diagnostic.* = .{ .line = b.line, .column = b.column, .message = edit_target_shape_message, .path = b.src_path };
        return false;
    }
    return true;
}

fn editedSetAttrMatches(a: markup.MarkupNode, b: markup.MarkupNode, name: []const u8, value: []const u8) bool {
    if (a.kind != b.kind or !std.mem.eql(u8, a.name, b.name)) return false;
    const added = a.attrEntry(name) == null;
    if (b.attrs.len != a.attrs.len + @intFromBool(added)) return false;
    for (a.attrs, 0..) |aa, index| {
        const ba = b.attrs[index];
        if (!std.mem.eql(u8, aa.name, ba.name)) return false;
        const expected = if (std.mem.eql(u8, aa.name, name)) value else aa.value;
        if (!std.mem.eql(u8, expected, ba.value)) return false;
    }
    if (added) {
        const last = b.attrs[b.attrs.len - 1];
        if (!std.mem.eql(u8, last.name, name) or !std.mem.eql(u8, last.value, value)) return false;
    }
    return childrenMatchExactly(a, b);
}

fn editedRemoveAttrMatches(a: markup.MarkupNode, b: markup.MarkupNode, name: []const u8) bool {
    if (a.kind != b.kind or !std.mem.eql(u8, a.name, b.name)) return false;
    if (b.attrs.len + 1 != a.attrs.len) return false;
    var b_index: usize = 0;
    for (a.attrs) |aa| {
        if (std.mem.eql(u8, aa.name, name)) continue;
        const ba = b.attrs[b_index];
        if (!std.mem.eql(u8, aa.name, ba.name) or !std.mem.eql(u8, aa.value, ba.value)) return false;
        b_index += 1;
    }
    return childrenMatchExactly(a, b);
}

fn editedSetTextMatches(a: markup.MarkupNode, b: markup.MarkupNode, text: []const u8) bool {
    if (a.kind != b.kind or !std.mem.eql(u8, a.name, b.name)) return false;
    if (a.attrs.len != b.attrs.len) return false;
    for (a.attrs, b.attrs) |aa, ba| {
        if (!std.mem.eql(u8, aa.name, ba.name) or !std.mem.eql(u8, aa.value, ba.value)) return false;
    }
    if (a.kind == .text) return std.mem.eql(u8, b.text, text) and b.children.len == 0;
    // The element's single text run carries the new text; element children
    // were refused up front, so any children here are text runs.
    if (b.children.len != 1 or b.children[0].kind != .text) return false;
    return std.mem.eql(u8, b.children[0].text, text);
}

fn childrenMatchExactly(a: markup.MarkupNode, b: markup.MarkupNode) bool {
    if (a.children.len != b.children.len or !std.mem.eql(u8, a.text, b.text)) return false;
    for (a.children, b.children) |ac, bc| {
        if (!nodesEqualShallow(ac, bc) or !childrenMatchExactly(ac, bc)) return false;
    }
    return true;
}
