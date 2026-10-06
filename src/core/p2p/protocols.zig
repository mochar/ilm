//! Wire protocols for the different operations that can be done when
//! a new bistream has been established.
//!
//! Connections must always communicate through bistreams, which
//! consists of a sender and a receiver stream.
//!
//! When established, the client always sends the first message, the
//! first byte of which should be the ProtocolTag (the client is free
//! to send more data in this initial message). If the tag is not
//! valid, the server returns a '1' byte and closes the bistreams. If
//! the server accepts this invite, it returns a '0' byte, and any
//! further communication is then protocol specific. Otherwise, it
//! returns a protocol specific non-zero rejection code.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Core = @import("../Core.zig");
const iroh = @import("iroh");
const p2p = @import("../p2p.zig");
const Peer = p2p.Peer;
const database = @import("../database/database.zig");
const Self = @This();

/// First byte in new bistream that the sender sends to establish the
/// kind of bistream it will be.
pub const ProtocolTag = enum(u8) {
    pair,
    // sync,
    _,
};

pub const ProtocolSession = struct {
    streams: iroh.BiStream,
    protocol: Protocol,
};

pub const Protocol = union(ProtocolTag) {
    pair: PairProtocol,
    // sync: SyncProtocol,
};

pub const PairProtocol = struct {
    const log = std.log.scoped(.p2p_pair_protocol);

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

    pub const PairError = error{
        Database,
    } || Allocator.Error || iroh.EndpointError || std.Io.Cancelable;

    pub const PairAcceptError = error{NotConnected} || PairError;

    /// Called from the server side to handle a pair request from a client.
    ///
    /// This is called after only the protocol tag has been consumed
    /// from the recv stream. This transfers ownership of BiStream.
    pub fn accept(
        router: *p2p.Router,
        streams_: iroh.BiStream,
        peer_id: Peer.Id,
    ) PairAcceptError!void {
        const core = router.getCore();
        const io = core.io;

        var arena_alloc: std.heap.ArenaAllocator = .init(core.gpa);
        defer arena_alloc.deinit();
        const arena = arena_alloc.allocator();

        var streams = streams_; // get a nonconst copy
        defer streams.deinit();

        var peer = router.connections.peers.getPtr(peer_id) orelse return error.NotConnected;
        var recv_buf: [512]u8 = undefined;

        var accepted: bool = undefined;
        var name: []const u8 = undefined;

        const stored_peer = p2p.peer.getById(&router.db, arena, &peer_id) catch return error.Database;

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
                .peer_id = peer_id,
                .name = name,
            };
            peer.pair_request = &pair_req;
            defer peer.pair_request = null;
            router.publishEvent(.{ .pair_request = &pair_req });

            // Pause thread, wait for user feedback, or thread cancel.
            try pair_req.signal.wait(io); // Cancelable

            accepted = pair_req.response == .accept;
        }

        // Accept: 1-byte + name, end stream
        // Reject: 0-byte, end stream
        const response: []const u8 = if (accepted)
            try std.mem.concat(arena, u8, &.{ &.{0}, router.name })
        else
            &.{1};
        streams.send.write(response, 5000) catch |err| {
            log.err("Failed to write back to pair: {t}", .{err});
            // continue if we err
        };
        streams.send.finish();

        if (accepted and stored_peer == null) {
            p2p.peer.add(core, name, peer_id) catch return error.Database;
        }
    }

    pub const PairRequestError = error{
        KnownPeer,
        InvalidResponse,
        Rejected,
    } || PairError;

    /// Request pairing with a peer. Blocks until done or error.
    ///
    /// If the peer accepts this will return the name returned by the
    /// pair, which the caller is responsible for deallocating.
    pub fn request(
        router: *p2p.Router,
        peer_id: Peer.Id,
        recv_buf: []u8,
    ) PairRequestError![]const u8 {
        if (requestInner(router, peer_id, recv_buf)) |name| {
            router.publishEvent(.{ .pair_established = peer_id });
            return name;
        } else |err| {
            router.publishEvent(.{ .pair_failed = .{ .peer_id = peer_id, .err = err } });
            return err;
        }
    }

    fn requestInner(
        router: *p2p.Router,
        peer_id: Peer.Id,
        recv_buf: []u8,
    ) PairRequestError![]const u8 {
        if (p2p.peer.exists(&router.db, &peer_id) catch false) {
            return error.KnownPeer;
        }

        const core = router.getCore();

        var arena_alloc: std.heap.ArenaAllocator = .init(core.gpa);
        defer arena_alloc.deinit();
        const arena = arena_alloc.allocator();

        log.info("Requesting pair with {x}", .{peer_id.bytes});

        // First establish connection in the router.
        // Connection is always closed on error, so we assume this peer is
        // not already connected to the router. On success, the connection
        // is passed to the router to keep around.
        // if (router.connections.peers.contains(peer_id)) {}
        var conn = try router.endpoint.connect(.{ .id = &peer_id.bytes });
        errdefer conn.close();
        var streams = try conn.openBiStream();

        const proto_byte: u8 = @intFromEnum(ProtocolTag.pair);
        const pair_bytes = try std.mem.concat(arena, u8, &.{ &.{proto_byte}, router.name });
        try streams.send.write(pair_bytes, 5000);
        streams.send.finish();

        // Expect to receive a 1-byte for a reject, or a 0-byte plus
        // optional name bytes for accept.
        const resp = try streams.recv.readToEnd(recv_buf, 1_000_000);
        streams.recv.deinit();

        if (resp.len == 0) return error.InvalidResponse;

        switch (resp[0]) {
            0 => {
                const name = resp[1..];
                log.info("Pair accepted with name: '{s}'", .{name});
                router.handleConn(conn, true) catch {}; // closes conn on error
                p2p.peer.add(core, name, peer_id) catch |err| {
                    log.warn("Failed to save peer in db: {t}", .{err});
                };
                return name;
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
};

pub const SyncProtocol = struct {};
