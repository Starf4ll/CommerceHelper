const std = @import("std");
const dvui = @import("dvui");

const goods_mod = @import("../data/goods.zig");
const routes_mod = @import("../data/routes.zig");
const config_mod = @import("../data/config.zig");
const live_profits_mod = @import("../data/live_profits.zig");
const matrix_mod = @import("../engine/matrix.zig");
const threshold_mod = @import("../engine/threshold.zig");
const onboarding = @import("onboarding.zig");
const settings = @import("settings.zig");
const threshold = @import("threshold.zig");
const live = @import("live.zig");
const live_engine = @import("../engine/live.zig");

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
    live_state: live.LiveState = .{},
    // `null` means "never calculated yet" or "cleared by an Origin/Config
    // change" (see handleOriginChange/update). `Some(LiveResults)` with
    // `count == 0` means Calculate was pressed but found no profitable
    // combination — a distinct state from "not calculated" that Story 3.3's
    // results rendering must tell apart.
    live_results: ?live_engine.LiveResults = null,

    // ── Threshold engine cache (Story 2.4; heap-boxed by Story 4.1) ──────────
    // One slot per Outpost (index matches OUTPOST_KEYS/config.zig order).
    // `OriginResult` grew far larger with the per-Good matrix sweep (Story
    // 4.1) than AppState's plain stack frame can hold inline, so each
    // populated slot is a GPA-owned pointer instead of an inline value —
    // `updateCache` (engine/threshold.zig) is solely responsible for
    // `create()`-ing and `destroy()`-ing them.
    threshold_cache: [12]?*threshold_mod.OriginResult = [_]?*threshold_mod.OriginResult{null} ** 12,
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
        // Every non-null threshold_cache slot is a GPA-owned box (Story 4.1)
        // — destroy them all on shutdown, same convention as the icon cache
        // below, so a full AppState lifecycle leaks nothing under
        // std.testing.allocator.
        for (&self.threshold_cache) |*slot| {
            if (slot.*) |ptr| {
                self.allocator.destroy(ptr);
                slot.* = null;
            }
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

        // 2.5. Load live_profits.json — optional; needs GoodsMap (just loaded
        // above) for name->index resolution. Fail-soft (missing/corrupt file
        // = empty result, no wizard/error-dialog impact) is entirely handled
        // inside loadLiveProfits itself. Any entry naming an Origin,
        // Destination or Good no longer present is dropped silently.
        {
            const entries = live_profits_mod.loadLiveProfits(self.allocator, self.exe_dir);
            defer live_profits_mod.deinitLiveProfitEntries(entries, self.allocator);
            applyLiveProfitEntries(&self.live_state.profits, &self.goods.?, entries);
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
        // Read staleness before updateCache clears it — "Config changed" is
        // exactly this existing signal (settings.zig:445-446), and it must
        // also invalidate any Live Mode results computed under the old Config.
        const was_stale = self.threshold_cache_stale;
        threshold_mod.updateCache(
            &self.threshold_cache,
            &self.threshold_cache_stale,
            self.config,
            self.goods,
            self.route_matrix,
            self.allocator,
        );
        if (was_stale) {
            self.live_results = null;
        }
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
                self.show_settings = !self.show_settings;
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
        // Profit inputs are no longer Origin-specific-and-cleared (Story 3.4):
        // switching Origin only changes which profits[origin_idx] slice the
        // grid reads/writes. live_results still clears — it was computed
        // under the old Origin's sweep and no longer applies.
        self.live_results = null;
        // A save-write failure from the previous Origin is no longer relevant
        // once the Origin has changed (same reasoning as threshold_state's
        // error_msg reset above; review finding — this reset was missing).
        self.live_state.write_error = null;
    }

    /// Runs the Live Mode calculation sweep (engine/live.zig's `calculate`)
    /// over the current Origin's Goods, Config, route matrix, and entered
    /// profits, storing the result into `live_results`. The only entry point
    /// into the Live engine — never auto-called from `update()`, only from
    /// the Calculate button in ui/live.zig (manual trigger, AD-5 Level 3).
    /// No-ops (leaves `live_results` untouched) if the app isn't fully
    /// loaded yet or no Origin is selected.
    pub fn calculateLive(self: *AppState) void {
        const cfg = self.config orelse return;
        if (cfg.origin.len == 0) return;

        var origin_idx: ?usize = null;
        for (config_mod.OUTPOST_KEYS, 0..) |key, i| {
            if (std.mem.eql(u8, cfg.origin, key)) {
                origin_idx = i;
                break;
            }
        }
        const idx = origin_idx orelse return;

        const gm = self.goods orelse return;
        const rm = self.route_matrix orelse return;
        const origin_goods: []const goods_mod.Good = gm.get(cfg.origin) orelse &[_]goods_mod.Good{};

        self.live_results = live_engine.calculate(
            origin_goods,
            cfg,
            idx,
            rm,
            self.live_state.profits[idx][0..],
        );
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

    /// Persist `self.live_state.profits[idx]` to live_profits.json if it
    /// differs from `before`, following `saveRoutes`'s exact convention:
    /// diff-before-write (no-op if nothing changed this frame), and on write
    /// failure revert just this Origin's slice and set `LiveState.write_error`.
    /// Rebuilds the whole file from every Origin's current in-memory profits
    /// (not just this Origin) since live_profits.json holds all 12 Origins in
    /// one flat, name-keyed list (Design Notes).
    pub fn saveLiveProfits(self: *AppState, idx: usize, before: [live.MAX_GOODS][12]f32) void {
        if (std.meta.eql(before, self.live_state.profits[idx])) return;

        self.writeAllLiveProfits() catch |err| {
            self.live_state.write_error = @errorName(err);
            self.live_state.profits[idx] = before;
            return;
        };
        self.live_state.write_error = null;
    }

    /// Walks all 12 Origins x each Origin's real GoodsMap slice x 12
    /// Destinations, emitting one entry per nonzero cell, and writes the
    /// resulting list to live_profits.json. Blank fields (profit == 0.0) are
    /// never written (Boundaries). Origin/Good/Destination strings referenced
    /// here are owned by OUTPOST_KEYS/GoodsMap (both outlive this call), so no
    /// duplication/freeing is needed for the entries themselves.
    ///
    /// `LiveState.profits` stays `f32` in memory (the input grid parses
    /// decimal text and the calculation engine works in floating point), but
    /// real Ducats-per-unit values are always whole numbers well under a
    /// 16-bit range, so each cell is rounded and saturated into
    /// `LiveProfitEntry.profit`'s `u16` here — this is also what keeps the
    /// JSON file itself a plain integer instead of scientific notation.
    fn writeAllLiveProfits(self: *AppState) !void {
        var entries = std.ArrayList(live_profits_mod.LiveProfitEntry).init(self.allocator);
        defer entries.deinit();

        for (config_mod.OUTPOST_KEYS, 0..) |origin_key, o_idx| {
            const origin_goods = self.goods.?.get(origin_key) orelse continue;
            for (origin_goods, 0..) |good, g_idx| {
                // Same MAX_GOODS bound applyLiveProfitEntries enforces on the
                // load side (Story 3.4 review) — profits[o_idx] is only
                // MAX_GOODS wide, so a GoodsMap slice beyond that would
                // otherwise index out of bounds here.
                if (g_idx >= live.MAX_GOODS) break;
                for (config_mod.OUTPOST_KEYS, 0..) |dest_key, d_idx| {
                    if (d_idx == o_idx) continue;
                    const profit = self.live_state.profits[o_idx][g_idx][d_idx];
                    if (profit <= 0.0) continue;
                    const rounded = @min(@round(profit), @as(f32, std.math.maxInt(u16)));
                    const profit_u16: u16 = @intFromFloat(rounded);
                    if (profit_u16 == 0) continue;
                    try entries.append(.{
                        .origin = origin_key,
                        .good = good.name,
                        .destination = dest_key,
                        .profit = profit_u16,
                    });
                }
            }
        }

        try live_profits_mod.writeLiveProfits(entries.items, self.allocator, self.exe_dir);
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

// ── live_profits load-time name->index resolution (Story 3.4) ──────────────
// Free functions (not AppState methods) so they're directly unit-testable
// without constructing a full AppState.

/// Returns the OUTPOST_KEYS index of `name`, or null if it names no known
/// Outpost. Same linear scan convention used throughout this file and
/// ui/live.zig for Origin/Destination resolution.
fn indexOfOutpost(name: []const u8) ?usize {
    for (config_mod.OUTPOST_KEYS, 0..) |key, i| {
        if (std.mem.eql(u8, name, key)) return i;
    }
    return null;
}

/// Resolves each loaded live_profits.json entry's origin/good/destination
/// NAME strings against OUTPOST_KEYS/GoodsMap and fills the matching
/// `profits[origin_idx][good_idx][dest_idx]` cell. Any entry naming an
/// Origin, Destination or Good no longer present (stale, per the I/O matrix)
/// is dropped silently — the rest still load normally.
fn applyLiveProfitEntries(
    profits: *[12][live.MAX_GOODS][12]f32,
    goods: *const GoodsMap,
    entries: []const live_profits_mod.LiveProfitEntry,
) void {
    for (entries) |entry| {
        const origin_idx = indexOfOutpost(entry.origin) orelse continue;
        const dest_idx = indexOfOutpost(entry.destination) orelse continue;
        const origin_goods = goods.get(entry.origin) orelse continue;

        var good_idx: ?usize = null;
        for (origin_goods, 0..) |g, i| {
            if (std.mem.eql(u8, g.name, entry.good)) {
                good_idx = i;
                break;
            }
        }
        const gidx = good_idx orelse continue;
        if (gidx >= live.MAX_GOODS) continue;

        // entry.profit is the persisted u16; LiveState.profits stays f32 in
        // memory (the input grid/engine work in floating point).
        profits[origin_idx][gidx][dest_idx] = @floatFromInt(entry.profit);
    }
}

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

// ── Settings button toggle (spec-destination-order-settings-toggle-and-tabs) ──
// Guards the toggle-to-close behavior: `self.show_settings = !self.show_settings`
// in renderMainArea's Settings button handler. A regression back to the old
// `self.show_settings = true` (open-only, never closes) would pass every other
// test in this file but silently break re-clicking "Settings" to close it.

test "Settings button toggle expression round-trips show_settings false -> true -> false" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(exe_dir);

    var state = makeThresholdTestState(allocator, exe_dir, Config{});

    try std.testing.expect(state.show_settings == false);

    // Mirrors the Settings button's handler exactly (renderMainArea).
    state.show_settings = !state.show_settings;
    try std.testing.expect(state.show_settings == true);

    state.show_settings = !state.show_settings;
    try std.testing.expect(state.show_settings == false);
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

// ── handleOriginChange ──────────────────────────────────────────────────────

test "handleOriginChange does NOT clear live_state.profits (Story 3.4)" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(exe_dir);

    var cfg = Config{};
    cfg.transports.backpack = true; // loadConfig requires >=1 transport; unused here but keeps cfg realistic
    cfg.origin = try allocator.dupe(u8, "tirChonaill"); // handleOriginChange frees the old origin, so it must be heap-owned

    var state = makeThresholdTestState(allocator, exe_dir, cfg);

    state.live_state.profits[0][0][0] = 42.0; // Origin 0 (tirChonaill)
    state.live_state.profits[0][5][3] = 7.5; // Origin 0 (tirChonaill)
    state.live_state.profits[1][63][11] = 1.0; // Origin 1 (dunbarton) — the Origin being switched TO

    try state.handleOriginChange(1); // switch to "dunbarton"

    // Story 3.4 reverses Story 3.1: switching Origin must leave every
    // Origin's stored profits untouched — nothing is cleared in memory.
    try std.testing.expectEqual(@as(f32, 42.0), state.live_state.profits[0][0][0]);
    try std.testing.expectEqual(@as(f32, 7.5), state.live_state.profits[0][5][3]);
    try std.testing.expectEqual(@as(f32, 1.0), state.live_state.profits[1][63][11]);

    allocator.free(state.config.?.origin);
}

// ── live_results clearing (Story 3.2 Matrix Test Audit: I/O row 4) ──────────

test "handleOriginChange clears live_results (Story 3.2)" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(exe_dir);

    var cfg = Config{};
    cfg.transports.backpack = true;
    cfg.origin = try allocator.dupe(u8, "tirChonaill");

    var state = makeThresholdTestState(allocator, exe_dir, cfg);
    state.live_results = live_engine.LiveResults{ .rows = undefined, .count = 3 };

    try state.handleOriginChange(1); // switch to "dunbarton"

    try std.testing.expect(state.live_results == null);

    allocator.free(state.config.?.origin);
}

test "update() clears live_results when threshold_cache_stale was true (Story 3.2)" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(exe_dir);

    var cfg = Config{};
    cfg.origin = try allocator.dupe(u8, "tirChonaill");
    defer allocator.free(cfg.origin);

    var state = makeThresholdTestState(allocator, exe_dir, cfg);
    state.threshold_cache_stale = true;
    state.live_results = live_engine.LiveResults{ .rows = undefined, .count = 3 };

    state.update();

    try std.testing.expect(state.live_results == null);
    try std.testing.expect(state.threshold_cache_stale == false);
}

