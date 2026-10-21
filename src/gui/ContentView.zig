const std = @import("std");
const dvui = @import("dvui");

const ilm = @import("ilm");
const Core = ilm.Core;
const Self = @This();
const ConceptsView = @import("ConceptsView.zig");
const PeersView = @import("PeersView.zig");
const DevView = @import("DevView.zig");
const gui = @import("gui.zig");

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
    const screen_size: gui.ScreenSize = .get();
    if (screen_size.width == .compact) {
        self.renderContent();
        self.renderTabs(screen_size);
    } else {
        self.renderTabs(screen_size);
        self.renderContent();
    }
}

fn renderTabs(self: *Self, size: gui.ScreenSize) void {
    var box = dvui.box(
        @src(),
        .{ .dir = .horizontal },
        .{
            .expand = .horizontal,
            .background = true,
            .padding = if (size.width == .compact) .{ .h = 6, .y = 6 } else null,
        },
    );
    defer box.deinit();

    const tab_names = [_][]const u8{ "concepts", "peers", "debug" };
    for (tab_names, 0..) |tab_name, tab_index| {
        const is_selected = self.tab == tab_index;
        const tab_opts: dvui.Options = .{
            .id_extra = tab_index,
            .background = false,
            .border = .all(0.0),
            .font = dvui.Font.theme(.mono).larger(4.5),
            .color_text = if (is_selected) null else .{ .color = .gray },
            .color_text_hover = if (is_selected)
                .{ .color = dvui.themeGet().text }
            else if (dvui.themeGet().text_hover) |c| .{ .color = c } else null,
        };
        if (dvui.button(@src(), tab_name, .{ .draw_focus = false }, tab_opts)) {
            self.tab = tab_index;
        }
    }

    _ = dvui.spacer(@src(), .{ .expand = .horizontal });

    var menu = dvui.menu(@src(), .horizontal, .{ .expand = .vertical });
    defer menu.deinit();

    if (dvui.menuItemIcon(@src(), "dots", dvui.entypo.dots_three_vertical, .{ .submenu = true, .focus_as_outline = true }, .{ .expand = .vertical, .background = false, .gravity_y = 0.5, .margin = .{ .w = 6 } })) |r| {
        var float_menu = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer float_menu.deinit();

        if (dvui.menuItemLabel(@src(), "Sync with peers", .{}, .{})) |_| {
            var iter = self.core.router.connections.peers.valueIterator();
            while (iter.next()) |peer| {
                self.core.router.sendSyncRequest(peer.*.id) catch {};
            }
            float_menu.close();
        }
    }
}

fn renderContent(self: *Self) void {
    switch (self.tab) {
        0 => self.concepts_view.render(),
        1 => self.peers_view.render(),
        2 => self.dev_view.render(),
        else => {},
    }
}
