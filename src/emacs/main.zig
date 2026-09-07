const std = @import("std");
var io = std.Io.Threaded.init_single_threaded;

const Core = @import("core").Core;
const sqlite = @import("sqlite");

const emacs = @import("emacs.zig");
const Context = emacs.Context;
const c = emacs.c;

pub export var plugin_is_GPL_compatible: c_int = 1;
/// Functions that will be available to emacs
const Funcs = struct {
    pub fn init(ctx: *Context, data_dir: []const u8) !*Core {
        var diags: sqlite.Diagnostics = .{};
        const options: Core.Options = .{ .data_dir = data_dir, .sqlite_diagnostics = &diags };
        const allocator = std.heap.c_allocator;
        const core = Core.init(allocator, io.io(), options) catch |err| {
            if (diags.err) |sqlite_err| {
                ctx.setError("Failed to init: {t}: {s}", .{ err, sqlite_err.message });
            } else {
                ctx.setError("Failed to init: {t}", .{err});
            }
            return error.InitFailed;
        };
        return core;
    }

    pub fn isValid(_: *Context, core: *Core) bool {
        return core.isValid();
    }

    pub fn newId(_: *Context, core: *Core) Core.IdStr {
        var id = core.newId();
        return id.serialize();
    }

    pub fn addConcept(ctx: *Context, core: *Core, name: []u8, parent_ids: []Core.Id) !Core.IdStr {
        var diags: sqlite.Diagnostics = .{};
        var id = core.addConcept(name, parent_ids, &diags) catch |err| {
            if (diags.err) |sqlite_err| {
                ctx.setError("Sqlite error: {s}", .{ sqlite_err.message });
            } else {
                ctx.setError("Failed to add concept: {t}", .{err});
            }
            return err;
        };
        return id.serialize();
    }

    pub fn addConceptParent(ctx: *Context, core: *Core, child_id: Core.Id, parent_id: Core.Id) !void {
        var diags: sqlite.Diagnostics = .{};
        core.addConceptParent(child_id, parent_id, &diags) catch |err| {
            if (diags.err) |sqlite_err| {
                ctx.setError("Sqlite error: {s}", .{ sqlite_err.message });
            } else {
                ctx.setError("Failed to add concept parent: {t}", .{err});
            }
            return err;
        };
    }

    pub fn removeConceptParent(ctx: *Context, core: *Core, child_id: Core.Id, parent_id: Core.Id) !void {
        var diags: sqlite.Diagnostics = .{};
        core.removeConceptParent(child_id, parent_id, &diags) catch |err| {
            if (diags.err) |sqlite_err| {
                ctx.setError("Sqlite error: {s}", .{ sqlite_err.message });
            } else {
                ctx.setError("Failed to remove concept parent: {t}", .{err});
            }
            return err;
        };
    }

    pub fn getAllConcepts(ctx: *Context, core: *Core) ![]Core.Concept {
        var arena = std.heap.ArenaAllocator.init(core.allocator);
        defer arena.deinit();
        var diags: sqlite.Diagnostics = .{};
        const concepts = core.getAllConcepts(arena.allocator(), &diags) catch |err| {
            if (diags.err) |sqlite_err| {
                ctx.setError("Sqlite error: {s}", .{ sqlite_err.message });
            } else {
                ctx.setError("Failed to get concepts: {t}", .{err});
            }
            return err;
        };
        return concepts;
    }

    pub fn getConceptsById(ctx: *Context, core: *Core, ids: []Core.Id) ![]Core.Concept {
        var arena = std.heap.ArenaAllocator.init(core.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var diags: sqlite.Diagnostics = .{};
        const concepts = core.getConceptsById(allocator, ids, &diags) catch |err| {
            if (diags.err) |sqlite_err| {
                ctx.setError("Sqlite error: {s}", .{ sqlite_err.message });
            } else {
                ctx.setError("Failed to get concepts: {t}", .{err});
            }
            return err;
        };
        emacs.message(ctx.env, "Found {d} ids and {d} concepts", .{ ids.len, concepts.len });
        return concepts;
    }

    pub fn getAncestors(ctx: *Context, core: *Core, ids: []Core.Id, direct_only: bool) ![]Core.ConceptAncestor {
        var arena = std.heap.ArenaAllocator.init(core.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var diags: sqlite.Diagnostics = .{};
        const ancestors = core.getAncestors(allocator, ids, direct_only, &diags) catch |err| {
            if (diags.err) |sqlite_err| {
                ctx.setError("Sqlite error: {s}", .{ sqlite_err.message });
            } else {
                ctx.setError("Failed to get ancestors: {t}", .{err});
            }
            return err;
        };
        return ancestors;
    }
};

export fn emacs_module_init(rt: [*c]c.emacs_runtime) c_int {
    const env = rt.*.get_environment.?(rt);

    emacs.registerFunc(env, "ilm--core-init", Funcs.init, "Initialize ilm core and return state");
    emacs.registerFunc(env, "ilm--core-is-valid", Funcs.isValid, "Return t if core in valid state");
    emacs.registerFunc(env, "ilm--core-new-id", Funcs.newId, "Generate a new UUID");
    emacs.registerFunc(env, "ilm--core-add-concept", Funcs.addConcept, "Add new concept, return id");
    emacs.registerFunc(env, "ilm--core-add-concept-parent", Funcs.addConceptParent, "Assign a parent to a concept");
    emacs.registerFunc(env, "ilm--core-remove-concept-parent", Funcs.removeConceptParent, "Unassign a parent from a concept");
    emacs.registerFunc(env, "ilm--core-all-concepts", Funcs.getAllConcepts, "Get all concepts");
    emacs.registerFunc(env, "ilm--core-concepts-by-id", Funcs.getConceptsById, "Get concepts by IDs");
    emacs.registerFunc(env, "ilm--core-ancestors", Funcs.getAncestors, "Get ancestory of concepts");

    return 0;
}