test "update() leaves live_results untouched when threshold_cache_stale is false (Story 3.2)" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(exe_dir);

    var cfg = Config{};
    cfg.origin = try allocator.dupe(u8, "tirChonaill");
    defer allocator.free(cfg.origin);

    var state = makeThresholdTestState(allocator, exe_dir, cfg);
    state.threshold_cache_stale = false;
    state.live_results = live_engine.LiveResults{ .rows = undefined, .count = 3 };

    state.update();

    try std.testing.expect(state.live_results != null);
    try std.testing.expectEqual(@as(u8, 3), state.live_results.?.count);
}

// ── calculateLive() success path (Story 3.2 Matrix Test Audit) ─────────────
// Unlike the live_results tests above (which hand-construct live_results and
// only check clearing/null behavior), this drives AppState's actual entry
// point into the Live engine — mirroring engine/live.zig's own
// "calculate happy path" test, but going through calculateLive() end to end:
// a real GoodsMap, a real RouteMatrix with one reachable Destination, a
// Config with a valid Origin and an owned Transport, and a nonzero entered
// profit.

test "calculateLive happy path: populates live_results via the real AppState entry point" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(exe_dir);

    var cfg = Config{};
    cfg.transports.backpack = true; // owned Transport
    cfg.origin = try allocator.dupe(u8, "tirChonaill"); // valid Origin (OUTPOST_KEYS[0])
    defer allocator.free(cfg.origin);

    // GoodsMap with one Good at the Origin. Static string fields (no
    // allocation) mirror engine/live.zig's own makeGood test helper — the
    // map's only heap allocation is its internal bucket storage, freed below
    // via gm.deinit() (not deinitGoodsMap, which would wrongly try to free
    // these static strings).
    var good_slice = [_]goods_mod.Good{
        .{
            .name = "TestGood",
            .description = "",
            .image = "",
            .weight = 10,
            .quantityPerSlot = 5,
            .cost = 0,
            .merchantRating = 1,
        },
    };
    var gm = GoodsMap.init(allocator);
    defer gm.deinit();
    try gm.put("tirChonaill", good_slice[0..]);

    // RouteMatrix: only tirChonaill(0)<->dunbarton(1) is reachable.
    var matrix = std.mem.zeroes(RouteMatrix);
    matrix.baseTimes[0][1] = 100;
    matrix.baseTimes[1][0] = 100;

    var state = AppState{
        .allocator = allocator,
        .exe_dir = exe_dir,
        .routes = null,
        .route_matrix = matrix,
        .goods = gm,
        .config = cfg,
        .needs_wizard = false,
        .load_error = null,
        .threshold_cache_stale = false,
        .icon_cache = std.StringHashMap([]const u8).init(allocator),
    };

    state.live_state.profits[0][0][1] = 50.0; // Origin 0 (tirChonaill), TestGood @ dunbarton: 50 Ducats/unit

    state.calculateLive();

    try std.testing.expect(state.live_results != null);
    const results = state.live_results.?;
    try std.testing.expectEqual(@as(u8, 1), results.count);

    const row = results.rows[0];
    try std.testing.expectEqual(@as(usize, 1), row.destination_idx);
    try std.testing.expect(std.mem.eql(u8, "Backpack", row.transport_name));
    try std.testing.expectEqual(@as(u8, 1), row.load.count);
    try std.testing.expectEqual(@as(usize, 0), row.load.items[0].good_idx);
    // primaryQty(weight=10, qty=5, backpack cap=400 slots=4, mods=0) = min(40, 20) = 20
    try std.testing.expectEqual(@as(u32, 20), row.load.items[0].qty);
    try std.testing.expectApproxEqAbs(@as(f64, 1000.0), row.total_profit, 0.001);
    // travel = 100 / 0.91 = 109.8901s => 1.831502 min; ducats/min = 1000 / 1.831502 = 546.0
    try std.testing.expectApproxEqAbs(@as(f64, 546.0), row.ducats_per_min, 0.1);
}

