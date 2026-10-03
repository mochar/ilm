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

pub fn init(core: *Core) !Self {
    const db_writes = try core.gpa.create(DbWrites);
    db_writes.*.queue = .init(&db_writes.buf);
    try core.db_writer.subscribe(.{ .cb = dbWriteCallback, .ctx = @ptrCast(db_writes) });

    var self: Self = .{
        .core = core,
        .db_writes = db_writes,
        .peer_views = .empty,
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

    for (self.peer_views.values()) |*view| view.deinit();
    self.peer_views.deinit(self.core.gpa);
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

    dvui.labelNoFmt(@src(), self.core.router.name, .{}, .{
        .expand = .horizontal,
        .font = .theme(.title),
    });

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

        var entry = dvui.textEntry(@src(), .{ .placeholder = "Peer ID or ticket" }, .{ .expand = .horizontal });
        const enter_pressed = entry.enter_pressed;
        const input = entry.getText();
        const entry_valid = input.len == 64;
        entry.deinit();

        // TODO Button to take picture of qr code
        if (dvui.buttonIcon(@src(), "qrcode", dvui.entypo.camera, .{}, .{}, .{ .expand = .vertical, .gravity_y = 0.5 })) {
            dvui.toast(@src(), .{ .message = "TODO qr code" });
        }

        if (dvui.buttonLabelAndIcon(@src(), .{ .label = " Pair", .tvg_bytes = dvui.entypo.link, .icon_first = true, .button_opts = .{ .grayed = !entry_valid } }, .{ .gravity_y = 0.5 }) or enter_pressed) {
            log.info("Input: {s}", .{input});
            if (entry_valid) {
                self.pair(input) catch |err| {
                    utils.toastErr(@src(), err, "Failed to pair", .{});
                };
            } else {
                dvui.toast(@src(), .{ .message = "Peer ID must be 64 characters long" });
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

fn pair(self: *Self, endpoint_id: []const u8) !void {
    _ = try self.core.router.connectToEndpoint(.{ .id = endpoint_id });
    // ilm.peer.add(self.core, , name: []const u8)
}
