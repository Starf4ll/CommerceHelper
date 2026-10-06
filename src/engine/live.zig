// engine/live.zig — Live Mode calculation engine
const std = @import("std");
const config_mod = @import("../data/config.zig");
const goods_mod = @import("../data/goods.zig");
const matrix_mod = @import("matrix.zig");
const optimizer_mod = @import("optimizer.zig");
const threshold_mod = @import("threshold.zig");

/// Maximum number of distinct Goods supported per Origin sweep. Real data
/// has 5 Goods per Outpost; this gives generous headroom. Deliberately
/// independent of threshold.zig's own (lower) per-Origin eligible-Good cap —
/// the two serve different purposes and need not match.
const MAX_GOODS: usize = 64;

/// Maximum rows kept in a calculate() result — top 10 by Ducats/min.
pub const MAX_LIVE_RESULTS: usize = 10;

/// Maximum Good/qty entries in a single row's load composition (the primary
/// Good plus whatever secondaries mixedLoadFill packs in). mixedLoadFill's
/// own output buffer is sized one less than this, leaving room for the
/// primary Good at items[0].
pub const MAX_LOAD_ITEMS: usize = 16;

/// A single Good and the quantity carried of it, within a LoadComposition.
pub const GoodQty = struct {
    good_idx: usize,
    qty: u32,
};

/// The full cargo for one result row: the primary Good at items[0], followed
/// by whatever secondary Goods mixedLoadFill packed into remaining capacity.
pub const LoadComposition = struct {
    items: [MAX_LOAD_ITEMS]GoodQty,
    count: u8,
};

/// One ranked result: a Destination × Transport × mixed load, and the
/// Ducats/min it yields.
pub const LiveResult = struct {
    destination_idx: usize,
    transport_name: []const u8,
    load: LoadComposition,
    total_profit: f64,
    ducats_per_min: f64,
};

/// Top-N (by Ducats/min, descending) result set from a single calculate()
/// sweep. `count` may be less than MAX_LIVE_RESULTS — no padding.
pub const LiveResults = struct {
    rows: [MAX_LIVE_RESULTS]LiveResult,
    count: u8,
};

fn blankResult() LiveResult {
    return .{
        .destination_idx = 0,
        .transport_name = "",
        .load = .{
            .items = [_]GoodQty{.{ .good_idx = 0, .qty = 0 }} ** MAX_LOAD_ITEMS,
            .count = 0,
        },
        .total_profit = 0,
        .ducats_per_min = 0,
    };
}

