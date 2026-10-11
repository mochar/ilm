const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");

// ** Main
// For android we build a static lib, so zig's start.zig never runs
// and never builds the std.process.Init dvui.App.main needs. main.c
// has the real C main() and calls this exported symbol; hand-build
// the same minimal Init here.

extern "c" var environ: ?[*:null]?[*:0]u8;

pub fn runDvuiMain(argc: c_int, argv: [*][*:0]u8) !u8 {
    const gpa = std.heap.c_allocator;

    var arena_allocator: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_allocator.deinit();

    const args_vector: std.process.Args.Vector = argv[0..@intCast(argc)];
    const environ_block: std.process.Environ.Block = .{ .slice = std.mem.span(environ orelse @as([*:null]?[*:0]u8, @ptrFromInt(@alignOf(?[*:0]u8)))) };

    var threaded: std.Io.Threaded = .init(gpa, .{
        .argv0 = .init(.{ .vector = args_vector }),
        .environ = .{ .block = environ_block },
    });
    defer threaded.deinit();

    var environ_map = try std.process.Environ.createMap(.{ .block = environ_block }, gpa);
    defer environ_map.deinit();

    const preopens = try std.process.Preopens.init(arena_allocator.allocator());

    return dvui.App.main(.{
        .minimal = .{ .args = .{ .vector = args_vector }, .environ = .{ .block = environ_block } },
        .arena = &arena_allocator,
        .gpa = gpa,
        .io = threaded.io(),
        .environ_map = &environ_map,
        .preopens = preopens,
    });
}

// ** Logging
// See https://developer.android.com/ndk/reference/group/logging
// c.SDL_Log poops its pants so cannot use that.

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
