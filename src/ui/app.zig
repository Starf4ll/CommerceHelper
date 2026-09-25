const std = @import("std");
const dvui = @import("dvui");

const goods_mod = @import("../data/goods.zig");
const routes_mod = @import("../data/routes.zig");
const config_mod = @import("../data/config.zig");
const onboarding = @import("onboarding.zig");
const settings = @import("settings.zig");

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
        if (self.show_settings) {
            try settings.render(&self.settings_state, self);
        } else {
            if (dvui.button(@src(), "Open Settings", .{}, .{})) {
                self.show_settings = true;
            }
        }
    }
};
