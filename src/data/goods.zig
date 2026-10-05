const std = @import("std");
const embedded_assets = @import("embedded_assets");

pub const Good = struct {
    name: []const u8,
    description: []const u8,
    image: []const u8,
    weight: u32,
    quantityPerSlot: u32,
    cost: u32,
    merchantRating: u32,
};

/// Keys are town names (e.g. "tirChonaill"), values are slices of Good.
pub const GoodsMap = std.StringHashMap([]Good);

const DEFAULT_GOODS_JSON: []const u8 = embedded_assets.DEFAULT_GOODS_JSON;

pub const max_file_size = 4 * 1024 * 1024; // 4 MiB

/// Load goods.json from exe_dir.  Returns a GoodsMap whose keys and Good
/// string fields are all allocated from `allocator`.  Caller owns the result
/// and must call deinitGoodsMap to free it.
pub fn loadGoods(allocator: std.mem.Allocator, exe_dir: []const u8) !GoodsMap {
    const path = try std.fs.path.join(allocator, &.{ exe_dir, "goods.json" });
    defer allocator.free(path);

    const text = try std.fs.cwd().readFileAlloc(allocator, path, max_file_size);
    defer allocator.free(text);

    return parseGoods(allocator, text);
}

fn parseGoods(allocator: std.mem.Allocator, text: []const u8) !GoodsMap {
    // Parse into a generic JSON value first so we can iterate object keys.
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        text,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    if (parsed.value != .object) return error.BadType;
    const root = parsed.value.object;

    var map = GoodsMap.init(allocator);
    errdefer deinitGoodsMap(&map, allocator);

    var it = root.iterator();
    while (it.next()) |entry| {
        const town_key = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(town_key);

        if (entry.value_ptr.* != .array) return error.BadType;
        const arr = entry.value_ptr.array;
        const goods = try allocator.alloc(Good, arr.items.len);
        // Tracks how many leading entries of `goods` are fully populated —
        // on an error partway through this town's array, only those (not
        // the whole backing slice) have live string allocations to free.
        var filled: usize = 0;
        errdefer {
            for (goods[0..filled]) |g| {
                allocator.free(g.name);
                allocator.free(g.description);
                allocator.free(g.image);
            }
            allocator.free(goods);
        }

        for (arr.items, 0..) |item, i| {
            if (item != .object) return error.BadType;
            const obj = item.object;

            // String fields — check key presence and tag before accessing.
            const name_val = if (obj.get("name")) |v| v else return error.MissingField;
            if (name_val != .string) return error.BadType;
            const desc_val = if (obj.get("description")) |v| v else return error.MissingField;
            if (desc_val != .string) return error.BadType;
            const image_val = if (obj.get("image")) |v| v else return error.MissingField;
            if (image_val != .string) return error.BadType;

            // Integer fields — check key presence, tag, then cast safely.
            const weight_val = if (obj.get("weight")) |v| v else return error.MissingField;
            if (weight_val != .integer) return error.BadType;
            const qty_val = if (obj.get("quantityPerSlot")) |v| v else return error.MissingField;
            if (qty_val != .integer) return error.BadType;
            const cost_val = if (obj.get("cost")) |v| v else return error.MissingField;
            if (cost_val != .integer) return error.BadType;
            const rating_val = if (obj.get("merchantRating")) |v| v else return error.MissingField;
            if (rating_val != .integer) return error.BadType;

            // Dupe each string field into a named local (not directly into
            // the struct literal) so a failure partway through this item's
            // three dupes, or through a later integer cast in the same
            // literal (e.g. weight overflowing u32 after name/description/
            // image already duped), frees what already succeeded via the
            // errdefers below instead of leaking it — the outer errdefer
            // above only knows about `filled` *whole* items, not an
            // in-flight partial one. Mirrors live_profits.zig's identical
            // pattern (loadLiveProfitsInner).
            const name_dup = try allocator.dupe(u8, name_val.string);
            errdefer allocator.free(name_dup);
            const desc_dup = try allocator.dupe(u8, desc_val.string);
            errdefer allocator.free(desc_dup);
            const image_dup = try allocator.dupe(u8, image_val.string);
            errdefer allocator.free(image_dup);

            goods[i] = Good{
                .name = name_dup,
                .description = desc_dup,
                .image = image_dup,
                .weight = std.math.cast(u32, weight_val.integer) orelse return error.Overflow,
                .quantityPerSlot = std.math.cast(u32, qty_val.integer) orelse return error.Overflow,
                .cost = std.math.cast(u32, cost_val.integer) orelse return error.Overflow,
                .merchantRating = std.math.cast(u32, rating_val.integer) orelse return error.Overflow,
            };
            filled = i + 1;
        }

        try map.put(town_key, goods);
    }

    return map;
}

