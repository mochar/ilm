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
const iroh = @import("iroh");
const ilm = @import("../root.zig");
const Peer = ilm.p2p.Peer;
const Router = ilm.p2p.Router;
const ConnectedPeer = Router.ConnectedPeer;
pub const PairProtocol = @import("protocols/PairProtocol.zig");
pub const SyncProtocol = @import("protocols/SyncProtocol.zig");

const log = std.log.scoped(.p2p_protocols);

/// First byte in new bistream that the sender sends to establish the
/// kind of bistream it will be.
pub const ProtocolTag = enum(u8) {
    pair,
    sync,
    _,
};

pub const Protocol = union(ProtocolTag) {
    pair: PairProtocol,
    sync: SyncProtocol,
};

pub const RequestHandleError = PairProtocol.PairAcceptError || SyncProtocol.SyncAcceptError;

pub const AcceptError = PairProtocol.PairAcceptError || SyncProtocol.SyncAcceptError;

/// Handle a bistream from a peer by establish the protocol and calling the corresponding handler.
pub fn accept(router: *Router, conn_peer: *ConnectedPeer, streams_: iroh.BiStream) AcceptError!void {
    const peer_id = conn_peer.id;
    
    defer router.publishEvent(.{ .stream_closed = peer_id });

    var streams = streams_; // get a nonconst copy

    // All bistreams start with client sending the protocol tag.
    // All we do here is check this tag, and call the associated protocol
    // function to do the actual work.
    var protocol_buf: [1]u8 = undefined;
    _ = streams.recv.readExact(&protocol_buf, 5000) catch |err| {
        log.err("Failed to read protocol tag: {t}", .{err});
        streams.deinit();
        return err;
    };
    const protocol_tag = protocol_buf[0];
    const protocol: ProtocolTag = @enumFromInt(protocol_tag);

    switch (protocol) {
        .pair => {
            log.info("Client {x} requested pair", .{peer_id.bytes[0..4]});
            PairProtocol.accept(router, conn_peer, streams) catch |err| {
                log.err("Pair request failed: {t}", .{err});
                return err;
            };
        },
        .sync => {
            log.info("Client {x} requested sync", .{peer_id.bytes[0..4]});
            conn_peer.sync.accept(streams) catch |err| {
                log.err("Sync request failed: {t}", .{err});
                return err;
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
