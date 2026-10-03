const std = @import("std");
const Allocator = std.mem.Allocator;
const Core = @import("../Core.zig");
const database = @import("../database/database.zig");
const Diagnostics = database.Diagnostics;
const Db = database.Db;
const iroh = @import("iroh");
const Self = @This();

const log = std.log.scoped(.p2p_peer);

pub const Peer = struct {
    /// Endpoint/public key ID
    pub const Id = [32]u8;

    id: Id,
    name: []const u8,
};

pub fn getAll(db: *Db, alloc: Allocator) ![]Peer {
    var diags: Diagnostics = .{};
    var stmt = try db.prepareWithDiags(
        "SELECT id, name FROM peer",
        .{ .diags = &diags },
    );
    defer stmt.deinit();
    return try database.helpers.queryAll(Peer, alloc, &stmt, .{});
}

pub fn getById(db: *Db, alloc: Allocator, id: *const Peer.Id) !?Peer {
    var diags: Diagnostics = .{};
    const peer = db.oneAlloc(
        Peer,
        alloc,
        "SELECT id, name FROM peer WHERE id = ?",
        .{ .diags = &diags },
        .{id},
    ) catch |err| {
        log.err("SQLite query failed ({t}): {s}", .{ err, diags.message });
        return err;
    };
    return peer;
}

pub fn exists(db: *Db, id: *const Peer.Id) !bool {
    var diags: Diagnostics = .{};
    const flag = db.one(
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

/// Inserts blindly wihout checking if ID is valid.
pub fn add(core: *Core, name: []const u8, id: Peer.Id) !void {
    const res = try core.db_writer.runCommand(.{ .add_peer = .{
        .id = id,
        .name = name,
    } }, .{});
    return if (res.write) |_| {} else |err| return err;
}

/// Inserts blindly wihout checking if ID is valid.
pub fn addImpl(db: *Db, name: []const u8, id: []const u8) !void {
    var diags: Diagnostics = .{};

    var stmt = db.prepareWithDiags(
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

pub fn delete(core: *Core, id: Peer.Id) !void {
    const res = try core.db_writer.runCommand(.{ .delete_peer = .{ .id = id } }, .{});
    return if (res.write) |_| {} else |err| return err;
}

pub fn deleteImpl(db: *Db, id: Peer.Id) !void {
    var diags: Diagnostics = .{};
    db.exec("DELETE FROM peer WHERE id = ?", .{ .diags = &diags }, .{id}) catch |err| {
        log.err("Failed to delete peer: {s}", .{diags.message});
        return err;
    };
}