/// Free all memory owned by a GoodsMap produced by loadGoods.
pub fn deinitGoodsMap(map: *GoodsMap, allocator: std.mem.Allocator) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        for (entry.value_ptr.*) |g| {
            allocator.free(g.name);
            allocator.free(g.description);
            allocator.free(g.image);
        }
        allocator.free(entry.value_ptr.*);
        allocator.free(entry.key_ptr.*);
    }
    map.deinit();
}

/// Write the embedded default goods.json to exe_dir/goods.json.
pub fn restoreGoods(allocator: std.mem.Allocator, exe_dir: []const u8) !void {
    const out_path = try std.fs.path.join(allocator, &.{ exe_dir, "goods.json" });
    defer allocator.free(out_path);
    try std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = DEFAULT_GOODS_JSON });
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "parseGoods: malformed later item does not leak the earlier item's duped strings" {
    const text =
        \\{
        \\  "tirChonaill": [
        \\    {"name":"Fish","description":"d","image":"i.png","weight":1,"quantityPerSlot":1,"cost":1,"merchantRating":1},
        \\    {"name":"Herb","description":"d","weight":1,"quantityPerSlot":1,"cost":1,"merchantRating":1}
        \\  ]
        \\}
    ;
    try std.testing.expectError(error.MissingField, parseGoods(std.testing.allocator, text));
}

test "parseGoods: non-object top-level JSON returns error.BadType" {
    try std.testing.expectError(error.BadType, parseGoods(std.testing.allocator, "[]"));
}

test "parseGoods: non-array town value returns error.BadType" {
    try std.testing.expectError(error.BadType, parseGoods(std.testing.allocator, "{\"tirChonaill\":\"oops\"}"));
}

test "parseGoods: non-object array item returns error.BadType" {
    try std.testing.expectError(error.BadType, parseGoods(std.testing.allocator, "{\"tirChonaill\":[42]}"));
}

test "DEFAULT_GOODS_JSON (the embedded Restore Defaults fallback) parses successfully" {
    // restoreGoods() writes this verbatim; retryAfterRestore() then reloads
    // it through this exact parseGoods() path. If the embedded asset ever
    // drifted out of shape (wrong @embedFile target, a hand-edit that broke
    // its JSON shape), "Restore Defaults" would silently fail to recover —
    // this guards that the one in-app recovery mechanism actually works.
    var map = try parseGoods(std.testing.allocator, DEFAULT_GOODS_JSON);
    defer deinitGoodsMap(&map, std.testing.allocator);
}

test "parseGoods: well-formed multi-item town parses cleanly" {
    const text =
        \\{
        \\  "tirChonaill": [
        \\    {"name":"Fish","description":"d1","image":"f.png","weight":1,"quantityPerSlot":5,"cost":10,"merchantRating":1},
        \\    {"name":"Herb","description":"d2","image":"h.png","weight":2,"quantityPerSlot":3,"cost":20,"merchantRating":2}
        \\  ]
        \\}
    ;
    var map = try parseGoods(std.testing.allocator, text);
    defer deinitGoodsMap(&map, std.testing.allocator);

    const goods = map.get("tirChonaill").?;
    try std.testing.expectEqual(@as(usize, 2), goods.len);
    try std.testing.expectEqualStrings("Fish", goods[0].name);
    try std.testing.expectEqualStrings("Herb", goods[1].name);
}
