const std = @import("std");
const dvui = @import("dvui");

const goods_mod = @import("../data/goods.zig");
const routes_mod = @import("../data/routes.zig");
const config_mod = @import("../data/config.zig");
const matrix_mod = @import("../engine/matrix.zig");
const threshold_mod = @import("../engine/threshold.zig");
const onboarding = @import("onboarding.zig");
const settings = @import("settings.zig");
const threshold = @import("threshold.zig");
const live = @import("live.zig");

pub const GoodsMap = goods_mod.GoodsMap;
pub const RouteData = routes_mod.RouteData;
pub const Config = config_mod.Config;
pub const RouteMatrix = matrix_mod.RouteMatrix;

// ── LoadError ─────────────────────────────────────────────────────────────────

pub const LoadErrorKind = enum { routes, goods };

pub const LoadError = struct {
    filename: []const u8,
    message: []const u8,
    kind: LoadErrorKind,
};

// ── AppState ──────────────────────────────────────────────────────────────────

pub const AppState = struct {
    allocator: std.mem.Allocator,
    exe_dir: []const u8,

    routes: ?RouteData,
    route_matrix: ?RouteMatrix,
    goods: ?GoodsMap,
    config: ?Config,

    needs_wizard: bool,
    load_error: ?LoadError,
    wizard_state: onboarding.WizardState = .{},
    engine_dirty: bool = false,
    show_settings: bool = false,
    settings_state: settings.SettingsState = .{},
    active_tab: enum { threshold, live } = .threshold,
    origin_error: ?[]const u8 = null,
    threshold_state: threshold.ThresholdState = .{},

    // ── Threshold engine cache (Story 2.4) ────────────────────────────────────
    // One slot per Outpost (index matches OUTPOST_KEYS/config.zig order).
    threshold_cache: [12]?threshold_mod.OriginResult = [_]?threshold_mod.OriginResult{null} ** 12,
    threshold_cache_stale: bool = true,

    // ── Icon byte cache (Story 2.6) ────────────────────────────────────────────
    // Keyed by Good.image path (a stable slice owned by `goods`, live for the
    // lifetime of AppState). Values are allocator-owned file bytes, read from
    // disk at most once per path — see iconBytes()/Design Notes for why.
    icon_cache: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator, exe_dir: []const u8) AppState {
        var state = AppState{
            .allocator = allocator,
            .exe_dir = exe_dir,
            .routes = null,
            .route_matrix = null,
            .goods = null,
            .config = null,
            .needs_wizard = false,
            .load_error = null,
            .icon_cache = std.StringHashMap([]const u8).init(allocator),
        };
        state.runStartupSequence();
        return state;
    }

    pub fn deinit(self: *AppState) void {
        if (self.goods) |*m| {
            goods_mod.deinitGoodsMap(m, self.allocator);
        }
        if (self.config) |*c| {
            config_mod.deinitConfig(c, self.allocator);
        }
        if (self.load_error) |err| {
            self.allocator.free(err.message);
        }
        var icon_it = self.icon_cache.valueIterator();
        while (icon_it.next()) |bytes| {
            self.allocator.free(bytes.*);
        }
        self.icon_cache.deinit();
    }

    // ── Internal helpers ──────────────────────────────────────────────────────

    fn runStartupSequence(self: *AppState) void {
        // 1. Load routes.json — required; on failure set load_error and return.
        if (routes_mod.loadRoutes(self.allocator, self.exe_dir)) |r| {
            self.routes = r;
            self.route_matrix = matrix_mod.build(r);
        } else |err| {
            self.setLoadError(.routes, "routes.json", err);
            return;
        }

        // 2. Load goods.json — required; on failure set load_error and return.
        if (goods_mod.loadGoods(self.allocator, self.exe_dir)) |g| {
            self.goods = g;
        } else |err| {
            self.setLoadError(.goods, "goods.json", err);
            return;
        }

        // 3. Load config.json — optional; null => show wizard placeholder.
        self.config = config_mod.loadConfig(self.allocator, self.exe_dir);
        if (self.config == null) {
            self.needs_wizard = true;
        }
    }

    fn setLoadError(self: *AppState, kind: LoadErrorKind, filename: []const u8, err: anyerror) void {
        const fname = filename;
        const msg = std.fmt.allocPrint(self.allocator, "{s}", .{@errorName(err)}) catch "unknown error";
        self.load_error = LoadError{
            .filename = fname,
            .message = msg,
            .kind = kind,
        };
    }

    fn retryAfterRestore(self: *AppState) void {
        // Free the existing load_error before retrying.
        if (self.load_error) |err| {
            self.allocator.free(err.message);
            self.load_error = null;
        }
        self.runStartupSequence();
    }

    // ── Render ────────────────────────────────────────────────────────────────

    /// Clears the per-Origin Threshold cache when stale, then lazily fills the
    /// current Origin's slot on demand. Pure cache bookkeeping — no UI, no I/O
    /// beyond the pure `sweepOrigin` call. Called as the first line of render().
    ///
    /// Staleness is set by settings.zig whenever a value-type Config field
    /// changes (transports, either Modifier, any Merchant Rating, Speed Bonus,
    /// or Gear Discount). Switching the viewed Origin alone does not set it —
    /// that is a cache read, not an invalidation trigger.
    pub fn update(self: *AppState) void {
        threshold_mod.updateCache(
            &self.threshold_cache,
            &self.threshold_cache_stale,
            self.config,
            self.goods,
            self.route_matrix,
        );
    }

    /// Returns the bytes of the icon file at `exe_dir/image_path`, reading
    /// from disk at most once per path and caching the result with a stable
    /// pointer. Returns null (never crashes) if the file can't be read — the
    /// caller falls back to name-only rendering.
    ///
    /// The cache exists because dvui's `ImageSource.imageFile` defaults to
    /// `invalidation = .ptr`: it keys its texture cache off `bytes.ptr`, so
    /// re-reading the file fresh every frame would hand it a new pointer each
    /// time and force a GPU texture rebuild every frame.
    pub fn iconBytes(self: *AppState, image_path: []const u8) ?[]const u8 {
        if (self.icon_cache.get(image_path)) |cached| return cached;

        const path = std.fs.path.join(self.allocator, &.{ self.exe_dir, image_path }) catch return null;
        defer self.allocator.free(path);

        const bytes = std.fs.cwd().readFileAlloc(self.allocator, path, goods_mod.max_file_size) catch return null;
        self.icon_cache.put(image_path, bytes) catch {
            self.allocator.free(bytes);
            return null;
        };
        return bytes;
    }

    /// Called once per frame from main.zig inside win.begin/end.
    /// Returns an error only for unrecoverable dvui failures.
    pub fn render(self: *AppState) !void {
        self.update();
        if (self.load_error != null) {
            try self.renderErrorDialog();
        } else if (self.needs_wizard) {
            try self.renderWizardPlaceholder();
        } else {
            try self.renderMainArea();
        }
    }

    fn renderErrorDialog(self: *AppState) !void {
        const err = self.load_error.?;

        // Modal floating window — blocks input to anything beneath it.
        var fw = dvui.floatingWindow(
            @src(),
            .{ .modal = true },
            .{ .min_size_content = .{ .w = 400, .h = 0 } },
        );
        defer fw.deinit();

        _ = dvui.windowHeader("Data Load Error", "", null);

        // Error message text.
        dvui.label(@src(), "Failed to load: {s}", .{err.filename}, .{ .expand = .horizontal });
        dvui.label(@src(), "Error: {s}", .{err.message}, .{
            .expand = .horizontal,
            .color_text = .{ .r = 200, .g = 50, .b = 50, .a = 255 },
        });

        {
            var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5, .margin = .{ .y = 8 } });
            defer hbox.deinit();

            if (dvui.button(@src(), "Restore Defaults", .{}, .{})) {
                // Synchronously restore the missing/corrupt file and retry.
                const restore_result: anyerror!void = switch (err.kind) {
                    .routes => routes_mod.restoreRoutes(self.allocator, self.exe_dir),
                    .goods => goods_mod.restoreGoods(self.allocator, self.exe_dir),
                };
                if (restore_result) |_| {
                    self.retryAfterRestore();
                } else |re| {
                    // Replace the load error message with the restore failure.
                    self.allocator.free(self.load_error.?.message);
                    const new_msg = std.fmt.allocPrint(
                        self.allocator,
                        "Restore failed: {s}",
                        .{@errorName(re)},
                    ) catch "restore failed";
                    self.load_error.?.message = new_msg;
                }
            }
        }
    }

    fn renderWizardPlaceholder(self: *AppState) !void {
        try onboarding.render(&self.wizard_state, self);
    }

    fn renderMainArea(self: *AppState) !void {
        // ── Top bar: Origin dropdown + Settings button ────────────────────────

        // Build dropdown entries: placeholder at index 0, outposts at 1..12.
        const placeholder: []const u8 = "— Select Origin —";
        var dropdown_entries: [13][]const u8 = undefined;
        dropdown_entries[0] = placeholder;
        for (config_mod.OUTPOST_DISPLAY_NAMES, 0..) |name, i| {
            dropdown_entries[i + 1] = name;
        }

        // Derive current dropdown index from config.origin each frame.
        var dropdown_idx: usize = 0;
        for (config_mod.OUTPOST_KEYS, 0..) |key, i| {
            if (std.mem.eql(u8, self.config.?.origin, key)) {
                dropdown_idx = i + 1;
                break;
            }
        }

        {
            var top_bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .margin = .{ .x = 8, .y = 6 },
            });
            defer top_bar.deinit();

            dvui.label(@src(), "Origin:", .{}, .{ .gravity_y = 0.5 });

            const prev_idx = dropdown_idx;
            if (dvui.dropdown(
                @src(),
                &dropdown_entries,
                &dropdown_idx,
                .{ .min_size_content = .{ .w = 160 }, .margin = .{ .x = 4 } },
            )) {
                // Selection changed — only act if user picked an actual outpost.
                if (dropdown_idx != prev_idx and dropdown_idx > 0) {
                    try self.handleOriginChange(dropdown_idx - 1);
                } else if (dropdown_idx == 0) {
                    // User picked the placeholder; clear any stale error.
                    self.origin_error = null;
                }
            }

            if (self.origin_error) |msg| {
                dvui.label(@src(), "Error: {s}", .{msg}, .{
                    .gravity_y = 0.5,
                    .margin = .{ .x = 8 },
                    .color_text = .{ .r = 200, .g = 50, .b = 50, .a = 255 },
                });
            }

            // Push Settings button to the right.
            {
                var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal });
                defer spacer.deinit();
            }

            if (dvui.button(@src(), "Settings", .{}, .{ .margin = .{ .x = 4 } })) {
                self.show_settings = true;
            }
        }

        // ── Tab selector row (always visible) ────────────────────────────────
        {
            var tab_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .margin = .{ .x = 8, .y = 2 },
            });
            defer tab_row.deinit();

            const threshold_active = self.active_tab == .threshold;
            const live_active = self.active_tab == .live;

            if (dvui.button(@src(), "Threshold", .{}, .{
                .margin = .{ .x = 2 },
                .color_fill = if (threshold_active)
                    dvui.Color{ .r = 80, .g = 120, .b = 200, .a = 255 }
                else
                    dvui.Color{ .r = 60, .g = 60, .b = 60, .a = 255 },
            })) {
                self.active_tab = .threshold;
            }

            if (dvui.button(@src(), "Live", .{}, .{
                .margin = .{ .x = 2 },
                .color_fill = if (live_active)
                    dvui.Color{ .r = 80, .g = 120, .b = 200, .a = 255 }
                else
                    dvui.Color{ .r = 60, .g = 60, .b = 60, .a = 255 },
            })) {
                self.active_tab = .live;
            }
        }

        // ── Content area: settings panel or active tab ────────────────────────
        if (self.show_settings) {
            try settings.render(&self.settings_state, self);
        } else {
            switch (self.active_tab) {
                .threshold => try threshold.renderTab(self),
                .live => try live.renderTab(self),
            }
        }
    }

    fn handleOriginChange(self: *AppState, outpost_idx: usize) !void {
        const old_origin = self.config.?.origin;
        const new_origin = try self.allocator.dupe(u8, config_mod.OUTPOST_KEYS[outpost_idx]);
        self.config.?.origin = new_origin;
        config_mod.writeConfig(self.config.?, self.allocator, self.exe_dir) catch |err| {
            self.allocator.free(new_origin);
            self.config.?.origin = old_origin;
            self.origin_error = @errorName(err);
            return;
        };
        self.allocator.free(old_origin);
        self.engine_dirty = true;
        self.origin_error = null;
        // A threshold-add/remove error from the previous Origin is no longer
        // relevant once the Origin has changed.
        self.threshold_state.error_msg = null;
        // TODO(Epic 3): clear live inputs here
    }

    /// Persist `self.routes` to routes.json if it differs from `before`, then
    /// rebuild the route matrix and invalidate the threshold cache.
    /// No-ops (no write, no rebuild) if nothing changed this frame.
    /// Keeps the engine rebuild (matrix_mod.build) out of ui/settings.zig
    /// (AD-2/AD-4) — settings.zig only ever calls this method.
    pub fn saveRoutes(self: *AppState, before: RouteData) void {
        if (std.meta.eql(before, self.routes.?)) return;

        routes_mod.writeRoutes(self.routes.?, self.allocator, self.exe_dir) catch |err| {
            self.settings_state.write_error = @errorName(err);
            self.routes.? = before;
            return;
        };

        self.route_matrix = matrix_mod.build(self.routes.?);
        self.threshold_cache_stale = true;
        self.settings_state.write_error = null;
    }

    /// Validates and inserts `value` into `config.thresholds` at its sorted
    /// position, persists the config, and marks the threshold cache stale.
    /// On any rejection, `self.config` is left untouched and
    /// `threshold_state.error_msg` is set; on success it is cleared.
    /// Mirrors the `handleOriginChange`/`saveRoutes` setter convention (AD-4)
    /// — ui/threshold.zig never calls config_mod.writeConfig directly.
    pub fn addThreshold(self: *AppState, value: u32) enum { ok, invalid, duplicate, full } {
        var cfg = self.config.?;
        const count = cfg.thresholdCount;

        if (value == 0) {
            self.threshold_state.error_msg = "Threshold must be a positive integer";
            return .invalid;
        }

        for (cfg.thresholds[0..count]) |v| {
            if (v == value) {
                self.threshold_state.error_msg = "Threshold already exists";
                return .duplicate;
            }
        }

        if (count >= config_mod.MAX_THRESHOLDS) {
            self.threshold_state.error_msg = "Maximum thresholds reached";
            return .full;
        }

        // Find the sorted insert position, then shift everything from there
        // right by one to make room.
        var insert_idx: usize = count;
        for (cfg.thresholds[0..count], 0..) |v, i| {
            if (value < v) {
                insert_idx = i;
                break;
            }
        }
        var i: usize = count;
        while (i > insert_idx) : (i -= 1) {
            cfg.thresholds[i] = cfg.thresholds[i - 1];
        }
        cfg.thresholds[insert_idx] = value;
        cfg.thresholdCount = count + 1;

        config_mod.writeConfig(cfg, self.allocator, self.exe_dir) catch |err| {
            // self.config was never mutated (we worked on a local copy) — no
            // partial state to revert.
            self.threshold_state.error_msg = @errorName(err);
            return .invalid;
        };

        self.config = cfg;
        self.threshold_cache_stale = true;
        self.threshold_state.error_msg = null;
        return .ok;
    }

    /// Removes the threshold at `index` (as taken directly from the render
    /// loop's `slot.rows` index — sweepOrigin documents rows[i] as built from
    /// cfg.thresholds[0..thresholdCount] in the same order, so index
    /// alignment holds without re-deriving it from the value). Enforces the
    /// minimum-1 rule (FR-8), persists the config, and marks the threshold
    /// cache stale. On any rejection, `self.config` is left untouched and
    /// `threshold_state.error_msg` is set; on success it is cleared.
    pub fn removeThreshold(self: *AppState, index: usize) void {
        var cfg = self.config.?;
        const count = cfg.thresholdCount;

        if (count <= 1) {
            self.threshold_state.error_msg = "At least one threshold is required";
            return;
        }
        if (index >= count) {
            self.threshold_state.error_msg = "Invalid threshold index";
            return;
        }

        var i = index;
        while (i < count - 1) : (i += 1) {
            cfg.thresholds[i] = cfg.thresholds[i + 1];
        }
        cfg.thresholds[count - 1] = 0;
        cfg.thresholdCount = count - 1;

        config_mod.writeConfig(cfg, self.allocator, self.exe_dir) catch |err| {
            // self.config was never mutated (we worked on a local copy) — no
            // partial state to revert.
            self.threshold_state.error_msg = @errorName(err);
            return;
        };

        self.config = cfg;
        self.threshold_cache_stale = true;
        self.threshold_state.error_msg = null;
    }
};

