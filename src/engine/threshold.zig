const std = @import("std");
const config_mod = @import("../data/config.zig");
const goods_mod = @import("../data/goods.zig");
const matrix_mod = @import("matrix.zig");
const optimizer_mod = @import("optimizer.zig");

/// Maximum number of eligible Goods swept per Origin (Story 4.1). Real data
/// has 5 Goods per Outpost; this gives 60% headroom. A hand-edited
/// `goods.json` that exceeds this bound simply stops being swept past the
/// 8th eligible Good for that Origin — a documented limit, not a crash.
///
/// (Was `64` pre-Story-4.1, matching optimizer.zig's mixedLoadFill stack
/// buffer — no longer relevant here since this module never calls
/// mixedLoadFill.)
const MAX_GOODS: usize = 8;

/// One independently-computed Good × Threshold × Destination combination
/// (Story 4.1). `reachable = false` means no owned Transport could carry any
/// quantity of the Good, or the Destination itself has no usable route
/// (including the trivial case of `destination_idx == origin_idx`) — the
/// cell still exists in the matrix, it is never omitted.
pub const ThresholdCell = struct {
    good_idx: usize,
    threshold: u32,
    destination_idx: usize,
    reachable: bool,
    transport_name: []const u8,
    travel_minutes: f64,
    ducats_per_min: f64,
};

/// The best-Ducats/min combination found for a single Threshold value.
///
/// Pre-Story-4.1 this was `sweepOrigin`'s real output shape (one collapsed
/// winner per Threshold across every Good). It now exists purely as a
/// compatibility bridge so `ui/threshold.zig` keeps compiling/rendering
/// unchanged — see `OriginResult.rows`/`count` below. Story 4.2/4.3 deletes
/// this type entirely once the new per-Good/per-Destination UI lands.
pub const ThresholdRow = struct {
    threshold: u32,
    has_result: bool,
    good_idx: usize,
    transport_name: []const u8,
    destination_idx: usize,
    ducats_per_min: f64,
};

/// Per-Origin sweep result (Story 4.1).
///
/// `cells[g][t][d]` holds the Good × Threshold × Destination combination for
/// the `g`-th *eligible* Good swept at this Origin (insertion order, not the
/// Good's raw index into the Origin's Goods slice — that raw index is
/// `cells[g][t][d].good_idx`), the `t`-th configured Threshold
/// (`cfg.thresholds[t]`, ascending — matches `cfg.thresholds[0..thresholdCount]`
/// order), and Destination index `d` (0-11, OUTPOST_KEYS order; `d == origin`
/// is always `reachable = false`).
///
/// Only `cells[0..good_count][0..threshold_count][0..12]` are meaningful —
/// the remaining slots are zeroed (`reachable = false`) filler, never read.
pub const OriginResult = struct {
    cells: [MAX_GOODS][config_mod.MAX_THRESHOLDS][12]ThresholdCell,
    good_count: u8,
    threshold_count: u8,

    // ── Compatibility bridge (temporary — see ThresholdRow's doc comment) ──
    // Derived from `cells` at the end of `sweepOrigin`: for each Threshold,
    // the single reachable cell (across every Good/Destination) with the
    // highest Ducats/min, exactly mirroring the pre-Story-4.1 "one collapsed
    // winner per Threshold" shape `ui/threshold.zig` still renders.
    rows: [config_mod.MAX_THRESHOLDS]ThresholdRow,
    count: u8,
};

const OwnedTransport = struct {
    name: []const u8,
    transport: config_mod.Transport,
};

