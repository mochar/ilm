const std = @import("std");

const T = enum { a, b };
const U = union(T) {
    a: usize,
    b: f32,
};

pub fn main() !void {
    const t =  T.b;
    const i = std.meta.fieldInfo(U, t);
    std.debug.print("{any}\n", .{i.type});
}
