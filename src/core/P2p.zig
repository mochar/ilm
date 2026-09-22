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

pub fn spawnListenThread(self: *Self) !void {
    try self.endpoint.ensureOnline();
    std.log.info("Online!", .{});
    self.endpoint.logAddr();
    self.is_running.store(true, .seq_cst);
    self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
}

pub fn stopListenThread(self: *Self) !void {
    if (self.thread) |thread| {
        self.is_running.store(false, .seq_cst);
        self.endpoint.close();
        thread.join();
    }
}

fn acceptLoop(self: *Self) void {
    var recv_buf: [2048]u8 = undefined;

    std.log.info("Listening for connections...", .{});
    while (self.is_running.load(.seq_cst)) connect: {
        if (self.endpoint.accept()) |conn| {
            defer conn.wait_close() catch {};
            std.log.info("Received connection!", .{});
            _ = self.connections_received.fetchAdd(1, .seq_cst);

            const total_attempts = 3;
            var cur_attempt: usize = 1;
            while (cur_attempt <= total_attempts) receive: {
                std.log.info("Waiting for stream... (Attempt {d}/{d})", .{ cur_attempt, total_attempts });
                var stream = conn.createRecvStream() catch {
                    cur_attempt += 1;
                    break :receive;
                };
                defer stream.deinit();
                std.log.info("Received stream!", .{});

                // On error downstream, we enter the while loop again,
                // but with a fresh number of attempts.
                cur_attempt = 1;

                while (true) {
                    // TODO On timeout break connection
                    if (stream.read(&recv_buf, .{ .timeout_ms = 5000 }) catch break :receive) |msg| {
                        std.log.info("Got message: {s}", .{msg});
                    } else {
                        std.log.info("Stream EOF", .{});
                        conn.close();
                        break :connect;
                    }
                }
            }
        } else |err| {
            std.log.err("Error '{any}' accepting action", .{err});
        }
    }
}
