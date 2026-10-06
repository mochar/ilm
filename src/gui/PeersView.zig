const std = @import("std");
const dvui = @import("dvui");
const ilm = @import("ilm");
const Core = ilm.Core;
const Peer = ilm.p2p.Peer;
const DbWriter = ilm.database.DbWriter;
const utils = @import("utils.zig");
const PeerView = @import("PeerView.zig");
const Self = @This();

const log = std.log.scoped(.peers_view);

const DbWrites = struct {
    buf: [12]DbWriter.Write,
    queue: std.Io.Queue(DbWriter.Write),
};

core: *Core,
db_writes: *DbWrites,
peer_views: std.AutoArrayHashMapUnmanaged(Peer.Id, PeerView),

requesting_pair: *std.atomic.Value(bool),

name_edit: struct {
    editing: bool = false,
    name: std.ArrayList(u8) = .empty,
} = .{},

pub fn init(core: *Core) !Self {
    const db_writes = try core.gpa.create(DbWrites);
    db_writes.*.queue = .init(&db_writes.buf);
    try core.db_writer.subscribe(.{ .cb = dbWriteCallback, .ctx = @ptrCast(db_writes) });

    const requesting_pair = try core.gpa.create(std.atomic.Value(bool));
    requesting_pair.* = .init(false);
    try core.router.addEventTrigger(.{ .ctx = @ptrCast(requesting_pair), .triggerFn = routerEventCallback });

    var self: Self = .{
        .core = core,
        .db_writes = db_writes,
        .peer_views = .empty,
        .requesting_pair = requesting_pair,
    };
    errdefer self.deinit();

    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    const peers = try ilm.p2p.peer.getAll(&core.db, arena.allocator());
    for (peers) |*p| {
        try self.peer_views.put(core.gpa, p.id, try PeerView.init(core, p.id));
    }

    return self;
}

pub fn deinit(self: *Self) void {
    self.db_writes.queue.close(dvui.io);
    self.core.gpa.destroy(self.db_writes);

    self.core.gpa.destroy(self.requesting_pair);

    self.name_edit.name.deinit(self.core.gpa);

    for (self.peer_views.values()) |*view| view.deinit();
    self.peer_views.deinit(self.core.gpa);
}

fn routerEventCallback(requesting_pair_opaque: ?*anyopaque, event: ilm.p2p.Router.Event) void {
    const requesting_pair: *std.atomic.Value(bool) = @ptrCast(@alignCast(requesting_pair_opaque.?));
    switch (event) {
        .pair_established, .pair_failed => {
            _ = requesting_pair.swap(false, .acq_rel);
        },
        else => {},
    }
}

fn dbWriteCallback(writes_opaque: *anyopaque, result: DbWriter.WriteResult) void {
    const write = result.write catch return;
    switch (write.table_id) {
        .peer => {
            const writes: *DbWrites = @ptrCast(@alignCast(writes_opaque));
            writes.queue.putOneUncancelable(dvui.io, write) catch |err| {
                log.err("Failed to add peer to write: {t}", .{err});
            };
        },
        else => {},
    }
}

fn processDbWrites(self: *Self) !void {
    var write: DbWriter.Write = undefined;
    while (self.db_writes.queue.getUncancelable(dvui.io, @ptrCast(&write), 0) catch 0 != 0) {
        switch (write.table_id) {
            .peer => |id| {
                switch (write.op) {
                    .insert => {
                        const peer_view = PeerView.init(self.core, id) catch continue;
                        self.peer_views.put(self.core.gpa, id, peer_view) catch continue;
                    },
                    .update => {
                        if (self.peer_views.getPtr(id)) |v| v.deinit();
                        _ = self.peer_views.orderedRemove(id);

                        const peer_view = PeerView.init(self.core, id) catch continue;
                        self.peer_views.put(self.core.gpa, id, peer_view) catch continue;
                    },
                    .delete => {
                        if (self.peer_views.getPtr(id)) |v| v.deinit();
                        _ = self.peer_views.orderedRemove(id);
                    },
                }
            },
            else => {},
        }
    }
}

pub fn render(self: *Self) void {
    self.processDbWrites() catch {};

    const win_rect = dvui.windowRect();
    const is_wide = win_rect.w > win_rect.h;
    var hbox = dvui.box(@src(), .{
        .dir = if (is_wide) .horizontal else .vertical,
        .equal_space = !is_wide,
    }, .{ .expand = .both });
    defer hbox.deinit();

    // Left sidebar scroll area
    if (is_wide) {
        self.renderSidebar(is_wide);
        self.renderContent();
    } else {
        self.renderContent();
        self.renderSidebar(is_wide);
    }
}

