const std = @import("std");
const dvui = @import("dvui");
const ilm = @import("ilm");
const Core = ilm.Core;
const crdt = ilm.database.crdt;
const utils = @import("utils.zig");
const Self = @This();

core: *Core,
arena: std.heap.ArenaAllocator,
changeset: []crdt.Change = &.{},

pub fn init(core: *Core) !Self {
    return .{
        .core = core,
        .arena = .init(core.gpa),
    };
}

pub fn deinit(self: *Self) void {
    self.arena.deinit();
}

pub fn render(self: *Self) void {
    var box = dvui.box(@src(), .{}, .{ .expand = .both, .background = true });
    defer box.deinit();

    if (dvui.button(@src(), "Get changeset", .{}, .{})) {
        self.changeset = &.{};
        _ = self.arena.reset(.retain_capacity);
        if (crdt.getChanges(&self.core.db, &.{9,9,9}, 0, self.arena.allocator())) |cs| {
            self.changeset = cs;
        } else |err| {
            utils.toastErr(@src(), err, "Failed to get changeset", .{});
        }
    }

    {
        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
        defer scroll.deinit();

        var grid = dvui.grid(@src(), .{
            .scroll_opts = .{ .horizontal = .auto },
            .rows = self.changeset.len,
        }, .{ .expand = .horizontal });
        defer grid.deinit();

        const fieldnames = std.meta.fieldNames(crdt.Change);
        for (fieldnames, 0..) |colname, i| {
            const cell = grid.colHeader(.{ .col = i }, .{ .border = .all(1) });
            defer cell.deinit();
            dvui.label(@src(), "{s}", .{colname}, .{});
        }

        const start_row, const end_row = grid.rowsVisible();
        for (start_row..end_row) |row| {
            const change = self.changeset[row];

            {
                var cell = grid.cell(.{ .col = 0, .row = row }, .{ .border = .all(1), .expand = .horizontal });
                defer cell.deinit();
                dvui.label(@src(), "{s}", .{change.table}, .{});
            }
            
            inline for (fieldnames[1..6], 1..) |*fieldname, col| {
                _ = fieldname; // autofix
                var cell = grid.cell(.{ .col = col, .row = row }, .{ .border = .all(1) });
                defer cell.deinit();
                dvui.label(@src(), "{any}", .{@field(change, std.meta.fieldNames(crdt.Change)[col])}, .{});
            }
            
            {
                var cell = grid.cell(.{ .col = 6, .row = row }, .{ .border = .all(1), .expand = .horizontal });
                defer cell.deinit();
                dvui.label(@src(), "{x}", .{change.site_id[0..4]}, .{});
            }
            
            inline for (fieldnames[7..], 7..) |*fieldname, col| {
                _ = fieldname; // autofix
                var cell = grid.cell(.{ .col = col, .row = row }, .{ .border = .all(1) });
                defer cell.deinit();
                dvui.label(@src(), "{any}", .{@field(change, std.meta.fieldNames(crdt.Change)[col])}, .{});
            }
        }
    }
}
