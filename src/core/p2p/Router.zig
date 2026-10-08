const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const iroh = @import("iroh");
const Core = @import("../Core.zig");
const database = @import("../database.zig");
const Db = database.Db;
const p2p = @import("../p2p.zig");
const protocols = p2p.protocols;
const Peer = p2p.peer.Peer;
const Self = @This();

const log = std.log.scoped(.p2p_router);

pub const ALPN: iroh.Alpn = .{ .alpn = "/ilm/1" };

pub const ConnectedPeer = struct {
    conn: iroh.Connection,
    id: Peer.Id,
    /// Use this to cancel the conn loop and all its bistream loops
    /// TODO This doesnt work at all..
    io_group: std.Io.Group,
    // sessions: std.ArrayList(protocols.ProtocolSession) = .empty,
    /// Populated if peer is waiting on a pair request
    pair_request: ?*protocols.PairProtocol.IncomingRequest = null,

    pub fn fromConnection(conn: iroh.Connection) ConnectedPeer {
        const id = conn.addr.id.copyBytes();
        return .{
            .conn = conn,
            .id = .{ .bytes = id },
            .io_group = .init,
        };
    }

    pub fn close(self: *ConnectedPeer, io: std.Io) void {
        self.conn.close();
        self.io_group.cancel(io);
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
    /// A new pair was established.
    pair_established: Peer.Id,
    /// Our pair request failed, due to error or rejection.
    /// Not called when we reject incoming pair requests.
    pair_failed: struct {
        peer_id: Peer.Id,
        err: protocols.PairProtocol.PairRequestError,
    },
    sync_start: Peer,
    sync_done: struct {
        peer: Peer,
        err: ?anyerror = null,
    },
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
name: []const u8,

io_group: std.Io.Group,

connections: struct {
    mutex: std.Io.Mutex = .init,
    // TODO Use Peer.Id.Short as key
    peers: std.AutoHashMap(Peer.Id, ConnectedPeer),
},

event_triggers: std.ArrayList(EventTrigger),

pub fn init(gpa: std.mem.Allocator, io: std.Io, db_path: [:0]const u8, secret_key: iroh.SecretKey) !Self {
    iroh.enableTracing();

    var db = try database.getDb(db_path, .{});
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
        .name = try gpa.dupe(u8, "Ilm enjoyer"),
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
    self.gpa.free(self.name);
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

pub fn setName(self: *Self, name: []const u8) !void {
    self.name = try self.gpa.dupe(u8, name);
}

pub fn sendPairRequest(self: *Self, peer_id: Peer.Id) void {
    const request = struct {
        pub fn f(router: *Self, peer: Peer.Id) std.Io.Cancelable!void {
            var recv_buf: [512]u8 = undefined;
            _ = p2p.protocols.PairProtocol.request(router, peer, &recv_buf) catch |err| switch (err) {
                error.Canceled => |e| return e,
                else => |e| log.err("Pair request with {x} failed: {t}", .{ peer.bytes[0..4], e }),
            };
        }
    }.f;
    self.io_group.async(self.io, request, .{ self, peer_id });
}

pub fn sendSyncRequest(self: *Self, peer_id: Peer.Id) void {
    const request = struct {
        pub fn f(router: *Self, peer: Peer.Id) std.Io.Cancelable!void {
            _ = p2p.protocols.SyncProtocol.request(router, peer) catch |err| switch (err) {
                error.Canceled => |e| return e,
                else => |e| log.err("Sync request with {x} failed: {t}", .{ peer.bytes[0..4], e }),
            };
        }
    }.f;
    self.io_group.async(self.io, request, .{ self, peer_id });
}

pub fn connectToEndpoint(self: *Self, peer_id: Peer.Id) !void {
    // We dont check here if peer is already in self.connections because
    // that might be false, and while we are trying to connect, this peer
    // might have in the meanwhile connected, leading to double connect.
    // Instead this logic is handled in handleConn.
    log.info("Attempting connection to peer {x}...", .{peer_id.bytes[0..4]});
    const conn = try self.endpoint.connect(.{ .id = &peer_id.bytes });
    try self.handleConn(conn, true); // closes conn on error
}

pub fn closeConnection(
    self: *Self,
    opts: struct {
        peer_id: Peer.Id,
        conn: ?*iroh.Connection = null,
    },
) void {
    self.connections.mutex.lockUncancelable(self.io);
    defer self.connections.mutex.unlock(self.io);
    if (self.connections.peers.getPtr(opts.peer_id)) |conn_peer| {
        if (opts.conn == null or opts.conn.?.ptr == conn_peer.conn.ptr) {
            conn_peer.close(self.io);
            _ = self.connections.peers.remove(opts.peer_id);
            log.info("Connection dropped to {x}", .{opts.peer_id.bytes[0..4]});
            self.publishEvent(.{ .disconnected = opts.peer_id });
        }
    }
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
        _ = self.connectToEndpoint(p.id) catch |err| {
            log.warn("Failed to connect to peer {s}: {t}", .{ p.name, err });
            continue;
        };
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

    // Connect loops will cleanup and their connections.
    self.io_group.cancel(self.io);

    // Clean up connection map (closing is already done).
    {
        self.connections.mutex.lockUncancelable(self.io);
        defer self.connections.mutex.unlock(self.io);
        self.connections.peers.clearRetainingCapacity();
    }
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

        self.handleConn(conn, false) catch {};
    }
}

/// Register new connection and spawn its connLoop thread
pub fn handleConn(self: *Self, conn: iroh.Connection, initiated: bool) Allocator.Error!void {
    // If we already have a connection, we remove that one and
    // replace it with this new one, as the peer might have
    // lost theirs.
    self.closeConnection(.{ .peer_id = .{ .bytes = conn.addr.id.copyBytes() } });

    errdefer conn.close();

    var conn_peer: ConnectedPeer = .fromConnection(conn);

    {
        self.connections.mutex.lockUncancelable(self.io);
        defer self.connections.mutex.unlock(self.io);
        self.connections.peers.put(conn_peer.id, conn_peer) catch |err| {
            log.err("Failed to store connection: {t}", .{err});
            return err;
        };
    }

    log.info(
        "{s} connection to peer {x}",
        .{ if (initiated) "Initiated" else "Accepted", conn_peer.id.bytes[0..4] },
    );
    self.publishEvent(.{ .connected = .{ .peer_id = conn_peer.id, .initiated = initiated } });
    // self.io_group.async(self.io, connLoop, .{ self, conn_peer.id });
    conn_peer.io_group.async(self.io, connLoop, .{ self, conn_peer.id });
}

/// Listens for new bi streams and spawns new streamLoop thread when
/// one has been established.
fn connLoop(self: *Self, peer_id: Peer.Id) error{Canceled}!void {
    var conn_peer: ConnectedPeer = blk: {
        self.connections.mutex.lockUncancelable(self.io);
        defer self.connections.mutex.unlock(self.io);
        break :blk self.connections.peers.get(peer_id) orelse unreachable;
    };
    var conn = &conn_peer.conn;

    // We specify the connection so that we dont close a newer connection.
    defer self.closeConnection(.{ .peer_id = peer_id, .conn = conn });

    while (true) {
        log.info("Waiting for stream from peer {x}...", .{peer_id.bytes[0..4]});

        const streams = conn.acceptBiStream() catch |err| {
            log.err("Failed to accept stream from {x}: {t}. Quitting connLoop.", .{ peer_id.bytes[0..4], err });
            return error.Canceled;
        };

        log.info("Received stream!", .{});
        self.publishEvent(.{ .stream_received = peer_id });

        // self.io_group.async(self.io, handleStream, .{ self, peer_id, streams });
        conn_peer.io_group.async(self.io, handleStream, .{ self, peer_id, streams });
    }
}

/// Run when a bistream has been established.
fn handleStream(self: *Self, peer_id: Peer.Id, streams: iroh.BiStream) error{Canceled}!void {
    protocols.handleRequest(self, peer_id, streams) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => {},
    };
}
