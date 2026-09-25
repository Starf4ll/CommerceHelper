const std = @import("std");
const config = @import("../data/config.zig");
const goods_mod = @import("../data/goods.zig");

/// Returns the maximum number of units of a good a transport can carry,
/// accounting for active modifiers (commerce partner and/or grandmaster title).
/// modifier_count: 0, 1, or 2 — total count of active +1 bonuses.
pub fn primaryQty(weight: u32, qty_per_slot: u32, transport: config.Transport, modifier_count: u2) u32 {
    std.debug.assert(weight > 0);
    std.debug.assert(modifier_count <= 2);
    const effective_cap = transport.weightCapacity + @as(u32, modifier_count) * 100;
    const effective_slots = transport.slotCount + @as(u32, modifier_count);
    return @min(effective_cap / weight, effective_slots * qty_per_slot);
}

/// Returns the combined discount percent (integer) from merchant rating tier
/// and equipped gear discount.
/// merchant_rating: 1–9; gear_discount: percent points from gear.
pub fn effectiveDiscount(merchant_rating: u8, gear_discount: u32) u32 {
    const rating_discount: u32 = if (merchant_rating >= 9)
        3
    else if (merchant_rating >= 7)
        2
    else if (merchant_rating >= 5)
        1
    else
        0;
    return rating_discount + gear_discount;
}

/// A single secondary-good fill result: which good and how many units to carry.
pub const FillEntry = struct { good_idx: usize, qty: u32 };

/// Greedy fill of remaining transport capacity with secondary goods, ranked by
/// profit-per-slot (profits[i] × quantityPerSlot) descending.
/// Ties broken by weight ascending, then name ascending (alphabetical).
///
/// - goods:        full goods slice for the origin (caller owns)
/// - primary_idx:  index of the already-placed primary good (excluded)
/// - primary_qty:  units of primary good already loaded
/// - transport:    transport stats (capacity, slots, speed)
/// - modifier_count: 0–2 active +1 bonuses (commerce partner / grandmaster)
/// - profits:      per-unit profit for each good at the target destination;
///                 profits[i] == 0 means skip good i; if `i >= profits.len`,
///                 good `i` is also skipped (treated as zero-profit)
/// - out:          caller-provided output buffer; length caps the fill count
///
/// Returns the number of FillEntry values written to out.
pub fn mixedLoadFill(
    goods: []const goods_mod.Good,
    primary_idx: usize,
    primary_qty: u32,
    transport: config.Transport,
    modifier_count: u2,
    profits: []const u32,
    out: []FillEntry,
) usize {
    std.debug.assert(modifier_count <= 2);
    const effective_cap = transport.weightCapacity + @as(u32, modifier_count) * 100;
    const effective_slots = transport.slotCount + @as(u32, modifier_count);

    const primary_good = &goods[primary_idx];
    std.debug.assert(primary_good.quantityPerSlot > 0);
    const primary_slots_used = (primary_qty + primary_good.quantityPerSlot - 1) / primary_good.quantityPerSlot;

    std.debug.assert(primary_qty * primary_good.weight <= effective_cap);
    var remaining_weight: u32 = effective_cap - primary_qty * primary_good.weight;
    var remaining_slots: u32 = effective_slots - primary_slots_used;

    // Build a local index array of candidates (stack-allocated; 64 > any realistic goods count).
    var candidate_buf: [64]usize = undefined;
    var candidate_count: usize = 0;

    for (goods, 0..) |_, i| {
        if (i == primary_idx) continue;
        if (i >= profits.len or profits[i] == 0) continue;
        std.debug.assert(candidate_count < candidate_buf.len);
        candidate_buf[candidate_count] = i;
        candidate_count += 1;
    }

    const candidates = candidate_buf[0..candidate_count];

    // Sort by profit-per-slot descending, tie-break weight ascending, tie-break name ascending.
    const SortCtx = struct {
        g: []const goods_mod.Good,
        p: []const u32,

        fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            const pps_a = ctx.p[a] * ctx.g[a].quantityPerSlot;
            const pps_b = ctx.p[b] * ctx.g[b].quantityPerSlot;
            if (pps_a != pps_b) return pps_a > pps_b; // descending profit-per-slot
            if (ctx.g[a].weight != ctx.g[b].weight) return ctx.g[a].weight < ctx.g[b].weight; // ascending weight
            return std.mem.lessThan(u8, ctx.g[a].name, ctx.g[b].name); // ascending name
        }
    };
    std.mem.sort(usize, candidates, SortCtx{ .g = goods, .p = profits }, SortCtx.lessThan);

    var written: usize = 0;
    for (candidates) |i| {
        if (written >= out.len) break;
        if (remaining_slots == 0 or remaining_weight == 0) break;

        const good = &goods[i];
        std.debug.assert(good.weight > 0);
        std.debug.assert(good.quantityPerSlot > 0);
        const qty_by_slots: u32 = remaining_slots * good.quantityPerSlot;
        const qty_by_weight: u32 = remaining_weight / good.weight;
        const raw_qty = @min(qty_by_slots, qty_by_weight);
        // Round down to nearest complete slot.
        const qty = (raw_qty / good.quantityPerSlot) * good.quantityPerSlot;
        if (qty == 0) continue;

        out[written] = .{ .good_idx = i, .qty = qty };
        written += 1;

        remaining_weight -= qty * good.weight;
        const slots_used = (qty + good.quantityPerSlot - 1) / good.quantityPerSlot;
        remaining_slots -= slots_used;
    }

    return written;
}

