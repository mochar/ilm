const std = @import("std");
const database = @import("database.zig");
const Id = database.Id;
const P2p = @import("P2p.zig");
const sqlite = @import("sqlite");

const Core = @This();

gpa: std.mem.Allocator,
io: std.Io,
data_dir: []const u8,
db: sqlite.Db,
p2p: P2p,

pub const Options = struct {
    sqlite_diagnostics: ?*sqlite.Diagnostics = null,
};

pub fn init(gpa: std.mem.Allocator, io: std.Io, data_dir: []const u8, options: Options) !Core {
    const db_path = try std.fs.path.joinZ(gpa, &.{ data_dir, "ilm.db" });
    defer gpa.free(db_path);
    var db = try database.getDb(.{ .path = db_path, .diags = options.sqlite_diagnostics });
    errdefer db.deinit();

    const p2p: P2p = try .init(gpa);

    return .{
        .gpa = gpa,
        .io = io,
        .data_dir = gpa.dupe(u8, data_dir) catch @panic("OOM"),
        .db = db,
        .p2p = p2p,
    };
}

pub fn deinit(core: *Core) void {
    core.db.deinit();
    core.gpa.free(core.data_dir);
}

/// Returns true if still functional
pub fn isValid(core: *Core) bool {
    return database.isValid(&core.db);
}

pub fn setupP2p(core: *Core) !void {
    core.p2p.spawnListenThread() catch |err| {
        std.log.err("Failed to spawn thread: {t}", .{err});
        return err;
    };
}

pub fn newId(core: *Core) Id {
    return Id.new(core.io);
}

pub fn exec(core: *Core, comptime query: []const u8, args: anytype) !void {
    var diags: sqlite.Diagnostics = .{};

    var stmt = core.db.prepareWithDiags(query, .{ .diags = &diags }) catch |err| {
        std.log.err("DB prepare error: {s} \nQuery: {s}", .{ diags.message, query });
        return err;
    };
    defer stmt.deinit();

    stmt.exec(.{ .diags = &diags }, args) catch |err| {
        std.log.err("DB exec error: {s} \nQuery: {s}", .{ diags.message, query });
        return err;
    };
}
