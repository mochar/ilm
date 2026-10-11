const std = @import("std");
const dvui = @import("dvui");

pub fn toastErr(src: std.builtin.SourceLocation, err: anyerror, comptime fmt: []const u8, args: anytype) void {
    const arena = dvui.currentWindow().lifo();
    const msg = std.fmt.allocPrint(arena, "{t}: " ++ fmt, .{err} ++ args) catch "An error occurred";
    defer arena.free(msg);
    dvui.toast(src, .{ .message = msg });
    dvui.logError(src, err, fmt, args);
}

pub const ScreenSize = struct {
    pub const Height = enum {
        /// Phones in landscape. Prefer side nav
        compact,
        /// Phines in portrait, tablets.
        medium,
        /// Large tablet in portrat, desktop monitors
        expanded,

        pub fn get() Height {
            return switch (@as(u32, @intFromFloat(dvui.windowRect().h))) {
                0...479 => .compact,
                480...899 => .medium,
                else => .expanded,
            };
        }
    };

    pub const Width = enum {
        /// Mobile
        compact,
        /// Tablet
        medium,
        /// Desktop
        expanded,
        /// Widescreen
        large,

        pub fn get() Width {
            return switch (@as(u32, @intFromFloat(dvui.windowRect().w))) {
                0...599 => .compact,
                600...899 => .medium,
                900...1199 => .expanded,
                else => .large,
            };
        }
    };

    width: Width,
    height: Height,

    pub fn get() ScreenSize {
        return .{ .width = .get(), .height = .get() };
    }
};
