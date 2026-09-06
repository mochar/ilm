const std = @import("std");

const sqlite = @import("sqlite");
const uuid = @import("uuid");
pub const Uuid = uuid.Uuid;
pub const UuidStr = uuid.urn.Urn;

// Alias for u128
// Alias for [36]u8
const Core = @This();

const schema = @embedFile("schema.sql");

counter: i64 = 0,
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
        .counter = 0,
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

pub const IdStr = [36]u8;
pub const Id = struct {
    uuid: Uuid,

    pub fn new(io: std.Io) Id {
        return .{ .uuid = uuid.v7.new(io) };
    }

    pub fn serialize(self: *Id) IdStr {
        return uuid.urn.serialize(self.uuid);
    }
};

pub fn newId(core: *Core) Id {
    return Id.new(core.io);
}

pub const Concept = struct {
    id: Uuid,
    name: []const u8,
};

pub fn addConcept(core: *Core, name: []const u8, diags: *sqlite.Diagnostics) !Id {
    var stmt = try core.db.prepareWithDiags("INSERT INTO concept(id, name) VALUES (?, ?)", .{ .diags = diags });
    defer stmt.deinit();

    const id = core.newId();
    const id_blob: sqlite.Blob = .{ .data = std.mem.asBytes(&id.uuid) };
    try stmt.exec(.{ .diags = diags }, .{ .id = id_blob, .name = name });
    return id;
}

pub fn getAllConcepts(core: *Core, allocator: std.mem.Allocator, diags: *sqlite.Diagnostics) ![]Concept {
    var stmt = try core.db.prepareWithDiags("SELECT id, name FROM concept", .{ .diags = diags });
    defer stmt.deinit();
    const concepts = try stmt.all(Concept, allocator, .{ .diags = diags, }, .{});
    return concepts;
}

fn getConceptsById(core: *Core, allocator: std.mem.Allocator, ids: []Uuid) ![]Concept {
    // Build the query
    var query_builder = std.array_list.Managed(u8).init(core.allocator);
    defer query_builder.deinit();

    try query_builder.appendSlice("SELECT id, name FROM items WHERE id IN (");
    for (0..ids.len) |i| {
        if (i > 0) try query_builder.appendSlice(", ");
        try query_builder.appendByte('?');
    }
    try query_builder.appendByte(')');
    const query: []const u8 = query_builder.items;

    // Execute
    var stmt = try core.db.prepareDynamic(query);
    defer stmt.deinit();

    // var arena = std.heap.ArenaAllocator.init(allocator);
    // defer arena.deinit();

    const concepts = try stmt.all(Concept, allocator, .{}, ids);
    return concepts;
}