/// Returns one optional OwnedTransport per TransportFlags field, checked
/// explicitly — TransportFlags/TRANSPORT_STATS have no array or iterator.
/// Public so engine/live.zig (Story 3.2) can reuse it instead of a third
/// hand-enumeration of TransportFlags.
pub fn ownedTransports(flags: config_mod.TransportFlags) [8]?OwnedTransport {
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

const zero_cell = ThresholdCell{
    .good_idx = 0,
    .threshold = 0,
    .destination_idx = 0,
    .reachable = false,
    .transport_name = "",
    .travel_minutes = 0,
    .ducats_per_min = 0,
};

const zero_row = ThresholdRow{
    .threshold = 0,
    .has_result = false,
    .good_idx = 0,
    .transport_name = "",
    .destination_idx = 0,
    .ducats_per_min = 0,
};

/// Builds a fully-zeroed cell matrix (every cell `reachable = false`) —
/// shared by `sweepOrigin`'s initial `result` and the test-only
/// `sentinelResult()` so the nested array-repeat literal exists in exactly
/// one place.
fn zeroCells() [MAX_GOODS][config_mod.MAX_THRESHOLDS][12]ThresholdCell {
    return [_][config_mod.MAX_THRESHOLDS][12]ThresholdCell{
        [_][12]ThresholdCell{
            [_]ThresholdCell{zero_cell} ** 12,
        } ** config_mod.MAX_THRESHOLDS,
    } ** MAX_GOODS;
}

/// Builds a fully-zeroed rows array (`has_result = false` throughout) — same
/// de-duplication rationale as `zeroCells()` above.
fn zeroRows() [config_mod.MAX_THRESHOLDS]ThresholdRow {
    return [_]ThresholdRow{zero_row} ** config_mod.MAX_THRESHOLDS;
}

/// For each eligible Good (Merchant Rating <= player's rating at this Origin,
/// bounded to the first `MAX_GOODS` such Goods) × each configured Threshold ×
/// each Destination (0-11, excluding the Origin itself), evaluates every
/// owned Transport via `primaryQty` (single-Good Load only — never
/// `optimizer.mixedLoadFill`) and keeps the best (max) Ducats/min as that
/// cell. Pure: no allocator, no I/O, no side effects; returns by value.
///
/// Profit/unit for every eligible Good equals the Threshold value directly
/// (uniform — no buy-cost subtraction, pending OI-5).
pub fn sweepOrigin(
    goods: []const goods_mod.Good,
    cfg: config_mod.Config,
    origin_idx: usize,
    route_matrix: matrix_mod.RouteMatrix,
) OriginResult {
    std.debug.assert(origin_idx < 12);

    var modifier_count: u2 = 0;
    if (cfg.commercePartner) modifier_count += 1;
    if (cfg.grandmasterTitle) modifier_count += 1;

    const player_rating: u32 = config_mod.merchantRatingAt(cfg.merchantRatings, origin_idx);
    const transports = ownedTransports(cfg.transports);

    var result = OriginResult{
        .cells = zeroCells(),
        .good_count = 0,
        .threshold_count = cfg.thresholdCount,
        .rows = zeroRows(),
        .count = cfg.thresholdCount,
    };

    var good_count: usize = 0;

    for (goods, 0..) |good, good_idx| {
        // Per-Good bound (documented limit, not a crash): Goods beyond the
        // 8th *eligible* one for this Origin are simply never swept.
        if (good_count >= MAX_GOODS) break;
        if (good.merchantRating > player_rating) continue; // ineligible — no cells at all, doesn't count toward the bound

        const slot = good_count;
        good_count += 1;

        for (cfg.thresholds[0..cfg.thresholdCount], 0..) |threshold_value, t_idx| {
            // Default every Destination to unreachable up front, then only
            // ever improve a cell as Transports are evaluated below.
            var cells_for_threshold: [12]ThresholdCell = undefined;
            for (0..12) |dest_idx| {
                cells_for_threshold[dest_idx] = ThresholdCell{
                    .good_idx = good_idx,
                    .threshold = threshold_value,
                    .destination_idx = dest_idx,
                    .reachable = false,
                    .transport_name = "",
                    .travel_minutes = 0,
                    .ducats_per_min = 0,
                };
            }

            for (transports) |maybe_t| {
                const t = maybe_t orelse continue;

                // primaryQty depends only on the Good/Transport/modifiers —
                // never on Destination — so compute it once per Transport
                // here instead of redundantly inside the 12-Destination loop.
                const primary_qty = optimizer_mod.primaryQty(
                    good.weight,
                    good.quantityPerSlot,
                    t.transport,
                    modifier_count,
                );
                if (primary_qty == 0) continue; // no viable owned Transport for this Good

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
                    if (travel_seconds <= 0.0) continue; // Destination unreachable

                    const travel_minutes = travel_seconds / 60.0;
                    const ducats_per_min =
                        @as(f64, @floatFromInt(threshold_value)) *
                        @as(f64, @floatFromInt(primary_qty)) / travel_minutes;

                    const cell = &cells_for_threshold[dest_idx];
                    if (!cell.reachable or ducats_per_min > cell.ducats_per_min) {
                        cell.* = ThresholdCell{
                            .good_idx = good_idx,
                            .threshold = threshold_value,
                            .destination_idx = dest_idx,
                            .reachable = true,
                            .transport_name = t.name,
                            .travel_minutes = travel_minutes,
                            .ducats_per_min = ducats_per_min,
                        };
                    }
                }
            }

            for (0..12) |dest_idx| {
                result.cells[slot][t_idx][dest_idx] = cells_for_threshold[dest_idx];
            }
        }
    }

    result.good_count = @intCast(good_count);

    // ── Compatibility bridge derivation (see OriginResult.rows doc comment) ──
    for (0..cfg.thresholdCount) |t_idx| {
        var best = ThresholdRow{
            .threshold = cfg.thresholds[t_idx],
            .has_result = false,
            .good_idx = 0,
            .transport_name = "",
            .destination_idx = 0,
            .ducats_per_min = 0,
        };

        for (0..good_count) |g| {
            for (0..12) |d| {
                const cell = result.cells[g][t_idx][d];
                if (!cell.reachable) continue;
                if (!best.has_result or cell.ducats_per_min > best.ducats_per_min) {
                    best = ThresholdRow{
                        .threshold = cell.threshold,
                        .has_result = true,
                        .good_idx = cell.good_idx,
                        .transport_name = cell.transport_name,
                        .destination_idx = cell.destination_idx,
                        .ducats_per_min = cell.ducats_per_min,
                    };
                }
            }
        }

        result.rows[t_idx] = best;
    }

    return result;
}

