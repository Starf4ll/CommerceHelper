// ui/live.zig — Live Mode profit input grid (Story 3.1)
const std = @import("std");
const dvui = @import("dvui");

const app_mod = @import("app.zig");
const AppState = app_mod.AppState;
const config_mod = @import("../data/config.zig");
const goods_mod = @import("../data/goods.zig");
const Good = goods_mod.Good;

/// Maximum number of distinct Goods supported per Origin — mirrors
/// `engine/threshold.zig`'s own MAX_GOODS. No shared header exists between
/// the two modules, so each keeps its own copy of this constant.
pub const MAX_GOODS: usize = 64;

/// Per-Good, per-Destination profit inputs (FR entered by the player in Live
/// Mode). `profits[good_idx][dest_idx]` keys off the Good's position in
/// `origin_goods` (stable — only changes on Origin swap, which clears this
/// whole array) and the Destination's OUTPOST_KEYS index (0-11; the origin's
/// own slot is simply never read or written).
pub const LiveState = struct {
    profits: [MAX_GOODS][12]f32 = [_][12]f32{[_]f32{0.0} ** 12} ** MAX_GOODS,
};

/// Resets every stored profit to 0.0 — called whenever the Origin changes,
/// since profit inputs are Origin-specific and never persisted.
pub fn clearProfits(state: *LiveState) void {
    state.profits = [_][12]f32{[_]f32{0.0} ** 12} ** MAX_GOODS;
}

/// Renders one placeholder label, centered, matching the "no data yet" style
/// used elsewhere in this tab (mirrors `threshold.zig`'s placeholder).
fn placeholder(text: []const u8) void {
    dvui.label(@src(), "{s}", .{text}, .{
        .expand = .horizontal,
        .gravity_x = 0.5,
        .margin = .{ .y = 16, .x = 16 },
    });
}

/// Parses a profit field's raw text into its stored value: blank or
/// unparsable text is 0.0, and any negative result is clamped to 0.0 (defense
/// in depth — profitField's digits+"." filter already blocks '-' at input
/// time, but this keeps the parse itself safe if ever called with raw text).
fn parseProfitInput(text: []const u8) f32 {
    var parsed: f32 = std.fmt.parseFloat(f32, text) catch 0.0;
    if (parsed < 0.0) parsed = 0.0;
    return parsed;
}

/// A single profit input field. Thin wrapper around dvui's low-level
/// TextEntryWidget (the same building block `dvui.textEntryNumber` uses),
/// with a stricter digits+"." filter than `textEntryNumber` provides —
/// `textEntryNumber`'s own float filter ("1234567890+-.e") permits '-',
/// which the AC forbids outright, not just after parsing.
///
/// Blank/unparsable text and negative parses are all treated as 0.0. A
/// stored value of exactly 0.0 always displays as a blank field (not "0") so
/// that a cleared/never-touched field looks empty rather than zeroed.
fn profitField(value: *f32, id_extra: usize, tab_index: u16) void {
    const filter = "1234567890.";

    const opts: dvui.Options = .{
        .id_extra = id_extra,
        .tab_index = tab_index,
        .min_size_content = .{ .w = 70 },
    };

    const id = dvui.parentGet().extendId(@src(), opts.idExtra());

    const buffer = dvui.dataGetSliceDefault(null, id, "buffer", []u8, &[_]u8{0} ** 32);

    // Resync the buffer whenever the stored value changed from outside this
    // widget's own edits (e.g. clearProfits resetting it to 0.0 on Origin
    // change) — same convention as dvui.textEntryNumber's init-value sync.
    const old_value = dvui.dataGet(null, id, "value", f32);
    if (old_value == null or old_value.? != value.*) {
        dvui.dataSet(null, id, "value", value.*);
        @memset(buffer, 0);
        if (value.* != 0.0) {
            _ = std.fmt.bufPrint(buffer, "{d}", .{value.*}) catch {};
        }
    }

    var te = dvui.TextEntryWidget.init(@src(), .{ .text = .{ .buffer = buffer } }, opts);
    te.install();
    te.processEvents();

    // Strip anything outside the digits+"." filter before drawing — this is
    // what keeps '-' from ever being inserted, not just from parsing.
    te.filterIn(filter);

    const parsed = parseProfitInput(te.getText());

    if ((te.enter_pressed or te.text_changed) and value.* != parsed) {
        dvui.dataSet(null, id, "value", parsed);
        value.* = parsed;
    }

    te.draw();
    te.deinit();
}

