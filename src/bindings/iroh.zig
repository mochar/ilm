const std = @import("std");
const sqlite = @import("sqlite");
const c = @import("c");

const log = std.log.scoped(.iroh);

pub fn enableTracing() void {
    c.iroh_enable_tracing();
}

/// 32-byte secret key.
pub const SecretKey = struct {
    pub const KEY_LEN = 32;
    pub const HEX_LEN = 64;

    ptr: *c.SecretKey_t,

    pub fn generate() SecretKey {
        return .{ .ptr = c.secret_key_generate() orelse @panic("failed to generate secret key") };
    }

    pub fn default() SecretKey {
        return .{ .ptr = c.secret_key_default() orelse @panic("failed to create secret key") };
    }

    pub fn deinit(self: *const SecretKey) void {
        c.secret_key_free(self.ptr);
    }

    /// Derives the corresponding public key.
    pub fn public(self: *const SecretKey) PublicKey {
        return .{ .key = c.secret_key_public(self.ptr) };
    }

    /// Returns the 64-character hex-encoded string representation
    pub fn asHex(self: *const SecretKey) [HEX_LEN]u8 {
        const c_str = c.secret_key_as_base32(self.ptr) orelse @panic("secret_key_as_base32 returned null");
        defer c.rust_free_string(c_str);

        const slice = std.mem.span(c_str);
        var result: [64]u8 = undefined;
        @memcpy(&result, slice[0..64]);
        return result;
    }

    /// Allocates and returns a hex-encoded string.
    pub fn toHexAlloc(self: *const SecretKey, allocator: std.mem.Allocator) ![]u8 {
        const c_str = c.secret_key_as_base32(self.ptr) orelse return error.OutOfMemory;
        defer c.rust_free_string(c_str);
        return allocator.dupe(u8, std.mem.span(c_str));
    }

    /// Return a SecretKey from a hex encoded string.
    pub fn fromHex(hex_str: []const u8) !SecretKey {
        if (hex_str.len != 64) return error.InvalidLength;

        // Copy as zero terminated
        var buf: [65]u8 = undefined;
        var alloc = std.heap.FixedBufferAllocator.init(&buf);
        _ = alloc.allocator().dupeZ(u8, hex_str) catch unreachable;

        var secret_key = SecretKey.default();
        errdefer secret_key.deinit();

        if (c.secret_key_from_base32(&buf, @ptrCast(&secret_key.ptr)) != 0) {
            return error.InvalidKey;
        }

        return secret_key;
    }

    pub fn dupe(self: *const SecretKey) !SecretKey {
        const hex = self.asHex();
        return try .fromHex(&hex);
    }
};

/// Alias of EndpointId.
/// 32-byte public key / NodeId.
pub const PublicKey = struct {
    pub const KEY_LEN = 32;
    pub const HEX_LEN = 64;

    key: c.PublicKey_t,

    pub const PublicKeyError = error{
        InvalidPublicKey,
        InvalidSecretKey,
    };

    fn checkErrorResult(result: c_int) ?PublicKeyError {
        return switch (result) {
            c.KEY_RESULT_OK => null,
            c.KEY_RESULT_INVALID_PUBLIC_KEY => error.InvalidPublicKey,
            c.KEY_RESULT_INVALID_SECRET_KEY => error.InvalidSecretKey,
            else => unreachable,
        };
    }

    pub fn default() PublicKey {
        return .{ .key = c.public_key_default() };
    }

    pub fn fromBytes(key_bytes: []const u8) !PublicKey {
        if (key_bytes.len != 32) return error.InvalidSize;
        var key: PublicKey = .default();
        @memcpy(&key.key.key.idx, key_bytes[0..32]);
        return key;
    }

    pub fn deinit(self: *const PublicKey) void {
        c.public_key_free(self.key);
    }

    /// Returns reference to the raw 32-byte public key array.
    pub fn bytes(self: *const PublicKey) *const [32]u8 {
        return &self.key.key.idx;
    }

    /// Returns the raw 32-byte public key array.
    pub fn copyBytes(self: *const PublicKey) [32]u8 {
        return self.key.key.idx;
    }

    // TODO This is just regular hex encoding so we can use zig for this instead.
    /// Returns the 64-character hex-encoded string representation
    pub fn toHex(self: *const PublicKey) [64:0]u8 {
        const c_str = c.public_key_as_base32(&self.key) orelse @panic("secret_key_as_base32 returned null");
        defer c.rust_free_string(c_str);
        const result: [64:0]u8 = c_str[0..64 :0].*;
        return result;
    }

    /// Return a PublicKey from a hex encoded string.
    pub fn fromHex(hex_str: []const u8) !PublicKey {
        if (hex_str.len != 64) return error.InvalidLength;

        // Copy as zero terminated
        var buf: [65]u8 = undefined;
        var alloc = std.heap.FixedBufferAllocator.init(&buf);
        _ = alloc.allocator().dupeZ(u8, hex_str) catch unreachable;

        var public_key = PublicKey.default();
        errdefer public_key.deinit();

        const errno = c.public_key_from_base32(&buf, &public_key.key);
        if (checkErrorResult(errno)) |err| {
            log.err("Invalid endpoint id ({t}): {s}", .{ err, hex_str });
            return err;
        }

        return public_key;
    }
};