// ── saveRoutes tests (Story 2.5) ─────────────────────────────────────────────
// Directly construct a minimal AppState — no AppState.init / real dvui window
// needed, since saveRoutes touches only allocator, exe_dir, routes,
// route_matrix, settings_state.write_error and threshold_cache_stale.

test "saveRoutes success: writes to disk, rebuilds route_matrix, marks threshold cache stale" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(exe_dir);

    const before = std.mem.zeroes(RouteData);
    var after = before;
    after.tirChonaill.dunbarton = 999;

    var state = AppState{
        .allocator = allocator,
        .exe_dir = exe_dir,
        .routes = after,
        .route_matrix = null,
        .goods = null,
        .config = null,
        .needs_wizard = false,
        .load_error = null,
        .threshold_cache_stale = false,
        .icon_cache = std.StringHashMap([]const u8).init(allocator),
    };

    state.saveRoutes(before);

    // routes.json round-trips the new value.
    const loaded = try routes_mod.loadRoutes(allocator, exe_dir);
    try std.testing.expect(std.meta.eql(loaded, after));

    // route_matrix rebuilt from the new data.
    try std.testing.expect(std.meta.eql(state.route_matrix.?, matrix_mod.build(after)));

    // Threshold cache fully invalidated; no error surfaced.
    try std.testing.expect(state.threshold_cache_stale == true);
    try std.testing.expect(state.settings_state.write_error == null);
}

