const std = @import("std");
const Core = @import("../Core.zig");
const iroh = @import("iroh");
const Self = @This();

const log = std.log.scoped(.p2p_protocols);

/// First byte in new bistream that the sender sends to establish the
/// kind of bistream it will be.
pub const ProtocolTag = enum(u8) {
    pair,
    _,
};

pub const Error = error{Protocol};

/// Request pairing with a peer. Blocks until done or error.
///
/// If the peer accepts this will return the name returned by the
/// pair, which the caller is responsible for deallocating.
pub fn requestPair(endpoint: *iroh.Endpoint, peer_endpoint_id: []const u8) ![:0]u8 {
    const public_key: iroh.PublicKey = try .fromHex(peer_endpoint_id);
    defer public_key.deinit();

    const addr: iroh.EndpointAddr = .fromPublicKey(&public_key);
    defer addr.deinit();

    log.info("Trying to connect...", .{});
    var conn = try endpoint.connect(.{ .addr = &addr });
    defer conn.close();
    // const endpoint_id = endpoint.state.online.addr.id.bytes();
    
    log.info("Connected! Creating streams...", .{});
    const streams = try conn.openBiStream();
    // defer streams.deinit();

    const proto_byte: u8 = @intFromEnum(ProtocolTag.pair);
    const pair_bytes = [1]u8{ proto_byte } ++ "Mamma";
    try streams.send.write(pair_bytes, 5000);
    streams.send.finish();

    var recv_buf: [512]u8 = undefined;
    const resp = try streams.recv.readToEnd(&recv_buf, 5000);
    streams.recv.deinit();
    log.info("Got respone: {s}", .{resp});

    // const name = try streams.recv.readToEnd(alloc, .{});
    // log.info("Got name: {s}", .{name});
    // return name;

    return @constCast(@ptrCast("wow"));
}