/// Sweeps every Destination × eligible primary Good × owned Transport
/// combination, keyed on real per-Good/per-Destination profit
/// (`LiveState.profits`) instead of threshold.zig's uniform Threshold value,
/// and keeps a running top-10 by Ducats/min. Pure: no allocator, no I/O, no
/// side effects. Mirrors threshold.zig's sweepOrigin structurally (stack
/// buffers, module-private helpers, reused optimizer functions).
///
/// - goods:        the current Origin's Goods slice (goods.len <= MAX_GOODS)
/// - cfg:          current Config (transports, modifiers, speed bonus, ratings)
/// - origin_idx:   the current Origin's OUTPOST_KEYS index (0-11)
/// - route_matrix: base/boat travel times between all Outposts
/// - profits:      profits[good_idx][dest_idx] — f32 Ducats/unit as entered
///                  in Live Mode. Only good_idx < profits.len is considered;
///                  a Good beyond that is treated as zero-profit everywhere.
///
/// Only Goods with profits[good_idx][dest_idx] > 0 at the current
/// Destination are eligible, whether acting as primary or secondary (FR-10).
/// The FR-5 rating filter (`merchantRating > player_rating` excludes
/// regardless of profit) applies identically to both roles.
pub fn calculate(
    goods: []const goods_mod.Good,
    cfg: config_mod.Config,
    origin_idx: usize,
    route_matrix: matrix_mod.RouteMatrix,
    profits: []const [12]f32,
) LiveResults {
    std.debug.assert(origin_idx < 12);
    std.debug.assert(goods.len <= MAX_GOODS);

    var modifier_count: u2 = 0;
    if (cfg.commercePartner) modifier_count += 1;
    if (cfg.grandmasterTitle) modifier_count += 1;

    const player_rating: u32 = config_mod.merchantRatingAt(cfg.merchantRatings, origin_idx);
    const transports = threshold_mod.ownedTransports(cfg.transports);

    var results = LiveResults{
        .rows = [_]LiveResult{blankResult()} ** MAX_LIVE_RESULTS,
        .count = 0,
    };

    var scaled_profits_buf: [MAX_GOODS]u32 = undefined;
    var fill_buf: [MAX_LOAD_ITEMS - 1]optimizer_mod.FillEntry = undefined;

    for (0..12) |dest_idx| {
        if (dest_idx == origin_idx) continue;

        // Per-Destination eligibility + scaled profit (×100, rounded) for
        // mixedLoadFill's own profit-per-slot ranking. mixedLoadFill's
        // ordering only cares about relative magnitude, so the scaling is
        // invariant for ranking purposes — total_profit/ducats_per_min are
        // computed separately below, from the original f32 values.
        //
        // The ×100 scale-up is saturated to u32's max before the int cast: a
        // profit above ~42.9M Ducats/unit would otherwise overflow u32 in the
        // @intFromFloat cast, which is a safety-checked panic in
        // Debug/ReleaseSafe and UB in ReleaseFast. Clamping loses no ranking
        // fidelity for a value already this far outside any realistic
        // Ducats/unit — every good this large sorts identically whether
        // capped or not.
        const scaled_profits = scaled_profits_buf[0..goods.len];
        const max_scaled: f64 = @floatFromInt(std.math.maxInt(u32));
        for (goods, 0..) |g, i| {
            const raw_p: f32 = if (i < profits.len) profits[i][dest_idx] else 0.0;
            const eligible = g.merchantRating <= player_rating and raw_p > 0.0;
            if (eligible) {
                const rounded: f64 = @round(@as(f64, raw_p) * 100.0);
                const capped: f64 = @min(rounded, max_scaled);
                scaled_profits[i] = @intFromFloat(capped);
            } else {
                scaled_profits[i] = 0;
            }
        }

        for (goods, 0..) |primary_good, primary_idx| {
            if (scaled_profits[primary_idx] == 0) continue;
            const primary_profit: f64 = @floatCast(profits[primary_idx][dest_idx]);

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
                    scaled_profits,
                    fill_buf[0..],
                );

                var total_profit: f64 = primary_profit * @as(f64, @floatFromInt(primary_qty));
                var load = LoadComposition{
                    .items = [_]GoodQty{.{ .good_idx = 0, .qty = 0 }} ** MAX_LOAD_ITEMS,
                    .count = 1,
                };
                load.items[0] = .{ .good_idx = primary_idx, .qty = primary_qty };

                for (fill_buf[0..fill_count], 0..) |entry, fi| {
                    const good_profit: f64 = @floatCast(profits[entry.good_idx][dest_idx]);
                    total_profit += good_profit * @as(f64, @floatFromInt(entry.qty));
                    load.items[fi + 1] = .{ .good_idx = entry.good_idx, .qty = entry.qty };
                    load.count += 1;
                }

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
                const ducats_per_min = total_profit / travel_minutes;

                insertResult(&results, .{
                    .destination_idx = dest_idx,
                    .transport_name = t.name,
                    .load = load,
                    .total_profit = total_profit,
                    .ducats_per_min = ducats_per_min,
                });
            }
        }
    }

    return results;
}

