//! Widget provenance: the back-edge from a live widget's structural id to
//! the markup that authored it — (source file, node byte span, template
//! instantiation chain, iteration keys). This is write-back's read half:
//! automation reports where a widget came from, and the edit verbs target
//! exactly those bytes.
//!
//! Capture happens at view build time and costs nothing when off: the
//! markup engines stamp a `NodeSource` onto each built `Ui.Node` only when
//! the builder carries a sink, and `finalize` — the one choke point where
//! every node's structural id is assigned — feeds the sink one record per
//! markup-authored widget. Builder-authored (Zig) widgets carry no source
//! by design: their absence from the table IS the honest "authored in
//! Zig" answer (source-location capture for Zig call sites is deliberately
//! out of scope for now).

const std = @import("std");
const markup = @import("ui_markup.zig");

/// One `<use>` site in a template instantiation chain: where the
/// expansion was requested, in the file that requested it.
pub const UseSite = struct {
    /// Source file, relative to the markup root; empty for a single-file
    /// document's root file.
    src_path: []const u8 = "",
    span: markup.Span = .{},
    line: usize = 0,
    column: usize = 0,
};

/// Where a built node was authored. For a widget inside a template
/// instantiation, `src_path`/`span` name the DEFINITION site (the element
/// in the template body) and `chain` names every `<use>` that put it
/// there, outermost first — both halves of "jump to its markup".
pub const NodeSource = struct {
    src_path: []const u8 = "",
    span: markup.Span = .{},
    line: usize = 0,
    column: usize = 0,
    chain: []const UseSite = &.{},
};

/// An identity key on the trail from the root to a widget, mirroring
/// `canvas.UiKey` without importing it (this module stays std-only below
/// the builder). String keys point into the build arena; sinks copy.
pub const Key = union(enum) {
    index: usize,
    int: u64,
    str: []const u8,
};

/// Explicit-key trail cap. Deeper explicit nesting keeps its identity
/// (ids are unaffected); only the reported trail truncates, and the
/// record says so.
pub const max_key_trail = 8;

/// The explicit keys between the root and the node being finalized —
/// `for` iteration keys and author `key=`/`global-key=` identity, in
/// root-to-leaf order. Auto index keys are omitted: they carry position,
/// not identity.
pub const KeyTrail = struct {
    keys: [max_key_trail]Key = undefined,
    len: usize = 0,
    truncated: bool = false,

    pub fn push(self: *KeyTrail, key: Key) bool {
        if (self.len >= self.keys.len) {
            self.truncated = true;
            return false;
        }
        self.keys[self.len] = key;
        self.len += 1;
        return true;
    }

    pub fn pop(self: *KeyTrail) void {
        self.len -= 1;
    }

    pub fn items(self: *const KeyTrail) []const Key {
        return self.keys[0..self.len];
    }
};

/// Type-erased collector `finalize` feeds: one call per finalized node
/// that carries a `NodeSource`, with the structural id just assigned and
/// the key trail down to the node (the node's own explicit key included).
/// The callee copies everything it keeps — every slice lives in the
/// build arena and dies with the frame.
pub const Sink = struct {
    context: *anyopaque,
    record_fn: *const fn (context: *anyopaque, id: u64, source: *const NodeSource, keys: []const Key, keys_truncated: bool) void,

    pub fn record(self: Sink, id: u64, source: *const NodeSource, keys: []const Key, keys_truncated: bool) void {
        self.record_fn(self.context, id, source, keys, keys_truncated);
    }
};
