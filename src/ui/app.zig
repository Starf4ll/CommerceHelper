const std = @import("std");
const dvui = @import("dvui");

const goods_mod = @import("../data/goods.zig");
const routes_mod = @import("../data/routes.zig");
const config_mod = @import("../data/config.zig");
const onboarding = @import("onboarding.zig");
const settings = @import("settings.zig");
const threshold = @import("threshold.zig");
const live = @import("live.zig");

pub const GoodsMap = goods_mod.GoodsMap;
pub const RouteData = routes_mod.RouteData;
pub const Config = config_mod.Config;

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

    pub fn init(allocator: std.mem.Allocator, exe_dir: []const u8) AppState {
        var state = AppState{
            .allocator = allocator,
            .exe_dir = exe_dir,
            .routes = null,
            .goods = null,
            .config = null,
            .needs_wizard = false,
            .load_error = null,
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
    }

    // ── Internal helpers ──────────────────────────────────────────────────────

    fn runStartupSequence(self: *AppState) void {
        // 1. Load routes.json — required; on failure set load_error and return.
        if (routes_mod.loadRoutes(self.allocator, self.exe_dir)) |r| {
            self.routes = r;
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

    /// Called once per frame from main.zig inside win.begin/end.
    /// Returns an error only for unrecoverable dvui failures.
    pub fn render(self: *AppState) !void {
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
        // TODO(Epic 3): clear live inputs here
    }
};
