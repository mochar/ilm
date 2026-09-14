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
const EmacsValue = emacs.EmacsValue;
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
        ctx.env.message("Found {d} ids and {d} concepts", .{ ids.len, concepts.len });
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

    // const GraphContainer = struct {
    //     renderer: *Graph.Renderer,
    //     canvas_spec: EmacsValue,

    //     pub fn fromEmacsRepr(env: emacs.Env, q_container: EmacsValue) GraphContainer {
            
    //     }
    // };

    pub fn makeGraph(ctx: *Context, core: *Core, q_id: EmacsValue, view_width: u32, view_height: u32, buffer_width: u32, buffer_height: u32) !EmacsValue {
        const q_list = ctx.env.intern("list");

        // Make canvas spec
        const canvas_spec = blk: {
            const args = [_]EmacsValue{
                ctx.env.intern("image"),
                ctx.env.intern(":type"),
                ctx.env.intern("canvas"),
                ctx.env.intern(":id"),
                q_id,
                ctx.env.intern(":data-width"),
                ctx.env.makeInteger(buffer_width),
                ctx.env.intern(":data-height"),
                ctx.env.makeInteger(buffer_height),
            };
            break :blk try ctx.env.funcall(q_list, &args);
        };

        // Pass emacs the canvas spec which returns the buffer
        const canvas_buffer = blk: {
            const raw_buf = try ctx.env.canvasData(canvas_spec);
            break :blk raw_buf[0..buffer_width*buffer_height*4];
        };

        // Create graph renderer in heap
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
            .buffer = canvas_buffer,
            .buffer_stride = buffer_width,
            .buffer_height = buffer_height,
        }) catch |err| {
            ctx.setError("Failed to initialize Graph Renderer: {t}", .{err});
            return err;
        };

        // Construct response: a plist with
        const graph_user_ptr = ctx.env.makeUserPtr(Graph.Renderer, graph_renderer);
        const args = [_]EmacsValue{
            ctx.env.intern(":graph-ptr"),
            graph_user_ptr,
            ctx.env.intern(":canvas"),
            canvas_spec,
            ctx.env.intern(":width"),
            ctx.env.makeInteger(view_width),
            ctx.env.intern(":height"),
            ctx.env.makeInteger(view_height),
        };
        return try ctx.env.funcall(q_list, &args);
    }

    pub fn updateGraph(ctx: *Context, core: *Core, q_graph_data: EmacsValue, concept_id: Id) !void {
        const gr = try ctx.env.plistGet(q_graph_data, "graph-ptr", ctx.arena, *Graph.Renderer);
        const graph = &gr.graph;

        const view_width = try ctx.env.plistGet(q_graph_data, "width", ctx.arena, u32);
        const view_height = try ctx.env.plistGet(q_graph_data, "height", ctx.arena, u32);
        const canvas_spec = try ctx.env.plistGet(q_graph_data, "canvas", ctx.arena, EmacsValue);
        const canvas: emacs.Canvas = try .fromSpec(ctx.arena, ctx.env, canvas_spec);
        if (canvas.buffer.ptr != gr.buffer.ptr) {
            // If we decide to no longer parse the buffer from canvas_spec, we
            // can alternatively check if the buffer width and height matches,
            // since emacs creates a new buffer if :data-width or :data-height
            // changed.
            ctx.setError("Canvas buffer does not match graph buffer (resized?)", .{});
            return error.DifferentBuffers;
        }

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
        gr.render() catch |err| return ctx.setError("Failed to render graph: {t}", .{err});

        const refresh_sym = ctx.env.intern("canvas-refresh");
        _ = try ctx.env.funcall1(refresh_sym, canvas_spec);
    }
};

export fn emacs_module_init(raw_rt: [*c]c.emacs_runtime) c_int {
    const rt = emacs.Runtime.fromRaw(raw_rt) orelse return 1;
    const env = rt.getEnvironment() orelse return 1;

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
