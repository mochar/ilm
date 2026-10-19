const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.concept);
const sqlite = @import("sqlite");
const Core = @import("Core.zig");
const database = @import("database.zig");
const Db = database.Db;
const Diagnostics = database.Diagnostics;
const Uuid = database.Uuid;
const Write = database.tables.Write;
const crdt = database.crdt;
const Graph = @import("graphviz").Graph;

pub const Concept = struct {
    id: Uuid,
    name: []const u8,
};

pub const ConceptAncestor = struct {
    id: Uuid,
    name: []const u8,
    child_id: Uuid,
    depth: usize,
    is_direct: bool,
};

// ** DB operations

pub fn add(core: *Core, name: []const u8, parent_ids: []const Uuid) !Uuid {
    const id = core.newId();
    const res = try core.db_writer.runCommand(.{ .add_concept = .{
        .id = id,
        .name = name,
        .parent_ids = parent_ids,
    } }, .{});
    return if (res.err) |err| err else id;
}

pub fn addImpl(db: *Db, id: Uuid, name: []const u8, parent_ids: []const Uuid) !void {
    var diags: Diagnostics = .{};

    var savepoint = try db.savepoint("addconcept");
    defer savepoint.rollback();
    const id_blob = id.asBlob();

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
            .{ .id = id_blob, .name = name },
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
        for (parent_ids) |*parent_id| {
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
}

pub fn rename(core: *Core, id: Uuid, name: []const u8) !void {
    const res = try core.db_writer.runCommand(.{ .rename_concept = .{
        .id = id,
        .name = name,
    } }, .{});
    return res.err orelse {};
}

// TODO Validate that rename actually happened (in case concept not found in db)
pub fn renameImpl(db: *Db, id: Uuid, name: []const u8) !void {
    var diags: Diagnostics = .{};

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
        .{ .name = name, .id = id.asBlob() },
    ) catch |err| {
        log.err("SQLite exec failed: {s}", .{diags.message});
        return err;
    };
}

pub fn deleteMany(core: *Core, ids: []const Uuid) !void {
    const res = try core.db_writer.runCommand(.{ .delete_concepts = .{ .ids = ids } }, .{});
    return res.err orelse {};
}

pub fn delete(core: *Core, id: Uuid) !void {
    return deleteMany(core, &.{id});
}

pub fn deleteManyImpl(db: *Db, ids: []const Uuid) !void {
    var diags: Diagnostics = .{};
    var savepoint = try db.savepoint("delconcept");
    defer savepoint.rollback();

    var del_rel_stmt = db.prepareWithDiags(
        \\DELETE FROM concept_rel
        \\WHERE parent_id = ? OR child_id = ?
    , .{ .diags = &diags }) catch |err| {
        log.err("SQLite prepare failed: {s}", .{diags.message});
        return err;
    };
    defer del_rel_stmt.deinit();

    var del_conc_stmt = db.prepareWithDiags(
        \\DELETE FROM concept
        \\WHERE id = ?
    , .{ .diags = &diags }) catch |err| {
        log.err("SQLite prepare failed: {s}", .{diags.message});
        return err;
    };
    defer del_conc_stmt.deinit();

    for (ids) |*id| {
        del_rel_stmt.reset();
        del_conc_stmt.reset();

        del_rel_stmt.exec(
            .{ .diags = &diags },
            .{ id.asBlob(), id.asBlob() },
        ) catch |err| {
            log.err("SQLite exec failed: {s}", .{diags.message});
            return err;
        };

        del_conc_stmt.exec(
            .{ .diags = &diags },
            .{ .id = id.asBlob() },
        ) catch |err| {
            log.err("SQLite exec failed: {s}", .{diags.message});
            return err;
        };
    }

    savepoint.commit();
}

pub fn addParent(core: *Core, child_id: Uuid, parent_id: Uuid) !void {
    const res = try core.db_writer.runCommand(.{ .add_concept_parent = .{
        .child_id = child_id,
        .parent_id = parent_id,
    } }, .{});
    return res.err orelse {};
}