/// Inserts `candidate` into `results`, maintaining descending order by
/// ducats_per_min and keeping only the top MAX_LIVE_RESULTS. No-op if
/// `results` is already full and `candidate` doesn't beat the current
/// last-place row.
fn insertResult(results: *LiveResults, candidate: LiveResult) void {
    if (results.count < MAX_LIVE_RESULTS) {
        var i: usize = results.count;
        while (i > 0 and results.rows[i - 1].ducats_per_min < candidate.ducats_per_min) : (i -= 1) {
            results.rows[i] = results.rows[i - 1];
        }
        results.rows[i] = candidate;
        results.count += 1;
        return;
    }

    if (candidate.ducats_per_min <= results.rows[MAX_LIVE_RESULTS - 1].ducats_per_min) return;

    var i: usize = MAX_LIVE_RESULTS - 1;
    while (i > 0 and results.rows[i - 1].ducats_per_min < candidate.ducats_per_min) : (i -= 1) {
        results.rows[i] = results.rows[i - 1];
    }
    results.rows[i] = candidate;
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

fn makeUniformMatrix(base: u32, boat: u32) matrix_mod.RouteMatrix {
    return matrix_mod.RouteMatrix{
        .baseTimes = [_][12]u32{[_]u32{base} ** 12} ** 12,
        .boatTimes = [_][12]u32{[_]u32{boat} ** 12} ** 12,
    };
}

fn zeroProfits() [MAX_GOODS][12]f32 {
    return [_][12]f32{[_]f32{0.0} ** 12} ** MAX_GOODS;
}

test "calculate happy path: single Good/Transport/Destination" {
    const goods = [_]goods_mod.Good{
        makeGood("OnlyGood", 10, 5, 1),
    };

    var cfg = config_mod.Config{};
    cfg.transports.wagon = true;

    var matrix = makeUniformMatrix(100_000, 0);
    matrix.baseTimes[0][1] = 100;
    matrix.baseTimes[1][0] = 100;

    var profits = zeroProfits();
    profits[0][1] = 100.0; // OnlyGood @ Destination 1: 100 Ducats/unit

    const result = calculate(&goods, cfg, 0, matrix, &profits);

    try std.testing.expectEqual(@as(u8, 1), result.count);
    const row = result.rows[0];
    try std.testing.expectEqual(@as(usize, 1), row.destination_idx);
    try std.testing.expect(std.mem.eql(u8, "Wagon", row.transport_name));
    try std.testing.expectEqual(@as(u8, 1), row.load.count);
    try std.testing.expectEqual(@as(usize, 0), row.load.items[0].good_idx);
    // primaryQty(weight=10, qty=5, wagon cap=900 slots=7, mods=0) = min(90, 35) = 35
    try std.testing.expectEqual(@as(u32, 35), row.load.items[0].qty);
    try std.testing.expectApproxEqAbs(@as(f64, 3500.0), row.total_profit, 0.001);
    // travel = 100 / 1.90 = 52.6316s => 0.877193 min; ducats/min = 3500 / 0.877193 = 3990.0
    try std.testing.expectApproxEqAbs(@as(f64, 3990.0), row.ducats_per_min, 0.01);
}

test "calculate zero combos: no profit entered yields count=0" {
    const goods = [_]goods_mod.Good{
        makeGood("OnlyGood", 10, 5, 1),
    };
    var cfg = config_mod.Config{};
    cfg.transports.wagon = true;
    const matrix = makeUniformMatrix(100, 0);
    const profits = zeroProfits();

    const result = calculate(&goods, cfg, 0, matrix, &profits);
    try std.testing.expectEqual(@as(u8, 0), result.count);
}

test "calculate fewer than 10 results: only as many rows as profitable combos exist" {
    const goods = [_]goods_mod.Good{
        makeGood("GoodA", 10, 5, 1),
        makeGood("GoodB", 10, 5, 1),
    };
    var cfg = config_mod.Config{};
    cfg.transports.wagon = true;

    // Unreachable everywhere except Destination 1 (travel_seconds<=0 elsewhere).
    var matrix = makeUniformMatrix(0, 0);
    matrix.baseTimes[0][1] = 100;
    matrix.baseTimes[1][0] = 100;

    var profits = zeroProfits();
    profits[0][1] = 50.0;
    profits[1][1] = 60.0;

    const result = calculate(&goods, cfg, 0, matrix, &profits);
    // 2 Goods x 1 owned Transport x 1 reachable Destination = 2 combos, no padding.
    try std.testing.expectEqual(@as(u8, 2), result.count);
}

test "calculate decimal profit precision: 12.5/unit reflected exactly in total_profit" {
    const goods = [_]goods_mod.Good{
        makeGood("OnlyGood", 10, 5, 1),
    };
    var cfg = config_mod.Config{};
    cfg.transports.wagon = true;

    var matrix = makeUniformMatrix(100_000, 0);
    matrix.baseTimes[0][1] = 100;
    matrix.baseTimes[1][0] = 100;

    var profits = zeroProfits();
    profits[0][1] = 12.5;

    const result = calculate(&goods, cfg, 0, matrix, &profits);
    try std.testing.expectEqual(@as(u8, 1), result.count);
    // primary_qty = 35 (same as happy-path); total_profit = 12.5 * 35 = 437.5 exactly.
    try std.testing.expectApproxEqAbs(@as(f64, 437.5), result.rows[0].total_profit, 0.0001);
}

test "calculate rating-excluded Good yields no result despite profit set" {
    const goods = [_]goods_mod.Good{
        makeGood("Excluded", 10, 5, 5), // merchantRating=5 > default player rating=1
    };
    var cfg = config_mod.Config{};
    cfg.transports.wagon = true;

    const matrix = makeUniformMatrix(100, 0);

    var profits = zeroProfits();
    profits[0][1] = 100.0; // profit set, but rating excludes regardless (FR-5)

    const result = calculate(&goods, cfg, 0, matrix, &profits);
    try std.testing.expectEqual(@as(u8, 0), result.count);
}

test "calculate tie-break parity with mixedLoadFill's weight rule" {
    // Primary (idx0): weight=600 qtyPerSlot=1, dogSled cap=700 slots=11.
    // primaryQty = min(700/600=1, 11*1=11) = 1 (weight-bound).
    // remaining_weight = 100; remaining_slots = 10.
    // Big (idx1) and Small (idx2) share the same real profit (10.0/unit) =>
    // identical profit-per-slot after scaling => tie-break by weight
    // ascending => Small must be picked first, consuming all remaining
    // capacity, leaving no room for Big.
    //
    // FR-10 also makes Big and Small eligible as their own primary Good
    // (profit>0 is the sole eligibility gate for either role), so the sweep
    // legitimately produces 3 rows — one per primary — not just Primary's.
    // Both alternates are slot-bound to the same primaryQty=11 with the same
    // profit/unit (10.0), so they tie at a lower Ducats/min than Primary's
    // row, which is what this test actually cares about: it stays ranked
    // first, and its own secondary slot resolved via the weight tie-break.
    const goods = [_]goods_mod.Good{
        makeGood("Primary", 600, 1, 1),
        makeGood("Big", 20, 1, 1),
        makeGood("Small", 10, 1, 1),
    };

    var cfg = config_mod.Config{};
    cfg.transports.dogSled = true;

    var matrix = makeUniformMatrix(100_000, 0);
    matrix.baseTimes[0][1] = 186;
    matrix.baseTimes[1][0] = 186;

    var profits = zeroProfits();
    profits[0][1] = 100.0; // Primary
    profits[1][1] = 10.0; // Big
    profits[2][1] = 10.0; // Small — tie with Big on profit-per-slot

    const result = calculate(&goods, cfg, 0, matrix, &profits);

    try std.testing.expectEqual(@as(u8, 3), result.count);
    const row = result.rows[0];
    try std.testing.expectEqual(@as(u8, 2), row.load.count);
    try std.testing.expectEqual(@as(usize, 0), row.load.items[0].good_idx);
    try std.testing.expectEqual(@as(u32, 1), row.load.items[0].qty);
    try std.testing.expectEqual(@as(usize, 2), row.load.items[1].good_idx); // Small, not Big
    try std.testing.expectEqual(@as(u32, 10), row.load.items[1].qty);

    // total_profit = 100*1 + 10*10 = 200; travel = 186/1.86 = 100s = 1.6667min
    try std.testing.expectApproxEqAbs(@as(f64, 200.0), row.total_profit, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 120.0), row.ducats_per_min, 0.01);
}

