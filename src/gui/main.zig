const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const sqlite = @import("sqlite");
const sdl = @import("sdl-backend");
const assets = @import("assets");
const ilm = @import("ilm");
const Core = ilm.Core;

const themes = @import("themes.zig");
const androidLogFn = @import("android.zig").logFn;
const ContentView = @import("ContentView.zig");
const SetupView = @import("SetupView.zig");

const log = std.log.scoped(.gui_main);

pub const dvui_app: dvui.App = .{
    .config = .{
        .options = .{
            .size = .{ .w = 800.0, .h = 600.0 },
            .min_size = .{ .w = 250.0, .h = 350.0 },
            .title = "ilm",
        },
    },
    .frameFn = appFrame,
    .initFn = appInit,
    .deinitFn = appDeinit,
};
pub const main = dvui.App.main;

export fn dvui_main() callconv(.c) void { // For android
    // Not init passed by main so make a ourselves
    var environ_map = std.process.Environ.Map.init(gpa);
    defer environ_map.deinit();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    var real_init: std.process.Init = undefined;
    real_init.gpa = gpa;
    real_init.io = threaded.io();
    real_init.environ_map = &environ_map;

    _ = dvui.App.main(real_init) catch {};
}

pub const panic = dvui.App.panic;

pub const std_options: std.Options = .{
    // .logFn = dvui.App.logFn,
    .logFn = if (builtin.abi.isAndroid()) androidLogFn else std.log.defaultLog,
};

var gpa_instance = std.heap.DebugAllocator(.{
    .never_unmap = true,
    .retain_metadata = true,
}){};
const gpa = gpa_instance.allocator();

const View = union(enum) {
    main: void,
    content: ContentView,
    setup: SetupView,
};

var view: View = .main;
var core: ?*Core = null;

fn switchView(new_view: View) void {
    switch (view) {
        .main => {},
        inline else => |*v| v.deinit(),
    }
    view = new_view;
}

// Runs before the first frame, after backend and dvui.Window.init()
// - runs between win.begin()/win.end()
pub fn appInit(win: *dvui.Window) !void {
    // win.backend.impl.touch_mouse_events = true;
    // _ = sdl.c.SDL_SetHint(sdl.c.SDL_HINT_TOUCH_MOUSE_EVENTS, "1");
    // _ = sdl.c.SDL_SetHint(sdl.c.SDL_HINT_MOUSE_TOUCH_EVENTS, "1");

    // TODO Find out how to find out if dark or light mode
    if (std.mem.eql(u8, win.theme.name, "Adwaita Light")) {
        win.themeSet(themes.Papyrus.light);
    }

    try dvui.addFont("dejavu sans", assets.fonts.dejavu_sans, null);

    var data_dir: ?[]const u8 = null;
    if (builtin.abi == .android) {
        if (sdl.c.SDL_GetPrefPath("org.libsdl", "ilm")) |c_str| {
            data_dir = std.mem.span(c_str);
        } else {
            dvui.toast(@src(), .{ .message = "Failed to find prefpath" });
            return;
        }
    }

    if (data_dir) |dir| {
        connect(dir);
    } else {
        connect("/home/mochar/tmp/ilm/");
        // switchView(.{ .setup = .init(gpa) });
    }
}

// Run as app is shutting down before dvui.Window.deinit()
pub fn appDeinit(win: *dvui.Window) void {
    _ = win;
    switch (view) {
        .main => {},
        inline else => |*v| v.deinit(),
    }
    if (core) |c| c.destroy();
}

pub fn appFrame() !dvui.App.Result {
    var scaler = dvui.scale(
        @src(),
        .{ .scale = &dvui.currentWindow().content_scale, .pinch_zoom = .global },
        .{ .rect = .cast(dvui.windowRect()) },
    );
    scaler.deinit();

    var box = dvui.box(@src(), .{}, .{ .expand = .both });
    defer box.deinit();

    switch (view) {
        .main => {},
        inline else => |*v| v.render(),
    }

    return .ok;
}

pub fn connect(data_dir: []const u8) void {
    if (core) |c| c.destroy();

    if (Core.create(.{ .gpa = gpa, .io = dvui.io, .data_dir = data_dir })) |c| {
        core = c;
        core.?.setup() catch |err| {
            log.err("Failed to setup core: {t}", .{err});
            dvui.toast(@src(), .{ .message = "Failed to setup core" });
        };
        if (ContentView.init(gpa, core.?)) |con| {
            switchView(.{ .content = con });
            dvui.toast(@src(), .{ .message = "Connected!" });
        } else |_| {
            dvui.toast(@src(), .{ .message = "Content init failed" });
        }
    } else |err| {
        core = null;
        var err_buf: [1024]u8 = undefined;
        const err_msg = std.fmt.bufPrint(&err_buf, "Failed to init: {t}", .{err}) catch "Failed to init";
        dvui.toast(@src(), .{ .message = err_msg });
    }
}