/// Converts a base land travel time into an effective (speed-scaled) travel
/// time, returned in seconds (f64).
///
/// - base_land_time: raw land segment time in seconds
/// - boat_time:      flat boat segment time in seconds; added after speed
///                   scaling — the boat segment is unaffected by `speed_factor`
///                   and `speed_bonus`
/// - speed_factor:   transport speed multiplier (e.g. 1.90 for Wagon)
/// - speed_bonus:    percent points from player gear/title (e.g. 10 for +10%)
pub fn effectiveTravelTime(
    base_land_time: u32,
    boat_time: u32,
    speed_factor: f64,
    speed_bonus: u32,
) f64 {
    std.debug.assert(speed_factor > 0.0);
    const land: f64 = @as(f64, @floatFromInt(base_land_time));
    const boat: f64 = @as(f64, @floatFromInt(boat_time));
    const bonus_mult: f64 = 1.0 + @as(f64, @floatFromInt(speed_bonus)) / 100.0;
    return land / (speed_factor * bonus_mult) + boat;
}

test "primaryQty weight-bound: Wagon cap=900, weight=100, qty=5, mods=0 → 9" {
    const wagon = config.TRANSPORT_STATS.wagon;
    try std.testing.expectEqual(@as(u32, 9), primaryQty(100, 5, wagon, 0));
}

test "primaryQty slot-bound: PackElephant cap=1700, weight=10, qty=2, mods=0 → 14" {
    const pe = config.TRANSPORT_STATS.packElephant;
    try std.testing.expectEqual(@as(u32, 14), primaryQty(10, 2, pe, 0));
}

test "primaryQty +1 modifier: Wagon weight=100, qty=5 → 10" {
    const wagon = config.TRANSPORT_STATS.wagon;
    try std.testing.expectEqual(@as(u32, 10), primaryQty(100, 5, wagon, 1));
}

test "primaryQty +2 modifiers: Wagon weight=100, qty=5 → 11" {
    const wagon = config.TRANSPORT_STATS.wagon;
    try std.testing.expectEqual(@as(u32, 11), primaryQty(100, 5, wagon, 2));
}

test "effectiveDiscount rating 1-4: rating=3 gear=5 → 5" {
    try std.testing.expectEqual(@as(u32, 5), effectiveDiscount(3, 5));
}

test "effectiveDiscount rating 5-6: rating=6 gear=2 → 3" {
    try std.testing.expectEqual(@as(u32, 3), effectiveDiscount(6, 2));
}

test "effectiveDiscount rating 7-8: rating=7 gear=0 → 2" {
    try std.testing.expectEqual(@as(u32, 2), effectiveDiscount(7, 0));
}

test "effectiveDiscount rating 9: rating=9 gear=3 → 6" {
    try std.testing.expectEqual(@as(u32, 6), effectiveDiscount(9, 3));
}

