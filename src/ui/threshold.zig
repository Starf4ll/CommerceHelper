// ui/threshold.zig — Threshold Mode Good sub-tabs (Story 4.2)
const std = @import("std");
const dvui = @import("dvui");

const app_mod = @import("app.zig");
const AppState = app_mod.AppState;
const config_mod = @import("../data/config.zig");
const goods_mod = @import("../data/goods.zig");
const Good = goods_mod.Good;
const threshold_mod = @import("../engine/threshold.zig");

/// Text color applied to a highlighted row's labels (Story 4.3) — reuses the
/// exact `color_text` value/mechanism already established by every other
/// distinct-color row in this codebase (this file's threshold error message,
/// `settings.zig`/`onboarding.zig`/`live.zig`'s write-error labels): setting
/// `Options.color_text` on an otherwise-default label. Distinct from the
/// default text color is all "highlighted" requires; no new color convention
/// is introduced.
const HIGHLIGHT_COLOR = dvui.Color{ .r = 200, .g = 50, .b = 50, .a = 255 };

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

/// Indices of one Good x Threshold x Destination cell — `bestCellInGood`'s
/// return shape. A named type (rather than repeating an anonymous `struct{...}`
/// literal at both the function's return type and its local `best` variable)
/// because two textually-identical anonymous struct literals in Zig are
/// distinct nominal types, not the same type.
pub const BestCellIndices = struct { threshold_idx: usize, destination_idx: usize };

/// Finds the single reachable cell with the highest `ducats_per_min` across
/// an entire Good's tab — every configured Threshold (`0..slot.threshold_count`)
/// x every Destination (0-11) for `slot.cells[good_slot]`. Returns `null` when
/// no cell in that Good's slice is reachable (Boundaries' "no row is
/// highlighted" case).
///
/// Returns indices rather than a `ThresholdCell` copy (Design Notes): the
/// render loop compares `(t_idx, dest_idx)` against these indices directly
/// instead of float-comparing `ducats_per_min` a second time, which sidesteps
/// ambiguous double-highlighting on an exact tie. Ties are broken by this
/// function alone — only a strictly greater `ducats_per_min` replaces the
/// current best, so the first cell encountered in ascending
/// (threshold_idx, destination_idx) order wins any tie.
///
/// Takes `slot` by `*const` pointer rather than by value so a caller already
/// holding a pointer (the ~112KB `OriginResult` cache entries) never has to
/// copy the whole struct just to call this.
///
/// Pure/dvui-free so it's directly unit-testable, mirroring
/// `clampActiveGoodIdx`/`noGoodsPlaceholder`'s convention.
pub fn bestCellInGood(
    slot: *const threshold_mod.OriginResult,
    good_slot: usize,
) ?BestCellIndices {
    std.debug.assert(good_slot < slot.good_count);
    var best: ?BestCellIndices = null;
    var best_ducats_per_min: f64 = 0;

    for (0..slot.threshold_count) |t_idx| {
        for (0..12) |dest_idx| {
            const cell = slot.cells[good_slot][t_idx][dest_idx];
            if (!cell.reachable) continue;
            if (best == null or cell.ducats_per_min > best_ducats_per_min) {
                best = .{ .threshold_idx = t_idx, .destination_idx = dest_idx };
                best_ducats_per_min = cell.ducats_per_min;
            }
        }
    }

    return best;
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

    // Never assume the previously active sub-tab is still valid — an Origin
    // switch (or a Config change shrinking eligibility) may have shrunk
    // good_count since the index was last set.
    app_state.threshold_state.active_good_idx = clampActiveGoodIdx(
        app_state.threshold_state.active_good_idx,
        slot.good_count,
    );

    // ── Good sub-tab row + active content (Story 4.2) — rendered first, above
    // the shared Threshold controls below; one button per eligible Good,
    // built entirely off slot.good_count/cells, never a hardcoded count ───────
    if (noGoodsPlaceholder(slot.good_count)) |msg| {
        placeholder(msg);
    } else {
        // `frame_active_good_idx` is snapshotted once, before the loop, and
        // used both for every tab button's `active` decision and for every
        // content-area lookup below (slot.cells indexing, bestCellInGood).
        // Reading `app_state.threshold_state.active_good_idx` live instead
        // would break the moment a click mutates it mid-loop: a click on a
        // lower-index tab mutates the field before the loop reaches the g
        // that used to match the *old* value, so the tab row's highlighted
        // button and the content area rendered below it could disagree for
        // the rest of this frame. The snapshot guarantees both stay in sync,
        // regardless of when a click lands.
        const frame_active_good_idx = app_state.threshold_state.active_good_idx;
        {
            var tab_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .margin = .{ .x = 8, .y = 2 },
            });
            defer tab_row.deinit();

            for (0..slot.good_count) |g| {
                const good_idx = slot.cells[g][0][0].good_idx;
                const good = origin_goods[good_idx];
                const active = frame_active_good_idx == g;

                if (goodTabButton(good, active, g, app_state)) {
                    app_state.threshold_state.active_good_idx = g;
                }
            }
        }

        // Active Good's content area (Story 4.3): one collapsible section per
        // configured Threshold (ascending), each listing every reachable
        // Destination's best Transport/Travel Time/Ducats-per-min; an
        // unreachable Destination still gets a row ("No route available")
        // rather than being omitted. The single best reachable cell across
        // the whole tab (every Threshold x every Destination) is highlighted.
        renderGoodContent(app_state, slot, frame_active_good_idx, idx);
    }

    _ = dvui.separator(@src(), .{ .expand = .horizontal, .margin = .{ .x = 16, .y = 2 } });

    // ── New Threshold input row (Story 2.7) — shared across every Good's tab,
    // rendered below the sub-tabs above (Story 4.2) ─────────────────────────────
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
}

