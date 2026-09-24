const std = @import("std");
const Core = @import("Core.zig");
const iroh = @import("iroh");
const Self = @This();

pub const ALPN = "/ilm/sync/1";
const EVENT_QUEUE_SIZE = 128;

pub const Event = union(enum) {
    connected: usize,
    disconnected: usize,
    stream_received: void,
    stream_closed: void,
    // own message buf to not deal with allocation
    message: struct {
        buf: [512]u8,
        len: usize,
    },
};
pub const EventQueue = std.Io.Queue(Event);

/// A trigger to be called when a new event happens.
/// This prevents the need to poll the queue manually.
/// Note that the event is not passed, the queue must be drained still.
pub const EventTrigger = struct {
    ctx: ?*anyopaque = null,
    triggerFn: *const fn (ctx: ?*anyopaque) void,

    pub fn trigger(self: EventTrigger) void {
        self.triggerFn(self.ctx);
    }
};

gpa: std.mem.Allocator,
io: std.Io,
endpoint: iroh.Endpoint,
thread: ?std.Thread = null,
is_running: std.atomic.Value(bool) = .init(false),
connections_received: std.atomic.Value(usize) = .init(0),
connection_mutex: std.Io.Mutex = .init,
connection: ?iroh.Connection = null,
events: []Event,
event_queue: EventQueue,
event_triggers: std.ArrayList(EventTrigger),

pub fn init(gpa: std.mem.Allocator, io: std.Io, secret_key: iroh.SecretKey) !Self {
    var endpoint: iroh.Endpoint = try .init(.{ .gpa = gpa, .alpn = ALPN, .secret_key = secret_key });
    errdefer endpoint.deinit();

    const events = try gpa.alloc(Event, EVENT_QUEUE_SIZE);
    errdefer gpa.free(events);

    return .{
        .endpoint = endpoint,
        .gpa = gpa,
        .io = io,
        .events = events,
        .event_queue = .init(events),
        .event_triggers = .empty,
    };
}

pub fn deinit(self: *Self) void {
    self.stopListenThread() catch |err| {
        std.log.err("Failed to stop p2p listen thread: {t}", .{err});
    };
    self.endpoint.deinit();
    self.gpa.free(self.events);
    self.event_triggers.deinit(self.gpa);
    // self.event_queue.close(self.io); // not really necessary
}

pub fn getCore(self: *const Self) *const Core {
    return @fieldParentPtr("p2p", self);
}

pub fn addEventTrigger(self: *Self, trigger: EventTrigger) !void {
    try self.event_triggers.append(self.gpa, trigger);
}

fn pushEvent(self: *Self, event: Event) !void {
    try self.event_queue.putOneUncancelable(self.io, event);
    for (self.event_triggers.items) |*trigger| {
        trigger.trigger();
    }
}

pub fn drainEvents(self: *Self, buffer: []Event) ![]Event {
    const count = self.event_queue.getUncancelable(self.io, buffer, 0) catch 0;
    return buffer[0..count];
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
    var recv_buf: [512]u8 = undefined;

    std.log.info("Listening for connections...", .{});
    connect: while (self.is_running.load(.seq_cst)) {
        if (self.endpoint.accept()) |conn| {
            std.log.info("Received connection!", .{});

            var n_conns = self.connections_received.fetchAdd(1, .seq_cst);
            self.pushEvent(.{ .connected = n_conns }) catch {};

            if (self.connection_mutex.lock(self.io)) {
                self.connection = conn;
                self.connection_mutex.unlock(self.io);
                defer if (self.connection_mutex.lock(self.io)) {
                    self.connection = null;
                    self.connection_mutex.unlock(self.io);
                } else |err| {
                    std.log.err("Failed to lock mutex in p2p accept loop to remove connection: {t}", .{err});
                };
            } else |err| {
                std.log.err("Failed to lock mutex in p2p accept loop to set connection: {t}", .{err});
            }

            const total_attempts = 3;
            var cur_attempt: usize = 1;
            receive: while (cur_attempt <= total_attempts) {
                std.log.info("Waiting for stream... (Attempt {d}/{d})", .{ cur_attempt, total_attempts });
                var stream = conn.createRecvStream() catch {
                    cur_attempt += 1;
                    continue :receive;
                };
                std.log.info("Received stream!", .{});
                self.pushEvent(.stream_received) catch {};

                defer {
                    stream.deinit();
                    self.pushEvent(.stream_closed) catch {};
                }

                // On error downstream, we enter the while loop again,
                // but with a fresh number of attempts.
                cur_attempt = 1;

                while (true) {
                    // TODO On timeout break connection
                    if (stream.read(&recv_buf, .{ .timeout_ms = 5000 }) catch continue :receive) |msg| {
                        std.log.info("Got message: {s}", .{msg});
                        self.pushEvent(.{ .message = .{ .buf = recv_buf, .len = msg.len } }) catch {};
                    } else {
                        std.log.info("Stream EOF", .{});
                        conn.close();
                        n_conns = self.connections_received.fetchSub(1, .seq_cst);
                        self.pushEvent(.{ .disconnected = n_conns }) catch {};
                        continue :connect;
                    }
                }
            }
        } else |err| {
            std.log.err("Error '{any}' accepting action", .{err});
        }
    }
}
