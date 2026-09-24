const std = @import("std");
const dvui = @import("dvui");
const ilm = @import("ilm");
const Core = ilm.Core;
const connect = @import("main.zig").connect;
const Self = @This();

arena: std.heap.ArenaAllocator,
data_dir: ?[]u8 = null,
device_name_buf: []u8,

pub fn init(gpa: std.mem.Allocator) Self {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    return .{
        .arena = arena,
        .data_dir = @constCast("/home/mochar/tmp/ilm/"),
        .device_name_buf = arena.allocator().alloc(u8, 1028) catch @panic("OOM"),
    };
}

pub fn deinit(self: *Self) void {
    self.arena.deinit();
}

pub fn render(self: *Self) void {
    var box = dvui.box(@src(), .{}, .{ .style = .window, .background = true, .expand = .both });
    defer box.deinit();

    dvui.label(@src(), "Set up", .{}, .{ .font = .theme(.title) });

    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hbox.deinit();

        dvui.label(@src(), "Data directory: {s}", .{self.data_dir orelse "Not selected"}, .{ .gravity_y = 0.5 });
        if (dvui.button(@src(), "Select", .{}, .{ .label = .{ .label_widget = .prev } })) {
            if (dvui.dialogNativeFolderSelect(self.arena.allocator(), .{}) catch null) |dir| {
                self.data_dir = @constCast(dir);
                dvui.toast(@src(), .{ .message = dir });
            }
        }
    }

    const device_name = blk: {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
        });
        defer hbox.deinit();
        dvui.label(@src(), "Device name", .{}, .{ .gravity_y = 0.5 });
        var entry = dvui.textEntry(@src(), .{ .text = .{ .buffer = self.device_name_buf } }, .{ .label = .{ .label_widget = .prev } });
        defer entry.deinit();
        break :blk entry.getText();
    };

    _ = dvui.separator(@src(), .{ .expand = .horizontal, .gravity_y = 0.5 });

    if (dvui.button(@src(), "Set up", .{}, .{})) {
        if (self.data_dir) |data_dir| {
            connect(data_dir);
            dvui.toast(@src(), .{ .message = device_name });
        }
    }
}
