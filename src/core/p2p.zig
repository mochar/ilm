const std = @import("std");
const iroh = @import("iroh").c;

/// 32-byte secret key.
pub const SecretKey = struct {
    ptr: *iroh.SecretKey_t,

    pub fn generate() SecretKey {
        return .{ .ptr = iroh.secret_key_generate() orelse @panic("failed to generate secret key") };
    }

    pub fn deinit(self: *const SecretKey) void {
        iroh.secret_key_free(self.ptr);
    }

    /// Derives the corresponding public key.
    pub fn public(self: *const SecretKey) PublicKey {
        return .{ .raw = iroh.secret_key_public(self.ptr) };
    }

    /// Returns the 64-character hex-encoded string representation
    pub fn asHex(self: *const SecretKey) [64]u8 {
        const c_str = iroh.secret_key_as_base32(self.ptr) orelse @panic("secret_key_as_base32 returned null");
        defer iroh.rust_free_string(c_str);

        const slice = std.mem.span(c_str);
        var result: [64]u8 = undefined;
        @memcpy(&result, slice[0..64]);
        return result;
    }

    /// Allocates and returns a hex-encoded string.
    pub fn toHexAlloc(self: *const SecretKey, allocator: std.mem.Allocator) ![]u8 {
        const c_str = iroh.secret_key_as_base32(self.ptr) orelse return error.OutOfMemory;
        defer iroh.rust_free_string(c_str);
        return allocator.dupe(u8, std.mem.span(c_str));
    }
};

/// 32-byte public key / NodeId.
pub const PublicKey = struct {
    raw: iroh.PublicKey_t,

    /// Returns the raw 32-byte public key array.
    pub fn bytes(self: *const PublicKey) *const [32]u8 {
        return &self.raw.key;
    }

    /// Allocates and returns the base32 string representation.
    pub fn toBase32(self: *const PublicKey, allocator: std.mem.Allocator) ![]u8 {
        const c_str = iroh.public_key_as_base32(&self.raw) orelse return error.OutOfMemory;
        defer iroh.rust_free_string(c_str);
        return allocator.dupe(u8, std.mem.span(c_str));
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
