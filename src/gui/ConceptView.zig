const std = @import("std");
const dvui = @import("dvui");
const ilm = @import("ilm");
const Core = ilm.Core;
const Id = ilm.database.Id;
const Concept = ilm.concept.Concept;

const Self = @This();
const log = std.log.scoped(.concept_view);
const GraphView = @import("GraphView.zig");
const utils = @import("utils.zig");

const MAX_GRAPH_WIDTH: u32 = 512;
const MAX_GRAPH_HEIGHT: u32 = 512;

/// Own a copy. Changes are propogated through Action enum.
concept: Concept,
core: *Core,
graph_view: GraphView,
/// Since this view is short lived, all allocation done with this
/// arena and only freed at deinit.
arena: std.heap.ArenaAllocator,

editing_name: bool = false,
name: std.ArrayList(u8) = .empty,

pub const Options = struct {
    concept_id: Id,
    core: *Core,
    gpa: std.mem.Allocator,
    io: std.Io,
};

pub fn init(opts: Options) !Self {
    var arena: std.heap.ArenaAllocator = .init(opts.gpa);
    errdefer arena.deinit();

    const concept = blk: {
        const concepts = try ilm.concept.getById(opts.core, arena.allocator(), &.{opts.concept_id});
        if (concepts.len != 1) {
            log.err("Expected 1 concept, found {d}", .{concepts.len});
            return error.InvalidDbResult;
        }
        break :blk concepts[0];
    };

    var graph_view: GraphView = try .init(.{
        .gpa = opts.gpa,
        .io = opts.io,
        .max_width = MAX_GRAPH_WIDTH,
        .max_height = MAX_GRAPH_HEIGHT,
        .src = @src(),
    });
    errdefer graph_view.deinit();

    var self: Self = .{
        .concept = concept,
        .core = opts.core,
        .graph_view = graph_view,
        .arena = arena,
    };
    errdefer self.deinit();

    try self.name.appendSlice(arena.allocator(), concept.name);
    try self.updateGraph();

    return self;
}

pub fn deinit(self: *Self) void {
    self.graph_view.deinit();
    self.arena.deinit();
}

pub fn updateGraph(self: *Self) !void {
    var renderer = &self.graph_view.renderer;
    const graph = self.graph_view.graph();
    const arena = self.arena.allocator(); // dont clear capacity

    renderer.clear();

    try renderer.highlighted.put(self.concept.id.uuid, {});
    try ilm.concept.fillAncestorGraph(self.core, graph, arena, &self.concept);
    try renderer.layout("dotx");
    try self.graph_view.updateGraph();
}

pub const Action = union(enum) {
    node_select: u128,
    quit: void,
    rename: void,
};

pub fn render(self: *Self) ?Action {
    var action: ?Action = null;

    var box = dvui.box(@src(), .{}, .{ .expand = .both });
    defer box.deinit();

    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hbox.deinit();
        if (dvui.buttonIcon(@src(), "back", dvui.entypo.back, .{}, .{}, .{ .gravity_y = 0.5 })) {
            if (self.editing_name) {
                self.editing_name = false;
            } else {
                return .quit;
            }
        }

        if (self.editing_name) {
            var edit_entry = dvui.textEntry(
                @src(),
                .{ .placeholder = "Name", .text = .{ .array_list = .{
                    .allocator = self.arena.allocator(),
                    .backing = &self.name,
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
                if (ilm.concept.rename(self.core, self.concept.id, self.name.items)) {
                    self.concept.name = self.arena.allocator().dupe(u8, self.name.items) catch @panic("OOM");
                    action = .rename;
                } else |err| {
                    utils.toastErr(@src(), err, "Error when editing name", .{});
                }
                self.editing_name = false;
            }
        } else {
            if (dvui.button(@src(), self.concept.name, .{}, .{
                .expand = .horizontal,
                .gravity_y = 0.5,
                .font = .theme(.title),
                .background = false,
            })) {
                self.editing_name = true;
            }
        }
    }

    if (self.graph_view.render(.{
        .expand = .ratio,
        .margin = .all(10.0),
    }) catch |err| {
        utils.toastErr(@src(), err, "Failed to render graph", .{});
        return action;
    }) |graph_action| {
        switch (graph_action) {
            .node_select => |id| action = .{ .node_select = id },
        }
    }

    if (dvui.buttonLabelAndIcon(
        @src(),
        .{
            .label = "Add child concept",
            .tvg_bytes = dvui.entypo.plus,
        },
        .{ .expand = .horizontal },
    )) {
        dvui.toast(@src(), .{ .message = "kek" });
        // dvui.dialog(src: SourceLocation, user_struct: anytype, opts: DialogOptions)
    }

    return action;
}
