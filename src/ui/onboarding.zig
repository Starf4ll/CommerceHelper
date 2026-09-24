const std = @import("std");
const dvui = @import("dvui");

const app_mod = @import("app.zig");
const config_mod = @import("../data/config.zig");

const AppState = app_mod.AppState;

// ── WizardState ───────────────────────────────────────────────────────────────

pub const WizardState = struct {
    // Transport checkboxes
    backpack: bool = false,
    handcart: bool = false,
    wagon: bool = false,
    packElephant: bool = false,
    alpaca: bool = false,
    dogSled: bool = false,
    camel: bool = false,
    tradersSkiff: bool = false,

    // Modifier toggles
    commercePartner: bool = false,
    grandmasterTitle: bool = false,

    // Merchant ratings (1–9)
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

    // Percentage bonuses (integer whole-percent values; u32 serialises as 0 not 0e0)
    speedBonus: u32 = 0,
    gearDiscount: u32 = 0,

    // Write-failure error message (null = no error).
    // Always set from @errorName(), which returns a comptime string literal —
    // this slice has static lifetime and must never be freed.
    write_error: ?[]const u8 = null,
};

// ── Helpers ───────────────────────────────────────────────────────────────────

fn anyTransportSelected(s: *const WizardState) bool {
    return s.backpack or s.handcart or s.wagon or s.packElephant or
        s.alpaca or s.dogSled or s.camel or s.tradersSkiff;
}

/// Render a labeled u8 number entry that clamps to [min_val, max_val] on every
/// frame.  Uses dvui.textEntryNumber internally; id_extra differentiates
/// multiple calls at the same @src().
/// IMPORTANT: id_extra values must be stable sequential integers matching call
/// order — reordering calls without updating id_extra will corrupt dvui widget
/// identity and cause stale input state.
/// Returns true when the current value is in bounds, false when the field is
/// showing red (TooSmall or TooBig).  Callers accumulate this to gate Confirm.
fn ratingRow(
    comptime label: []const u8,
    value: *u8,
    id_extra: usize,
) bool {
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
        .TooSmall => { value.* = 1; return false; },
        .TooBig => { value.* = 9; return false; },
        else => return true,
    }
}

/// Render a labeled u32 integer-percent entry.  u32 cannot go negative so no
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

// ── render ────────────────────────────────────────────────────────────────────

