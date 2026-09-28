const std = @import("std");

/// Converts a microsecond wait budget (as returned by dvui's `Window.waitTime`)
/// into a millisecond timeout for a Win32 wait call. `infinite` is the
/// sentinel millisecond value meaning "wait with no timeout" (`win32.INFINITE`),
/// passed in so this file has no dependency on the win32 package and can be
/// unit-tested without linking DirectX/win32.
///
/// No overflow clamp is needed on the finite branch: the largest possible
/// `timeout_micros` other than the `maxInt(u32)` sentinel is `maxInt(u32) - 1`
/// (~4.29e9), which converts to ~4.29e6 ms — far below `u32`'s range.
pub fn msFromMicros(timeout_micros: u32, infinite: u32) u32 {
    if (timeout_micros == std.math.maxInt(u32)) return infinite;
    return @intCast((@as(u64, timeout_micros) + 999) / 1000);
}

/// Interprets a `MsgWaitForMultipleObjects` return code: true means the wait
/// ended because a message became available (interrupted by input), false
/// means it timed out (or the call failed, per its caller's handling).
pub fn isInterrupted(result: u32, wait_object_0: u32) bool {
    return result == wait_object_0;
}

test "msFromMicros: maxInt(u32) (indefinite wait) maps to the infinite sentinel" {
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), msFromMicros(std.math.maxInt(u32), 0xFFFFFFFF));
}

test "msFromMicros: zero micros rounds to zero ms" {
    try std.testing.expectEqual(@as(u32, 0), msFromMicros(0, 0xFFFFFFFF));
}

test "msFromMicros: sub-millisecond remainder rounds up" {
    try std.testing.expectEqual(@as(u32, 1), msFromMicros(1, 0xFFFFFFFF));
    try std.testing.expectEqual(@as(u32, 1), msFromMicros(999, 0xFFFFFFFF));
    try std.testing.expectEqual(@as(u32, 1), msFromMicros(1000, 0xFFFFFFFF));
    try std.testing.expectEqual(@as(u32, 2), msFromMicros(1001, 0xFFFFFFFF));
}

test "msFromMicros: large finite value converts without overflow" {
    try std.testing.expectEqual(@as(u32, 16667), msFromMicros(16_666_666, 0xFFFFFFFF));
}

test "msFromMicros: largest legal non-sentinel input converts correctly" {
    const largest_non_sentinel = std.math.maxInt(u32) - 1;
    try std.testing.expectEqual(@as(u32, 4_294_968), msFromMicros(largest_non_sentinel, 0xFFFFFFFF));
}

test "isInterrupted: result matching WAIT_OBJECT_0 is interrupted" {
    try std.testing.expect(isInterrupted(0, 0));
}

test "isInterrupted: a timeout result is not interrupted" {
    const wait_timeout = 258; // WIN32_ERROR.WAIT_TIMEOUT
    try std.testing.expect(!isInterrupted(wait_timeout, 0));
}

test "isInterrupted: a failure result is not interrupted" {
    const wait_failed = 0xFFFFFFFF;
    try std.testing.expect(!isInterrupted(wait_failed, 0));
}
