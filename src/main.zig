const std = @import("std");
const dvui = @import("dvui");
const Backend = @import("dx11-backend");
const win32 = Backend.win32;

const app_mod = @import("ui/app.zig");

var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};

const window_class = win32.L("CommerceHelperWindow");

pub fn main() !void {
    defer {
        const result = gpa_instance.deinit();
        if (result == .leak) @panic("GPA detected memory leaks on exit");
    }

    const gpa = gpa_instance.allocator();

    // Resolve the executable directory so all data files are loaded relative
    // to the exe, not the current working directory.
    const exe_dir = try std.fs.selfExeDirPathAlloc(gpa);
    defer gpa.free(exe_dir);

    // Attach console on Windows so debug output is visible
    dvui.Backend.Common.windowsAttachConsole() catch {};

    Backend.RegisterClass(window_class, .{}) catch win32.panicWin32(
        "RegisterClass",
        win32.GetLastError(),
    );

    var window_state: Backend.WindowState = undefined;

    const backend = try Backend.initWindow(&window_state, .{
        .registered_class = window_class,
        .dvui_gpa = gpa,
        .allocator = gpa,
        .size = .{ .w = 800.0, .h = 600.0 },
        .min_size = .{ .w = 250.0, .h = 350.0 },
        .vsync = true,
        .title = "CommerceHelper",
    });
    defer backend.deinit();

    const win = backend.getWindow();

    // Initialise application state — runs the startup data loading sequence.
    var app_state = app_mod.AppState.init(gpa, exe_dir);
    defer app_state.deinit();

    while (true) switch (Backend.serviceMessageQueue()) {
        .queue_empty => {
            const nstime = win.beginWait(backend.hasEvent());

            try win.begin(nstime);

            try app_state.render();

            _ = try win.end(.{});

            backend.setCursor(win.cursorRequested());
        },
        .quit => break,
        .close_windows => {
            if (backend.receivedClose()) break;
        },
    };
}
