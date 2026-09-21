const std = @import("std");
const database = @import("database.zig");
const Id = database.Id;
const sqlite = @import("sqlite");

const Core = @This();

gpa: std.mem.Allocator,
io: std.Io,
data_dir: []const u8,
db: sqlite.Db,

pub const Options = struct {
    sqlite_diagnostics: ?*sqlite.Diagnostics = null,
};

pub fn init(gpa: std.mem.Allocator, io: std.Io, data_dir: []const u8, options: Options) !Core {
    const db_path = try std.fs.path.joinZ(gpa, &.{ data_dir, "ilm.db" });
    defer gpa.free(db_path);
    const db = try database.getDb(.{ .path = db_path, .diags = options.sqlite_diagnostics });
    return .{
        .gpa = gpa,
        .io = io,
        .data_dir = gpa.dupe(u8, data_dir) catch @panic("OOM"),
        .db = db,
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
