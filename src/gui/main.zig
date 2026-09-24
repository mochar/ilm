const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const sqlite = @import("sqlite");
const sdl = @import("sdl-backend");
const ilm = @import("ilm");
const Core = ilm.Core;
const ContentView = @import("ContentView.zig");
const SetupView = @import("SetupView.zig");

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
    .logFn = dvui.App.logFn,
};

var gpa_instance = std.heap.DebugAllocator(.{
    .never_unmap = true,
    .retain_metadata = true,
}){};
const gpa = gpa_instance.allocator();
var frame_arena_allocator: std.heap.ArenaAllocator = .init(gpa);
const arena = frame_arena_allocator.allocator();

const View = union(enum) {
    main: void,
    content: ContentView,
    setup: SetupView,
};

var view: View = .main;
var core: ?*Core = null;
/// Holds copied-over events from the p2p event queue. See p2pEventTrigger.
var p2p_event_queue: [32]ilm.P2p.Event = undefined;

/// Called when a new p2p events are available. Drains events and updates ui.
fn p2pEventTrigger(window_opaque: ?*anyopaque) void {
    const window: *dvui.Window = @ptrCast(@alignCast(window_opaque orelse unreachable));
    if (core) |c| blk: {
        const events = c.p2p.drainEvents(&p2p_event_queue) catch break :blk;
        for (events) |event| {
            switch (event) {
                .connected => dvui.toast(@src(), .{ .window = window, .message = "Connected to p2p client" }),
                .disconnected => dvui.toast(@src(), .{ .window = window, .message = "Disconnected from p2p client" }),
                .stream_received => dvui.toast(@src(), .{ .window = window, .message = "Stream received to p2p client" }),
                .stream_closed => dvui.toast(@src(), .{ .window = window, .message = "Stream closed to p2p client" }),
                .message => |payload| {
                    const msg = payload.buf[0..payload.len];
                    const txt = std.fmt.allocPrint(arena, "Recieved p2p msg: {s}", .{msg}) catch "OOM";
                    dvui.toast(@src(), .{ .window = window, .message = txt });
                },
            }
        }
    }
}

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
    _ = win;

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
        switchView(.{ .setup = .init(gpa) });
    }
}

// Run as app is shutting down before dvui.Window.deinit()
pub fn appDeinit(win: *dvui.Window) void {
    _ = win;
    switch (view) {
        .main => {},
        inline else => |*v| v.deinit(),
    }
    if (core) |c| {
        c.deinit();
        gpa.destroy(c);
    }
}

pub fn appFrame() !dvui.App.Result {
    // TODO Use max capacity, see DVUI Window.zig for example
    defer _ = frame_arena_allocator.reset(.retain_capacity);

    var scaler = dvui.scale(
        @src(),
        .{ .scale = &dvui.currentWindow().content_scale, .pinch_zoom = .global },
        .{ .rect = .cast(dvui.windowRect()) },
    );
    scaler.deinit();

    // if (menu()) |res| return res;

    var box = dvui.box(@src(), .{}, .{ .expand = .both });
    defer box.deinit();

    switch (view) {
        .main => {},
        inline else => |*v| v.render(),
    }

    return .ok;
}

pub fn connect(data_dir: []const u8) void {
    if (core) |c| c.deinit();

    var diags: sqlite.Diagnostics = .{};
    core = gpa.create(Core) catch {
        return dvui.toast(@src(), .{ .message = "Failed to allocate Core" });
    };
    if (Core.init(.{ .gpa = gpa, .io = dvui.io, .data_dir = data_dir, .sqlite_diagnostics = &diags })) |c| {
        core.?.* = c;
        core.?.p2p.addEventTrigger(.{
            .ctx = dvui.currentWindow(),
            .triggerFn = p2pEventTrigger,
        }) catch |err| {
            std.log.err("Failed to add p2p event trigger: {t}", .{err});
            dvui.toast(@src(), .{ .message = "Failed to add p2p event trigger" });
        };
        core.?.setupP2p() catch |err| {
            std.log.err("Failed to setup p2p: {t}", .{err});
            dvui.toast(@src(), .{ .message = "Failed to setup p2p" });
        };
        if (ContentView.init(gpa, core.?)) |con| {
            switchView(.{ .content = con });
            dvui.toast(@src(), .{ .message = "Connected!" });
        } else |_| {
            dvui.toast(@src(), .{ .message = "Content init failed" });
        }
    } else |err| {
        gpa.destroy(core.?);
        core = null;
        var err_buf: [1024]u8 = undefined;
        const err_msg = if (diags.err) |sqlite_err| blk: {
            break :blk std.fmt.bufPrint(&err_buf, "Failed to init: {t}: {s}", .{ err, sqlite_err.message }) catch "Failed to init";
        } else std.fmt.bufPrint(&err_buf, "Failed to init: {t}", .{err}) catch "Failed to init";
        dvui.toast(@src(), .{ .message = err_msg });
    }
}
