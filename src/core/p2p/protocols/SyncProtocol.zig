const Self = @This();

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

const State = union(enum) {
    dormant,
    sending,
    retrieving,
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
    return @fieldParentPtr("sync", self);
}

/// Byte that represents response to a sync request.
const RequestAnswer = enum(u8) {
    accept = 0,
    /// Generic reject
    reject = 1,
    /// Unknown peer
    unknown = 2,
    _,
};

pub const SyncBaseError = error{
    Busy,
    Database,
    UnknownPeer,
    NotConnected,
} || Allocator.Error || iroh.EndpointError || std.Io.Cancelable;

pub const SyncAcceptError = error{
    InvalidDbVersion,
} || SyncBaseError;

pub const SyncRequestError = error{
    InvalidResponse,
    Rejected,
} || SyncBaseError;

pub const SyncTwowayError = SyncAcceptError || SyncRequestError;

pub fn accept(self: *Self, streams_: iroh.BiStream) SyncTwowayError!void {
    if (self.state != .dormant) return error.Busy;
    self.state = .retrieving;
    defer self.state = .dormant;

    const peer = self.connectedPeer();
    defer _ = self.arena.reset(.free_all);

    var streams = streams_; // get a nonconst copy
    defer streams.deinit();

    if (!(p2p.peer.exists(&self.router.db, &peer.id) catch return error.Database)) {
        log.warn("Sync request rejected from unknown peer {x}", .{peer.id.bytes[0..4]});
        try streams.send.write(&.{@intFromEnum(RequestAnswer.unknown)}, 5000);
        return error.UnknownPeer;
    }

    // Send approval.
    try streams.send.write(&.{@intFromEnum(RequestAnswer.accept)}, 5000);

    try self.doSend(&streams);
    try self.doRetrieve(&streams);

    streams.send.finish();
}

pub fn request(self: *Self) SyncTwowayError!void {
    if (self.state != .dormant) return error.Busy;
    self.state = .sending;
    defer self.state = .dormant;

    const peer_id = self.connectedPeer().id;

    const peer = (p2p.peer.getById(&self.router.db, self.arena.allocator(), &peer_id) catch return error.Database) orelse {
        log.err("Sync request failed as peer {x} is unknown", .{peer_id.bytes[0..4]});
        return error.UnknownPeer;
    };

    log.info("Requesting sync with peer {x} ({s})", .{ peer.id.bytes[0..4], peer.name });
    self.router.publishEvent(.{ .sync_start = .{ .conn_peer = self.connectedPeer(), .peer = peer } });

    if (self.requestInner()) {
        self.router.publishEvent(.{ .sync_done = .{ .peer = peer } });
        return;
    } else |err| {
        self.router.publishEvent(.{ .sync_done = .{ .peer = peer, .err = err } });
        return err;
    }
}

fn requestInner(self: *Self) SyncTwowayError!void {
    defer _ = self.arena.reset(.free_all);

    const peer = self.connectedPeer();
    var streams = try peer.conn.openBiStream();

    // Send protocol byte
    const proto_byte: u8 = @intFromEnum(TAG);
    try streams.send.write(&.{proto_byte}, 5000);

    // Wait for approval or rejection
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
                self.router.getCore().deletePeerAndCloseConnection(peer.id) catch {};
            },
        }
        streams.send.finish(); // necessary?
        return error.Rejected;
    }

    try self.doRetrieve(&streams);
    try self.doSend(&streams);

    streams.send.finish();
}

/// Called when sending changes to a peer.
fn doSend(self: *Self, streams: *iroh.BiStream) SyncAcceptError!void {
    const arena = self.arena.allocator();

    // Client is supposed to send site id and their latest db versions.
    var peer_db_versions: std.AutoHashMap([16]u8, u64) = .init(arena);
    defer peer_db_versions.deinit();

    {
        // First sends a u32 indicating how many.
        const num_sites = num: {
            var bytes: [4]u8 = undefined;
            _ = try streams.recv.readExact(&bytes, 5000);
            break :num std.mem.readInt(u32, &bytes, .little);
        };

        for (0..num_sites) |_| {
            // Each entry is [16]u8 site_id and u64 db version.
            var site_id: [16]u8 = undefined;
            _ = try streams.recv.readExact(&site_id, 5000);

            var db_version_bytes: [8]u8 = undefined;
            _ = try streams.recv.readExact(&db_version_bytes, 5000);
            const db_version = std.mem.readInt(u64, &db_version_bytes, .little);

            try peer_db_versions.put(site_id, db_version);
        }
    }

    const db_versions = crdt.getSiteDbVersions(&self.router.db, arena) catch return error.Database;
    for (db_versions) |ours| {
        const by_site_id = ours.site_id;
        const since_db_version = peer_db_versions.get(by_site_id) orelse 0;
        if (ours.db_version <= since_db_version) continue;

        // We now query the changeset and send it back.
        const type_info = @typeInfo(crdt.Change).@"struct";
        const changeset = crdt.getChanges(
            &self.router.db,
            &by_site_id,
            since_db_version,
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
    }
    try streams.send.write(&.{0}, 5000); // indicate done
}

/// Called when requesting changes from a peer.
fn doRetrieve(self: *Self, streams: *iroh.BiStream) SyncRequestError!void {
    const core = self.router.getCore();
    const arena = self.arena.allocator();

    // Send site id and db versions of all known peers.
    {
        const db_versions = crdt.getSiteDbVersions(&self.router.db, arena) catch return error.Database;

        const num: u32 = @intCast(db_versions.len);
        const num_bytes: *const [4]u8 = @ptrCast(@alignCast(&num));
        try streams.send.write(num_bytes, 5000);

        for (db_versions) |*v| {
            try streams.send.write(&v.site_id, 5000);

            const version_bytes: *const [8]u8 = @ptrCast(@alignCast(&v.db_version));
            try streams.send.write(version_bytes, 5000);
        }
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
}