test "saveRoutes no-op: unchanged RouteData triggers no write and no rebuild" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(exe_dir);

    const routes = std.mem.zeroes(RouteData);
    const sentinel_matrix = matrix_mod.build(routes);

    var state = AppState{
        .allocator = allocator,
        .exe_dir = exe_dir,
        .routes = routes,
        .route_matrix = sentinel_matrix,
        .goods = null,
        .config = null,
        .needs_wizard = false,
        .load_error = null,
        .threshold_cache_stale = false,
        .icon_cache = std.StringHashMap([]const u8).init(allocator),
    };

    state.saveRoutes(routes); // before == current: nothing changed this frame

    // No routes.json was ever written.
    if (tmp.dir.access("routes.json", .{})) {
        try std.testing.expect(false); // no-op must not have written the file
    } else |err| {
        try std.testing.expect(err == error.FileNotFound);
    }

    // route_matrix and threshold_cache_stale left untouched.
    try std.testing.expect(std.meta.eql(state.route_matrix.?, sentinel_matrix));
    try std.testing.expect(state.threshold_cache_stale == false);
}

test "saveRoutes failure: write error reverts routes and sets write_error, leaves matrix/cache untouched" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_root);
    // A subdirectory that is never created — writeFile's parent-directory
    // lookup fails, forcing writeRoutes to return an error.
    const exe_dir = try std.fs.path.join(allocator, &.{ tmp_root, "does_not_exist" });
    defer allocator.free(exe_dir);

    const before = std.mem.zeroes(RouteData);
    var after = before;
    after.qilla.vales = 42;

    const sentinel_matrix = matrix_mod.build(before);

    var state = AppState{
        .allocator = allocator,
        .exe_dir = exe_dir,
        .routes = after,
        .route_matrix = sentinel_matrix,
        .goods = null,
        .config = null,
        .needs_wizard = false,
        .load_error = null,
        .threshold_cache_stale = false,
        .icon_cache = std.StringHashMap([]const u8).init(allocator),
    };

    state.saveRoutes(before);

    // Reverted to the pre-edit snapshot.
    try std.testing.expect(std.meta.eql(state.routes.?, before));

    // Error surfaced via SettingsState.write_error.
    try std.testing.expect(state.settings_state.write_error != null);

    // route_matrix and threshold_cache_stale left untouched.
    try std.testing.expect(std.meta.eql(state.route_matrix.?, sentinel_matrix));
    try std.testing.expect(state.threshold_cache_stale == false);
}

