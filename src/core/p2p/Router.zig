const std = @import("std");
const sqlite = @import("sqlite");
const iroh = @import("iroh");
const Core = @import("../Core.zig");
const database = @import("../database/database.zig");
const Db = database.Db;
const p2p_peer = @import("peer.zig");
const protocols = @import("protocols.zig");
const Peer = p2p_peer.Peer;
const Self = @This();

const log = std.log.scoped(.p2p);

pub const ALPN: iroh.Alpn = .{ .alpn = "/ilm/1" };

pub const ConnectedPeer = struct {
    conn: iroh.Connection,
    id: *const Peer.Id,
    known: bool,
    sessions: std.ArrayList(protocols.ProtocolSession) = .empty,

    pub fn fromConnection(conn: iroh.Connection, db: *Db) ConnectedPeer {
        const id = conn.addr.id.bytes();
        const known = p2p_peer.exists(db, id) catch false;
        return .{ .conn = conn, .id = id, .known = known };
    }
};

pub const Event = union(enum) {
    connected: struct {
        peer_id: Peer.Id,
        /// Did we start the connection?
        initiated: bool,
    },
    disconnected: Peer.Id,
    stream_received: Peer.Id,
    stream_closed: Peer.Id,
    // own message buf to not deal with allocation
    message: struct {
        buf: [512]u8,
        len: usize,
    },
};

/// A trigger to be called when a new event happens.
/// This prevents the need to poll the queue manually.
/// Note that the event is not passed, the queue must be drained still.
pub const EventTrigger = struct {
    ctx: ?*anyopaque = null,
    triggerFn: *const fn (ctx: ?*anyopaque, event: Event) void,

    pub fn trigger(self: EventTrigger, event: Event) void {
        self.triggerFn(self.ctx, event);
    }
};

gpa: std.mem.Allocator,
io: std.Io,
db: database.Db,
endpoint: iroh.Endpoint,
name: []const u8 = "Ilm enjoyer",

thread: ?std.Thread = null,
is_running: std.atomic.Value(bool) = .init(false),

connections: struct {
    mutex: std.Io.Mutex = .init,
    peers: std.AutoHashMap(*const Peer.Id, ConnectedPeer),
},

event_triggers: std.ArrayList(EventTrigger),

pub fn init(gpa: std.mem.Allocator, io: std.Io, db_path: [:0]const u8, secret_key: iroh.SecretKey) !Self {
    var db = try database.getDb(db_path, .{ .write = false, .create = false });
    errdefer db.deinit();
    
    var endpoint: iroh.Endpoint = try .init(.{
        .gpa = gpa,
        .alpn = &ALPN,
        .secret_key = secret_key,
    });
    errdefer endpoint.deinit();

    return .{
        .gpa = gpa,
        .io = io,
        .db = db,
        .endpoint = endpoint,
        .connections = .{ .peers = .init(gpa) },
        .event_triggers = .empty,
    };
}

pub fn deinit(self: *Self) void {
    self.stopListenThread() catch |err| {
        log.err("Failed to stop p2p listen thread: {t}", .{err});
    };
    // self.endpoint.close();

    self.event_triggers.deinit(self.gpa);

    self.connections.mutex.lockUncancelable(self.io);
    defer self.connections.mutex.unlock(self.io);
    self.connections.peers.deinit();

    self.db.deinit();
}

pub fn getCore(self: *const Self) *Core {
    return @fieldParentPtr("p2p", self);
}

pub fn addEventTrigger(self: *Self, trigger: EventTrigger) !void {
    try self.event_triggers.append(self.gpa, trigger);
}

fn pushEvent(self: *Self, event: Event) !void {
    for (self.event_triggers.items) |*trigger| {
        trigger.trigger(event);
    }
}

pub fn connect(self: *Self, target: iroh.ConnectionTarget) !Peer.Id {
    // TODO In thread.
    const conn = self.endpoint.connect(target) catch |err| {
        log.err("Failed establish connection: {t}", .{err});
        return err;
    };
    try self.handleConn(conn); // closes conn on error
    return conn.addr.id.copyBytes();
}

pub fn spawnListenThread(self: *Self) !void {
    try self.endpoint.ensureOnline();
    log.info("Online!", .{});
    self.endpoint.logAddr();
    self.is_running.store(true, .seq_cst);
    if (std.Thread.spawn(.{}, acceptLoop, .{ self })) |thread| {
        thread.detach();
        self.thread = thread;
    } else |err| {
        log.err("Failed to spawn p2p thread: {t}", .{err});
        return err;
    }
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

fn acceptLoop(self: *Self) void {
    log.info("Listening for connections...", .{});
    while (self.is_running.load(.seq_cst)) {
        const conn = self.endpoint.accept() catch |err| {
            log.err("Error '{t}' accepting connection", .{err});
            continue;
        };
        log.info("Received connection!", .{});
        self.handleConn(conn) catch {};
    }
}

fn handleConn(self: *Self, conn: iroh.Connection) !void {
    errdefer conn.close();
    const peer: ConnectedPeer = .fromConnection(conn, &self.db);

    self.connections.mutex.lockUncancelable(self.io);
    defer self.connections.mutex.unlock(self.io);
    self.connections.peers.put(peer.id, peer) catch |err| {
        log.err("Failed to store connection: {t}", .{err});
        return err;
    };
    errdefer _ = self.connections.peers.remove(peer.id);

    if (std.Thread.spawn(.{}, connLoop, .{ self, peer.id })) |conn_thread| {
        conn_thread.detach();
        self.pushEvent(.{ .connected = .{ .peer_id = peer.id.*, .initiated = false } }) catch {};
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

const StreamState = union(enum) { started, done, protocol: protocols.ProtocolTag };

/// Run when a bistream has been established.
fn streamLoop(self: *Self, peer_id: *const Peer.Id, streams: iroh.BiStream) void {
    // const peer = self.connections.peers.getPtr(peer_id) orelse unreachable;
    // const conn = &peer.conn;

    defer {
        self.pushEvent(.{ .stream_closed = peer_id.* }) catch {};
    }

    var recv_buf: [512]u8 = undefined;

    {
        const protocol_tag = streams.recv.readExact(recv_buf[0..1], 5000) catch |err| {
            log.err("Failed to read protocol tag: {t}", .{err});
            return;
        };
        const protocol: protocols.ProtocolTag = @enumFromInt(protocol_tag[0]);
        log.info("Requested with protocol {t}", .{protocol});
        switch (protocol) {
            .pair => {
                const name = streams.recv.readToEnd(&recv_buf, 5000) catch |err| {
                    log.err("Failed to read pair name: {t}", .{err});
                    return;
                };
                streams.recv.deinit();
                log.info("Pair requested with name {s}", .{name});

                streams.send.write("OK", 5000) catch |err| {
                    log.err("Failed to write back to pair: {t}", .{err});
                    return;
                };
                streams.send.finish();
                return;
            },
            _ => {
                log.err("Sender specified unknown protocol {d}", .{protocol_tag[0]});
                return;
            },
            else => {
                log.err("Unhandled protocol: {t}", .{protocol});
                return;
            },
        }
    }
}