/// Renders a Good's icon (if readable) + name, horizontally centered, as a
/// standalone block header sitting above its Destination rows.
///
/// Deliberately not `threshold.goodCell`: that helper is designed to sit
/// beside other same-row cells in a horizontal row (it uses `.gravity_y` for
/// cross-axis centering within that row's height). Reused as-is here — a
/// direct child of a vertical block alongside a much taller sibling vbox — it
/// visibly overlapped the Destination rows below it, because `.gravity_y`
/// governs main-axis position (not cross-axis) inside a vertical box. This
/// header uses `.gravity_x` instead, which is the correct cross-axis property
/// for a vertical box's child, to center it horizontally without touching its
/// vertical (stacking) position at all.
fn goodHeader(good: Good, id_extra: usize, app_state: *AppState) void {
    var wd: dvui.WidgetData = undefined;
    var header = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .gravity_x = 0.5,
        .id_extra = id_extra,
        .data_out = &wd,
    });
    defer header.deinit();

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

pub fn renderTab(app_state: *AppState) !void {
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();

    const origin = app_state.config.?.origin;
    if (origin.len == 0) {
        placeholder("Select an Origin above");
        return;
    }

    // Resolve the origin's index fresh every frame — same linear scan
    // threshold.zig/renderMainArea use.
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

    const player_rating = config_mod.merchantRatingAt(app_state.config.?.merchantRatings, idx);
    const origin_goods = app_state.goods.?.get(origin) orelse &[_]goods_mod.Good{};
    std.debug.assert(origin_goods.len <= MAX_GOODS);

    // Sequential Tab order across every rendered field, in exact
    // Good-then-Destination render order. Starts at 1 (0 would disable
    // tabbing per dvui.Options.tab_index convention).
    var tab_counter: u16 = 1;
    var any_visible = false;

    for (origin_goods, 0..) |good, good_idx| {
        // FR-5: hide a Good's entire block when its merchantRating exceeds
        // the player's rating at the current Origin — identical comparison
        // to engine/threshold.zig's sweepOrigin eligibility check.
        if (good.merchantRating > player_rating) continue;
        any_visible = true;

        var block = dvui.box(@src(), .{}, .{
            .expand = .horizontal,
            .margin = .{ .x = 16, .y = 4 },
            .id_extra = good_idx,
        });
        defer block.deinit();

        goodHeader(good, good_idx, app_state);

        {
            var vbox = dvui.box(@src(), .{}, .{
                .expand = .horizontal,
                .margin = .{ .x = 32, .y = 2 },
                .id_extra = good_idx,
            });
            defer vbox.deinit();

            for (0..12) |dest_idx| {
                if (dest_idx == idx) continue;

                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .horizontal,
                    .margin = .{ .y = 1 },
                    .id_extra = dest_idx,
                });
                defer row.deinit();

                dvui.label(@src(), "{s}", .{config_mod.OUTPOST_DISPLAY_NAMES[dest_idx]}, .{
                    .gravity_y = 0.5,
                    .min_size_content = .{ .w = 130 },
                    .id_extra = dest_idx,
                });

                profitField(&app_state.live_state.profits[good_idx][dest_idx], dest_idx, tab_counter);
                tab_counter += 1;
            }
        }

        _ = dvui.separator(@src(), .{ .expand = .horizontal, .margin = .{ .x = 16, .y = 4 }, .id_extra = good_idx });
    }

    if (!any_visible) {
        placeholder("No Goods available at your Merchant Rating for this Origin");
    }

    // Manual trigger (AD-5 Level 3) — engine/live.zig's calculate() never
    // runs automatically; only this button invokes it. Story 3.3 renders
    // app_state.live_results — no visible table here yet.
    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .gravity_x = 0.5,
            .margin = .{ .y = 12, .x = 16 },
        });
        defer hbox.deinit();

        if (dvui.button(@src(), "Calculate", .{}, .{})) {
            app_state.calculateLive();
        }
    }
}

// ── parseProfitInput tests ───────────────────────────────────────────────────

test "parseProfitInput: blank text is 0.0" {
    try std.testing.expectEqual(@as(f32, 0.0), parseProfitInput(""));
}

test "parseProfitInput: unparsable text is 0.0" {
    try std.testing.expectEqual(@as(f32, 0.0), parseProfitInput("."));
}

test "parseProfitInput: negative text clamps to 0.0" {
    try std.testing.expectEqual(@as(f32, 0.0), parseProfitInput("-5"));
}

test "parseProfitInput: valid decimal parses through" {
    try std.testing.expectEqual(@as(f32, 12.5), parseProfitInput("12.5"));
}

// ── clearProfits tests ───────────────────────────────────────────────────────

test "clearProfits resets every slot to 0.0" {
    var state = LiveState{};
    state.profits[0][0] = 42.0;
    state.profits[3][11] = 7.5;
    state.profits[63][5] = 1.0;

    clearProfits(&state);

    for (state.profits) |row| {
        for (row) |v| {
            try std.testing.expectEqual(@as(f32, 0.0), v);
        }
    }
}

test "LiveState defaults to all-zero profits" {
    const state = LiveState{};
    for (state.profits) |row| {
        for (row) |v| {
            try std.testing.expectEqual(@as(f32, 0.0), v);
        }
    }
}
