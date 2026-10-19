//! Responsible for all write operations to the database.
//!
//! Writes are requested by pushing WriteRequests to the write queue. The
//! Writer will constantly drain the queue, processing these commands one
//! by one. Subscribers can subscribe to WriteResult events, which contains if the
//! command was succesfull, and if so, what table and row was affected,
//! and through what operation (update, insert, delete).
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
pub const sqlite = @import("sqlite");
pub const Diagnostics = sqlite.Diagnostics;
const ilm = @import("../root.zig");
const database = ilm.database;
const tables = database.tables;
const crdt = database.crdt;
pub const Write = tables.Write;

const log = std.log.scoped(.database_writer);

/// An autoincrementing integer unique for each write request. The
/// result also contains this id, allowing subscribers to know the
/// origin of the write.
pub const WriteRequestId = usize;

pub const WriteResult = struct {
    id: WriteRequestId,
    cmd: tables.TableCommand,
    /// Db versions after running the command.
    /// Points to DbWriter's internal field, which will be overwritten
    /// right after a new db write. Subscribers should therefore make
    /// a copy if need to be kept around.
    db_versions: *const crdt.DbVersionsMap,
    err: ?anyerror,
};

const WriteRequest = struct {
    id: WriteRequestId,
    // TODO If TableCommand gets too fat, consider heap
    // allocation. Arena is then required and will clean up the
    // command as well.
    cmd: tables.TableCommand,
    /// Passing an arena will make the writer call arena.deinit() when
    /// it is done processing the write command. This can be used to
    /// allocate the contents of the command.
    arena: ?std.heap.ArenaAllocator = null,
    sync_ctx: ?*SyncContext = null,

    /// Synchronous writes pass a reference to a stack allocated
    /// instance of this. The signal is used to suspend the calling
    /// thread and resume it when the result arrives.
    pub const SyncContext = struct {
        signal: std.Io.Event = .unset,
        result: WriteResult = undefined,
    };
};

const WriteQueue = std.Io.Queue(WriteRequest);

pub const CallbackFn = *const fn (*anyopaque, WriteResult) void;

pub const Subscriber = struct {
    ctx: *anyopaque,
    cb: CallbackFn,
    unsubscribed: bool = false,
};

gpa: Allocator,
io: std.Io,
db: sqlite.Db,
/// Gets updated after every write
db_versions: crdt.DbVersionsMap,
queue_buf: []WriteRequest,
queue: WriteQueue,
id_counter: std.atomic.Value(WriteRequestId) = .init(0),
subscribers: std.ArrayList(Subscriber) = .empty,
thread: ?std.Thread = null,

pub fn init(gpa: Allocator, io: std.Io, db_path: [:0]const u8) !Self {
    var db = try database.getDb(db_path, .{ .flags = .{ .write = true } });
    errdefer db.deinit();

    var db_versions = try crdt.getDbVersionsMap(&db, gpa);
    errdefer db_versions.deinit(gpa);

    const queue_buf = try gpa.alloc(WriteRequest, 64);
    errdefer gpa.free(queue_buf);

    return .{
        .gpa = gpa,
        .io = io,
        .db = db,
        .db_versions = db_versions,
        .queue_buf = queue_buf,
        .queue = .init(queue_buf),
    };
}

pub fn deinit(self: *Self) void {
    self.subscribers.deinit(self.gpa);
    // NOTE Closing the queue does not mean the queue buffer is empty,
    // so the buffer is still assumed to be available after closing (I
    // think??). Freeing the buffer right after can therefore leads to
    // memory problems. However I intend for this struct to stay alive
    // for the duration of the application, so this is not a big deal?
    self.queue.close(self.io);
    self.gpa.free(self.queue_buf);
    self.db_versions.deinit(self.gpa);
    self.db.deinit();
}

pub fn subscribe(self: *Self, data: Subscriber) Allocator.Error!void {
    try self.subscribers.append(self.gpa, data);
}

pub fn unsubscribe(self: *Self, target: Subscriber) void {
    // We only mark the unsubscription in the struct. This handles
    // cases were subscribers unsub during this loop. The cleanup
    // happens in the next publish().
    for (self.subscribers.items) |*sub| {
        if (sub.ctx == target.ctx and sub.cb == target.cb) {
            sub.unsubscribed = true;
            return;
        }
    }
}

fn publish(self: *Self, event: WriteResult) void {
    for (self.subscribers.items) |*sub| {
        if (!sub.unsubscribed) {
            sub.cb(sub.ctx, event);
        }
    }

    // Clean up dead subscribers.
    // We iterate backwards because we use swapRemove
    var i: usize = self.subscribers.items.len;
    while (i > 0) {
        i -= 1;
        if (self.subscribers.items[i].unsubscribed) {
            _ = self.subscribers.swapRemove(i);
        }
    }
}

/// Add a write request to the queue and returns its id.
///
/// Optionally, an arena allocator can be passed that will be deinited
/// after the command has been processed. This can be used to allocate
/// the fields of the command. If omitted, care must be taken to ensure
/// the lifetime of the command fields are valid until after the
/// subscribers have been notified.
pub fn addCommand(
    self: *Self,
    cmd: tables.TableCommand,
    opts: struct {
        arena: ?std.heap.ArenaAllocator = null,
    },
) std.Io.QueueClosedError!WriteRequestId {
    const req: WriteRequest = .{
        .id = self.id_counter.fetchAdd(1, .seq_cst),
        .cmd = cmd,
        .arena = opts.arena,
    };
    try self.queue.putOneUncancelable(self.io, req);
    return req.id;
}

/// Run a write command synchronously, blocks until done.
pub fn runCommand(
    self: *Self,
    cmd: tables.TableCommand,
    opts: struct {
        arena: ?std.heap.ArenaAllocator = null,
    },
) std.Io.QueueClosedError!WriteResult {
    var sync_ctx: WriteRequest.SyncContext = .{};

    const req: WriteRequest = .{
        .id = self.id_counter.fetchAdd(1, .seq_cst),
        .cmd = cmd,
        .arena = opts.arena,
        .sync_ctx = &sync_ctx,
    };
    try self.queue.putOneUncancelable(self.io, req);

    sync_ctx.signal.waitUncancelable(self.io);

    return sync_ctx.result;
}

fn runLoop(self: *Self) !void {
    while (true) {
        const req = self.queue.getOneUncancelable(self.io) catch |err| switch (err) {
            error.Closed => {
                log.err("Db Writer queue closed, killing thread.", .{});
                return;
            },
        };
        defer if (req.arena) |arena| arena.deinit();

        const write_err: ?anyerror = switch (req.cmd) {
            inline else => |cmd| blk: {
                if (cmd.write(&self.db)) {
                    // Update db version map on successful write.
                    self.db_versions.deinit(self.gpa);
                    self.db_versions = crdt.getDbVersionsMap(&self.db, self.gpa) catch unreachable;

                    break :blk null;
                } else |err| {
                    log.err("Table write cmd failed: {t}", .{err});
                    break :blk err;
                }
            },
        };

        const result: WriteResult = .{
            .id = req.id,
            .cmd = req.cmd,
            .err = write_err,
            .db_versions = &self.db_versions,
        };

        if (req.sync_ctx) |sync_ctx| {
            sync_ctx.result = result;
            sync_ctx.signal.set(self.io);
        }

        self.publish(result);
    }
}

pub fn spawnWriteThread(self: *Self) !void {
    const thread = std.Thread.spawn(.{}, runLoop, .{self}) catch |err| {
        log.err("Failed to spawn DbWriter thread: {t}", .{err});
        return err;
    };
    thread.detach();
    self.thread = thread;
}