test "calculate absurdly large profit is saturated, not a u32 overflow panic" {
    // 100_000_000.0 Ducats/unit is far past the ~42.9M/unit point where
    // @round(raw_p * 100.0) would overflow u32 in the pre-clamp cast — this
    // proves the saturation fix keeps calculate() panic-free and still
    // produces a sane (capped-ranking, correctly-priced) result.
    const goods = [_]goods_mod.Good{
        makeGood("HugeProfitGood", 10, 5, 1),
    };
    var cfg = config_mod.Config{};
    cfg.transports.wagon = true;

    var matrix = makeUniformMatrix(100_000, 0);
    matrix.baseTimes[0][1] = 100;
    matrix.baseTimes[1][0] = 100;

    var profits = zeroProfits();
    profits[0][1] = 100_000_000.0;

    const result = calculate(&goods, cfg, 0, matrix, &profits);

    try std.testing.expectEqual(@as(u8, 1), result.count);
    const row = result.rows[0];
    try std.testing.expectEqual(@as(usize, 1), row.destination_idx);
    // primaryQty is unaffected by the scaled-profit clamp (same as happy path).
    try std.testing.expectEqual(@as(u32, 35), row.load.items[0].qty);
    // total_profit/ducats_per_min are computed from the original f64 profit,
    // not the saturated scaled_profits ranking value, so pricing stays exact.
    try std.testing.expectApproxEqAbs(@as(f64, 3_500_000_000.0), row.total_profit, 1.0);
}