// ── Story 2.3 tests: effectiveTravelTime ─────────────────────────────────────

test "effectiveTravelTime speed-only land: base=600 boat=0 factor=1.90 bonus=10 → ≈287.08" {
    const result = effectiveTravelTime(600, 0, 1.90, 10);
    try std.testing.expectApproxEqAbs(@as(f64, 287.08), result, 0.01);
}

test "effectiveTravelTime with boat leg: base=300 boat=120 factor=1.00 bonus=0 → 420.0" {
    const result = effectiveTravelTime(300, 120, 1.00, 0);
    try std.testing.expectEqual(@as(f64, 420.0), result);
}

test "effectiveTravelTime zero speed bonus: base=500 boat=0 factor=2.15 bonus=0 → ≈232.56" {
    const result = effectiveTravelTime(500, 0, 2.15, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 232.56), result, 0.01);
}

// ── Story 2.3 tests: mixedLoadFill ───────────────────────────────────────────

// Helper: build a minimal Good for testing (description, image unused by optimizer).
fn makeGood(name: []const u8, weight: u32, qty_per_slot: u32) goods_mod.Good {
    return .{
        .name = name,
        .description = "",
        .image = "",
        .weight = weight,
        .quantityPerSlot = qty_per_slot,
        .cost = 0,
        .merchantRating = 1,
    };
}

test "mixedLoadFill no remaining capacity → returns 0" {
    // Transport cap=900 slots=9; primary good weight=100 qtyPerSlot=1, qty=9
    // → fills weight fully (9×100=900) and uses 9 slots (all slots).
    // remaining_weight=0, remaining_slots=0 → no secondaries can fit.
    const transport = config.Transport{ .weightCapacity = 900, .slotCount = 9, .speedFactor = 1.0 };
    const goods = [_]goods_mod.Good{
        makeGood("A", 100, 1),
    };
    const profits = [_]u32{50};
    var out: [8]FillEntry = undefined;
    const count = mixedLoadFill(&goods, 0, 9, transport, 0, &profits, &out);
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "mixedLoadFill single secondary fits exactly" {
    // remaining_weight=200, remaining_slots=2; good A: profit=50, weight=100, qtyPerSlot=1
    // Primary is a dummy at index 0 using 0 weight and 5 slots of a synthetic transport.
    // Use a custom transport: cap=200, slots=7, speed=1.0; primary: weight=0 qty_per_slot=5, qty=0.
    // Actually: primary_qty=0 means primary_slots_used=0. remaining_weight=200, remaining_slots=7.
    // We need remaining_slots=2 and remaining_weight=200. Use cap=200 slots=2.
    const transport = config.Transport{ .weightCapacity = 200, .slotCount = 2, .speedFactor = 1.0 };
    // Primary at index 0: weight=0 → but weight must be > 0 for primaryQty; use weight=1, qty=0.
    // primary_qty=0, primary_slots_used=ceil(0/1)=0. remaining_weight=200, remaining_slots=2.
    const goods = [_]goods_mod.Good{
        makeGood("Primary", 1, 1), // index 0, primary
        makeGood("A", 100, 1),     // index 1, secondary
    };
    const profits = [_]u32{ 0, 50 };
    var out: [8]FillEntry = undefined;
    const count = mixedLoadFill(&goods, 0, 0, transport, 0, &profits, &out);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(usize, 1), out[0].good_idx);
    try std.testing.expectEqual(@as(u32, 2), out[0].qty);
}

test "mixedLoadFill weight rounds down to slot boundary" {
    // remaining_weight=250, remaining_slots=3; good A: weight=100, qtyPerSlot=2
    // qty_by_weight = 250/100=2; qty_by_slots=3*2=6; raw=min(6,2)=2
    // slot-round: (2/2)*2=2 units → 1 slot; writes [{A,2}]
    const transport = config.Transport{ .weightCapacity = 250, .slotCount = 3, .speedFactor = 1.0 };
    const goods = [_]goods_mod.Good{
        makeGood("Primary", 1, 1),
        makeGood("A", 100, 2),
    };
    const profits = [_]u32{ 0, 50 };
    var out: [8]FillEntry = undefined;
    const count = mixedLoadFill(&goods, 0, 0, transport, 0, &profits, &out);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(usize, 1), out[0].good_idx);
    try std.testing.expectEqual(@as(u32, 2), out[0].qty);
}

