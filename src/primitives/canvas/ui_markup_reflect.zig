//! Comptime reflection helpers over an app's Model/Msg, shared by the
//! runtime interpreter (ui_markup_view.zig), the comptime-compiled engine
//! (ui_markup_compiled.zig), and the model-contract describe step
//! (ui_markup_contract.zig). One definition means the three consumers
//! cannot disagree about WHICH Zig declarations markup can bind: fields,
//! public zero-arg methods, arena-taking scalar methods, and slice/array
//! iterables all resolve through these predicates.
//!
//! std-only on purpose: the contract describe step runs inside a tiny
//! emit program and `native check` parses its output with no canvas
//! dependency in sight.

const std = @import("std");
const expr = @import("ui_markup_expr.zig");

/// Comptime walks over an app's Model and Msg scale with the type's
/// field/decl count, and the default 1000-backwards-branch quota dies at
/// real app sizes — inside toolkit code the app never asked to run,
/// before it uses any markup. Every Model/Msg shaped comptime walk
/// derives its quota from the scanned type instead of relying on the
/// default: generous linear headroom per field/decl (name compares,
/// fn-signature checks, `sliceElement` recursion) plus the item-type
/// dedupe's worst-case quadratic accumulation. Apps never raise the quota
/// for these scans; `ui_markup_huge_model_tests.zig` is the compile-cost
/// guard.
pub fn typeScanQuota(comptime T: type) u32 {
    const entries: u32 = switch (@typeInfo(T)) {
        .@"struct" => |info| @intCast(info.fields.len + info.decls.len),
        .@"union" => |info| @intCast(info.fields.len + info.decls.len),
        .@"enum" => |info| @intCast(info.fields.len + info.decls.len),
        else => 0,
    };
    return 2000 + entries * 64 + entries * entries;
}

/// The element type a `for each` can iterate from this declaration:
/// slices, arrays, and single-item pointers to either.
pub fn sliceElement(comptime T: type) ?type {
    return switch (@typeInfo(T)) {
        .array => |info| info.child,
        .pointer => |info| if (info.size == .slice) info.child else if (info.size == .one) sliceElement(info.child) else null,
        else => null,
    };
}

/// An iterable-producing model fn: `fn (*const Model) []const Item`, or
/// with `with_arena` the build-arena form
/// `fn (*const Model, std.mem.Allocator) []const Item`.
pub fn isItemFn(comptime DeclType: type, comptime Item: type, comptime with_arena: bool) bool {
    const info = switch (@typeInfo(DeclType)) {
        .@"fn" => |fn_info| fn_info,
        else => return false,
    };
    if (info.params.len == 0 or info.params[0].type == null) return false;
    switch (@typeInfo(info.params[0].type.?)) {
        .pointer => {},
        else => return false,
    }
    const expected_params: usize = if (with_arena) 2 else 1;
    if (info.params.len != expected_params) return false;
    const Return = info.return_type orelse return false;
    if (sliceElement(Return) != Item) return false;
    if (with_arena and info.params[1].type != std.mem.Allocator) return false;
    return true;
}

/// An arena-taking scalar binding fn: `fn (self: *const T,
/// arena: std.mem.Allocator) V`. The `for each` arena form returns a slice
/// of items; this form returns one value (typically a formatted
/// `[]const u8` allocated from the arena).
pub fn isArenaScalarFn(comptime T: type, comptime DeclType: type) bool {
    const info = switch (@typeInfo(DeclType)) {
        .@"fn" => |fn_info| fn_info,
        else => return false,
    };
    if (info.params.len != 2 or info.return_type == null) return false;
    if (info.params[0].type != *const T) return false;
    return info.params[1].type == std.mem.Allocator;
}

/// A zero-arg scalar binding fn: `fn (self: *const T) V`.
pub fn isZeroArgFn(comptime T: type, comptime DeclType: type) bool {
    const info = switch (@typeInfo(DeclType)) {
        .@"fn" => |fn_info| fn_info,
        else => return false,
    };
    return info.params.len == 1 and info.return_type != null and info.params[0].type == *const T;
}

/// Types a binding leaf can produce a `Value` from, mirroring the
/// interpreter's runtime acceptance (`valueOf` returning null is exactly
/// when the interpreter reports an unresolvable binding).
pub fn supportedScalar(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .bool, .int, .float, .comptime_int, .@"enum" => true,
        .pointer => |info| info.size == .slice and info.child == u8,
        .optional => |info| supportedScalar(info.child),
        else => false,
    };
}

/// The `Value` kind a leaf type produces, or null for optionals (none
/// resolves to boolean, some to the child's kind — only known at
/// runtime). Mirrors the compiled engine's `bindingVariant`.
pub fn scalarKindOf(comptime T: type) ?expr.ValueKind {
    return switch (@typeInfo(T)) {
        .bool => .boolean,
        .int, .comptime_int => .integer,
        .float => .float,
        .@"enum" => .string,
        .pointer => .string,
        .optional => null,
        else => null,
    };
}

/// A markup literal's value: `true`/`false`, then integer, then float,
/// then plain text — the one classification the interpreter, the compiled
/// engine, and the contract checker all apply to attribute literals and
/// template-arg defaults.
pub fn literalValue(text: []const u8) expr.Value {
    if (std.mem.eql(u8, text, "true")) return .{ .boolean = true };
    if (std.mem.eql(u8, text, "false")) return .{ .boolean = false };
    if (std.fmt.parseInt(i64, text, 10)) |int| return .{ .integer = int } else |_| {}
    if (std.fmt.parseFloat(f32, text)) |float| return .{ .float = float } else |_| {}
    return .{ .string = text };
}