pub fn addParentImpl(db: *Db, child_id: Uuid, parent_id: Uuid) !void {
    var diags: Diagnostics = .{};
    var stmt = try db.prepareWithDiags(
        "INSERT OR IGNORE INTO concept_rel(parent_id, child_id) VALUES (?, ?)",
        .{ .diags = &diags },
    );
    defer {
        _ = sqlite.c.sqlite3_reset(stmt.dynamic_stmt.stmt);
        stmt.deinit();
    }
    try stmt.exec(.{ .diags = &diags }, .{
        .parent_id = parent_id.asBlob(),
        .child_id = child_id.asBlob(),
    });
}

pub fn removeParent(core: *Core, child_id: Uuid, parent_id: Uuid) !void {
    var diags: Diagnostics = .{};
    var stmt = try core.db.prepareWithDiags(
        "DELETE FROM concept_rel WHERE parent_id = ? AND child_id = ?",
        .{ .diags = &diags },
    );
    defer {
        _ = sqlite.c.sqlite3_reset(stmt.dynamic_stmt.stmt);
        stmt.deinit();
    }
    try stmt.exec(
        .{ .diags = &diags },
        .{ .parent_id = parent_id.asBlob(), .child_id = child_id.asBlob() },
    );
}

fn queryConcepts(alloc: Allocator, stmt: anytype, values: anytype) ![]Concept {
    var diags: Diagnostics = .{};
    var iter = try stmt.iteratorAlloc(Concept, alloc, values);
    var rows: std.ArrayList(Concept) = .empty;
    defer rows.deinit(alloc);
    while (try iter.nextAlloc(alloc, .{ .diags = &diags })) |row| {
        try rows.append(alloc, row);
    }
    return try rows.toOwnedSlice(alloc);
}

pub fn getAll(core: *Core, alloc: Allocator) ![]Concept {
    var diags: Diagnostics = .{};
    var stmt = try core.db.prepareWithDiags(
        // "SELECT id, name FROM concept ORDER BY name",
        "SELECT id, name FROM concept",
        .{ .diags = &diags },
    );
    defer stmt.deinit();
    return try queryConcepts(alloc, &stmt, .{});
}

pub fn getById(core: *Core, alloc: Allocator, id: Uuid) !?Concept {
    var diags: Diagnostics = .{};
    var stmt = try core.db.prepareWithDiags(
        "SELECT id, name FROM concept WHERE id = ?",
        .{ .diags = &diags },
    );
    defer stmt.deinit();
    return try stmt.oneAlloc(Concept, alloc, .{ .diags = &diags }, .{id});
}

pub fn getByIds(core: *Core, alloc: Allocator, ids: []const Uuid) ![]Concept {
    if (ids.len == 0) return &.{};

    var arena_alloc: std.heap.ArenaAllocator = .init(alloc);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    var query_builder: std.ArrayList(u8) = .empty;
    defer query_builder.deinit(arena);
    try query_builder.appendSlice(arena, "SELECT id, name FROM concept WHERE id IN (");
    for (0..ids.len) |i| {
        if (i > 0) try query_builder.appendSlice(arena, ", ");
        try query_builder.appendSlice(arena, "?");
    }
    try query_builder.appendSlice(arena, ")");
    const query: []const u8 = query_builder.items;

    var diags: Diagnostics = .{};
    var stmt = try core.db.prepareDynamicWithDiags(query, .{ .diags = &diags });
    defer stmt.deinit();

    return try queryConcepts(alloc, &stmt, ids);
}

pub fn getByNameMatch(core: *Core, alloc: Allocator, substr: []const u8) ![]Concept {
    const query =
        \\SELECT id, name
        \\FROM concept
        \\WHERE instr(name, ?) > 0
    ;
    var diags: Diagnostics = .{};
    var stmt = try core.db.prepareWithDiags(query, .{ .diags = &diags });
    defer stmt.deinit();
    return try queryConcepts(alloc, &stmt, .{substr});
}