test "mixedLoadFill tie-break by weight" {
    // profitPerSlot equal: good X (profit=10, qtyPerSlot=1, weight=10)
    //                      good Y (profit=10, qtyPerSlot=1, weight=20)
    // pps_X = pps_Y = 10; tie-break: X preferred (lower weight)
    const transport = config.Transport{ .weightCapacity = 1000, .slotCount = 2, .speedFactor = 1.0 };
    const goods = [_]goods_mod.Good{
        makeGood("Primary", 1, 1), // index 0
        makeGood("Y", 20, 1),      // index 1
        makeGood("X", 10, 1),      // index 2
    };
    const profits = [_]u32{ 0, 10, 10 };
    var out: [1]FillEntry = undefined;
    const count = mixedLoadFill(&goods, 0, 0, transport, 0, &profits, &out);
    try std.testing.expectEqual(@as(usize, 1), count);
    // X (index 2, weight=10) should be preferred over Y (index 1, weight=20)
    try std.testing.expectEqual(@as(usize, 2), out[0].good_idx);
}

test "mixedLoadFill tie-break by name" {
    // profitPerSlot equal, weight equal; 'Zinc' vs 'Copper' → Copper preferred (alphabetical)
    const transport = config.Transport{ .weightCapacity = 1000, .slotCount = 2, .speedFactor = 1.0 };
    const goods = [_]goods_mod.Good{
        makeGood("Primary", 1, 1), // index 0
        makeGood("Zinc", 10, 1),   // index 1
        makeGood("Copper", 10, 1), // index 2
    };
    const profits = [_]u32{ 0, 10, 10 };
    var out: [1]FillEntry = undefined;
    const count = mixedLoadFill(&goods, 0, 0, transport, 0, &profits, &out);
    try std.testing.expectEqual(@as(usize, 1), count);
    // Copper (index 2) < Zinc (index 1) alphabetically → Copper preferred
    try std.testing.expectEqual(@as(usize, 2), out[0].good_idx);
}

test "mixedLoadFill zero-profit good skipped" {
    const transport = config.Transport{ .weightCapacity = 500, .slotCount = 5, .speedFactor = 1.0 };
    const goods = [_]goods_mod.Good{
        makeGood("Primary", 1, 1),
        makeGood("ZeroProfitGood", 50, 1),
        makeGood("ProfitGood", 50, 1),
    };
    const profits = [_]u32{ 0, 0, 30 }; // index 1 has zero profit, index 2 has profit
    var out: [8]FillEntry = undefined;
    const count = mixedLoadFill(&goods, 0, 0, transport, 0, &profits, &out);
    // Only index 2 should appear
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(usize, 2), out[0].good_idx);
}

test "mixedLoadFill primary_idx excluded even with profit" {
    const transport = config.Transport{ .weightCapacity = 500, .slotCount = 5, .speedFactor = 1.0 };
    const goods = [_]goods_mod.Good{
        makeGood("PrimaryGood", 50, 1), // index 0, primary
        makeGood("SecondaryGood", 50, 1),
    };
    const profits = [_]u32{ 999, 30 }; // primary has high profit but must not appear as secondary
    var out: [8]FillEntry = undefined;
    const count = mixedLoadFill(&goods, 0, 0, transport, 0, &profits, &out);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(usize, 1), out[0].good_idx); // only secondary
}

