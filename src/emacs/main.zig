const std = @import("std");
var io = std.Io.Threaded.init_single_threaded;

const ilm = @import("ilm");
const Core = ilm.Core;
const Id = ilm.Id;
const Concept = ilm.concept.Concept;
const ConceptAncestor = ilm.concept.ConceptAncestor;
const Graph = ilm.Graph;
const sqlite = @import("sqlite");

const emacs = @import("emacs.zig");
const Context = emacs.Context;
const c = emacs.c;

pub export var plugin_is_GPL_compatible: c_int = 1;

/// Functions that will be available to emacs
const Funcs = struct {
    pub fn init(ctx: *Context, data_dir: []const u8) !*Core {
        var diags: sqlite.Diagnostics = .{};
        const allocator = std.heap.c_allocator;
        const core = Core.init(allocator, io.io(), data_dir, .{ .sqlite_diagnostics = &diags }) catch |err| {
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

    pub fn newId(_: *Context, core: *Core) Id.StrT {
        var id = core.newId();
        return id.serialize();
    }

    pub fn addConcept(ctx: *Context, core: *Core, name: []u8, parent_ids: []Id) !Id.StrT {
        var diags: sqlite.Diagnostics = .{};
        var id = ilm.concept.add(core, name, parent_ids, .{ .diags = &diags }) catch |err| {
            if (diags.err) |sqlite_err| {
                ctx.setError("Sqlite error: {s}", .{sqlite_err.message});
            } else {
                ctx.setError("Failed to add concept: {t}", .{err});
            }
            return err;
        };
        return id.serialize();
    }

    pub fn addConceptParent(ctx: *Context, core: *Core, child_id: Id, parent_id: Id) !void {
        var diags: sqlite.Diagnostics = .{};
        ilm.concept.addParent(core, child_id, parent_id, .{ .diags = &diags }) catch |err| {
            if (diags.err) |sqlite_err| {
                ctx.setError("Sqlite error: {s}", .{sqlite_err.message});
            } else {
                ctx.setError("Failed to add concept parent: {t}", .{err});
            }
            return err;
        };
    }

    pub fn removeConceptParent(ctx: *Context, core: *Core, child_id: Id, parent_id: Id) !void {
        var diags: sqlite.Diagnostics = .{};
        ilm.concept.removeParent(core, child_id, parent_id, .{ .diags = &diags }) catch |err| {
            if (diags.err) |sqlite_err| {
                ctx.setError("Sqlite error: {s}", .{sqlite_err.message});
            } else {
                ctx.setError("Failed to remove concept parent: {t}", .{err});
            }
            return err;
        };
    }

    pub fn getAllConcepts(ctx: *Context, core: *Core) ![]Concept {
        var diags: sqlite.Diagnostics = .{};
        const concepts = ilm.concept.getAll(core, ctx.arena, .{ .diags = &diags }) catch |err| {
            if (diags.err) |sqlite_err| {
                ctx.setError("Sqlite error: {s}", .{sqlite_err.message});
            } else {
                ctx.setError("Failed to get concepts: {t}", .{err});
            }
            return err;
        };
        return concepts;
    }

    pub fn getConceptsById(ctx: *Context, core: *Core, ids: []const Id) ![]Concept {
        var diags: sqlite.Diagnostics = .{};
        const concepts = ilm.concept.getById(core, ctx.arena, ids, .{ .diags = &diags }) catch |err| {
            if (diags.err) |sqlite_err| {
                ctx.setError("Sqlite error: {s}", .{sqlite_err.message});
            } else {
                ctx.setError("Failed to get concepts: {t}", .{err});
            }
            return err;
        };
        emacs.message(ctx.env, "Found {d} ids and {d} concepts", .{ ids.len, concepts.len });
        return concepts;
    }

    pub fn getAncestors(ctx: *Context, core: *Core, ids: []Id, direct_only: bool) ![]ConceptAncestor {
        var diags: sqlite.Diagnostics = .{};
        const ancestors = ilm.concept.getAncestors(core, ctx.arena, ids, direct_only, .{ .diags = &diags }) catch |err| {
            if (diags.err) |sqlite_err| {
                ctx.setError("Sqlite error: {s}", .{sqlite_err.message});
            } else {
                ctx.setError("Failed to get ancestors: {t}", .{err});
            }
            return err;
        };
        return ancestors;
    }

    const ConceptGraph = struct {
        graph: Graph,
        renderer: Graph.Renderer,

        pub fn deinit(self: *ConceptGraph) void {
            self.renderer.deinit();
            self.graph.deinit();
        }
    };

    // TODO Add way to pass finalizer to ctx.
    // This leaks memory as we have no way currently to free the pointer data
    // itself (we only have finalizer calling deinit() on the pointer data struct).
    pub fn makeGraph(ctx: *Context, core: *Core, canvas_spec: c.emacs_value) !*ConceptGraph {
        const canvas_info: emacs.Canvas = try .fromSpec(core.gpa, ctx.env, canvas_spec);
        const width = canvas_info.width;
        const height = canvas_info.height;

        emacs.message(ctx.env, "Found width '{d}' and height '{d}'", .{ width, height });

        const canvas_buf: [*]u8 = @ptrCast(ctx.env.canvas_data.?(ctx.env, canvas_spec));
        const g = core.gpa.create(ConceptGraph) catch |err| {
            ctx.setError("Failed to allocate ConceptGraph: {t}", .{err});
            return err;
        };
        g.graph = Graph.init(core.gpa, .{
            .width = width,
            .height = height,
        }) catch |err| {
            ctx.setError("Failed to initialize Graph: {t}", .{err});
            return err;
        };
        g.renderer = Graph.Renderer.init(.{
            .gpa = core.gpa,
            .graph = &g.graph,
            .buffer = canvas_buf[0 .. width * height * 4],
            .buffer_stride = width,
            .buffer_height = height,
        }) catch |err| {
            ctx.setError("Failed to initialize Graph renderer: {t}", .{err});
            return err;
        };
        return g;
    }

    pub fn updateGraph(ctx: *Context, core: *Core, g: *ConceptGraph, concept_id: Id) !void {
        const ids: [1]Id = .{concept_id};
        const concept = (try Funcs.getConceptsById(ctx, core, &ids))[0];
        var diags: sqlite.Diagnostics = .{};
        g.graph.addNode(concept.id.uuid, concept.name) catch |err| {
            return ctx.setError("Failed to add node: {t}", .{err});
        };
        const ancestors = ilm.concept.getAncestors(core, ctx.arena, &ids, false, .{ .diags = &diags }) catch |err| {
            return ctx.setError("Failed to get ancestors: {t}", .{err});
        };
        for (ancestors) |*ancestor| {
            g.graph.addNode(ancestor.id.uuid, ancestor.name) catch |err| {
                return ctx.setError("Failed to add node: {t}", .{err});
            };
        }
        for (ancestors) |*ancestor| {
            g.graph.addEdge(ancestor.id.uuid, ancestor.child_id.uuid) catch |err| {
                return ctx.setError("Failed to add edge: {t}", .{err});
            };
        }

        g.graph.layout("dot") catch |err| {
            return ctx.setError("Failed to layout graph: {t}", .{err});
        };
        g.renderer.render(&g.graph) catch |err| {
            return ctx.setError("Failed to render graph: {t}", .{err});
        };
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
    emacs.registerFunc(env, "ilm--core-make-graph", Funcs.makeGraph, "");
    emacs.registerFunc(env, "ilm--core-update-graph", Funcs.updateGraph, "");

    return 0;
}
