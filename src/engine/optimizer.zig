const std = @import("std");
const config = @import("../data/config.zig");

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
