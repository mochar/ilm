const std = @import("std");
const dvui = @import("dvui");

const ilm = @import("ilm");
const Core = ilm.Core;
const Self = @This();
const Concepts = @import("Concepts.zig");

gpa: std.mem.Allocator,
core: *Core,
concepts: Concepts,
tab: usize = 0,

pub fn init(gpa: std.mem.Allocator, core: *Core) !Self {
    return .{
        .gpa = gpa,
        .core = core,
        .concepts = try .init(gpa, core),
    };
}

pub fn deinit(self: *Self) void {
    self.concepts.deinit();
}

pub fn render(self: *Self) ?dvui.App.Result {
    {
        var tabs = dvui.tabs(@src(), .{}, .{});
        defer tabs.deinit();
        if (tabs.addTabLabel(true, "Concepts", .{})) {
            self.tab = 0;
        }
    }

    {
        if (self.tab == 0) {
            self.concepts.render();
        }
    }

    return null;
}
