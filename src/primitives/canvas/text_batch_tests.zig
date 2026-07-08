//! Batched-measurement seam parity and cache honesty.
//!
//! THE LAW this file pins: a provider that answers the batched advances
//! seam must produce the SAME line breaks (and span runs, and elision
//! points) the unbatched per-prefix seam produces for the same inputs.
//! The mock provider below models the class of providers the contract
//! covers — additive advances with kerning-ish per-cluster variation
//! (every cluster's advance differs by lead byte and byte length, so no
//! two words measure alike), where a slice's width is the sum of its
//! per-cluster advances. For that class the batched accumulation
//! performs bit-identical f32 additions to the prefix re-measure, so
//! break offsets are compared EXACTLY, not approximately.
//!
//! Also pinned here: the advance cache's call accounting (one batched
//! host call per run, cached across repeat layouts), its generation
//! invalidation, the oversize scratch path, the rejection of dishonest
//! advances (NaN), and the retained span wrap cache's hit/miss/
//! invalidation behavior.

const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const text_interaction = @import("text_interaction.zig");
const text_measure_cache = @import("text_measure_cache.zig");
const text_metrics = @import("text_metrics.zig");
const text_spans = @import("text_spans.zig");

const FontId = canvas.FontId;
const TextMeasureProvider = text_metrics.TextMeasureProvider;
const nextTextOffset = text_interaction.nextTextOffset;

// ---------------------------------------------------------------- mock

const MockCounters = struct {
    unit_calls: u64 = 0,
    batch_calls: u64 = 0,
};

var mock_counters: MockCounters = .{};

/// Kerning-ish per-cluster advance: varies with the cluster's lead byte,
/// its byte length, and the font id, so cumulative widths are irregular
/// the way shaped text is — while staying additive (position
/// independent), the property the batched contract is defined over.
fn mockClusterAdvance(font_id: FontId, size: f32, cluster: []const u8) f32 {
    const lead: f32 = @floatFromInt(cluster[0] % 13);
    const len: f32 = @floatFromInt(cluster.len);
    const font: f32 = @floatFromInt(font_id % 5);
    return size * (0.31 + lead * 0.037 + len * 0.041 + font * 0.011);
}

fn mockMeasure(context: ?*anyopaque, font_id: FontId, size: f32, text: []const u8) f32 {
    _ = context;
    mock_counters.unit_calls += 1;
    var width: f32 = 0;
    var index: usize = 0;
    while (index < text.len) {
        const next = nextTextOffset(text, index);
        width += mockClusterAdvance(font_id, size, text[index..next]);
        index = next;
    }
    return width;
}

fn mockMeasureAdvances(context: ?*anyopaque, font_id: FontId, size: f32, text: []const u8, advances: []f32) bool {
    _ = context;
    mock_counters.batch_calls += 1;
    var index: usize = 0;
    while (index < text.len) {
        const next = nextTextOffset(text, index);
        advances[index] = mockClusterAdvance(font_id, size, text[index..next]);
        @memset(advances[index + 1 .. next], 0);
        index = next;
    }
    return true;
}

fn mockMeasureAdvancesDeclined(context: ?*anyopaque, font_id: FontId, size: f32, text: []const u8, advances: []f32) bool {
    _ = context;
    _ = font_id;
    _ = size;
    _ = text;
    _ = advances;
    mock_counters.batch_calls += 1;
    return false;
}

fn mockMeasureAdvancesNan(context: ?*anyopaque, font_id: FontId, size: f32, text: []const u8, advances: []f32) bool {
    _ = context;
    _ = font_id;
    _ = size;
    mock_counters.batch_calls += 1;
    @memset(advances[0..text.len], std.math.nan(f32));
    return true;
}

const unbatched_provider = TextMeasureProvider{ .measure_fn = mockMeasure };
const batched_provider = TextMeasureProvider{ .measure_fn = mockMeasure, .measure_advances_fn = mockMeasureAdvances };
const declined_provider = TextMeasureProvider{ .measure_fn = mockMeasure, .measure_advances_fn = mockMeasureAdvancesDeclined };
const nan_provider = TextMeasureProvider{ .measure_fn = mockMeasure, .measure_advances_fn = mockMeasureAdvancesNan };

// ------------------------------------------------------------- fixtures

