const std = @import("std");
const Allocator = std.mem.Allocator;
const Core = @import("../Core.zig");
const db = @import("../database.zig");
const iroh = @import("iroh");
const Self = @This();

const log = std.log.scoped(.p2p_peer);

pub const Peer = struct {
    /// Endpoint/public key ID
    pub const Id = [32]u8;

    rowid: i64,
    id: Id,
    name: []const u8,
};

pub fn getAll(core: *Core, alloc: Allocator) ![]Peer {
    var diags: db.Diagnostics = .{};
    var stmt = try core.db.prepareWithDiags(
        "SELECT rowid, id, name FROM peer",
        .{ .diags = &diags },
    );
    defer stmt.deinit();
    return try db.queryAll(Peer, alloc, &stmt, .{});
}

pub fn getById(core: *Core, alloc: Allocator, id: *const Peer.Id) !?Peer {
    var diags: db.Diagnostics = .{};
    const peer = core.db.oneAlloc(
        Peer,
        alloc,
        "SELECT rowid, id, name FROM peer WHERE id = ?",
        .{ .diags = &diags },
        .{id},
    ) catch |err| {
        log.err("SQLite query failed ({t}): {s}", .{ err, diags.message });
        return err;
    };
    return peer;
}

pub fn known(core: *Core, id: *const Peer.Id) !bool {
    var diags: db.Diagnostics = .{};
    const flag = core.db.one(
        bool,
        \\SELECT
        \\    CASE 
        \\        WHEN EXISTS(SELECT NULL FROM peer WHERE id = ?)
        \\        THEN 1
        \\        ELSE 0
        \\    END
    ,
        .{ .diags = &diags },
        .{id},
    ) catch |err| {
        log.err("SQLite query failed ({t}): {s}", .{ err, diags.message });
        return err;
    };
    return flag.?;
}

pub fn add(
    core: *Core,
    name: []const u8,
    id: []const u8
) !void {
    if (id.len == 64) {
        id = (try iroh.PublicKey.fromHex(id)).bytes();
    } else if (id.len != 32) {
        return error.InvalidID;
    }    
    var diags: db.Diagnostics = .{};

    var stmt = core.db.prepareWithDiags(
        "INSERT INTO peer(id, name) VALUES (?, ?)",
        .{ .diags = &diags },
    ) catch |err| {
        log.err("SQLite prepare failed: {s}", .{diags.message});
        return err;
    };
    defer stmt.deinit();

    stmt.exec(
        .{ .diags = &diags },
        .{ .id = id, .name = name },
    ) catch |err| {
        log.err("SQLite exec failed: {s}", .{diags.message});
        return err;
    };
}