// ── addThreshold/removeThreshold tests (Story 2.7) ──────────────────────────
// Directly construct a minimal AppState — no AppState.init / real dvui window
// needed, since these setters touch only allocator, exe_dir, config,
// threshold_state.error_msg and threshold_cache_stale. Built the same way as
// the saveRoutes tests above.

fn makeThresholdTestState(allocator: std.mem.Allocator, exe_dir: []const u8, cfg: Config) AppState {
    return AppState{
        .allocator = allocator,
        .exe_dir = exe_dir,
        .routes = null,
        .route_matrix = null,
        .goods = null,
        .config = cfg,
        .needs_wizard = false,
        .load_error = null,
        .threshold_cache_stale = false,
        .icon_cache = std.StringHashMap([]const u8).init(allocator),
    };
}

test "addThreshold valid value: inserted at sorted position, persisted, cache invalidated" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(exe_dir);

    var cfg = Config{};
    cfg.transports.backpack = true; // loadConfig requires >=1 transport to accept the round-trip
    cfg.thresholds[0] = 100;
    cfg.thresholds[1] = 300;
    cfg.thresholdCount = 2;

    var state = makeThresholdTestState(allocator, exe_dir, cfg);

    const outcome = state.addThreshold(250);
    try std.testing.expect(outcome == .ok);

    // Inserted at the correct sorted position (between 100 and 300).
    try std.testing.expectEqual(@as(u8, 3), state.config.?.thresholdCount);
    try std.testing.expectEqual(@as(u32, 100), state.config.?.thresholds[0]);
    try std.testing.expectEqual(@as(u32, 250), state.config.?.thresholds[1]);
    try std.testing.expectEqual(@as(u32, 300), state.config.?.thresholds[2]);

    // Persisted to config.json.
    const loaded = config_mod.loadConfig(allocator, exe_dir).?;
    defer allocator.free(loaded.origin);
    try std.testing.expectEqual(@as(u8, 3), loaded.thresholdCount);
    try std.testing.expectEqual(@as(u32, 250), loaded.thresholds[1]);

    // Cache invalidated; error cleared.
    try std.testing.expect(state.threshold_cache_stale == true);
    try std.testing.expect(state.threshold_state.error_msg == null);
}

