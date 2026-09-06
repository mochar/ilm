const std = @import("std");
const Core = @import("core").Core;
const emacs = @import("emacs.zig");
const Context = emacs.Context;
const c = emacs.c;
const sqlite = @import("sqlite");

pub export var plugin_is_GPL_compatible: c_int = 1;
var io = std.Io.Threaded.init_single_threaded;

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

    pub fn newId(_: *Context, core: *Core) Core.IdStr {
        var id = core.newId();
        return id.serialize();
    }

    pub fn addConcept(ctx: *Context, core: *Core, name: []u8) !Core.IdStr {
        var diags: sqlite.Diagnostics = .{};
        var id = core.addConcept(name, &diags) catch |err| {
            if (diags.err) |sqlite_err| {
                ctx.setError("Sqlite error: {s}", .{ sqlite_err.message });
            } else {
                ctx.setError("Failed to add concept: {t}", .{err});
            }
            return err;
        };
        return id.serialize();
    }
};

export fn emacs_module_init(rt: [*c]c.emacs_runtime) c_int {
    const env = rt.*.get_environment.?(rt);

    emacs.registerFunc(env, "ilm--core-init", Funcs.init, "Initialize ilm core and return state");
    emacs.registerFunc(env, "ilm--core-new-id", Funcs.newId, "Generate a new UUID");
    emacs.registerFunc(env, "ilm--core-add-concept", Funcs.addConcept, "Add new concept, return id");

    return 0;
}
