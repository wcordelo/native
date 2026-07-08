//! Memoized per-pixel command results for the reference renderer.
//!
//! Every reference-renderer command is a deterministic per-pixel
//! function: the output byte at (x, y) depends only on the command's
//! parameters, the pixel's coordinates, and the destination bytes the
//! command may read (the pixel itself for blends, a kernel-radius apron
//! around it for the backdrop blur). That purity means a command whose
//! parameters AND readable source bytes are identical to a previous run
//! must produce identical output bytes — so the renderer can replay the
//! stored result instead of re-running the loop.
//!
//! Why this exists: hosts that re-render a retained scene every frame
//! (the docs live previews) were paying the full cost of the heavyweight
//! per-pixel commands — the modal scrim's full-viewport Gaussian blur,
//! the surface drop shadow's distance field, the scrim wash's
//! full-viewport blend — for repaints that only changed a caret or a
//! line of text ABOVE those layers. With the memo, the stable layers
//! replay as row copies and only the actual change re-renders.
//!
//! Honesty contract: this is pure memoization. A hit replays bytes that
//! are equal to what re-rendering would produce, by construction of the
//! key. Rendering stays deterministic and pinned reference signatures
//! cannot move, memoized or not — the memo only moves time.
//!
//! Ownership: callers hand the renderer a memo that outlives the render
//! pass (one per live scene). Misses allocate entry pixel storage from
//! the memo's allocator; allocation failure simply skips storing — the
//! command still renders, just unmemoized.
//!
//! `max_image_scale_fills_per_pass` bounds how many scaled-image panels
//! one pass may FILL (hits are free): panel fills are the one memo
//! operation costlier than the work they replace when the very next
//! frame re-keys every panel (fractional scroll phases), so the budget
//! pins the worst case at roughly the unmemoized raster.

const std = @import("std");

