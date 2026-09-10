const std = @import("std");
const Core = @import("core").Core;
pub const c = @cImport({
    @cInclude("emacs-module.h");
});

pub const Context = struct {
    env: *c.emacs_env,
    arena: std.mem.Allocator,
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

/// Test if an emacs_value symbol has the given name.
pub fn symbol_eq(env: *c.emacs_env, a_symbol: c.emacs_value, b_name: [:0]const u8) bool {
    const b_symbol = env.*.intern.?(env, b_name.ptr);
    return env.*.eq.?(env, a_symbol, b_symbol);
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
/// Can allocate, so make sure to deallocate when type is: []T.
/// Raises compile-time error unsupported types.
pub fn convertFrom(comptime T: type, env: *c.emacs_env, val: c.emacs_value, allocator: std.mem.Allocator) !T {
    switch (@typeInfo(T)) {
        .pointer => |pointer| {
            // If single item pointer, assume this is as user_ptr that we passed to emacs.
            if (pointer.size == .one) {
                const ptr = env.*.get_user_ptr.?(env, val) orelse return error.NullUserPtr;
                return @ptrCast(@alignCast(ptr));
            }

            // Strings
            if (pointer.size == .slice and pointer.child == u8) {
                return copyStringAlloc(env, val, allocator);
            }
            
            // Convert Emacs list to Zig slice []T
            const q_car = env.*.intern.?(env, "car");
            const q_cdr = env.*.intern.?(env, "cdr");

            // TODO memory managed right here?
            var list: std.ArrayList(pointer.child) = .empty;
            errdefer list.deinit(allocator);

            var current = val;
            while (env.*.is_not_nil.?(env, current)) {
                var args = [_]c.emacs_value{current};
                const head = env.*.funcall.?(env, q_car, 1, &args);
                current = env.*.funcall.?(env, q_cdr, 1, &args);
                
                const item = try convertFrom(pointer.child, env, head, allocator);
                try list.append(allocator, item);
            }

            return try list.toOwnedSlice(allocator);
        },
        .@"struct" => |s| {
            // Custom deserializer
            if (@hasDecl(T, "fromEmacsRepr")) {
                const fn_info = @typeInfo(@TypeOf(T.fromEmacsRepr)).@"fn";
                const repr_type = fn_info.params[0].type.?;
                const repr = try convertFrom(repr_type, env, val, allocator);
                return try T.fromEmacsRepr(repr);
            }

            // Convert Elisp plist into Zig struct
            const q_plist_get = env.*.intern.?(env, "plist-get");
            var result: T = undefined;

            inline for (s.fields) |field| {
                const kw_name = ":" ++ field.name;
                const q_key = env.*.intern.?(env, kw_name.ptr);
                var get_args = [_]c.emacs_value{ val, q_key };
                const field_emacs_val = env.*.funcall.?(env, q_plist_get, 2, &get_args);

                @field(result, field.name) = try convertFrom(
                    field.type,
                    env,
                    field_emacs_val,
                    allocator,
                );
            }

            return result;
        },
        .int => return @intCast(env.*.extract_integer.?(env, val)),
        .bool => return env.*.is_not_nil.?(env, val),
        else => {},
    }
    @compileError("Cannot convert Emacs value for unsupported type: " ++ @typeName(T));
}

/// Convert value of type T to c.emacs_value.
/// For structs, if "emacsRepr" function exists, will use that.
/// Raises compile-time error unsupported types.
pub fn convertTo(comptime T: type, env: *c.emacs_env, val: T) !c.emacs_value {
    switch (@typeInfo(T)) {
        .void => return env.*.intern.?(env, "nil"),
        .int => return env.*.make_integer.?(env, @intCast(val)),
        .bool => return env.*.intern.?(env, if (val) "t" else "nil"),
        .@"struct" => |s| {
            // First check if it has a "toEmacsRepr" method
            if (@hasDecl(T, "toEmacsRepr")) {
                const repr = val.toEmacsRepr();
                return convertTo(@TypeOf(repr), env, repr);
            }

            // Convert struct into plist: (:field1 val1 :field2 val2 ...)
            const q_list = env.*.intern.?(env, "list");
            var plist_items: [s.fields.len * 2]c.emacs_value = undefined;

            inline for (s.fields, 0..) |field, idx| {
                const kw_name = ":" ++ field.name;
                plist_items[idx * 2] = env.*.intern.?(env, kw_name.ptr);
                plist_items[idx * 2 + 1] = try convertTo(field.type, env, @field(val, field.name));
            }

            return env.*.funcall.?(env, q_list, @intCast(plist_items.len), &plist_items);
        },
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
            } else if (pointer.size == .slice) {
                if (pointer.child == u8) {
                    return env.*.make_string.?(env, val.ptr, @intCast(val.len));
                } else {
                    // Convert []T into Emacs list: (elem1 elem2 ...)
                    const q_cons = env.*.intern.?(env, "cons");
                    var list = env.*.intern.?(env, "nil");

                    // Build list backwards with cons.
                    // This prevents needing to allocate using an ArrayList
                    var i: usize = val.len;
                    while (i > 0) {
                        i -= 1;
                        const elem = try convertTo(pointer.child, env, val[i]);
                        var cons_args = [_]c.emacs_value{ elem, list };
                        list = env.*.funcall.?(env, q_cons, 2, &cons_args);
                    }
                    return list;
                }
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
            const q_nil = env.intern.?(env, "nil");

            var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer arena.deinit();
            const allocator = arena.allocator();
            var ctx: Context = .{ .env = env, .arena = allocator };

            // Build tuple of arguments converted at comptime
            var args_tuple: std.meta.ArgsTuple(@TypeOf(func)) = undefined;
            inline for (func_info.params, 0..) |param, i| {
                if (i == 0) {
                    args_tuple[0] = &ctx;
                } else if (param.type.? == c.emacs_value) {
                    args_tuple[i] = args[i - 1];
                } else {
                    args_tuple[i] = convertFrom(param.type.?, env, args[i - 1], allocator) catch |err| {
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

/// Parses a list iteratively through car and cdr and storing the current cons.
///
/// The current cons is nil, we have finished traversing the list. Note that if
/// last element is nil, this is not the same as the cons being nil (it is (cons
/// nil nil)).
pub const ListConverter = struct {
    env: *c.emacs_env,
    q_car: c.emacs_value,
    q_cdr: c.emacs_value,
    /// Current cons, null means finished traversing the list.
    cons: ?c.emacs_value,

    pub fn init(env: *c.emacs_env, list: c.emacs_value) ListConverter {
        return .{
            .env = env,
            .q_car = env.*.intern.?(env, "car"),
            .q_cdr = env.*.intern.?(env, "cdr"),
            .cons = if (env.*.is_not_nil.?(env, list)) list else null,
        };
    }

    pub fn next(self: *ListConverter) !c.emacs_value {
        if (self.cons == null) return error.Done;
        var args = [_]c.emacs_value{self.cons.?};
        const car = self.env.*.funcall.?(self.env, self.q_car, 1, &args);
        const cdr = self.env.*.funcall.?(self.env, self.q_cdr, 1, &args);
        self.cons = if (self.env.*.is_not_nil.?(self.env, cdr)) cdr else null;
        return car;
    }

    /// Note that if T is null, this can return null, so an empty list raises an
    /// error instead to avoid ambiguity.
    pub fn nextType(self: *ListConverter, comptime T: type, allocator: std.mem.Allocator) !T {
        const value = try self.next();
        return try convertFrom(T, self.env, value, allocator);
    }
};

pub const Canvas = struct {
    width: u32,
    height: u32,

    pub fn fromSpec(gpa: std.mem.Allocator, env: *c.emacs_env, canvas_spec: c.emacs_value) !Canvas {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const allocator = arena.allocator();

        var converter = ListConverter.init(env, canvas_spec);

        var cur = try converter.next();
        if (!symbol_eq(env, cur, "image")) return error.Invalid;

        var type_correct = false;
        var width: ?u32 = null;
        var height: ?u32 = null;
        while (converter.cons != null) {
            cur = try converter.next();
            if (symbol_eq(env, cur, ":type")) {
                cur = try converter.next();
                if (!symbol_eq(env, cur, "canvas")) return error.NotCanvasType;
                type_correct = true;
            } else if (symbol_eq(env, cur, ":data-width")) {
                width = try convertFrom(u32, env, try converter.next(), allocator);
            } else if (symbol_eq(env, cur, ":data-height")) {
                height = try convertFrom(u32, env, try converter.next(), allocator);
            }
        }

        if (!type_correct or width == null or height == null) return error.Incomplete;
        return .{ .width = width.?, .height = height.? };
    }
};
