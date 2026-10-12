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

/// Like dvui.checkbox, but target is passed rather and used as fixed
/// state, rather than passing pointer to boolean and having the
/// widget update it.
pub fn manualCheckbox(src: std.builtin.SourceLocation, target: bool, opts: dvui.Options) bool {
    const options = dvui.checkbox_defaults.override(opts);
    var ret = false;

    var b = dvui.box(src, .{ .dir = .horizontal }, options);
    defer b.deinit();

    dvui.tabIndexSet(b.data().id, b.data().options.tab_index, b.data().rectScale().r);

    var hovered: bool = false;
    if (dvui.clicked(b.data(), .{ .hovered = &hovered })) {
        ret = true;
    }

    const check_size = options.fontGet().textHeight();
    const s = dvui.spacer(@src(), .{ .min_size_content = dvui.Size.all(check_size), .gravity_y = 0.5 });

    const rs = s.borderRectScale();
    const hover_t = dvui.hoverFade(b.data().id, hovered);

    if (b.data().visible()) {
        const focused = b.data().id == dvui.focusedWidgetId();
        const pressed = dvui.captured(b.data().id);
        dvui.checkmark(target, focused, rs, pressed, hover_t, options);
    }

    return ret;
}