// ── applyLiveProfitEntries (Story 3.4 startup apply) ────────────────────────
// Free-function tests — no AppState/dvui needed, just a GoodsMap fixture and
// a raw profits array, mirroring engine/live.zig's own pure-function test
// style.

test "applyLiveProfitEntries: matched entry resolves names to the correct cell" {
    const allocator = std.testing.allocator;

    var good_slice = [_]goods_mod.Good{
        .{ .name = "TestGood", .description = "", .image = "", .weight = 1, .quantityPerSlot = 1, .cost = 0, .merchantRating = 1 },
    };
    var gm = GoodsMap.init(allocator);
    defer gm.deinit();
    try gm.put("tirChonaill", good_slice[0..]);

    var profits = [_][live.MAX_GOODS][12]f32{[_][12]f32{[_]f32{0.0} ** 12} ** live.MAX_GOODS} ** 12;

    const entries = [_]live_profits_mod.LiveProfitEntry{
        .{ .origin = "tirChonaill", .good = "TestGood", .destination = "dunbarton", .profit = 42 },
    };

    applyLiveProfitEntries(&profits, &gm, &entries);

    try std.testing.expectEqual(@as(f32, 42.0), profits[0][0][1]); // tirChonaill=0, TestGood=0, dunbarton=1
}

