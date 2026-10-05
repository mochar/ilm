const std = @import("std");
const sqlite = @import("sqlite");
const iroh = @import("iroh");
const Core = @import("../Core.zig");
const database = @import("../database/database.zig");
const Db = database.Db;
const p2p = @import("../p2p.zig");
const protocols = p2p.protocols;
const Peer = p2p.peer.Peer;
const Self = @This();

const log = std.log.scoped(.p2p);

pub const ALPN: iroh.Alpn = .{ .alpn = "/ilm/1" };

pub const ConnectedPeer = struct {
    conn: iroh.Connection,
    id: Peer.Id,
    // sessions: std.ArrayList(protocols.ProtocolSession) = .empty,
    /// Populated if peer is waiting on a pair request
    pair_request: ?*protocols.PairProtocol.IncomingRequest = null,

    pub fn fromConnection(conn: iroh.Connection) ConnectedPeer {
        const id = conn.addr.id.copyBytes();
        return .{ .conn = conn, .id = .{ .bytes = id } };
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
    pair_request: *protocols.PairProtocol.IncomingRequest,
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
    return @constCast(@fieldParentPtr("router", self));
}

pub fn addEventTrigger(self: *Self, trigger: EventTrigger) std.mem.Allocator.Error!void {
    try self.event_triggers.append(self.gpa, trigger);
}

pub fn publishEvent(self: *Self, event: Event) void {
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
    return .{ .bytes = conn.addr.id.copyBytes() };
}

/// Try to establish connections with all known peers.
fn connectToPeers(self: *Self) !void {
    var arena_alloc: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    const peers = p2p.peer.getAll(&self.db, arena) catch |err| {
        log.err("Failed to get peers: {t}", .{err});
        return err;
    };
    for (peers) |p| {
        _ = self.connectToEndpoint(.{ .id = &p.id.bytes }) catch |err| {
            log.err("Failed to connect to peer {s}: {t}", .{ p.name, err });
            continue;
        };
        log.info("Connect to peer {s}", .{p.name});
    }
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

    self.io_group.async(self.io, struct {
        pub fn f(s: *Self) error{Canceled}!void {
            s.connectToPeers() catch return error.Canceled;
        }
    }.f, .{self});
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
// TODO Use std.Io.checkCancel(self.io) with errdefer closing endpoint
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

/// Register new connection and spawn its connLoop thread
fn handleConn(self: *Self, conn: iroh.Connection) !void {
    errdefer conn.close();
    const peer: ConnectedPeer = .fromConnection(conn);

    self.connections.mutex.lockUncancelable(self.io);
    defer self.connections.mutex.unlock(self.io);
    self.connections.peers.put(peer.id, peer) catch |err| {
        log.err("Failed to store connection: {t}", .{err});
        return err;
    };
    errdefer _ = self.connections.peers.remove(peer.id);

    self.io_group.async(self.io, connLoop, .{ self, peer.id });
}

/// Listens for new bi streams and spawns new streamLoop thread when
/// one has been established.
fn connLoop(self: *Self, peer_id: Peer.Id) void {
    self.publishEvent(.{ .connected = .{ .peer_id = peer_id, .initiated = false } });

    self.connections.mutex.lockUncancelable(self.io);
    const peer = self.connections.peers.get(peer_id) orelse {
        self.connections.mutex.unlock(self.io);
        unreachable;
    };
    var conn = peer.conn;
    self.connections.mutex.unlock(self.io);

    defer {
        log.info("Connection dropped to {x}", .{peer_id.bytes});
        conn.close();
        self.connections.mutex.lockUncancelable(self.io);
        _ = self.connections.peers.remove(peer_id);
        self.connections.mutex.unlock(self.io);
        self.publishEvent(.{ .disconnected = peer_id });
    }

    const total_attempts = 3;
    var attempt: usize = 1;
    receive: while (true) {
        log.info("Waiting for stream from peer {x}...", .{peer_id.bytes});

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
        self.publishEvent(.{ .stream_received = peer_id });
        attempt = 1;

        self.io_group.async(self.io, streamLoop, .{ self, peer_id, streams });
    }
}

/// Run when a bistream has been established.
fn streamLoop(self: *Self, peer_id: Peer.Id, streams_: iroh.BiStream) error{Canceled}!void {
    defer self.publishEvent(.{ .stream_closed = peer_id });

    var streams = streams_; // get a nonconst copy

    // All bistreams start with client sending the protocol tag.
    // All we do here is check this tag, and call the associated protocol
    // function to do the actual work.
    var protocol_buf: [1]u8 = undefined;
    _ = streams.recv.readExact(&protocol_buf, 5000) catch |err| {
        log.err("Failed to read protocol tag: {t}", .{err});
        streams.deinit();
        return;
    };
    const protocol_tag = protocol_buf[0];
    const protocol: protocols.ProtocolTag = @enumFromInt(protocol_tag);

    switch (protocol) {
        .pair => {
            log.info("Client requested pair", .{});
            p2p.protocols.PairProtocol.accept(self, streams, peer_id) catch |err| switch (err) {
                error.Canceled => |e| return e,
                else => log.err("Pair request failed: {t}", .{err}),
            };
        },
        _ => {
            log.err("Client specified unknown protocol '{d}', breaking bistream", .{protocol_tag});
            streams.send.write(&.{1}, 5000) catch |err| {
                log.err("Failed to write back: {t}", .{err});
            };
            streams.deinit();
        },
    }
}
