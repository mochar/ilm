const std = @import("std");
const Core = @import("Core.zig");
const iroh = @import("iroh");
const Self = @This();

pub const ALPN = "/ilm/sync/1";

endpoint: iroh.Endpoint,
thread: ?std.Thread = null,
is_running: std.atomic.Value(bool) = .init(false),
mutex: std.Io.Mutex = .init,
connections_received: std.atomic.Value(usize) = .init(0),

pub fn init(gpa: std.mem.Allocator) !Self {
    const endpoint: iroh.Endpoint = try .init(gpa, ALPN);
    return .{ .endpoint = endpoint };
}

pub fn deinit(self: *Self) void {
    self.endpoint.deinit();
}

pub fn getCore(self: *const Self) *const Core {
    return @fieldParentPtr("p2p", self);
}

pub fn spawnListenThread(self: *Self, io: std.Io) !void {
    try self.endpoint.ensureOnline();
    std.log.info("Online!", .{});
    self.endpoint.logAddr();
    self.is_running.store(true, .seq_cst);
    self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self, io});
}

pub fn stopListenThread(self: *Self) !void {
    if (self.thread) |thread| {
        self.is_running.store(false, .seq_cst);
        self.endpoint.close();
        thread.join();
    }
}

fn acceptLoop(self: *Self, io: std.Io) void {
    _ = io;
    std.log.info("Listening for connections...", .{});
    while (self.is_running.load(.seq_cst)) {
        if (self.endpoint.accept()) |conn| {
            defer conn.deinit();
            std.log.info("Received connection", .{});
            _ = self.connections_received.fetchAdd(1, .seq_cst);
        } else |err| {
            std.log.err("Error '{any}' accepting action", .{err});
        }
    }
}