/// Column widths shared by the header row and every data/no-route row below
/// it, so they stay visually aligned. `COL_MSG_W` is the combined width of
/// the three rightmost columns — the width an unreachable row's spanning
/// "No route available" message occupies instead of those three labels.
const COL_DESTINATION_W: f32 = 130;
const COL_TRANSPORT_W: f32 = 100;
const COL_TRAVEL_TIME_W: f32 = 100;
const COL_DUCATS_W: f32 = 100;
const COL_MSG_W: f32 = COL_TRANSPORT_W + COL_TRAVEL_TIME_W + COL_DUCATS_W;

/// One Destination row's rendering decision within a Threshold section:
/// `.skip` for the Origin's own index (excluded, matches `live.zig:339`'s
/// self-destination exclusion — never rendered at all, not even as a
/// no-route row); `.no_route` when the cell is unreachable; `.data` with the
/// values to render otherwise.
///
/// Pure/dvui-free so it's directly unit-testable, mirroring
/// `bestCellInGood`'s convention — the render loop's per-row decisions would
/// otherwise be untested inline branching in a dvui-coupled function.
pub const RowContent = union(enum) {
    skip,
    no_route,
    data: struct {
        transport_name: []const u8,
        travel_minutes: f64,
        ducats_per_min: f64,
    },
};

pub fn rowContent(
    cell: threshold_mod.ThresholdCell,
    dest_idx: usize,
    origin_idx: usize,
) RowContent {
    if (dest_idx == origin_idx) return .skip;
    if (!cell.reachable) return .no_route;
    return .{ .data = .{
        .transport_name = cell.transport_name,
        .travel_minutes = cell.travel_minutes,
        .ducats_per_min = cell.ducats_per_min,
    } };
}

/// Renders the header row above the per-Threshold sections' data rows,
/// mirroring `live.zig`'s header-row pattern (same column widths as the rows
/// below, indented to `x = 32` to align under the sections' indentation).
fn renderTableHeader() void {
    var header = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .margin = .{ .x = 32, .y = 4 },
    });
    defer header.deinit();

    dvui.label(@src(), "Destination", .{}, .{ .min_size_content = .{ .w = COL_DESTINATION_W } });
    dvui.label(@src(), "Transport", .{}, .{ .min_size_content = .{ .w = COL_TRANSPORT_W } });
    dvui.label(@src(), "Travel Time (min)", .{}, .{ .min_size_content = .{ .w = COL_TRAVEL_TIME_W } });
    dvui.label(@src(), "Ducats/min", .{}, .{ .min_size_content = .{ .w = COL_DUCATS_W } });
}