/// Retrieve the hierarchy of ancestors for a set of concepts.
///
/// If `direct_only` is true, only returns immediate parents (depth = 1).
/// Otherwise, returns the entire transitive ancestry with minimum depth and an
/// `is_direct` flag.
///
/// NOTE: Direct parents (depth = 1) will be included even if marked as redundant
/// in `concept_rel`.
pub fn getAncestors(
    core: *Core,
    alloc: std.mem.Allocator,
    opts: struct {
        ids: ?[]const Uuid = null,
        direct_only: bool = false,
    },
) ![]ConceptAncestor {
    var query_builder: std.ArrayList(u8) = .empty;
    defer query_builder.deinit(alloc);

    if (opts.direct_only) {
        const ids = opts.ids orelse &.{};
        try query_builder.appendSlice(alloc,
            \\SELECT c.id, c.name, cr.child_id, 1 AS depth, 1 AS is_direct
            \\FROM concept_rel cr
            \\JOIN concept c ON cr.parent_id = c.id
            \\WHERE cr.child_id IN (
        );
        for (0..ids.len) |i| {
            if (i > 0) try query_builder.appendSlice(alloc, ", ");
            try query_builder.appendSlice(alloc, "?");
        }
        try query_builder.appendSlice(alloc,
            \\)
            \\ORDER BY cr.child_id, c.name
        );
    } else {
        try query_builder.appendSlice(alloc,
            \\WITH RECURSIVE ancestors(id, child_id, depth) AS (
            \\    SELECT parent_id, child_id, 1
            \\    FROM concept_rel
        );
        if (opts.ids) |ids| {
            try query_builder.appendSlice(alloc, "\nWHERE child_id IN (");
            for (0..ids.len) |i| {
                if (i > 0) try query_builder.appendSlice(alloc, ", ");
                try query_builder.appendSlice(alloc, "?");
            }
            try query_builder.appendSlice(alloc, "\n)");
        }
        try query_builder.appendSlice(alloc,
            \\    UNION ALL
            \\    SELECT cr.parent_id, a.child_id, a.depth + 1
            \\    FROM concept_rel cr
            \\    JOIN ancestors a ON cr.child_id = a.id
            \\)
            \\SELECT c.id, c.name, a.child_id, MIN(a.depth) AS depth, (MIN(a.depth) = 1) AS is_direct
            \\FROM ancestors a
            \\JOIN concept c ON a.id = c.id
            \\GROUP BY c.id, a.child_id
            \\ORDER BY a.child_id, depth, c.name
        );
    }
    const query: []const u8 = query_builder.items;

    var diags: Diagnostics = .{};
    var stmt = core.db.prepareDynamicWithDiags(query, .{ .diags = &diags }) catch |err| {
        log.err("SQLite prepare failed: {s}", .{diags.message});
        return err;
    };
    defer stmt.deinit();

    var iter = try stmt.iteratorAlloc(ConceptAncestor, alloc, opts.ids orelse &.{});
    var rows: std.ArrayList(ConceptAncestor) = .empty;
    defer rows.deinit(alloc);
    while (try iter.nextAlloc(alloc, .{ .diags = &diags })) |row| {
        try rows.append(alloc, row);
    }
    const result = try rows.toOwnedSlice(alloc);

    return result;
}

/// Get concepts with no parent concepts.
pub fn getRoots(core: *Core, allocator: std.mem.Allocator) ![]Concept {
    // A concept has no ancestors if it never appears as a child_id in concept_rel
    const query =
        \\SELECT c.id, c.name
        \\FROM concept c
        \\WHERE NOT EXISTS (
        \\    SELECT 1 FROM concept_rel cr WHERE cr.child_id = c.id
        \\)
        \\ORDER BY c.name
    ;

    var diags: Diagnostics = .{};
    var stmt = core.db.prepareDynamicWithDiags(query, .{ .diags = &diags }) catch |err| {
        log.err("SQLite prepare failed: {s}", .{diags.message});
        return err;
    };
    defer stmt.deinit();

    var iter = try stmt.iteratorAlloc(Concept, allocator, .{});

    var rows: std.ArrayList(Concept) = .empty;
    defer rows.deinit(allocator);

    while (try iter.nextAlloc(allocator, .{ .diags = &diags })) |row| {
        try rows.append(allocator, row);
    }

    return try rows.toOwnedSlice(allocator);
}

pub const Relation = struct {
    parent_id: Uuid,
    child_id: Uuid,
};

