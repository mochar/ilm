const std = @import("std");
const dvui = @import("dvui");

const ilm = @import("ilm");
const Core = ilm.Core;
const Self = @This();
const ConceptsView = @import("ConceptsView.zig");
const PeersView = @import("PeersView.zig");
const DevView = @import("DevView.zig");

gpa: std.mem.Allocator,
core: *Core,
concepts_view: *ConceptsView,
peers_view: PeersView,
dev_view: DevView,
tab: usize = 0,

pub fn init(gpa: std.mem.Allocator, core: *Core) !Self {
    try core.router.addEventTrigger(.{
        .ctx = dvui.currentWindow(),
        .triggerFn = onPeerEvent,
    });

    return .{
        .gpa = gpa,
        .core = core,
        .concepts_view = try .create(gpa, core),
        .peers_view = try .init(core),
        .dev_view = try .init(core),
    };
}

pub fn deinit(self: *Self) void {
    self.concepts_view.destroy();
    self.peers_view.deinit();
    self.dev_view.deinit();
}

fn onPeerEvent(window_opaque: ?*anyopaque, event: ilm.p2p.Router.Event) void {
    const window: *dvui.Window = @ptrCast(@alignCast(window_opaque orelse unreachable));
    switch (event) {
        .connected => dvui.toast(@src(), .{ .window = window, .message = "Connected to p2p client" }),
        .disconnected => dvui.toast(@src(), .{ .window = window, .message = "Disconnected from p2p client" }),
        .stream_received => dvui.toast(@src(), .{ .window = window, .message = "Stream received to p2p client" }),
        .stream_closed => dvui.toast(@src(), .{ .window = window, .message = "Stream closed to p2p client" }),
        .pair_request => |req| {
            const msg = std.fmt.allocPrint(window.arena(), "Pair request from '{s}'", .{req.name}) catch "OOM";
            dvui.toast(@src(), .{ .window = window, .message = msg });
        },
        .sync_start => |e| {
            const msg = std.fmt.allocPrint(window.arena(), "Syncing with '{s}'", .{e.peer.name}) catch "OOM";
            dvui.toast(@src(), .{ .window = window, .message = msg });
        },
        .sync_done => |sync| {
            const msg = if (sync.err) |err|
                std.fmt.allocPrint(window.arena(), "Sync failed with '{s}': {t}", .{ sync.peer.name, err }) catch "OOM"
            else
                std.fmt.allocPrint(window.arena(), "Synced with '{s}'", .{sync.peer.name}) catch "OOM";
            dvui.toast(@src(), .{ .window = window, .message = msg });
        },
        else => {},
    }
}

pub fn render(self: *Self) void {
    {
        var tabs = dvui.tabs(@src(), .{}, .{ .expand = .horizontal });
        defer tabs.deinit();

        const tab_names = [_][]const u8{ "Concepts", "Peers", "Debug" };
        for (tab_names, 0..) |tab_name, tab_index| {
            const is_selected = self.tab == tab_index;
            if (tabs.addTabLabel(true, tab_name, .{ .border = if (is_selected) null else .{ .h = 1.0 } })) {
                self.tab = tab_index;
            }
        }

        _ = dvui.spacer(@src(), .{ .expand = .horizontal });

        if (dvui.button(@src(), "Sync", .{}, .{.padding = .all(4.0)})) {
            var iter = self.core.router.connections.peers.valueIterator();
            while (iter.next()) |peer| {
                self.core.router.sendSyncRequest(peer.*.id) catch {};
            }
        }
    }

    {
        switch (self.tab) {
            0 => self.concepts_view.render(),
            1 => self.peers_view.render(),
            2 => self.dev_view.render(),
            else => {},
        }
    }
}
