const std = @import("std");
const zqlite = @import("zqlite");
const Self = @This();

const log = std.log.scoped(.db);

const schema = @embedFile("schema.sql");

conn: zqlite.Conn,

const Options = struct {
    write: bool = false,
    create: bool = false,
};

pub fn init(path: [:0]const u8, opts: Options) !Self {
    var flags: c_int = zqlite.OpenFlags.EXResCode;
    flags |= if (opts.write) zqlite.OpenFlags.ReadWrite else zqlite.OpenFlags.ReadOnly;
    if (opts.create) flags |= zqlite.OpenFlags.Create;

    const conn = zqlite.Conn.init(path, flags) catch |err| {
        log.err("Failed to open database: {t}", .{err});
        return err;
    };
    errdefer conn.close();

    // Execute schema script
    var errmsg: [*c]u8 = null;
    const rc = zqlite.c.sqlite3_exec(conn.conn, schema.ptr, null, null, &errmsg);
    if (rc != zqlite.c.SQLITE_OK) {
        if (errmsg != null) {
            log.err("Schema execution failed: {s}", .{errmsg});
            zqlite.c.sqlite3_free(errmsg);
        } else {
            log.err("Schema execution failed", .{});
        }
        return error.Schema;
    }

    return .{ .conn = conn };
}

pub fn deinit(self: *Self) void {
    self.conn.close();
}

// pub fn all(self: *const Self, T: anytype) void {
//     self.conn.rows
// }
