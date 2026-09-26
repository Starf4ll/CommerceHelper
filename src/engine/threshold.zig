const std = @import("std");
const config_mod = @import("../data/config.zig");
const goods_mod = @import("../data/goods.zig");
const matrix_mod = @import("matrix.zig");
const optimizer_mod = @import("optimizer.zig");

/// Maximum number of distinct Goods supported per Origin sweep — matches the
/// stack-buffer convention already used by optimizer.zig's mixedLoadFill
/// (candidate_buf: [64]usize).
const MAX_GOODS: usize = 64;

/// The best-Ducats/min combination found for a single Threshold value.
pub const ThresholdRow = struct {
    threshold: u32,
    has_result: bool,
    good_idx: usize,
    transport_name: []const u8,
    destination_idx: usize,
    ducats_per_min: f64,
};

/// Per-Origin sweep result: one row per configured Threshold (ascending,
/// matching Config's stored order), `count` of which are populated.
pub const OriginResult = struct {
    rows: [config_mod.MAX_THRESHOLDS]ThresholdRow,
    count: u8,
};

const OwnedTransport = struct {
    name: []const u8,
    transport: config_mod.Transport,
};

/// Returns one optional OwnedTransport per TransportFlags field, checked
/// explicitly — TransportFlags/TRANSPORT_STATS have no array or iterator.
fn ownedTransports(flags: config_mod.TransportFlags) [8]?OwnedTransport {
    return .{
        if (flags.backpack) OwnedTransport{ .name = "Backpack", .transport = config_mod.TRANSPORT_STATS.backpack } else null,
        if (flags.handcart) OwnedTransport{ .name = "Handcart", .transport = config_mod.TRANSPORT_STATS.handcart } else null,
        if (flags.wagon) OwnedTransport{ .name = "Wagon", .transport = config_mod.TRANSPORT_STATS.wagon } else null,
        if (flags.packElephant) OwnedTransport{ .name = "Pack Elephant", .transport = config_mod.TRANSPORT_STATS.packElephant } else null,
        if (flags.alpaca) OwnedTransport{ .name = "Alpaca", .transport = config_mod.TRANSPORT_STATS.alpaca } else null,
        if (flags.dogSled) OwnedTransport{ .name = "Dog Sled", .transport = config_mod.TRANSPORT_STATS.dogSled } else null,
        if (flags.camel) OwnedTransport{ .name = "Camel", .transport = config_mod.TRANSPORT_STATS.camel } else null,
        if (flags.tradersSkiff) OwnedTransport{ .name = "Trader's Skiff", .transport = config_mod.TRANSPORT_STATS.tradersSkiff } else null,
    };
}

