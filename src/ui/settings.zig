const std = @import("std");
const dvui = @import("dvui");

const app_mod = @import("app.zig");
const config_mod = @import("../data/config.zig");

const AppState = app_mod.AppState;
const Config = config_mod.Config;

// ── SettingsState ─────────────────────────────────────────────────────────────

pub const SettingsState = struct {
    // Write-failure error message (null = no error).
    // Always set from @errorName(), which returns a comptime string literal —
    // this slice has static lifetime and must never be freed.
    write_error: ?[]const u8 = null,
};

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Render a labeled u8 number entry that clamps to [1, 9] on every frame.
/// Uses dvui.textEntryNumber internally; id_extra differentiates multiple
/// calls at the same @src().
/// IMPORTANT: id_extra values must be stable sequential integers matching call
/// order — reordering calls without updating id_extra will corrupt dvui widget
/// identity and cause stale input state.
fn ratingRow(
    comptime label: []const u8,
    value: *u8,
    id_extra: usize,
) void {
    var hbox = dvui.box(
        @src(),
        .{ .dir = .horizontal },
        .{ .expand = .horizontal, .id_extra = id_extra },
    );
    defer hbox.deinit();

    dvui.label(
        @src(),
        label,
        .{},
        .{ .gravity_y = 0.5, .min_size_content = .{ .w = 130 }, .id_extra = id_extra },
    );

    const result = dvui.textEntryNumber(
        @src(),
        u8,
        .{ .value = value, .min = 1, .max = 9 },
        .{ .min_size_content = .{ .w = 50 }, .id_extra = id_extra },
    );

    switch (result.value) {
        .TooSmall => { value.* = 1; },
        .TooBig => { value.* = 9; },
        else => {},
    }
}

/// Render a labeled u32 integer-percent entry. u32 cannot go negative so no
/// clamping is needed; the field is always valid once rendered.
fn percentRow(
    comptime label: []const u8,
    value: *u32,
    id_extra: usize,
) void {
    var hbox = dvui.box(
        @src(),
        .{ .dir = .horizontal },
        .{ .expand = .horizontal, .id_extra = id_extra },
    );
    defer hbox.deinit();

    dvui.label(
        @src(),
        label,
        .{},
        .{ .gravity_y = 0.5, .min_size_content = .{ .w = 130 }, .id_extra = id_extra },
    );

    _ = dvui.textEntryNumber(
        @src(),
        u32,
        .{ .value = value },
        .{ .min_size_content = .{ .w = 70 }, .id_extra = id_extra },
    );
}

/// Compare two Config values — returns true if any value-type field differs.
/// `origin` is excluded: it is not editable in Settings (Story 1.5 handles it).
fn valueFieldsChanged(a: Config, b: Config) bool {
    return !std.meta.eql(a.transports, b.transports) or
        a.commercePartner != b.commercePartner or
        a.grandmasterTitle != b.grandmasterTitle or
        !std.meta.eql(a.merchantRatings, b.merchantRatings) or
        a.speedBonus != b.speedBonus or
        a.gearDiscount != b.gearDiscount;
}

// ── render ────────────────────────────────────────────────────────────────────

