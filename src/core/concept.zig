const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.concept);
const Core = @import("Core.zig");
const sqlite = @import("sqlite");
const Id = @import("database.zig").Id;
const Graph = @import("graphviz").Graph;

pub const Concept = struct {
    rowid: i64,
    id: Id,
    name: []const u8,
};

pub const ConceptAncestor = struct {
    id: Id,
    name: []const u8,
    child_id: Id,
    depth: usize,
    is_direct: bool,
};

// ** DB operations

pub fn add(core: *Core, name: []const u8, parent_ids: []const Id) !Id {
    var diags: sqlite.Diagnostics = .{};

    var savepoint = try core.db.savepoint("addconcept");
    defer savepoint.rollback();
    const id = core.newId();
    const id_blob = id.asBlob();

    {
        var stmt = core.db.prepareWithDiags(
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
        var stmt = core.db.prepareWithDiags(
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

    return id;
}

// TODO Validate that rename actually happened (in case concept not found in db)
pub fn rename(core: *Core, id: Id, name: []const u8) !void {
    var diags: sqlite.Diagnostics = .{};

    var stmt = core.db.prepareWithDiags(
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

// TODO Validate that delete actually happened (in case concept not found in db)
pub fn delete(core: *Core, id: Id) !void {
    var diags: sqlite.Diagnostics = .{};
    var savepoint = try core.db.savepoint("delconcept");
    defer savepoint.rollback();

    // Delete the relationship first. Otherwise inbetween there will
    // conceptid in concept_rel of a concept that doesnt exist. This
    // is a problem because of the sqlite update hook, which reacts
    // immediately.
    {
        var stmt = core.db.prepareWithDiags(
            \\DELETE FROM concept_rel
            \\WHERE parent_id = ? OR child_id = ?
        , .{ .diags = &diags }) catch |err| {
            log.err("SQLite prepare failed: {s}", .{diags.message});
            return err;
        };
        defer stmt.deinit();

        stmt.exec(
            .{ .diags = &diags },
            .{ id.asBlob(), id.asBlob() },
        ) catch |err| {
            log.err("SQLite exec failed: {s}", .{diags.message});
            return err;
        };
    }

    {
        var stmt = core.db.prepareWithDiags(
            \\DELETE FROM concept
            \\WHERE id = ?
        , .{ .diags = &diags }) catch |err| {
            log.err("SQLite prepare failed: {s}", .{diags.message});
            return err;
        };
        defer stmt.deinit();

        stmt.exec(
            .{ .diags = &diags },
            .{ .id = id.asBlob() },
        ) catch |err| {
            log.err("SQLite exec failed: {s}", .{diags.message});
            return err;
        };
    }

    savepoint.commit();
}

pub fn addParent(core: *Core, child_id: Id, parent_id: Id) !void {
    var diags: sqlite.Diagnostics = .{};
    var stmt = try core.db.prepareWithDiags(
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

pub fn removeParent(core: *Core, child_id: Id, parent_id: Id) !void {
    var diags: sqlite.Diagnostics = .{};
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
    var diags: sqlite.Diagnostics = .{};
    var iter = try stmt.iteratorAlloc(Concept, alloc, values);
    var rows: std.ArrayList(Concept) = .empty;
    defer rows.deinit(alloc);
    while (try iter.nextAlloc(alloc, .{ .diags = &diags })) |row| {
        try rows.append(alloc, row);
    }
    return try rows.toOwnedSlice(alloc);
}

pub fn getAll(core: *Core, alloc: Allocator) ![]Concept {
    var diags: sqlite.Diagnostics = .{};
    var stmt = try core.db.prepareWithDiags(
        // "SELECT id, name FROM concept ORDER BY name",
        "SELECT rowid, id, name FROM concept",
        .{ .diags = &diags },
    );
    defer stmt.deinit();
    return try queryConcepts(alloc, &stmt, .{});
}

pub fn getById(core: *Core, alloc: Allocator, id: Id) !?Concept {
    var diags: sqlite.Diagnostics = .{};
    var stmt = try core.db.prepareWithDiags(
        "SELECT rowid, id, name FROM concept WHERE id = ?",
        .{ .diags = &diags },
    );
    defer stmt.deinit();
    return try stmt.oneAlloc(Concept, alloc, .{ .diags = &diags }, .{id});
}

pub fn getByIds(core: *Core, alloc: Allocator, ids: []const Id) ![]Concept {
    if (ids.len == 0) return &.{};

    var arena_alloc: std.heap.ArenaAllocator = .init(alloc);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    var query_builder: std.ArrayList(u8) = .empty;
    defer query_builder.deinit(arena);
    try query_builder.appendSlice(arena, "SELECT rowid, id, name FROM concept WHERE id IN (");
    for (0..ids.len) |i| {
        if (i > 0) try query_builder.appendSlice(arena, ", ");
        try query_builder.appendSlice(arena, "?");
    }
    try query_builder.appendSlice(arena, ")");
    const query: []const u8 = query_builder.items;

    var diags: sqlite.Diagnostics = .{};
    var stmt = try core.db.prepareDynamicWithDiags(query, .{ .diags = &diags });
    defer stmt.deinit();

    return try queryConcepts(alloc, &stmt, ids);
}

pub fn getByNameMatch(core: *Core, alloc: Allocator, substr: []const u8) ![]Concept {
    const query =
        \\SELECT rowid, id, name
        \\FROM concept
        \\WHERE instr(name, ?) > 0
    ;
    var diags: sqlite.Diagnostics = .{};
    var stmt = try core.db.prepareWithDiags(query, .{ .diags = &diags });
    defer stmt.deinit();
    return try queryConcepts(alloc, &stmt, .{substr});
}

pub fn getIdByRowId(core: *Core, rowid: i64) !?Id {
    if (try core.db.one(Id.ByteT, "SELECT id FROM concept WHERE rowid = ?", .{}, .{rowid})) |id_bytes| {
        return .{ .uuid = @bitCast(id_bytes) };
    }
    return null;
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
        ids: ?[]const Id = null,
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

    var diags: sqlite.Diagnostics = .{};
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
        \\SELECT c.rowid, c.id, c.name
        \\FROM concept c
        \\WHERE NOT EXISTS (
        \\    SELECT 1 FROM concept_rel cr WHERE cr.child_id = c.id
        \\)
        \\ORDER BY c.name
    ;

    var diags: sqlite.Diagnostics = .{};
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
    parent_id: Id,
    child_id: Id,
};

pub fn getRelations(core: *Core, alloc: Allocator, ids: ?[]const Id) ![]Relation {
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

    var diags: sqlite.Diagnostics = .{};
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

// ** Graph

pub fn fillAncestorGraph(core: *Core, graph: *Graph, alloc: Allocator, concept: *Concept) !void {
    var ids: std.ArrayList(Id) = .empty;
    defer ids.deinit(alloc);

    graph.addNode(concept.id.uuid, concept.name) catch |err| {
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
        graph.addNode(ancestor.id.uuid, ancestor.name) catch |err| {
            log.err("Failed to add concept node ({t})", .{err});
            return err;
        };
        try ids.append(alloc, ancestor.id);
    }

    const relations = try getRelations(core, alloc, ids.items);
    defer alloc.free(relations);
    for (relations) |*relation| {
        graph.addEdge(relation.parent_id.uuid, relation.child_id.uuid) catch |err| {
            log.err("Failed to add concept edge ({t})", .{err});
            return err;
        };
    }
}

pub fn fillFullGraph(core: *Core, graph: *Graph, arena: Allocator, all_concepts: ?[]Concept) !void {
    const concepts = all_concepts orelse try getAll(core, arena);
    for (concepts) |*concept| {
        graph.addNode(concept.id.uuid, concept.name) catch |err| {
            log.err("Failed to add concept node ({t})", .{err});
            return err;
        };
    }
    const relations = try getRelations(core, arena, null);
    for (relations) |*relation| {
        graph.addEdge(relation.parent_id.uuid, relation.child_id.uuid) catch |err| {
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

    var diags: sqlite.Diagnostics = .{};
    const core = Core.init(std.testing.allocator, std.testing.io, real_path, .{
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
    defer core.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var diags: sqlite.Diagnostics = .{};
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
    defer core.deinit();

    var diags: sqlite.Diagnostics = .{};
    const c1_id = try add(&core, "Math", &.{}, .{ .diags = &diags });

    // Adding self as parent should fail due to CHECK (parent_id != child_id)
    const err = addParent(&core, c1_id, c1_id, .{ .diags = &diags });
    try std.testing.expectError(error.SQLiteConstraint, err);
}

test "concept: prevent 2-node cycle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var core = try createTestCore(&tmp);
    defer core.deinit();

    var diags: sqlite.Diagnostics = .{};
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
    defer core.deinit();

    var diags: sqlite.Diagnostics = .{};
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
    defer core.deinit();

    var diags: sqlite.Diagnostics = .{};
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
    defer core.deinit();

    var diags: sqlite.Diagnostics = .{};
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
    defer core.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var diags: sqlite.Diagnostics = .{};
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