pub fn render(state: *WizardState, app_state: *AppState) !void {
    // Full-window scroll area so the form is usable at any window size.
    var scroll = dvui.scrollArea(
        @src(),
        .{},
        .{ .expand = .both },
    );
    defer scroll.deinit();

    // ── Title ────────────────────────────────────────────────────────────────
    dvui.label(@src(), "Character Setup", .{}, .{
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

        _ = dvui.checkbox(@src(), &state.backpack, "Backpack", .{});
        _ = dvui.checkbox(@src(), &state.handcart, "Handcart", .{});
        _ = dvui.checkbox(@src(), &state.wagon, "Wagon", .{});
        _ = dvui.checkbox(@src(), &state.packElephant, "Pack Elephant", .{});
        _ = dvui.checkbox(@src(), &state.alpaca, "Alpaca", .{});
        _ = dvui.checkbox(@src(), &state.dogSled, "Dog Sled", .{});
        _ = dvui.checkbox(@src(), &state.camel, "Camel", .{});
        _ = dvui.checkbox(@src(), &state.tradersSkiff, "Trader's Skiff", .{});
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

        _ = dvui.checkbox(@src(), &state.commercePartner, "Commerce Partner", .{});
        _ = dvui.checkbox(@src(), &state.grandmasterTitle, "Grandmaster Title", .{});
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

        percentRow("Speed Bonus (%)", &state.speedBonus, 0);
        percentRow("Gear Discount (%)", &state.gearDiscount, 1);
    }

    // ── Section: Merchant Ratings ────────────────────────────────────────────
    dvui.label(@src(), "Merchant Ratings (1–9)", .{}, .{
        .expand = .horizontal,
        .margin = .{ .y = 4, .x = 16 },
    });

    // Accumulate rating validity; ratingRow() always renders, always returns
    // false while showing red.  Left-operand placement ensures no row is skipped.
    var all_ratings_valid = true;
    {
        var vbox = dvui.box(@src(), .{}, .{
            .expand = .horizontal,
            .margin = .{ .x = 32, .y = 2 },
        });
        defer vbox.deinit();

        all_ratings_valid = ratingRow("Tir Chonaill", &state.tirChonaill, 0) and all_ratings_valid;
        all_ratings_valid = ratingRow("Dunbarton", &state.dunbarton, 1) and all_ratings_valid;
        all_ratings_valid = ratingRow("Bangor", &state.bangor, 2) and all_ratings_valid;
        all_ratings_valid = ratingRow("Cobh", &state.cobh, 3) and all_ratings_valid;
        all_ratings_valid = ratingRow("Tara", &state.tara, 4) and all_ratings_valid;
        all_ratings_valid = ratingRow("Emain Macha", &state.emainMacha, 5) and all_ratings_valid;
        all_ratings_valid = ratingRow("Taillteann", &state.taillteann, 6) and all_ratings_valid;
        all_ratings_valid = ratingRow("Belvast", &state.belvast, 7) and all_ratings_valid;
        all_ratings_valid = ratingRow("Qilla", &state.qilla, 8) and all_ratings_valid;
        all_ratings_valid = ratingRow("Cor", &state.cor, 9) and all_ratings_valid;
        all_ratings_valid = ratingRow("Filia", &state.filia, 10) and all_ratings_valid;
        all_ratings_valid = ratingRow("Vales", &state.vales, 11) and all_ratings_valid;
    }

    // ── Write-error feedback ─────────────────────────────────────────────────
    if (state.write_error) |msg| {
        dvui.label(@src(), "Error: {s}", .{msg}, .{
            .expand = .horizontal,
            .margin = .{ .y = 4, .x = 16 },
            .color_text = .{ .r = 200, .g = 50, .b = 50, .a = 255 },
        });
    }

    // ── Confirm button ───────────────────────────────────────────────────────
    {
        const can_confirm = anyTransportSelected(state) and all_ratings_valid;

        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .gravity_x = 0.5,
            .margin = .{ .y = 12, .x = 16 },
        });
        defer hbox.deinit();

        if (can_confirm) {
            if (dvui.button(@src(), "Confirm", .{}, .{})) {
                // Build Config from wizard state.
                const origin = try app_state.allocator.dupe(u8, "");
                const config = config_mod.Config{
                    .origin = origin,
                    .transports = .{
                        .backpack = state.backpack,
                        .handcart = state.handcart,
                        .wagon = state.wagon,
                        .packElephant = state.packElephant,
                        .alpaca = state.alpaca,
                        .dogSled = state.dogSled,
                        .camel = state.camel,
                        .tradersSkiff = state.tradersSkiff,
                    },
                    .commercePartner = state.commercePartner,
                    .grandmasterTitle = state.grandmasterTitle,
                    .merchantRatings = .{
                        .tirChonaill = state.tirChonaill,
                        .dunbarton = state.dunbarton,
                        .bangor = state.bangor,
                        .cobh = state.cobh,
                        .tara = state.tara,
                        .emainMacha = state.emainMacha,
                        .taillteann = state.taillteann,
                        .belvast = state.belvast,
                        .qilla = state.qilla,
                        .cor = state.cor,
                        .filia = state.filia,
                        .vales = state.vales,
                    },
                    .speedBonus = state.speedBonus,
                    .gearDiscount = state.gearDiscount,
                };

                config_mod.writeConfig(config, app_state.allocator, app_state.exe_dir) catch |err| {
                    // Free the origin we just allocated since the config won't
                    // be stored in app_state.
                    app_state.allocator.free(origin);
                    // Show error near Confirm and re-enable the button next frame.
                    state.write_error = @errorName(err);
                    return;
                };

                // Free any previously-stored config before replacing it.
                if (app_state.config) |*old| {
                    config_mod.deinitConfig(old, app_state.allocator);
                }
                app_state.config = config;
                app_state.needs_wizard = false;
                state.write_error = null;
            }
        } else {
            // Disabled appearance: blend text and fill colors, skip event processing.
            const control_opts: dvui.Options = .{};
            const blended = dvui.Color.average(
                control_opts.color(.text),
                control_opts.color(.fill),
            );
            var bw = dvui.ButtonWidget.init(@src(), .{}, .{
                .color_text = blended,
                .tab_index = 0, // exclude from tab order
            });
            bw.install();
            // Do NOT call bw.processEvents() — button is non-interactive.
            bw.drawBackground();
            bw.drawFocus();
            defer bw.deinit();

            {
                var inner = dvui.box(@src(), .{ .dir = .horizontal }, bw.data().options.strip().override(.{ .gravity_y = 0.5 }));
                defer inner.deinit();
                dvui.labelNoFmt(@src(), "Confirm", .{}, bw.data().options.strip().override(.{ .gravity_x = 0.5, .gravity_y = 0.5 }));
            }
        }
    }
}
