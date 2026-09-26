const std = @import("std");

pub const OUTPOST_KEYS: [12][]const u8 = .{
    "tirChonaill",
    "dunbarton",
    "bangor",
    "cobh",
    "tara",
    "emainMacha",
    "taillteann",
    "belvast",
    "qilla",
    "cor",
    "filia",
    "vales",
};

pub const OUTPOST_DISPLAY_NAMES: [12][]const u8 = .{
    "Tir Chonaill",
    "Dunbarton",
    "Bangor",
    "Cobh",
    "Tara",
    "Emain Macha",
    "Taillteann",
    "Belvast",
    "Qilla",
    "Cor",
    "Filia",
    "Vales",
};

comptime {
    std.debug.assert(OUTPOST_KEYS.len == OUTPOST_DISPLAY_NAMES.len);
}

pub const TransportFlags = struct {
    backpack: bool = false,
    handcart: bool = false,
    wagon: bool = false,
    packElephant: bool = false,
    alpaca: bool = false,
    dogSled: bool = false,
    camel: bool = false,
    tradersSkiff: bool = false,
};

pub const Transport = struct {
    weightCapacity: u32,
    slotCount: u32,
    speedFactor: f64,
};

pub const TransportStatsTable = struct {
    backpack: Transport,
    handcart: Transport,
    wagon: Transport,
    packElephant: Transport,
    alpaca: Transport,
    dogSled: Transport,
    camel: Transport,
    tradersSkiff: Transport,
};

pub const TRANSPORT_STATS: TransportStatsTable = .{
    .backpack = .{ .weightCapacity = 400, .slotCount = 4, .speedFactor = 0.91 },
    .handcart = .{ .weightCapacity = 800, .slotCount = 6, .speedFactor = 1.00 },
    .wagon = .{ .weightCapacity = 900, .slotCount = 7, .speedFactor = 1.90 },
    .packElephant = .{ .weightCapacity = 1700, .slotCount = 7, .speedFactor = 1.37 },
    .alpaca = .{ .weightCapacity = 1100, .slotCount = 10, .speedFactor = 1.90 },
    .dogSled = .{ .weightCapacity = 700, .slotCount = 11, .speedFactor = 1.86 },
    .camel = .{ .weightCapacity = 1400, .slotCount = 7, .speedFactor = 2.15 },
    .tradersSkiff = .{ .weightCapacity = 1200, .slotCount = 8, .speedFactor = 2.40 },
};

pub const MerchantRatings = struct {
    tirChonaill: u8 = 1,
    dunbarton: u8 = 1,
    bangor: u8 = 1,
    cobh: u8 = 1,
    tara: u8 = 1,
    emainMacha: u8 = 1,
    taillteann: u8 = 1,
    belvast: u8 = 1,
    qilla: u8 = 1,
    cor: u8 = 1,
    filia: u8 = 1,
    vales: u8 = 1,
};

pub const MAX_THRESHOLDS: usize = 32;
pub const DEFAULT_THRESHOLDS = [_]u32{ 50, 100, 150, 200, 300, 400, 500, 600, 800, 1000 };

pub const Config = struct {
    origin: []const u8 = "",
    transports: TransportFlags = .{},
    commercePartner: bool = false,
    grandmasterTitle: bool = false,
    merchantRatings: MerchantRatings = .{},
    speedBonus: u32 = 0,
    gearDiscount: u32 = 0,
    thresholds: [MAX_THRESHOLDS]u32 = blk: {
        var arr = [_]u32{0} ** MAX_THRESHOLDS;
        for (DEFAULT_THRESHOLDS, 0..) |v, i| arr[i] = v;
        break :blk arr;
    },
    thresholdCount: u8 = DEFAULT_THRESHOLDS.len,
};

/// Returns the player's Merchant Rating at the given Outpost index (0-11,
/// matching OUTPOST_KEYS order). Reusable Origin-indexed rating lookup.
pub fn merchantRatingAt(ratings: MerchantRatings, outpost_idx: usize) u8 {
    return switch (outpost_idx) {
        0 => ratings.tirChonaill,
        1 => ratings.dunbarton,
        2 => ratings.bangor,
        3 => ratings.cobh,
        4 => ratings.tara,
        5 => ratings.emainMacha,
        6 => ratings.taillteann,
        7 => ratings.belvast,
        8 => ratings.qilla,
        9 => ratings.cor,
        10 => ratings.filia,
        11 => ratings.vales,
        else => unreachable,
    };
}

