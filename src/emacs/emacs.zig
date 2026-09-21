//! Zig bindings and utilities for emacs_module.h.
const std = @import("std");
pub const c = @import("emacs_c");

pub const EmacsValue = c.emacs_value;
pub const FuncallExit = c.emacs_funcall_exit;
pub const EmacsFunc = *const fn (
    env: [*c]c.emacs_env,
    nargs: c.ptrdiff_t,
    args: [*c]c.emacs_value,
    data: ?*anyopaque,
) callconv(.c) c.emacs_value;

/// Holds env during emacs function call.
/// Used in log function to print to emacs.
pub threadlocal var active_env: ?Env = null;

/// Wrapper around Emacs runtime pointer
pub const Runtime = struct {
    raw: *c.emacs_runtime,

    pub fn fromRaw(raw: ?*c.emacs_runtime) ?Runtime {
        const ptr = raw orelse return null;
        return .{ .raw = ptr };
    }

    pub fn getEnvironment(self: Runtime) ?Env {
        const raw_env = self.raw.get_environment.?(self.raw);
        return Env.fromRaw(raw_env);
    }
};

/// Wrapper around Emacs environment pointer (`emacs_env`)
pub const Env = struct {
    raw: *c.emacs_env,

    pub fn fromRaw(raw: ?*c.emacs_env) ?Env {
        const ptr = raw orelse return null;
        return .{ .raw = ptr };
    }

    pub fn nil(self: Env) EmacsValue {
        return self.raw.intern.?(self.raw, "nil");
    }

    pub fn t(self: Env) EmacsValue {
        return self.raw.intern.?(self.raw, "t");
    }

    pub fn intern(self: Env, name: [:0]const u8) EmacsValue {
        return self.raw.intern.?(self.raw, name.ptr);
    }

    pub fn isNotNil(self: Env, val: EmacsValue) bool {
        return self.raw.is_not_nil.?(self.raw, val);
    }

    pub fn isNil(self: Env, val: EmacsValue) bool {
        return !self.isNotNil(val);
    }

    pub fn eq(self: Env, a: EmacsValue, b: EmacsValue) bool {
        return self.raw.eq.?(self.raw, a, b);
    }

    pub fn symbolEq(self: Env, sym: EmacsValue, name: [:0]const u8) bool {
        const target = self.intern(name);
        return self.eq(sym, target);
    }

    pub fn typeOf(self: Env, val: EmacsValue) EmacsValue {
        return self.raw.type_of.?(self.raw, val);
    }

    pub fn nonLocalExitCheck(self: Env) FuncallExit {
        return self.raw.non_local_exit_check.?(self.raw);
    }

    pub fn nonLocalExitClear(self: Env) void {
        self.raw.non_local_exit_clear.?(self.raw);
    }

    pub fn nonLocalExitSignal(self: Env, symbol: EmacsValue, data: EmacsValue) void {
        self.raw.non_local_exit_signal.?(self.raw, symbol, data);
    }

    pub fn nonLocalExitThrow(self: Env, tag: EmacsValue, value: EmacsValue) void {
        self.raw.non_local_exit_throw.?(self.raw, tag, value);
    }

    /// Check if a non-local exit occurred. If so, clears it and returns error.EmacsError.
    pub fn checkExit(self: Env) !void {
        if (self.nonLocalExitCheck() != c.emacs_funcall_exit_return) {
            self.nonLocalExitClear();
            return error.EmacsError;
        }
    }

    pub fn funcall(self: Env, function: EmacsValue, args: []const EmacsValue) !EmacsValue {
        const raw_args: [*c]c.emacs_value = if (args.len > 0) @constCast(args.ptr) else null;
        const res = self.raw.funcall.?(
            self.raw,
            function,
            @intCast(args.len),
            raw_args,
        );
        try self.checkExit();
        return res;
    }

    pub fn funcall0(self: Env, function: EmacsValue) !EmacsValue {
        return self.funcall(function, &.{});
    }

    pub fn funcall1(self: Env, function: EmacsValue, arg1: EmacsValue) !EmacsValue {
        const args = [_]EmacsValue{arg1};
        return self.funcall(function, &args);
    }

    pub fn funcall2(self: Env, function: EmacsValue, arg1: EmacsValue, arg2: EmacsValue) !EmacsValue {
        const args = [_]EmacsValue{ arg1, arg2 };
        return self.funcall(function, &args);
    }
    
    pub fn funcall3(self: Env, function: EmacsValue, arg1: EmacsValue, arg2: EmacsValue, arg3: EmacsValue) !EmacsValue {
        const args = [_]EmacsValue{ arg1, arg2, arg3 };
        return self.funcall(function, &args);
    }

    pub fn makeInteger(self: Env, n: i64) EmacsValue {
        return self.raw.make_integer.?(self.raw, n);
    }

    pub fn extractInteger(self: Env, val: EmacsValue) !i64 {
        const res = self.raw.extract_integer.?(self.raw, val);
        try self.checkExit();
        return res;
    }

    pub fn makeFloat(self: Env, d: f64) EmacsValue {
        return self.raw.make_float.?(self.raw, d);
    }

    pub fn extractFloat(self: Env, val: EmacsValue) !f64 {
        const res = self.raw.extract_float.?(self.raw, val);
        try self.checkExit();
        return res;
    }

    pub fn makeString(self: Env, str: []const u8) !EmacsValue {
        const res = self.raw.make_string.?(self.raw, str.ptr, @intCast(str.len));
        try self.checkExit();
        return res;
    }

    pub fn copyStringBuf(self: Env, val: EmacsValue, buf: []u8) ?[:0]const u8 {
        var len: c.ptrdiff_t = @intCast(buf.len);
        if (!self.raw.copy_string_contents.?(self.raw, val, buf.ptr, &len)) {
            return null;
        }
        return buf[0..@intCast(len - 1) :0];
    }

    pub fn copyStringAlloc(self: Env, val: EmacsValue, allocator: std.mem.Allocator) ![:0]u8 {
        // The argument BUF can be a ‘NULL’ pointer, in which case the function
        // store the contents of ARG, and returns ‘true’.  This is how you can
        // determine the size of BUF needed to store a particular string: first
        // call ‘copy_string_contents’ with ‘NULL’ as BUF, then allocate enough
        // memory to hold the number of bytes stored by the function in ‘*LEN’,
        // and call the function again with non-‘NULL’ BUF to actually perform
        // the text copying.
        var len: c.ptrdiff_t = 0;
        if (!self.raw.copy_string_contents.?(self.raw, val, null, &len)) {
            try self.checkExit();
            return error.EmacsStringCopyFailed;
        }

        const str_len: usize = @intCast(len - 1);
        const buf = try allocator.allocSentinel(u8, str_len, 0);
        errdefer allocator.free(buf);

        if (!self.raw.copy_string_contents.?(self.raw, val, buf.ptr, &len)) {
            try self.checkExit();
            return error.EmacsStringCopyFailed;
        }

        return buf;
    }

    pub fn makeUserPtr(self: Env, comptime T: type, ptr: *T) EmacsValue {
        const finalizer = struct {
            fn f(p: ?*anyopaque) callconv(.c) void {
                if (p) |raw| {
                    const typed: *T = @ptrCast(@alignCast(raw));
                    if (@hasDecl(T, "deinit")) typed.deinit();
                    std.heap.c_allocator.destroy(typed);
                }
            }
        }.f;
        return self.raw.make_user_ptr.?(self.raw, finalizer, ptr);
    }

    pub fn getUserPtr(self: Env, comptime T: type, val: EmacsValue) !*T {
        const raw_ptr = self.raw.get_user_ptr.?(self.raw, val) orelse {
            try self.checkExit();
            return error.NullUserPtr;
        };
        return @ptrCast(@alignCast(raw_ptr));
    }

    pub fn canvasData(self: Env, canvas: EmacsValue) ![*]u8 {
        const raw_buf = self.raw.canvas_data.?(self.raw, canvas) orelse {
            try self.checkExit();
            return error.CanvasDataNull;
        };
        return @ptrCast(raw_buf);
    }

    pub fn makeFunction(
        self: Env,
        min_args: isize,
        max_args: isize,
        func: EmacsFunc,
        doc: [:0]const u8,
        data: ?*anyopaque,
    ) EmacsValue {
        return self.raw.make_function.?(self.raw, min_args, max_args, func, doc.ptr, data);
    }

    /// Register a native Zig function directly into Emacs with type conversions.
    /// The function must have `*Context` as the first argument.
    pub fn registerFunc(
        self: Env,
        name: [:0]const u8,
        min_args: isize,
        max_args: isize,
        func: EmacsFunc,
        doc: [:0]const u8,
    ) void {
        const fn_val = self.makeFunction(min_args, max_args, func, doc, null);
        const sym_val = self.intern(name);
        const fset = self.intern("fset");
        _ = self.funcall2(fset, sym_val, fn_val) catch return;
    }

    pub fn message(self: Env, comptime fmt: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch |err| switch (err) {
            error.NoSpaceLeft => std.fmt.allocPrint(std.heap.c_allocator, fmt, args) catch return,
        };
        defer if (msg.ptr != &buf) std.heap.c_allocator.free(msg);

        const q_msg = self.makeString(msg) catch return;
        const q_message = self.intern("message");
        _ = self.funcall1(q_message, q_msg) catch return;
    }

    pub fn plistGet(
        self: Env,
        plist: EmacsValue,
        comptime property: []const u8,
        allocator: std.mem.Allocator,
        comptime T: type,
    ) !T {
        const q_plist_get = self.intern("plist-get");
        const kw_name = ":" ++ property;
        const q_key = self.intern(kw_name);
        const val = try self.funcall2(q_plist_get, plist, q_key);
        if (T == EmacsValue) return val;
        return try self.convertFrom(T, val, allocator);
    }
    
    pub fn plistSet(
        self: Env,
        plist: EmacsValue,
        comptime property: []const u8,
        value: anytype,
    ) !void {
        const q_plist_put = self.intern("plist-put");
        const kw_name = ":" ++ property;
        const q_key = self.intern(kw_name);
        const val_type = @TypeOf(value);
        const emacs_val = if (val_type == EmacsValue) value else try self.convertTo(val_type, value);
        _ = try self.funcall3(q_plist_put, plist, q_key, emacs_val);
    }
    
    /// Convert a EmacsValue to a native Zig type T.
    /// Can allocate, so make sure to deallocate when type is: []T.
    /// Raises compile-time error unsupported types.
    pub fn convertFrom(self: Env, comptime T: type, val: EmacsValue, allocator: std.mem.Allocator) !T {
        if (type == EmacsValue) return val;
        switch (@typeInfo(T)) {
            .pointer => |pointer| {
                if (pointer.size == .one) {
                    return try self.getUserPtr(pointer.child, val);
                }

                if (pointer.size == .slice and pointer.child == u8) {
                    return self.copyStringAlloc(val, allocator);
                }

                // Convert Emacs list to Zig slice []T
                var list: std.ArrayList(pointer.child) = .empty;
                errdefer list.deinit(allocator);

                const q_car = self.intern("car");
                const q_cdr = self.intern("cdr");

                var current = val;
                while (self.isNotNil(current)) {
                    const head = try self.funcall1(q_car, current);
                    current = try self.funcall1(q_cdr, current);

                    const item = try self.convertFrom(pointer.child, head, allocator);
                    try list.append(allocator, item);
                }

                return try list.toOwnedSlice(allocator);
            },
            .@"struct" => |s| {
                if (@hasDecl(T, "fromEmacsRepr")) {
                    const fn_info = @typeInfo(@TypeOf(T.fromEmacsRepr)).@"fn";
                    if (fn_info.params.len == 2 and fn_info.params[0].type.? != Env) {
                        @compileError("if fromEmacsRepr has two params, first must be Env");
                    }
                    const accepts_env = fn_info.params.len == 2;
                    const env_index = if (accepts_env) 1 else 0;
                    const repr_type = fn_info.params[env_index].type.?;
                    const repr = try self.convertFrom(repr_type, val, allocator);
                    if (accepts_env) {
                        return try T.fromEmacsRepr(self, repr);
                    } else {
                        return try T.fromEmacsRepr(repr);
                    }
                }

                var result: T = undefined;
                inline for (s.fields) |field| {
                    @field(result, field.name) = try self.plistGet(
                        val,
                        field.name,
                        allocator,
                        field.type,
                    );
                }
                return result;
            },
            .int => {
                const i = try self.extractInteger(val);
                return @intCast(i);
            },
            .float => {
                const f = try self.extractFloat(val);
                return @floatCast(f);
            },
            .bool => return self.isNotNil(val),
            else => {},
        }
        @compileError("Cannot convert Emacs value for unsupported type: " ++ @typeName(T));
    }

    /// Convert value of type T to EmacsValue.
    /// For structs, if "emacsRepr" function exists, will use that.
    /// Raises compile-time error unsupported types.
    pub fn convertTo(self: Env, comptime T: type, val: T) !EmacsValue {
        switch (@typeInfo(T)) {
            .void => return self.nil(),
            .int => return self.makeInteger(@intCast(val)),
            .float => return self.makeFloat(@floatCast(val)),
            .bool => return if (val) self.t() else self.nil(),
            .@"struct" => |s| {
                if (@hasDecl(T, "toEmacsRepr")) {
                    const repr = val.toEmacsRepr();
                    return self.convertTo(@TypeOf(repr), repr);
                }

                // Convert struct into plist: (:field1 val1 :field2 val2 ...)
                const q_list = self.intern("list");
                var plist_items: [s.fields.len * 2]EmacsValue = undefined;

                inline for (s.fields, 0..) |field, idx| {
                    const kw_name = ":" ++ field.name;
                    plist_items[idx * 2] = self.intern(kw_name);
                    plist_items[idx * 2 + 1] = try self.convertTo(field.type, @field(val, field.name));
                }

                return self.funcall(q_list, &plist_items);
            },
            .pointer => |pointer| {
                if (pointer.size == .one) {
                    return self.makeUserPtr(pointer.child, val);
                } else if (pointer.size == .slice) {
                    if (pointer.child == u8) {
                        return self.makeString(val);
                    } else {
                        // Convert []T into Emacs list backwards with cons
                        const q_cons = self.intern("cons");
                        var list = self.nil();

                        var i: usize = val.len;
                        while (i > 0) {
                            i -= 1;
                            const elem = try self.convertTo(pointer.child, val[i]);
                            list = try self.funcall2(q_cons, elem, list);
                        }
                        return list;
                    }
                }
            },
            .array => |array| {
                if (array.child == u8) {
                    return self.makeString(&val);
                }
            },
            else => {},
        }
        @compileError("Cannot convert to Emacs value for unsupported type: " ++ @typeName(T));
    }
};

