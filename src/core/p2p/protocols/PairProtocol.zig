const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const ilm = @import("../../root.zig");
const p2p = ilm.p2p;
const Peer = p2p.Peer;
const Router = p2p.Router;
const ConnectedPeer = Router.ConnectedPeer;
const iroh = @import("iroh");

const log = std.log.scoped(.p2p_pair_protocol);

pub const TAG: p2p.protocols.ProtocolTag = .pair;

pub const IncomingRequest = struct {
    pub const Response = enum { accept, reject };

    peer_id: Peer.Id,
    name: []const u8,
    response: Response = .reject,
    /// Used to suspend peer stream thread and resume it when the
    /// user accepts or rejects this pair.
    signal: std.Io.Event = .unset,

    pub fn accept(self: *IncomingRequest, io: std.Io) void {
        self.response = .accept;
        self.signal.set(io);
    }

    pub fn reject(self: *IncomingRequest, io: std.Io) void {
        self.response = .reject;
        self.signal.set(io);
    }
};

const State = union(enum) {
    dormant,
    // When sending
    requesting,
    // When accepting
    accepting,
    /// Populated if peer is waiting on a pair request
    waiting_approval: *IncomingRequest,
};

router: *Router,
arena: std.heap.ArenaAllocator,
state: State = .dormant,

pub fn init(gpa: Allocator, router: *Router) Self {
    return .{
        .router = router,
        .arena = .init(gpa),
    };
}

pub fn deinit(self: *Self) void {
    self.arena.deinit();
}

fn connectedPeer(self: *Self) *ConnectedPeer {
    return @fieldParentPtr("pair", self);
}

pub const PairError = error{
    Busy,
    Database,
} || Allocator.Error || iroh.EndpointError || std.Io.Cancelable;

pub const PairAcceptError = error{NotConnected} || PairError;

pub fn accept(self: *Self, streams_: iroh.BiStream) PairAcceptError!void {
    if (self.state != .dormant) return error.Busy;
    self.state = .accepting;
    defer self.state = .dormant;

    const core = self.router.getCore();
    const io = core.io;
    const peer = self.connectedPeer();
    const arena = self.arena.allocator();
    defer _ = self.arena.reset(.free_all);

    var streams = streams_; // get a nonconst copy
    defer streams.deinit();

    var recv_buf: [512]u8 = undefined;
    var accepted: bool = undefined;
    var name: []const u8 = undefined;

    const stored_peer = p2p.peer.getById(&self.router.db, arena, &peer.id) catch return error.Database;

    if (stored_peer) |known_peer| {
        log.info("Peer already known, accepting.", .{});
        accepted = true;
        name = known_peer.name;
    } else {
        // Client is supposed to send its name and immediately finish.
        // TODO: std.unicode.utf8ValidateSlice(input: []const u8)
        name = streams.recv.readToEnd(&recv_buf, 5000) catch |err| {
            log.err("Failed to read pair name: {t}", .{err});
            return err;
        };
        log.info("Pair client name: '{s}'", .{name});

        var pair_req: IncomingRequest = .{
            .peer_id = peer.id,
            .name = name,
        };
        self.state = .{ .waiting_approval =  &pair_req };
        defer self.state = .accepting;
        self.router.publishEvent(.{ .pair_request = &pair_req });

        // Pause thread, wait for user feedback, or thread cancel.
        try pair_req.signal.wait(io); // Cancelable

        accepted = pair_req.response == .accept;
    }

    // Accept: 1-byte + name, end stream
    // Reject: 0-byte, end stream
    const response: []const u8 = if (accepted)
        try std.mem.concat(arena, u8, &.{ &.{0}, self.router.name })
    else
        &.{1};
    streams.send.write(response, 5000) catch |err| {
        log.err("Failed to write back to peer {x}: {t}", .{ peer.id.bytes[0..4], err });
        // continue if we err
    };
    streams.send.finish();

    if (accepted and stored_peer == null) {
        p2p.peer.add(core, name, peer.id) catch return error.Database;
    }
}

pub const PairRequestError = error{
    KnownPeer,
    InvalidResponse,
    Rejected,
} || PairError;

/// Request pairing with a peer. Blocks until done or error.
///
/// If the peer accepts, the peer info will be stored in the
/// db which can be queried to get info of this peer.
pub fn request(self: *Self) PairRequestError!void {
    if (self.state != .dormant) return error.Busy;
    self.state = .requesting;
    defer self.state = .dormant;

    const peer = self.connectedPeer();
    
    if (p2p.peer.exists(&self.router.db, &peer.id) catch false) return error.KnownPeer;
    
    if (self.requestInner()) {
        self.router.publishEvent(.{ .pair_established = peer.id });
    } else |err| {
        self.router.publishEvent(.{ .pair_failed = .{ .peer_id = peer.id, .err = err } });
        return err;
    }
}

fn requestInner(self: *Self) PairRequestError!void {
    const peer = self.connectedPeer();
    log.info("Requesting pair with {x}", .{peer.id.bytes});
    
    const core = self.router.getCore();
    const conn = &peer.conn;
    const arena = self.arena.allocator();
    defer _ = self.arena.reset(.free_all);

    var streams = try conn.openBiStream();

    const proto_byte: u8 = @intFromEnum(TAG);
    const pair_bytes = try std.mem.concat(arena, u8, &.{ &.{proto_byte}, self.router.name });
    try streams.send.write(pair_bytes, 5000);
    streams.send.finish();

    // Expect to receive a 1-byte for a reject, or a 0-byte plus
    // optional name bytes for accept.
    var recv_buf: [512]u8 = undefined;
    const resp = try streams.recv.readToEnd(&recv_buf, 1_000_000);
    streams.recv.deinit();

    if (resp.len == 0) return error.InvalidResponse;

    switch (resp[0]) {
        0 => {
            const name = resp[1..];
            log.info("Pair accepted with name: '{s}'", .{name});
            p2p.peer.add(core, name, peer.id) catch |err| {
                log.warn("Failed to save peer in db: {t}", .{err});
            };
            return;
        },
        1 => {
            log.err("Pair request rejected", .{});
            return error.Rejected;
        },
        else => {
            log.err("Invalid pair response", .{});
            return error.InvalidResponse;
        },
    }
}
