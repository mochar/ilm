const std = @import("std");
const Core = @import("Core.zig");
const sqlite = @import("sqlite");

// Note on SQLite error handling & tests:
// When an SQLite statement fails (e.g. trigger raises an error on cycle/redundancy),
// SQLite's C API leaves the statement in an error state. If `sqlite3_finalize`
// is subsequently called without resetting the statement first, it returns the error code
// of that failed step, causing `zig-sqlite`'s `deinit()` to log an error via `std.log.err`.
// In Zig's test runner, logged errors are treated as test failures. To prevent false positive
// test failures, statements in `Core.zig` reset their SQLite C statement handle before deiniting.

fn createTestCore(t: *std.testing.TmpDir) !*Core {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try t.dir.realPath(std.testing.io, &path_buf);
    const real_path = path_buf[0..len];

    var diags: sqlite.Diagnostics = .{};
    const core = Core.init(std.testing.allocator, std.testing.io, .{
        .data_dir = real_path,
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

    const core = try createTestCore(&tmp);
    defer core.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var diags: sqlite.Diagnostics = .{};
    const c1_id = try core.addConcept("Math", &.{}, &diags);
    const c2_id = try core.addConcept("Physics", &.{}, &diags);

    const all = try core.getAllConcepts(alloc, &diags);
    try std.testing.expectEqual(@as(usize, 2), all.len);

    const fetched = try core.getConceptsById(alloc, &.{ c1_id, c2_id }, &diags);
    try std.testing.expectEqual(@as(usize, 2), fetched.len);
}

test "concept: prevent self loop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const core = try createTestCore(&tmp);
    defer core.deinit();

    var diags: sqlite.Diagnostics = .{};
    const c1_id = try core.addConcept("Math", &.{}, &diags);

    // Adding self as parent should fail due to CHECK (parent_id != child_id)
    const err = core.addConceptParent(c1_id, c1_id, &diags);
    try std.testing.expectError(error.SQLiteConstraint, err);
}

test "concept: prevent 2-node cycle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const core = try createTestCore(&tmp);
    defer core.deinit();

    var diags: sqlite.Diagnostics = .{};
    const a = try core.addConcept("A", &.{}, &diags);
    const b = try core.addConcept("B", &.{a}, &diags); // A -> B (A is parent of B)

    // Attempting B -> A should fail (cycle)
    const err = core.addConceptParent(a, b, &diags);
    try std.testing.expectError(error.SQLiteConstraint, err);
}

test "concept: prevent multi-node cycle (A -> B -> C, then C -> A)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const core = try createTestCore(&tmp);
    defer core.deinit();

    var diags: sqlite.Diagnostics = .{};
    const a = try core.addConcept("A", &.{}, &diags);
    const b = try core.addConcept("B", &.{a}, &diags); // A -> B
    const c = try core.addConcept("C", &.{b}, &diags); // B -> C

    // Attempting C -> A should fail (cycle: A -> B -> C -> A)
    const err = core.addConceptParent(a, c, &diags);
    try std.testing.expectError(error.SQLiteConstraint, err);
}

test "concept: prevent redundant edge insertion (A -> B -> C, then A -> C)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const core = try createTestCore(&tmp);
    defer core.deinit();

    var diags: sqlite.Diagnostics = .{};
    const a = try core.addConcept("A", &.{}, &diags);
    const b = try core.addConcept("B", &.{a}, &diags); // A -> B
    const c = try core.addConcept("C", &.{b}, &diags); // B -> C

    // Attempting A -> C should fail because A is already an indirect ancestor of C
    const err = core.addConceptParent(c, a, &diags);
    try std.testing.expectError(error.SQLiteConstraint, err);
}

test "concept: transitive reduction prunes shortcut edge after insertion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const core = try createTestCore(&tmp);
    defer core.deinit();

    var diags: sqlite.Diagnostics = .{};
    // 1. Create A -> C and A -> B
    const a = try core.addConcept("A", &.{}, &diags);
    const c = try core.addConcept("C", &.{a}, &diags); // A -> C
    const b = try core.addConcept("B", &.{a}, &diags); // A -> B

    // 2. Now add B -> C. This should automatically prune the direct shortcut edge A -> C
    try core.addConceptParent(c, b, &diags);

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

    const core = try createTestCore(&tmp);
    defer core.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var diags: sqlite.Diagnostics = .{};
    // Hierarchy: A -> B -> C -> D
    // and        E -> C
    const a = try core.addConcept("A", &.{}, &diags);
    const b = try core.addConcept("B", &.{a}, &diags);
    const e = try core.addConcept("E", &.{}, &diags);
    const c = try core.addConcept("C", &.{ b, e }, &diags);
    const d = try core.addConcept("D", &.{c}, &diags);

    // 1. Direct parents of D: only C
    {
        const direct_d = try core.getAncestors(alloc, &.{d}, true, &diags);
        try std.testing.expectEqual(@as(usize, 1), direct_d.len);
        try std.testing.expectEqual(c.uuid, direct_d[0].id.uuid);
        try std.testing.expectEqualStrings("C", direct_d[0].name);
        try std.testing.expectEqual(d.uuid, direct_d[0].child_id.uuid);
        try std.testing.expectEqual(@as(usize, 1), direct_d[0].depth);
        try std.testing.expect(direct_d[0].is_direct);
    }

    // 2. Full hierarchy of D: C (direct, depth 1), B & E (depth 2), A (depth 3)
    {
        const all_d = try core.getAncestors(alloc, &.{d}, false, &diags);
        try std.testing.expectEqual(@as(usize, 4), all_d.len);

        // Find C (direct parent)
        var found_c: ?Core.ConceptAncestor = null;
        var found_b: ?Core.ConceptAncestor = null;
        var found_e: ?Core.ConceptAncestor = null;
        var found_a: ?Core.ConceptAncestor = null;

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
        const multi = try core.getAncestors(alloc, &.{ c, d }, true, &diags);
        // Direct parents of C are B and E (2 parents)
        // Direct parent of D is C (1 parent)
        // Total = 3
        try std.testing.expectEqual(@as(usize, 3), multi.len);
    }
}
