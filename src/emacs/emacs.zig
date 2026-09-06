const std = @import("std");
const Core = @import("core").Core;
pub const c = @cImport({
    @cInclude("emacs-module.h");
});

pub const Context = struct {
    env: *c.emacs_env,
    err_msg_buf: [1024]u8 = undefined,
    err_msg: ?[]const u8 = null,

    pub fn warn(self: *Context, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;

        const q_msg = self.env.*.make_string.?(self.env, msg.ptr, @intCast(msg.len));
        const q_type = self.env.*.intern.?(self.env, "ilm");
        const q_display_warning = self.env.*.intern.?(self.env, "display-warning");

        var warn_args = [_]c.emacs_value{ q_type, q_msg };
        _ = self.env.*.funcall.?(self.env, q_display_warning, 2, &warn_args);
    }

    /// Set a custom human-readable error message to be signaled to Emacs
    pub fn setError(self: *Context, comptime fmt: []const u8, args: anytype) void {
        if (std.fmt.bufPrint(&self.err_msg_buf, fmt, args)) |msg| {
            self.err_msg = msg;
        } else |_| {
            self.err_msg = "Unknown error";
        }
    }

    const SignalOptions = struct {
        symbol: [:0]const u8 = "error",
        message: ?[]const u8 = null,
    };

    /// Signal a native Emacs error (stops execution in Elisp)
    pub fn signalError(self: *Context, options: SignalOptions) void {
        const msg = options.message orelse self.err_msg orelse "Unknown error";
        var q_msg = self.env.*.make_string.?(self.env, msg.ptr, @intCast(msg.len));

        const q_sym = self.env.*.intern.?(self.env, options.symbol.ptr);
        const q_list = self.env.*.intern.?(self.env, "list");
        const q_data = self.env.*.funcall.?(self.env, q_list, 1, &q_msg);
        self.env.*.non_local_exit_signal.?(self.env, q_sym, q_data);
    }
};

/// Function Type that emacs expect
pub const EmacsFunc = *const fn (env: [*c]c.emacs_env, nargs: c.ptrdiff_t, args: [*c]c.emacs_value, data: ?*anyopaque) callconv(.c) c.emacs_value;

