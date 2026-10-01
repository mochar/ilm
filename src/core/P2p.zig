const std = @import("std");
const sqlite = @import("sqlite");
const iroh = @import("iroh");
const Core = @import("Core.zig");
const database = @import("database/database.zig");
const pair = @import("p2p/pair.zig");
const sync = @import("p2p/sync.zig");
const p2p_peer = @import("p2p/peer.zig");
const Peer = p2p_peer.Peer;
const Self = @This();

const log = std.log.scoped(.p2p);

pub const ALPN: iroh.Alpn = .{ .alpn = "/ilm/1" };

pub const ConnectedPeer = struct {
    conn: iroh.Connection,
    id: *const Peer.Id,
    known: bool,

    pub fn fromConnection(conn: iroh.Connection, core: *Core) ConnectedPeer {
        const id = conn.addr.id.bytes();
        const known = p2p_peer.known(core, id) catch false;
        return .{ .conn = conn, .id = id, .known = known };
    }
};

const EVENT_QUEUE_SIZE = 128;

pub const Event = union(enum) {
    connected: Peer.Id,
    disconnected: Peer.Id,
    stream_received: Peer.Id,
    stream_closed: Peer.Id,
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
name: []const u8 = "Ilm enjoyer",

thread: ?std.Thread = null,
is_running: std.atomic.Value(bool) = .init(false),

connections: struct {
    mutex: std.Io.Mutex = .init,
    peers: std.AutoHashMap(*const Peer.Id, ConnectedPeer),
},

events: []Event,
event_queue: EventQueue,
event_triggers: std.ArrayList(EventTrigger),

pub fn init(gpa: std.mem.Allocator, io: std.Io, secret_key: iroh.SecretKey) !Self {
    var endpoint: iroh.Endpoint = try .init(.{
        .gpa = gpa,
        .alpn = &ALPN,
        .secret_key = secret_key,
    });
    errdefer endpoint.deinit();

    const events = try gpa.alloc(Event, EVENT_QUEUE_SIZE);
    errdefer gpa.free(events);

    return .{
        .gpa = gpa,
        .io = io,
        .endpoint = endpoint,
        .connections = .{ .peers = .init(gpa) },
        .events = events,
        .event_queue = .init(events),
        .event_triggers = .empty,
    };
}

pub fn deinit(self: *Self) void {
    self.stopListenThread() catch |err| {
        log.err("Failed to stop p2p listen thread: {t}", .{err});
    };
    // self.endpoint.close();
    
    self.event_triggers.deinit(self.gpa);
    // self.event_queue.close(self.io); // not really necessary
    self.gpa.free(self.events);

    self.connections.mutex.lockUncancelable(self.io);
    defer self.connections.mutex.unlock(self.io);
    self.connections.peers.deinit();
}

pub fn getCore(self: *const Self) *Core {
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

pub fn spawnListenThread(self: *Self, core: *Core) !void {
    try self.endpoint.ensureOnline();
    log.info("Online!", .{});
    self.endpoint.logAddr();
    self.is_running.store(true, .seq_cst);
    self.thread = std.Thread.spawn(.{}, acceptLoop, .{ self, core }) catch |err| {
        log.err("Failed to spawn p2p thread: {t}", .{err});
        return err;
    };
    self.thread.?.detach();
}

pub fn stopListenThread(self: *Self) !void {
    // TODO Closing endpoint at any point, here or in deinit, causes
    // deadlock when closing program. Maybe this is fixed if we use
    // io.Group and cancel all threads by canceling that group.
    if (self.thread) |thread| {
        _ = thread; // autofix
        self.is_running.store(false, .seq_cst);
        // self.endpoint.close();
        // thread.join();
    }
}

fn acceptLoop(self: *Self, core: *Core) void {
    log.info("Listening for connections...", .{});
    while (self.is_running.load(.seq_cst)) {
        const conn = self.endpoint.accept() catch |err| {
            log.err("Error '{t}' accepting connection", .{err});
            continue;
        };
        log.info("Received connection!", .{});
        self.handleConn(conn, core) catch |err| {
            log.err("Failed to handle connection, closing ({t})", .{err});
            conn.close();
        };
    }
}

fn handleConn(self: *Self, conn: iroh.Connection, core: *Core) !void {
    const peer: ConnectedPeer = .fromConnection(conn, core);

    self.connections.mutex.lockUncancelable(self.io);
    defer self.connections.mutex.unlock(self.io);
    try self.connections.peers.put(peer.id, peer);
    errdefer _ = self.connections.peers.remove(peer.id);

    if (std.Thread.spawn(.{}, connLoop, .{ self, peer.id })) |conn_thread| {
        conn_thread.detach();
        self.pushEvent(.{ .connected = peer.id.* }) catch {};
    } else |err| {
        log.err("Failed to spawn connection thread: {t}", .{err});
        return err;
    }
}

fn connLoop(self: *Self, peer_id: *const Peer.Id) void {
    const peer = self.connections.peers.getPtr(peer_id) orelse unreachable;
    const conn = &peer.conn;

    defer {
        log.info("Connection dropped to {x}", .{peer_id});
        conn.close();
        _ = self.connections.peers.remove(peer_id);
        self.pushEvent(.{ .disconnected = peer_id.* }) catch {};
    }

    const total_attempts = 3;
    var attempt: usize = 1;
    receive: while (true) {
        log.info("Waiting for stream from peer {x}...", .{peer_id});

        var streams = conn.acceptBiStream() catch |err| {
            if (attempt == total_attempts) {
                log.err("Failed to accept stream: {t}. Quitting at attempt {d}", .{ err, attempt });
                return;
            } else {
                log.err("Failed to accept stream: {t}. Trying again.", .{err});
                attempt += 1;
                continue :receive;
            }
        };

        log.info("Received stream!", .{});
        self.pushEvent(.{ .stream_received = peer_id.* }) catch {};
        attempt = 1;

        if (std.Thread.spawn(.{}, streamLoop, .{ self, peer_id, streams })) |stream_thread| {
            stream_thread.detach();
        } else |err| {
            log.err("Failed to spawn stream thread: {t}", .{err});
            streams.deinit();
            self.pushEvent(.{ .stream_closed = peer_id.* }) catch {};
        }
    }
}

fn streamLoop(self: *Self, peer_id: *const Peer.Id, streams: iroh.BiStream) void {
    // const peer = self.connections.peers.getPtr(peer_id) orelse unreachable;
    // const conn = &peer.conn;

    defer {
        streams.deinit();
        self.pushEvent(.{ .stream_closed = peer_id.* }) catch {};
    }

    var recv_buf: [512]u8 = undefined;

    while (true) {
        const msg = streams.recv.read(&recv_buf, .{ .timeout_ms = 5000 }) catch |err| switch (err) {
            error.Timeout => {
                log.info("Timed out waiting for message", .{});
                continue;
            },
            else => {
                log.err("Stream read error: {t}. Killing stream.", .{err});
                return;
            },
        };

        if (msg.len == 0) {
            log.info("Stream EOF on peer {x}. Quitting.", .{peer_id});
            return;
        }

        log.info("Got message: {x}", .{msg});
        self.pushEvent(.{ .message = .{ .buf = recv_buf, .len = msg.len } }) catch {};
    }
}