/// Cache bookkeeping for AppState's per-Origin Threshold cache (Story 2.4;
/// reshaped to heap-boxed pointers in Story 4.1 — `OriginResult` is now far
/// larger than before, too large for AppState's plain stack-resident inline
/// array). Pure, dvui-free logic extracted from `AppState.update()` so it can
/// be unit tested without pulling in dvui/UI modules. Behavior:
///
/// 1. If `stale.*` is true, `destroy()` every non-null cached pointer via
///    `allocator`, null every slot, and set `stale.* = false` — this happens
///    unconditionally, even if `cfg` is null. No pointer is ever leaked.
/// 2. Guard on `cfg`, `cfg.origin` non-empty, `goods_map`, and `route_matrix`
///    all being present; return early otherwise (pre-wizard skip).
/// 3. Find the current Origin's index via the OUTPOST_KEYS linear scan; if
///    that slot is empty, `create()` a box, run `sweepOrigin` into it, and
///    store the pointer. If the allocation itself fails, the slot is simply
///    left `null` and retried on the next call (no crash, no partial state).
pub fn updateCache(
    cache: *[12]?*OriginResult,
    stale: *bool,
    cfg: ?config_mod.Config,
    goods_map: ?goods_mod.GoodsMap,
    route_matrix: ?matrix_mod.RouteMatrix,
    allocator: std.mem.Allocator,
) void {
    if (stale.*) {
        for (cache) |*slot| {
            if (slot.*) |ptr| {
                allocator.destroy(ptr);
                slot.* = null;
            }
        }
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
        const boxed = allocator.create(OriginResult) catch return; // OOM: leave slot null, retry next call
        boxed.* = sweepOrigin(goods_slice, c, idx, rm);
        cache[idx] = boxed;
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

test "sweepOrigin multi-good happy path: independent cells per Good, no collapsed winner" {
    const goods = [_]goods_mod.Good{
        makeGood("GoodA", 10, 5, 1),
        makeGood("GoodB", 20, 2, 1),
    };

    var cfg = config_mod.Config{};
    cfg.transports.wagon = true;
    cfg.thresholds[0] = 100;
    cfg.thresholds[1] = 200;
    cfg.thresholdCount = 2;

    var matrix = makeUniformMatrix(100_000, 0);
    matrix.baseTimes[0][1] = 100;
    matrix.baseTimes[1][0] = 100;

    const result = sweepOrigin(&goods, cfg, 0, matrix);

    try std.testing.expectEqual(@as(u8, 2), result.good_count);
    try std.testing.expectEqual(@as(u8, 2), result.threshold_count);

    // GoodA (slot 0): primaryQty(weight=10, qty=5, wagon cap=900 slots=7) = min(90,35) = 35
    const cell_a = result.cells[0][0][1];
    try std.testing.expect(cell_a.reachable);
    try std.testing.expectEqual(@as(usize, 0), cell_a.good_idx);
    try std.testing.expectEqual(@as(usize, 1), cell_a.destination_idx);
    try std.testing.expectEqualStrings("Wagon", cell_a.transport_name);
    try std.testing.expectApproxEqAbs(@as(f64, 3990.0), cell_a.ducats_per_min, 0.01);

    // GoodB (slot 1): primaryQty(weight=20, qty=2, wagon cap=900 slots=7) = min(45,14) = 14
    // ducats/min = 100 * 14 * 60 * 1.9 / 100 = 1596.0
    const cell_b = result.cells[1][0][1];
    try std.testing.expect(cell_b.reachable);
    try std.testing.expectEqual(@as(usize, 1), cell_b.good_idx);
    try std.testing.expectApproxEqAbs(@as(f64, 1596.0), cell_b.ducats_per_min, 0.01);

    // The two Goods' cells at the same Threshold/Destination must genuinely
    // differ — the pre-Story-4.1 bug collapsed every Good onto one winner.
    try std.testing.expect(cell_a.ducats_per_min != cell_b.ducats_per_min);
}

test "sweepOrigin compatibility bridge: rows/count mirror the single best reachable cell per Threshold" {
    // Two Goods, one configured Threshold, one reachable Destination: GoodA
    // (heavier, slower) and GoodB (lighter, faster) each get their own
    // independent, reachable cell at threshold[0]/destination[1] — this
    // test exercises the bridge's "pick the max across every Good/Destination
    // for a given Threshold" rule by asserting the bridge row picks GoodB's
    // strictly-higher ducats/min cell as threshold[0]'s winner.
    const goods = [_]goods_mod.Good{
        makeGood("GoodA", 20, 2, 1), // primaryQty = 14 (see multi-good happy path test)
        makeGood("GoodB", 10, 5, 1), // primaryQty = 35 — strictly better ducats/min
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
    // GoodB (raw good_idx 1) has the higher ducats/min (3990.0 vs 1596.0) and
    // must win the compatibility-bridge row, exactly mirroring the winning
    // cell's own fields.
    try std.testing.expectEqual(@as(usize, 1), row.good_idx);
    try std.testing.expectEqual(@as(usize, 1), row.destination_idx);
    try std.testing.expectEqualStrings("Wagon", row.transport_name);
    try std.testing.expectApproxEqAbs(@as(f64, 3990.0), row.ducats_per_min, 0.01);

    const winning_cell = result.cells[1][0][1];
    try std.testing.expectEqual(winning_cell.good_idx, row.good_idx);
    try std.testing.expectEqual(winning_cell.destination_idx, row.destination_idx);
    try std.testing.expectApproxEqAbs(winning_cell.ducats_per_min, row.ducats_per_min, 0.0001);
}

test "sweepOrigin rating-excluded Good produces no cells at all" {
    const goods = [_]goods_mod.Good{
        makeGood("Eligible", 10, 5, 1),
        makeGood("Excluded", 10, 5, 5), // merchantRating=5 > default player rating=1
    };

    var cfg = config_mod.Config{};
    cfg.transports.wagon = true;
    cfg.thresholds[0] = 100;
    cfg.thresholdCount = 1;

    var matrix = makeUniformMatrix(100_000, 0);
    matrix.baseTimes[0][1] = 100;
    matrix.baseTimes[1][0] = 100;

    const result = sweepOrigin(&goods, cfg, 0, matrix);

    // Only the eligible Good got a slot — the excluded one never appears
    // anywhere in the matrix (not even as an unreachable placeholder).
    try std.testing.expectEqual(@as(u8, 1), result.good_count);
    try std.testing.expectEqual(@as(usize, 0), result.cells[0][0][1].good_idx);
}

test "sweepOrigin cell unreachable: no owned Transport can carry the Good" {
    const goods = [_]goods_mod.Good{
        makeGood("TooHeavy", 100_000, 1, 1), // heavier than any owned Transport's capacity
    };

    var cfg = config_mod.Config{};
    cfg.transports.wagon = true; // cap=900 — primaryQty(100_000, 1, wagon, 0) = 0
    cfg.thresholds[0] = 100;
    cfg.thresholdCount = 1;

    var matrix = makeUniformMatrix(100_000, 0);
    matrix.baseTimes[0][1] = 100;
    matrix.baseTimes[1][0] = 100;

    const result = sweepOrigin(&goods, cfg, 0, matrix);

    try std.testing.expectEqual(@as(u8, 1), result.good_count);
    const cell = result.cells[0][0][1];
    try std.testing.expect(!cell.reachable);
    // Still present in the matrix, not omitted — good_idx/threshold/destination
    // identify exactly which combination this placeholder covers.
    try std.testing.expectEqual(@as(usize, 0), cell.good_idx);
    try std.testing.expectEqual(@as(u32, 100), cell.threshold);
    try std.testing.expectEqual(@as(usize, 1), cell.destination_idx);

    // Every cell at threshold[0] is unreachable (only one Good, only one
    // owned Transport, and it can't carry the Good to any Destination) — the
    // compatibility bridge must reflect that with has_result=false, exactly
    // as the pre-Story-4.1 shape did when nothing was found.
    try std.testing.expect(!result.rows[0].has_result);
}

test "sweepOrigin cell unreachable: Destination has no usable route, sibling Destination unaffected" {
    const goods = [_]goods_mod.Good{
        makeGood("OnlyGood", 10, 5, 1),
    };

    var cfg = config_mod.Config{};
    cfg.transports.wagon = true;
    cfg.thresholds[0] = 100;
    cfg.thresholdCount = 1;

    // Destination 1 (dunbarton): zero travel time both ways => effectiveTravelTime <= 0.
    // Destination 2 (bangor): a real, reachable route.
    var matrix = makeUniformMatrix(0, 0);
    matrix.baseTimes[0][2] = 100;
    matrix.baseTimes[2][0] = 100;

    const result = sweepOrigin(&goods, cfg, 0, matrix);

    const unreachable_cell = result.cells[0][0][1];
    try std.testing.expect(!unreachable_cell.reachable);

    const reachable_cell = result.cells[0][0][2];
    try std.testing.expect(reachable_cell.reachable);
    try std.testing.expectEqualStrings("Wagon", reachable_cell.transport_name);
}

test "sweepOrigin multiple thresholds: each cell's ducats_per_min scales independently" {
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

    try std.testing.expectEqual(@as(u8, 3), result.threshold_count);

    // primaryQty(weight=10, qty=5, wagon cap=900 slots=7, mods=0) = min(90,35) = 35
    // ducats/min = threshold * 35 * 60 * 1.9 / 100 = threshold * 39.9
    const expected = [_]struct { t_idx: usize, ducats: f64 }{
        .{ .t_idx = 0, .ducats = 1995.0 },
        .{ .t_idx = 1, .ducats = 3990.0 },
        .{ .t_idx = 2, .ducats = 7980.0 },
    };
    for (expected) |exp| {
        const cell = result.cells[0][exp.t_idx][1];
        try std.testing.expect(cell.reachable);
        try std.testing.expectApproxEqAbs(exp.ducats, cell.ducats_per_min, 0.01);
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

    const cell = result.cells[0][0][1];
    try std.testing.expect(cell.reachable);
    // primaryQty(weight=10, qty=5, wagon cap=1000 slots=8, mods=1) = min(100,40) = 40
    try std.testing.expectApproxEqAbs(@as(f64, 4560.0), cell.ducats_per_min, 0.01);
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

    const cell = result.cells[0][0][1];
    try std.testing.expect(cell.reachable);
    // primaryQty(weight=10, qty=5, wagon cap=1100 slots=9, mods=2) = min(110,45) = 45
    try std.testing.expectApproxEqAbs(@as(f64, 5130.0), cell.ducats_per_min, 0.01);
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

    try std.testing.expectEqual(@as(u8, 10), config_mod.merchantRatingAt(ratings, 0)); // tirChonaill
    try std.testing.expectEqual(@as(u8, 20), config_mod.merchantRatingAt(ratings, 1)); // dunbarton
    try std.testing.expectEqual(@as(u8, 30), config_mod.merchantRatingAt(ratings, 2)); // bangor
    try std.testing.expectEqual(@as(u8, 60), config_mod.merchantRatingAt(ratings, 3)); // emainMacha
    try std.testing.expectEqual(@as(u8, 70), config_mod.merchantRatingAt(ratings, 4)); // taillteann
    try std.testing.expectEqual(@as(u8, 50), config_mod.merchantRatingAt(ratings, 5)); // tara
    try std.testing.expectEqual(@as(u8, 40), config_mod.merchantRatingAt(ratings, 6)); // cobh
    try std.testing.expectEqual(@as(u8, 80), config_mod.merchantRatingAt(ratings, 7)); // belvast
    try std.testing.expectEqual(@as(u8, 90), config_mod.merchantRatingAt(ratings, 8)); // qilla
    try std.testing.expectEqual(@as(u8, 110), config_mod.merchantRatingAt(ratings, 9)); // filia
    try std.testing.expectEqual(@as(u8, 100), config_mod.merchantRatingAt(ratings, 10)); // cor
    try std.testing.expectEqual(@as(u8, 120), config_mod.merchantRatingAt(ratings, 11)); // vales
}

// ── Per-Good bound (Story 4.1) ───────────────────────────────────────────────

test "sweepOrigin per-Good bound: 9 eligible Goods, only the first 8 are swept" {
    var goods: [9]goods_mod.Good = undefined;
    for (&goods) |*g| {
        // Name is never inspected by sweepOrigin or by this test's
        // assertions (only weight/quantityPerSlot/merchantRating matter for
        // the sweep, and good_idx — not name — identifies each Good below).
        g.* = makeGood("Good", 10, 5, 1);
    }

    var cfg = config_mod.Config{};
    cfg.transports.wagon = true;
    cfg.thresholds[0] = 100;
    cfg.thresholdCount = 1;

    var matrix = makeUniformMatrix(100_000, 0);
    matrix.baseTimes[0][1] = 100;
    matrix.baseTimes[1][0] = 100;

    const result = sweepOrigin(&goods, cfg, 0, matrix);

    try std.testing.expectEqual(@as(u8, MAX_GOODS), result.good_count);

    // Slots 0..7 map to raw good_idx 0..7 (insertion order); the 9th Good
    // (raw index 8) never appears anywhere in the matrix.
    for (0..MAX_GOODS) |slot| {
        try std.testing.expectEqual(slot, result.cells[slot][0][1].good_idx);
    }
    for (0..MAX_GOODS) |slot| {
        for (0..config_mod.MAX_THRESHOLDS) |t| {
            for (0..12) |d| {
                try std.testing.expect(result.cells[slot][t][d].good_idx != 8);
            }
        }
    }
}

// ── Transport coverage (all 8 owned Transports actually evaluated) ─────────
//
// Every case below uses a single eligible Good, threshold=100, base_time=100
// on the only reachable destination, so ducats_per_min reduces to
// `qty * 60 * speed_factor` — letting each assertion double as a check that
// the sweep actually reached that Transport's TRANSPORT_STATS entry.

test "sweepOrigin backpack transport actually evaluated for an eligible Good" {
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
    const cell = result.cells[0][0][1];

    try std.testing.expect(cell.reachable);
    try std.testing.expectEqualStrings("Backpack", cell.transport_name);
    // primaryQty(weight=10, qty=5, backpack cap=400 slots=4, mods=0) = min(40,20) = 20
    try std.testing.expectApproxEqAbs(@as(f64, 1092.0), cell.ducats_per_min, 0.01);
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
    const cell = result.cells[0][0][1];

    try std.testing.expect(cell.reachable);
    try std.testing.expectEqualStrings("Handcart", cell.transport_name);
    // primaryQty(weight=10, qty=5, handcart cap=800 slots=6, mods=0) = min(80,30) = 30
    try std.testing.expectApproxEqAbs(@as(f64, 1800.0), cell.ducats_per_min, 0.01);
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
    const cell = result.cells[0][0][1];

    try std.testing.expect(cell.reachable);
    try std.testing.expectEqualStrings("Pack Elephant", cell.transport_name);
    // primaryQty(weight=10, qty=5, packElephant cap=1700 slots=7, mods=0) = min(170,35) = 35
    try std.testing.expectApproxEqAbs(@as(f64, 2877.0), cell.ducats_per_min, 0.01);
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
    const cell = result.cells[0][0][1];

    try std.testing.expect(cell.reachable);
    try std.testing.expectEqualStrings("Alpaca", cell.transport_name);
    // primaryQty(weight=10, qty=5, alpaca cap=1100 slots=10, mods=0) = min(110,50) = 50
    try std.testing.expectApproxEqAbs(@as(f64, 5700.0), cell.ducats_per_min, 0.01);
}

test "sweepOrigin dogSled transport matches TRANSPORT_STATS" {
    const goods = [_]goods_mod.Good{
        makeGood("OnlyGood", 10, 5, 1),
    };

    var cfg = config_mod.Config{};
    cfg.transports.dogSled = true;
    cfg.thresholds[0] = 100;
    cfg.thresholdCount = 1;

    var matrix = makeUniformMatrix(100_000, 0);
    matrix.baseTimes[0][1] = 100;
    matrix.baseTimes[1][0] = 100;

    const result = sweepOrigin(&goods, cfg, 0, matrix);
    const cell = result.cells[0][0][1];

    try std.testing.expect(cell.reachable);
    try std.testing.expectEqualStrings("Dog Sled", cell.transport_name);
    // primaryQty(weight=10, qty=5, dogSled cap=700 slots=11, mods=0) = min(70,55) = 55
    // ducats/min = 55 * 60 * 1.86 = 6138.0
    try std.testing.expectApproxEqAbs(@as(f64, 6138.0), cell.ducats_per_min, 0.01);
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
    const cell = result.cells[0][0][1];

    try std.testing.expect(cell.reachable);
    try std.testing.expectEqualStrings("Camel", cell.transport_name);
    // primaryQty(weight=10, qty=5, camel cap=1400 slots=7, mods=0) = min(140,35) = 35
    try std.testing.expectApproxEqAbs(@as(f64, 4515.0), cell.ducats_per_min, 0.01);
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
    const cell = result.cells[0][0][1];

    try std.testing.expect(cell.reachable);
    try std.testing.expectEqualStrings("Trader's Skiff", cell.transport_name);
    // primaryQty(weight=10, qty=5, tradersSkiff cap=1200 slots=8, mods=0) = min(120,40) = 40
    try std.testing.expectApproxEqAbs(@as(f64, 5760.0), cell.ducats_per_min, 0.01);
}

// ── updateCache tests (Story 2.4 Matrix Test Audit gap — rows 2, 3, 5; reshaped
// to heap-boxed pointers + allocator param by Story 4.1) ───────────────────

/// A value real `sweepOrigin` output could never produce for the test configs
/// below — used to detect whether updateCache left an existing slot untouched.
fn sentinelResult() OriginResult {
    var r = OriginResult{
        .cells = zeroCells(),
        .good_count = 200, // out of range for any real sweepOrigin call (max MAX_GOODS)
        .threshold_count = 0,
        .rows = zeroRows(),
        .count = 200, // out of range for any real sweepOrigin call (max 32)
    };
    r.rows[0].threshold = 424242;
    r.rows[0].ducats_per_min = 999999.0;
    return r;
}

/// Destroys every non-null cache slot via `allocator` and nulls it — test
/// teardown helper so populated slots never leak past a test's end, since
/// `std.testing.allocator`'s leak check runs once across the whole binary.
fn destroyCache(cache: *[12]?*OriginResult, allocator: std.mem.Allocator) void {
    for (cache) |*slot| {
        if (slot.*) |ptr| {
            allocator.destroy(ptr);
            slot.* = null;
        }
    }
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
    const allocator = std.testing.allocator;

    var goods_map = goods_mod.GoodsMap.init(allocator);
    defer goods_map.deinit();
    var goods_list = [_]goods_mod.Good{makeGood("OnlyGood", 10, 5, 1)};
    try goods_map.put("tirChonaill", goods_list[0..]);

    const cfg = makeTestCfg("tirChonaill");
    const matrix = makeUniformMatrix(100, 0);

    var cache = [_]?*OriginResult{null} ** 12;
    defer destroyCache(&cache, allocator);
    const sentinel_box = try allocator.create(OriginResult);
    sentinel_box.* = sentinelResult();
    cache[0] = sentinel_box;
    var stale = false;

    updateCache(&cache, &stale, cfg, goods_map, matrix, allocator);

    // Slot untouched — sweepOrigin was never re-triggered for it.
    try std.testing.expect(cache[0] != null);
    try std.testing.expectEqual(sentinel_box, cache[0].?);
    try std.testing.expectEqual(@as(u8, 200), cache[0].?.count);
    try std.testing.expectEqual(@as(u32, 424242), cache[0].?.rows[0].threshold);
    try std.testing.expectApproxEqAbs(@as(f64, 999999.0), cache[0].?.rows[0].ducats_per_min, 0.01);

    // No other slot was ever populated.
    for (cache[1..]) |slot| try std.testing.expect(slot == null);
    try std.testing.expect(!stale);
}

test "updateCache row 3: stale=true destroys and clears all 12 slots, recomputes only current Origin" {
    const allocator = std.testing.allocator;

    var goods_map = goods_mod.GoodsMap.init(allocator);
    defer goods_map.deinit();
    var goods_list = [_]goods_mod.Good{makeGood("OnlyGood", 10, 5, 1)};
    try goods_map.put("dunbarton", goods_list[0..]);

    const cfg = makeTestCfg("dunbarton"); // OUTPOST_KEYS index 1
    var matrix = makeUniformMatrix(100_000, 0);
    matrix.baseTimes[1][0] = 100;
    matrix.baseTimes[0][1] = 100;

    var cache = [_]?*OriginResult{null} ** 12;
    defer destroyCache(&cache, allocator);
    for (&cache) |*slot| {
        const boxed = try allocator.create(OriginResult);
        boxed.* = sentinelResult();
        slot.* = boxed;
    }
    var stale = true;

    updateCache(&cache, &stale, cfg, goods_map, matrix, allocator);

    try std.testing.expect(!stale);

    // Every slot except the current Origin's (idx 1) must be null — the
    // sentinel that was there before the clear must be gone (destroyed)
    // everywhere else.
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
    const allocator = std.testing.allocator;

    var cache = [_]?*OriginResult{null} ** 12;
    defer destroyCache(&cache, allocator);
    const sentinel_box = try allocator.create(OriginResult);
    sentinel_box.* = sentinelResult();
    cache[0] = sentinel_box;
    var stale = false;

    // cfg = null entirely.
    updateCache(&cache, &stale, null, null, null, allocator);
    try std.testing.expect(cache[0] != null);
    try std.testing.expectEqual(@as(u8, 200), cache[0].?.count);
    for (cache[1..]) |slot| try std.testing.expect(slot == null);

    // cfg present but origin == "" (pre-wizard).
    const cfg = config_mod.Config{}; // default origin is ""
    updateCache(&cache, &stale, cfg, null, null, allocator);
    try std.testing.expect(cache[0] != null);
    try std.testing.expectEqual(@as(u8, 200), cache[0].?.count);
    for (cache[1..]) |slot| try std.testing.expect(slot == null);

    try std.testing.expect(!stale);
}

test "updateCache goods_map missing (route_matrix present) returns without touching cache" {
    const allocator = std.testing.allocator;

    const cfg = makeTestCfg("tirChonaill");
    const matrix = makeUniformMatrix(100, 0);

    var cache = [_]?*OriginResult{null} ** 12;
    defer destroyCache(&cache, allocator);
    const sentinel_box = try allocator.create(OriginResult);
    sentinel_box.* = sentinelResult();
    cache[0] = sentinel_box;
    var stale = false;

    updateCache(&cache, &stale, cfg, null, matrix, allocator);

    // No goods_map => early return before the cache slot lookup; untouched, no crash.
    try std.testing.expect(cache[0] != null);
    try std.testing.expectEqual(@as(u8, 200), cache[0].?.count);
    for (cache[1..]) |slot| try std.testing.expect(slot == null);
    try std.testing.expect(!stale);
}

test "updateCache route_matrix missing (goods_map present) returns without touching cache" {
    const allocator = std.testing.allocator;

    var goods_map = goods_mod.GoodsMap.init(allocator);
    defer goods_map.deinit();
    var goods_list = [_]goods_mod.Good{makeGood("OnlyGood", 10, 5, 1)};
    try goods_map.put("tirChonaill", goods_list[0..]);

    const cfg = makeTestCfg("tirChonaill");

    var cache = [_]?*OriginResult{null} ** 12;
    defer destroyCache(&cache, allocator);
    const sentinel_box = try allocator.create(OriginResult);
    sentinel_box.* = sentinelResult();
    cache[0] = sentinel_box;
    var stale = false;

    updateCache(&cache, &stale, cfg, goods_map, null, allocator);

    // No route_matrix => early return before the cache slot lookup; untouched, no crash.
    try std.testing.expect(cache[0] != null);
    try std.testing.expectEqual(@as(u8, 200), cache[0].?.count);
    for (cache[1..]) |slot| try std.testing.expect(slot == null);
    try std.testing.expect(!stale);
}

test "updateCache stale-clear frees every populated slot via the passed allocator (GPA leak check)" {
    const allocator = std.testing.allocator;

    var cache = [_]?*OriginResult{null} ** 12;
    for (&cache) |*slot| {
        const boxed = try allocator.create(OriginResult);
        boxed.* = sentinelResult();
        slot.* = boxed;
    }
    var stale = true;

    // cfg=null: the stale-clear runs unconditionally, then the function
    // returns early (no recompute) — every one of the 12 populated slots
    // above must still be destroyed via `allocator`, or std.testing.allocator
    // reports a leak for the whole test binary at exit.
    updateCache(&cache, &stale, null, null, null, allocator);

    try std.testing.expect(!stale);
    for (cache) |slot| try std.testing.expect(slot == null);
}
