// ui/threshold.zig — Threshold Mode Good sub-tabs (Story 4.2)
const std = @import("std");
const dvui = @import("dvui");

const app_mod = @import("app.zig");
const AppState = app_mod.AppState;
const config_mod = @import("../data/config.zig");
const goods_mod = @import("../data/goods.zig");
const Good = goods_mod.Good;

/// Persistent UI state for the "add new threshold" input row (Story 2.7) and
/// the active Good sub-tab (Story 4.2), stored on AppState exactly like
/// SettingsState/settings_state.
pub const ThresholdState = struct {
    new_value: u32 = 0,
    error_msg: ?[]const u8 = null,

    /// Index into the current Origin's eligible-Good slots
    /// (`slot.cells[0..slot.good_count]`), mirroring
    /// `SettingsState.settings_tab`'s placement. Reset/clamped every frame in
    /// `renderTab` whenever it is out of range for the current Origin's
    /// `good_count` — never assumed valid across an Origin switch.
    active_good_idx: usize = 0,
};

/// Renders one placeholder label, centered, matching the "no data yet" style
/// used elsewhere in this tab.
fn placeholder(text: []const u8) void {
    dvui.label(@src(), "{s}", .{text}, .{
        .expand = .horizontal,
        .gravity_x = 0.5,
        .margin = .{ .y = 16, .x = 16 },
    });
}

/// Clamps `active_good_idx` to a valid sub-tab index for `good_count`
/// eligible Goods at the current Origin — falls back to 0 whenever the
/// previous index is out of range (including `good_count == 0`, where 0
/// simply remains the resting value until a Good becomes eligible again).
/// Pure/dvui-free so the Origin-switch reset behavior is directly
/// unit-testable, unlike the render code that calls it.
fn clampActiveGoodIdx(active_good_idx: usize, good_count: u8) usize {
    if (active_good_idx >= good_count) return 0;
    return active_good_idx;
}