pub fn getRelations(core: *Core, alloc: Allocator, ids: ?[]const Uuid) ![]Relation {
    var query_builder: std.ArrayList(u8) = .empty;
    defer query_builder.deinit(alloc);

    if (ids) |idss| {
        if (idss.len == 0) return &.{};
        try query_builder.appendSlice(alloc, "WITH id_list(id) AS ( VALUES ");
        for (0..idss.len) |i| {
            if (i > 0) try query_builder.appendSlice(alloc, ", ");
            try query_builder.appendSlice(alloc, "(?)");
        }
        try query_builder.appendSlice(alloc, ")\n");
    }
    try query_builder.appendSlice(alloc,
        \\SELECT parent_id, child_id
        \\FROM concept_rel cr
    );
    if (ids != null) {
        try query_builder.appendSlice(alloc,
            \\
            \\JOIN id_list l1 ON cr.parent_id = l1.id
            \\JOIN id_list l2 ON cr.child_id  = l2.id
        );
    }
    const query = query_builder.items;

    var diags: Diagnostics = .{};
    var stmt = core.db.prepareDynamicWithDiags(query, .{ .diags = &diags }) catch |err| {
        log.err("SQLite prepare failed: {s}", .{diags.message});
        return err;
    };
    defer stmt.deinit();

    var iter = if (ids) |idss|
        try stmt.iteratorAlloc(Relation, alloc, idss)
    else
        try stmt.iteratorAlloc(Relation, alloc, .{});
    var rows: std.ArrayList(Relation) = .empty;
    defer rows.deinit(alloc);
    while (try iter.nextAlloc(alloc, .{ .diags = &diags })) |row| {
        try rows.append(alloc, row);
    }
    const result = try rows.toOwnedSlice(alloc);

    return result;
}

// ** Query changes

// The following gets the rows of the 'concept' and 'concept_rel'
// tables, including deleted ones (though these only contain pks),
// that were edited, added, or removed between a db version interval
// per peer id. Each row has a field describing what kind of change it
// is.
// This is messy for two reasons:
//   1. The cr-sqlite fork stores for each change the original db
//      version, so we cannot just say "get everything after db version x",
//      as peers with a smaller db version may have made the change
//      later than a peer with a larger db versionn. We thus have to
//      check for each peer to get "latest changes since".
//   2. Instead of using the 'crsql_changes' virtual table that is
//      used to get and apply changesets, we parse the table-specific
//      clock tables directly. Not sure why. It is def possible to do the
//      same with 'crsql_changes' using the id packing function of crsql:
//         SELECT pks.id, c.cid, c.val, c.col_version
//         FROM crsql_changes c
//         JOIN concept__crsql_pks pks ON c.pk = crsql_pack_columns(pks.id)
//         WHERE c."table" = 'concept' AND c.site_id IS :site_id AND c.db_version > :db_version;

pub const ChangeOp = enum(u8) {
    insert = 0,
    update = 1,
    delete = 2,

    // for sqlite
    pub const BaseType = u8;
};

pub const ConceptChange = struct {
    id: Uuid,
    name: ?[]const u8,
    op: ChangeOp,
    /// Because the clock table records the db_version per column, we take the max.
    /// This gives for:
    ///  - inserts: The version when the concept was created.
    ///  - updates: The version of the most recent update made to this concept.
    ///  - deletes: The version when the concept was deleted.
    db_version: u64,
    /// The site that made this change.
    site_id: [16]u8,
};

pub const RelationChange = struct {
    parent_id: Uuid,
    child_id: Uuid,
    /// As of now only has inserts and deletes
    op: ChangeOp,
    db_version: u64,
    site_id: [16]u8,
};

pub fn TableChanges(comptime T: type) type {
    return struct {
        /// Ordered by db version, oldest to newest
        changes: []T,
        inserts: usize,
        deletes: usize,
        updates: usize,

        pub fn lastDbVersion(self: *const @This()) ?u64 {
            if (self.changes.len == 0) return null;
            return self.changes[self.changes.len - 1].db_version;
        }
    };
}
pub const ConceptChanges = TableChanges(ConceptChange);
pub const RelationChanges = TableChanges(RelationChange);

