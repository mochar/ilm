const std = @import("std");
const dvui = @import("dvui");

pub fn toastErr(src: std.builtin.SourceLocation, err: anyerror, comptime fmt: []const u8, args: anytype) void {
    const arena = dvui.currentWindow().lifo();
    const msg = std.fmt.allocPrint(arena, "{t}: " ++ fmt, .{err} ++ args) catch "An error occurred";
    defer arena.free(msg);
    dvui.toast(src, .{ .message = msg });
    dvui.logError(src, err, fmt, args);
}
