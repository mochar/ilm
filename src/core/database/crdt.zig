const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const ilm = @import("../root.zig");
const Core = ilm.Core;
const database = ilm.database;
const Db = database.Db;
const Diagnostics = database.Diagnostics;

const log = std.log.scoped(.db_crdt);

pub const SiteId = [16]u8;

/// In Fly.io fork, changes retain the site_id and db_version of the original device that
/// authored them. If Device B sends a change authored by Device C, it arrives with Device C's
/// ID and C's clock version. In upstream, everything merged from a peer got stamped with your
/// own local database's version clock.
///
/// Therefore, when Device A wants to sync from Device B, Device A must tell Device B exactly
/// where it left off with every device it knows about.
pub const SiteDbVersion = struct {
    site_id: SiteId,
    db_version: u64,
};

pub fn getSiteDbVersions(db: *Db, arena: Allocator) ![]SiteDbVersion {
    var diags: Diagnostics = .{};

    var stmt = db.prepareWithDiags(
        \\SELECT site_id, db_version
        \\FROM crsql_db_versions
    ,
        .{ .diags = &diags },
    ) catch |err| {
        log.err("Failed prepare stmt: ({t}) {f}", .{ err, diags });
        return err;
    };
    defer stmt.deinit();

    var iter = try stmt.iteratorAlloc(SiteDbVersion, arena, .{});
    var rows: std.ArrayList(SiteDbVersion) = .empty;
    defer rows.deinit(arena);
    while (try iter.nextAlloc(arena, .{ .diags = &diags })) |row| {
        try rows.append(arena, row);
    }
    return try rows.toOwnedSlice(arena);
}

/// See changes-vtab.c
pub const Change = struct {
    /// The name of the table the patch is from.
    /// TEXT NOT NULL
    table: []const u8,
    /// The primary key(s) that identify the row to be patched. If the
    /// table has many columns that comprise the primary key then
    /// the values are quote concatenated in pk order.
    /// BLOB NOT NULL
    pk: []const u8,
    /// TEXT NOT NULL
    cid: []const u8,
    /// The values to patch. quote concatenated in cid order.
    /// ANY
    val: []const u8,
    /// The version of the changed column.
    /// INTEGER NOT NULL
    col_version: u64,
    /// The min version of the patch. Used for filtering and for sites
    /// to update their "last seen" version from other sites.
    /// INTEGER NOT NULL
    db_version: u64,
    /// The site_id that is responsible for the update. If this is 0
    /// then the update was made locally.
    /// BLOB NOT NULL
    site_id: []const u8,
    /// INTEGER NOT NULL
    cl: u64,
    /// INTEGER NOT NULL
    seq: u64,
    /// TEXT NOT NULL
    ts: []const u8,
};

/// The site id parameter is used to prevent a site from fetching its own
/// changes that were patched into the remote.
///
/// The version parameter is used to get changes after a specific version.
/// Sites should keep track of the latest version they've received from other
/// sites and use that number as a cursor to fetch future changes.
pub fn getChanges(
    db: *Db,
    by_site_id: []const u8,
    since_db_version: u64,
    arena: Allocator,
) ![]Change {
    var diags: Diagnostics = .{};

    var stmt = db.prepareWithDiags(
        \\SELECT "table", "pk", "cid", "val", "col_version", "db_version", "site_id", "cl", "seq", "ts"
        \\FROM crsql_changes
        \\WHERE site_id IS ? AND db_version > ?
    ,
        .{ .diags = &diags },
    ) catch |err| {
        log.err("Failed prepare changeset stmt: ({t}) {f}", .{ err, diags });
        return err;
    };
    defer stmt.deinit();

    var iter = try stmt.iteratorAlloc(Change, arena, .{ sqlite.Blob{ .data = by_site_id }, since_db_version });
    var rows: std.ArrayList(Change) = .empty;
    defer rows.deinit(arena);
    while (try iter.nextAlloc(arena, .{ .diags = &diags })) |row| {
        try rows.append(arena, row);
    }
    return try rows.toOwnedSlice(arena);
}

pub fn mergeChanges(core: *Core, changes: []Change) !void {
    const res = try core.db_writer.runCommand(
        .{ .apply_changes = .{ .changes = changes } },
        .{ .arena = .init(core.gpa) },
    );
    return if (res.write) |_| {} else |err| return err;
}

pub fn mergeChangesImpl(db: *Db, changes: []Change) !void {
    var diags: Diagnostics = .{};

    var stmt = db.prepareWithDiags(
        \\INSERT INTO crsql_changes
        \\("table", "pk", "cid", "val", "col_version", "db_version", "site_id", "cl", "seq", "ts")
        \\VALUES
        \\(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ,
        .{ .diags = &diags },
    ) catch |err| {
        log.err("Failed prepare changeset stmt: ({t}) {f}", .{ err, diags });
        return err;
    };
    defer stmt.deinit();

    for (changes) |*change| {
        stmt.reset();
        stmt.exec(
            .{ .diags = &diags },
            .{ change.table, change.pk, change.cid, change.val, change.col_version, change.db_version, change.site_id, change.cl, change.seq, change.ts },
        ) catch |err| {
            log.err("SQlite exec failed: ({t}) {f}", .{ err, diags });
            return err;
        };
    }
}
