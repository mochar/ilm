const std = @import("std");

pub fn main() !void {
    const size: u16 = 8;
    std.debug.print("{any}\n", .{std.mem.asBytes(&size)});
}
