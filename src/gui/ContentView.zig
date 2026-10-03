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
tab: usize = 1,

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
    };
}

pub fn deinit(self: *Self) void {
    self.concepts_view.destroy();
    self.peers_view.deinit();
}

fn onPeerEvent(window_opaque: ?*anyopaque, event: ilm.p2p.Router.Event) void {
    const window: *dvui.Window = @ptrCast(@alignCast(window_opaque orelse unreachable));
    switch (event) {
        .connected => dvui.toast(@src(), .{ .window = window, .message = "Connected to p2p client" }),
        .disconnected => dvui.toast(@src(), .{ .window = window, .message = "Disconnected from p2p client" }),
        .stream_received => dvui.toast(@src(), .{ .window = window, .message = "Stream received to p2p client" }),
        .stream_closed => dvui.toast(@src(), .{ .window = window, .message = "Stream closed to p2p client" }),
        .message => |payload| {
            const arena = dvui.currentWindow().lifo();
            const msg = payload.buf[0..payload.len];
            const txt = std.fmt.allocPrint(arena, "Recieved p2p msg: {s}", .{msg}) catch "OOM";
            defer arena.free(txt);
            dvui.toast(@src(), .{ .window = window, .message = txt });
        },
        .pair_request => |req| {
            // See dvui.toast()
            const id_mutex = dvui.toastAdd(window, @src(), 0, null, pairToastDisplay, 10_000_000);
            const id = id_mutex.id;
            dvui.dataSet(window, id, "_pair_request", req);
            id_mutex.mutex.unlock(dvui.io);
        },
    }
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
                var box = dvui.box(@src(), .{}, .{ .expand = .horizontal });
                defer box.deinit();

                var tl = dvui.textLayout(@src(), .{}, .{ .expand = .both, .font = .theme(.title) });
                tl.format("Path: {s}\n", .{self.core.data_dir}, .{});

                tl.addText("\n\nRouter\n", .{ .font = .theme(.heading) });
                const group_pending = self.core.router.io_group.token.load(.unordered) != null;
                tl.addText(
                    std.fmt.allocPrint(
                        dvui.currentWindow().arena(),
                        "Group has pending tasks: {s}",
                        .{if (group_pending) "yes" else "no"},
                    ) catch "OOM",
                    .{},
                );
                tl.deinit();

                if (group_pending) {
                    if (dvui.button(@src(), "Stop", .{}, .{})) {
                        self.core.router.stop() catch {};
                    }
                } else {
                    if (dvui.button(@src(), "Start", .{}, .{})) {
                        self.core.router.start() catch {};
                    }
                }
            },
            else => {},
        }
    }
}

// From dvui.toastDisplay
pub fn pairToastDisplay(id: dvui.Id) !void {
    const pair_req = dvui.dataGet(null, id, "_pair_request", *ilm.p2p.protocols.PairProtocol.PairRequest) orelse {
        std.log.err("pairToastDisplay lost data for toast {x}\n", .{id});
        dvui.toastRemove(id);
        return;
    };

    var animator = dvui.animate(@src(), .{ .kind = .alpha, .duration = 500_000 }, .{ .id_extra = id.asUsize(), .gravity_x = 0.5 });
    defer animator.deinit();

    dvui.label(
        @src(),
        "Pair request from: {s}",
        .{pair_req.name},
        .{
            .background = true,
            .corners = .all(1000),
            .padding = .{ .x = 16, .y = 8, .w = 16, .h = 8 },
        },
    );

    if (dvui.button(@src(), "Accept", .{}, .{})) {
        pair_req.accept(dvui.io);
        dvui.toastRemove(id);
    }
    if (dvui.button(@src(), "Reject", .{}, .{})) {
        pair_req.reject(dvui.io);
        dvui.toastRemove(id);
    }

    if (dvui.timerDone(id)) {
        animator.startEnd();
    }

    if (animator.end()) {
        dvui.toastRemove(id);
        animator.data().min_size = .{};
    }
}
