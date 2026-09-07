const std = @import("std");

const sqlite = @import("sqlite");
const uuid = @import("uuid");
pub const Uuid = uuid.Uuid; // Alias for u128
pub const UuidStr = uuid.urn.Urn; // Alias for [36]u8

const Core = @This();

const schema = @embedFile("schema.sql");

allocator: std.mem.Allocator,
io: std.Io,
db: sqlite.Db,

pub const Options = struct {
    data_dir: []const u8,
    sqlite_diagnostics: ?*sqlite.Diagnostics = null,
};

pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !*Core {
    const db_path = try std.fs.path.joinZ(allocator, &.{ options.data_dir, "ilm.db" });
    defer allocator.free(db_path);

    var db = try sqlite.Db.init(.{
        .mode = .{ .File = db_path },
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
    if (rc != sqlite.c.SQLITE_OK) {
        if (options.sqlite_diagnostics) |diags| {
            diags.err = db.getDetailedError();
        }
        if (errmsg != null) {
            sqlite.c.sqlite3_free(errmsg);
        }
        return sqlite.errorFromResultCode(rc);
    }

    // Create instance and return
    const core = try allocator.create(Core);
    core.* = .{
        .allocator = allocator,
        .io = io,
        .db = db,
    };
    return core;
}

pub fn deinit(core: *Core) void {
    core.db.deinit();
    core.allocator.destroy(core);
}

/// Returns true if still functional
pub fn isValid(core: *Core) bool {
    // https://stackoverflow.com/a/21146372
    _ = core.db.pragma([128:0]u8, .{}, "schema_version", null) catch {
        return false;
    };
    return true;
}

// ** Id

pub const IdStr = [36]u8;
pub const Id = struct {
    uuid: Uuid,

    pub fn new(io: std.Io) Id {
        return .{ .uuid = uuid.v7.new(io) };
    }

    /// Parse a 36-character UUID string
    pub fn parse(s: []const u8) !Id {
        return .{ .uuid = try uuid.urn.deserialize(s) };
    }

    pub fn serialize(self: Id) IdStr {
        return uuid.urn.serialize(self.uuid);
    }

    // Emacs
    pub fn toEmacsRepr(self: Id) IdStr {
        return self.serialize();
    }
    
    pub fn fromEmacsRepr(id_str: []const u8) !Id {
        return Id.parse(id_str);
    }

    // Sqlite
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

pub fn newId(core: *Core) Id {
    return Id.new(core.io);
}

// ** Concept

pub const Concept = struct {
    id: Id,
    name: []const u8,
};

pub fn addConcept(core: *Core, name: []const u8, parent_ids: []const Id, diags: *sqlite.Diagnostics) !Id {
    var savepoint = try core.db.savepoint("addconcept");
    defer savepoint.rollback();
    const id = core.newId();
    const id_blob = id.asBlob();

    {
        var stmt = try core.db.prepareWithDiags("INSERT INTO concept(id, name) VALUES (?, ?)", .{ .diags = diags });
        defer {
            _ = sqlite.c.sqlite3_reset(stmt.dynamic_stmt.stmt);
            stmt.deinit();
        }
        try stmt.exec(.{ .diags = diags }, .{ .id = id_blob, .name = name });
    }

    {
        var stmt = try core.db.prepareWithDiags("INSERT INTO concept_rel(parent_id, child_id) VALUES (?, ?)", .{ .diags = diags });
        defer {
            _ = sqlite.c.sqlite3_reset(stmt.dynamic_stmt.stmt);
            stmt.deinit();
        }
        for (parent_ids) |*parent_id| {
            stmt.reset();
            try stmt.exec(.{ .diags = diags }, .{ .parent_id = parent_id.asBlob(), .child_id = id_blob });
        }
    }

    savepoint.commit();

    return id;
}

pub fn addConceptParent(core: *Core, child_id: Id, parent_id: Id, diags: *sqlite.Diagnostics) !void {
    var stmt = try core.db.prepareWithDiags("INSERT OR IGNORE INTO concept_rel(parent_id, child_id) VALUES (?, ?)", .{ .diags = diags });
    defer {
        _ = sqlite.c.sqlite3_reset(stmt.dynamic_stmt.stmt);
        stmt.deinit();
    }
    try stmt.exec(.{ .diags = diags }, .{ .parent_id = parent_id.asBlob(), .child_id = child_id.asBlob() });
}

pub fn removeConceptParent(core: *Core, child_id: Id, parent_id: Id, diags: *sqlite.Diagnostics) !void {
    var stmt = try core.db.prepareWithDiags("DELETE FROM concept_rel WHERE parent_id = ? AND child_id = ?", .{ .diags = diags });
    defer {
        _ = sqlite.c.sqlite3_reset(stmt.dynamic_stmt.stmt);
        stmt.deinit();
    }
    try stmt.exec(.{ .diags = diags }, .{ .parent_id = parent_id.asBlob(), .child_id = child_id.asBlob() });
}

pub fn getAllConcepts(core: *Core, allocator: std.mem.Allocator, diags: *sqlite.Diagnostics) ![]Concept {
    var stmt = try core.db.prepareWithDiags("SELECT id, name FROM concept", .{ .diags = diags });
    defer stmt.deinit();
    const concepts = try stmt.all(Concept, allocator, .{
        .diags = diags,
    }, .{});
    return concepts;
}

pub fn getConceptsById(core: *Core, allocator: std.mem.Allocator, ids: []const Id, diags: *sqlite.Diagnostics) ![]Concept {
    if (ids.len == 0) return &.{};

    // Build the query
    var query_builder: std.ArrayList(u8) = .empty;
    defer query_builder.deinit(core.allocator);

    try query_builder.appendSlice(core.allocator, "SELECT id, name FROM concept WHERE id IN (");
    for (0..ids.len) |i| {
        if (i > 0) try query_builder.append(core.allocator, ',');
        try query_builder.append(core.allocator, '?');
    }
    try query_builder.append(core.allocator, ')');
    const query: []const u8 = query_builder.items;

    // Execute
    var stmt = try core.db.prepareDynamicWithDiags(query, .{ .diags = diags });
    defer stmt.deinit();

    // TODO This gives an error because of a bug: https://github.com/vrischmann/zig-sqlite/issues/208
    // For now just copy function inline with the fix (.empty instead of .{})
    // const concepts = try stmt.all(Concept, allocator, .{ .diags = diags }, ids);

    var iter = try stmt.iteratorAlloc(Concept, allocator, ids);
    var rows: std.ArrayList(Concept) = .empty;
    while (try iter.nextAlloc(allocator, .{ .diags = diags })) |row| {
        try rows.append(allocator, row);
    }
    const concepts = rows.toOwnedSlice(allocator);

    return concepts;
}