test "applyLiveProfitEntries: entries naming an unknown Origin/Destination/Good are dropped silently, rest still apply" {
    const allocator = std.testing.allocator;

    var good_slice = [_]goods_mod.Good{
        .{ .name = "TestGood", .description = "", .image = "", .weight = 1, .quantityPerSlot = 1, .cost = 0, .merchantRating = 1 },
    };
    var gm = GoodsMap.init(allocator);
    defer gm.deinit();
    try gm.put("tirChonaill", good_slice[0..]);

    var profits = [_][live.MAX_GOODS][12]f32{[_][12]f32{[_]f32{0.0} ** 12} ** live.MAX_GOODS} ** 12;

    const entries = [_]live_profits_mod.LiveProfitEntry{
        // Unknown Origin — dropped.
        .{ .origin = "notAnOutpost", .good = "TestGood", .destination = "dunbarton", .profit = 1 },
        // Unknown Destination — dropped.
        .{ .origin = "tirChonaill", .good = "TestGood", .destination = "notAnOutpost", .profit = 2 },
        // Unknown Good (not in tirChonaill's GoodsMap slice) — dropped.
        .{ .origin = "tirChonaill", .good = "NoSuchGood", .destination = "dunbarton", .profit = 3 },
        // Valid entry — must still apply despite the three stale ones above.
        .{ .origin = "tirChonaill", .good = "TestGood", .destination = "bangor", .profit = 4 },
    };

    applyLiveProfitEntries(&profits, &gm, &entries);

    // Nothing but the one valid cell was ever written.
    try std.testing.expectEqual(@as(f32, 4.0), profits[0][0][2]); // tirChonaill=0, TestGood=0, bangor=2
    for (profits, 0..) |origin_slice, o| {
        for (origin_slice, 0..) |good_row, g| {
            for (good_row, 0..) |v, d| {
                if (o == 0 and g == 0 and d == 2) continue; // the one expected nonzero cell
                try std.testing.expectEqual(@as(f32, 0.0), v);
            }
        }
    }
}