fn queryChanges(
    comptime T: type,
    db: *Db,
    comptime query: []const u8,
    since_db_versions: *const crdt.DbVersionsMap,
    until_db_versions: *const crdt.DbVersionsMap,
    alloc: Allocator,
) !TableChanges(T) {
    var diags: Diagnostics = .{};
    var stmt = db.prepareWithDiags(query, .{ .diags = &diags }) catch |err| {
        const detail = db.getDetailedError();
        log.err("SQLite prepare failed for 'queryChanges' ({t}): {f}", .{ err, detail });
        return err;
    };
    defer stmt.deinit();

    var changes: std.ArrayList(T) = .empty;
    defer changes.deinit(alloc);
    var inserts: usize = 0;
    var deletes: usize = 0;
    var updates: usize = 0;

    // Site ids may not match, as new peers might have been added or old
    // ones removed. In general don't want to assume structure of version
    // maps. So first find union of site ids.
    var site_ids: std.AutoHashMapUnmanaged(crdt.SiteId, void) = .empty;
    try site_ids.ensureTotalCapacity(
        alloc,
        @intCast(since_db_versions.count() + until_db_versions.count()),
    );
    defer site_ids.deinit(alloc);
    for (since_db_versions.keys()) |site_id|
        site_ids.putAssumeCapacity(site_id, {});
    for (until_db_versions.keys()) |site_id|
        site_ids.putAssumeCapacity(site_id, {});

    var site_ids_iter = site_ids.keyIterator();
    while (site_ids_iter.next()) |site_id| {
        stmt.reset();

        var stmt_iter = try stmt.iteratorAlloc(T, alloc, .{
            .since_db_version = since_db_versions.get(site_id.*) orelse 0,
            .until_db_version = until_db_versions.get(site_id.*) orelse std.math.maxInt(u64),
            .site_id = sqlite.Blob{ .data = site_id },
        });
        while (try stmt_iter.nextAlloc(alloc, .{ .diags = &diags })) |change| {
            try changes.append(alloc, change);
            switch (change.op) {
                .insert => inserts += 1,
                .delete => deletes += 1,
                .update => updates += 1,
            }
        }
    }

    return .{
        .changes = try changes.toOwnedSlice(alloc),
        .inserts = inserts,
        .deletes = deletes,
        .updates = updates,
    };
}

pub fn getConceptChanges(
    db: *Db,
    since_db_versions: *const crdt.DbVersionsMap,
    until_db_versions: *const crdt.DbVersionsMap,
    alloc: Allocator,
) !ConceptChanges {
    const query =
        \\WITH changed_keys AS (
        \\    SELECT
        \\        clk.key,
        \\        MIN(clk.db_version) AS min_db_version,
        \\        MAX(clk.db_version) AS max_db_version
        \\    FROM concept__crsql_clock clk
        \\    JOIN crsql_site_id s ON s.ordinal = clk.site_id
        \\    WHERE s.site_id = :site_id
        \\      AND clk.db_version >  :since_db_version
        \\      AND clk.db_version <= :until_db_version
        \\    GROUP BY clk.key
        \\)
        \\SELECT
        \\    pks.id,
        \\    c.name,
        \\    CASE
        \\        WHEN c.id IS NULL THEN 2 -- delete
        \\        WHEN ck.min_db_version > :since_db_version THEN 0 -- insert
        \\        ELSE 1 -- update
        \\    END AS op,
        \\    ck.max_db_version AS db_version,
        \\    :site_id AS site_id
        \\FROM changed_keys ck
        \\JOIN concept__crsql_pks pks ON pks.__crsql_key = ck.key
        \\LEFT JOIN concept c ON c.id = pks.id;
    ;
    return try queryChanges(ConceptChange, db, query, since_db_versions, until_db_versions, alloc);
}