pub const EndpointAddr = struct {
    addr: c.EndpointAddr_t,
    id: PublicKey,

    pub fn fromAddr(addr: c.EndpointAddr_t) EndpointAddr {
        return .{ .addr = addr, .id = .{ .key = addr.id } };
    }

    pub fn fromPublicKey(public_key: *const PublicKey) EndpointAddr {
        const addr = c.endpoint_addr_new(public_key.key);
        return .fromAddr(addr);
    }

    pub fn copy(self: *const EndpointAddr) EndpointAddr {
        return .fromPublicKey(&self.id);
    }

    pub fn deinit(self: *const EndpointAddr) void {
        c.endpoint_addr_free(self.addr);
    }

    /// A token containing information for establishing a connection to an endpoint.
    /// https://docs.rs/iroh-tickets/latest/iroh_tickets/endpoint/struct.EndpointTicket.html
    /// https://docs.iroh.computer/concepts/tickets
    pub fn ticketAlloc(self: *const EndpointAddr, alloc: std.mem.Allocator) ![]const u8 {
        const c_str = c.endpoint_addr_as_str(&self.addr);
        defer c.rust_free_string(c_str);
        return try alloc.dupe(u8, std.mem.span(c_str));
    }

    pub fn relayUrlNthAlloc(self: *const EndpointAddr, alloc: std.mem.Allocator, nth: usize) !?[]const u8 {
        const relay_url = c.endpoint_addr_relay_urls_nth(&self.addr, nth);
        if (relay_url.*) |url| {
            const c_str = c.url_as_str(url);
            defer c.rust_free_string(c_str);
            return try alloc.dupe(u8, std.mem.span(c_str));
        }
        return null;
    }
};

pub const EndpointError = error{
    BindError,
    AcceptFailed,
    AcceptUniFailed,
    AcceptBiFailed,
    ConnectUniError,
    ConnectBiError,
    ConnectError,
    AddrError,
    SendError,
    ReadError,
    Timeout,
    CloseError,
    IncomingError,
    ConnectionTypeError,
    UnknownError, // For unexpected C values
};

/// Converts the EndpointResult errno into a EndpointError error
pub fn checkEndpointResult(result: c_int) ?EndpointError {
    return switch (result) {
        c.ENDPOINT_RESULT_OK => null,
        c.ENDPOINT_RESULT_BIND_ERROR => error.BindError,
        c.ENDPOINT_RESULT_ACCEPT_FAILED => error.AcceptFailed,
        c.ENDPOINT_RESULT_ACCEPT_UNI_FAILED => error.AcceptUniFailed,
        c.ENDPOINT_RESULT_ACCEPT_BI_FAILED => error.AcceptBiFailed,
        c.ENDPOINT_RESULT_CONNECT_UNI_ERROR => error.ConnectUniError,
        c.ENDPOINT_RESULT_CONNECT_BI_ERROR => error.ConnectBiError,
        c.ENDPOINT_RESULT_CONNECT_ERROR => error.ConnectError,
        c.ENDPOINT_RESULT_ADDR_ERROR => error.AddrError,
        c.ENDPOINT_RESULT_SEND_ERROR => error.SendError,
        c.ENDPOINT_RESULT_READ_ERROR => error.ReadError,
        c.ENDPOINT_RESULT_TIMEOUT => error.Timeout,
        c.ENDPOINT_RESULT_CLOSE_ERROR => error.CloseError,
        c.ENDPOINT_RESULT_INCOMING_ERROR => error.IncomingError,
        c.ENDPOINT_RESULT_CONNECTION_TYPE_ERROR => error.ConnectionTypeError,
        else => error.UnknownError,
    };
}

