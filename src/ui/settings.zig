const std = @import("std");
const dvui = @import("dvui");

const app_mod = @import("app.zig");
const config_mod = @import("../data/config.zig");
const routes_mod = @import("../data/routes.zig");

const AppState = app_mod.AppState;
const Config = config_mod.Config;
const RouteData = routes_mod.RouteData;

// ── SettingsState ─────────────────────────────────────────────────────────────

pub const SettingsState = struct {
    // Write-failure error message (null = no error).
    // Always set from @errorName(), which returns a comptime string literal —
    // this slice has static lifetime and must never be freed.
    write_error: ?[]const u8 = null,

    // Which Settings sub-tab is currently visible. Purely a display selector —
    // fields on either tab still save immediately on change, tab switches never
    // discard or delay a save (see spec-destination-order-settings-toggle-and-tabs).
    settings_tab: enum { general, route_times } = .general,
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
        .TooSmall => {
            value.* = 1;
        },
        .TooBig => {
            value.* = 9;
        },
        else => {},
    }
}

/// Render a labeled u32 integer entry (percentages, route-time seconds, etc.).
/// u32 cannot go negative so no clamping is needed; the field is always valid
/// once rendered.
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

/// Returns true if at least one Transport checkbox is enabled. Mirrors
/// onboarding.zig's identical check on WizardState — Settings must enforce
/// the same "at least one transport" invariant that onboarding's Confirm
/// gate and loadConfig's own load-time validation already enforce, or a
/// zero-transport Config saved here would fail to reload on next launch.
fn anyTransportSelected(t: config_mod.TransportFlags) bool {
    return t.backpack or t.handcart or t.wagon or t.packElephant or
        t.alpaca or t.dogSled or t.camel or t.tradersSkiff;
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

    // ── Sub-tab selector row ───────────────────────────────────────────────────
    {
        var tab_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .x = 8, .y = 2 },
        });
        defer tab_row.deinit();

        const general_active = state.settings_tab == .general;
        const route_times_active = state.settings_tab == .route_times;

        if (dvui.button(@src(), "General", .{}, .{
            .margin = .{ .x = 2 },
            .color_fill = if (general_active)
                dvui.Color{ .r = 80, .g = 120, .b = 200, .a = 255 }
            else
                dvui.Color{ .r = 60, .g = 60, .b = 60, .a = 255 },
        })) {
            state.settings_tab = .general;
        }

        if (dvui.button(@src(), "Route Times", .{}, .{
            .margin = .{ .x = 2 },
            .color_fill = if (route_times_active)
                dvui.Color{ .r = 80, .g = 120, .b = 200, .a = 255 }
            else
                dvui.Color{ .r = 60, .g = 60, .b = 60, .a = 255 },
        })) {
            state.settings_tab = .route_times;
        }
    }

    if (state.settings_tab == .general) {
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
            ratingRow("Emain Macha", &app_state.config.?.merchantRatings.emainMacha, 3);
            ratingRow("Taillteann", &app_state.config.?.merchantRatings.taillteann, 4);
            ratingRow("Tara", &app_state.config.?.merchantRatings.tara, 5);
            ratingRow("Cobh", &app_state.config.?.merchantRatings.cobh, 6);
            ratingRow("Belvast", &app_state.config.?.merchantRatings.belvast, 7);
            ratingRow("Qilla", &app_state.config.?.merchantRatings.qilla, 8);
            ratingRow("Filia", &app_state.config.?.merchantRatings.filia, 9);
            ratingRow("Cor", &app_state.config.?.merchantRatings.cor, 10);
            ratingRow("Vales", &app_state.config.?.merchantRatings.vales, 11);
        }
    }

    if (state.settings_tab == .route_times) {
        // ── Section: Route Times (seconds) ───────────────────────────────────────
        // Snapshot before rendering so saveRoutes can detect changes and revert
        // on write failure. Raw RouteData fields are edited directly (not the
        // computed matrix) — see spec-2-5 Design Notes for why.
        const routes_before: RouteData = app_state.routes.?;

        // -- Boat ports (4 subsections, 20 fields) --------------------------------
        {
            dvui.label(@src(), "Port: Belvast", .{}, .{ .expand = .horizontal, .margin = .{ .y = 4, .x = 24 } });
            {
                var vbox = dvui.box(@src(), .{}, .{ .expand = .horizontal, .margin = .{ .x = 32, .y = 2 } });
                defer vbox.deinit();
                percentRow("From Cobh", &app_state.routes.?.boats.portBelvast.fromCobh, 0);
                percentRow("Wait", &app_state.routes.?.boats.portBelvast.wait, 1);
                percentRow("Travel", &app_state.routes.?.boats.portBelvast.travel, 2);
                percentRow("To Belvast", &app_state.routes.?.boats.portBelvast.toBelvast, 3);
                percentRow("Belvast Boat to Qilla Boat", &app_state.routes.?.boats.portBelvast.belvastBoatToQillaBoat, 4);
            }
            _ = dvui.separator(@src(), .{ .expand = .horizontal, .margin = .{ .x = 16, .y = 4 } });
        }

        {
            dvui.label(@src(), "Port: Qilla", .{}, .{ .expand = .horizontal, .margin = .{ .y = 4, .x = 24 } });
            {
                var vbox = dvui.box(@src(), .{}, .{ .expand = .horizontal, .margin = .{ .x = 32, .y = 2 } });
                defer vbox.deinit();
                percentRow("From Cobh", &app_state.routes.?.boats.portQilla.fromCobh, 0);
                percentRow("Wait", &app_state.routes.?.boats.portQilla.wait, 1);
                percentRow("Travel", &app_state.routes.?.boats.portQilla.travel, 2);
                percentRow("To Qilla", &app_state.routes.?.boats.portQilla.toQilla, 3);
                percentRow("To Cor", &app_state.routes.?.boats.portQilla.toCor, 4);
            }
            _ = dvui.separator(@src(), .{ .expand = .horizontal, .margin = .{ .x = 16, .y = 4 } });
        }

        {
            dvui.label(@src(), "Port: Sella", .{}, .{ .expand = .horizontal, .margin = .{ .y = 4, .x = 24 } });
            {
                var vbox = dvui.box(@src(), .{}, .{ .expand = .horizontal, .margin = .{ .x = 32, .y = 2 } });
                defer vbox.deinit();
                percentRow("From Bangor", &app_state.routes.?.boats.portSella.fromBangor, 0);
                percentRow("Wait", &app_state.routes.?.boats.portSella.wait, 1);
                percentRow("Travel", &app_state.routes.?.boats.portSella.travel, 2);
                percentRow("To Vales", &app_state.routes.?.boats.portSella.toVales, 3);
                percentRow("To Cor", &app_state.routes.?.boats.portSella.toCor, 4);
            }
            _ = dvui.separator(@src(), .{ .expand = .horizontal, .margin = .{ .x = 16, .y = 4 } });
        }

        {
            dvui.label(@src(), "Port: Connous", .{}, .{ .expand = .horizontal, .margin = .{ .y = 4, .x = 24 } });
            {
                var vbox = dvui.box(@src(), .{}, .{ .expand = .horizontal, .margin = .{ .x = 32, .y = 2 } });
                defer vbox.deinit();
                percentRow("From Bangor", &app_state.routes.?.boats.portConnous.fromBangor, 0);
                percentRow("Wait", &app_state.routes.?.boats.portConnous.wait, 1);
                percentRow("Travel", &app_state.routes.?.boats.portConnous.travel, 2);
                percentRow("To Filia", &app_state.routes.?.boats.portConnous.toFilia, 3);
                percentRow("To Cor", &app_state.routes.?.boats.portConnous.toCor, 4);
            }
            _ = dvui.separator(@src(), .{ .expand = .horizontal, .margin = .{ .x = 16, .y = 4 } });
        }

        // -- Uladh outposts (7 subsections, 42 fields) ----------------------------
        {
            dvui.label(@src(), "Tir Chonaill", .{}, .{ .expand = .horizontal, .margin = .{ .y = 4, .x = 24 } });
            {
                var vbox = dvui.box(@src(), .{}, .{ .expand = .horizontal, .margin = .{ .x = 32, .y = 2 } });
                defer vbox.deinit();
                percentRow("To Dunbarton", &app_state.routes.?.tirChonaill.dunbarton, 0);
                percentRow("To Bangor", &app_state.routes.?.tirChonaill.bangor, 1);
                percentRow("To Emain Macha", &app_state.routes.?.tirChonaill.emainMacha, 2);
                percentRow("To Taillteann", &app_state.routes.?.tirChonaill.taillteann, 3);
                percentRow("To Tara", &app_state.routes.?.tirChonaill.tara, 4);
                percentRow("To Cobh", &app_state.routes.?.tirChonaill.cobh, 5);
            }
            _ = dvui.separator(@src(), .{ .expand = .horizontal, .margin = .{ .x = 16, .y = 4 } });
        }

        {
            dvui.label(@src(), "Dunbarton", .{}, .{ .expand = .horizontal, .margin = .{ .y = 4, .x = 24 } });
            {
                var vbox = dvui.box(@src(), .{}, .{ .expand = .horizontal, .margin = .{ .x = 32, .y = 2 } });
                defer vbox.deinit();
                percentRow("To Tir Chonaill", &app_state.routes.?.dunbarton.tirChonaill, 0);
                percentRow("To Bangor", &app_state.routes.?.dunbarton.bangor, 1);
                percentRow("To Emain Macha", &app_state.routes.?.dunbarton.emainMacha, 2);
                percentRow("To Taillteann", &app_state.routes.?.dunbarton.taillteann, 3);
                percentRow("To Tara", &app_state.routes.?.dunbarton.tara, 4);
                percentRow("To Cobh", &app_state.routes.?.dunbarton.cobh, 5);
            }
            _ = dvui.separator(@src(), .{ .expand = .horizontal, .margin = .{ .x = 16, .y = 4 } });
        }

        {
            dvui.label(@src(), "Bangor", .{}, .{ .expand = .horizontal, .margin = .{ .y = 4, .x = 24 } });
            {
                var vbox = dvui.box(@src(), .{}, .{ .expand = .horizontal, .margin = .{ .x = 32, .y = 2 } });
                defer vbox.deinit();
                percentRow("To Tir Chonaill", &app_state.routes.?.bangor.tirChonaill, 0);
                percentRow("To Dunbarton", &app_state.routes.?.bangor.dunbarton, 1);
                percentRow("To Emain Macha", &app_state.routes.?.bangor.emainMacha, 2);
                percentRow("To Taillteann", &app_state.routes.?.bangor.taillteann, 3);
                percentRow("To Tara", &app_state.routes.?.bangor.tara, 4);
                percentRow("To Cobh", &app_state.routes.?.bangor.cobh, 5);
            }
            _ = dvui.separator(@src(), .{ .expand = .horizontal, .margin = .{ .x = 16, .y = 4 } });
        }

        {
            dvui.label(@src(), "Emain Macha", .{}, .{ .expand = .horizontal, .margin = .{ .y = 4, .x = 24 } });
            {
                var vbox = dvui.box(@src(), .{}, .{ .expand = .horizontal, .margin = .{ .x = 32, .y = 2 } });
                defer vbox.deinit();
                percentRow("To Tir Chonaill", &app_state.routes.?.emainMacha.tirChonaill, 0);
                percentRow("To Dunbarton", &app_state.routes.?.emainMacha.dunbarton, 1);
                percentRow("To Bangor", &app_state.routes.?.emainMacha.bangor, 2);
                percentRow("To Taillteann", &app_state.routes.?.emainMacha.taillteann, 3);
                percentRow("To Tara", &app_state.routes.?.emainMacha.tara, 4);
                percentRow("To Cobh", &app_state.routes.?.emainMacha.cobh, 5);
            }
            _ = dvui.separator(@src(), .{ .expand = .horizontal, .margin = .{ .x = 16, .y = 4 } });
        }

        {
            dvui.label(@src(), "Taillteann", .{}, .{ .expand = .horizontal, .margin = .{ .y = 4, .x = 24 } });
            {
                var vbox = dvui.box(@src(), .{}, .{ .expand = .horizontal, .margin = .{ .x = 32, .y = 2 } });
                defer vbox.deinit();
                percentRow("To Tir Chonaill", &app_state.routes.?.taillteann.tirChonaill, 0);
                percentRow("To Dunbarton", &app_state.routes.?.taillteann.dunbarton, 1);
                percentRow("To Bangor", &app_state.routes.?.taillteann.bangor, 2);
                percentRow("To Emain Macha", &app_state.routes.?.taillteann.emainMacha, 3);
                percentRow("To Tara", &app_state.routes.?.taillteann.tara, 4);
                percentRow("To Cobh", &app_state.routes.?.taillteann.cobh, 5);
            }
            _ = dvui.separator(@src(), .{ .expand = .horizontal, .margin = .{ .x = 16, .y = 4 } });
        }

        {
            dvui.label(@src(), "Tara", .{}, .{ .expand = .horizontal, .margin = .{ .y = 4, .x = 24 } });
            {
                var vbox = dvui.box(@src(), .{}, .{ .expand = .horizontal, .margin = .{ .x = 32, .y = 2 } });
                defer vbox.deinit();
                percentRow("To Tir Chonaill", &app_state.routes.?.tara.tirChonaill, 0);
                percentRow("To Dunbarton", &app_state.routes.?.tara.dunbarton, 1);
                percentRow("To Bangor", &app_state.routes.?.tara.bangor, 2);
                percentRow("To Emain Macha", &app_state.routes.?.tara.emainMacha, 3);
                percentRow("To Taillteann", &app_state.routes.?.tara.taillteann, 4);
                percentRow("To Cobh", &app_state.routes.?.tara.cobh, 5);
            }
            _ = dvui.separator(@src(), .{ .expand = .horizontal, .margin = .{ .x = 16, .y = 4 } });
        }

        {
            dvui.label(@src(), "Cobh", .{}, .{ .expand = .horizontal, .margin = .{ .y = 4, .x = 24 } });
            {
                var vbox = dvui.box(@src(), .{}, .{ .expand = .horizontal, .margin = .{ .x = 32, .y = 2 } });
                defer vbox.deinit();
                percentRow("To Tir Chonaill", &app_state.routes.?.cobh.tirChonaill, 0);
                percentRow("To Dunbarton", &app_state.routes.?.cobh.dunbarton, 1);
                percentRow("To Bangor", &app_state.routes.?.cobh.bangor, 2);
                percentRow("To Emain Macha", &app_state.routes.?.cobh.emainMacha, 3);
                percentRow("To Taillteann", &app_state.routes.?.cobh.taillteann, 4);
                percentRow("To Tara", &app_state.routes.?.cobh.tara, 5);
            }
            _ = dvui.separator(@src(), .{ .expand = .horizontal, .margin = .{ .x = 16, .y = 4 } });
        }

        // -- Iria outposts (4 subsections, 12 fields) -----------------------------
        {
            dvui.label(@src(), "Qilla", .{}, .{ .expand = .horizontal, .margin = .{ .y = 4, .x = 24 } });
            {
                var vbox = dvui.box(@src(), .{}, .{ .expand = .horizontal, .margin = .{ .x = 32, .y = 2 } });
                defer vbox.deinit();
                percentRow("To Vales", &app_state.routes.?.qilla.vales, 0);
                percentRow("To Filia", &app_state.routes.?.qilla.filia, 1);
                percentRow("To Cor", &app_state.routes.?.qilla.cor, 2);
            }
            _ = dvui.separator(@src(), .{ .expand = .horizontal, .margin = .{ .x = 16, .y = 4 } });
        }

        {
            dvui.label(@src(), "Filia", .{}, .{ .expand = .horizontal, .margin = .{ .y = 4, .x = 24 } });
            {
                var vbox = dvui.box(@src(), .{}, .{ .expand = .horizontal, .margin = .{ .x = 32, .y = 2 } });
                defer vbox.deinit();
                percentRow("To Qilla", &app_state.routes.?.filia.qilla, 0);
                percentRow("To Vales", &app_state.routes.?.filia.vales, 1);
                percentRow("To Cor", &app_state.routes.?.filia.cor, 2);
            }
            _ = dvui.separator(@src(), .{ .expand = .horizontal, .margin = .{ .x = 16, .y = 4 } });
        }

        {
            dvui.label(@src(), "Cor", .{}, .{ .expand = .horizontal, .margin = .{ .y = 4, .x = 24 } });
            {
                var vbox = dvui.box(@src(), .{}, .{ .expand = .horizontal, .margin = .{ .x = 32, .y = 2 } });
                defer vbox.deinit();
                percentRow("To Qilla", &app_state.routes.?.cor.qilla, 0);
                percentRow("To Vales", &app_state.routes.?.cor.vales, 1);
                percentRow("To Filia", &app_state.routes.?.cor.filia, 2);
            }
            _ = dvui.separator(@src(), .{ .expand = .horizontal, .margin = .{ .x = 16, .y = 4 } });
        }

        {
            dvui.label(@src(), "Vales", .{}, .{ .expand = .horizontal, .margin = .{ .y = 4, .x = 24 } });
            {
                var vbox = dvui.box(@src(), .{}, .{ .expand = .horizontal, .margin = .{ .x = 32, .y = 2 } });
                defer vbox.deinit();
                percentRow("To Qilla", &app_state.routes.?.vales.qilla, 0);
                percentRow("To Filia", &app_state.routes.?.vales.filia, 1);
                percentRow("To Cor", &app_state.routes.?.vales.cor, 2);
            }
            _ = dvui.separator(@src(), .{ .expand = .horizontal, .margin = .{ .x = 16, .y = 4 } });
        }

        // Persist any route-field edit this frame (no-op if nothing changed).
        // Rebuild of route_matrix and threshold cache invalidation happen inside
        // saveRoutes — settings.zig never touches engine/matrix.zig directly.
        app_state.saveRoutes(routes_before);
    }

    // ── Save-and-compare: write if any value-type field changed ───────────────
    const cfg = app_state.config.?;
    if (valueFieldsChanged(before, cfg)) {
        var write_ok = true;
        if (!anyTransportSelected(cfg.transports)) {
            write_ok = false;
            state.write_error = "At least one transport is required";
            app_state.config.? = before; // revert in-frame mutations
        } else {
            config_mod.writeConfig(cfg, app_state.allocator, app_state.exe_dir) catch |err| {
                write_ok = false;
                state.write_error = @errorName(err);
                app_state.config.? = before; // revert in-frame mutations
            };
        }
        app_state.threshold_cache_stale = true;
        // Only clear the shared write_error on this block's own write success —
        // otherwise this would clobber an error this same block just set above,
        // or one saveRoutes() set moments earlier in this same render pass.
        if (write_ok) state.write_error = null;
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

// ── Tests ─────────────────────────────────────────────────────────────────────

test "valueFieldsChanged: identical Configs → false" {
    const a = Config{};
    const b = Config{};
    try std.testing.expect(!valueFieldsChanged(a, b));
}

test "valueFieldsChanged: transports differ → true" {
    const a = Config{};
    var b = Config{};
    b.transports.wagon = true;
    try std.testing.expect(valueFieldsChanged(a, b));
}

test "valueFieldsChanged: commercePartner differs → true" {
    const a = Config{};
    var b = Config{};
    b.commercePartner = true;
    try std.testing.expect(valueFieldsChanged(a, b));
}

test "valueFieldsChanged: grandmasterTitle differs → true" {
    const a = Config{};
    var b = Config{};
    b.grandmasterTitle = true;
    try std.testing.expect(valueFieldsChanged(a, b));
}

test "valueFieldsChanged: merchantRatings differs → true" {
    const a = Config{};
    var b = Config{};
    b.merchantRatings.bangor = 5;
    try std.testing.expect(valueFieldsChanged(a, b));
}

test "valueFieldsChanged: speedBonus differs → true" {
    const a = Config{};
    var b = Config{};
    b.speedBonus = 10;
    try std.testing.expect(valueFieldsChanged(a, b));
}

test "valueFieldsChanged: gearDiscount differs → true" {
    const a = Config{};
    var b = Config{};
    b.gearDiscount = 5;
    try std.testing.expect(valueFieldsChanged(a, b));
}

test "valueFieldsChanged: origin differs → false (excluded by design)" {
    const a = Config{};
    var b = Config{};
    b.origin = "dunbarton";
    try std.testing.expect(!valueFieldsChanged(a, b));
}

test "anyTransportSelected: all false → false" {
    try std.testing.expect(!anyTransportSelected(.{}));
}

test "anyTransportSelected: any one true → true" {
    try std.testing.expect(anyTransportSelected(.{ .backpack = true }));
    try std.testing.expect(anyTransportSelected(.{ .tradersSkiff = true }));
}
