//! See https://developer.android.com/ndk/reference/group/logging
//! c.SDL_Log poops its pants so cannot use that.
const std = @import("std");
const builtin = @import("builtin");

extern "c" fn __android_log_write(prio: c_int, tag: [*:0]const u8, text: [*:0]const u8) c_int;

var android_log_buf: [1028]u8 = undefined;

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!builtin.abi.isAndroid()) @compileError("Cannot use Android logFn if not on Android");
    // See ~/Android/Sdk/sources/android-37.0/com/android/i18n/util/Log.java
    const prio = switch (level) {
        .debug => 3,
        .info => 4,
        .warn => 5,
        .err => 6,
    };
    const text = std.fmt.bufPrintZ(&android_log_buf, format, args) catch "OOM";
    _ = __android_log_write(prio, @ptrCast(@tagName(scope)), text);
}