pub const Alpn = struct {
    alpn: []const u8,

    pub fn slice(self: *const Alpn) c.slice_ref_uint8_t {
        var alpn_slice: c.slice_ref_uint8_t = undefined;
        alpn_slice.ptr = self.alpn.ptr;
        alpn_slice.len = self.alpn.len;
        return alpn_slice;
    }
};

pub const ConnectionTarget = union(enum) {
    /// A copy is made so dont forget to free yours
    addr: *const EndpointAddr,
    /// A copy is made so dont forget to free yours
    public_key: *const PublicKey,
    // Can be either raw bytes or hex
    id: []const u8,

    pub fn copyAddr(target: @This()) !EndpointAddr {
        const addr: EndpointAddr = switch (target) {
            .addr => |addr| addr.copy(),
            .public_key => |pk| EndpointAddr.fromPublicKey(pk),
            .id => |id| blk: {
                const pk = if (id.len == 64)
                    try PublicKey.fromHex(id)
                else if (id.len == 32)
                    try PublicKey.fromBytes(id)
                else
                    return error.InvalidID;
                defer pk.deinit();
                break :blk EndpointAddr.fromPublicKey(&pk);
            },
        };
        return addr;
    }
};

pub const Endpoint = struct {
    gpa: std.mem.Allocator,
    ptr: *c.Endpoint_t,
    alpn: *const Alpn,
    state: union(enum) {
        bound,
        online: OnlineState,
        closed,
    },

    pub const OnlineState = struct {
        addr: EndpointAddr,
        /// Note this just addr.id.toHex(), but stored here for
        /// convenience.
        id: [64:0]u8,
        relay_url: []const u8,
        ticket: []const u8,

        pub fn deinit(self: *const OnlineState, alloc: std.mem.Allocator) void {
            self.addr.deinit();
            alloc.free(self.relay_url);
            alloc.free(self.ticket);
        }
    };

    pub const Options = struct {
        gpa: std.mem.Allocator,
        alpn: *const Alpn,
        /// Transfer ownership, do not free!
        secret_key: ?SecretKey = null,
    };

    pub fn init(opts: Options) !Endpoint {
        var config = c.endpoint_config_default();
        defer c.endpoint_config_free(config);
        config.discovery_cfg = c.DISCOVERY_CONFIG_ALL;
        if (opts.secret_key) |secret_key| {
            // Note: I get a double free error when freeing secret key
            // afterwards, so it seems to be consumed by iroh already.
            config.secret_key = secret_key.ptr;
        }
        const slice = opts.alpn.slice();
        c.endpoint_config_add_alpn(&config, slice);

        const endpoint = c.endpoint_default() orelse unreachable;
        errdefer c.endpoint_free(endpoint);
        const bind_res = c.endpoint_bind(&config, null, null, &endpoint);
        if (bind_res != 0) return error.BindFailed;

        return .{
            .gpa = opts.gpa,
            .ptr = endpoint,
            .alpn = opts.alpn,
            .state = .bound,
        };
    }

    pub fn deinit(self: *const Endpoint) void {
        if (self.state != .closed) c.endpoint_free(self.ptr);
        switch (self.state) {
            .bound, .closed => {},
            .online => |state| state.deinit(self.gpa),
        }
    }

    pub fn ensureOnline(self: *Endpoint) EndpointError!void {
        self.checkOnline(.{}) catch |err| {
            switch (self.state) {
                .online => |state| state.deinit(self.gpa),
                else => {},
            }
            return err;
        };

        // Get our address
        var addr_c = c.endpoint_addr_default();
        const addr_res = c.endpoint_addr(&self.ptr, &addr_c);
        if (checkEndpointResult(addr_res)) |err| return err;
        const addr = EndpointAddr.fromAddr(addr_c);
        const id = addr.id.toHex();
        // TODO Can use addr_c.relay_urls.len to ensure not null
        const relay_url = if (addr.relayUrlNthAlloc(self.gpa, 0)) |url|
            url orelse unreachable
        else |_|
            @panic("OOM");
        const ticket = addr.ticketAlloc(self.gpa) catch @panic("OOM");
        self.state = .{ .online = .{
            .addr = addr,
            .id = id,
            .relay_url = relay_url,
            .ticket = ticket,
        } };
    }

    pub fn logAddr(self: *Endpoint) void {
        switch (self.state) {
            .online => |state| {
                log.info("Listening on:", .{});
                log.info("  Endpoint Id: {s}", .{state.id});
                log.info("  Ticket: {s}", .{state.ticket});
                log.info("  Relay: {s}", .{state.relay_url});
                log.info("  Addrs:", .{});
                for (0..state.addr.addr.ip_addrs.len - 1) |i| {
                    const socket_addr = c.endpoint_addr_ip_addrs_nth(&state.addr.addr, i);
                    const socket_str = c.socket_addr_as_str(socket_addr);
                    defer c.rust_free_string(socket_str);
                    log.info("    - {s}", .{socket_str});
                }
            },
            else => {},
        }
    }

    /// Returns once the endpoint is online.
    ///
    /// We are considered online if we have a home relay and at least one
    /// direct address.
    ///
    /// Will block at most `timeout` milliseconds.
    pub fn checkOnline(self: *const Endpoint, opts: struct { timeout_ms: u64 = 5000 }) EndpointError!void {
        const errno = c.endpoint_online(&self.ptr, opts.timeout_ms);
        if (checkEndpointResult(errno)) |err| {
            log.err("Failed to get a home relay: {t}", .{err});
            return err;
        }
    }

    /// Accept a new connection on this endpoint.
    ///
    /// Blocks the current thread until a connection is established.
    pub fn accept(self: *const Endpoint) EndpointError!Connection {
        var conn = c.connection_default() orelse return error.UnknownError;
        errdefer c.connection_free(conn);

        const errno = c.endpoint_accept(&self.ptr, self.alpn.slice(), &conn);
        if (checkEndpointResult(errno)) |err| {
            log.err("Failed to accept connection: {t}", .{err});
            return err;
        }
        errdefer c.connection_close(conn);

        const pkey: PublicKey = .{ .key = c.connection_remote_id(&conn) };
        defer pkey.deinit();
        const addr: EndpointAddr = .fromPublicKey(&pkey);

        return .{ .ptr = conn, .alpn = self.alpn, .addr = addr };
    }

    /// Blocks all incoming connections and then waits for all current connections
    /// to close gracefully, before shutting down the endpoint.
    /// Consumes the endpoint, no need to free it afterwards.
    pub fn close(self: *Endpoint) void {
        c.endpoint_close(self.ptr);
        self.state = .closed;
        self.deinit();
    }

    pub fn connect(self: *const Endpoint, ep: ConnectionTarget) EndpointError!Connection {
        const addr = ep.copyAddr() catch return error.AddrError;
        const conn = Connection.default(self.alpn, addr);
        const alpn_slice = self.alpn.slice();
        const errno = c.endpoint_connect(&self.ptr, alpn_slice, addr.addr, &conn.ptr);
        if (checkEndpointResult(errno)) |err| {
            log.err("Failed to connect to server: {t}", .{err});
            return err;
        }
        return conn;
    }
};