test "addThreshold valid value: inserted before the first existing element" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(exe_dir);

    var cfg = Config{};
    cfg.thresholds[0] = 100;
    cfg.thresholds[1] = 300;
    cfg.thresholdCount = 2;

    var state = makeThresholdTestState(allocator, exe_dir, cfg);

    const outcome = state.addThreshold(50);
    try std.testing.expect(outcome == .ok);

    try std.testing.expectEqual(@as(u8, 3), state.config.?.thresholdCount);
    try std.testing.expectEqual(@as(u32, 50), state.config.?.thresholds[0]);
    try std.testing.expectEqual(@as(u32, 100), state.config.?.thresholds[1]);
    try std.testing.expectEqual(@as(u32, 300), state.config.?.thresholds[2]);
}

test "addThreshold valid value: inserted after the last existing element" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(exe_dir);

    var cfg = Config{};
    cfg.thresholds[0] = 100;
    cfg.thresholds[1] = 300;
    cfg.thresholdCount = 2;

    var state = makeThresholdTestState(allocator, exe_dir, cfg);

    const outcome = state.addThreshold(500);
    try std.testing.expect(outcome == .ok);

    try std.testing.expectEqual(@as(u8, 3), state.config.?.thresholdCount);
    try std.testing.expectEqual(@as(u32, 100), state.config.?.thresholds[0]);
    try std.testing.expectEqual(@as(u32, 300), state.config.?.thresholds[1]);
    try std.testing.expectEqual(@as(u32, 500), state.config.?.thresholds[2]);
}