/// Break-relevant shapes: plain prose, doubled spaces and tabs, 2/3/4
/// byte UTF-8 clusters, an oversized unbreakable word (cluster wrap),
/// explicit newlines, trailing whitespace, and a stray continuation
/// byte plus a truncated trailing cluster (the fallback-scalar walk).
const parity_texts = [_][]const u8{
    "The quick brown fox jumps over the lazy dog near the river bank today",
    "wrap  doubled  spaces\tand\ttabs mixed with ordinary words in between",
    "multibyte \xc3\xa9\xe4\xb8\xad\xf0\x9f\x99\x82 clusters avec du texte accentu\xc3\xa9 \xf0\x9f\x99\x82\xf0\x9f\x99\x82 end",
    "one veryveryverylongunbreakablewordthatmustclusterwrapacrosslines then more",
    "explicit\nnewlines\nsplit these lines and wrapping still applies afterwards",
    "trailing spaces survive the breaker      ",
    "a",
    "stray \x80 continuation and truncated tail \xe2\x80",
};

const parity_options = [_]canvas.TextLayoutOptions{
    .{ .max_width = 90, .wrap = .word },
    .{ .max_width = 41.5, .wrap = .word },
    .{ .max_width = 90, .wrap = .character },
    .{ .max_width = 150, .wrap = .word, .alignment = .center, .line_height = 19 },
    .{ .max_width = 120, .wrap = .none, .overflow = .ellipsis },
    .{ .max_width = 8, .wrap = .none, .overflow = .ellipsis },
};

fn drawTextFor(text: []const u8, options: canvas.TextLayoutOptions, provider: *const TextMeasureProvider) canvas.DrawText {
    var with_measure = options;
    with_measure.measure = provider;
    return .{
        .font_id = canvas.default_sans_font_id,
        .size = 14,
        .origin = geometry.PointF.init(3, 17),
        .color = canvas.Color.rgb8(0, 0, 0),
        .text = text,
        .text_layout = with_measure,
    };
}

fn expectApproxF32(expected: f32, actual: f32) !void {
    try std.testing.expect(std.math.approxEqAbs(f32, expected, actual, 0.001));
}

// --------------------------------------------------------------- parity

test "batched provider seam breaks lines exactly like the per-prefix seam" {
    for (parity_texts) |text| {
        for (parity_options) |options| {
            var unbatched_lines: [64]canvas.TextLine = undefined;
            var batched_lines: [64]canvas.TextLine = undefined;
            const unbatched = try canvas.layoutTextRun(
                drawTextFor(text, options, &unbatched_provider),
                blk: {
                    var with = options;
                    with.measure = &unbatched_provider;
                    break :blk with;
                },
                &unbatched_lines,
            );
            // Fresh generation per case so no advances cached by an
            // earlier case (same bytes, same mock) mask a fetch bug.
            canvas.bumpTextMeasureGeneration();
            const batched = try canvas.layoutTextRun(
                drawTextFor(text, options, &batched_provider),
                blk: {
                    var with = options;
                    with.measure = &batched_provider;
                    break :blk with;
                },
                &batched_lines,
            );

            try std.testing.expectEqual(unbatched.lines.len, batched.lines.len);
            for (unbatched.lines, batched.lines) |expected, actual| {
                // Break offsets and elision points are THE law: exact.
                try std.testing.expectEqual(expected.text_start, actual.text_start);
                try std.testing.expectEqual(expected.text_len, actual.text_len);
                try std.testing.expectEqual(expected.elided_text_len, actual.elided_text_len);
                // Geometry: identical additions on both seams except the
                // elision trim, which subtracts instead of re-measuring
                // (documented ulp-level drift) — compared tightly.
                try expectApproxF32(expected.ellipsis_advance, actual.ellipsis_advance);
                try expectApproxF32(expected.bounds.x, actual.bounds.x);
                try expectApproxF32(expected.bounds.width, actual.bounds.width);
                try expectApproxF32(expected.baseline, actual.baseline);
            }
        }
    }
}

