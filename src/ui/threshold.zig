// ui/threshold.zig — Threshold Mode table (Story 2.6)
const std = @import("std");
const dvui = @import("dvui");

const app_mod = @import("app.zig");
const AppState = app_mod.AppState;
const config_mod = @import("../data/config.zig");
const goods_mod = @import("../data/goods.zig");
const Good = goods_mod.Good;

/// Renders one placeholder label, centered, matching the "no data yet" style
/// used elsewhere in this tab.
fn placeholder(text: []const u8) void {
    dvui.label(@src(), "{s}", .{text}, .{
        .expand = .horizontal,
        .gravity_x = 0.5,
        .margin = .{ .y = 16, .x = 16 },
    });
}

pub fn renderTab(app_state: *AppState) !void {
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();

    const origin = app_state.config.?.origin;
    if (origin.len == 0) {
        placeholder("Select an Origin above");
        return;
    }

    // Resolve the origin's index fresh every frame — mirrors the linear scan
    // renderMainArea uses for the Origin dropdown. No second UI-level cache;
    // threshold_cache itself is kept fresh by AppState.update() each frame.
    var origin_idx: ?usize = null;
    for (config_mod.OUTPOST_KEYS, 0..) |key, i| {
        if (std.mem.eql(u8, origin, key)) {
            origin_idx = i;
            break;
        }
    }
    const idx = origin_idx orelse {
        placeholder("Select an Origin above");
        return;
    };

    const slot = app_state.threshold_cache[idx] orelse {
        placeholder("Select an Origin above");
        return;
    };

    const origin_goods = app_state.goods.?.get(origin) orelse &[_]goods_mod.Good{};

    // ── Header row ───────────────────────────────────────────────────────────
    {
        var header = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .x = 16, .y = 4 },
        });
        defer header.deinit();

        dvui.label(@src(), "Threshold", .{}, .{ .min_size_content = .{ .w = 70 } });
        dvui.label(@src(), "Good", .{}, .{ .min_size_content = .{ .w = 170 } });
        dvui.label(@src(), "Transport", .{}, .{ .min_size_content = .{ .w = 100 } });
        dvui.label(@src(), "Destination", .{}, .{ .min_size_content = .{ .w = 100 } });
        dvui.label(@src(), "Ducats/min", .{}, .{ .min_size_content = .{ .w = 100 } });
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal, .margin = .{ .x = 16, .y = 2 } });

    // ── Rows: one per configured Threshold, ascending, as sweepOrigin stored
    // them — no re-sorting here.
    for (slot.rows[0..slot.count], 0..) |row, row_idx| {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .x = 16, .y = 2 },
            .id_extra = row_idx,
        });
        defer hbox.deinit();

        dvui.label(@src(), "{d}", .{row.threshold}, .{
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 70 },
            .id_extra = row_idx,
        });

        if (!row.has_result) {
            dvui.label(@src(), "No route available", .{}, .{
                .gravity_y = 0.5,
                .expand = .horizontal,
                .id_extra = row_idx,
            });
            continue;
        }

        const good = origin_goods[row.good_idx];
        goodCell(good, row_idx, app_state);

        dvui.label(@src(), "{s}", .{row.transport_name}, .{
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 100 },
            .id_extra = row_idx,
        });

        dvui.label(@src(), "{s}", .{config_mod.OUTPOST_DISPLAY_NAMES[row.destination_idx]}, .{
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 100 },
            .id_extra = row_idx,
        });

        dvui.label(@src(), "{d:.1}", .{row.ducats_per_min}, .{
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 100 },
            .id_extra = row_idx,
        });
    }
}

/// Renders a Good's icon (if readable) + name, with its description as a
/// hover tooltip (AD-8). Icon read failure falls back to name-only, never
/// crashes — iconBytes() returns null on any read error.
fn goodCell(good: Good, id_extra: usize, app_state: *AppState) void {
    var wd: dvui.WidgetData = undefined;
    var cell = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 170 },
        .id_extra = id_extra,
        .data_out = &wd,
    });
    defer cell.deinit();

    if (app_state.iconBytes(good.image)) |bytes| {
        _ = dvui.image(@src(), .{
            .source = .{ .imageFile = .{ .bytes = bytes, .name = good.image } },
        }, .{
            .min_size_content = .{ .w = 20, .h = 20 },
            .gravity_y = 0.5,
            .margin = .{ .x = 4 },
            .id_extra = id_extra,
        });
    }

    dvui.label(@src(), "{s}", .{good.name}, .{
        .gravity_y = 0.5,
        .id_extra = id_extra,
    });

    dvui.tooltip(
        @src(),
        .{ .active_rect = wd.borderRectScale().r },
        "{s}",
        .{good.description},
        .{ .id_extra = id_extra },
    );
}
