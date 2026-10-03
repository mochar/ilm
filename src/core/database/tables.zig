const std = @import("std");
const sqlite = @import("sqlite");
const Diagnostics = sqlite.Diagnostics;
const Id = @import("Id.zig");
const ilm = @import("../root.zig");

pub const Table = enum {
    concept,
    concept_rel,
    peer,
    unknown,
};

pub const ConceptId = Id;
pub const ConceptRelId = struct { parent: Id, child: Id };
/// Endpoint/public key ID
pub const PeerId = [32]u8;

pub const TableId = union(Table) {
    concept: ConceptId,
    concept_rel: ConceptRelId,
    peer: PeerId,
    unknown: void,
};

pub const Write = struct {
    table_id: TableId,
    op: enum { insert, delete, update },
};

pub const TableCommand = union(enum) {
    const log = std.log.scoped(.database_table_writer);

    add_concept: struct {
        id: ConceptId,
        name: []const u8,
        parent_ids: []const ConceptId,

        pub fn write(self: *const @This(), db: *sqlite.Db) !Write {
            var diags: Diagnostics = .{};

            var savepoint = try db.savepoint("addconcept");
            defer savepoint.rollback();
            const id_blob = self.id.asBlob();

            {
                var stmt = db.prepareWithDiags(
                    "INSERT INTO concept(id, name) VALUES (?, ?)",
                    .{ .diags = &diags },
                ) catch |err| {
                    log.err("SQLite prepare failed: {s}", .{diags.message});
                    return err;
                };
                defer {
                    _ = sqlite.c.sqlite3_reset(stmt.dynamic_stmt.stmt);
                    stmt.deinit();
                }
                stmt.exec(
                    .{ .diags = &diags },
                    .{ .id = id_blob, .name = self.name },
                ) catch |err| {
                    log.err("SQLite exec failed: {s}", .{diags.message});
                    return err;
                };
            }

            {
                var stmt = db.prepareWithDiags(
                    "INSERT INTO concept_rel(parent_id, child_id) VALUES (?, ?)",
                    .{ .diags = &diags },
                ) catch |err| {
                    log.err("SQLite prepare failed: {s}", .{diags.message});
                    return err;
                };
                defer {
                    _ = sqlite.c.sqlite3_reset(stmt.dynamic_stmt.stmt);
                    stmt.deinit();
                }
                for (self.parent_ids) |*parent_id| {
                    stmt.reset();
                    stmt.exec(
                        .{ .diags = &diags },
                        .{ .parent_id = parent_id.asBlob(), .child_id = id_blob },
                    ) catch |err| {
                        log.err("SQLite exec failed: {s}", .{diags.message});
                        return err;
                    };
                }
            }

            savepoint.commit();

            return .{ .op = .insert, .table_id = .{ .concept = self.id } };
        }
    },
    rename_concept: struct {
        id: ConceptId,
        name: []const u8,

        // TODO Validate that rename actually happened (in case concept not found in db)
        pub fn write(self: *const @This(), db: *sqlite.Db) !Write {
            var diags: sqlite.Diagnostics = .{};

            var stmt = db.prepareWithDiags(
                \\UPDATE concept
                \\SET name = ?
                \\WHERE id = ?
            , .{ .diags = &diags }) catch |err| {
                log.err("SQLite prepare failed: {s}", .{diags.message});
                return err;
            };
            defer stmt.deinit();

            stmt.exec(
                .{ .diags = &diags },
                .{ .name = self.name, .id = self.id.asBlob() },
            ) catch |err| {
                log.err("SQLite exec failed: {s}", .{diags.message});
                return err;
            };

            return .{ .op = .update, .table_id = .{ .concept = self.id } };
        }
    },
    delete_concept: struct {
        id: ConceptId,

        // TODO Validate that delete actually happened (in case concept not found in db)
        pub fn write(self: *const @This(), db: *sqlite.Db) !Write {
            var diags: sqlite.Diagnostics = .{};
            var savepoint = try db.savepoint("delconcept");
            defer savepoint.rollback();

            // Delete the relationship first. Otherwise inbetween there will
            // conceptid in concept_rel of a concept that doesnt exist. This
            // is a problem because of the sqlite update hook, which reacts
            // immediately.
            {
                var stmt = db.prepareWithDiags(
                    \\DELETE FROM concept_rel
                    \\WHERE parent_id = ? OR child_id = ?
                , .{ .diags = &diags }) catch |err| {
                    log.err("SQLite prepare failed: {s}", .{diags.message});
                    return err;
                };
                defer stmt.deinit();

                stmt.exec(
                    .{ .diags = &diags },
                    .{ self.id.asBlob(), self.id.asBlob() },
                ) catch |err| {
                    log.err("SQLite exec failed: {s}", .{diags.message});
                    return err;
                };
            }

            {
                var stmt = db.prepareWithDiags(
                    \\DELETE FROM concept
                    \\WHERE id = ?
                , .{ .diags = &diags }) catch |err| {
                    log.err("SQLite prepare failed: {s}", .{diags.message});
                    return err;
                };
                defer stmt.deinit();

                stmt.exec(
                    .{ .diags = &diags },
                    .{ .id = self.id.asBlob() },
                ) catch |err| {
                    log.err("SQLite exec failed: {s}", .{diags.message});
                    return err;
                };
            }

            savepoint.commit();
            
            return .{ .op = .delete, .table_id = .{ .concept = self.id } };
        }
    },
    add_peer: struct {
        id: PeerId,
        name: []const u8,

        pub fn write(self: *const @This(), db: *sqlite.Db) !Write {
            try ilm.p2p.peer.addImpl(db, self.name, &self.id);
            return .{ .op = .insert, .table_id = .{ .peer = self.id } };
        }
    },
    delete_peer: struct {
        id: PeerId,

        pub fn write(self: *const @This(), db: *sqlite.Db) !Write {
            try ilm.p2p.peer.deleteImpl(db, self.id);
            return .{ .op = .delete, .table_id = .{ .peer = self.id } };
        }
    },
};