test "a declined batch and dishonest advances fall back to per-prefix breaks" {
    const fallback_providers = [_]*const TextMeasureProvider{ &declined_provider, &nan_provider };
    for (fallback_providers) |provider| {
        for (parity_texts) |text| {
            const options = canvas.TextLayoutOptions{ .max_width = 90, .wrap = .word };
            var unbatched_lines: [64]canvas.TextLine = undefined;
            var fallback_lines: [64]canvas.TextLine = undefined;
            const unbatched = try canvas.layoutTextRun(drawTextFor(text, options, &unbatched_provider), blk: {
                var with = options;
                with.measure = &unbatched_provider;
                break :blk with;
            }, &unbatched_lines);
            canvas.bumpTextMeasureGeneration();
            const fallback = try canvas.layoutTextRun(drawTextFor(text, options, provider), blk: {
                var with = options;
                with.measure = provider;
                break :blk with;
            }, &fallback_lines);
            try std.testing.expectEqual(unbatched.lines.len, fallback.lines.len);
            for (unbatched.lines, fallback.lines) |expected, actual| {
                try std.testing.expectEqual(expected.text_start, actual.text_start);
                try std.testing.expectEqual(expected.text_len, actual.text_len);
            }
        }
    }
}

test "batched span layout matches the per-prefix span layout run for run" {
    const paragraph = "Chat reply with **bold-ish** span styling, multibyte \xc3\xa9\xe4\xb8\xad\xf0\x9f\x99\x82 text, a veryverylongunbreakabletokenthatwraps, and a mono tail";
    const spans = [_]text_spans.TextSpan{
        .{ .text = paragraph[0..21] },
        .{ .text = paragraph[21..33], .weight = .bold },
        .{ .text = paragraph[33..99], .italic = true },
        .{ .text = paragraph[99..], .monospace = true, .scale = 0.9 },
    };
    const widths = [_]f32{ 60, 110, 240.5 };
    for (widths) |width| {
        const unbatched_options = text_spans.TextSpanLayoutOptions{ .size = 13, .max_width = width, .measure = &unbatched_provider };
        var batched_options = unbatched_options;
        batched_options.measure = &batched_provider;

        var unbatched_runs: [text_spans.max_text_span_runs_per_paragraph]text_spans.TextSpanRun = undefined;
        var batched_runs: [text_spans.max_text_span_runs_per_paragraph]text_spans.TextSpanRun = undefined;
        const unbatched = text_spans.layoutTextSpans(&spans, unbatched_options, &unbatched_runs);
        canvas.bumpTextMeasureGeneration();
        const batched = text_spans.layoutTextSpans(&spans, batched_options, &batched_runs);

        try std.testing.expectEqual(unbatched.runs.len, batched.runs.len);
        try std.testing.expectEqual(unbatched.line_count, batched.line_count);
        try std.testing.expectEqual(unbatched.truncated, batched.truncated);
        for (unbatched.runs, batched.runs) |expected, actual| {
            try std.testing.expectEqual(expected.span_index, actual.span_index);
            try std.testing.expectEqual(expected.line_index, actual.line_index);
            try std.testing.expect(expected.text.ptr == actual.text.ptr);
            try std.testing.expectEqual(expected.text.len, actual.text.len);
            try std.testing.expectEqual(expected.font_id, actual.font_id);
            // Same additions on both seams: exact.
            try std.testing.expectEqual(expected.x, actual.x);
            try std.testing.expectEqual(expected.width, actual.width);
            try std.testing.expectEqual(expected.baseline, actual.baseline);
        }
        try std.testing.expectEqual(unbatched.size.width, batched.size.width);
        try std.testing.expectEqual(unbatched.size.height, batched.size.height);
    }
}

// --------------------------------------------------------- advance cache

test "advance cache pays one batched call per run and caches across layouts" {
    canvas.bumpTextMeasureGeneration();
    mock_counters = .{};
    const text = "steady-state typing re-lays-out this unchanged wrapped run every rebuild";
    const options = canvas.TextLayoutOptions{ .max_width = 100, .wrap = .word };
    var lines: [64]canvas.TextLine = undefined;

    _ = try canvas.layoutTextRun(drawTextFor(text, options, &batched_provider), blk: {
        var with = options;
        with.measure = &batched_provider;
        break :blk with;
    }, &lines);
    try std.testing.expectEqual(@as(u64, 1), mock_counters.batch_calls);
    // No per-prefix measurement happened at all on the batched seam.
    try std.testing.expectEqual(@as(u64, 0), mock_counters.unit_calls);

    _ = try canvas.layoutTextRun(drawTextFor(text, options, &batched_provider), blk: {
        var with = options;
        with.measure = &batched_provider;
        break :blk with;
    }, &lines);
    try std.testing.expectEqual(@as(u64, 1), mock_counters.batch_calls);

    // Font registration / theme flip / new runtime: the generation bump
    // must force a fresh host fetch.
    canvas.bumpTextMeasureGeneration();
    _ = try canvas.layoutTextRun(drawTextFor(text, options, &batched_provider), blk: {
        var with = options;
        with.measure = &batched_provider;
        break :blk with;
    }, &lines);
    try std.testing.expectEqual(@as(u64, 2), mock_counters.batch_calls);
}