/// Renders the active Good's tab content (Story 4.3): a header row followed
/// by one `dvui.expander` section per configured Threshold (ascending,
/// `slot.cells[good_slot][0..slot.threshold_count]`), collapsed by default,
/// each expanding into one row per Destination per `rowContent`'s decision —
/// excluded, "No route available", or real data. The single best reachable
/// cell across the whole tab (from `bestCellInGood`) gets its row's labels
/// highlighted via `HIGHLIGHT_COLOR`. A zero-configured-Thresholds Origin
/// gets a placeholder instead of a silently empty area.
///
/// Read-only over `slot` — no re-sweeping/recomputing here (Boundaries'
/// "Never"); `slot` is a pointer so neither this function nor
/// `bestCellInGood` ever copies the ~112KB `OriginResult`.
fn renderGoodContent(
    app_state: *AppState,
    slot: *threshold_mod.OriginResult,
    good_slot: usize,
    origin_idx: usize,
) void {
    if (slot.threshold_count == 0) {
        placeholder("No Thresholds configured");
        return;
    }

    const cfg = app_state.config.?;
    const best = bestCellInGood(slot, good_slot);

    renderTableHeader();

    for (0..slot.threshold_count) |t_idx| {
        var label_buf: [32]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "Threshold: {d}", .{cfg.thresholds[t_idx]}) catch "Threshold";

        // `id_extra` combines `origin_idx`, `good_slot`, and `t_idx`: dvui
        // persists an expander's expand/collapse state by id across frames,
        // so without all three, two different Goods' (or two different
        // Origins') same-valued Threshold sections (e.g. both showing
        // "Threshold: 50") would share one expand state and leak it across
        // tabs or Origin switches. good_slot is bounded well under
        // MAX_GOODS=8, t_idx well under MAX_THRESHOLDS=32, and origin_idx
        // under 12, so this plain usize multiply/add never overflows or
        // collides.
        const expanded = dvui.expander(@src(), label, .{ .default_expanded = false }, .{
            .expand = .horizontal,
            .margin = .{ .x = 16, .y = 2 },
            .id_extra = origin_idx * 10_000 + good_slot * 100 + t_idx,
        });
        if (!expanded) continue;

        for (0..12) |dest_idx| {
            const cell = slot.cells[good_slot][t_idx][dest_idx];
            const content = rowContent(cell, dest_idx, origin_idx);
            if (content == .skip) continue;

            const row_id = t_idx * 100 + dest_idx;
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .margin = .{ .x = 32, .y = 1 },
                .id_extra = row_id,
            });
            defer row.deinit();

            const is_best = if (best) |b|
                (b.threshold_idx == t_idx and b.destination_idx == dest_idx)
            else
                false;
            const highlight: ?dvui.Color = if (is_best) HIGHLIGHT_COLOR else null;

            dvui.label(@src(), "{s}", .{config_mod.OUTPOST_DISPLAY_NAMES[dest_idx]}, .{
                .gravity_y = 0.5,
                .min_size_content = .{ .w = COL_DESTINATION_W },
                .id_extra = row_id,
                .color_text = highlight,
            });

            switch (content) {
                .skip => unreachable, // already `continue`d above
                .no_route => {
                    // Same destination-name column as a data row, then a
                    // single label spanning the combined width of the three
                    // data columns it replaces — keeps every row's total
                    // width (and thus column alignment) identical.
                    dvui.label(@src(), "No route available", .{}, .{
                        .gravity_y = 0.5,
                        .min_size_content = .{ .w = COL_MSG_W },
                        .id_extra = row_id,
                        .color_text = highlight,
                    });
                },
                .data => |d| {
                    dvui.label(@src(), "{s}", .{d.transport_name}, .{
                        .gravity_y = 0.5,
                        .min_size_content = .{ .w = COL_TRANSPORT_W },
                        .id_extra = row_id,
                        .color_text = highlight,
                    });

                    dvui.label(@src(), "{d:.1}", .{d.travel_minutes}, .{
                        .gravity_y = 0.5,
                        .min_size_content = .{ .w = COL_TRAVEL_TIME_W },
                        .id_extra = row_id,
                        .color_text = highlight,
                    });

                    dvui.label(@src(), "{d:.1}", .{d.ducats_per_min}, .{
                        .gravity_y = 0.5,
                        .min_size_content = .{ .w = COL_DUCATS_W },
                        .id_extra = row_id,
                        .color_text = highlight,
                    });
                },
            }
        }
    }
}

/// Renders a Good's icon (if readable and decodable) + name, with its
/// description as a hover tooltip (AD-8). Icon failure falls back to
/// name-only, never crashes — iconTexture() returns null on either a read
/// error or a decode error.
fn goodCell(good: Good, id_extra: usize, app_state: *AppState) void {
    var wd: dvui.WidgetData = undefined;
    var cell = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 170 },
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

// ── bestCellInGood ────────────────────────────────────────────────────────────

