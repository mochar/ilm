const std = @import("std");
const Allocator = std.mem.Allocator;
const ilm = @import("../../root.zig");
const p2p = ilm.p2p;
const Peer = p2p.Peer;
const Router = p2p.Router;
const ConnectedPeer = Router.ConnectedPeer;
const crdt = ilm.database.crdt;
const iroh = @import("iroh");

const log = std.log.scoped(.p2p_sync_protocol);

pub const TAG: p2p.protocols.ProtocolTag = .sync;


const RequestAnswer = enum(u8) {
    accept = 0,
    /// Generic reject
    reject = 1,
    /// Unknown peer
    unknown = 2,
    _,
};

pub const SyncError = error{
    Database,
    UnknownPeer,
    NotConnected,
} || Allocator.Error || iroh.EndpointError || std.Io.Cancelable;

pub const SyncAcceptError = error{
    InvalidDbVersion,
} || SyncError;

pub fn accept(
    router: *p2p.Router,
    conn_peer: *ConnectedPeer,
    streams_: iroh.BiStream,
) SyncAcceptError!void {
    const peer_id = conn_peer.id;
    const core = router.getCore();

    var arena_alloc: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    var streams = streams_; // get a nonconst copy
    defer streams.deinit();

    const peer = if (p2p.peer.getById(&router.db, arena, &peer_id) catch return error.Database) |peer|
        peer
    else {
        log.warn("Sync request rejected from unknown peer {x}", .{peer_id.bytes[0..4]});
        try streams.send.write(&.{@intFromEnum(RequestAnswer.unknown)}, 5000);
        return error.UnknownPeer;
    };
    _ = peer;

    // Client is supposed to send the db version and wait for approval.
    // Db version is a u64, which we enforce the size of (8 bytes).
    const db_version = blk: {
        var db_version_bytes: [8]u8 = undefined;
        _ = try streams.recv.readExact(&db_version_bytes, 5000);
        break :blk std.mem.readInt(u64, &db_version_bytes, .little);
    };
    log.info("Sync requested from db version {d}", .{db_version});

    // Send approval.
    try streams.send.write(&.{@intFromEnum(RequestAnswer.accept)}, 5000);

    // We now query the changeset and send it back.
    {
        const type_info = @typeInfo(crdt.Change).@"struct";
        const changeset = crdt.getChanges(
            &router.db,
            peer_id.bytes[0..16],
            db_version,
            arena,
        ) catch |err| {
            log.err("Failed to get changeset: {t}", .{err});
            return error.Database;
        };
        for (changeset) |*change| {
            try streams.send.write(&.{1}, 5000); // indicate not done
            inline for (type_info.fields) |*field| {
                const value = @field(change, field.name);
                switch (field.type) {
                    []const u8 => {
                        const size: u16 = @intCast(value.len);
                        try streams.send.write(std.mem.asBytes(&size), 5000);
                        try streams.send.write(value, 5000);
                    },
                    u64 => {
                        const size: u16 = 8;
                        try streams.send.write(std.mem.asBytes(&size), 5000);
                        const bytes: *const [8]u8 = @ptrCast(@alignCast(&value));
                        try streams.send.write(bytes, 5000);
                    },
                    inline else => unreachable,
                }
            }
        }
        try streams.send.write(&.{0}, 5000); // indicate done
        streams.send.finish();
    }
}

pub const SyncRequestError = error{
    InvalidResponse,
    Rejected,
} || SyncError;

pub fn request(
    router: *p2p.Router,
    conn_peer: *ConnectedPeer,
) SyncRequestError!void {
    const peer_id = conn_peer.id;

    var arena_alloc: std.heap.ArenaAllocator = .init(router.getCore().gpa);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    const peer = if (p2p.peer.getById(&router.db, arena, &peer_id) catch return error.Database) |peer|
        peer
    else {
        log.err("Sync request failed as peer {x} is unknown", .{peer_id.bytes[0..4]});
        return error.UnknownPeer;
    };

    log.info("Requesting sync with peer {x} ({s})", .{ peer.id.bytes[0..4], peer.name });
    router.publishEvent(.{ .sync_start = .{ .conn_peer = conn_peer, .peer = peer }});

    if (requestInner(router, conn_peer, peer, arena)) {
        router.publishEvent(.{ .sync_done = .{ .peer = peer } });
        return;
    } else |err| {
        router.publishEvent(.{ .sync_done = .{ .peer = peer, .err = err } });
        return err;
    }
}

fn requestInner(
    router: *p2p.Router,
    conn_peer: *ConnectedPeer,
    peer: Peer,
    arena: std.mem.Allocator,
) SyncRequestError!void {
    const core = router.getCore();
    const conn = &conn_peer.conn;

    var streams = try conn.openBiStream();

    // Send protocol byte and db version
    {
        const proto_byte: u8 = @intFromEnum(TAG);
        const db_version: u64 = 0;
        const db_version_bytes: *const [8]u8 = @ptrCast(@alignCast(&db_version));
        const sync_bytes = try std.mem.concat(arena, u8, &.{ &.{proto_byte}, db_version_bytes });
        try streams.send.write(sync_bytes, 5000);
    }

    // Wait for approval (0) or rejection (1) byte
    blk: {
        var resp: [1]u8 = undefined;
        _ = try streams.recv.readExact(&resp, 1_000_000);
        const answer: RequestAnswer = @enumFromInt(resp[0]);
        switch (answer) {
            .accept => break :blk,
            .reject => log.warn("Sync rejected for unspecified reason, stopping.", .{}),
            _ => log.warn("Sync rejected for unknown reason, stopping.", .{}),
            .unknown => {
                log.warn("Sync rejected as peer is no longer a friend, stopping.", .{});
                core.deletePeerAndCloseConnection(peer.id) catch {};
            },
        }
        streams.send.finish(); // necessary?
        return error.Rejected;
    }

    // Peer is supposed to send all the crsql changes and end the send stream.
    {
        const type_info = @typeInfo(crdt.Change).@"struct";
        var recv_buf: [4096]u8 = undefined;
        var changes: std.ArrayList(crdt.Change) = .empty;

        while (true) {
            // Each Change is prepended with a 1-byte. A 0-byte means
            // peer is done sending.
            const prefix = try streams.recv.readExact(recv_buf[0..1], 5000);
            if (prefix[0] == 0) break;

            var change: crdt.Change = undefined;
            inline for (type_info.fields) |*field| {
                const size_bytes = try streams.recv.readExact(recv_buf[0..2], 5000);
                const size = std.mem.readInt(u16, size_bytes[0..2], .little);
                const field_bytes = try streams.recv.readExact(recv_buf[0..size], 5000);
                switch (field.type) {
                    []const u8 => @field(change, field.name) = try arena.dupe(u8, field_bytes),
                    u64 => @field(change, field.name) = std.mem.readInt(u64, field_bytes[0..8], .little),
                    inline else => unreachable,
                }
            }
            try changes.append(arena, change);
        }

        crdt.mergeChanges(core, changes.items) catch |err| {
            log.err("Error merging crdt changes: {t}", .{err});
            return error.Database;
        };
        log.info("Written {d} sync changes to the db", .{changes.items.len});
    }

    streams.send.finish();
}
