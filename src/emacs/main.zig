const std = @import("std");
const Core = @import("core").Core;
const c = @cImport({
    @cInclude("emacs-module.h");
});

pub export var plugin_is_GPL_compatible: c_int = 1;

const Emacs = struct {
    const EmacsFunc = *const fn (env: [*c]c.emacs_env, nargs: c.ptrdiff_t, args: [*c]c.emacs_value, data: ?*anyopaque) callconv(.c) c.emacs_value;

    fn message(env: *c.emacs_env, msg: []const u8) void {
        const q_message = env.intern.?(env, "message");
        const q_str = env.make_string.?(env, msg.ptr, @intCast(msg.len));
        var args = [_]c.emacs_value{ q_str };
        _ = env.funcall.?(env, q_message, 1, &args);
    }

    fn registerFunc(
        env: *c.emacs_env,
        name: [:0]const u8,
        min_args: isize,
        max_args: isize,
        func: EmacsFunc,
        doc: [:0]const u8,
    ) void {
        const fn_val = env.make_function.?(env, min_args, max_args, func, doc.ptr, null);
        const sym_val = env.intern.?(env, name.ptr);
        const fset = env.intern.?(env, "fset");
        var fset_args = [_]c.emacs_value{ sym_val, fn_val };
        _ = env.funcall.?(env, fset, 2, &fset_args);
    }
};

const Funcs = struct {
    fn finalizeCore(ptr: ?*anyopaque) callconv(.c) void {
        if (ptr) |p| {
            const core: *Core = @ptrCast(@alignCast(p));
            core.deinit();
        }
    }

    pub fn init(
        env: ?*c.emacs_env,
        nargs: isize,
        args: [*c]c.emacs_value,
        data: ?*anyopaque,
    ) callconv(.c) c.emacs_value {
        _ = nargs; // autofix
        _ = args; // autofix
        _ = data; // autofix
        const e = env orelse return null;
        const core = Core.init(std.heap.c_allocator) catch {
            Emacs.message(e, "Failed to init");
            return null;
        };
        return e.*.make_user_ptr.?(e, finalizeCore, core);
    }

    pub fn inc(
        env: ?*c.emacs_env,
        nargs: isize,
        args: [*c]c.emacs_value,
        data: ?*anyopaque,
    ) callconv(.c) c.emacs_value {
        _ = nargs; // autofix
        _ = data; // autofix
        const e = env orelse return null;
        const user_ptr = e.*.get_user_ptr.?(e, args[0]) orelse return null;
        const core: *Core = @ptrCast(@alignCast(user_ptr));

        const new_val = core.increment();
        return e.*.make_integer.?(e, new_val);
    }
};

export fn emacs_module_init(rt: [*c]c.emacs_runtime) c_int {
    const env = rt.*.get_environment.?(rt);
    Emacs.message(env, "wowowowwo");

    Emacs.registerFunc(env, "ilm--init", 0, 0, Funcs.init, "Initialize ilm core and return state");
    Emacs.registerFunc(env, "ilm--inc", 1, 1, Funcs.inc, "Increment");

    return 0;
}