pub fn render(state: *SettingsState, app_state: *AppState) !void {
    // Snapshot before rendering so we can detect changes afterward.
    const before = app_state.config.?;

    // Full-window scroll area so the form is usable at any window size.
    var scroll = dvui.scrollArea(
        @src(),
        .{},
        .{ .expand = .both },
    );
    defer scroll.deinit();

    // ── Title ────────────────────────────────────────────────────────────────
    dvui.label(@src(), "Settings", .{}, .{
        .expand = .horizontal,
        .gravity_x = 0.5,
        .margin = .{ .y = 8, .x = 16 },
    });

    // ── Section: Transports ──────────────────────────────────────────────────
    dvui.label(@src(), "Available Transports", .{}, .{
        .expand = .horizontal,
        .margin = .{ .y = 4, .x = 16 },
    });

    {
        var vbox = dvui.box(@src(), .{}, .{
            .expand = .horizontal,
            .margin = .{ .x = 32, .y = 2 },
        });
        defer vbox.deinit();

        _ = dvui.checkbox(@src(), &app_state.config.?.transports.backpack, "Backpack", .{});
        _ = dvui.checkbox(@src(), &app_state.config.?.transports.handcart, "Handcart", .{});
        _ = dvui.checkbox(@src(), &app_state.config.?.transports.wagon, "Wagon", .{});
        _ = dvui.checkbox(@src(), &app_state.config.?.transports.packElephant, "Pack Elephant", .{});
        _ = dvui.checkbox(@src(), &app_state.config.?.transports.alpaca, "Alpaca", .{});
        _ = dvui.checkbox(@src(), &app_state.config.?.transports.dogSled, "Dog Sled", .{});
        _ = dvui.checkbox(@src(), &app_state.config.?.transports.camel, "Camel", .{});
        _ = dvui.checkbox(@src(), &app_state.config.?.transports.tradersSkiff, "Trader's Skiff", .{});
    }

    // ── Section: Modifiers ───────────────────────────────────────────────────
    dvui.label(@src(), "Active Modifiers", .{}, .{
        .expand = .horizontal,
        .margin = .{ .y = 4, .x = 16 },
    });

    {
        var vbox = dvui.box(@src(), .{}, .{
            .expand = .horizontal,
            .margin = .{ .x = 32, .y = 2 },
        });
        defer vbox.deinit();

        _ = dvui.checkbox(@src(), &app_state.config.?.commercePartner, "Commerce Partner", .{});
        _ = dvui.checkbox(@src(), &app_state.config.?.grandmasterTitle, "Grandmaster Title", .{});
    }

    // ── Section: Percentage Bonuses ──────────────────────────────────────────
    dvui.label(@src(), "Percentage Bonuses", .{}, .{
        .expand = .horizontal,
        .margin = .{ .y = 4, .x = 16 },
    });

    {
        var vbox = dvui.box(@src(), .{}, .{
            .expand = .horizontal,
            .margin = .{ .x = 32, .y = 2 },
        });
        defer vbox.deinit();

        percentRow("Speed Bonus (%)", &app_state.config.?.speedBonus, 0);
        percentRow("Gear Discount (%)", &app_state.config.?.gearDiscount, 1);
    }

    // ── Section: Merchant Ratings ─────────────────────────────────────────────
    dvui.label(@src(), "Merchant Ratings (1\u{2013}9)", .{}, .{
        .expand = .horizontal,
        .margin = .{ .y = 4, .x = 16 },
    });

    {
        var vbox = dvui.box(@src(), .{}, .{
            .expand = .horizontal,
            .margin = .{ .x = 32, .y = 2 },
        });
        defer vbox.deinit();

        ratingRow("Tir Chonaill", &app_state.config.?.merchantRatings.tirChonaill, 0);
        ratingRow("Dunbarton", &app_state.config.?.merchantRatings.dunbarton, 1);
        ratingRow("Bangor", &app_state.config.?.merchantRatings.bangor, 2);
        ratingRow("Cobh", &app_state.config.?.merchantRatings.cobh, 3);
        ratingRow("Tara", &app_state.config.?.merchantRatings.tara, 4);
        ratingRow("Emain Macha", &app_state.config.?.merchantRatings.emainMacha, 5);
        ratingRow("Taillteann", &app_state.config.?.merchantRatings.taillteann, 6);
        ratingRow("Belvast", &app_state.config.?.merchantRatings.belvast, 7);
        ratingRow("Qilla", &app_state.config.?.merchantRatings.qilla, 8);
        ratingRow("Cor", &app_state.config.?.merchantRatings.cor, 9);
        ratingRow("Filia", &app_state.config.?.merchantRatings.filia, 10);
        ratingRow("Vales", &app_state.config.?.merchantRatings.vales, 11);
    }

    // ── Save-and-compare: write if any value-type field changed ───────────────
    const cfg = app_state.config.?;
    if (valueFieldsChanged(before, cfg)) {
        config_mod.writeConfig(cfg, app_state.allocator, app_state.exe_dir) catch |err| {
            state.write_error = @errorName(err);
            app_state.config.? = before; // revert in-frame mutations
        };
        app_state.engine_dirty = true;
        state.write_error = null;
    }

    // ── Write-error feedback ──────────────────────────────────────────────────
    if (state.write_error) |msg| {
        dvui.label(@src(), "Error: {s}", .{msg}, .{
            .expand = .horizontal,
            .margin = .{ .y = 4, .x = 16 },
            .color_text = .{ .r = 200, .g = 50, .b = 50, .a = 255 },
        });
    }

    // ── Close Settings button ─────────────────────────────────────────────────
    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .gravity_x = 0.5,
            .margin = .{ .y = 12, .x = 16 },
        });
        defer hbox.deinit();

        if (dvui.button(@src(), "Close Settings", .{}, .{})) {
            app_state.show_settings = false;
        }
    }
}
