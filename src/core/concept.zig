const std = @import("std");
const Core = @import("Core.zig");
const sqlite = @import("sqlite");
const Id = @import("database.zig").Id;

pub const Concept = struct {
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

pub const Options = struct {
    diags: ?*sqlite.Diagnostics = null,
};

pub fn add(core: *Core, name: []const u8, parent_ids: []const Id, opts: Options) !Id {
    var savepoint = try core.db.savepoint("addconcept");
    defer savepoint.rollback();
    const id = core.newId();
    const id_blob = id.asBlob();

    {
        var stmt = try core.db.prepareWithDiags("INSERT INTO concept(id, name) VALUES (?, ?)", .{ .diags = opts.diags });
        defer {
            _ = sqlite.c.sqlite3_reset(stmt.dynamic_stmt.stmt);
            stmt.deinit();
        }
        try stmt.exec(.{ .diags = opts.diags }, .{ .id = id_blob, .name = name });
    }

    {
        var stmt = try core.db.prepareWithDiags("INSERT INTO concept_rel(parent_id, child_id) VALUES (?, ?)", .{ .diags = opts.diags });
        defer {
            _ = sqlite.c.sqlite3_reset(stmt.dynamic_stmt.stmt);
            stmt.deinit();
        }
        for (parent_ids) |*parent_id| {
            stmt.reset();
            try stmt.exec(.{ .diags = opts.diags }, .{ .parent_id = parent_id.asBlob(), .child_id = id_blob });
        }
    }

    savepoint.commit();

    return id;
}

pub fn addParent(core: *Core, child_id: Id, parent_id: Id, opts: Options) !void {
    var stmt = try core.db.prepareWithDiags("INSERT OR IGNORE INTO concept_rel(parent_id, child_id) VALUES (?, ?)", .{ .diags = opts.diags });
    defer {
        _ = sqlite.c.sqlite3_reset(stmt.dynamic_stmt.stmt);
        stmt.deinit();
    }
    try stmt.exec(.{ .diags = opts.diags }, .{ .parent_id = parent_id.asBlob(), .child_id = child_id.asBlob() });
}

pub fn removeParent(core: *Core, child_id: Id, parent_id: Id, opts: Options) !void {
    var stmt = try core.db.prepareWithDiags("DELETE FROM concept_rel WHERE parent_id = ? AND child_id = ?", .{ .diags = opts.diags });
    defer {
        _ = sqlite.c.sqlite3_reset(stmt.dynamic_stmt.stmt);
        stmt.deinit();
    }
    try stmt.exec(.{ .diags = opts.diags }, .{ .parent_id = parent_id.asBlob(), .child_id = child_id.asBlob() });
}

pub fn getAll(core: *Core, allocator: std.mem.Allocator, opts: Options) ![]Concept {
    var stmt = try core.db.prepareWithDiags("SELECT id, name FROM concept ORDER BY name", .{ .diags = opts.diags });
    defer stmt.deinit();

    var iter = try stmt.iteratorAlloc(Concept, allocator, .{});
    var rows: std.ArrayList(Concept) = .empty;
    defer rows.deinit(allocator);
    while (try iter.nextAlloc(allocator, .{ .diags = opts.diags })) |row| {
        try rows.append(allocator, row);
    }
    const result = try rows.toOwnedSlice(allocator);

    return result;
}

pub fn getById(core: *Core, allocator: std.mem.Allocator, ids: []const Id, opts: Options) ![]Concept {
    if (ids.len == 0) return &.{};

    var query_builder: std.ArrayList(u8) = .empty;
    defer query_builder.deinit(allocator);
    try query_builder.appendSlice(allocator, "SELECT id, name FROM concept WHERE id IN (");
    for (0..ids.len) |i| {
        if (i > 0) try query_builder.appendSlice(allocator, ", ");
        try query_builder.appendSlice(allocator, "?");
    }
    try query_builder.appendSlice(allocator, ")");

    const query: []const u8 = query_builder.items;
    var stmt = try core.db.prepareDynamicWithDiags(query, .{ .diags = opts.diags });
    defer stmt.deinit();

    var iter = try stmt.iteratorAlloc(Concept, allocator, ids);
    var rows: std.ArrayList(Concept) = .empty;
    defer rows.deinit(allocator);
    while (try iter.nextAlloc(allocator, .{ .diags = opts.diags })) |row| {
        try rows.append(allocator, row);
    }
    const result = try rows.toOwnedSlice(allocator);

    return result;
}

/// Retrieve the hierarchy of ancestors for a set of concepts.
///
/// If `direct_only` is true, only returns immediate parents (depth = 1).
/// Otherwise, returns the entire transitive ancestry with minimum depth and an
/// `is_direct` flag.
///
/// NOTE: Direct parents (depth = 1) will be included even if marked as redundant
/// in `concept_rel`.
pub fn getAncestors(core: *Core, allocator: std.mem.Allocator, ids: []const Id, direct_only: bool, opts: Options) ![]ConceptAncestor {
    if (ids.len == 0) return &.{};

    var query_builder: std.ArrayList(u8) = .empty;
    defer query_builder.deinit(allocator);

    if (direct_only) {
        try query_builder.appendSlice(allocator,
            \\SELECT c.id, c.name, cr.child_id, 1 AS depth, 1 AS is_direct
            \\FROM concept_rel cr
            \\JOIN concept c ON cr.parent_id = c.id
            \\WHERE cr.child_id IN (
        );
        for (0..ids.len) |i| {
            if (i > 0) try query_builder.appendSlice(allocator, ", ");
            try query_builder.appendSlice(allocator, "?");
        }
        try query_builder.appendSlice(allocator,
            \\)
            \\ORDER BY cr.child_id, c.name
        );
    } else {
        try query_builder.appendSlice(allocator,
            \\WITH RECURSIVE ancestors(id, child_id, depth) AS (
            \\    SELECT parent_id, child_id, 1
            \\    FROM concept_rel
            \\    WHERE child_id IN (
        );
        for (0..ids.len) |i| {
            if (i > 0) try query_builder.appendSlice(allocator, ", ");
            try query_builder.appendSlice(allocator, "?");
        }
        try query_builder.appendSlice(allocator,
            \\    )
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
    var stmt = try core.db.prepareDynamicWithDiags(query, .{ .diags = opts.diags });
    defer stmt.deinit();

    var iter = try stmt.iteratorAlloc(ConceptAncestor, allocator, ids);
    var rows: std.ArrayList(ConceptAncestor) = .empty;
    defer rows.deinit(allocator);
    while (try iter.nextAlloc(allocator, .{ .diags = opts.diags })) |row| {
        try rows.append(allocator, row);
    }
    const result = try rows.toOwnedSlice(allocator);

    return result;
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

    const fetched = try getById(&core, alloc, &.{ c1_id, c2_id }, .{ .diags = &diags });
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