/// Builds a fully-`reachable = false` OriginResult for `bestCellInGood` tests
/// to selectively mark cells reachable on top of — every cell within
/// `[0..good_count][0..threshold_count][0..12]` (the only range
/// `bestCellInGood` ever reads) must be initialized, since `OriginResult` has
/// no default value of its own and a stray `undefined` `reachable` bit would
/// make the test's outcome depend on uninitialized memory.
fn zeroTestResult(good_count: u8, threshold_count: u8) threshold_mod.OriginResult {
    var result: threshold_mod.OriginResult = undefined;
    result.good_count = good_count;
    result.threshold_count = threshold_count;
    for (0..result.cells.len) |g| {
        for (0..result.cells[g].len) |t| {
            for (0..result.cells[g][t].len) |d| {
                result.cells[g][t][d] = .{
                    .good_idx = g,
                    .threshold = 0,
                    .destination_idx = d,
                    .reachable = false,
                    .transport_name = "",
                    .travel_minutes = 0,
                    .ducats_per_min = 0,
                };
            }
        }
    }
    return result;
}

test "bestCellInGood: no reachable cells across the whole tab returns null" {
    const result = zeroTestResult(1, 2);
    try std.testing.expect(bestCellInGood(&result, 0) == null);
}

test "bestCellInGood: single best among several reachable cells wins regardless of Threshold/Destination order" {
    var result = zeroTestResult(1, 2);
    result.cells[0][0][1].reachable = true;
    result.cells[0][0][1].ducats_per_min = 100.0;
    result.cells[0][1][3].reachable = true;
    result.cells[0][1][3].ducats_per_min = 250.0; // strictly higher — must win
    result.cells[0][1][5].reachable = true;
    result.cells[0][1][5].ducats_per_min = 200.0;

    const best = bestCellInGood(&result, 0).?;
    try std.testing.expectEqual(@as(usize, 1), best.threshold_idx);
    try std.testing.expectEqual(@as(usize, 3), best.destination_idx);
}

test "bestCellInGood: exact tie resolves to the first-encountered cell (ascending Threshold, then Destination)" {
    var result = zeroTestResult(1, 2);
    result.cells[0][0][2].reachable = true;
    result.cells[0][0][2].ducats_per_min = 500.0;
    result.cells[0][1][4].reachable = true;
    result.cells[0][1][4].ducats_per_min = 500.0; // exact tie: only a strictly
    // greater ducats_per_min replaces the current best, so the earlier
    // (threshold_idx=0, destination_idx=2) cell must win, not this one.

    const best = bestCellInGood(&result, 0).?;
    try std.testing.expectEqual(@as(usize, 0), best.threshold_idx);
    try std.testing.expectEqual(@as(usize, 2), best.destination_idx);
}

test "bestCellInGood: only reads the given good_slot's cells, other slots are ignored" {
    var result = zeroTestResult(2, 1);
    result.cells[1][0][0].reachable = true;
    result.cells[1][0][0].ducats_per_min = 9999.0;

    // good_slot 0 has no reachable cells of its own, even though good_slot 1 does.
    try std.testing.expect(bestCellInGood(&result, 0) == null);

    const best = bestCellInGood(&result, 1).?;
    try std.testing.expectEqual(@as(usize, 0), best.threshold_idx);
    try std.testing.expectEqual(@as(usize, 0), best.destination_idx);
}

// ── rowContent ────────────────────────────────────────────────────────────────

fn makeTestCell(reachable: bool) threshold_mod.ThresholdCell {
    return .{
        .good_idx = 0,
        .threshold = 100,
        .destination_idx = 1,
        .reachable = reachable,
        .transport_name = "Wagon",
        .travel_minutes = 12.5,
        .ducats_per_min = 456.7,
    };
}

test "rowContent: reachable cell at a non-Origin Destination yields the real-data decision" {
    const cell = makeTestCell(true);
    const content = rowContent(cell, 1, 0); // dest_idx=1, origin_idx=0 — not the Origin

    switch (content) {
        .data => |d| {
            try std.testing.expectEqualStrings("Wagon", d.transport_name);
            try std.testing.expectApproxEqAbs(@as(f64, 12.5), d.travel_minutes, 0.0001);
            try std.testing.expectApproxEqAbs(@as(f64, 456.7), d.ducats_per_min, 0.0001);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "rowContent: unreachable cell at a non-Origin Destination yields the no-route decision" {
    const cell = makeTestCell(false);
    const content = rowContent(cell, 1, 0); // dest_idx=1, origin_idx=0 — not the Origin

    try std.testing.expect(content == .no_route);
}

test "rowContent: Origin's own Destination index is skipped regardless of reachability" {
    const reachable_cell = makeTestCell(true);
    try std.testing.expect(rowContent(reachable_cell, 3, 3) == .skip);

    const unreachable_cell = makeTestCell(false);
    try std.testing.expect(rowContent(unreachable_cell, 3, 3) == .skip);
}
