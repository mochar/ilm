const Self = @This();

const std = @import("std");
const dvui = @import("dvui");

const ilm = @import("ilm");
const Core = ilm.Core;
const CrdtView = @import("CrdtView.zig");

core: *Core,
crdt_view: CrdtView,
tab: usize = 0,

pub fn init(core: *Core) !Self {
    return .{
        .core = core,
        .crdt_view = try .init(core),
    };
}

pub fn deinit(self: *Self) void {
    self.crdt_view.deinit();
}

pub fn render(self: *Self) void {
    {
        var tabs = dvui.tabs(@src(), .{}, .{ .expand = .horizontal });
        defer tabs.deinit();

        const tab_names = [_][]const u8{ "Info", "Crdt" };
        for (tab_names, 0..) |tab_name, tab_index| {
            const is_selected = self.tab == tab_index;
            if (tabs.addTabLabel(true, tab_name, .{ .border = if (is_selected) null else .{ .h = 1.0 } })) {
                self.tab = tab_index;
            }
        }

        _ = dvui.spacer(@src(), .{ .expand = .horizontal });

        dvui.label(@src(), "FPS: {d}", .{dvui.currentWindow().FPS()}, .{});
    }

    {
        switch (self.tab) {
            0 => self.renderInfo() catch {},
            1 => self.crdt_view.render(),
            else => {},
        }
    }
}

pub fn renderInfo(self: *Self) !void {
    var box = dvui.box(@src(), .{}, .{ .expand = .both });
    defer box.deinit();

    var tl = dvui.textLayout(@src(), .{}, .{ .expand = .both, .font = .theme(.title) });
    tl.format("Path: {s}\n", .{self.core.data_dir}, .{});

    tl.addText("\n\nRouter\n", .{ .font = .theme(.heading) });

    {
        const group_pending = self.core.router.io_group.token.load(.unordered) != null;
        tl.addText(
            std.fmt.allocPrint(
                dvui.currentWindow().arena(),
                "Group has pending tasks: {s}",
                .{if (group_pending) "yes" else "no"},
            ) catch "OOM",
            .{},
        );
        tl.addText("  ", .{});

        const bo: dvui.Options = .{
            .background = true,
            .color_fill = .{ .color = dvui.themeGet().control.fill.? },
        };
        if (group_pending) {
            if (tl.addTextClick("Stop", bo)) |_| {
                self.core.router.stop() catch {};
            }
        } else {
            if (tl.addTextClick("Start", bo)) |_| {
                self.core.router.start() catch {};
            }
        }

        tl.addText("\n", .{});
    }

    {
        tl.addText("Connections:", .{});
        var iter = self.core.router.connections.peers.valueIterator();
        while (iter.next()) |conn_peer| {
            tl.format("\n  - {x}", .{conn_peer.*.id.bytes}, .{});
        }
    }

    tl.deinit();
}
