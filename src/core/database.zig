const std = @import("std");
const sqlite = @import("sqlite");
const uuid = @import("uuid");

const schema = @embedFile("schema.sql");

pub const DatabaseOptions = struct {
    path: [:0]const u8,
    diags: ?*sqlite.Diagnostics = null,
};

pub fn getDb(options: DatabaseOptions) !sqlite.Db {
    var db = try sqlite.Db.init(.{
        .mode = .{ .File = options.path },
        .open_flags = .{
            .write = true,
            .create = true,
        },
        .threading_mode = .MultiThread,
    });
    errdefer db.deinit();

    // Execute schema script
    var errmsg: [*c]u8 = null;
    const rc = sqlite.c.sqlite3_exec(db.db, schema.ptr, null, null, &errmsg);

    if (rc == sqlite.c.SQLITE_OK) return db;
    
    if (options.diags) |diags| {
        diags.err = db.getDetailedError();
    }
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

/// A wrapper around a u128 UUID. All rows use this ID type.
pub const Id = struct {
    uuid: u128,

    pub const IntT = u128;
    pub const StrT = [36]u8;

    pub fn new(io: std.Io) Id {
        return .{ .uuid = uuid.v7.new(io) };
    }

    /// Parse a 36-character UUID string
    pub fn parse(s: []const u8) !Id {
        return .{ .uuid = try uuid.urn.deserialize(s) };
    }

    pub fn serialize(self: Id) StrT {
        return uuid.urn.serialize(self.uuid);
    }

    // Emacs helpers to convert to and from string repr.
    pub fn toEmacsRepr(self: Id) StrT {
        return self.serialize();
    }
    
    pub fn fromEmacsRepr(id_str: []const u8) !Id {
        return Id.parse(id_str);
    }

    // Sqlite helpers to convert to and from Blob.
    pub const BaseType = sqlite.Blob;

    pub fn asBlob(self: *const Id) sqlite.Blob {
        // Must take in a pointer, otherwise &self.uuid points to this functions
        // stack frame
        return sqlite.Blob{ .data = std.mem.asBytes(&self.uuid) };
    }

    pub fn bindField(self: Id, allocator: std.mem.Allocator) !BaseType {
        // Since self is passed by value and sqlite.Blob only holds a reference,
        // need to allocate on heap. For this reason, prefer to do it manually:
        //   try stmt.exec(.{ .diags = diags }, .{ .id = id.asBlob(), .name = name });
        const bytes = try allocator.dupe(u8, std.mem.asBytes(&self.uuid));
        return .{ .data = bytes };
    }

    pub fn readField(_: std.mem.Allocator, blob: BaseType) !Id {
        const uuid_int = std.mem.bytesAsValue(u128, blob.data);
        return .{ .uuid = uuid_int.* };
    }
};