pub const Connection = struct {
    ptr: *c.Connection_t,
    alpn: *const Alpn,
    /// Address of the endpoint we are connected to. Owns it.
    addr: EndpointAddr,

    pub fn default(alpn: *const Alpn, addr: EndpointAddr) Connection {
        return .{
            .ptr = c.connection_default() orelse unreachable,
            .alpn = alpn,
            .addr = addr,
        };
    }

    pub fn deinit(self: *const Connection) void {
        c.connection_free(self.ptr);
        self.addr.deinit();
    }

    /// Close a connection.
    /// Consumes the connection, no need to free it afterwards.
    pub fn close(self: *const Connection) void {
        c.connection_close(self.ptr);
        self.addr.deinit();
    }

    /// Wait for the connection to be closed. Errors when failed to
    /// close cleanly, which can be ignored. Blocks the current
    /// thread.
    ///
    /// Consumes the connection, no need to free it afterwards.
    pub fn wait_close(self: *const Connection) EndpointError!void {
        // TODO Rust version returns ConnectionError enum with reason
        // for why it is closed. One of them is ConnectionClosed that
        // contains struct Closed with some info.
        const errno = c.connection_closed(self.ptr);
        if (checkEndpointResult(errno)) |err| {
            log.err("Failed to close connection cleanly: {t}", .{err});
            return err;
        }
    }

    pub fn openUniStream(self: *const Connection) EndpointError!SendStream {
        var stream = SendStream.default();
        errdefer stream.deinit();

        const errno = c.connection_open_uni(&self.ptr, @ptrCast(&stream.ptr));
        if (checkEndpointResult(errno)) |err| {
            log.err("Failed to establish send stream: {t}", .{err});
            return err;
        }

        return stream;
    }

    pub fn acceptUniStream(self: *const Connection) EndpointError!RecvStream {
        var stream = RecvStream.default();
        errdefer stream.deinit();

        const errno = c.connection_accept_uni(&self.ptr, @ptrCast(&stream.ptr));
        if (checkEndpointResult(errno)) |err| {
            log.err("Failed to accept uni stream: {t}", .{err});
            return err;
        }

        return stream;
    }

    pub fn openBiStream(self: *const Connection) EndpointError!BiStream {
        var send_stream = SendStream.default();
        errdefer send_stream.deinit();

        var recv_stream = RecvStream.default();
        errdefer recv_stream.deinit();

        const errno = c.connection_open_bi(&self.ptr, @ptrCast(&send_stream.ptr), @ptrCast(&recv_stream.ptr));
        if (checkEndpointResult(errno)) |err| {
            log.err("Failed to establish bi stream: {t}", .{err});
            return err;
        }

        return .{ .send = send_stream, .recv = recv_stream };
    }

    pub fn acceptBiStream(self: *const Connection) EndpointError!BiStream {
        var send_stream = SendStream.default();
        errdefer send_stream.deinit();

        var recv_stream = RecvStream.default();
        errdefer recv_stream.deinit();

        const errno = c.connection_accept_bi(&self.ptr, @ptrCast(&send_stream.ptr), @ptrCast(&recv_stream.ptr));
        if (checkEndpointResult(errno)) |err| {
            log.err("Failed to accept bi stream: {t}", .{err});
            return err;
        }

        return .{ .send = send_stream, .recv = recv_stream };
    }
};

