// ui/threshold.zig — placeholder pending Epic 2
const dvui = @import("dvui");

const AppState = @import("app.zig").AppState;

pub fn renderTab(app_state: *AppState) !void {
    _ = app_state;
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();
    dvui.label(@src(), "Threshold Mode \u{2014} coming in Epic 2", .{}, .{
        .expand = .horizontal,
        .gravity_x = 0.5,
        .margin = .{ .y = 16, .x = 16 },
    });
}
