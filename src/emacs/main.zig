const std = @import("std");
const ilm = @import("ilm");
const Core = ilm.Core;
const Id = ilm.Id;
const sqlite = @import("sqlite");
const emacs = @import("emacs.zig");
const Context = emacs.Context;
const EmacsValue = emacs.EmacsValue;
const c = emacs.c;

const GraphFuncs = @import("graph.zig").Funcs;
const ConceptFuncs = @import("concept.zig").Funcs;

var gpa_instance = std.heap.DebugAllocator(.{}){};
const gpa = gpa_instance.allocator();
const c_allocator = std.heap.c_allocator;
var io = std.Io.Threaded.init_single_threaded;

pub export var plugin_is_GPL_compatible: c_int = 1;

pub const Funcs = struct {
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
};

export fn emacs_module_init(raw_rt: [*c]c.emacs_runtime) c_int {
    const rt = emacs.Runtime.fromRaw(raw_rt) orelse return 1;
    const env = rt.getEnvironment() orelse return 1;

    emacs.registerFunc(env, "ilm--core-init", Funcs.init, "Initialize ilm core and return state");
    emacs.registerFunc(env, "ilm--core-is-valid", Funcs.isValid, "Return t if core in valid state");
    emacs.registerFunc(env, "ilm--core-new-id", Funcs.newId, "Generate a new UUID");
    
    emacs.registerFunc(env, "ilm--core-add-concept", ConceptFuncs.add, "Add new concept, return id");
    emacs.registerFunc(env, "ilm--core-add-concept-parent", ConceptFuncs.addParent, "Assign a parent to a concept");
    emacs.registerFunc(env, "ilm--core-remove-concept-parent", ConceptFuncs.removeParent, "Unassign a parent from a concept");
    emacs.registerFunc(env, "ilm--core-all-concepts", ConceptFuncs.getAll, "Get all concepts");
    emacs.registerFunc(env, "ilm--core-concepts-by-id", ConceptFuncs.getById, "Get concepts by IDs");
    emacs.registerFunc(env, "ilm--core-concept-ancestors", ConceptFuncs.getAncestors, "Get ancestory of concepts");
    emacs.registerFunc(env, "ilm--core-set-concept-graph", ConceptFuncs.setGraph, "");
    
    emacs.registerFunc(env, "ilm--core-make-graph", GraphFuncs.make, "");
    emacs.registerFunc(env, "ilm--core-resize-graph", GraphFuncs.resize, "");
    emacs.registerFunc(env, "ilm--core-update-graph", GraphFuncs.update, "");
    emacs.registerFunc(env, "ilm--core-graph-mouse-up", GraphFuncs.mouseUp, "");
    emacs.registerFunc(env, "ilm--core-graph-mouse-down", GraphFuncs.mouseDown, "");
    emacs.registerFunc(env, "ilm--core-graph-mouse-move", GraphFuncs.mouseMove, "");
    emacs.registerFunc(env, "ilm--core-pan-graph", GraphFuncs.pan, "Pan graph camera by (dx, dy)");
    emacs.registerFunc(env, "ilm--core-zoom-graph", GraphFuncs.zoom, "Zoom graph camera by factor at (focus_x, focus_y)");
    emacs.registerFunc(env, "ilm--core-fit-graph", GraphFuncs.fit, "Fit graph camera to bounding box");
    emacs.registerFunc(env, "ilm--core-get-node-at", GraphFuncs.getNodeAt, "Get node UUID under screen coordinates");

    return 0;
}