test "addThreshold duplicate: rejected, config and file unchanged" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(exe_dir);

    var cfg = Config{};
    cfg.thresholds[0] = 100;
    cfg.thresholdCount = 1;

    var state = makeThresholdTestState(allocator, exe_dir, cfg);

    const outcome = state.addThreshold(100);
    try std.testing.expect(outcome == .duplicate);
    try std.testing.expectEqual(@as(u8, 1), state.config.?.thresholdCount);
    try std.testing.expectEqualStrings("Threshold already exists", state.threshold_state.error_msg.?);

    // Nothing was ever written.
    if (tmp.dir.access("config.json", .{})) {
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expect(err == error.FileNotFound);
    }
    try std.testing.expect(state.threshold_cache_stale == false);
}

test "addThreshold zero: rejected with positive-integer error" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(exe_dir);

    var cfg = Config{};
    cfg.thresholds[0] = 100;
    cfg.thresholdCount = 1;

    var state = makeThresholdTestState(allocator, exe_dir, cfg);

    const outcome = state.addThreshold(0);
    try std.testing.expect(outcome == .invalid);
    try std.testing.expectEqual(@as(u8, 1), state.config.?.thresholdCount);
    try std.testing.expectEqualStrings("Threshold must be a positive integer", state.threshold_state.error_msg.?);
    try std.testing.expect(state.threshold_cache_stale == false);
}

