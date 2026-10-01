const std = @import("std");
const dvui = @import("dvui");

const ilm = @import("ilm");
const Core = ilm.Core;
const Self = @This();
const ConceptsView = @import("ConceptsView.zig");
const PeersView = @import("PeersView.zig");

gpa: std.mem.Allocator,
core: *Core,
concepts_view: *ConceptsView,
peers_view: PeersView,
tab: usize = 0,

pub fn init(gpa: std.mem.Allocator, core: *Core) !Self {
    return .{
        .gpa = gpa,
        .core = core,
        .concepts_view = try .create(gpa, core),
        .peers_view = try .init(core, gpa),
    };
}

pub fn deinit(self: *Self) void {
    self.concepts_view.destroy();
    self.peers_view.deinit();
}

pub fn render(self: *Self) void {
    {
        var tabs = dvui.tabs(@src(), .{}, .{ .expand = .horizontal });
        defer tabs.deinit();

        const tab_names: [3][]const u8 = .{ "Concepts", "Peers", "Info" };
        for (tab_names, 0..) |tab_name, tab_index| {
            const is_selected = self.tab == tab_index;
            if (tabs.addTabLabel(true, tab_name, .{ .style = if (is_selected) .content else null })) {
                self.tab = tab_index;
            }
        }

        _ = dvui.spacer(@src(), .{ .expand = .horizontal });

        dvui.label(@src(), "FPS: {d}", .{dvui.currentWindow().FPS()}, .{});
    }

    {
        switch (self.tab) {
            0 => self.concepts_view.render(),
            1 => self.peers_view.render(),
            2 => {
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