pub const Context = struct {
    env: Env,
    arena: std.mem.Allocator,
    err_msg_buf: [1024]u8 = undefined,
    err_msg: ?[]const u8 = null,

    pub fn warn(self: *Context, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;

        const q_msg = self.env.makeString(msg) catch return;
        const q_type = self.env.intern("ilm");
        const q_display_warning = self.env.intern("display-warning");

        _ = self.env.funcall2(q_display_warning, q_type, q_msg) catch return;
    }

    /// Set a custom human-readable error message to be signaled to Emacs
    pub fn setError(self: *Context, comptime fmt: []const u8, args: anytype) void {
        if (std.fmt.bufPrint(&self.err_msg_buf, fmt, args)) |msg| {
            self.err_msg = msg;
        } else |_| {
            self.err_msg = "Unknown error";
        }
    }

    pub const SignalOptions = struct {
        symbol: [:0]const u8 = "error",
        message: ?[]const u8 = null,
    };

    /// Signal a native Emacs error (stops execution in Elisp)
    pub fn signalError(self: *Context, options: SignalOptions) void {
        const msg = options.message orelse self.err_msg orelse "Unknown error";
        const q_msg = self.env.makeString(msg) catch return;
        const q_sym = self.env.intern(options.symbol);
        const q_list = self.env.intern("list");
        const q_data = self.env.funcall1(q_list, q_msg) catch return;
        self.env.nonLocalExitSignal(q_sym, q_data);
    }
};

