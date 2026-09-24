const std = @import("std");
const dvui = @import("dvui");

const ilm = @import("ilm");
const Core = ilm.Core;
const Self = @This();
const ConceptsView = @import("ConceptsView.zig");

gpa: std.mem.Allocator,
core: *Core,
concepts_view: ConceptsView,
tab: usize = 0,

pub fn init(gpa: std.mem.Allocator, core: *Core) !Self {
    return .{
        .gpa = gpa,
        .core = core,
        .concepts_view = try .init(gpa, core),
    };
}

pub fn deinit(self: *Self) void {
    self.concepts_view.deinit();
}

pub fn render(self: *Self) void {
    {
        var tabs = dvui.tabs(@src(), .{}, .{ .expand = .horizontal });
        defer tabs.deinit();
        if (tabs.addTabLabel(true, "Concepts", .{})) {
            self.tab = 0;
        }
        if (tabs.addTabLabel(true, "Info", .{})) {
            self.tab = 1;
        }
    }

    {
        switch (self.tab) {
            0 => self.concepts_view.render(),
            1 => {
                var tl = dvui.textLayout(@src(), .{}, .{ .expand = .both, .font = .theme(.title) });
                defer tl.deinit();
                tl.format("Path: {s}\n", .{self.core.data_dir}, .{});

                tl.addText("\n\nP2P\n", .{ .font = .theme(.heading) });
                switch (self.core.p2p.endpoint.state) {
                    .bound => tl.addText("Endpoint not online\n", .{}),
                    .online => |state| {
                        tl.addText("Endpoint id:\n", .{});
                        if (tl.addTextClick(&state.id, .{ .margin = .all(4.0) })) |_| {
                            dvui.clipboardTextSet(&state.id);
                            dvui.toast(@src(), .{ .message = "Endpoint ID copied to clipboard!" });
                        }
                        tl.addText("\nTicket is:\n", .{});
                        if (tl.addTextClick(state.ticket, .{ .margin = .all(4.0) })) |_| {
                            dvui.clipboardTextSet(state.ticket);
                            dvui.toast(@src(), .{ .message = "Ticket copied to clipboard!" });
                        }
                    },
                }
            },
            else => {},
        }
    }
}
