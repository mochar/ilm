const std = @import("std");

const Core = @import("core").Core;
const Concept = Core.Concept;
const dvui = @import("dvui");
const sqlite = @import("sqlite");

const Self = @This();
core: *Core,
arena: std.heap.ArenaAllocator,
render_arena: std.heap.ArenaAllocator,
concepts: []Concept = &.{},
selected: ?*Concept = null,

pub fn init(gpa: std.mem.Allocator, core: *Core) Self {
    var self: Self = .{
        .core = core,
        .arena = std.heap.ArenaAllocator.init(gpa),
        .render_arena = std.heap.ArenaAllocator.init(gpa),
    };
    self.getConcepts();
    return self;
}

pub fn deinit(self: *Self) void {
    self.arena.deinit();
    self.render_arena.deinit();
}

fn getConcepts(self: *Self) void {
    var arena_instance: std.heap.ArenaAllocator = .init(self.arena.allocator());
    const arena = arena_instance.allocator();
    defer arena_instance.deinit();

    var diags: sqlite.Diagnostics = .{};
    if (self.core.getAllConcepts(arena, &diags)) |concepts| {
        if (self.arena.allocator().dupe(Concept, concepts)) |cs| {
            self.concepts = cs;
        } else |_| {
            dvui.toast(@src(), .{ .message = "Failed to allocate concepts" });
        }
    } else |err| {
        if (diags.err) |sqlite_err| {
            const err_msg = std.fmt.allocPrint(arena, "Sqlite error: {s}", .{sqlite_err.message}) catch "Failed to get concepts";
            dvui.toast(@src(), .{ .message = err_msg });
        } else {
            const err_msg = std.fmt.allocPrint(arena, "Failed to get concepts: {t}", .{err}) catch "Failed to get concepts";
            dvui.toast(@src(), .{ .message = err_msg });
        }
    }
}

pub fn render(self: *Self) void {
    defer _ = self.render_arena.reset(.retain_capacity);

    {
        var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .font = .theme(.title) });
        defer tl.deinit();
        tl.format("Found {d} concepts", .{self.concepts.len}, .{});
    }

    var hbox = dvui.box(@src(), .{ .dir = .horizontal}, .{});
    defer hbox.deinit();

    {
        var scroll = dvui.scrollArea(@src(), .{}, .{});
        defer scroll.deinit();
        for (self.concepts, 0..) |*concept, i| {
            var c_box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i });
            defer c_box.deinit();
            if (dvui.labelClick(@src(), "{s}", .{concept.name}, .{}, .{})) {
                self.selected = concept;
            }
        }
    }

    if (self.selected) |concept| {
        dvui.label(@src(), "{s}", .{concept.name}, .{});
    }
}
