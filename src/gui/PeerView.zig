const std = @import("std");
const dvui = @import("dvui");
const ilm = @import("ilm");
const Core = ilm.Core;
const Peer = ilm.p2p.Peer;
const utils = @import("utils.zig");
const Self = @This();

const log = std.log.scoped(.peer_view);

core: *Core,
arena: std.heap.ArenaAllocator,
peer: Peer,

name_edit: struct {
    editing: bool = false,
    name: std.ArrayList(u8) = .empty,
} = .{},

pub fn init(core: *Core, peer_id: Peer.Id) !Self {
    var arena_alloc: std.heap.ArenaAllocator = .init(core.gpa);
    errdefer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    const peer = try ilm.p2p.peer.getById(&core.db, arena, &peer_id) orelse return error.NotFound;

    var self: Self = .{
        .core = core,
        .arena = arena_alloc,
        .peer = peer,
    };

    try self.name_edit.name.appendSlice(arena, peer.name);

    return self;
}

pub fn deinit(self: *Self) void {
    self.arena.deinit();
}

pub fn render(self: *Self) void {
    var box = dvui.box(@src(), .{}, .{
        .expand = .horizontal,
        .border = .all(1.0),
        .margin = .all(3.0),
        .padding = .all(3.0),
    });
    defer box.deinit();

    const peer_conn = self.core.router.connections.peers.getPtr(self.peer.id);

    if (self.name_edit.editing) {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{});
        defer hbox.deinit();

        var edit_entry = dvui.textEntry(
            @src(),
            .{ .placeholder = "Name", .text = .{ .array_list = .{
                .allocator = self.arena.allocator(),
                .backing = &self.name_edit.name,
            } } },
            .{ .expand = .horizontal },
        );
        const enter_pressed = edit_entry.enter_pressed;
        edit_entry.deinit();

        const ok_pressed = dvui.buttonIcon(@src(), "back", dvui.entypo.check, .{}, .{}, .{
            .gravity_y = 0.5,
            .gravity_x = 1.0,
        });

        if (enter_pressed or ok_pressed) {
            if (ilm.p2p.peer.rename(self.core, self.peer.id, self.name_edit.name.items)) {
                self.peer.name = self.arena.allocator().dupe(u8, self.name_edit.name.items) catch @panic("OOM");
            } else |err| {
                utils.toastErr(@src(), err, "Error when editing name", .{});
            }
            self.name_edit.editing = false;
        }
    } else {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hbox.deinit();

        dvui.labelNoFmt(@src(), "●", .{}, .{
            .color_text = .{ .color = if (peer_conn != null) .fromHex("#42c52c") else .gray },
            .font = .find(.{ .family = "dejavu sans" }),
            .padding = .{ .y = 5, .x = 4 },
        });

        if (dvui.labelClick(@src(), "{s}", .{self.peer.name}, .{}, .{
            .font = .theme(.heading),
            .background = false,
        })) {
            self.name_edit.editing = true;
        }
    }

    dvui.label(@src(), "{x}", .{&self.peer.id.bytes}, .{ .color_text = .gray });

    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{});
        defer hbox.deinit();

        if (peer_conn == null and dvui.button(@src(), "Connect", .{}, .{})) {
            _ = self.core.router.connectToEndpoint(self.peer.id) catch |err| {
                utils.toastErr(@src(), err, "Failed to connect", .{});
            };
        }

        if (dvui.button(@src(), "Delete", .{}, .{})) {
            self.core.deletePeerAndCloseConnection(self.peer.id) catch |err| {
                utils.toastErr(@src(), err, "Failed to delete peer", .{});
            };
        }
    }
}