// ── saveLiveProfits (Story 3.4) ──────────────────────────────────────────────
// Mirrors saveRoutes's exact 3-test pattern (success/no-op/failure).

test "saveLiveProfits success: writes to disk, clears write_error" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(exe_dir);

    var good_slice = [_]goods_mod.Good{
        .{ .name = "TestGood", .description = "", .image = "", .weight = 1, .quantityPerSlot = 1, .cost = 0, .merchantRating = 1 },
    };
    var gm = GoodsMap.init(allocator);
    defer gm.deinit();
    try gm.put("tirChonaill", good_slice[0..]);

    var state = AppState{
        .allocator = allocator,
        .exe_dir = exe_dir,
        .routes = null,
        .route_matrix = null,
        .goods = gm,
        .config = null,
        .needs_wizard = false,
        .load_error = null,
        .icon_cache = std.StringHashMap([]const u8).init(allocator),
    };

    const before = state.live_state.profits[0]; // all-zero snapshot
    state.live_state.profits[0][0][1] = 25.0; // tirChonaill/TestGood @ dunbarton

    state.saveLiveProfits(0, before);

    try std.testing.expect(state.live_state.write_error == null);

    const loaded = live_profits_mod.loadLiveProfits(allocator, exe_dir);
    defer live_profits_mod.deinitLiveProfitEntries(loaded, allocator);
    try std.testing.expectEqual(@as(usize, 1), loaded.len);
    try std.testing.expectEqualStrings("tirChonaill", loaded[0].origin);
    try std.testing.expectEqualStrings("TestGood", loaded[0].good);
    try std.testing.expectEqualStrings("dunbarton", loaded[0].destination);
    try std.testing.expectEqual(@as(u16, 25), loaded[0].profit);
}