test "advance cache serves oversize runs through the uncached scratch slot" {
    canvas.bumpTextMeasureGeneration();
    mock_counters = .{};
    var storage: [text_measure_cache.max_cached_advance_run_bytes + 512]u8 = undefined;
    for (&storage, 0..) |*byte, index| byte.* = if (index % 12 == 11) ' ' else 'a' + @as(u8, @intCast(index % 20));
    const options = canvas.TextLayoutOptions{ .max_width = 300, .wrap = .word };
    var lines: [512]canvas.TextLine = undefined;

    _ = try canvas.layoutTextRun(drawTextFor(&storage, options, &batched_provider), blk: {
        var with = options;
        with.measure = &batched_provider;
        break :blk with;
    }, &lines);
    // The run exceeds a cache slot but fits the oversize scratch: still
    // exactly one batched call for the whole layout (line breaker plus
    // per-line bounds all ride the memoized slot).
    try std.testing.expectEqual(@as(u64, 1), mock_counters.batch_calls);
    try std.testing.expectEqual(@as(u64, 0), mock_counters.unit_calls);
}

test "runs past the scratch bound fall back to the per-prefix seam" {
    canvas.bumpTextMeasureGeneration();
    mock_counters = .{};
    var storage: [text_measure_cache.max_batched_advance_run_bytes + 8]u8 = undefined;
    @memset(&storage, 'x');
    const provider = &batched_provider;
    try std.testing.expect(text_measure_cache.textRunAdvances(provider, 1, 14, &storage) == null);
    try std.testing.expectEqual(@as(u64, 0), mock_counters.batch_calls);
}

// ------------------------------------------------------- span wrap cache

test "span wrap cache skips measurement entirely for unchanged paragraphs" {
    canvas.bumpTextMeasureGeneration();
    mock_counters = .{};
    const paragraph = "cached paragraph body that wraps across a few lines at this width";
    const spans = [_]text_spans.TextSpan{.{ .text = paragraph }};
    const options = text_spans.TextSpanLayoutOptions{ .size = 13, .max_width = 90, .measure = &batched_provider };
    var runs: [text_spans.max_text_span_runs_per_paragraph]text_spans.TextSpanRun = undefined;

    const first = text_spans.layoutTextSpans(&spans, options, &runs);
    const calls_after_first = mock_counters.batch_calls + mock_counters.unit_calls;
    try std.testing.expect(calls_after_first > 0);
    try std.testing.expect(first.runs.len > 1);

    var second_runs: [text_spans.max_text_span_runs_per_paragraph]text_spans.TextSpanRun = undefined;
    const second = text_spans.layoutTextSpans(&spans, options, &second_runs);
    // Steady state: not one provider call of ANY kind — the wrap result
    // itself was retained.
    try std.testing.expectEqual(calls_after_first, mock_counters.batch_calls + mock_counters.unit_calls);
    try std.testing.expectEqual(first.runs.len, second.runs.len);
    try std.testing.expectEqual(first.line_count, second.line_count);
    for (first.runs, second.runs) |expected, actual| {
        try std.testing.expectEqual(expected.span_index, actual.span_index);
        try std.testing.expectEqual(expected.line_index, actual.line_index);
        try std.testing.expect(expected.text.ptr == actual.text.ptr);
        try std.testing.expectEqual(expected.text.len, actual.text.len);
        try std.testing.expectEqual(expected.x, actual.x);
        try std.testing.expectEqual(expected.width, actual.width);
        try std.testing.expectEqual(expected.baseline, actual.baseline);
        try std.testing.expectEqual(expected.size, actual.size);
        try std.testing.expectEqual(expected.font_id, actual.font_id);
    }
}

