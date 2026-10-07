const std = @import("std");
const Allocator = std.mem.Allocator;
pub const sqlite = @import("sqlite");
pub const Diagnostics = sqlite.Diagnostics;
pub const Db = sqlite.Db;
pub const helpers = @import("database/helpers.zig");
pub const Id = @import("database/Id.zig");
pub const tables = @import("database/tables.zig");
pub const DbWriter = @import("database/DbWriter.zig");

const log = std.log.scoped(.database);

const schema = @embedFile("database/schema.sql");

pub fn getDb(path: [:0]const u8, flags: sqlite.Db.OpenFlags) !sqlite.Db {
    var diags: sqlite.Diagnostics = .{};

    var db = sqlite.Db.init(.{
        .mode = .{ .File = path },
        .open_flags = flags,
        .diags = &diags,
    }) catch |err| {
        log.err("Failed to open database: {t}", .{err});
        return err;
    };
    errdefer db.deinit();

    // Load cr-sqlite extension
    // {
    //     var rc = sqlite.c.sqlite3_enable_load_extension(db.db, 1);
    //     if (rc != sqlite.c.SQLITE_OK) {
    //         log.err("Failed to enable sqlite extension loading: {d}", .{rc});
    //         return error.SqliteExtensionLoad;
    //     }

    //     var err_msg: [*c]u8 = undefined;
    //     rc = sqlite.c.sqlite3_load_extension(db.db, "/home/mochar/src/cr-sqlite/core/dist/crsqlite.so", "sqlite3_crsqlite_init", &err_msg);
    //     if (rc != sqlite.c.SQLITE_OK) {
    //         defer sqlite.c.sqlite3_free(err_msg);
    //         const msg = std.mem.span(err_msg);
    //         log.err("Failed to load crsqlite extension: {s}", .{msg});
    //         return error.CrsqliteFailed;
    //     }
    // }

    // Execute schema script
    var errmsg: [*c]u8 = null;
    const rc = sqlite.c.sqlite3_exec(db.db, schema.ptr, null, null, &errmsg);

    if (rc == sqlite.c.SQLITE_OK) return db;

    diags.err = db.getDetailedError();
    if (errmsg != null) {
        sqlite.c.sqlite3_free(errmsg);
    }
    return sqlite.errorFromResultCode(rc);
}

/// Returns true if still functional
pub fn isValid(db: *sqlite.Db) bool {
    // https://stackoverflow.com/a/21146372
    _ = db.pragma([128:0]u8, .{}, "schema_version", null) catch return false;
    return true;
}
