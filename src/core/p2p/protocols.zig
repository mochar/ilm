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
const Core = @import("../Core.zig");
const iroh = @import("iroh");
const Peer = @import("peer.zig").Peer;
const Self = @This();

const log = std.log.scoped(.p2p_protocols);

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
    pub const PairRequest = struct {
        pub const Response = enum { accept, reject };
        
        peer_id: Peer.Id,
        name: []const u8,
        response: Response = .reject,
        /// Used to suspend peer stream thread and resume it when the
        /// user accepts or rejects this pair.
        signal: std.Io.Event = .unset,

        pub fn accept(self: *PairRequest, io: std.Io) void {
            self.response = .accept;
            self.signal.set(io);
        }

        pub fn reject(self: *PairRequest, io: std.Io) void {
            self.response = .reject;
            self.signal.set(io);
        }
    };

    pub const Session = struct {
        // streams: iroh.BiStream,
        response: PairRequest,
    };
};

pub const SyncProtocol = struct {};

/// Request pairing with a peer. Blocks until done or error.
///
/// If the peer accepts this will return the name returned by the
/// pair, which the caller is responsible for deallocating.
pub fn requestPair(endpoint: *iroh.Endpoint, peer_endpoint_id: []const u8) ![:0]u8 {
    log.info("Trying to connect...", .{});
    var conn = try endpoint.connect(.{ .id = peer_endpoint_id });
    defer conn.close();
    // const endpoint_id = endpoint.state.online.addr.id.bytes();

    log.info("Connected! Creating streams...", .{});
    var streams = try conn.openBiStream();

    const proto_byte: u8 = @intFromEnum(ProtocolTag.pair);
    const pair_bytes = [1]u8{proto_byte} ++ "Mamma";
    try streams.send.write(pair_bytes, 5000);
    streams.send.finish();

    var recv_buf: [512]u8 = undefined;
    // const resp = try streams.recv.readToEnd(&recv_buf, 30_000);
    const resp = try streams.recv.readToEnd(&recv_buf, 1_000_000);
    streams.recv.deinit();

    if (resp.len == 0) return error.InvalidResponse;

    switch (resp[0]) {
        0 => {
            const name = resp[1..];
            log.info("Pair accepted with name: '{s}'", .{name});
        },
        1 => log.info("Pair rejected", .{}),
        else => log.info("Invalid pair response", .{}),
    }

    return @ptrCast(@constCast("wow"));
}
