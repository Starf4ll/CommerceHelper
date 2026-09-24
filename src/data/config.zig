const std = @import("std");

/// Stub Config struct; additional fields will be added in Stories 1.3–1.5.
pub const Config = struct {
    origin: []const u8 = "",
};

const max_file_size = 1 * 1024 * 1024; // 1 MiB

/// Load config.json from exe_dir.
/// Returns null if the file is missing or contains invalid JSON — no error
/// dialog, no panic.  The caller treats null as "show the wizard".
pub fn loadConfig(allocator: std.mem.Allocator, exe_dir: []const u8) ?Config {
    const path = std.fs.path.join(allocator, &.{ exe_dir, "config.json" }) catch return null;
    defer allocator.free(path);

    const text = std.fs.cwd().readFileAlloc(allocator, path, max_file_size) catch return null;
    defer allocator.free(text);

    const parsed = std.json.parseFromSlice(
        Config,
        allocator,
        text,
        .{ .ignore_unknown_fields = true },
    ) catch return null;
    defer parsed.deinit();

    // Config only has a string field; dupe it so it outlives the parsed arena.
    const cfg = Config{
        .origin = allocator.dupe(u8, parsed.value.origin) catch return null,
    };
    return cfg;
}

/// Free a Config that was returned by loadConfig (only needed if non-null).
pub fn deinitConfig(config: *Config, allocator: std.mem.Allocator) void {
    allocator.free(config.origin);
}