/// Emacs canvas buffer.
///
/// Note that the pixel buffer is only valid as long as the canvas object is
/// alive and its dimensions (:data-width and :data-height) have not been
/// changed. If it has changed, Emacs will create a new pixel buffer and
/// automatically resize the canvas. View dimensions (:width and :height)
/// preserve the pixel buffer, though these are not relevant for us.
pub const Canvas = struct {
    buffer: []u8,
    /// In pixels.
    width: u32,
    /// In pixels.
    height: u32,

    /// Get buffer and properties from canvas image spec.
    pub fn fromSpec(arena: std.mem.Allocator, env: Env, canvas_spec: EmacsValue) !Canvas {
        const q_car = env.intern("car");
        const q_img = try env.funcall1(q_car, canvas_spec);
        if (!env.symbolEq(q_img, "image")) return error.Invalid;

        const q_cdr = env.intern("cdr");
        const attrs = try env.funcall1(q_cdr, canvas_spec);

        const c_type = env.plistGet(attrs, "type", arena, EmacsValue) catch return error.InvalidType;
        if (!env.symbolEq(c_type, "canvas")) return error.NotCanvasType;

        const width = env.plistGet(attrs, "data-width", arena, u32) catch return error.InvalidWidth;
        const height = env.plistGet(attrs, "data-height", arena, u32) catch return error.InvalidHeight;

        const buf = try env.canvasData(canvas_spec);

        return .{
            .buffer = buf[0 .. width * height * 4],
            .width = width,
            .height = height,
        };
    }
};