test "mixedLoadFill acceptance: two candidates A and B" {
    // remaining_weight=500, remaining_slots=4
    // A: profit=40, weight=100, qtyPerSlot=2 → pps=80
    // B: profit=30, weight=50,  qtyPerSlot=1 → pps=30
    // A placed first: qty=min(4×2, 500/100)=min(8,5)=5 → slot-round: (5/2)×2=4 units (2 slots, 200 weight)
    // Remaining: weight=300, slots=2
    // B: qty=min(2×1, 300/50)=min(2,6)=2 → slot-round: 2; deduct 100 weight, 2 slots
    // Result: [{A,4},{B,2}], returns 2
    const transport = config.Transport{ .weightCapacity = 500, .slotCount = 4, .speedFactor = 1.0 };
    const goods = [_]goods_mod.Good{
        makeGood("Primary", 1, 1), // index 0, primary (qty=0)
        makeGood("A", 100, 2),     // index 1
        makeGood("B", 50, 1),      // index 2
    };
    const profits = [_]u32{ 0, 40, 30 };
    var out: [8]FillEntry = undefined;
    const count = mixedLoadFill(&goods, 0, 0, transport, 0, &profits, &out);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(usize, 1), out[0].good_idx); // A
    try std.testing.expectEqual(@as(u32, 4), out[0].qty);
    try std.testing.expectEqual(@as(usize, 2), out[1].good_idx); // B
    try std.testing.expectEqual(@as(u32, 2), out[1].qty);
}

test "mixedLoadFill modifier_count > 0 expands effective capacity" {
    // Wagon: cap=900, slots=7. With modifier_count=1: effectiveCap=1000, effectiveSlots=8.
    // Primary: weight=100, qtyPerSlot=1, qty=9 (fills 900 weight, 9 slots on effective).
    // remaining_weight = 1000 - 900 = 100; remaining_slots = 8 - 9 = ...
    // Wait, 9 slots > effectiveSlots=8 would underflow. Use qty=8 instead:
    // primary_qty=8: weight_used=800, slots_used=8. remaining_weight=200, remaining_slots=0.
    // Still no secondary fits (remaining_slots=0). Let's use qty=7:
    // weight_used=700, slots_used=7. remaining_weight=300, remaining_slots=1.
    // Secondary B: weight=100, qtyPerSlot=1, profit=30.
    // qty = min(1*1, 300/100) = min(1,3) = 1; slot-round: 1. Writes [{B,1}].
    const transport = config.Transport{ .weightCapacity = 900, .slotCount = 7, .speedFactor = 1.0 };
    const goods = [_]goods_mod.Good{
        makeGood("Primary", 100, 1), // index 0
        makeGood("B", 100, 1),       // index 1
    };
    const profits = [_]u32{ 0, 30 };
    var out: [8]FillEntry = undefined;
    // With modifier_count=1: effectiveCap=1000, effectiveSlots=8
    // primary_qty=7: weight_used=700, slots_used=7. remaining=300 weight, 1 slot.
    // B: qty=min(1, 3)=1. Writes [{B,1}].
    const count = mixedLoadFill(&goods, 0, 7, transport, 1, &profits, &out);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(usize, 1), out[0].good_idx);
    try std.testing.expectEqual(@as(u32, 1), out[0].qty);
}

test "mixedLoadFill profits slice shorter than goods slice skips tail" {
    // goods has 3 entries (index 0=primary, 1, 2) but profits only covers indices 0-1.
    // Good at index 2 has i >= profits.len → skipped.
    const transport = config.Transport{ .weightCapacity = 500, .slotCount = 5, .speedFactor = 1.0 };
    const goods = [_]goods_mod.Good{
        makeGood("Primary", 1, 1),
        makeGood("Covered", 50, 1),
        makeGood("Uncovered", 50, 1),
    };
    const profits = [_]u32{ 0, 30 }; // only 2 entries; index 2 is out of range
    var out: [8]FillEntry = undefined;
    const count = mixedLoadFill(&goods, 0, 0, transport, 0, &profits, &out);
    // Only "Covered" (index 1) should appear; "Uncovered" (index 2) is skipped.
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(usize, 1), out[0].good_idx);
}

test "mixedLoadFill zero-length out buffer returns 0" {
    const transport = config.Transport{ .weightCapacity = 500, .slotCount = 5, .speedFactor = 1.0 };
    const goods = [_]goods_mod.Good{
        makeGood("Primary", 1, 1),
        makeGood("A", 50, 1),
    };
    const profits = [_]u32{ 0, 30 };
    var out: [0]FillEntry = undefined;
    const count = mixedLoadFill(&goods, 0, 0, transport, 0, &profits, &out);
    try std.testing.expectEqual(@as(usize, 0), count);
}
