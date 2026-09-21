const std = @import("std");
const c = @import("c");

/// 32-byte secret key.
pub const SecretKey = struct {
    ptr: *c.SecretKey_t,

    pub fn generate() SecretKey {
        return .{ .ptr = c.secret_key_generate() orelse @panic("failed to generate secret key") };
    }

    pub fn deinit(self: *const SecretKey) void {
        c.secret_key_free(self.ptr);
    }

    /// Derives the corresponding public key.
    pub fn public(self: *const SecretKey) PublicKey {
        return .{ .key = c.secret_key_public(self.ptr) };
    }

    /// Returns the 64-character hex-encoded string representation
    pub fn asHex(self: *const SecretKey) [64]u8 {
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
};

/// 32-byte public key / NodeId.
pub const PublicKey = struct {
    key: c.PublicKey_t,

    /// Returns the raw 32-byte public key array.
    pub fn bytes(self: *const PublicKey) *const [32]u8 {
        return &self.key.key;
    }

    /// Allocates and returns the base32 string representation.
    pub fn toBase32(self: *const PublicKey, allocator: std.mem.Allocator) ![]u8 {
        const c_str = c.public_key_as_base32(&self.key) orelse return error.OutOfMemory;
        defer c.rust_free_string(c_str);
        return allocator.dupe(u8, std.mem.span(c_str));
    }
};

pub const EndpointAddr = struct {
    addr: c.EndpointAddr_t,
    id: PublicKey,

    pub fn fromAddr(addr: c.EndpointAddr_t) EndpointAddr {
        return .{ .addr = addr, .id = .{ .key = addr.id } };
    }

    pub fn deinit(self: *const EndpointAddr) void {
        c.endpoint_addr_free(self.addr);
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

/// A struct container a pointer and len of u8s.
pub const SliceRef = struct {};

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
    state: union(enum) {
        bound: void,
        online: struct {
            addr: EndpointAddr,
            id: []const u8,
            relay_url: []const u8,
        },
    },

    pub fn init(gpa: std.mem.Allocator, alpn: []const u8) !Endpoint {
        var alpn_slice: c.slice_ref_uint8_t = undefined;
        alpn_slice.ptr = alpn.ptr;
        alpn_slice.len = alpn.len;

        var config = c.endpoint_config_default();
        defer c.endpoint_config_free(config);
        c.endpoint_config_add_alpn(&config, alpn_slice);
        config.discovery_cfg = c.DISCOVERY_CONFIG_ALL;

        const endpoint = c.endpoint_default() orelse unreachable;
        const bind_res = c.endpoint_bind(&config, null, null, &endpoint);
        if (bind_res != 0) return error.BindFailed;

        return .{ .gpa = gpa, .ptr = endpoint, .state = .bound };
    }

    pub fn deinit(endpoint: *Endpoint) void {
        c.endpoint_free(endpoint.ptr);
        switch (endpoint.state) {
            .bound => {},
            .online => |state| {
                state.addr.deinit();
                endpoint.gpa.free(state.id);
                endpoint.gpa.free(state.relay_url);
            },
        }
    }

    pub fn ensureOnline(endpoint: *Endpoint) EndpointError!void {
        try endpoint.checkOnline(.{});

        // Get our address
        var addr_c = c.endpoint_addr_default();
        const addr_res = c.endpoint_addr(&endpoint.ptr, &addr_c);
        if (checkEndpointResult(addr_res)) |err| return err;
        const addr = EndpointAddr.fromAddr(addr_c);
        const id = addr.id.toBase32(endpoint.gpa) catch @panic("OOM");
        // TODO Can use addr_c.relay_urls.len to ensure not null
        const relay_url = if (addr.relayUrlNthAlloc(endpoint.gpa, 0)) |url|
            url orelse unreachable
        else |_|
            @panic("OOM");
        endpoint.state = .{ .online = .{
            .addr = addr,
            .id = id,
            .relay_url = relay_url,
        } };
    }

    pub fn logAddr(endpoint: *Endpoint) void {
        switch (endpoint.state) {
            .online => |state| {
                std.log.info("Listening on:", .{});
                std.log.info("  Endpoint Id: {s}:", .{ state.id });
                std.log.info("  Relay: {s}:", .{ state.relay_url });
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