pub fn getRelationChanges(
    db: *Db,
    since_db_versions: *const crdt.DbVersionsMap,
    until_db_versions: *const crdt.DbVersionsMap,
    alloc: Allocator,
) !RelationChanges {
    const query =
        \\WITH changed_keys AS (
        \\    SELECT
        \\        clk.key,
        \\        MAX(clk.db_version) AS db_version
        \\    FROM concept_rel__crsql_clock clk
        \\    JOIN crsql_site_id s ON s.ordinal = clk.site_id
        \\    WHERE s.site_id = :site_id
        \\      AND clk.db_version > :since_db_version
        \\      AND clk.db_version <= :until_db_version
        \\    GROUP BY clk.key
        \\)
        \\SELECT
        \\    pks.parent_id,
        \\    pks.child_id,
        \\    CASE
        \\        WHEN r.parent_id IS NULL THEN 2 -- delete
        \\        ELSE 0                          -- insert
        \\    END AS op,
        \\    ck.db_version AS db_version,
        \\    :site_id AS site_id
        \\FROM changed_keys ck
        \\JOIN concept_rel__crsql_pks pks ON pks.__crsql_key = ck.key
        \\LEFT JOIN concept_rel r
        \\    ON  r.parent_id = pks.parent_id
        \\    AND r.child_id = pks.child_id;
    ;
    return try queryChanges(RelationChange, db, query, since_db_versions, until_db_versions, alloc);
}

pub const Change = union(enum) {
    concept: ConceptChange,
    relation: RelationChange,
};

pub const Changes = struct {
    concepts: ConceptChanges,
    relations: RelationChanges,
};

pub fn getChanges(
    db: *Db,
    since_db_versions: *const crdt.DbVersionsMap,
    until_db_versions: *const crdt.DbVersionsMap,
    alloc: Allocator,
) !Changes {
    return .{
        .concepts = try getConceptChanges(db, since_db_versions, until_db_versions, alloc),
        .relations = try getRelationChanges(db, since_db_versions, until_db_versions, alloc),
    };
}

// ** Graph

pub fn fillAncestorGraph(core: *Core, graph: *Graph, alloc: Allocator, concept: *Concept) !void {
    var ids: std.ArrayList(Uuid) = .empty;
    defer ids.deinit(alloc);

    graph.addNode(concept.id.int, concept.name) catch |err| {
        log.err("Failed to add concept node ({t})", .{err});
        return err;
    };
    try ids.append(alloc, concept.id);
    const ancestors = getAncestors(core, alloc, .{ .ids = &.{concept.id} }) catch |err| {
        log.err("Failed to get ancestors ({t})", .{err});
        return err;
    };
    defer alloc.free(ancestors);
    for (ancestors) |*ancestor| {
        graph.addNode(ancestor.id.int, ancestor.name) catch |err| {
            log.err("Failed to add concept node ({t})", .{err});
            return err;
        };
        try ids.append(alloc, ancestor.id);
    }

    const relations = try getRelations(core, alloc, ids.items);
    defer alloc.free(relations);
    for (relations) |*relation| {
        graph.addEdge(relation.parent_id.int, relation.child_id.int) catch |err| {
            log.err("Failed to add concept edge ({t})", .{err});
            return err;
        };
    }
}

pub fn fillFullGraph(core: *Core, graph: *Graph, arena: Allocator, all_concepts: ?[]Concept) !void {
    const concepts = all_concepts orelse try getAll(core, arena);
    for (concepts) |*concept| {
        graph.addNode(concept.id.int, concept.name) catch |err| {
            log.err("Failed to add concept node ({t})", .{err});
            return err;
        };
    }
    const relations = try getRelations(core, arena, null);
    for (relations) |*relation| {
        graph.addEdge(relation.parent_id.int, relation.child_id.int) catch |err| {
            log.err("Failed to add concept edge ({t})", .{err});
            return err;
        };
    }
}

// ** Tests

// Note on SQLite error handling & tests:
// When an SQLite statement fails (e.g. trigger raises an error on cycle/redundancy),
// SQLite's C API leaves the statement in an error state. If `sqlite3_finalize`
// is subsequently called without resetting the statement first, it returns the error code
// of that failed step, causing `zig-sqlite`'s `deinit()` to log an error via `std.log.err`.
// In Zig's test runner, logged errors are treated as test failures. To prevent false positive
// test failures, statements in `Core.zig` reset their SQLite C statement handle before deiniting.

