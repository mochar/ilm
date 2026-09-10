const std = @import("std");
pub const Core = @import("Core.zig");
pub const database = @import("database.zig");
pub const Id = database.Id;
pub const concept = @import("concept.zig");
pub const Graph = @import("Graph.zig");

test {
    _ = @import("concept.zig");
    _ = @import("Graph.zig");
}