test "addThreshold at capacity: rejected with maximum-reached error" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(exe_dir);

    var cfg = Config{};
    var i: u32 = 0;
    while (i < config_mod.MAX_THRESHOLDS) : (i += 1) {
        cfg.thresholds[i] = (i + 1) * 10; // 10, 20, .. 320 — all distinct
    }
    cfg.thresholdCount = config_mod.MAX_THRESHOLDS;

    var state = makeThresholdTestState(allocator, exe_dir, cfg);

    const outcome = state.addThreshold(5000); // not a duplicate, but no room
    try std.testing.expect(outcome == .full);
    try std.testing.expectEqual(@as(u8, config_mod.MAX_THRESHOLDS), state.config.?.thresholdCount);
    try std.testing.expectEqualStrings("Maximum thresholds reached", state.threshold_state.error_msg.?);
    try std.testing.expect(state.threshold_cache_stale == false);
}

test "addThreshold write failure: config left unchanged, error_msg set to @errorName" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_root);
    // A subdirectory that is never created — writeFile's parent-directory
    // lookup fails, forcing writeConfig to return an error.
    const exe_dir = try std.fs.path.join(allocator, &.{ tmp_root, "does_not_exist" });
    defer allocator.free(exe_dir);

    var cfg = Config{};
    cfg.thresholds[0] = 100;
    cfg.thresholdCount = 1;

    var state = makeThresholdTestState(allocator, exe_dir, cfg);

    const outcome = state.addThreshold(200);
    try std.testing.expect(outcome == .invalid);
    // In-memory config left exactly as before the call.
    try std.testing.expectEqual(@as(u8, 1), state.config.?.thresholdCount);
    try std.testing.expectEqual(@as(u32, 100), state.config.?.thresholds[0]);
    try std.testing.expect(state.threshold_state.error_msg != null);
    try std.testing.expect(state.threshold_cache_stale == false);
}

test "removeThreshold normal: removed, remaining values shift left, persisted" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(exe_dir);

    var cfg = Config{};
    cfg.transports.backpack = true; // loadConfig requires >=1 transport to accept the round-trip
    cfg.thresholds[0] = 100;
    cfg.thresholds[1] = 200;
    cfg.thresholds[2] = 300;
    cfg.thresholdCount = 3;

    var state = makeThresholdTestState(allocator, exe_dir, cfg);

    state.removeThreshold(1); // remove the middle value (200)

    try std.testing.expectEqual(@as(u8, 2), state.config.?.thresholdCount);
    try std.testing.expectEqual(@as(u32, 100), state.config.?.thresholds[0]);
    try std.testing.expectEqual(@as(u32, 300), state.config.?.thresholds[1]);

    const loaded = config_mod.loadConfig(allocator, exe_dir).?;
    defer allocator.free(loaded.origin);
    try std.testing.expectEqual(@as(u8, 2), loaded.thresholdCount);
    try std.testing.expectEqual(@as(u32, 300), loaded.thresholds[1]);

    try std.testing.expect(state.threshold_cache_stale == true);
    try std.testing.expect(state.threshold_state.error_msg == null);
}

test "removeThreshold last remaining: rejected, list unchanged" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(exe_dir);

    var cfg = Config{};
    cfg.thresholds[0] = 100;
    cfg.thresholdCount = 1;

    var state = makeThresholdTestState(allocator, exe_dir, cfg);

    state.removeThreshold(0);

    try std.testing.expectEqual(@as(u8, 1), state.config.?.thresholdCount);
    try std.testing.expectEqual(@as(u32, 100), state.config.?.thresholds[0]);
    try std.testing.expectEqualStrings("At least one threshold is required", state.threshold_state.error_msg.?);

    // Nothing was ever written.
    if (tmp.dir.access("config.json", .{})) {
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expect(err == error.FileNotFound);
    }
    try std.testing.expect(state.threshold_cache_stale == false);
}

