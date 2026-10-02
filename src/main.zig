const std = @import("std");
const dvui = @import("dvui");
const Backend = @import("dx11-backend");
const win32 = Backend.win32;

const app_mod = @import("ui/app.zig");
const idle_wait = @import("util/idle_wait.zig");

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
        .size = .{ .w = 1080.0, .h = 600.0 },
        .min_size = .{ .w = 600.0, .h = 300.0 },
        .vsync = true,
        .title = "CommerceHelper",
    });
    defer backend.deinit();

    const win = backend.getWindow();

    // Initialise application state — runs the startup data loading sequence.
    var app_state = app_mod.AppState.init(gpa, exe_dir);
    defer app_state.deinit(backend.backend());

    // Tracks whether the previous idle wait was woken by an input event
    // (as opposed to timing out), so beginWait can avoid adjusting its
    // frame-time slop estimate for an interrupted wait.
    var interrupted = false;

    while (true) switch (Backend.serviceMessageQueue()) {
        .queue_empty => {
            const nstime = win.beginWait(interrupted);

            try win.begin(nstime);

            try app_state.render();

            const end_micros = try win.end(.{});

            backend.setCursor(win.cursorRequested());

            const wait_event_micros = win.waitTime(end_micros);
            interrupted = waitEventTimeout(wait_event_micros);
        },
        .quit => break,
        .close_windows => {
            if (backend.receivedClose()) break;
        },
    };
}

/// Idles until either `timeout_micros` elapses or an OS input message
/// arrives, whichever comes first. Returns true if woken by a message.
///
/// This is dvui's idle-wait contract (see `Window.waitTime`) adapted for
/// the DX11 backend, which — unlike SDL — has no built-in
/// `waitEventTimeout`. Mirrors dvui's SDL backend (`sdl.zig`'s
/// `waitEventTimeout`), using `MsgWaitForMultipleObjects` so the wait is
/// interruptible by input rather than a fixed sleep.
fn waitEventTimeout(timeout_micros: u32) bool {
    const ms = idle_wait.msFromMicros(timeout_micros, win32.INFINITE);

    const result = win32.MsgWaitForMultipleObjects(0, null, win32.FALSE, ms, win32.QS_ALLINPUT);
    if (result == @intFromEnum(win32.WAIT_FAILED)) {
        std.log.err("MsgWaitForMultipleObjects failed, error={}", .{win32.GetLastError()});
        // Back off briefly so a persistently failing wait call can't busy-spin
        // the loop and flood the log every frame.
        std.Thread.sleep(1 * std.time.ns_per_ms);
        return false;
    }
    return idle_wait.isInterrupted(result, @intFromEnum(win32.WAIT_OBJECT_0));
}