test "saveLiveProfits rounds a fractional profit and saturates an out-of-u16-range one" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(exe_dir);

    var good_slice = [_]goods_mod.Good{
        .{ .name = "GoodA", .description = "", .image = "", .weight = 1, .quantityPerSlot = 1, .cost = 0, .merchantRating = 1 },
        .{ .name = "GoodB", .description = "", .image = "", .weight = 1, .quantityPerSlot = 1, .cost = 0, .merchantRating = 1 },
    };
    var gm = GoodsMap.init(allocator);
    defer gm.deinit();
    try gm.put("tirChonaill", good_slice[0..]);

    var state = AppState{
        .allocator = allocator,
        .exe_dir = exe_dir,
        .routes = null,
        .route_matrix = null,
        .goods = gm,
        .config = null,
        .needs_wizard = false,
        .load_error = null,
        .icon_cache = std.StringHashMap([]const u8).init(allocator),
    };

    const before = state.live_state.profits[0]; // all-zero snapshot
    state.live_state.profits[0][0][1] = 12.6; // GoodA @ dunbarton — rounds to 13
    state.live_state.profits[0][1][1] = 100_000.0; // GoodB @ dunbarton — saturates to u16 max

    state.saveLiveProfits(0, before);

    try std.testing.expect(state.live_state.write_error == null);

    const loaded = live_profits_mod.loadLiveProfits(allocator, exe_dir);
    defer live_profits_mod.deinitLiveProfitEntries(loaded, allocator);
    try std.testing.expectEqual(@as(usize, 2), loaded.len);

    var found_a = false;
    var found_b = false;
    for (loaded) |entry| {
        if (std.mem.eql(u8, entry.good, "GoodA")) {
            try std.testing.expectEqual(@as(u16, 13), entry.profit);
            found_a = true;
        } else if (std.mem.eql(u8, entry.good, "GoodB")) {
            try std.testing.expectEqual(@as(u16, std.math.maxInt(u16)), entry.profit);
            found_b = true;
        }
    }
    try std.testing.expect(found_a and found_b);
}

