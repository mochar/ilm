const std = @import("std");
const Allocator = std.mem.Allocator;
const Core = @import("../Core.zig");
const db = @import("../database.zig");
const iroh = @import("iroh");
const Self = @This();

const log = std.log.scoped(.p2p_peer);

pub const Peer = struct {
    pub const Id = [32]u8;

    id: Id,
    name: []const u8,
};

pub fn getAll(core: *Core, alloc: Allocator) ![]Peer {
    var diags: db.Diagnostics = .{};
    var stmt = try core.db.prepareWithDiags(
        "SELECT id, name FROM peer",
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
        "SELECT id, name FROM peer WHERE id = ?",
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

pub fn add(core: *Core, id: *const [32]u8, name: []const u8) !void {
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
