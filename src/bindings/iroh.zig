const std = @import("std");
const c = @import("c");

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
};

/// Alias of EndpointId.
/// 32-byte public key / NodeId.
pub const PublicKey = struct {
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

    pub fn deinit(self: *const PublicKey) void {
        c.public_key_free(self.key);
    }

    /// Returns the raw 32-byte public key array.
    pub fn bytes(self: *const PublicKey) *const [32]u8 {
        return &self.key.key;
    }

    /// Returns the 64-character hex-encoded string representation
    pub fn toHex(self: *const PublicKey) [64:0]u8 {
        const c_str = c.public_key_as_base32(&self.key) orelse @panic("secret_key_as_base32 returned null");
        defer c.rust_free_string(c_str);

        // var result: [64:0]u8 = undefined;
        // @memcpy(&result, c_str[0..64]);
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
            std.log.err("Invalid endpoint id ({t}): {s}", .{ err, hex_str });
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

pub const Endpoint = struct {
    gpa: std.mem.Allocator,
    ptr: *c.Endpoint_t,
    alpn: []const u8,
    alpn_slice: c.slice_ref_uint8_t,
    state: union(enum) {
        bound: void,
        online: OnlineState,
    },

    pub const OnlineState = struct {
        addr: EndpointAddr,
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
        alpn: []const u8,
        /// Transfer ownership, do not free!
        secret_key: ?SecretKey = null,
    };

    /// ALPN is assumed to be a static slice or with lifetime longer than this.
    pub fn init(opts: Options) !Endpoint {
        var alpn_slice: c.slice_ref_uint8_t = undefined;
        alpn_slice.ptr = opts.alpn.ptr;
        alpn_slice.len = opts.alpn.len;

        var config = c.endpoint_config_default();
        defer c.endpoint_config_free(config);
        c.endpoint_config_add_alpn(&config, alpn_slice);
        config.discovery_cfg = c.DISCOVERY_CONFIG_ALL;
        if (opts.secret_key) |secret_key| {
            // Note: I get a double free error when freeing secret key
            // afterwards, so it seems to be consumed by iroh already.
            config.secret_key = secret_key.ptr;
        }

        const endpoint = c.endpoint_default() orelse unreachable;
        const bind_res = c.endpoint_bind(&config, null, null, &endpoint);
        if (bind_res != 0) return error.BindFailed;

        return .{
            .gpa = opts.gpa,
            .ptr = endpoint,
            .alpn = opts.alpn,
            .alpn_slice = alpn_slice,
            .state = .bound,
        };
    }

    pub fn deinit(endpoint: *Endpoint) void {
        c.endpoint_free(endpoint.ptr);
        switch (endpoint.state) {
            .bound => {},
            .online => |state| state.deinit(endpoint.gpa),
        }
    }

    pub fn ensureOnline(endpoint: *Endpoint) EndpointError!void {
        endpoint.checkOnline(.{}) catch |err| {
            switch (endpoint.state) {
                .online => |state| state.deinit(endpoint.gpa),
                else => {},
            }
            return err;
        };

        // Get our address
        var addr_c = c.endpoint_addr_default();
        const addr_res = c.endpoint_addr(&endpoint.ptr, &addr_c);
        if (checkEndpointResult(addr_res)) |err| return err;
        const addr = EndpointAddr.fromAddr(addr_c);
        const id = addr.id.toHex();
        // TODO Can use addr_c.relay_urls.len to ensure not null
        const relay_url = if (addr.relayUrlNthAlloc(endpoint.gpa, 0)) |url|
            url orelse unreachable
        else |_|
            @panic("OOM");
        const ticket = addr.ticketAlloc(endpoint.gpa) catch @panic("OOM");
        endpoint.state = .{
            .online = .{
                .addr = addr,
                .id = id,
                .relay_url = relay_url,
                .ticket = ticket,
            }
        };
    }

    pub fn logAddr(endpoint: *Endpoint) void {
        switch (endpoint.state) {
            .online => |state| {
                std.log.info("Listening on:", .{});
                std.log.info("  Endpoint Id: {s}", .{state.id});
                std.log.info("  Ticket: {s}", .{state.ticket});
                std.log.info("  Relay: {s}", .{state.relay_url});
                std.log.info("  Addrs:", .{});
                for (0..state.addr.addr.ip_addrs.len - 1) |i| {
                    const socket_addr = c.endpoint_addr_ip_addrs_nth(&state.addr.addr, i);
                    const socket_str = c.socket_addr_as_str(socket_addr);
                    defer c.rust_free_string(socket_str);
                    std.log.info("    - {s}", .{socket_str});
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
    pub fn checkOnline(endpoint: *const Endpoint, opts: struct { timeout_ms: u64 = 5000 }) EndpointError!void {
        const errno = c.endpoint_online(&endpoint.ptr, opts.timeout_ms);
        if (checkEndpointResult(errno)) |err| {
            std.log.err("Failed to get a home relay: {t}", .{err});
            return err;
        }
    }

    /// Accept a new connection on this endpoint.
    ///
    /// Blocks the current thread until a connection is established.
    pub fn accept(endpoint: *const Endpoint) EndpointError!Connection {
        const conn = Connection.default();
        const errno = c.endpoint_accept(&endpoint.ptr, endpoint.alpn_slice, &conn.ptr);
        if (checkEndpointResult(errno)) |err| {
            std.log.err("Failed to accept connection: {t}", .{err});
            return err;
        }
        return conn;
    }

    /// Blocks all incoming connections and then waits for all current connections
    /// to close gracefully, before shutting down the endpoint.
    /// Consumes the endpoint, no need to free it afterwards.
    pub fn close(endpoint: *const Endpoint) void {
        c.endpoint_close(&endpoint.ptr);
        endpoint.deinit();
    }

    pub fn connect(ep: *const Endpoint, addr: *const EndpointAddr) EndpointError!Connection {
        const conn = Connection.default();
        const errno = c.endpoint_connect(&ep.ptr, ep.alpn_slice, addr.addr, &conn.ptr);
        if (checkEndpointResult(errno)) |err| {
            std.log.err("Failed to connect to server: {t}", .{err});
            return err;
        }
        return conn;
    }
};

pub const Connection = struct {
    ptr: *c.Connection_t,

    pub fn default() Connection {
        return .{ .ptr = c.connection_default() orelse unreachable };
    }

    pub fn deinit(self: *const Connection) void {
        c.connection_free(self.ptr);
    }

    /// Close a connection.
    /// Consumes the connection, no need to free it afterwards.
    pub fn close(self: *const Connection) void {
        c.connection_close(self.ptr);
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
            std.log.err("Failed to close connection cleanly: {t}", .{err});
            return err;
        }
    }

    pub fn createSendStream(self: *const Connection) EndpointError!SendStream {
        return try SendStream.fromConnection(self);
    }

    pub fn createRecvStream(self: *const Connection) EndpointError!RecvStream {
        return try RecvStream.fromConnection(self);
    }
};

pub const SendStream = struct {
    ptr: *c.SendStream_t,

    pub fn fromConnection(conn: *const Connection) EndpointError!SendStream {
        var stream = c.send_stream_default() orelse unreachable;
        const errno = c.connection_open_uni(&conn.ptr, @ptrCast(&stream));
        if (checkEndpointResult(errno)) |err| {
            std.log.err("Failed to establish send stream: {t}", .{err});
            return err;
        }
        return .{ .ptr = stream };
    }

    /// Must be called before Endpoint.deinit()!
    pub fn deinit(self: *const SendStream) void {
        c.send_stream_free(self.ptr);
    }

    /// Finish the sending on this stream.
    /// Consumes the send stream, no need to free it afterwards.
    ///
    /// Note that finishing can fail when not all data was managed to
    /// be send before closing the stream. However this function does
    /// not error when that happens, only logs it.
    pub fn finish(self: *const SendStream) void {
        const errno = c.send_stream_finish(self.ptr);
        if (checkEndpointResult(errno)) |err| {
            std.log.err("Failed to finish sending: {t}", .{err});
        }
    }

    /// Send data on the stream. If timeout not null, returns an error
    /// if the data was not written before it.
    ///
    /// Blocks current thread.
    pub fn write(
        self: *SendStream,
        data: [:0]const u8,
        opts: struct { timeout_ms: ?u64 = null },
    ) EndpointError!void {
        var data_slice: c.slice_ref_uint8_t = undefined;
        data_slice.ptr = data.ptr;
        data_slice.len = data.len;

        const errno = if (opts.timeout_ms) |timeout|
            c.send_stream_write_timeout(@ptrCast(&self.ptr), data_slice, timeout)
        else
            c.send_stream_write(@ptrCast(&self.ptr), data_slice);
        if (checkEndpointResult(errno)) |err| {
            std.log.err("Failed to send data: {t}", .{err});
            return err;
        }
    }
};

pub const RecvStream = struct {
    ptr: *c.RecvStream_t,

    pub fn fromConnection(conn: *const Connection) EndpointError!RecvStream {
        var stream = c.recv_stream_default() orelse unreachable;
        const errno = c.connection_accept_uni(&conn.ptr, @ptrCast(&stream));
        if (checkEndpointResult(errno)) |err| {
            std.log.err("Failed to accept uni stream: {t}", .{err});
            return err;
        }
        return .{ .ptr = stream };
    }

    pub fn deinit(self: *RecvStream) void {
        c.recv_stream_free(self.ptr);
    }

    /// Return slice in buf of data that was read, or null if EOF.
    pub fn read(
        self: *RecvStream,
        buf: []u8,
        opts: struct { timeout_ms: ?u64 = null },
    ) EndpointError!?[]const u8 {
        var buf_slice: c.slice_mut_uint8 = undefined;
        buf_slice.ptr = buf.ptr;
        buf_slice.len = buf.len;

        // Seems this api is still WIP, the rust function has
        // commented out accepting n_read as a pointer and returning
        // an error instead. Right now returns -1 as error, which
        // makes it ambiguous what caused it.
        const n_read = if (opts.timeout_ms) |timeout|
            c.recv_stream_read_timeout(@ptrCast(&self.ptr), buf_slice, timeout)
        else
            c.recv_stream_read(@ptrCast(&self.ptr), buf_slice);

        if (n_read == -1) {
            std.log.err("Failed to recieve data", .{});
            return EndpointError.ReadError;
        }
        if (n_read == 0) return null;

        return buf[0..@intCast(n_read)];
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