test "saveLiveProfits no-op: unchanged slice triggers no write" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(exe_dir);

    var gm = GoodsMap.init(allocator);
    defer gm.deinit();

    var state = AppState{
        .allocator = allocator,
        .exe_dir = exe_dir,
        .routes = null,
        .route_matrix = null,
        .goods = gm,
        .config = null,
        .needs_wizard = false,
        .load_error = null,
        .icon_cache = std.StringHashMap([]const u8).init(allocator),
    };

    const before = state.live_state.profits[0]; // identical to current — before == current

    state.saveLiveProfits(0, before);

    // No live_profits.json was ever written.
    if (tmp.dir.access("live_profits.json", .{})) {
        try std.testing.expect(false); // no-op must not have written the file
    } else |err| {
        try std.testing.expect(err == error.FileNotFound);
    }
    try std.testing.expect(state.live_state.write_error == null);
}

test "saveLiveProfits failure: write error reverts the Origin's slice and sets write_error" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_root);
    // A subdirectory that is never created — writeFile's parent-directory
    // lookup fails, forcing writeLiveProfits to return an error.
    const exe_dir = try std.fs.path.join(allocator, &.{ tmp_root, "does_not_exist" });
    defer allocator.free(exe_dir);

    var good_slice = [_]goods_mod.Good{
        .{ .name = "TestGood", .description = "", .image = "", .weight = 1, .quantityPerSlot = 1, .cost = 0, .merchantRating = 1 },
    };
    var gm = GoodsMap.init(allocator);
    defer gm.deinit();
    try gm.put("tirChonaill", good_slice[0..]);

    var state = AppState{
        .allocator = allocator,
        .exe_dir = exe_dir,
        .routes = null,
        .route_matrix = null,
        .goods = gm,
        .config = null,
        .needs_wizard = false,
        .load_error = null,
        .icon_cache = std.StringHashMap([]const u8).init(allocator),
    };

    const before = state.live_state.profits[0]; // all-zero snapshot
    state.live_state.profits[0][0][1] = 25.0;

    state.saveLiveProfits(0, before);

    // Reverted to the pre-edit snapshot.
    try std.testing.expect(std.meta.eql(state.live_state.profits[0], before));

    // Error surfaced via LiveState.write_error.
    try std.testing.expect(state.live_state.write_error != null);
}

// ── runStartupSequence live_profits wiring (Story 3.4 review finding) ──────
// Every other AppState test in this file hand-builds an AppState struct
// literal, bypassing init()/runStartupSequence() entirely. applyLiveProfitEntries
// is otherwise only exercised as a free function with a hand-built profits
// array and GoodsMap — nothing drives it through the real startup path
// (real files on disk, self.goods populated by the time it's called, correct
// call order relative to the goods load). This test closes that gap by going
// through AppState.init() exactly as main.zig does.