fn createTestCore(t: *std.testing.TmpDir) !Core {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try t.dir.realPath(std.testing.io, &path_buf);
    const real_path = path_buf[0..len];

    var diags: Diagnostics = .{};
    const core = Core.create(std.testing.allocator, std.testing.io, real_path, .{
        .sqlite_diagnostics = &diags,
    }) catch |err| {
        if (diags.err) |sqlite_err| {
            std.debug.print("SQLITE INIT ERROR: {s}\n", .{sqlite_err.message});
        }
        return err;
    };
    return core;
}

test "concept: basic creation and retrieval" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var core = try createTestCore(&tmp);
    defer core.destroy();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var diags: Diagnostics = .{};
    const c1_id = try add(&core, "Math", &.{}, .{ .diags = &diags });
    const c2_id = try add(&core, "Physics", &.{}, .{ .diags = &diags });

    const all = try getAll(&core, alloc, .{ .diags = &diags });
    try std.testing.expectEqual(@as(usize, 2), all.len);

    const fetched = try getByIds(&core, alloc, &.{ c1_id, c2_id }, .{ .diags = &diags });
    try std.testing.expectEqual(@as(usize, 2), fetched.len);
}

test "concept: prevent self loop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var core = try createTestCore(&tmp);
    defer core.destroy();

    var diags: Diagnostics = .{};
    const c1_id = try add(&core, "Math", &.{}, .{ .diags = &diags });

    // Adding self as parent should fail due to CHECK (parent_id != child_id)
    const err = addParent(&core, c1_id, c1_id, .{ .diags = &diags });
    try std.testing.expectError(error.SQLiteConstraint, err);
}

test "concept: prevent 2-node cycle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var core = try createTestCore(&tmp);
    defer core.destroy();

    var diags: Diagnostics = .{};
    const a = try add(&core, "A", &.{}, .{ .diags = &diags });
    const b = try add(&core, "B", &.{a}, .{ .diags = &diags }); // A -> B (A is parent of B)

    // Attempting B -> A should fail (cycle)
    const err = addParent(&core, a, b, .{ .diags = &diags });
    try std.testing.expectError(error.SQLiteConstraint, err);
}

test "concept: prevent multi-node cycle (A -> B -> C, then C -> A)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var core = try createTestCore(&tmp);
    defer core.destroy();

    var diags: Diagnostics = .{};
    const a = try add(&core, "A", &.{}, .{ .diags = &diags });
    const b = try add(&core, "B", &.{a}, .{ .diags = &diags }); // A -> B
    const c = try add(&core, "C", &.{b}, .{ .diags = &diags }); // B -> C

    // Attempting C -> A should fail (cycle: A -> B -> C -> A)
    const err = addParent(&core, a, c, .{ .diags = &diags });
    try std.testing.expectError(error.SQLiteConstraint, err);
}

test "concept: prevent redundant edge insertion (A -> B -> C, then A -> C)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var core = try createTestCore(&tmp);
    defer core.destroy();

    var diags: Diagnostics = .{};
    const a = try add(&core, "A", &.{}, .{ .diags = &diags });
    const b = try add(&core, "B", &.{a}, .{ .diags = &diags }); // A -> B
    const c = try add(&core, "C", &.{b}, .{ .diags = &diags }); // B -> C

    // Attempting A -> C should fail because A is already an indirect ancestor of C
    const err = addParent(&core, c, a, .{ .diags = &diags });
    try std.testing.expectError(error.SQLiteConstraint, err);
}

