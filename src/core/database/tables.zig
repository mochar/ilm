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
pub const PeerId = ilm.p2p.Peer.Id;

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

    pub fn affectedTables(self: TableCommand) []const Table {
        return switch(self) {
            inline else => |cmd| @TypeOf(cmd).tables,
        };
    }

    pub fn affectsTable(self: *const TableCommand, table: Table) bool {
        for (self.affectedTables()) |affected_table| {
            if (table == affected_table) return true;
        }
        return false;
    }

    pub fn affectsTables(self: *const TableCommand, tables: []const Table) bool {
        for (tables) |table| {
            if (self.affectsTable(table)) return true;
        }
        return false;
    }

    add_concept: struct {
        pub const tables = &[_]Table{ .concept, .concept_rel };
        
        id: ConceptId,
        name: []const u8,
        parent_ids: []const ConceptId,

        pub fn write(self: *const @This(), db: *Db) !void {
            try ilm.concept.addImpl(db, self.id, self.name, self.parent_ids);
        }
    },
    rename_concept: struct {
        pub const tables = &[_]Table{ .concept };
        
        id: ConceptId,
        name: []const u8,

        pub fn write(self: *const @This(), db: *Db) !void {
            try ilm.concept.renameImpl(db, self.id, self.name);
        }
    },
    delete_concepts: struct {
        pub const tables = &[_]Table{ .concept, .concept_rel };
        
        ids: []const ConceptId,

        pub fn write(self: *const @This(), db: *Db) !void {
            try ilm.concept.deleteManyImpl(db, self.ids);
        }
    },
    add_concept_parent: struct {
        pub const tables = &[_]Table{ .concept_rel };
        
        child_id: ConceptId,
        parent_id: ConceptId,

        pub fn write(self: *const @This(), db: *Db) !void {
            try ilm.concept.addParentImpl(db, self.child_id, self.parent_id);
        }
    },
    add_peer: struct {
        pub const tables = &[_]Table{ .peer };
        
        id: PeerId,
        name: []const u8,

        pub fn write(self: *const @This(), db: *Db) !void {
            try ilm.p2p.peer.addImpl(db, self.name, &self.id);
        }
    },
    delete_peer: struct {
        pub const tables = &[_]Table{ .peer };
        
        id: PeerId,

        pub fn write(self: *const @This(), db: *Db) !void {
            try ilm.p2p.peer.deleteImpl(db, self.id);
        }
    },
    rename_peer: struct {
        pub const tables = &[_]Table{ .peer };
        
        id: PeerId,
        name: []const u8,

        pub fn write(self: *const @This(), db: *Db) !void {
            try ilm.p2p.peer.renameImpl(db, self.id, self.name);
        }
    },
    apply_changes: struct {
        pub const tables = &[_]Table{ .crsql_changes };
        
        changes: []crdt.Change,

        pub fn write(self: *const @This(), db: *Db) !void {
            try crdt.mergeChangesImpl(db, self.changes);
        }
    },
};