/// For each configured Threshold, evaluates every eligible Good × owned
/// Transport × reachable Destination combination and keeps the best (max)
/// Ducats/min row. Pure: no allocator, no I/O, no side effects.
///
/// Profit/unit for every eligible Good equals the Threshold value directly
/// (uniform across primary and secondary Goods — no buy-cost subtraction,
/// pending OI-5). Because profit is therefore identical across all eligible
/// secondary candidates, mixedLoadFill's own quantityPerSlot → weight → name
/// tie-break chain fully determines secondary ranking.
pub fn sweepOrigin(
    goods: []const goods_mod.Good,
    cfg: config_mod.Config,
    origin_idx: usize,
    route_matrix: matrix_mod.RouteMatrix,
) OriginResult {
    std.debug.assert(origin_idx < 12);
    std.debug.assert(goods.len <= MAX_GOODS);

    var modifier_count: u2 = 0;
    if (cfg.commercePartner) modifier_count += 1;
    if (cfg.grandmasterTitle) modifier_count += 1;

    const player_rating: u32 = config_mod.merchantRatingAt(cfg.merchantRatings, origin_idx);
    const transports = ownedTransports(cfg.transports);

    var result = OriginResult{
        .rows = [_]ThresholdRow{.{
            .threshold = 0,
            .has_result = false,
            .good_idx = 0,
            .transport_name = "",
            .destination_idx = 0,
            .ducats_per_min = 0,
        }} ** config_mod.MAX_THRESHOLDS,
        .count = cfg.thresholdCount,
    };

    var profits_buf: [MAX_GOODS]u32 = undefined;
    var fill_buf: [MAX_GOODS]optimizer_mod.FillEntry = undefined;

    for (cfg.thresholds[0..cfg.thresholdCount], 0..) |threshold_value, row_idx| {
        var best = ThresholdRow{
            .threshold = threshold_value,
            .has_result = false,
            .good_idx = 0,
            .transport_name = "",
            .destination_idx = 0,
            .ducats_per_min = 0,
        };

        // Profit/unit is the Threshold value itself for every rating-eligible
        // Good, 0 otherwise — uniform across primary and secondary Goods.
        const profits = profits_buf[0..goods.len];
        for (goods, 0..) |g, i| {
            profits[i] = if (g.merchantRating <= player_rating) threshold_value else 0;
        }

        for (goods, 0..) |primary_good, primary_idx| {
            if (primary_good.merchantRating > player_rating) continue;

            for (transports) |maybe_t| {
                const t = maybe_t orelse continue;

                const primary_qty = optimizer_mod.primaryQty(
                    primary_good.weight,
                    primary_good.quantityPerSlot,
                    t.transport,
                    modifier_count,
                );
                if (primary_qty == 0) continue;

                const fill_count = optimizer_mod.mixedLoadFill(
                    goods,
                    primary_idx,
                    primary_qty,
                    t.transport,
                    modifier_count,
                    profits,
                    fill_buf[0..],
                );

                var secondary_units: u32 = 0;
                for (fill_buf[0..fill_count]) |entry| secondary_units += entry.qty;

                const total_units: u32 = primary_qty + secondary_units;

                for (0..12) |dest_idx| {
                    if (dest_idx == origin_idx) continue;

                    const base_time = route_matrix.baseTimes[origin_idx][dest_idx];
                    const boat_time = route_matrix.boatTimes[origin_idx][dest_idx];
                    const travel_seconds = optimizer_mod.effectiveTravelTime(
                        base_time,
                        boat_time,
                        t.transport.speedFactor,
                        cfg.speedBonus,
                    );
                    if (travel_seconds <= 0.0) continue;

                    const travel_minutes = travel_seconds / 60.0;
                    const ducats_per_min =
                        @as(f64, @floatFromInt(threshold_value)) *
                        @as(f64, @floatFromInt(total_units)) / travel_minutes;

                    if (!best.has_result or ducats_per_min > best.ducats_per_min) {
                        best = ThresholdRow{
                            .threshold = threshold_value,
                            .has_result = true,
                            .good_idx = primary_idx,
                            .transport_name = t.name,
                            .destination_idx = dest_idx,
                            .ducats_per_min = ducats_per_min,
                        };
                    }
                }
            }
        }

        result.rows[row_idx] = best;
    }

    return result;
}

