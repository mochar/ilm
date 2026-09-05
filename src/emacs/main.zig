const std = @import("std");

const Core = @import("core").Core;
const sqlite = @import("sqlite");

const c = @cImport({
    @cInclude("emacs-module.h");
});

pub export var plugin_is_GPL_compatible: c_int = 1;
var io = std.Io.Threaded.init_single_threaded;

const Emacs = struct {
    const EmacsFunc = *const fn (env: [*c]c.emacs_env, nargs: c.ptrdiff_t, args: [*c]c.emacs_value, data: ?*anyopaque) callconv(.c) c.emacs_value;

    /// Print a message to the emacs message buffer
    fn message(env: *c.emacs_env, comptime fmt: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch |err| switch (err) {
            error.NoSpaceLeft => std.fmt.allocPrint(std.heap.c_allocator, fmt, args) catch return,
        };
        defer if (msg.ptr != &buf) std.heap.c_allocator.free(msg);

        const q_message = env.intern.?(env, "message");
        const q_str = env.make_string.?(env, msg.ptr, @intCast(msg.len));
        var emacs_args = [_]c.emacs_value{q_str};
        _ = env.funcall.?(env, q_message, 1, &emacs_args);
    }

    /// Copy an emacs string to a buffer
    fn copyStringBuf(env: *c.emacs_env, emacs_str: c.emacs_value, buf: []u8) ?[:0]const u8 {
        var len: c.ptrdiff_t = @intCast(buf.len);
        if (!env.*.copy_string_contents.?(env, emacs_str, buf.ptr, &len)) {
            return null;
        }
        return buf[0..@intCast(len - 1) :0];
    }

    /// Copy a emacs string to a zero terminated string
    fn copyStringAlloc(env: *c.emacs_env, emacs_str: c.emacs_value, allocator: std.mem.Allocator) ![:0]u8 {
        // The argument BUF can be a ‘NULL’ pointer, in which case the function
        // store the contents of ARG, and returns ‘true’.  This is how you can
        // determine the size of BUF needed to store a particular string: first
        // call ‘copy_string_contents’ with ‘NULL’ as BUF, then allocate enough
        // memory to hold the number of bytes stored by the function in ‘*LEN’,
        // and call the function again with non-‘NULL’ BUF to actually perform
        // the text copying.
        var len: c.ptrdiff_t = 0;
        if (!env.*.copy_string_contents.?(env, emacs_str, null, &len)) {
            return error.EmacsStringCopyFailed;
        }

        const str_len: usize = @intCast(len - 1);
        const buf = try allocator.allocSentinel(u8, str_len, 0);
        errdefer allocator.free(buf);

        // Copy string contents into allocated buffer
        if (!env.*.copy_string_contents.?(env, emacs_str, buf.ptr, &len)) {
            return error.EmacsStringCopyFailed;
        }

        return buf;
    }

    /// Make a function available from emacs
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
        _ = data; // autofix
        const e = env orelse unreachable;

        var data_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const data_dir = Emacs.copyStringBuf(e, args[0], &data_dir_buf) orelse {
            Emacs.message(e, "ilm: Failed to read data_dir argument", .{});
            return e.intern.?(e, "nil");
        };

        var diags = sqlite.Diagnostics{};
        const options: Core.Options = .{ .data_dir = data_dir, .sqlite_diagnostics = &diags };
        const allocator = std.heap.c_allocator;
        const core = Core.init(allocator, io.io(), options) catch |err| {
            if (diags.err) |sqlite_err| {
                Emacs.message(e, "ilm: Failed to init: {t}: {s}", .{ err, sqlite_err.message });
            } else {
                Emacs.message(e, "ilm: Failed to init: {t}", .{err});
            }
            return e.intern.?(e, "nil");
        };
        return e.*.make_user_ptr.?(e, finalizeCore, core);
    }

    pub fn newId(
        env: ?*c.emacs_env,
        nargs: isize,
        args: [*c]c.emacs_value,
        data: ?*anyopaque,
    ) callconv(.c) c.emacs_value {
        _ = nargs; // autofix
        _ = data; // autofix
        const e = env orelse unreachable;
        const user_ptr = e.*.get_user_ptr.?(e, args[0]) orelse return e.intern.?(e, "nil");
        const core: *Core = @ptrCast(@alignCast(user_ptr));

        var id = core.newId();
        const id_str = id.serialize();
        return e.make_string.?(e, &id_str, @intCast(id_str.len));
    }    

    pub fn addConcept(
        env: ?*c.emacs_env,
        nargs: isize,
        args: [*c]c.emacs_value,
        data: ?*anyopaque,
    ) callconv(.c) c.emacs_value {
        _ = nargs; // autofix
        _ = data; // autofix
        const e = env orelse unreachable;
        const user_ptr = e.*.get_user_ptr.?(e, args[0]) orelse return e.intern.?(e, "nil");
        const core: *Core = @ptrCast(@alignCast(user_ptr));

        var name_buf: [1028]u8 = undefined;
        const name = Emacs.copyStringBuf(e, args[1], &name_buf) orelse {
            Emacs.message(e, "ilm: Failed to copy string", .{});
            return e.intern.?(e, "nil");
        };

        var id = core.addConcept(name) catch {
            Emacs.message(e, "ilm: Failed to add concept", .{});
            return e.intern.?(e, "nil");
        };
        const id_str = id.serialize();
        return e.make_string.?(e, &id_str, @intCast(id_str.len));
    }
};

export fn emacs_module_init(rt: [*c]c.emacs_runtime) c_int {
    const env = rt.*.get_environment.?(rt);
    Emacs.message(env, "wowowowwo", .{});

    Emacs.registerFunc(env, "ilm--init", 1, 1, Funcs.init, "Initialize ilm core and return state");
    Emacs.registerFunc(env, "ilm--new-id", 1, 1, Funcs.newId, "New UUID");
    Emacs.registerFunc(env, "ilm--add-concept", 2, 2, Funcs.addConcept, "Add new concept, return id");

    return 0;
}
