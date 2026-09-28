const std = @import("std");
const Allocator = std.mem.Allocator;
pub const sqlite = @import("sqlite");
pub const Diagnostics = sqlite.Diagnostics;
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

pub const Table = enum {
    concept,
    concept_rel,
    peer,
    unknown,
};

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

    pub fn bindField(self: Id, allocator: Allocator) !BaseType {
        // Since self is passed by value and sqlite.Blob only holds a reference,
        // need to allocate on heap. For this reason, prefer to do it manually:
        //   try stmt.exec(.{ .diags = diags }, .{ .id = id.asBlob(), .name = name });
        const bytes = try allocator.dupe(u8, std.mem.asBytes(&self.uuid));
        return .{ .data = bytes };
    }

    pub fn readField(_: Allocator, blob: BaseType) !Id {
        const uuid_int = std.mem.bytesAsValue(u128, blob.data);
        return .{ .uuid = uuid_int.* };
    }
};

pub fn queryAll(comptime T: type, alloc: Allocator, stmt: anytype, values: anytype) ![]T {
    var diags: sqlite.Diagnostics = .{};
    var iter = try stmt.iteratorAlloc(T, alloc, values);
    var rows: std.ArrayList(T) = .empty;
    defer rows.deinit(alloc);
    while (try iter.nextAlloc(alloc, .{ .diags = &diags })) |row| {
        try rows.append(alloc, row);
    }
    return try rows.toOwnedSlice(alloc);
}

/// Publishes database update events to subscribers.
pub const EventPub = struct {
    pub const Callback = *const fn (*anyopaque, Event) void;

    pub const Subscriber = struct {
        ctx: *anyopaque,
        cb: Callback,
    };

    pub const Event = struct {
        table: Table,
        op: enum(c_int) {
            insert = sqlite.c.SQLITE_INSERT,
            delete = sqlite.c.SQLITE_DELETE,
            update = sqlite.c.SQLITE_UPDATE,
        },
        /// https://sqlite.org/lang_createtable.html#rowid
        rowid: i64,
    };

    gpa: Allocator,
    // For pointer stability cannot pass reference to the sqlite.Db
    // struct. Since it only contains the *c.sqlite3 handle as a
    // field, i could just copy it...
    db: *sqlite.c.sqlite3,
    subscribers: std.ArrayList(Subscriber) = .empty,

    pub fn create(gpa: Allocator, db: *sqlite.c.sqlite3) !*EventPub {
        const self = try gpa.create(EventPub);
        self.* = .{ .db = db, .gpa = gpa, .subscribers = .empty };
        _ = sqlite.c.sqlite3_update_hook(db, sqliteUpdateHook, @ptrCast(self));
        return self;
    }

    pub fn destroy(self: *EventPub) void {
        self.subscribers.deinit(self.gpa);
        _ = sqlite.c.sqlite3_update_hook(self.db, null, null);
        self.gpa.destroy(self);
    }

    /// https://sqlite.org/c3ref/update_hook.html
    fn sqliteUpdateHook(
        eventpub: ?*anyopaque,
        op: c_int,
        db: [*c]const u8,
        table: [*c]const u8,
        rowid: c_longlong,
    ) callconv(.c) void {
        _ = db;
        const self: *EventPub = @ptrCast(@alignCast(eventpub));
        self.publish(.{
            .op = @enumFromInt(op),
            .table = std.meta.stringToEnum(Table, std.mem.span(table)) orelse .unknown,
            .rowid = @intCast(rowid),
        });
    }

    fn publish(self: *EventPub, event: Event) void {
        for (self.subscribers.items) |*sub| {
            sub.cb(sub.ctx, event);
        }
    }

    pub fn subscribe(self: *EventPub, data: Subscriber) Allocator.Error!void {
        try self.subscribers.append(self.gpa, data);
    }
};
