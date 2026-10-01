const std = @import("std");
const dvui = @import("dvui");
const ilm = @import("ilm");
const Core = ilm.Core;
const Id = ilm.database.Id;
const Concept = ilm.concept.Concept;
const DbWriter = ilm.database.DbWriter;
const GraphView = @import("GraphView.zig");
const utils = @import("utils.zig");
const Self = @This();

const log = std.log.scoped(.concept_view);

const MAX_GRAPH_WIDTH: u32 = 512;
const MAX_GRAPH_HEIGHT: u32 = 512;

core: *Core,
gpa: std.mem.Allocator,
/// Since this view is short lived, all allocation done with this
/// arena and only freed at deinit.
arena: std.heap.ArenaAllocator,

/// Own a copy. Optional in case the concept gets deleted or some
/// error occurs when retrieving the concept. By setting this to null
/// we can put this view in an invalid, but still functional state.
concept: ?Concept = null,
concept_id: Id,

graph_view: GraphView,

/// Set to true on db write events that effect this concept.
dirty: std.atomic.Value(bool) = .init(false),

name_edit: struct {
    editing: bool = false,
    name: std.ArrayList(u8) = .empty,
} = .{},

pub const Options = struct {
    concept_id: Id,
    core: *Core,
    gpa: std.mem.Allocator,
    io: std.Io,
};

pub fn create(opts: Options) !*Self {
    const gpa = opts.gpa;

    var self = try gpa.create(Self);
    errdefer gpa.destroy(self);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();

    var graph_view: GraphView = try .init(.{
        .gpa = opts.gpa,
        .io = opts.io,
        .max_width = MAX_GRAPH_WIDTH,
        .max_height = MAX_GRAPH_HEIGHT,
        .src = @src(),
    });
    errdefer graph_view.deinit();

    self.* = .{
        .concept_id = opts.concept_id,
        .gpa = gpa,
        .core = opts.core,
        .graph_view = graph_view,
        .arena = arena,
    };
    errdefer self.destroy();

    try opts.core.db_writer.subscribe(.{ .cb = dbWriteCallback, .ctx = @ptrCast(self) });
    self.getConcept();

    return self;
}

pub fn destroy(self: *Self) void {
    self.core.db_writer.unsubscribe(.{ .cb = dbWriteCallback, .ctx = @ptrCast(self) });
    self.graph_view.deinit();
    self.arena.deinit();
    self.gpa.destroy(self);
}

/// Retrieve concept from db and set state to match.
fn getConcept(self: *Self) void {
    if (ilm.concept.getById(self.core, self.arena.allocator(), self.concept_id) catch null) |concept| {
        self.setConcept(concept);
    } else {
        log.err("Concept not found", .{});
        dvui.toast(@src(), .{ .message = "Concept not found" });
    }
}

fn setConcept(self: *Self, concept: ?Concept) void {
    self.name_edit.name.clearRetainingCapacity();
    self.graph_view.renderer.clear();
    self.concept = concept;
    if (concept) |c| {
        self.name_edit.name.appendSlice(self.arena.allocator(), c.name) catch {};
        self.resetGraph() catch {};
    }
}

fn dbWriteCallback(self_opaque: *anyopaque, result: DbWriter.WriteResult) void {
    const write = result.write catch return;
    const self: *Self = @ptrCast(@alignCast(self_opaque));
    if (self.concept) |*concept| {
        switch (write.table_id) {
            .concept => |id| {
                if (id.int != concept.id.int) return;
                self.dirty.store(true, .seq_cst);
            },
            .concept_rel => |ids| {
                if (ids.parent.int == concept.id.int or ids.child.int == concept.id.int) {
                    self.dirty.store(true, .seq_cst);
                }
            },
            else => {},
        }
    }
}

pub fn resetGraph(self: *Self) !void {
    var renderer = &self.graph_view.renderer;
    const graph = self.graph_view.graph();
    const arena = self.arena.allocator(); // dont clear capacity

    renderer.clear();

    if (self.concept) |*concept| {
        try renderer.highlighted.put(concept.id.int, {});
        try ilm.concept.fillAncestorGraph(self.core, graph, arena, concept);
        try renderer.layout("dotx");
        try self.graph_view.updateGraph();
    }
}

pub const Action = union(enum) {
    node_select: u128,
    quit: void,
    rename: void,
    new: Id,
    delete: void,
};

pub fn render(self: *Self) ?Action {
    if (self.dirty.load(.seq_cst)) {
        self.getConcept();
        self.dirty.store(false, .seq_cst);
    }

    var action: ?Action = null;

    var box = dvui.box(@src(), .{}, .{ .expand = .both });
    defer box.deinit();

    header: {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hbox.deinit();
        if (dvui.buttonIcon(@src(), "back", dvui.entypo.back, .{}, .{}, .{ .gravity_y = 0.5 })) {
            if (self.name_edit.editing) {
                self.name_edit.editing = false;
            } else {
                return .quit;
            }
        }

        if (self.concept == null) {
            dvui.labelNoFmt(@src(), "Not Found", .{}, .{
                .expand = .horizontal,
                .gravity_y = 0.5,
                .font = .theme(.title),
                .background = false,
            });
            break :header;
        }

        var concept = &self.concept.?;

        if (self.name_edit.editing) {
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
                if (ilm.concept.rename(self.core, concept.id, self.name_edit.name.items)) {
                    concept.name = self.arena.allocator().dupe(u8, self.name_edit.name.items) catch @panic("OOM");
                    action = .rename;
                } else |err| {
                    utils.toastErr(@src(), err, "Error when editing name", .{});
                }
                self.name_edit.editing = false;
            }
        } else {
            if (dvui.button(@src(), concept.name, .{}, .{
                .expand = .horizontal,
                .gravity_y = 0.5,
                .font = .theme(.title),
                .background = false,
            })) {
                self.name_edit.editing = true;
            }
        }
    }

    if (self.concept == null) return action;
    const concept = &self.concept.?;

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
        if (ilm.concept.add(
            self.core,
            std.fmt.allocPrint(self.arena.allocator(), "{s} child", .{concept.name}) catch @panic("OOM"),
            &.{concept.id},
        )) |child_id| {
            return .{ .new = child_id };
        } else |err| {
            utils.toastErr(@src(), err, "Failed to create child node", .{});
        }
    }

    if (dvui.buttonLabelAndIcon(
        @src(),
        .{
            .label = "Delete concept",
            .tvg_bytes = dvui.entypo.trash,
        },
        .{
            .expand = .horizontal,
            .color_fill = .red,
        },
    )) {
        if (ilm.concept.delete(self.core, concept.id)) {
            return .delete;
        } else |err| {
            utils.toastErr(@src(), err, "Failed to delete node", .{});
        }
    }

    return action;
}
