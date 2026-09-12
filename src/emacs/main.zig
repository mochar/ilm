const std = @import("std");
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

var gpa_instance = std.heap.DebugAllocator(.{}){};
const gpa = gpa_instance.allocator();
const c_allocator = std.heap.c_allocator;
var io = std.Io.Threaded.init_single_threaded;

pub export var plugin_is_GPL_compatible: c_int = 1;

/// Functions that will be available to emacs
const Funcs = struct {
    pub fn init(ctx: *Context, data_dir: []const u8) !*Core {
        var diags: sqlite.Diagnostics = .{};
        const core = try c_allocator.create(Core);
        core.* = Core.init(gpa, io.io(), data_dir, .{ .sqlite_diagnostics = &diags }) catch |err| {
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

    // TODO Make CanvasData struct that parses plist with width, height, canvas
    // spec. Set the :ptr property with the zig renderer/canvas struct (rather
    // than returning it). In functions that update the graph or render, :ptr
    // should already be set. We can't set these properties directly on canvas
    // spec object because emacs tests for eq to see if canvas is the same (thus
    // we wrap it).
    pub fn makeGraph(ctx: *Context, core: *Core, canvas_data: c.emacs_value) !*Graph.Renderer {
        const view_width = try emacs.plist_get(ctx.arena, u32, "width", ctx.env, canvas_data);
        const view_height = try emacs.plist_get(ctx.arena, u32, "height", ctx.env, canvas_data);
        const canvas_spec = try emacs.plist_get(ctx.arena, c.emacs_value, "canvas", ctx.env, canvas_data);
        const canvas: emacs.Canvas = try .fromSpec(ctx.arena, ctx.env, canvas_spec);

        const graph_renderer = c_allocator.create(Graph.Renderer) catch |err| {
            ctx.setError("Failed to allocate Graph.Renderer: {t}", .{err});
            return err;
        };
        errdefer c_allocator.destroy(graph_renderer);

        graph_renderer.* = Graph.Renderer.init(.{
            .gpa = core.gpa,
            .graph_options = .{
                .width = view_width,
                .height = view_height,
            },
            .buffer = canvas.buffer,
            .buffer_stride = canvas.buffer_width,
            .buffer_height = canvas.buffer_height,
        }) catch |err| {
            ctx.setError("Failed to initialize Graph Renderer: {t}", .{err});
            return err;
        };
        return graph_renderer;
    }

    pub fn updateGraph(ctx: *Context, core: *Core, g: *Graph.Renderer, canvas_data: c.emacs_value, concept_id: Id) !void {
        const graph = &g.graph;
        
        const view_width = try emacs.plist_get(ctx.arena, u32, "width", ctx.env, canvas_data);
        const view_height = try emacs.plist_get(ctx.arena, u32, "height", ctx.env, canvas_data);
        const canvas_spec = try emacs.plist_get(ctx.arena, c.emacs_value, "canvas", ctx.env, canvas_data);
        const canvas: emacs.Canvas = try .fromSpec(ctx.arena, ctx.env, canvas_spec);
        if (canvas.buffer.ptr != g.buffer.ptr) {
            // If we decide to no longer parse the buffer from canvas_spec, we
            // can alternatively check if the buffer width and height matches,
            // since emacs creates a new buffer if :data-width or :data-height
            // changed.
            ctx.setError("Canvas buffer does not match graph buffer (resized?)", .{});
            return error.DifferentBuffers;
        }

        emacs.message(ctx.env, "Size: {d}x{d}", .{canvas.view_width orelse 0, canvas.view_height orelse 0});

        graph.clear();
        graph.setDimensions(view_width, view_height);

        const ids: [1]Id = .{concept_id};
        const concept = blk: {
            const concepts = try Funcs.getConceptsById(ctx, core, &ids);
            if (concepts.len == 0) {
                ctx.setError("Failed to get concept with id: {s}", .{concept_id.serialize()});
                return error.NotFound;
            }
            break :blk concepts[0];
        };

        graph.addNode(concept.id.uuid, concept.name) catch |err| {
            return ctx.setError("Failed to add node: {t}", .{err});
        };

        var diags: sqlite.Diagnostics = .{};
        const ancestors = ilm.concept.getAncestors(core, ctx.arena, &ids, false, .{ .diags = &diags }) catch |err| {
            return ctx.setError("Failed to get ancestors: {t}", .{err});
        };
        for (ancestors) |*ancestor| {
            graph.addNode(ancestor.id.uuid, ancestor.name) catch |err| {
                return ctx.setError("Failed to add node: {t}", .{err});
            };
        }
        for (ancestors) |*ancestor| {
            graph.addEdge(ancestor.id.uuid, ancestor.child_id.uuid) catch |err| {
                return ctx.setError("Failed to add edge: {t}", .{err});
            };
        }

        graph.layout("dot") catch |err| return ctx.setError("Failed to layout graph: {t}", .{err});
        g.render() catch |err| return ctx.setError("Failed to render graph: {t}", .{err});

        var args = [_]c.emacs_value{ canvas_spec };
        _ = ctx.env.funcall.?(ctx.env, ctx.env.intern.?(ctx.env, "canvas-refresh"), 2, &args);
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