pub const BiStream = struct {
    send: SendStream,
    recv: RecvStream,

    pub fn deinit(self: *BiStream) void {
        self.recv.deinit();
        self.send.deinit();
    }
};

pub const SendStream = struct {
    ptr: *c.SendStream_t,
    freed: bool = false,

    pub fn default() SendStream {
        const stream = c.send_stream_default() orelse unreachable;
        return .{ .ptr = stream };
    }

    /// Must be called before Endpoint.deinit()!
    pub fn deinit(self: *SendStream) void {
        if (self.freed) return;
        c.send_stream_free(self.ptr);
        self.freed = true;
    }

    /// Finish the sending on this stream.
    /// Consumes the send stream, no need to free it afterwards.
    ///
    /// Note that finishing can fail when not all data was managed to
    /// be send before closing the stream. However this function does
    /// not error when that happens, only logs it.
    pub fn finish(self: *SendStream) void {
        const errno = c.send_stream_finish(self.ptr);
        if (checkEndpointResult(errno)) |err| {
            log.err("Failed to finish sending: {t}", .{err});
        }
        self.freed = true;
    }

    /// Send data on the stream. If timeout not null, returns an error
    /// if the data was not written before it.
    ///
    /// Blocks current thread.
    pub fn write(
        self: *const SendStream,
        // data: [:0]const u8,
        data: []const u8,
        timeout_ms: ?u64,
    ) EndpointError!void {
        var data_slice: c.slice_ref_uint8_t = undefined;
        data_slice.ptr = data.ptr;
        data_slice.len = data.len;

        const errno = if (timeout_ms) |timeout|
            c.send_stream_write_timeout(@ptrCast(@constCast(&self.ptr)), data_slice, timeout)
        else
            c.send_stream_write(@ptrCast(@constCast(&self.ptr)), data_slice);
        if (checkEndpointResult(errno)) |err| {
            log.err("Failed to send data: {t}", .{err});
            return err;
        }
    }
};