test "calculate more than 10 profitable combos: keeps exactly the top 10 by ducats_per_min" {
    // Two identically-shaped Goods (same weight/qtyPerSlot/rating, so both
    // yield the same primaryQty=35 on Wagon and identical travel time to
    // every Destination) times 6 reachable Destinations = 12 combos, more
    // than MAX_LIVE_RESULTS. mixedLoadFill contributes nothing here (35 qty
    // consumes all 7 Wagon slots, leaving remaining_slots=0), so
    // total_profit is exactly profit*35 for every combo and ducats_per_min
    // ranks purely by the assigned profit value — letting this test control
    // insertResult's ordering precisely.
    //
    // Sweep order is dest_idx ascending, then primary_idx ascending
    // (GoodA=0 before GoodB=1), so combos arrive in this fixed sequence:
    //   dest1/A=10  dest1/B=20  dest2/A=30  dest2/B=40  dest3/A=50 dest3/B=60
    //   dest4/A=70  dest4/B=80  dest5/A=90  dest5/B=100 dest6/A=95 dest6/B=5
    //
    // The first 10 fill the buffer (count<10 branch, each inserted in sorted
    // position). dest6/A=95 arrives 11th: it beats the then-last-place value
    // (10, dest1/A) so it evicts that row and inserts in sorted position —
    // exercising the "evict + insert sorted" branch. dest6/B=5 arrives last:
    // it does NOT beat the new last-place value (20, dest1/B), so it is
    // dropped without modifying results — exercising the "no-op drop" branch.
    const goods = [_]goods_mod.Good{
        makeGood("GoodA", 10, 5, 1),
        makeGood("GoodB", 10, 5, 1),
    };
    var cfg = config_mod.Config{};
    cfg.transports.wagon = true;

    const matrix = makeUniformMatrix(100, 0);

    var profits = zeroProfits();
    profits[0][1] = 10.0; // dest1/A
    profits[1][1] = 20.0; // dest1/B
    profits[0][2] = 30.0; // dest2/A
    profits[1][2] = 40.0; // dest2/B
    profits[0][3] = 50.0; // dest3/A
    profits[1][3] = 60.0; // dest3/B
    profits[0][4] = 70.0; // dest4/A
    profits[1][4] = 80.0; // dest4/B
    profits[0][5] = 90.0; // dest5/A
    profits[1][5] = 100.0; // dest5/B
    profits[0][6] = 95.0; // dest6/A
    profits[1][6] = 5.0; // dest6/B

    const result = calculate(&goods, cfg, 0, matrix, &profits);

    try std.testing.expectEqual(@as(u8, 10), result.count);

    // Expected: top 10 by profit descending, i.e. every combo except
    // dest1/A (10) and dest6/B (5), which were dropped.
    const Expected = struct { dest: usize, good: usize, profit: f64 };
    const expected = [_]Expected{
        .{ .dest = 5, .good = 1, .profit = 100.0 },
        .{ .dest = 6, .good = 0, .profit = 95.0 },
        .{ .dest = 5, .good = 0, .profit = 90.0 },
        .{ .dest = 4, .good = 1, .profit = 80.0 },
        .{ .dest = 4, .good = 0, .profit = 70.0 },
        .{ .dest = 3, .good = 1, .profit = 60.0 },
        .{ .dest = 3, .good = 0, .profit = 50.0 },
        .{ .dest = 2, .good = 1, .profit = 40.0 },
        .{ .dest = 2, .good = 0, .profit = 30.0 },
        .{ .dest = 1, .good = 1, .profit = 20.0 },
    };

    for (expected, 0..) |exp, i| {
        const row = result.rows[i];
        try std.testing.expectEqual(exp.dest, row.destination_idx);
        try std.testing.expectEqual(exp.good, row.load.items[0].good_idx);
        try std.testing.expectApproxEqAbs(exp.profit * 35.0, row.total_profit, 0.001);
        if (i > 0) {
            try std.testing.expect(result.rows[i - 1].ducats_per_min >= row.ducats_per_min);
        }
    }

    // The two dropped candidates (dest1/A=10, dest6/B=5) must not appear.
    for (result.rows[0..result.count]) |row| {
        const is_dropped_a = row.destination_idx == 1 and row.load.items[0].good_idx == 0;
        const is_dropped_b = row.destination_idx == 6 and row.load.items[0].good_idx == 1;
        try std.testing.expect(!is_dropped_a);
        try std.testing.expect(!is_dropped_b);
    }
}
