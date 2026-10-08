const std = @import("std");
const Allocator = std.mem.Allocator;
pub const sqlite = @import("sqlite");
pub const Diagnostics = sqlite.Diagnostics;
pub const Db = sqlite.Db;
pub const helpers = @import("database/helpers.zig");
pub const Id = @import("database/Id.zig");
pub const tables = @import("database/tables.zig");
pub const DbWriter = @import("database/DbWriter.zig");
pub const crdt = @import("database/crdt.zig");

const log = std.log.scoped(.database);

const schema = @embedFile("database/schema.sql");

const Options = struct {
    flags: sqlite.Db.OpenFlags = .{ .write = false, .create = false },
    /// Required when flags.create is true
    site_id: ?*const [16]u8 = null,
};

pub fn getDb(path: [:0]const u8, opts: Options) !sqlite.Db {
    if (opts.flags.create and opts.site_id == null) {
        log.err("Must pass site_id when flags.create is true", .{});
        return error.NoSiteId;
    }

    var diags: sqlite.Diagnostics = .{};

    var db = sqlite.Db.init(.{
        .mode = .{ .File = path },
        .open_flags = opts.flags,
        .diags = &diags,
    }) catch |err| {
        log.err("Failed to open database: {t}", .{err});
        return err;
    };
    errdefer db.deinit();

    // TODO I think this only fails with newly generated databases,
    // which then require write permissions to fix, and then can be
    // switched back again to no write. So just a bug, write permission
    // not needed to load in ext.
    // if (opts.flags.write) {
    {
        // Load cr-sqlite extension. Requires write permission.
        var rc = sqlite.c.sqlite3_enable_load_extension(db.db, 1);
        if (rc != sqlite.c.SQLITE_OK) {
            log.err("Failed to enable sqlite extension loading: {d}", .{rc});
            return error.SqliteExtensionLoad;
        }

        rc = sqlite.c.sqlite3_load_extension(db.db, "/home/mochar/src/cr-sqlite/core/dist/crsqlite.so", null, null);
        if (rc != sqlite.c.SQLITE_OK) {
            const e = db.getDetailedError();
            log.err("Failed to load crsqlite extension: {f}", .{e});
            return error.CrsqliteFailed;
        }
    }

    if (opts.flags.create) {
        // Set the crsqlite site id
        db.exec(
            "UPDATE crsql_site_id SET site_id = ? WHERE ordinal = 0",
            .{ .diags = &diags },
            .{sqlite.Blob{ .data = opts.site_id.? }},
        ) catch |err| {
            log.err("Failed to set crsql site id ({t}): {f}", .{ err, diags });
            return err;
        };

        // Execute schema script
        const rc = sqlite.c.sqlite3_exec(db.db, schema.ptr, null, null, null);
        if (rc != sqlite.c.SQLITE_OK) {
            const e = db.getDetailedError();
            log.err("Failed to execute schema: {f}", .{e});
            return error.CrsqliteFailed;
        }
    }

    return db;
}

/// Returns true if still functional
pub fn isValid(db: *sqlite.Db) bool {
    // https://stackoverflow.com/a/21146372
    _ = db.pragma([128:0]u8, .{}, "schema_version", null) catch return false;
    return true;
}