pub const RecvStream = struct {
    ptr: *c.RecvStream_t,
    freed: bool = false,

    pub fn default() RecvStream {
        const stream = c.recv_stream_default() orelse unreachable;
        return .{ .ptr = stream };
    }

    pub fn deinit(self: *RecvStream) void {
        if (self.freed) return;
        c.recv_stream_free(self.ptr);
        self.freed = true;
    }

    /// Return slice in buf of data that was read, or null if EOF.
    pub fn read(self: *const RecvStream, buf: []u8, timeout_ms: ?u64) EndpointError![]const u8 {
        var buf_slice: c.slice_mut_uint8 = undefined;
        buf_slice.ptr = buf.ptr;
        buf_slice.len = buf.len;

        // Seems this api is still WIP, the rust function has
        // commented out accepting n_read as a pointer and returning
        // an error instead. Right now returns -1 as error, which
        // makes it ambiguous what caused it.
        const n_read = if (timeout_ms) |timeout|
            c.recv_stream_read_timeout(@ptrCast(@constCast(&self.ptr)), buf_slice, timeout)
        else
            c.recv_stream_read(@ptrCast(@constCast(&self.ptr)), buf_slice);

        if (n_read == -1) {
            log.err("Failed to recieve data", .{});
            return EndpointError.ReadError;
        }
        // if (n_read == 0) return null;

        return buf[0..@intCast(n_read)];
    }

    pub fn readToEnd(self: *const RecvStream, buffer: []u8, timeout_ms: u64) EndpointError![]const u8 {
        var rust_buffer = c.rust_buffer_alloc(0);
        defer c.rust_buffer_free(rust_buffer);
        const errno = c.recv_stream_read_to_end_timeout(
            @ptrCast(@constCast(&self.ptr)),
            &rust_buffer,
            buffer.len,
            timeout_ms,
        );
        if (checkEndpointResult(errno)) |err| {
            log.err("Failed to read stream: {t}", .{err});
            return err;
        }
        @memcpy(buffer[0..rust_buffer.len], rust_buffer.ptr[0..rust_buffer.len]);
        return buffer[0..rust_buffer.len];
    }

    pub fn readExact(self: *const RecvStream, buf: []u8, timeout_ms: u64) EndpointError![]const u8 {
        var buf_slice: c.slice_mut_uint8 = undefined;
        buf_slice.ptr = buf.ptr;
        buf_slice.len = buf.len;

        const rc = c.recv_stream_read_exact_timeout(@ptrCast(@constCast(&self.ptr)), buf_slice, timeout_ms);
        if (checkEndpointResult(rc)) |err| {
            log.err("Failed to read stream: {t}", .{err});
            return err;
        }

        return buf;
    }
};

test "SecretKey generation, hex encoding, and public key" {
    const key = SecretKey.generate();
    defer key.deinit();

    const hex = key.asHex();
    try std.testing.expectEqual(64, hex.len);
    for (hex) |ch| {
        try std.testing.expect((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'));
    }

    const hex_alloc = try key.toHexAlloc(std.testing.allocator);
    defer std.testing.allocator.free(hex_alloc);
    try std.testing.expectEqualSlices(u8, &hex, hex_alloc);

    const pubkey = key.public();
    const b32 = try pubkey.toBase32(std.testing.allocator);
    defer std.testing.allocator.free(b32);
    try std.testing.expect(b32.len > 0);
}