fn renderSidebar(self: *Self, is_wide: bool) void {
    const box_width = dvui.windowRect().w * 0.3;
    var box = dvui.box(@src(), .{}, .{
        .background = true,
        .expand = if (is_wide) .vertical else .both,
        .min_size_content = .width(box_width),
        .max_size_content = .width(box_width),
    });
    defer box.deinit();

    // Name
    if (self.name_edit.editing) {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{});
        defer hbox.deinit();

        var edit_entry = dvui.textEntry(
            @src(),
            .{
                .placeholder = "Name",
                .text = .{ .array_list = .{
                    .allocator = self.core.gpa,
                    .backing = &self.name_edit.name,
                } },
            },
            .{ .expand = .horizontal },
        );
        const enter_pressed = edit_entry.enter_pressed;
        edit_entry.deinit();

        const ok_pressed = dvui.buttonIcon(@src(), "ok", dvui.entypo.check, .{}, .{}, .{
            .gravity_y = 0.5,
            .gravity_x = 1.0,
        });

        if (enter_pressed or ok_pressed) {
            if (self.name_edit.name.items.len > 0) {
                self.core.router.setName(self.name_edit.name.items) catch {};
            }
            self.name_edit.editing = false;
        }
    } else {
        const clicked = dvui.labelClick(@src(), "{s}", .{self.core.router.name}, .{}, .{
            .expand = .horizontal,
            .font = dvui.themeGet().font_title.larger(2),
        });
        if (clicked) {
            self.name_edit.name.clearRetainingCapacity();
            self.name_edit.name.appendSlice(self.core.gpa, self.core.router.name) catch {};
            self.name_edit.editing = true;
        }
    }

    var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
    defer tl.deinit();

    switch (self.core.router.endpoint.state) {
        .online => |*state| {
            tl.addText("Endpoint id\n", .{ .font = .theme(.heading) });
            if (tl.addTextClick(&state.id, .{ .margin = .all(4.0) })) |_| {
                dvui.clipboardTextSet(&state.id);
                dvui.toast(@src(), .{ .message = "Endpoint ID copied to clipboard!" });
            }
            tl.addText("\nTicket\n", .{ .font = .theme(.heading) });
            if (tl.addTextClick(state.ticket, .{ .margin = .all(4.0) })) |_| {
                dvui.clipboardTextSet(state.ticket);
                dvui.toast(@src(), .{ .message = "Ticket copied to clipboard!" });
            }
        },
        .bound => {
            tl.addText("Offline!", .{});
        },
        .closed => {
            tl.addText("Closed!", .{});
        },
    }
}

fn renderContent(self: *Self) void {
    var box = dvui.box(@src(), .{}, .{ .expand = .both, .background = true });
    defer box.deinit();

    {
        // Pair requests
        var conn_peers = self.core.router.connections.peers.valueIterator();
        while (conn_peers.next()) |con_peer| {
            if (con_peer.pair_request != null) {
                renderPairingPeer(con_peer) catch {};
            }
        }

        // Known peers
        for (self.peer_views.values()) |*peer_view| {
            peer_view.render();
        }
    }

    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hbox.deinit();

        const requesting = self.requesting_pair.load(.acquire);

        var entry = dvui.textEntry(@src(), .{ .placeholder = "Peer ID or ticket" }, .{ .expand = .horizontal });
        const enter_pressed = entry.enter_pressed;
        const input = entry.getText();
        const entry_valid = input.len == 64;
        entry.deinit();

        // TODO Button to take picture of qr code
        if (dvui.buttonIcon(@src(), "qrcode", dvui.entypo.camera, .{}, .{}, .{ .expand = .vertical, .gravity_y = 0.5 })) {
            dvui.toast(@src(), .{ .message = "TODO qr code" });
        }

        const btn_pressed = dvui.buttonLabelAndIcon(
            @src(),
            .{
                .label = " Pair",
                .tvg_bytes = dvui.entypo.link,
                .icon_first = true,
                .button_opts = .{ .grayed = !entry_valid or requesting },
            },
            .{ .gravity_y = 0.5 },
        );

        if (btn_pressed or enter_pressed) {
            if (requesting) {
                dvui.toast(@src(), .{ .message = "Pair request already in progress" });
            } else if (!entry_valid) {
                dvui.toast(@src(), .{ .message = "Peer ID must be 64 characters long" });
            } else {
                self.pair(input) catch |err| {
                    utils.toastErr(@src(), err, "Failed to pair", .{});
                };
            }
        }
    }
}

fn renderPairingPeer(peer: *ilm.p2p.Router.ConnectedPeer) !void {
    const req = peer.pair_request.?;
    var box = dvui.box(@src(), .{}, .{
        .expand = .horizontal,
        .border = .all(2.0),
        .margin = .all(6.0),
        .padding = .all(6.0),
    });
    defer box.deinit();

    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hbox.deinit();

        dvui.icon(@src(), "pair", dvui.entypo.link, .{}, .{ .gravity_y = 0.5 });

        var tl = dvui.textLayout(@src(), .{}, .{ .expand = .both });
        defer tl.deinit();

        tl.addText("Pair request from ", .{ .font = .theme(.heading) });
        tl.format("{s}", .{req.name}, .{ .font = .theme(.heading) });
    }

    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer hbox.deinit();

    if (dvui.button(@src(), "Accept", .{}, .{})) {
        req.accept(dvui.io);
    }
    if (dvui.button(@src(), "Reject", .{}, .{})) {
        req.reject(dvui.io);
    }
}

fn pair(self: *Self, endpoint_id_hex: []const u8) !void {
    var endpoint_id_bytes: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&endpoint_id_bytes, endpoint_id_hex);
    const peer_id: ilm.p2p.Peer.Id = .{ .bytes = endpoint_id_bytes };

    _ = self.requesting_pair.swap(true, .acq_rel);
    self.core.router.sendPairRequest(peer_id);
}