test "AppState.init loads live_profits.json and populates live_state.profits (Story 3.4 startup wiring)" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(exe_dir);

    // routes.json: any well-formed RouteData round-trips via the real writer.
    try routes_mod.writeRoutes(std.mem.zeroes(RouteData), allocator, exe_dir);

    // goods.json: minimal but real, in loadGoods's expected schema (object of
    // town -> Good[]), so this exercises the actual parser, not a fixture.
    try tmp.dir.writeFile(.{
        .sub_path = "goods.json",
        .data =
        \\{"tirChonaill":[{"name":"TestGood","description":"d","image":"i","weight":1,"quantityPerSlot":1,"cost":0,"merchantRating":1}]}
        ,
    });

    // live_profits.json: one entry that should resolve cleanly once goods.json
    // has loaded (tirChonaill=Origin 0, TestGood=index 0, dunbarton=Destination 1).
    const entries = [_]live_profits_mod.LiveProfitEntry{
        .{ .origin = "tirChonaill", .good = "TestGood", .destination = "dunbarton", .profit = 77 },
    };
    try live_profits_mod.writeLiveProfits(&entries, allocator, exe_dir);

    // No config.json — needs_wizard is expected true; live_profits loading
    // must not depend on config having loaded (it runs before step 3).
    var state = AppState.init(allocator, exe_dir);
    defer state.deinit();

    try std.testing.expect(state.load_error == null); // routes/goods both loaded
    try std.testing.expectEqual(@as(f32, 77.0), state.live_state.profits[0][0][1]);
}

// ── threshold_cache leak check (Story 4.1 review finding) ──────────────────
// Every other AppState test that exercises `.update()` uses
// `makeThresholdTestState` (goods=null, route_matrix=null), so `updateCache`
// always guard-clauses out before ever allocating; every test that calls
// `.deinit()` never populates `threshold_cache` first. Neither path would
// catch a regression in `AppState.deinit()`'s threshold_cache destroy loop
// (wrong allocator, wrong field, or dropped entirely) — `zig build test`
// would stay green while every real run leaked. This test goes through the
// real `AppState.init()` startup path (real routes/goods/config.json, same
// convention as the live_profits startup-wiring test above) so `.update()`
// actually `allocator.create()`s a threshold_cache slot, then relies on
// `std.testing.allocator`'s leak detector (checked at process exit) to catch
// any regression in the matching `destroy()` inside `.deinit()`.
test "AppState.deinit() frees a real threshold_cache pointer created via update() (Story 4.1 leak check)" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(exe_dir);

    // routes.json: any well-formed RouteData round-trips via the real writer.
    try routes_mod.writeRoutes(std.mem.zeroes(RouteData), allocator, exe_dir);

    // goods.json: a real, parsed (not hand-built) Good at tirChonaill, so
    // AppState.deinit()'s normal deinitGoodsMap path stays safe to exercise.
    try tmp.dir.writeFile(.{
        .sub_path = "goods.json",
        .data =
        \\{"tirChonaill":[{"name":"TestGood","description":"d","image":"i","weight":10,"quantityPerSlot":5,"cost":0,"merchantRating":1}]}
        ,
    });

    // config.json: a valid, wizard-completed Config with an Origin set and
    // one owned Transport — required for update()/updateCache to actually
    // reach the allocation path instead of guard-clausing out on a null
    // config or empty origin.
    var cfg = Config{};
    cfg.origin = "tirChonaill";
    cfg.transports.backpack = true;
    try config_mod.writeConfig(cfg, allocator, exe_dir);

    var state = AppState.init(allocator, exe_dir);
    defer state.deinit();

    try std.testing.expect(state.load_error == null);
    try std.testing.expect(!state.needs_wizard);

    // The only real path that ever allocator.create()s a threshold_cache
    // slot — mirrors what render() does every frame via AppState.update().
    state.update();

    try std.testing.expect(state.threshold_cache[0] != null);
    // state.deinit() (deferred above) must destroy() this exact pointer via
    // the same allocator that created it.
}
