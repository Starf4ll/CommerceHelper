// ui/live.zig — Live Mode profit input grid (Story 3.1)
const std = @import("std");
const dvui = @import("dvui");

const app_mod = @import("app.zig");
const AppState = app_mod.AppState;
const config_mod = @import("../data/config.zig");
const goods_mod = @import("../data/goods.zig");
const Good = goods_mod.Good;
const engine_live = @import("../engine/live.zig");

/// Maximum number of distinct Goods supported per Origin — mirrors
/// `engine/live.zig`'s own MAX_GOODS (64). `engine/threshold.zig` uses a
/// different, smaller bound (8) for an unrelated reason (its own per-Origin
/// eligible-Good cap), so the two are not expected to match. No shared
/// header exists between any of these modules, so each keeps its own copy
/// of this constant.
pub const MAX_GOODS: usize = 64;

/// Per-Origin, per-Good, per-Destination profit inputs (FR entered by the
/// player in Live Mode), persisted across sessions and Origins (Story 3.4).
/// `profits[origin_idx][good_idx][dest_idx]` keys off the Origin's
/// OUTPOST_KEYS index (0-11), the Good's position in that Origin's
/// `origin_goods` slice (stable — only changes if the Good list itself
/// changes), and the Destination's OUTPOST_KEYS index (0-11; an Origin's own
/// slot is simply never read or written). Switching the viewed Origin only
/// changes which `profits[origin_idx]` slice the grid reads/writes — it is
/// never cleared.
pub const LiveState = struct {
    profits: [12][MAX_GOODS][12]f32 = [_][MAX_GOODS][12]f32{[_][12]f32{[_]f32{0.0} ** 12} ** MAX_GOODS} ** 12,

    /// Set when the most recent `AppState.saveLiveProfits` write to
    /// live_profits.json failed — mirrors `SettingsState.write_error`.
    /// Cleared on the next successful save.
    write_error: ?[]const u8 = null,
};

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
    // widget's own edits (e.g. switching Origin swaps which profits[idx]
    // slice this same widget id now points at) — same convention as
    // dvui.textEntryNumber's init-value sync.
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

