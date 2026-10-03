const std = @import("std");
const known_folders = @import("known-folders");
const iroh = @import("iroh");
const sqlite = @import("sqlite");
const database = @import("database/database.zig");
const DbWriter = @import("database/DbWriter.zig");
const Id = database.Id;
const p2p = @import("p2p.zig");
const Router = p2p.Router;
const Peer = p2p.Peer;
const Core = @This();

const log = std.log.scoped(.core);

gpa: std.mem.Allocator,
io: std.Io,
data_dir: []const u8,
/// Read only
db: sqlite.Db,
db_writer: DbWriter,
router: Router,

/// List of known peers in sync with the db.
peers: []Peer = &.{},

// fn getDefaultDataDir(io: std.Io, alloc: std.mem.Allocator, environ: *std.process.Environ.Map) ?[]const u8 {
//     std.process.Environ.createMap(.empty, alloc)
//     // known_folders.getPath(io, alloc, environ, .data)
// }

pub const Options = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    data_dir: []const u8,
};

pub fn create(opts: Options) !*Core {
    const gpa = opts.gpa;
    const io = opts.io;

    const core = try gpa.create(Core);
    errdefer gpa.destroy(core);

    const data_dir = gpa.dupe(u8, opts.data_dir) catch @panic("OOM");
    errdefer gpa.free(data_dir);
    const dir = try std.Io.Dir.createDirPathOpen(.cwd(), io, data_dir, .{});
    defer dir.close(io);

    // Load sqlite database
    const db_path = try std.fs.path.joinZ(opts.gpa, &.{ data_dir, "ilm.db" });
    defer gpa.free(db_path);
    // First need to check if it does not exist yet. In that case we
    // need to create the Db object using write and create
    // permissions, as a read only db cannot create a new file.
    dir.access(io, "ilm.db", .{ .read = true, .write = true }) catch |err| switch (err) {
        error.FileNotFound => {
            var db = try database.getDb(db_path, .{ .write = true, .create = true });
            db.deinit();
        },
        else => return err,
    };
    var db = try database.getDb(db_path, .{ .write = false, .create = false });
    errdefer db.deinit();

    // Setup db writer
    var db_writer: DbWriter = try .init(opts.gpa, opts.io, db_path);
    errdefer db_writer.deinit();

    // Setup secret key
    const secret_key = blk: {
        if (dir.access(io, "secretkey.txt", .{ .read = true, .write = true })) {
            var secret_key_hex: [iroh.SecretKey.HEX_LEN]u8 = undefined;
            _ = try dir.readFile(io, "secretkey.txt", &secret_key_hex);
            const secret_key = try iroh.SecretKey.fromHex(&secret_key_hex);
            break :blk secret_key;
        } else |err| {
            switch (err) {
                error.FileNotFound => {
                    const secret_key = iroh.SecretKey.generate();
                    const secret_key_hex = secret_key.asHex();
                    try dir.writeFile(io, .{ .sub_path = "secretkey.txt", .data = &secret_key_hex });
                    break :blk secret_key;
                },
                else => return err,
            }
        }
    };

    // P2p router
    var router: Router = try .init(gpa, io, db_path, secret_key);
    errdefer router.deinit();

    core.* = .{
        .gpa = gpa,
        .io = io,
        .data_dir = data_dir,
        .db = db,
        .db_writer = db_writer,
        .router = router,
    };

    try db_writer.subscribe(.{ .cb = dbWriteCallback, .ctx = @ptrCast(core) });
    core.getPeers();

    return core;
}

pub fn destroy(core: *Core) void {
    core.db_writer.deinit();
    core.db.deinit();
    core.gpa.free(core.data_dir);
    core.router.deinit();
    core.gpa.free(core.peers);

    core.gpa.destroy(core);
}

pub fn setup(core: *Core) !void {
    try core.router.start();
    try core.db_writer.spawnWriteThread();
}

fn dbWriteCallback(core_opaque: *anyopaque, result: DbWriter.WriteResult) void {
    const write = result.write catch return;
    switch (write.table_id) {
        .peer => {
            const core: *Core = @ptrCast(@alignCast(core_opaque));
            core.getPeers();
        },
        else => return,
    }
}

fn getPeers(core: *Core) void {
    core.gpa.free(core.peers);
    core.peers = &.{};
    if (p2p.peer.getAll(&core.db, core.gpa)) |peers| {
        core.peers = peers;
    } else |err| {
        log.err("Failed to get peers from db: {t}", .{err});
    }
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