pub const ReferenceRenderMemo = struct {
    /// Distinct heavyweight commands one retained scene realistically
    /// carries: the tile background, the modal scrim's blur + wash, the
    /// surface shadow, fill, and border, a few control fills/borders
    /// over the threshold, and a couple of widget backdrops. Eviction is
    /// least-recently-used beyond that — an eviction loop (more stable
    /// big commands than entries) only costs time, never correctness.
    pub const max_entries: usize = 16;

    /// Everything a memoized command's output pixels are a pure function
    /// of. Two runs with equal keys produce equal bytes, so replaying
    /// the stored pixels is exact, not approximate.
    pub const Key = struct {
        surface_width: usize,
        surface_height: usize,
        rect_x: usize,
        rect_y: usize,
        rect_width: usize,
        rect_height: usize,
        /// Hash of the command's own parameters: kind, value fields,
        /// opacity, transform — everything that parametrizes the
        /// per-pixel function (built by the renderer, which knows the
        /// command types).
        params_hash: u64,
        /// Hash of every destination row the command can read before it
        /// writes: the rect expanded vertically by the read apron
        /// (kernel radius for blur, zero for single-pixel blends),
        /// full-width rows. Hashing whole rows keeps the span contiguous
        /// and is a superset of the horizontal apron — a wider hash can
        /// only cause a spurious miss, never a wrong hit.
        source_hash: u64,
    };

    const Entry = struct {
        key: Key = undefined,
        /// The command's output pixels for its rect, tightly packed
        /// RGBA8 rows (`rect_width * 4` bytes per row).
        pixels: []u8 = &.{},
        used: bool = false,
        /// LRU stamp from the memo clock; refreshed on every hit.
        stamp: u64 = 0,
    };

    allocator: std.mem.Allocator,
    entries: [max_entries]Entry = @splat(.{}),
    clock: u64 = 0,
    /// Commands smaller than this many pixels render directly: the memo
    /// trades a hash of the source region per frame for the loop, and
    /// that trade only wins on large rects. Tests may lower it to
    /// exercise the memo on small surfaces.
    min_pixels: usize = 32 * 1024,
    /// Hit/miss counters: observability for tests and profiling only.
    hits: u64 = 0,
    misses: u64 = 0,
    /// Scaled-image sample pool state (see the pool section below).
    image_scale_entries: [max_image_scale_entries]ImageScaleEntry = @splat(.{}),
    image_scale_total_bytes: usize = 0,
    image_scale_hits: u64 = 0,
    image_scale_misses: u64 = 0,
    /// Panel fills spent in the CURRENT render pass (reset by
    /// `renderPass`): a fill costs a full-panel resample, so a pass that
    /// keeps missing (a fractional-offset kinetic scroll re-phases every
    /// draw every frame) must not pay fill + store for panels the next
    /// frame re-misses anyway. Beyond the budget, draws sample directly
    /// — the exact pixels either way, only the caching stops.
    image_scale_fills_this_pass: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) ReferenceRenderMemo {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ReferenceRenderMemo) void {
        for (&self.entries) |*entry| {
            if (entry.pixels.len > 0) self.allocator.free(entry.pixels);
            entry.* = .{};
        }
        for (&self.image_scale_entries) |*entry| {
            if (entry.pixels.len > 0) self.allocator.free(entry.pixels);
            entry.* = .{};
        }
        self.image_scale_total_bytes = 0;
    }

    /// Build the key for a command about to run: hashes the destination
    /// rows it can read (rect expanded vertically by `apron_rows`,
    /// clamped to the surface). `source` is the surface's pixel buffer
    /// BEFORE the command writes anything.
    pub fn keyFor(
        source: []const u8,
        surface_width: usize,
        surface_height: usize,
        rect_x: usize,
        rect_y: usize,
        rect_width: usize,
        rect_height: usize,
        apron_rows: usize,
        params_hash: u64,
    ) Key {
        const apron_top = rect_y -| apron_rows;
        const apron_bottom = @min(surface_height, rect_y + rect_height + apron_rows);
        const row_bytes = surface_width * 4;
        const hashed = source[apron_top * row_bytes .. apron_bottom * row_bytes];
        return .{
            .surface_width = surface_width,
            .surface_height = surface_height,
            .rect_x = rect_x,
            .rect_y = rect_y,
            .rect_width = rect_width,
            .rect_height = rect_height,
            .params_hash = params_hash,
            .source_hash = std.hash.Wyhash.hash(0x5c72_11b8, hashed),
        };
    }

    /// The stored output pixels for this key, or null on miss. A hit
    /// refreshes the entry's LRU stamp.
    pub fn find(self: *ReferenceRenderMemo, key: Key) ?[]const u8 {
        for (&self.entries) |*entry| {
            if (!entry.used) continue;
            if (!std.meta.eql(entry.key, key)) continue;
            self.clock += 1;
            entry.stamp = self.clock;
            self.hits += 1;
            return entry.pixels;
        }
        self.misses += 1;
        return null;
    }

    /// Claim storage for this key's output pixels and return it for the
    /// caller to fill (rect rows, tightly packed). Evicts the least
    /// recently used entry when full; returns null when the allocator
    /// cannot supply the buffer (the command simply stays unmemoized).
    pub fn store(self: *ReferenceRenderMemo, key: Key) ?[]u8 {
        const byte_len = key.rect_width * key.rect_height * 4;
        if (byte_len == 0) return null;
        var victim: *Entry = &self.entries[0];
        for (&self.entries) |*entry| {
            if (!entry.used) {
                victim = entry;
                break;
            }
            if (entry.stamp < victim.stamp) victim = entry;
        }
        if (victim.pixels.len != byte_len) {
            if (victim.pixels.len > 0) self.allocator.free(victim.pixels);
            victim.pixels = &.{};
            victim.used = false;
            victim.pixels = self.allocator.alloc(u8, byte_len) catch return null;
        }
        self.clock += 1;
        victim.key = key;
        victim.stamp = self.clock;
        victim.used = true;
        return victim.pixels;
    }

    // ------------------------------------------------ scaled-image samples
    //
    // Scale-once pool for `draw_image`: at integer device alignment a
    // destination pixel's sampled color depends only on its offset
    // INSIDE the destination rect (the sampler's coordinate math reduces
    // exactly — see the alignment proof at the renderer's cache site),
    // so one sampled panel serves the draw at EVERY position. This is
    // what makes a scrolling album grid cheap: the covers' expensive
    // linear resampling runs once per (image content, panel size), and
    // every later frame blends from the panel. Same honesty contract as
    // the command memo: a hit replays bytes equal to what direct
    // sampling would produce, by construction — only time moves.

    /// Distinct (image, size) panels one retained scene realistically
    /// draws (a grid of covers plus a hero). LRU beyond that.
    pub const max_image_scale_entries: usize = 12;
    /// Per-panel and pool-wide byte bounds: a panel bigger than a 4K
    /// frame is not a cache citizen, and the pool never grows past the
    /// total budget (LRU eviction makes room first, then the panel is
    /// simply not cached).
    pub const max_image_scale_entry_bytes: usize = 8 * 1024 * 1024;
    pub const max_image_scale_total_bytes: usize = 48 * 1024 * 1024;
    /// Panel fills one pass may pay (see the module doc): hits are
    /// free, and over-budget misses simply sample directly.
    pub const max_image_scale_fills_per_pass: u64 = 3;

    /// Everything a panel's bytes are a pure function of: the source
    /// image content (id + dimensions + pixel bytes, hashed with the
    /// same fingerprint the render plans key image uploads by), the
    /// source sub-rect, the panel's pixel dimensions, and the sampling
    /// mode. Position is deliberately absent — that is the point.
    pub const ImageScaleKey = struct {
        content_hash: u64,
        src_x: f32,
        src_y: f32,
        src_width: f32,
        src_height: f32,
        /// Destination extent in f32 (the sampler divides by these
        /// exact values) and the destination origin's subpixel phase
        /// (`x - floor(x)`, exactly representable for any f32): panels
        /// depend on size and phase, never on position, so a draw moved
        /// by whole pixels reuses its panel.
        dst_width: f32,
        dst_height: f32,
        phase_x: f32,
        phase_y: f32,
        dst_width_px: usize,
        dst_height_px: usize,
        sampling: u8,
    };

    const ImageScaleEntry = struct {
        key: ImageScaleKey = undefined,
        pixels: []u8 = &.{},
        used: bool = false,
        stamp: u64 = 0,
    };

    /// The stored panel for this key, or null on miss. A hit refreshes
    /// the entry's LRU stamp.
    pub fn findImageScale(self: *ReferenceRenderMemo, key: ImageScaleKey) ?[]const u8 {
        for (&self.image_scale_entries) |*entry| {
            if (!entry.used) continue;
            if (!std.meta.eql(entry.key, key)) continue;
            self.clock += 1;
            entry.stamp = self.clock;
            self.image_scale_hits += 1;
            return entry.pixels;
        }
        self.image_scale_misses += 1;
        return null;
    }

    /// Claim storage for this key's panel and return it for the caller
    /// to fill (`dst_width_px * dst_height_px * 4` bytes). Evicts least
    /// recently used panels until the pool budget fits; returns null for
    /// over-bound panels or on allocation failure (the draw simply
    /// samples directly).
    pub fn storeImageScale(self: *ReferenceRenderMemo, key: ImageScaleKey) ?[]u8 {
        const byte_len = key.dst_width_px * key.dst_height_px * 4;
        if (byte_len == 0 or byte_len > max_image_scale_entry_bytes) return null;
        // Budget first: evict least-recently-used panels until the new
        // one fits the pool.
        while (self.image_scale_total_bytes + byte_len > max_image_scale_total_bytes) {
            const oldest = self.oldestImageScaleEntry() orelse return null;
            self.evictImageScale(oldest);
        }
        // Then a slot: a free one, else evict the LRU panel.
        var slot: ?*ImageScaleEntry = null;
        for (&self.image_scale_entries) |*entry| {
            if (!entry.used) {
                slot = entry;
                break;
            }
        }
        if (slot == null) {
            const oldest = self.oldestImageScaleEntry() orelse return null;
            self.evictImageScale(oldest);
            slot = oldest;
        }
        const entry = slot.?;
        entry.pixels = self.allocator.alloc(u8, byte_len) catch {
            entry.* = .{};
            return null;
        };
        self.image_scale_total_bytes += byte_len;
        self.clock += 1;
        entry.key = key;
        entry.stamp = self.clock;
        entry.used = true;
        return entry.pixels;
    }

    fn oldestImageScaleEntry(self: *ReferenceRenderMemo) ?*ImageScaleEntry {
        var oldest: ?*ImageScaleEntry = null;
        for (&self.image_scale_entries) |*entry| {
            if (!entry.used) continue;
            if (oldest == null or entry.stamp < oldest.?.stamp) oldest = entry;
        }
        return oldest;
    }

    fn evictImageScale(self: *ReferenceRenderMemo, entry: *ImageScaleEntry) void {
        self.image_scale_total_bytes -= entry.pixels.len;
        if (entry.pixels.len > 0) self.allocator.free(entry.pixels);
        entry.* = .{};
    }
};
