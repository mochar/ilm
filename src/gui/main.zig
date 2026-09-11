const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const sqlite = @import("sqlite");

const Core = @import("ilm").Core;
const Content = @import("Content.zig");

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
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{
    .logFn = dvui.App.logFn,
};

var gpa_instance = std.heap.DebugAllocator(.{}){};
const gpa = gpa_instance.allocator();

var content: ?Content = null;
var core: ?*Core = null;

// Runs before the first frame, after backend and dvui.Window.init()
// - runs between win.begin()/win.end()
pub fn appInit(win: *dvui.Window) !void {
    _ = win;
    connect();
}

// Run as app is shutting down before dvui.Window.deinit()
pub fn appDeinit(win: *dvui.Window) void {
    _ = win;
    if (content) |*c| c.deinit();
    if (core) |c| {
        c.deinit();
        gpa.destroy(c);
    }
}

pub fn appFrame() !dvui.App.Result {
    var scaler = dvui.scale(@src(), .{ .scale = &dvui.currentWindow().content_scale, .pinch_zoom = .global }, .{ .rect = .cast(dvui.windowRect()) });
    scaler.deinit();

    if (menu()) |res| return res;

    var box = dvui.box(@src(), .{}, .{ .expand = .both });
    defer box.deinit();

    if (content) |*c| {
        if (c.render()) |res| return res;
    }

    return .ok;
}

pub fn menu() ?dvui.App.Result {
    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .style = .window, .background = true, .expand = .horizontal });
    defer hbox.deinit();

    var m = dvui.menu(@src(), .horizontal, .{});
    defer m.deinit();

    if (dvui.menuItemLabel(@src(), "File", .{ .submenu = true }, .{ .tag = "first-focusable" })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();

        if (dvui.menuItemLabel(@src(), "Close Menu", .{}, .{ .expand = .horizontal }) != null) {
            m.close();
        }

        if (dvui.backend.kind != .web) {
            if (dvui.menuItemLabel(@src(), "Exit", .{}, .{ .expand = .horizontal }) != null) {
                return .close;
            }
        }
    }

    if (dvui.menuItemLabel(@src(), "Connect", .{ .submenu = true }, .{})) |_| {
        connect();
    }

    return null;
}

fn connect() void {
    if (content) |*c| c.deinit();
    if (core) |c| c.deinit();

    var diags: sqlite.Diagnostics = .{};
    const data_dir = "/home/mochar/tmp/ilm/";
    core = gpa.create(Core) catch {
        return dvui.toast(@src(), .{ .message = "Failed to allocate Core" });
    };
    if (Core.init(gpa, dvui.io, data_dir, .{ .sqlite_diagnostics = &diags })) |c| {
        core.?.* = c;
        if (Content.init(gpa, core.?)) |con| {
            content = con;
            dvui.toast(@src(), .{ .message = "Connected!" });
        } else |_| {
            dvui.toast(@src(), .{ .message = "Content init failed" });
        }
    } else |err| {
        var err_buf: [1024]u8 = undefined;
        const err_msg = if (diags.err) |sqlite_err| blk: {
            break :blk std.fmt.bufPrint(&err_buf, "Failed to init: {t}: {s}", .{ err, sqlite_err.message }) catch "Failed to init";
        } else std.fmt.bufPrint(&err_buf, "Failed to init: {t}", .{err}) catch "Failed to init";
        dvui.toast(@src(), .{ .message = err_msg });
    }
}
