const std = @import("std");
const embedded_assets = @import("embedded_assets");

// ── Boat port sub-structs ────────────────────────────────────────────────────

pub const PortBelvast = struct {
    fromCobh: u32,
    wait: u32,
    travel: u32,
    toBelvast: u32,
    belvastBoatToQillaBoat: u32,
};

pub const PortQilla = struct {
    fromCobh: u32,
    wait: u32,
    travel: u32,
    toQilla: u32,
    toCor: u32,
};

pub const PortSella = struct {
    fromBangor: u32,
    wait: u32,
    travel: u32,
    toVales: u32,
    toCor: u32,
};

pub const PortConnous = struct {
    fromBangor: u32,
    wait: u32,
    travel: u32,
    toFilia: u32,
    toCor: u32,
};

pub const Boats = struct {
    portBelvast: PortBelvast,
    portQilla: PortQilla,
    portSella: PortSella,
    portConnous: PortConnous,
};

// ── Ulaidh travel-time tables ────────────────────────────────────────────────

pub const TirChonaill = struct {
    dunbarton: u32,
    bangor: u32,
    emainMacha: u32,
    taillteann: u32,
    tara: u32,
    cobh: u32,
};

pub const Dunbarton = struct {
    tirChonaill: u32,
    bangor: u32,
    emainMacha: u32,
    taillteann: u32,
    tara: u32,
    cobh: u32,
};

pub const Bangor = struct {
    tirChonaill: u32,
    dunbarton: u32,
    emainMacha: u32,
    taillteann: u32,
    tara: u32,
    cobh: u32,
};

pub const EmainMacha = struct {
    tirChonaill: u32,
    dunbarton: u32,
    bangor: u32,
    taillteann: u32,
    tara: u32,
    cobh: u32,
};

pub const Taillteann = struct {
    tirChonaill: u32,
    dunbarton: u32,
    bangor: u32,
    emainMacha: u32,
    tara: u32,
    cobh: u32,
};

pub const Tara = struct {
    tirChonaill: u32,
    dunbarton: u32,
    bangor: u32,
    emainMacha: u32,
    taillteann: u32,
    cobh: u32,
};

pub const Cobh = struct {
    tirChonaill: u32,
    dunbarton: u32,
    bangor: u32,
    emainMacha: u32,
    taillteann: u32,
    tara: u32,
};

// ── Iria travel-time tables ──────────────────────────────────────────────────

pub const Qilla = struct {
    vales: u32,
    filia: u32,
    cor: u32,
};

pub const Vales = struct {
    qilla: u32,
    filia: u32,
    cor: u32,
};

pub const Filia = struct {
    qilla: u32,
    vales: u32,
    cor: u32,
};

pub const Cor = struct {
    qilla: u32,
    vales: u32,
    filia: u32,
};

// ── Top-level RouteData ───────────────────────────────────────────────────────

pub const RouteData = struct {
    boats: Boats,
    tirChonaill: TirChonaill,
    dunbarton: Dunbarton,
    bangor: Bangor,
    emainMacha: EmainMacha,
    taillteann: Taillteann,
    tara: Tara,
    cobh: Cobh,
    qilla: Qilla,
    vales: Vales,
    filia: Filia,
    cor: Cor,
};

const DEFAULT_ROUTES_JSON: []const u8 = embedded_assets.DEFAULT_ROUTES_JSON;

const max_file_size = 1 * 1024 * 1024; // 1 MiB

/// Load routes.json from exe_dir and parse into a RouteData.
/// All numeric fields are value types; no heap allocation needed for the result
/// itself, but parseFromSlice may use `allocator` internally — we copy out the
/// value and let the parsed arena be freed immediately.
pub fn loadRoutes(allocator: std.mem.Allocator, exe_dir: []const u8) !RouteData {
    const path = try std.fs.path.join(allocator, &.{ exe_dir, "routes.json" });
    defer allocator.free(path);

    const text = try std.fs.cwd().readFileAlloc(allocator, path, max_file_size);
    defer allocator.free(text);

    return parseRoutes(allocator, text);
}

fn parseRoutes(allocator: std.mem.Allocator, text: []const u8) !RouteData {
    const parsed = try std.json.parseFromSlice(
        RouteData,
        allocator,
        text,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    // RouteData contains only numeric fields — safe to copy out.
    return parsed.value;
}

/// Write the embedded default routes.json to exe_dir/routes.json.
pub fn restoreRoutes(allocator: std.mem.Allocator, exe_dir: []const u8) !void {
    const out_path = try std.fs.path.join(allocator, &.{ exe_dir, "routes.json" });
    defer allocator.free(out_path);
    try std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = DEFAULT_ROUTES_JSON });
}