/// Selects the placeholder message for a zero-eligible-Goods Origin (I/O
/// matrix's "No eligible Goods" row) — matches `ui/live.zig`'s existing
/// wording verbatim for consistency. Returns null when there's at least one
/// eligible Good, telling the caller to render the sub-tab row instead.
/// Pure/dvui-free so it's directly unit-testable — mirrors `live.zig`'s
/// `resultsMessage` convention.
fn noGoodsPlaceholder(good_count: u8) ?[]const u8 {
    if (good_count == 0) return "No Goods available at your Merchant Rating for this Origin";
    return null;
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

    // ── New Threshold input row (Story 2.7) — shared across every Good's tab,
    // relocated above the sub-tab row below (Story 4.2) ────────────────────────
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .x = 16, .y = 4 },
        });
        defer row.deinit();

        dvui.label(@src(), "New Threshold:", .{}, .{
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 110 },
        });

        _ = dvui.textEntryNumber(
            @src(),
            u32,
            .{ .value = &app_state.threshold_state.new_value },
            .{ .min_size_content = .{ .w = 70 } },
        );

        if (dvui.button(@src(), "Add", .{}, .{ .margin = .{ .x = 8 } })) {
            const outcome = app_state.addThreshold(app_state.threshold_state.new_value);
            if (outcome == .ok) {
                app_state.threshold_state.new_value = 0;
            }
        }
    }

    if (app_state.threshold_state.error_msg) |msg| {
        dvui.label(@src(), "Error: {s}", .{msg}, .{
            .expand = .horizontal,
            .margin = .{ .x = 16, .y = 2 },
            .color_text = .{ .r = 200, .g = 50, .b = 50, .a = 255 },
        });
    }

    // ── Existing Thresholds list (Story 2.7's Remove control, relocated here
    // alongside the Add row above — Story 4.2) — shared across every Good's
    // tab since the Threshold list itself is shared; reuses removeThreshold
    // unchanged ──────────────────────────────────────────────────────────────
    {
        dvui.label(@src(), "Existing Thresholds:", .{}, .{
            .margin = .{ .x = 16, .y = 4 },
        });

        const cfg = app_state.config.?;
        for (cfg.thresholds[0..cfg.thresholdCount], 0..) |threshold_value, t_idx| {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .margin = .{ .x = 16, .y = 2 },
                .id_extra = t_idx,
            });
            defer row.deinit();

            dvui.label(@src(), "{d}", .{threshold_value}, .{
                .gravity_y = 0.5,
                .min_size_content = .{ .w = 70 },
                .id_extra = t_idx,
            });

            if (dvui.button(@src(), "Remove", .{}, .{
                .min_size_content = .{ .w = 70 },
                .id_extra = t_idx,
            })) {
                app_state.removeThreshold(t_idx);
            }
        }
    }

    // Never assume the previously active sub-tab is still valid — an Origin
    // switch (or a Config change shrinking eligibility) may have shrunk
    // good_count since the index was last set.
    app_state.threshold_state.active_good_idx = clampActiveGoodIdx(
        app_state.threshold_state.active_good_idx,
        slot.good_count,
    );

    if (noGoodsPlaceholder(slot.good_count)) |msg| {
        placeholder(msg);
        return;
    }

    // ── Good sub-tab row (Story 4.2) — one button per eligible Good, built
    // entirely off slot.good_count/cells, never a hardcoded count ───────────────
    var active_good: Good = undefined;
    {
        var tab_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .x = 8, .y = 2 },
        });
        defer tab_row.deinit();

        for (0..slot.good_count) |g| {
            const good_idx = slot.cells[g][0][0].good_idx;
            const good = origin_goods[good_idx];
            const active = app_state.threshold_state.active_good_idx == g;
            if (active) active_good = good;

            if (goodTabButton(good, active, g, app_state)) {
                app_state.threshold_state.active_good_idx = g;
            }
        }
    }

    _ = dvui.separator(@src(), .{ .expand = .horizontal, .margin = .{ .x = 16, .y = 2 } });

    // ── Active Good's content area — placeholder body for this story; Story
    // 4.3 replaces this with the real per-Threshold/per-Destination table.
    // `active_good` is always set by the loop above: active_good_idx was just
    // clamped to `[0, slot.good_count)`, and the loop covers exactly that
    // range, so its `g == active_good_idx` branch always fires exactly once.
    {
        dvui.label(@src(), "{s}", .{active_good.name}, .{
            .expand = .horizontal,
            .margin = .{ .x = 16, .y = 8 },
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

/// Renders one Good sub-tab button (icon + name + description tooltip),
/// highlighted when active, using the exact color-fill-by-active-state
/// convention `app.zig`'s Threshold/Live tab row and `settings.zig`'s
/// General/Route Times sub-tab row already use. Built directly on
/// `dvui.ButtonWidget` (the same building block `dvui.button` wraps) with
/// `goodCell` rendered as its content — reuses `goodCell`'s exact
/// icon/label/tooltip mechanics as-is (it parents itself under whatever
/// widget is current, which `bw.install()` below makes this button) rather
/// than duplicating the tooltip-attachment logic under a near-identical copy.
fn goodTabButton(good: Good, active: bool, id_extra: usize, app_state: *AppState) bool {
    var bw = dvui.ButtonWidget.init(@src(), .{}, .{
        .margin = .{ .x = 2 },
        .id_extra = id_extra,
        .color_fill = if (active)
            dvui.Color{ .r = 80, .g = 120, .b = 200, .a = 255 }
        else
            dvui.Color{ .r = 60, .g = 60, .b = 60, .a = 255 },
    });
    bw.install();
    bw.processEvents();
    bw.drawBackground();
    const click = bw.clicked();

    goodCell(good, id_extra, app_state);

    bw.drawFocus();
    bw.deinit();

    return click;
}

// ── Tests ─────────────────────────────────────────────────────────────────────
// The render code above requires a live dvui window (see Verification's
// manual-check note); the branching decisions it makes are extracted into
// pure functions above (clampActiveGoodIdx, noGoodsPlaceholder) specifically
// so they're directly unit-testable, mirroring `live.zig`'s
// resultsMessage/travelMinutes/parseProfitInput convention.

test "clampActiveGoodIdx: in-range index passes through unchanged" {
    try std.testing.expectEqual(@as(usize, 2), clampActiveGoodIdx(2, 5));
}

test "clampActiveGoodIdx: index exactly equal to good_count is out of range, resets to 0" {
    try std.testing.expectEqual(@as(usize, 0), clampActiveGoodIdx(2, 2));
}

test "clampActiveGoodIdx: Origin switch shrinking good_count resets an out-of-range index to 0" {
    // active_good_idx == 4 was valid for the previous Origin; the new
    // Origin's good_count == 2 no longer covers it.
    try std.testing.expectEqual(@as(usize, 0), clampActiveGoodIdx(4, 2));
}

test "clampActiveGoodIdx: zero eligible Goods resets to 0" {
    try std.testing.expectEqual(@as(usize, 0), clampActiveGoodIdx(3, 0));
}

test "noGoodsPlaceholder: zero eligible Goods returns the placeholder message" {
    try std.testing.expectEqualStrings(
        "No Goods available at your Merchant Rating for this Origin",
        noGoodsPlaceholder(0).?,
    );
}

test "noGoodsPlaceholder: nonzero good_count returns null so the caller renders sub-tabs" {
    try std.testing.expect(noGoodsPlaceholder(3) == null);
    try std.testing.expect(noGoodsPlaceholder(1) == null);
}