test "span wrap cache misses on content, width, and generation changes" {
    canvas.bumpTextMeasureGeneration();
    const paragraph = "invalidation probe paragraph with enough words to wrap";
    const changed = "invalidation probe paragraph with enough words to warp";
    const spans = [_]text_spans.TextSpan{.{ .text = paragraph }};
    const changed_spans = [_]text_spans.TextSpan{.{ .text = changed }};
    var options = text_spans.TextSpanLayoutOptions{ .size = 13, .max_width = 90, .measure = &batched_provider };
    var runs: [text_spans.max_text_span_runs_per_paragraph]text_spans.TextSpanRun = undefined;

    _ = text_spans.layoutTextSpans(&spans, options, &runs);
    const misses_after_first = canvas.textSpanWrapCacheMissCount();

    // Same bytes, same width: hit.
    _ = text_spans.layoutTextSpans(&spans, options, &runs);
    try std.testing.expectEqual(misses_after_first, canvas.textSpanWrapCacheMissCount());

    // One byte differs: miss.
    _ = text_spans.layoutTextSpans(&changed_spans, options, &runs);
    try std.testing.expectEqual(misses_after_first + 1, canvas.textSpanWrapCacheMissCount());

    // Same bytes, different wrap width: miss.
    options.max_width = 91;
    _ = text_spans.layoutTextSpans(&spans, options, &runs);
    try std.testing.expectEqual(misses_after_first + 2, canvas.textSpanWrapCacheMissCount());
    options.max_width = 90;

    // Font registration / theme flip: the generation bump must miss.
    canvas.bumpTextMeasureGeneration();
    _ = text_spans.layoutTextSpans(&spans, options, &runs);
    try std.testing.expectEqual(misses_after_first + 3, canvas.textSpanWrapCacheMissCount());
}

test "span wrap cache never engages on the estimator path" {
    const spans = [_]text_spans.TextSpan{.{ .text = "estimator paragraphs stay byte-identical to the pre-cache breaker" }};
    const options = text_spans.TextSpanLayoutOptions{ .size = 13, .max_width = 90 };
    var runs: [text_spans.max_text_span_runs_per_paragraph]text_spans.TextSpanRun = undefined;
    const hits = canvas.textSpanWrapCacheHitCount();
    const misses = canvas.textSpanWrapCacheMissCount();
    _ = text_spans.layoutTextSpans(&spans, options, &runs);
    _ = text_spans.layoutTextSpans(&spans, options, &runs);
    try std.testing.expectEqual(hits, canvas.textSpanWrapCacheHitCount());
    try std.testing.expectEqual(misses, canvas.textSpanWrapCacheMissCount());
}

test "span wrap cache evicts least recently used entries and stays correct" {
    canvas.bumpTextMeasureGeneration();
    var storage: [text_spans.span_wrap_cache_capacity + 8][48]u8 = undefined;
    const options = text_spans.TextSpanLayoutOptions{ .size = 13, .max_width = 70, .measure = &batched_provider };
    var runs: [text_spans.max_text_span_runs_per_paragraph]text_spans.TextSpanRun = undefined;

    // Fill past capacity with distinct paragraphs.
    for (&storage, 0..) |*bytes, index| {
        const text = std.fmt.bufPrint(bytes, "distinct paragraph number {d} wraps a bit", .{index}) catch unreachable;
        const spans = [_]text_spans.TextSpan{.{ .text = text }};
        _ = text_spans.layoutTextSpans(&spans, options, &runs);
    }
    // The first paragraph was evicted; re-laying it out must MISS (a
    // stale hit would be a lie) and still produce the same layout the
    // uncached breaker produces.
    const first_text = std.fmt.bufPrint(&storage[0], "distinct paragraph number {d} wraps a bit", .{@as(usize, 0)}) catch unreachable;
    const spans = [_]text_spans.TextSpan{.{ .text = first_text }};
    const misses = canvas.textSpanWrapCacheMissCount();
    const cached = text_spans.layoutTextSpans(&spans, options, &runs);
    try std.testing.expectEqual(misses + 1, canvas.textSpanWrapCacheMissCount());

    var reference_runs: [text_spans.max_text_span_runs_per_paragraph]text_spans.TextSpanRun = undefined;
    var estimator_options = options;
    estimator_options.measure = &unbatched_provider;
    canvas.bumpTextMeasureGeneration();
    const reference = text_spans.layoutTextSpans(&spans, estimator_options, &reference_runs);
    try std.testing.expectEqual(reference.runs.len, cached.runs.len);
    try std.testing.expectEqual(reference.line_count, cached.line_count);
}