const max_file_size = 1 * 1024 * 1024; // 1 MiB

/// Load config.json from exe_dir.
/// Returns null if the file is missing or contains invalid JSON — no error
/// dialog, no panic.  The caller treats null as "show the wizard".
pub fn loadConfig(allocator: std.mem.Allocator, exe_dir: []const u8) ?Config {
    const path = std.fs.path.join(allocator, &.{ exe_dir, "config.json" }) catch return null;
    defer allocator.free(path);

    const text = std.fs.cwd().readFileAlloc(allocator, path, max_file_size) catch return null;
    defer allocator.free(text);

    const parsed = std.json.parseFromSlice(
        Config,
        allocator,
        text,
        .{ .ignore_unknown_fields = true },
    ) catch return null;
    defer parsed.deinit();

    // origin is a string field; dupe it so it outlives the parsed arena.
    const cfg = Config{
        .origin = allocator.dupe(u8, parsed.value.origin) catch return null,
        .transports = parsed.value.transports,
        .commercePartner = parsed.value.commercePartner,
        .grandmasterTitle = parsed.value.grandmasterTitle,
        .merchantRatings = parsed.value.merchantRatings,
        .speedBonus = parsed.value.speedBonus,
        .gearDiscount = parsed.value.gearDiscount,
        .thresholds = parsed.value.thresholds,
        .thresholdCount = parsed.value.thresholdCount,
    };

    // A wizard-completed config must have at least one transport selected.
    // If none are set the JSON likely has renamed/corrupt keys — treat as absent.
    const t = cfg.transports;
    if (!(t.backpack or t.handcart or t.wagon or t.packElephant or
          t.alpaca or t.dogSled or t.camel or t.tradersSkiff))
    {
        allocator.free(cfg.origin);
        return null;
    }

    // Merchant ratings must be in the valid 1–9 range.
    const mr = cfg.merchantRatings;
    const ratings_valid =
        (mr.tirChonaill >= 1 and mr.tirChonaill <= 9) and
        (mr.dunbarton >= 1 and mr.dunbarton <= 9) and
        (mr.bangor >= 1 and mr.bangor <= 9) and
        (mr.cobh >= 1 and mr.cobh <= 9) and
        (mr.tara >= 1 and mr.tara <= 9) and
        (mr.emainMacha >= 1 and mr.emainMacha <= 9) and
        (mr.taillteann >= 1 and mr.taillteann <= 9) and
        (mr.belvast >= 1 and mr.belvast <= 9) and
        (mr.qilla >= 1 and mr.qilla <= 9) and
        (mr.cor >= 1 and mr.cor <= 9) and
        (mr.filia >= 1 and mr.filia <= 9) and
        (mr.vales >= 1 and mr.vales <= 9);
    if (!ratings_valid) {
        allocator.free(cfg.origin);
        return null;
    }

    // thresholdCount indexes into the fixed-size `thresholds` array
    // (cfg.thresholds[0..cfg.thresholdCount] in sweepOrigin) — a corrupt or
    // hand-edited value greater than MAX_THRESHOLDS would slice out of bounds.
    if (cfg.thresholdCount > MAX_THRESHOLDS) {
        allocator.free(cfg.origin);
        return null;
    }

    return cfg;
}

/// Write config to {exe_dir}/config.json.
pub fn writeConfig(config: Config, allocator: std.mem.Allocator, exe_dir: []const u8) !void {
    const json = try std.json.stringifyAlloc(allocator, config, .{ .whitespace = .indent_2 });
    defer allocator.free(json);

    const path = try std.fs.path.join(allocator, &.{ exe_dir, "config.json" });
    defer allocator.free(path);

    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = json });
}

/// Free a Config that was returned by loadConfig or built by the wizard.
/// Only origin requires freeing; all other fields are value types.
pub fn deinitConfig(config: *Config, allocator: std.mem.Allocator) void {
    allocator.free(config.origin);
}