/// Parses a list iteratively through car and cdr.
///
/// The current cons is nil, we have finished traversing the list. Note that if
/// last element is nil, this is not the same as the cons being nil (it is (cons
/// nil nil)).
pub const ListConverter = struct {
    env: Env,
    cons: ?EmacsValue,

    pub fn init(env: Env, list: EmacsValue) ListConverter {
        return .{
            .env = env,
            .cons = if (env.isNotNil(list)) list else null,
        };
    }

    pub fn next(self: *ListConverter) !EmacsValue {
        const current = self.cons orelse return error.Done;
        const car = try self.env.funcall1(self.env.intern("car"), current);
        const cdr = try self.env.funcall1(self.env.intern("cdr"), current);
        self.cons = if (self.env.isNotNil(cdr)) cdr else null;
        return car;
    }

    /// Note that if T is null, this can return null, so an empty list raises an
    /// error instead to avoid ambiguity.
    pub fn nextType(self: *ListConverter, comptime T: type, allocator: std.mem.Allocator) !T {
        const value = try self.next();
        return try self.env.convertFrom(T, value, allocator);
    }
};

/// Wrap a native Zig function as an Emacs C module function
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
            raw_env: [*c]c.emacs_env,
            nargs: isize,
            args: [*c]c.emacs_value,
            data: ?*anyopaque,
        ) callconv(.c) c.emacs_value {
            _ = nargs;
            _ = data;
            const env = Env.fromRaw(raw_env) orelse unreachable;
            const q_nil = env.nil();

            // Set the active env so our logFn can find it
            active_env = env;
            defer active_env = null;

            var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer arena.deinit();
            const allocator = arena.allocator();
            var ctx: Context = .{ .env = env, .arena = allocator };

            // Build tuple of arguments converted at comptime
            var args_tuple: std.meta.ArgsTuple(@TypeOf(func)) = undefined;
            inline for (func_info.params, 0..) |param, i| {
                if (i == 0) {
                    args_tuple[0] = &ctx;
                } else if (param.type.? == EmacsValue) {
                    args_tuple[i] = args[i - 1];
                } else {
                    args_tuple[i] = env.convertFrom(param.type.?, args[i - 1], allocator) catch |err| {
                        ctx.setError("{t}: Error converting emacs argument with index {d} ", .{err, i});
                        ctx.signalError(.{});
                        return q_nil;
                    };
                }
            }

            // Call native Zig function
            const r_type, const r_val = blk: {
                if (@typeInfo(return_type) == .error_union) {
                    const result = @call(.auto, func, args_tuple) catch |err| {
                        if (ctx.err_msg == null) {
                            ctx.setError("Error: {t}", .{err});
                        }
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
            if (r_type == EmacsValue) return r_val;
            return env.convertTo(r_type, r_val) catch |err| {
                ctx.setError("Error converting return value: {t}", .{err});
                ctx.signalError(.{});
                return q_nil;
            };
        }
    }.f;
}

/// Register a native Zig function directly into Emacs with type conversions.
/// The function must have `*Context` as the first argument.
pub fn registerFunc(
    env: Env,
    name: [:0]const u8,
    comptime func: anytype,
    doc: [:0]const u8,
) void {
    const emacs_func = wrapFunc(func);
    const param_count = @typeInfo(@TypeOf(func)).@"fn".params.len - 1;
    env.registerFunc(name, param_count, param_count, emacs_func, doc);
}
