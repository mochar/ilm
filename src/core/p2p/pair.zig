const std = @import("std");
const Core = @import("../Core.zig");
const iroh = @import("iroh");
const Self = @This();

const log = std.log.scoped(.p2p_pair);

pub const ALPN: iroh.Alpn = .{ .alpn = "/ilm/pair/1" };

// pub const State = union(enum) {
//     not_started,
//     connected: struct {
//         conn: *iroh.Connection,
//         streams: *iroh.BiStream,
//     },
// };

// conn: ?iroh.Connection = null,
// streams: ?iroh.BiStream = null,
// state: State = .not_started,

// pub fn connect(endpoint: *iroh.Endpoint, peer_endpoint_id: []const u8) !void {
// }

/// Request pairing with a peer. Blocks until done or error.
///
/// If the peer accepts this will return the name returned by the
/// pair, which the caller is responsible for deallocating.
pub fn request(endpoint: *iroh.Endpoint, peer_endpoint_id: []const u8, alloc: std.mem.Allocator) ![:0]u8 {
    if (endpoint.state != .online) return error.NotOnline;

    const public_key: iroh.PublicKey = try .fromHex(peer_endpoint_id);
    defer public_key.deinit();

    const addr: iroh.EndpointAddr = .fromPublicKey(&public_key);
    defer addr.deinit();

    log.info("Trying to connect...", .{});
    var conn = try endpoint.connect(&addr, &ALPN);
    defer conn.close() catch {};
    
    log.info("Connected! Creating streams...", .{});
    const streams = try conn.createBiStream();
    defer streams.send.finish();
    defer streams.recv.deinit();

    const endpoint_id = endpoint.state.online.addr.id.bytes();
    try streams.send.write(endpoint_id, .{ .timeout_ms = 5000 });

    const name = try streams.recv.readToEnd(alloc, .{});
    log.info("Got name: {s}", .{name});
    return name;
}
