const std = @import("std");
const ilm = @import("../root.zig");
const database = ilm.database;
const Db = database.Db;
const Diagnostics = database.Diagnostics;
const Id = database.Id;
const crdt = database.crdt;
const sqlite = @import("sqlite");

pub const Table = enum {
    concept,
    concept_rel,
    peer,
    crsql_changes,
    unknown,
};

pub const ConceptId = Id;
pub const ConceptRelId = struct { parent: Id, child: Id };
pub const PeerId = ilm.p2p.peer.Peer.Id;

pub const TableId = union(Table) {
    concept: ConceptId,
    concept_rel: ConceptRelId,
    peer: PeerId,
    crsql_changes: void,
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

        pub fn write(self: *const @This(), db: *Db) !Write {
            try ilm.concept.addImpl(db, self.id, self.name, self.parent_ids);
            return .{ .op = .insert, .table_id = .{ .concept = self.id } };
        }
    },
    rename_concept: struct {
        id: ConceptId,
        name: []const u8,

        pub fn write(self: *const @This(), db: *Db) !Write {
            try ilm.concept.renameImpl(db, self.id, self.name);
            return .{ .op = .update, .table_id = .{ .concept = self.id } };
        }
    },
    delete_concept: struct {
        id: ConceptId,

        pub fn write(self: *const @This(), db: *Db) !Write {
            try ilm.concept.deleteImpl(db, self.id);
            return .{ .op = .delete, .table_id = .{ .concept = self.id } };
        }
    },
    add_concept_parent: struct {
        child_id: ConceptId,
        parent_id: ConceptId,

        pub fn write(self: *const @This(), db: *Db) !Write {
            try ilm.concept.addParentImpl(db, self.child_id, self.parent_id);
            return .{ .op = .insert, .table_id = .{ .concept_rel = .{ .parent = self.parent_id, .child = self.child_id } } };
        }
    },
    add_peer: struct {
        id: PeerId,
        name: []const u8,

        pub fn write(self: *const @This(), db: *Db) !Write {
            try ilm.p2p.peer.addImpl(db, self.name, &self.id);
            return .{ .op = .insert, .table_id = .{ .peer = self.id } };
        }
    },
    delete_peer: struct {
        id: PeerId,

        pub fn write(self: *const @This(), db: *Db) !Write {
            try ilm.p2p.peer.deleteImpl(db, self.id);
            return .{ .op = .delete, .table_id = .{ .peer = self.id } };
        }
    },
    rename_peer: struct {
        id: PeerId,
        name: []const u8,

        pub fn write(self: *const @This(), db: *Db) !Write {
            try ilm.p2p.peer.renameImpl(db, self.id, self.name);
            return .{ .op = .update, .table_id = .{ .peer = self.id } };
        }
    },
    apply_changes: struct {
        changes: []crdt.Change,

        pub fn write(self: *const @This(), db: *Db) !Write {
            try crdt.mergeChangesImpl(db, self.changes);
            return .{ .op = .update, .table_id = .crsql_changes };
        }
    },
};