/// Cache bookkeeping for AppState's per-Origin Threshold cache (Story 2.4).
/// Pure, dvui-free logic extracted from `AppState.update()` so it can be unit
/// tested without pulling in dvui/UI modules. Behavior:
///
/// 1. If `stale.*` is true, clear all 12 cache slots and set `stale.* = false`
///    — this happens unconditionally, even if `cfg` is null.
/// 2. Guard on `cfg`, `cfg.origin` non-empty, `goods_map`, and `route_matrix`
///    all being present; return early otherwise (pre-wizard skip).
/// 3. Find the current Origin's index via the OUTPOST_KEYS linear scan; if
///    that slot is empty, run `sweepOrigin` and store the result.
pub fn updateCache(
    cache: *[12]?OriginResult,
    stale: *bool,
    cfg: ?config_mod.Config,
    goods_map: ?goods_mod.GoodsMap,
    route_matrix: ?matrix_mod.RouteMatrix,
) void {
    if (stale.*) {
        cache.* = [_]?OriginResult{null} ** 12;
        stale.* = false;
    }

    const c = cfg orelse return;
    if (c.origin.len == 0) return; // pre-wizard: nothing to sweep yet

    const gm = goods_map orelse return;
    const rm = route_matrix orelse return;

    var origin_idx: ?usize = null;
    for (config_mod.OUTPOST_KEYS, 0..) |key, i| {
        if (std.mem.eql(u8, c.origin, key)) {
            origin_idx = i;
            break;
        }
    }
    const idx = origin_idx orelse return;

    if (cache[idx] == null) {
        const goods_slice: []const goods_mod.Good = gm.get(c.origin) orelse &[_]goods_mod.Good{};
        cache[idx] = sweepOrigin(goods_slice, c, idx, rm);
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

fn makeGood(name: []const u8, weight: u32, qty_per_slot: u32, rating: u32) goods_mod.Good {
    return .{
        .name = name,
        .description = "",
        .image = "",
        .weight = weight,
        .quantityPerSlot = qty_per_slot,
        .cost = 0,
        .merchantRating = rating,
    };
}

/// Builds a RouteMatrix with every cell set to (base, boat), for tests that
/// only care about one origin row and override specific destinations.
fn makeUniformMatrix(base: u32, boat: u32) matrix_mod.RouteMatrix {
    return matrix_mod.RouteMatrix{
        .baseTimes = [_][12]u32{[_]u32{base} ** 12} ** 12,
        .boatTimes = [_][12]u32{[_]u32{boat} ** 12} ** 12,
    };
}

test "sweepOrigin happy path: one eligible Good/Transport/Destination" {
    const goods = [_]goods_mod.Good{
        makeGood("OnlyGood", 10, 5, 1),
    };

    var cfg = config_mod.Config{};
    cfg.transports.wagon = true;
    cfg.thresholds[0] = 100;
    cfg.thresholdCount = 1;

    var matrix = makeUniformMatrix(100_000, 0);
    matrix.baseTimes[0][1] = 100;
    matrix.baseTimes[1][0] = 100;

    const result = sweepOrigin(&goods, cfg, 0, matrix);

    try std.testing.expectEqual(@as(u8, 1), result.count);
    const row = result.rows[0];
    try std.testing.expect(row.has_result);
    try std.testing.expectEqual(@as(u32, 100), row.threshold);
    try std.testing.expectEqual(@as(usize, 0), row.good_idx);
    try std.testing.expectEqual(@as(usize, 1), row.destination_idx);
    try std.testing.expect(std.mem.eql(u8, "Wagon", row.transport_name));
    // primaryQty(weight=10, qty=5, wagon cap=900 slots=7, mods=0) = min(90, 35) = 35
    // travel = 100 / 1.90 = 52.6316s => 0.877193 min
    // ducats/min = 100 * 35 / 0.877193 = 3990.0
    try std.testing.expectApproxEqAbs(@as(f64, 3990.0), row.ducats_per_min, 0.01);
}

test "sweepOrigin rating-excluded Good yields has_result=false" {
    const goods = [_]goods_mod.Good{
        makeGood("Excluded", 10, 1, 5), // merchantRating=5 > default player rating=1
    };

    var cfg = config_mod.Config{};
    cfg.transports.backpack = true;
    cfg.thresholds[0] = 50;
    cfg.thresholdCount = 1;

    const matrix = makeUniformMatrix(100, 0);

    const result = sweepOrigin(&goods, cfg, 0, matrix);

    try std.testing.expectEqual(@as(u8, 1), result.count);
    try std.testing.expect(!result.rows[0].has_result);
}

test "sweepOrigin tie-break parity with mixedLoadFill's weight rule" {
    // Primary (idx0): weight=600 qtyPerSlot=1, dogSled cap=700 slots=11.
    // primaryQty = min(700/600=1, 11*1=11) = 1 (weight-bound).
    // remaining_weight = 700 - 600 = 100; remaining_slots = 11 - 1 = 10.
    //
    // Secondary A (idx1): weight=20 qtyPerSlot=1 ("Big").
    // Secondary B (idx2): weight=10 qtyPerSlot=1 ("Small").
    // Profit/unit identical (=threshold) for both => profit-per-slot tie =>
    // tie-break by weight ascending => B must be picked first.
    // B first: qty = min(10*1, 100/10) = 10 -> uses all weight+slots (10 each).
    // Total units = 1 (primary) + 10 (B) = 11.
    // If A were wrongly picked first: qty = min(10*1, 100/20) = 5 -> total = 6.
    const goods = [_]goods_mod.Good{
        makeGood("Primary", 600, 1, 1),
        makeGood("Big", 20, 1, 1),
        makeGood("Small", 10, 1, 1),
    };

    var cfg = config_mod.Config{};
    cfg.transports.dogSled = true;
    cfg.thresholds[0] = 100;
    cfg.thresholdCount = 1;

    // dogSled speedFactor = 1.86; base=186 => travel = 186/1.86 = 100s = 1.6667min
    var matrix = makeUniformMatrix(100_000, 0);
    matrix.baseTimes[0][1] = 186;
    matrix.baseTimes[1][0] = 186;

    const result = sweepOrigin(&goods, cfg, 0, matrix);

    try std.testing.expect(result.rows[0].has_result);
    // Correct tie-break (B first, total_units=11): ducats/min = 100*11/(100/60) = 660.0
    // Wrong tie-break (A first, total_units=6):    ducats/min = 100*6/(100/60)  = 360.0
    try std.testing.expectApproxEqAbs(@as(f64, 660.0), result.rows[0].ducats_per_min, 0.01);
}

// ── updateCache tests (Story 2.4 Matrix Test Audit gap — rows 2, 3, 5) ────────

/// A value real `sweepOrigin` output could never produce for the test configs
/// below (threshold values used are all <=1000; count is always <=32) — used
/// to detect whether updateCache left an existing slot untouched.
fn sentinelResult() OriginResult {
    var r = OriginResult{
        .rows = [_]ThresholdRow{.{
            .threshold = 0,
            .has_result = false,
            .good_idx = 0,
            .transport_name = "",
            .destination_idx = 0,
            .ducats_per_min = 0,
        }} ** config_mod.MAX_THRESHOLDS,
        .count = 200, // out of range for any real sweepOrigin call (max 32)
    };
    r.rows[0].threshold = 424242;
    r.rows[0].ducats_per_min = 999999.0;
    return r;
}

fn makeTestCfg(origin: []const u8) config_mod.Config {
    var cfg = config_mod.Config{};
    cfg.origin = origin;
    cfg.transports.wagon = true;
    cfg.thresholds[0] = 100;
    cfg.thresholdCount = 1;
    return cfg;
}

test "updateCache row 2: populated non-stale slot is returned as-is, not recomputed" {
    var goods_map = goods_mod.GoodsMap.init(std.testing.allocator);
    defer goods_map.deinit();
    var goods_list = [_]goods_mod.Good{makeGood("OnlyGood", 10, 5, 1)};
    try goods_map.put("tirChonaill", goods_list[0..]);

    const cfg = makeTestCfg("tirChonaill");
    const matrix = makeUniformMatrix(100, 0);

    var cache = [_]?OriginResult{null} ** 12;
    cache[0] = sentinelResult();
    var stale = false;

    updateCache(&cache, &stale, cfg, goods_map, matrix);

    // Slot untouched — sweepOrigin was never re-triggered for it.
    try std.testing.expect(cache[0] != null);
    try std.testing.expectEqual(@as(u8, 200), cache[0].?.count);
    try std.testing.expectEqual(@as(u32, 424242), cache[0].?.rows[0].threshold);
    try std.testing.expectApproxEqAbs(@as(f64, 999999.0), cache[0].?.rows[0].ducats_per_min, 0.01);

    // No other slot was ever populated.
    for (cache[1..]) |slot| try std.testing.expect(slot == null);
    try std.testing.expect(!stale);
}

test "updateCache row 3: stale=true clears all 12 slots, recomputes only current Origin" {
    var goods_map = goods_mod.GoodsMap.init(std.testing.allocator);
    defer goods_map.deinit();
    var goods_list = [_]goods_mod.Good{makeGood("OnlyGood", 10, 5, 1)};
    try goods_map.put("dunbarton", goods_list[0..]);

    const cfg = makeTestCfg("dunbarton"); // OUTPOST_KEYS index 1
    var matrix = makeUniformMatrix(100_000, 0);
    matrix.baseTimes[1][0] = 100;
    matrix.baseTimes[0][1] = 100;

    var cache = [_]?OriginResult{sentinelResult()} ** 12;
    var stale = true;

    updateCache(&cache, &stale, cfg, goods_map, matrix);

    try std.testing.expect(!stale);

    // Every slot except the current Origin's (idx 1) must be null — the
    // sentinel that was there before the clear must be gone everywhere.
    for (cache, 0..) |slot, i| {
        if (i == 1) {
            try std.testing.expect(slot != null);
            // Recomputed via a real sweepOrigin call — not the sentinel.
            try std.testing.expect(slot.?.count != 200);
        } else {
            try std.testing.expect(slot == null);
        }
    }
}

test "updateCache row 5: cfg=null or empty origin returns without touching cache" {
    var cache = [_]?OriginResult{null} ** 12;
    cache[0] = sentinelResult();
    var stale = false;

    // cfg = null entirely.
    updateCache(&cache, &stale, null, null, null);
    try std.testing.expect(cache[0] != null);
    try std.testing.expectEqual(@as(u8, 200), cache[0].?.count);
    for (cache[1..]) |slot| try std.testing.expect(slot == null);

    // cfg present but origin == "" (pre-wizard).
    const cfg = config_mod.Config{}; // default origin is ""
    updateCache(&cache, &stale, cfg, null, null);
    try std.testing.expect(cache[0] != null);
    try std.testing.expectEqual(@as(u8, 200), cache[0].?.count);
    for (cache[1..]) |slot| try std.testing.expect(slot == null);

    try std.testing.expect(!stale);
}

test "updateCache goods_map missing (route_matrix present) returns without touching cache" {
    const cfg = makeTestCfg("tirChonaill");
    const matrix = makeUniformMatrix(100, 0);

    var cache = [_]?OriginResult{null} ** 12;
    cache[0] = sentinelResult();
    var stale = false;

    updateCache(&cache, &stale, cfg, null, matrix);

    // No goods_map => early return before the cache slot lookup; untouched, no crash.
    try std.testing.expect(cache[0] != null);
    try std.testing.expectEqual(@as(u8, 200), cache[0].?.count);
    for (cache[1..]) |slot| try std.testing.expect(slot == null);
    try std.testing.expect(!stale);
}

test "updateCache route_matrix missing (goods_map present) returns without touching cache" {
    var goods_map = goods_mod.GoodsMap.init(std.testing.allocator);
    defer goods_map.deinit();
    var goods_list = [_]goods_mod.Good{makeGood("OnlyGood", 10, 5, 1)};
    try goods_map.put("tirChonaill", goods_list[0..]);

    const cfg = makeTestCfg("tirChonaill");

    var cache = [_]?OriginResult{null} ** 12;
    cache[0] = sentinelResult();
    var stale = false;

    updateCache(&cache, &stale, cfg, goods_map, null);

    // No route_matrix => early return before the cache slot lookup; untouched, no crash.
    try std.testing.expect(cache[0] != null);
    try std.testing.expectEqual(@as(u8, 200), cache[0].?.count);
    for (cache[1..]) |slot| try std.testing.expect(slot == null);
    try std.testing.expect(!stale);
}

// ── Additional coverage: multi-threshold, modifiers, ratings, transports ────

test "sweepOrigin with multiple thresholds: each row's threshold and ducats_per_min scale correctly" {
    // Single Good/Transport/Destination (mirrors the happy-path test) but with
    // three distinct threshold values, to catch a loop/index misalignment
    // that a single-threshold config could never surface.
    const goods = [_]goods_mod.Good{
        makeGood("OnlyGood", 10, 5, 1),
    };

    var cfg = config_mod.Config{};
    cfg.transports.wagon = true;
    cfg.thresholds[0] = 50;
    cfg.thresholds[1] = 100;
    cfg.thresholds[2] = 200;
    cfg.thresholdCount = 3;

    var matrix = makeUniformMatrix(100_000, 0);
    matrix.baseTimes[0][1] = 100;
    matrix.baseTimes[1][0] = 100;

    const result = sweepOrigin(&goods, cfg, 0, matrix);

    try std.testing.expectEqual(@as(u8, 3), result.count);

    // primaryQty(weight=10, qty=5, wagon cap=900 slots=7, mods=0) = min(90, 35) = 35
    // travel = 100 / 1.90 = 52.6316s => 0.877193 min; total_units=35 (no secondaries)
    // ducats/min = threshold * 35 * 60 * 1.9 / 100 = threshold * 39.9
    const expected = [_]struct { threshold: u32, ducats: f64 }{
        .{ .threshold = 50, .ducats = 1995.0 },
        .{ .threshold = 100, .ducats = 3990.0 },
        .{ .threshold = 200, .ducats = 7980.0 },
    };

    for (expected, 0..) |exp, row_idx| {
        const row = result.rows[row_idx];
        try std.testing.expect(row.has_result);
        try std.testing.expectEqual(exp.threshold, row.threshold);
        try std.testing.expectEqual(@as(usize, 0), row.good_idx);
        try std.testing.expectEqual(@as(usize, 1), row.destination_idx);
        try std.testing.expect(std.mem.eql(u8, "Wagon", row.transport_name));
        try std.testing.expectApproxEqAbs(exp.ducats, row.ducats_per_min, 0.01);
    }
}

test "sweepOrigin commercePartner=true expands effective capacity (+100 weight/+1 slot)" {
    const goods = [_]goods_mod.Good{
        makeGood("OnlyGood", 10, 5, 1),
    };

    var cfg = config_mod.Config{};
    cfg.transports.wagon = true;
    cfg.commercePartner = true;
    cfg.thresholds[0] = 100;
    cfg.thresholdCount = 1;

    var matrix = makeUniformMatrix(100_000, 0);
    matrix.baseTimes[0][1] = 100;
    matrix.baseTimes[1][0] = 100;

    const result = sweepOrigin(&goods, cfg, 0, matrix);

    try std.testing.expect(result.rows[0].has_result);
    // primaryQty(weight=10, qty=5, wagon cap=900+100=1000 slots=7+1=8, mods=1)
    //   = min(100, 40) = 40 (vs 35 with mods=0) — the +100/+1 bump increases units.
    // ducats/min = 100 * 40 * 60 * 1.9 / 100 = 4560.0 (vs 3990.0 with mods=0)
    try std.testing.expectApproxEqAbs(@as(f64, 4560.0), result.rows[0].ducats_per_min, 0.01);
}

test "sweepOrigin commercePartner+grandmasterTitle expands capacity further (+200 weight/+2 slots)" {
    const goods = [_]goods_mod.Good{
        makeGood("OnlyGood", 10, 5, 1),
    };

    var cfg = config_mod.Config{};
    cfg.transports.wagon = true;
    cfg.commercePartner = true;
    cfg.grandmasterTitle = true;
    cfg.thresholds[0] = 100;
    cfg.thresholdCount = 1;

    var matrix = makeUniformMatrix(100_000, 0);
    matrix.baseTimes[0][1] = 100;
    matrix.baseTimes[1][0] = 100;

    const result = sweepOrigin(&goods, cfg, 0, matrix);

    try std.testing.expect(result.rows[0].has_result);
    // primaryQty(weight=10, qty=5, wagon cap=900+200=1100 slots=7+2=9, mods=2)
    //   = min(110, 45) = 45 (vs 35 with mods=0, 40 with mods=1)
    // ducats/min = 100 * 45 * 60 * 1.9 / 100 = 5130.0
    try std.testing.expectApproxEqAbs(@as(f64, 5130.0), result.rows[0].ducats_per_min, 0.01);
}

test "merchantRatingAt returns the field matching each outpost index (not a uniform default)" {
    // Every field gets a distinct value so a swapped `case` arm among any of
    // indices 0-11 (OUTPOST_KEYS order) would be caught immediately.
    const ratings = config_mod.MerchantRatings{
        .tirChonaill = 10,
        .dunbarton = 20,
        .bangor = 30,
        .cobh = 40,
        .tara = 50,
        .emainMacha = 60,
        .taillteann = 70,
        .belvast = 80,
        .qilla = 90,
        .cor = 100,
        .filia = 110,
        .vales = 120,
    };

    try std.testing.expectEqual(@as(u8, 10), config_mod.merchantRatingAt(ratings, 0));
    try std.testing.expectEqual(@as(u8, 20), config_mod.merchantRatingAt(ratings, 1));
    try std.testing.expectEqual(@as(u8, 30), config_mod.merchantRatingAt(ratings, 2));
    try std.testing.expectEqual(@as(u8, 40), config_mod.merchantRatingAt(ratings, 3));
    try std.testing.expectEqual(@as(u8, 50), config_mod.merchantRatingAt(ratings, 4));
    try std.testing.expectEqual(@as(u8, 60), config_mod.merchantRatingAt(ratings, 5));
    try std.testing.expectEqual(@as(u8, 70), config_mod.merchantRatingAt(ratings, 6));
    try std.testing.expectEqual(@as(u8, 80), config_mod.merchantRatingAt(ratings, 7));
    try std.testing.expectEqual(@as(u8, 90), config_mod.merchantRatingAt(ratings, 8));
    try std.testing.expectEqual(@as(u8, 100), config_mod.merchantRatingAt(ratings, 9));
    try std.testing.expectEqual(@as(u8, 110), config_mod.merchantRatingAt(ratings, 10));
    try std.testing.expectEqual(@as(u8, 120), config_mod.merchantRatingAt(ratings, 11));
}

// ── Transport coverage (Story 2.4 Matrix Test Audit gap — row 5) ─────────────
//
// Every case below uses a single eligible Good, threshold=100, base_time=100
// on the only reachable destination, so ducats_per_min reduces to
// `qty * 60 * speed_factor` — letting each assertion double as a check that
// the sweep actually reached that Transport's TRANSPORT_STATS entry.

test "sweepOrigin backpack transport actually evaluated for an eligible Good" {
    // The existing "rating-excluded" test sets backpack=true but its primary
    // Good is filtered out before the transport loop runs, so that pairing is
    // never actually checked there. Here the Good is rating-eligible.
    const goods = [_]goods_mod.Good{
        makeGood("OnlyGood", 10, 5, 1),
    };

    var cfg = config_mod.Config{};
    cfg.transports.backpack = true;
    cfg.thresholds[0] = 100;
    cfg.thresholdCount = 1;

    var matrix = makeUniformMatrix(100_000, 0);
    matrix.baseTimes[0][1] = 100;
    matrix.baseTimes[1][0] = 100;

    const result = sweepOrigin(&goods, cfg, 0, matrix);

    try std.testing.expect(result.rows[0].has_result);
    try std.testing.expect(std.mem.eql(u8, "Backpack", result.rows[0].transport_name));
    // primaryQty(weight=10, qty=5, backpack cap=400 slots=4, mods=0) = min(40, 20) = 20
    // ducats/min = 20 * 60 * 0.91 = 1092.0
    try std.testing.expectApproxEqAbs(@as(f64, 1092.0), result.rows[0].ducats_per_min, 0.01);
}

test "sweepOrigin handcart transport matches TRANSPORT_STATS" {
    const goods = [_]goods_mod.Good{
        makeGood("OnlyGood", 10, 5, 1),
    };

    var cfg = config_mod.Config{};
    cfg.transports.handcart = true;
    cfg.thresholds[0] = 100;
    cfg.thresholdCount = 1;

    var matrix = makeUniformMatrix(100_000, 0);
    matrix.baseTimes[0][1] = 100;
    matrix.baseTimes[1][0] = 100;

    const result = sweepOrigin(&goods, cfg, 0, matrix);

    try std.testing.expect(result.rows[0].has_result);
    try std.testing.expect(std.mem.eql(u8, "Handcart", result.rows[0].transport_name));
    // primaryQty(weight=10, qty=5, handcart cap=800 slots=6, mods=0) = min(80, 30) = 30
    // ducats/min = 30 * 60 * 1.00 = 1800.0
    try std.testing.expectApproxEqAbs(@as(f64, 1800.0), result.rows[0].ducats_per_min, 0.01);
}

test "sweepOrigin packElephant transport matches TRANSPORT_STATS" {
    const goods = [_]goods_mod.Good{
        makeGood("OnlyGood", 10, 5, 1),
    };

    var cfg = config_mod.Config{};
    cfg.transports.packElephant = true;
    cfg.thresholds[0] = 100;
    cfg.thresholdCount = 1;

    var matrix = makeUniformMatrix(100_000, 0);
    matrix.baseTimes[0][1] = 100;
    matrix.baseTimes[1][0] = 100;

    const result = sweepOrigin(&goods, cfg, 0, matrix);

    try std.testing.expect(result.rows[0].has_result);
    try std.testing.expect(std.mem.eql(u8, "Pack Elephant", result.rows[0].transport_name));
    // primaryQty(weight=10, qty=5, packElephant cap=1700 slots=7, mods=0) = min(170, 35) = 35
    // ducats/min = 35 * 60 * 1.37 = 2877.0
    try std.testing.expectApproxEqAbs(@as(f64, 2877.0), result.rows[0].ducats_per_min, 0.01);
}

test "sweepOrigin alpaca transport matches TRANSPORT_STATS" {
    const goods = [_]goods_mod.Good{
        makeGood("OnlyGood", 10, 5, 1),
    };

    var cfg = config_mod.Config{};
    cfg.transports.alpaca = true;
    cfg.thresholds[0] = 100;
    cfg.thresholdCount = 1;

    var matrix = makeUniformMatrix(100_000, 0);
    matrix.baseTimes[0][1] = 100;
    matrix.baseTimes[1][0] = 100;

    const result = sweepOrigin(&goods, cfg, 0, matrix);

    try std.testing.expect(result.rows[0].has_result);
    try std.testing.expect(std.mem.eql(u8, "Alpaca", result.rows[0].transport_name));
    // primaryQty(weight=10, qty=5, alpaca cap=1100 slots=10, mods=0) = min(110, 50) = 50
    // ducats/min = 50 * 60 * 1.90 = 5700.0
    try std.testing.expectApproxEqAbs(@as(f64, 5700.0), result.rows[0].ducats_per_min, 0.01);
}

test "sweepOrigin camel transport matches TRANSPORT_STATS" {
    const goods = [_]goods_mod.Good{
        makeGood("OnlyGood", 10, 5, 1),
    };

    var cfg = config_mod.Config{};
    cfg.transports.camel = true;
    cfg.thresholds[0] = 100;
    cfg.thresholdCount = 1;

    var matrix = makeUniformMatrix(100_000, 0);
    matrix.baseTimes[0][1] = 100;
    matrix.baseTimes[1][0] = 100;

    const result = sweepOrigin(&goods, cfg, 0, matrix);

    try std.testing.expect(result.rows[0].has_result);
    try std.testing.expect(std.mem.eql(u8, "Camel", result.rows[0].transport_name));
    // primaryQty(weight=10, qty=5, camel cap=1400 slots=7, mods=0) = min(140, 35) = 35
    // ducats/min = 35 * 60 * 2.15 = 4515.0
    try std.testing.expectApproxEqAbs(@as(f64, 4515.0), result.rows[0].ducats_per_min, 0.01);
}

test "sweepOrigin tradersSkiff transport matches TRANSPORT_STATS" {
    const goods = [_]goods_mod.Good{
        makeGood("OnlyGood", 10, 5, 1),
    };

    var cfg = config_mod.Config{};
    cfg.transports.tradersSkiff = true;
    cfg.thresholds[0] = 100;
    cfg.thresholdCount = 1;

    var matrix = makeUniformMatrix(100_000, 0);
    matrix.baseTimes[0][1] = 100;
    matrix.baseTimes[1][0] = 100;

    const result = sweepOrigin(&goods, cfg, 0, matrix);

    try std.testing.expect(result.rows[0].has_result);
    try std.testing.expect(std.mem.eql(u8, "Trader's Skiff", result.rows[0].transport_name));
    // primaryQty(weight=10, qty=5, tradersSkiff cap=1200 slots=8, mods=0) = min(120, 40) = 40
    // ducats/min = 40 * 60 * 2.40 = 5760.0
    try std.testing.expectApproxEqAbs(@as(f64, 5760.0), result.rows[0].ducats_per_min, 0.01);
}
