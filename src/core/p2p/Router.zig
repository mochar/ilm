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
    id: Peer.Id,
    known: bool,
    sessions: std.ArrayList(protocols.ProtocolSession) = .empty,

    pub fn fromConnection(conn: iroh.Connection, db: *Db) ConnectedPeer {
        const id = conn.addr.id.copyBytes();
        const known = p2p_peer.exists(db, &id) catch false;
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
/// Gets consumed when creating an endpoint, so we .dupe() this one.
secret_key: iroh.SecretKey,
name: []const u8 = "Ilm enjoyer",

io_group: std.Io.Group,

connections: struct {
    mutex: std.Io.Mutex = .init,
    peers: std.AutoHashMap(Peer.Id, ConnectedPeer),
},

event_triggers: std.ArrayList(EventTrigger),

pub fn init(gpa: std.mem.Allocator, io: std.Io, db_path: [:0]const u8, secret_key: iroh.SecretKey) !Self {
    iroh.enableTracing();

    var db = try database.getDb(db_path, .{ .write = false, .create = false });
    errdefer db.deinit();

    var endpoint: iroh.Endpoint = try .init(.{
        .gpa = gpa,
        .alpn = &ALPN,
        .secret_key = try secret_key.dupe(),
    });
    errdefer endpoint.deinit();

    return .{
        .gpa = gpa,
        .io = io,
        .db = db,
        .endpoint = endpoint,
        .secret_key = secret_key,
        .io_group = .init,
        .connections = .{ .peers = .init(gpa) },
        .event_triggers = .empty,
    };
}

pub fn deinit(self: *Self) void {
    log.info("Router deinit", .{});

    // TODO This should accept a timeout so that we only gracefully
    // close conncetions if they dont take too long.
    self.stop() catch {};

    {
        self.connections.mutex.lockUncancelable(self.io);
        defer self.connections.mutex.unlock(self.io);
        self.connections.peers.deinit();
    }

    self.event_triggers.deinit(self.gpa);
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

pub fn connectToEndpoint(self: *Self, target: iroh.ConnectionTarget) !Peer.Id {
    // TODO In thread.
    const conn = self.endpoint.connect(target) catch |err| {
        log.err("Failed establish connection: {t}", .{err});
        return err;
    };
    try self.handleConn(conn); // closes conn on error
    return conn.addr.id.copyBytes();
}

pub fn start(self: *Self) !void {
    if (self.endpoint.state == .closed) {
        self.endpoint = try .init(.{
            .gpa = self.gpa,
            .alpn = &ALPN,
            .secret_key = try self.secret_key.dupe(),
        });
    }
    try self.endpoint.ensureOnline();
    log.info("Online!", .{});
    self.endpoint.logAddr();
    self.io_group.async(self.io, acceptLoop, .{self});
}

/// Close all connections and threads.
pub fn stop(self: *Self) !void {
    // Since iroh uses tokio for its async, we have to close the
    // endpoint explicitely to trigger close. This also closes all
    // current connections gracefully, so we can cleanup connections
    // safely.
    self.endpoint.close();

    // Deinit and remove connections. No need to close them, as
    // endpoint.close does that for us.
    {
        self.connections.mutex.lockUncancelable(self.io);
        defer self.connections.mutex.unlock(self.io);
        var iter = self.connections.peers.valueIterator();
        while (iter.next()) |peer| {
            peer.conn.deinit();
        }
        self.connections.peers.clearRetainingCapacity();
    }

    self.io_group.cancel(self.io);
}

// TODO Im not sure if it should return Canceled error, group.async seems to suggest so.
fn acceptLoop(self: *Self) error{Canceled}!void {
    log.info("Listening for connections...", .{});
    while (true) {
        const conn = self.endpoint.accept() catch |err| {
            // In rust closing the connection is mapped to
            // AcceptFailed so we take that as a reason to
            // stop. IncomingError is documented to happen sometimes and
            // just log and retry.
            // AcceptError::ConnectionClosed(_)
            // | AcceptError::ALPNError(_)
            // | AcceptError::ConnectionError(_) => EndpointResult::AcceptFailed,
            // AcceptError::IncomingError(_) => EndpointResult::IncomingError,
            if (err == error.AcceptFailed) {
                log.info("Endpoint closed, quitting connection", .{});
                return error.Canceled;
            } else {
                log.err("Error '{t}' accepting connection, retrying...", .{err});
                continue;
            }
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

    self.io_group.async(self.io, connLoop, .{ self, peer.id });
}

fn connLoop(self: *Self, peer_id: Peer.Id) void {
    self.pushEvent(.{ .connected = .{ .peer_id = peer_id, .initiated = false } }) catch {};

    self.connections.mutex.lockUncancelable(self.io);
    const peer = self.connections.peers.get(peer_id) orelse {
        self.connections.mutex.unlock(self.io);
        unreachable;
    };
    var conn = peer.conn;
    self.connections.mutex.unlock(self.io);

    defer {
        log.info("Connection dropped to {x}", .{peer_id});
        conn.close();
        self.connections.mutex.lockUncancelable(self.io);
        _ = self.connections.peers.remove(peer_id);
        self.connections.mutex.unlock(self.io);
        self.pushEvent(.{ .disconnected = peer_id }) catch {};
    }

    const total_attempts = 3;
    var attempt: usize = 1;
    receive: while (true) {
        log.info("Waiting for stream from peer {x}...", .{peer_id});

        const streams = conn.acceptBiStream() catch |err| {
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
        self.pushEvent(.{ .stream_received = peer_id }) catch {};
        attempt = 1;

        self.io_group.async(self.io, streamLoop, .{ self, peer_id, streams });
    }
}

const StreamState = union(enum) { started, done, protocol: protocols.ProtocolTag };

/// Run when a bistream has been established.
fn streamLoop(self: *Self, peer_id: Peer.Id, streams: iroh.BiStream) void {
    // const peer = self.connections.peers.getPtr(peer_id) orelse unreachable;
    // const conn = &peer.conn;

    defer {
        self.pushEvent(.{ .stream_closed = peer_id }) catch {};
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
