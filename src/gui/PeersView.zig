const std = @import("std");
const dvui = @import("dvui");
const ilm = @import("ilm");
const Core = ilm.Core;
const Peer = ilm.peer.Peer;
const utils = @import("utils.zig");
const Self = @This();

const log = std.log.scoped(.peers_view);

core: *Core,
gpa: std.mem.Allocator,

pub fn init(core: *Core, gpa: std.mem.Allocator) !Self {
    return .{ .core = core, .gpa = gpa };
}

pub fn deinit(_: *Self) void {}

pub fn render(self: *Self) void {
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
    }
}

fn renderContent(self: *Self) void {
    var box = dvui.box(@src(), .{}, .{ .expand = .both, .background = true });
    defer box.deinit();

    {
        dvui.labelNoFmt(@src(), "Connections", .{}, .{ .font = .theme(.title) });
        var conn_peers = self.core.router.connections.peers.valueIterator();
        while (conn_peers.next()) |con_peer| {
            var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .border = .all(2.0),
            });
            defer hbox.deinit();

            dvui.label(@src(), "{x}", .{con_peer.id}, .{});
        }
    }

    for (self.core.peers) |*peer| {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .border = .all(2.0),
        });
        defer hbox.deinit();

        dvui.labelNoFmt(@src(), if (peer.name.len == 0) "noname" else peer.name, .{}, .{ .font = .theme(.heading) });
        dvui.label(@src(), "{x}", .{peer.id}, .{});
    }

    _ = dvui.separator(@src(), .{ .min_size_content = .height(2.0) });

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

        if (dvui.buttonLabelAndIcon(@src(), .{
            .label = " Pair",
            .tvg_bytes = dvui.entypo.link,
            .icon_first = true,
            .button_opts = .{ .grayed = !entry_valid }
        }, .{ .gravity_y = 0.5 }) or enter_pressed) {
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

fn pair(self: *Self, endpoint_id: []const u8) !void {
    _ = try self.core.router.connect(.{ .id = endpoint_id });
    // ilm.peer.add(self.core, , name: []const u8)
}
