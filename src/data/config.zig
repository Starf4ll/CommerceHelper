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

pub const Config = struct {
    origin: []const u8 = "",
    transports: TransportFlags = .{},
    commercePartner: bool = false,
    grandmasterTitle: bool = false,
    merchantRatings: MerchantRatings = .{},
    speedBonus: u32 = 0,
    gearDiscount: u32 = 0,
};

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