test "concept: transitive reduction prunes shortcut edge after insertion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var core = try createTestCore(&tmp);
    defer core.destroy();

    var diags: Diagnostics = .{};
    // 1. Create A -> C and A -> B
    const a = try add(&core, "A", &.{}, .{ .diags = &diags });
    const c = try add(&core, "C", &.{a}, .{ .diags = &diags }); // A -> C
    const b = try add(&core, "B", &.{a}, .{ .diags = &diags }); // A -> B

    // 2. Now add B -> C. This should automatically prune the direct shortcut edge A -> C
    try addParent(&core, c, b, .{ .diags = &diags });

    // Verify relations in concept_rel
    var stmt = try core.db.prepareWithDiags(
        "SELECT COUNT(*) FROM concept_rel WHERE parent_id = ? AND child_id = ?",
        .{ .diags = &diags },
    );
    defer stmt.deinit();

    // A -> C should no longer exist
    const count_ac = try stmt.one(usize, .{}, .{
        .parent = a.asBlob(),
        .child = c.asBlob(),
    });
    try std.testing.expectEqual(@as(?usize, 0), count_ac);

    // A -> B should exist
    stmt.reset();
    const count_ab = try stmt.one(usize, .{}, .{
        .parent = a.asBlob(),
        .child = b.asBlob(),
    });
    try std.testing.expectEqual(@as(?usize, 1), count_ab);

    // B -> C should exist
    stmt.reset();
    const count_bc = try stmt.one(usize, .{}, .{
        .parent = b.asBlob(),
        .child = c.asBlob(),
    });
    try std.testing.expectEqual(@as(?usize, 1), count_bc);
}

test "concept: getAncestors hierarchy and direct parents" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var core = try createTestCore(&tmp);
    defer core.destroy();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var diags: Diagnostics = .{};
    // Hierarchy: A -> B -> C -> D
    // and        E -> C
    const a = try add(&core, "A", &.{}, .{ .diags = &diags });
    const b = try add(&core, "B", &.{a}, .{ .diags = &diags });
    const e = try add(&core, "E", &.{}, .{ .diags = &diags });
    const c = try add(&core, "C", &.{ b, e }, .{ .diags = &diags });
    const d = try add(&core, "D", &.{c}, .{ .diags = &diags });

    // 1. Direct parents of D: only C
    {
        const direct_d = try getAncestors(&core, alloc, &.{d}, true, .{ .diags = &diags });
        try std.testing.expectEqual(@as(usize, 1), direct_d.len);
        try std.testing.expectEqual(c.uuid, direct_d[0].id.uuid);
        try std.testing.expectEqualStrings("C", direct_d[0].name);
        try std.testing.expectEqual(d.uuid, direct_d[0].child_id.uuid);
        try std.testing.expectEqual(@as(usize, 1), direct_d[0].depth);
        try std.testing.expect(direct_d[0].is_direct);
    }

    // 2. Full hierarchy of D: C (direct, depth 1), B & E (depth 2), A (depth 3)
    {
        const all_d = try getAncestors(&core, alloc, &.{d}, false, .{ .diags = &diags });
        try std.testing.expectEqual(@as(usize, 4), all_d.len);

        // Find C (direct parent)
        var found_c: ?ConceptAncestor = null;
        var found_b: ?ConceptAncestor = null;
        var found_e: ?ConceptAncestor = null;
        var found_a: ?ConceptAncestor = null;

        for (all_d) |anc| {
            if (anc.id.uuid == c.uuid) found_c = anc;
            if (anc.id.uuid == b.uuid) found_b = anc;
            if (anc.id.uuid == e.uuid) found_e = anc;
            if (anc.id.uuid == a.uuid) found_a = anc;
        }

        try std.testing.expect(found_c != null);
        try std.testing.expect(found_c.?.is_direct);
        try std.testing.expectEqual(@as(usize, 1), found_c.?.depth);

        try std.testing.expect(found_b != null);
        try std.testing.expect(!found_b.?.is_direct);
        try std.testing.expectEqual(@as(usize, 2), found_b.?.depth);

        try std.testing.expect(found_e != null);
        try std.testing.expect(!found_e.?.is_direct);
        try std.testing.expectEqual(@as(usize, 2), found_e.?.depth);

        try std.testing.expect(found_a != null);
        try std.testing.expect(!found_a.?.is_direct);
        try std.testing.expectEqual(@as(usize, 3), found_a.?.depth);
    }

    // 3. Multi-concept query: ancestors of C and D simultaneously
    {
        const multi = try getAncestors(&core, alloc, &.{ c, d }, true, .{ .diags = &diags });
        // Direct parents of C are B and E (2 parents)
        // Direct parent of D is C (1 parent)
        // Total = 3
        try std.testing.expectEqual(@as(usize, 3), multi.len);
    }
}