/// Print a message to the emacs message buffer
pub fn message(env: *c.emacs_env, comptime fmt: []const u8, args: anytype) void {
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
pub fn copyStringBuf(env: *c.emacs_env, emacs_str: c.emacs_value, buf: []u8) ?[:0]const u8 {
    var len: c.ptrdiff_t = @intCast(buf.len);
    if (!env.*.copy_string_contents.?(env, emacs_str, buf.ptr, &len)) {
        return null;
    }
    return buf[0..@intCast(len - 1) :0];
}

/// Copy a emacs string to a zero terminated string
pub fn copyStringAlloc(env: *c.emacs_env, emacs_str: c.emacs_value, allocator: std.mem.Allocator) ![:0]u8 {
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

    if (!env.*.copy_string_contents.?(env, emacs_str, buf.ptr, &len)) {
        return error.EmacsStringCopyFailed;
    }

    return buf;
}

/// Make a function available from emacs
pub fn registerEmacsFunc(
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

/// Convert a c.emacs_value to a native type T.
/// Can allocate, so make sure to deallocate when type is: []u8.
/// Raises compile-time error unsupported types.
pub fn convertFrom(comptime T: type, env: *c.emacs_env, val: c.emacs_value, allocator: std.mem.Allocator) !T {
    switch (@typeInfo(T)) {
        .pointer => |pointer| {
            if (pointer.size == .one and pointer.child == Core) {
                const ptr = env.*.get_user_ptr.?(env, val) orelse return error.NullUserPtr;
                return @ptrCast(@alignCast(ptr));
            } else if (pointer.size == .slice and pointer.child == u8) {
                return copyStringAlloc(env, val, allocator);
            }
        },
        .int => return @intCast(env.*.extract_integer.?(env, val)),
        .bool => return env.*.is_not_nil.?(env, val),
        else => {},
    }
    @compileError("Cannot convert Emacs value for unsupported type: " ++ @typeName(T));
}

/// Convert value of type T to c.emacs_value.
/// Raises compile-time error unsupported types.
pub fn convertTo(comptime T: type, env: *c.emacs_env, val: T) !c.emacs_value {
    switch (@typeInfo(T)) {
        .void => return env.*.intern.?(env, "nil"),
        .int => return env.*.make_integer.?(env, @intCast(val)),
        .bool => return env.*.intern.?(env, if (val) "t" else "nil"),
        .pointer => |pointer| {
            if (pointer.size == .one) {
                // Automatically create user_ptr with type-specific finalizer
                const finalizer = struct {
                    fn f(p: ?*anyopaque) callconv(.c) void {
                        if (p) |raw| {
                            const typed: T = @ptrCast(@alignCast(raw));
                            if (@hasDecl(pointer.child, "deinit")) typed.deinit();
                        }
                    }
                }.f;
                return env.*.make_user_ptr.?(env, finalizer, val);
            } else if (pointer.size == .slice and pointer.child == u8) {
                return env.*.make_string.?(env, val.ptr, @intCast(val.len));
            }
        },
        .array => |array| {
            if (array.child == u8) {
                return env.*.make_string.?(env, &val, array.len);
            }
        },
        else => {},
    }
    @compileError("Cannot convert to Emacs value for unsupported type: " ++ @typeName(T));
}

/// Wrap zig func as a Emacs function
pub fn wrapFunc(comptime func: anytype) EmacsFunc {
    const func_info = @typeInfo(@TypeOf(func)).@"fn";
    const return_type = func_info.return_type orelse void;

    if (func_info.params.len < 1) {
        @compileError("First argument must be *Context");
    }
    const first_arg_info = @typeInfo(func_info.params[0].type orelse void);
    if (first_arg_info != .pointer or first_arg_info.pointer.child != Context) {
        @compileError("First argument must be *Context");
    }

    return struct {
        pub fn f(
            env_opt: ?*c.emacs_env,
            nargs: isize,
            args: [*c]c.emacs_value,
            data: ?*anyopaque,
        ) callconv(.c) c.emacs_value {
            _ = nargs;
            _ = data;
            const env = env_opt orelse unreachable;
            var ctx: Context = .{ .env = env };
            const q_nil = env.intern.?(env, "nil");

            var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer arena.deinit();
            const allocator = arena.allocator();

            // Build tuple of arguments converted at comptime
            var args_tuple: std.meta.ArgsTuple(@TypeOf(func)) = undefined;
            inline for (func_info.params, 0..) |param, i| {
                if (i == 0) {
                    args_tuple[0] = &ctx;
                } else {
                    args_tuple[i] = convertFrom(param.type.?, env, args[i-1], allocator) catch |err| {
                        ctx.setError("Error building emacs function: {t}", .{err});
                        ctx.signalError(.{});
                        return q_nil;
                    };
                }
            }

            // Call native Zig function
            const r_type, const r_val = blk: {
                if (@typeInfo(return_type) == .error_union) {
                    const result = @call(.auto, func, args_tuple) catch {
                        ctx.signalError(.{});
                        return q_nil;
                    };
                    const T = @typeInfo(return_type).error_union.payload;
                    break :blk .{ T, result };
                } else {
                    const result = @call(.auto, func, args_tuple);
                    break :blk .{ return_type, result };
                }
            };

            // Convert return type to emacs type
            return convertTo(r_type, env, r_val) catch |err| {
                ctx.setError("Error building emacs function: {t}", .{err});
                ctx.signalError(.{});
                return q_nil;
            };
        }
    }.f;
}

/// Register a standard Zig function directly into Emacs.
/// The function must have `*Context` as the first argument.
pub fn registerFunc(
    env: *c.emacs_env,
    name: [:0]const u8,
    comptime func: anytype,
    doc: [:0]const u8,
) void {
    const emacs_func = wrapFunc(func);
    const param_count = @typeInfo(@TypeOf(func)).@"fn".params.len - 1;
    registerEmacsFunc(env, name, param_count, param_count, emacs_func, doc);
}