test "removeThreshold invalid index: rejected, list unchanged" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(exe_dir);

    var cfg = Config{};
    cfg.thresholds[0] = 100;
    cfg.thresholds[1] = 200;
    cfg.thresholdCount = 2;

    var state = makeThresholdTestState(allocator, exe_dir, cfg);

    state.removeThreshold(2); // == thresholdCount, out of range

    try std.testing.expectEqual(@as(u8, 2), state.config.?.thresholdCount);
    try std.testing.expectEqual(@as(u32, 100), state.config.?.thresholds[0]);
    try std.testing.expectEqual(@as(u32, 200), state.config.?.thresholds[1]);
    try std.testing.expect(state.threshold_state.error_msg != null);

    // Nothing was ever written.
    if (tmp.dir.access("config.json", .{})) {
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expect(err == error.FileNotFound);
    }
    try std.testing.expect(state.threshold_cache_stale == false);
}

test "removeThreshold write failure: config left unchanged, error_msg set to @errorName" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_root);
    // A subdirectory that is never created — writeFile's parent-directory
    // lookup fails, forcing writeConfig to return an error.
    const exe_dir = try std.fs.path.join(allocator, &.{ tmp_root, "does_not_exist" });
    defer allocator.free(exe_dir);

    var cfg = Config{};
    cfg.thresholds[0] = 100;
    cfg.thresholds[1] = 200;
    cfg.thresholdCount = 2;

    var state = makeThresholdTestState(allocator, exe_dir, cfg);

    state.removeThreshold(0);

    // In-memory config left exactly as before the call.
    try std.testing.expectEqual(@as(u8, 2), state.config.?.thresholdCount);
    try std.testing.expectEqual(@as(u32, 100), state.config.?.thresholds[0]);
    try std.testing.expectEqual(@as(u32, 200), state.config.?.thresholds[1]);
    try std.testing.expect(state.threshold_state.error_msg != null);
    try std.testing.expect(state.threshold_cache_stale == false);
}

// ── iconBytes ────────────────────────────────────────────────────────────────

test "iconBytes: reads and caches a file with a stable pointer; missing file returns null" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(exe_dir);

    try tmp.dir.makePath("static/img/good");
    try tmp.dir.writeFile(.{ .sub_path = "static/img/good/test.png", .data = "fake-icon-bytes" });

    var state = AppState{
        .allocator = allocator,
        .exe_dir = exe_dir,
        .routes = null,
        .route_matrix = null,
        .goods = null,
        .config = null,
        .needs_wizard = false,
        .load_error = null,
        .icon_cache = std.StringHashMap([]const u8).init(allocator),
    };
    // goods/config/routes/load_error are all null here, so deinit() is safe
    // to call directly — this also exercises AppState.deinit()'s icon-cache
    // free loop, which no other test in this file reaches.
    defer state.deinit();

    const first = state.iconBytes("static/img/good/test.png").?;
    try std.testing.expectEqualStrings("fake-icon-bytes", first);

    // Second call must hit the cache and return the exact same pointer —
    // dvui's texture cache keys off bytes.ptr (ImageSource default .ptr
    // invalidation), so a changed pointer would thrash it every frame.
    const second = state.iconBytes("static/img/good/test.png").?;
    try std.testing.expect(first.ptr == second.ptr);

    // Missing file: falls back to null, never crashes.
    const missing = state.iconBytes("static/img/good/does_not_exist.png");
    try std.testing.expect(missing == null);

    // Oversized file (> goods_mod.max_file_size): readFileAlloc's size limit
    // triggers an error, same null-fallback contract as the missing-file case.
    const oversized_path = "static/img/good/oversized.png";
    {
        const oversized_data = try allocator.alloc(u8, goods_mod.max_file_size + 1);
        defer allocator.free(oversized_data);
        @memset(oversized_data, 'x');
        try tmp.dir.writeFile(.{ .sub_path = oversized_path, .data = oversized_data });
    }
    const oversized = state.iconBytes(oversized_path);
    try std.testing.expect(oversized == null);
}
