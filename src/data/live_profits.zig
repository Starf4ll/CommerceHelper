// data/live_profits.zig — Live Mode profit persistence I/O (Story 3.4)
//
// Pure data-layer module: owns only load/write/deinit of live_profits.json.
// No knowledge of LiveState or GoodsMap (AD-2 data-layer isolation) — AppState
// (ui layer) does all name<->index translation. Entries are keyed by Origin,
// Good and Destination NAME strings (never array indices) so the file
// survives an Outpost/Good reindex.
const std = @import("std");

/// One persisted profit cell. `profit` is always > 0.0 on write (callers
/// filter out blank cells before writing) but this module does not enforce
/// that on load — a hand-edited 0.0 entry simply round-trips as-is.
pub const LiveProfitEntry = struct {
    origin: []const u8,
    good: []const u8,
    destination: []const u8,
    profit: f32,
};

const max_file_size = 4 * 1024 * 1024; // 4 MiB — mirrors goods.zig's ceiling

/// Load live_profits.json from exe_dir. Fail-soft, same "optional file, safe
/// fallback" contract as loadConfig: a missing file, unreadable file, or
/// corrupt/unparsable JSON all return an empty slice rather than an error.
/// Caller owns the result and must free it with deinitLiveProfitEntries.
pub fn loadLiveProfits(allocator: std.mem.Allocator, exe_dir: []const u8) []LiveProfitEntry {
    return loadLiveProfitsInner(allocator, exe_dir) catch &[_]LiveProfitEntry{};
}

fn loadLiveProfitsInner(allocator: std.mem.Allocator, exe_dir: []const u8) ![]LiveProfitEntry {
    const path = try std.fs.path.join(allocator, &.{ exe_dir, "live_profits.json" });
    defer allocator.free(path);

    const text = try std.fs.cwd().readFileAlloc(allocator, path, max_file_size);
    defer allocator.free(text);

    const parsed = try std.json.parseFromSlice(
        []LiveProfitEntry,
        allocator,
        text,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    // Dupe every string out of the parsed arena (freed above via parsed.deinit)
    // into allocator-owned memory the caller keeps — same convention as
    // goods.zig's parseGoods.
    const result = try allocator.alloc(LiveProfitEntry, parsed.value.len);
    var filled: usize = 0;
    errdefer {
        for (result[0..filled]) |e| {
            allocator.free(e.origin);
            allocator.free(e.good);
            allocator.free(e.destination);
        }
        allocator.free(result);
    }

    for (parsed.value, 0..) |entry, i| {
        // Dupe each field into a named local (not directly into the struct
        // literal) so a failure partway through this entry's three dupes
        // (e.g. OOM on .destination after .origin/.good already succeeded)
        // frees what already succeeded via the errdefers below, instead of
        // leaking it — the outer errdefer above only knows about the
        // `filled` *whole* entries, not an in-flight partial one.
        const origin_dup = try allocator.dupe(u8, entry.origin);
        errdefer allocator.free(origin_dup);
        const good_dup = try allocator.dupe(u8, entry.good);
        errdefer allocator.free(good_dup);
        const destination_dup = try allocator.dupe(u8, entry.destination);

        result[i] = LiveProfitEntry{
            .origin = origin_dup,
            .good = good_dup,
            .destination = destination_dup,
            .profit = entry.profit,
        };
        filled = i + 1;
    }

    return result;
}

/// Free a slice returned by loadLiveProfits (including the empty-slice
/// fail-soft result, which is safe to pass here — Allocator.free is a no-op
/// on a zero-length slice).
pub fn deinitLiveProfitEntries(entries: []LiveProfitEntry, allocator: std.mem.Allocator) void {
    for (entries) |e| {
        allocator.free(e.origin);
        allocator.free(e.good);
        allocator.free(e.destination);
    }
    allocator.free(entries);
}

/// Write `entries` to {exe_dir}/live_profits.json. Pure I/O — callers are
/// expected to have already filtered out blank (profit == 0.0) cells; this
/// module does no filtering of its own.
pub fn writeLiveProfits(entries: []const LiveProfitEntry, allocator: std.mem.Allocator, exe_dir: []const u8) !void {
    const json = try std.json.stringifyAlloc(allocator, entries, .{ .whitespace = .indent_2 });
    defer allocator.free(json);

    const path = try std.fs.path.join(allocator, &.{ exe_dir, "live_profits.json" });
    defer allocator.free(path);

    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = json });
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "writeLiveProfits + loadLiveProfits round-trips entries" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(exe_dir);

    const entries = [_]LiveProfitEntry{
        .{ .origin = "tirChonaill", .good = "Fish", .destination = "dunbarton", .profit = 12.5 },
        .{ .origin = "tirChonaill", .good = "Herb", .destination = "bangor", .profit = 3.0 },
    };

    try writeLiveProfits(&entries, allocator, exe_dir);

    const loaded = loadLiveProfits(allocator, exe_dir);
    defer deinitLiveProfitEntries(loaded, allocator);

    try std.testing.expectEqual(@as(usize, 2), loaded.len);
    try std.testing.expectEqualStrings("tirChonaill", loaded[0].origin);
    try std.testing.expectEqualStrings("Fish", loaded[0].good);
    try std.testing.expectEqualStrings("dunbarton", loaded[0].destination);
    try std.testing.expectEqual(@as(f32, 12.5), loaded[0].profit);
    try std.testing.expectEqualStrings("Herb", loaded[1].good);
    try std.testing.expectEqual(@as(f32, 3.0), loaded[1].profit);
}

test "loadLiveProfits: missing file returns empty result, no error" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(exe_dir);

    const loaded = loadLiveProfits(allocator, exe_dir);
    defer deinitLiveProfitEntries(loaded, allocator);

    try std.testing.expectEqual(@as(usize, 0), loaded.len);
}

test "loadLiveProfits: corrupt/unparsable file fails soft to empty result" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(exe_dir);

    try tmp.dir.writeFile(.{ .sub_path = "live_profits.json", .data = "{ not valid json ][" });

    const loaded = loadLiveProfits(allocator, exe_dir);
    defer deinitLiveProfitEntries(loaded, allocator);

    try std.testing.expectEqual(@as(usize, 0), loaded.len);
}
