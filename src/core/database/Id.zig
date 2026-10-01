//! A wrapper around a u128 UUID. All rows use this ID type.
const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const uuid = @import("uuid");
const Id = @This();

int: u128,

pub const IntT = u128;
pub const StrT = [36]u8;
pub const ByteT = [16]u8;

pub fn new(io: std.Io) Id {
    return .{ .int = uuid.v7.new(io) };
}

pub fn fromInt(int: u128) Id {
    return .{ .int = int };
}

/// Parse a 36-character UUID string
pub fn parse(s: []const u8) !Id {
    return .{ .int = try uuid.urn.deserialize(s) };
}

pub fn serialize(self: Id) StrT {
    return uuid.urn.serialize(self.int);
}

// Emacs helpers to convert to and from string repr.
pub fn toEmacsRepr(self: Id) StrT {
    return self.serialize();
}

pub fn fromEmacsRepr(id_str: []const u8) !Id {
    return Id.parse(id_str);
}

// Sqlite helpers to convert to and from Blob.
// Note that when only the id is in the result set, the return
// type should be set to [16]u8 and then converted to Id struct using
// @bitCast. See example concept.getIdByRowId
pub const BaseType = sqlite.Blob;

pub fn asBlob(self: *const Id) sqlite.Blob {
    // Must take in a pointer, otherwise &self.int points to this functions
    // stack frame
    return sqlite.Blob{ .data = std.mem.asBytes(&self.int) };
}

pub fn bindField(self: Id, allocator: Allocator) !BaseType {
    // Since self is passed by value and sqlite.Blob only holds a reference,
    // need to allocate on heap. For this reason, prefer to do it manually:
    //   try stmt.exec(.{ .diags = diags }, .{ .id = id.asBlob(), .name = name });
    const bytes = try allocator.dupe(u8, std.mem.asBytes(&self.int));
    return .{ .data = bytes };
}

pub fn readField(_: Allocator, blob: BaseType) !Id {
    const uuid_int = std.mem.bytesAsValue(u128, blob.data);
    return .{ .int = uuid_int.* };
}