/// Renders a Good's icon (if readable and decodable) + name, horizontally
/// centered, as a standalone block header sitting above its Destination rows.
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

    if (app_state.iconTexture(good.image)) |tex| {
        _ = dvui.image(@src(), .{
            .source = .{ .texture = tex },
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

/// Renders a Good's icon (if readable and decodable) + name, with its
/// description as a hover tooltip (AD-8). Icon failure falls back to
/// name-only, never crashes — iconTexture() returns null on either a read
/// error or a decode error.
///
/// Mirrors `threshold.zig`'s module-private `goodCell` exactly (same
/// icon/label/tooltip mechanics) — that helper isn't exported, so a result
/// row's Good cells (primary, and each load-composition item) need this local
/// copy rather than reaching across files.
fn goodCell(good: Good, id_extra: usize, app_state: *AppState) void {
    var wd: dvui.WidgetData = undefined;
    var cell = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 210 },
        .id_extra = id_extra,
        .data_out = &wd,
    });
    defer cell.deinit();

    if (app_state.iconTexture(good.image)) |tex| {
        _ = dvui.image(@src(), .{
            .source = .{ .texture = tex },
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

/// Renders a result row's full load composition — every entry in
/// `load.items[0..load.count]` as an icon+name+qty cell (each item still
/// individually hoverable for its own description via `goodCell`) — plus one
/// combined tooltip on the whole cell listing every item's name and quantity,
/// so the full load is readable at a glance without hovering each icon.
///
/// `id_extra` for each item uses the `row_idx * 100 + item_idx` composite
/// (not just `item_idx`): unlike Threshold's one-Good-per-row table, a single
/// row here renders multiple Good cells from the same loop call site, so
/// `item_idx` alone would collide across rows.
fn loadCompositionCell(load: engine_live.LoadComposition, origin_goods: []const Good, row_idx: usize, app_state: *AppState) void {
    std.debug.assert(load.count <= engine_live.MAX_LOAD_ITEMS);

    var wd: dvui.WidgetData = undefined;
    var cell = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 210 },
        .id_extra = row_idx,
        .data_out = &wd,
    });
    defer cell.deinit();

    // Combined breakdown tooltip on the whole cell — built into a stack
    // buffer since dvui.tooltip's fmt string must be comptime-known and the
    // item count is dynamic; a single "{s}" arg carries the pre-formatted
    // multi-line text. Truncates (never crashes) if an absurd number of
    // long Good names overflow the buffer — cosmetic only, load.count is
    // capped at MAX_LOAD_ITEMS (16).
    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    for (load.items[0..load.count], 0..) |item, item_idx| {
        const good = origin_goods[item.good_idx];

        goodCell(good, row_idx * 100 + item_idx, app_state);
        dvui.label(@src(), "x{d}", .{item.qty}, .{
            .gravity_y = 0.5,
            .margin = .{ .x = 2 },
            .id_extra = row_idx * 100 + item_idx,
        });

        if (item_idx != 0) writer.writeAll("\n") catch {};
        writer.print("{s} x{d}", .{ good.name, item.qty }) catch {};
    }

    dvui.tooltip(
        @src(),
        .{ .active_rect = wd.borderRectScale().r },
        "{s}",
        .{stream.getWritten()},
        .{ .id_extra = row_idx },
    );
}

/// Selects the placeholder message for the two non-table `live_results`
/// states (app.zig:51-55's null-vs-zero-count distinction). Returns null when
/// there are rows to render, telling the caller to render the table instead.
/// Pure/dvui-free so it's directly unit-testable, unlike the render code
/// around it.
fn resultsMessage(live_results: ?engine_live.LiveResults) ?[]const u8 {
    const results = live_results orelse return "Enter prices and press Calculate";
    if (results.count == 0) return "No profitable combinations found";
    return null;
}

/// Derives a result row's Travel Time in minutes from its stored
/// `total_profit`/`ducats_per_min` — `LiveResult` never stores travel time or
/// rank directly (see engine/live.zig and this feature's Boundaries). Safe
/// against division by zero: `calculate()` only inserts rows with
/// `ducats_per_min > 0` (travel_seconds > 0 and total_profit > 0 are both
/// required for a row to exist).
fn travelMinutes(total_profit: f64, ducats_per_min: f64) f64 {
    std.debug.assert(ducats_per_min > 0);
    return total_profit / ducats_per_min;
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

    // Snapshot this Origin's profit slice before rendering its fields, so
    // saveLiveProfits (below) can tell whether anything changed this frame —
    // exact convention as saveRoutes's before/after diff.
    const profits_before = app_state.live_state.profits[idx];

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

                profitField(&app_state.live_state.profits[idx][good_idx][dest_idx], dest_idx, tab_counter);
                tab_counter += 1;
            }
        }

        _ = dvui.separator(@src(), .{ .expand = .horizontal, .margin = .{ .x = 16, .y = 4 }, .id_extra = good_idx });
    }

    // Persist any profit-field edit this frame (no-op if nothing changed) —
    // exact saveRoutes convention: diff-before-write, revert+error on failure.
    app_state.saveLiveProfits(idx, profits_before);

    if (app_state.live_state.write_error) |msg| {
        dvui.label(@src(), "Error: {s}", .{msg}, .{
            .expand = .horizontal,
            .margin = .{ .y = 4, .x = 16 },
            .color_text = .{ .r = 200, .g = 50, .b = 50, .a = 255 },
        });
    }

    if (!any_visible) {
        placeholder("No Goods available at your Merchant Rating for this Origin");
    }

    // Manual trigger (AD-5 Level 3) — engine/live.zig's calculate() never
    // runs automatically; only this button invokes it.
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

    // ── Results table (Story 3.3) ───────────────────────────────────────────
    // Reads app_state.live_results only — never triggers recalculation. Null
    // (never calculated) and count==0 (calculated, no profitable combos) are
    // distinct states per app.zig:51-55; resultsMessage tells them apart.
    if (resultsMessage(app_state.live_results)) |msg| {
        placeholder(msg);
        return;
    }
    const results = app_state.live_results.?;
    std.debug.assert(results.count <= engine_live.MAX_LIVE_RESULTS);

    // ── Header row ───────────────────────────────────────────────────────────
    {
        var header = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .x = 16, .y = 4 },
        });
        defer header.deinit();

        dvui.label(@src(), "Rank", .{}, .{ .min_size_content = .{ .w = 40 } });
        dvui.label(@src(), "Good", .{}, .{ .min_size_content = .{ .w = 200 } });
        dvui.label(@src(), "Transport", .{}, .{ .min_size_content = .{ .w = 100 } });
        dvui.label(@src(), "Destination", .{}, .{ .min_size_content = .{ .w = 100 } });
        dvui.label(@src(), "Load", .{}, .{ .min_size_content = .{ .w = 240 } });
        dvui.label(@src(), "Total Profit", .{}, .{ .min_size_content = .{ .w = 100 } });
        dvui.label(@src(), "Travel Time", .{}, .{ .min_size_content = .{ .w = 100 } });
        dvui.label(@src(), "Ducats/min", .{}, .{ .min_size_content = .{ .w = 100 } });
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal, .margin = .{ .x = 16, .y = 2 } });

    // ── Rows: top results.count (<=10), already sorted descending by
    // Ducats/min by engine/live.zig's insertResult — no re-sorting here.
    for (results.rows[0..results.count], 0..) |row, row_idx| {
        var hrow = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .x = 16, .y = 2 },
            .id_extra = row_idx,
        });
        defer hrow.deinit();

        dvui.label(@src(), "{d}", .{row_idx + 1}, .{
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 40 },
            .id_extra = row_idx,
        });

        // Primary Good is load.items[0] (Boundaries) — resolved via the
        // current Origin's Goods slice, the same one calculateLive() swept.
        const primary_good = origin_goods[row.load.items[0].good_idx];
        goodCell(primary_good, row_idx, app_state);

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

        loadCompositionCell(row.load, origin_goods, row_idx, app_state);

        dvui.label(@src(), "{d:.2}", .{row.total_profit}, .{
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 100 },
            .id_extra = row_idx,
        });

        dvui.label(@src(), "{d:.1}", .{travelMinutes(row.total_profit, row.ducats_per_min)}, .{
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

// ── resultsMessage tests (Story 3.3) ────────────────────────────────────────
// The render code around resultsMessage requires a live dvui window (see
// Verification's manual-check note), but the null-vs-zero-count decision
// itself is pure and fully covered here.

test "resultsMessage: null live_results (never calculated) prompts to calculate" {
    try std.testing.expectEqualStrings(
        "Enter prices and press Calculate",
        resultsMessage(null).?,
    );
}

test "resultsMessage: calculated with zero results shows a distinct no-combinations message" {
    const results = engine_live.LiveResults{ .rows = undefined, .count = 0 };
    try std.testing.expectEqualStrings(
        "No profitable combinations found",
        resultsMessage(results).?,
    );
}

test "resultsMessage: nonzero count returns null so the caller renders the table" {
    const results = engine_live.LiveResults{ .rows = undefined, .count = 3 };
    try std.testing.expect(resultsMessage(results) == null);
}

// ── travelMinutes tests (Story 3.3) ─────────────────────────────────────────

test "travelMinutes: derives minutes from total_profit/ducats_per_min" {
    // 500 total profit at 100 Ducats/min implies 5 minutes of travel.
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), travelMinutes(500.0, 100.0), 0.0001);
}

test "travelMinutes: fractional result is not rounded" {
    try std.testing.expectApproxEqAbs(@as(f64, 1.6667), travelMinutes(200.0, 120.0), 0.001);
}
