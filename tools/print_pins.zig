//! Print every registry pin in paste-ready form: the table counts and
//! (code, name) fingerprints that ui_schema_tests.zig holds stable, plus
//! the derived-list counts it mirrors. Run `zig build print-pins` after
//! adding registry entries and copy the values straight into the test —
//! one command instead of a run → fail → decimal-to-hex → re-run cycle.
//!
//! Printing a value here does not bless it: the stability test's comments
//! own the law (renames/renumbers are schema-version-bump events, never
//! silent re-pins). This tool only removes the transcription step.

const std = @import("std");
const schema = @import("ui_schema");

pub fn main(init: std.process.Init) !void {
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const out = &writer.interface;
    try out.print("ui_schema registry pins (schema_version {d})\n\n", .{schema.schema_version});
    try out.print("  elements.len  {d}\n", .{schema.elements.len});
    try out.print("  attrs.len     {d}\n", .{schema.attrs.len});
    try out.print("  events.len    {d}\n\n", .{schema.events.len});
    try out.print("  element fingerprint  0x{x:0>16}\n", .{schema.tableFingerprint(schema.ElementInfo, &schema.elements)});
    try out.print("  attr fingerprint     0x{x:0>16}\n", .{schema.tableFingerprint(schema.AttrInfo, &schema.attrs)});
    try out.print("  event fingerprint    0x{x:0>16}\n\n", .{schema.tableFingerprint(schema.EventInfo, &schema.events)});
    try out.print("  element_names.len (plain elements)  {d}\n\n", .{schema.element_names.len});
    try out.print("  next free codes: element {d}, attr {d}, event {d}\n", .{
        nextFreeCode(schema.ElementInfo, &schema.elements),
        nextFreeCode(schema.AttrInfo, &schema.attrs),
        nextFreeCode(schema.EventInfo, &schema.events),
    });
    try out.flush();
}

/// One past the highest assigned code: the code a new entry takes at
/// birth. Parallel work waves should each be handed a reserved code from
/// this sequence up front so same-day additions can never collide.
fn nextFreeCode(comptime Entry: type, entries: []const Entry) u16 {
    var highest: u16 = 0;
    for (entries) |entry| highest = @max(highest, entry.code);
    return highest + 1;
}
