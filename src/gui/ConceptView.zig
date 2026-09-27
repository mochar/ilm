const std = @import("std");
const dvui = @import("dvui");
const ilm = @import("ilm");
const Core = ilm.Core;
const Concept = ilm.concept.Concept;

const Self = @This();
const log = std.log.scoped(.concept_view);
const GraphView = @import("GraphView.zig");
const utils = @import("utils.zig");

const MAX_GRAPH_WIDTH: u32 = 512;
const MAX_GRAPH_HEIGHT: u32 = 512;

concept: *Concept,
core: *Core,
graph_view: GraphView,
graph_arena: std.heap.ArenaAllocator,

pub const Options = struct {
    concept: *Concept,
    core: *Core,
    gpa: std.mem.Allocator,
    io: std.Io,
};

pub fn init(opts: Options) !Self {
    var graph_view: GraphView = try .init(.{
        .gpa = opts.gpa,
        .io = opts.io,
        .max_width = MAX_GRAPH_WIDTH,
        .max_height = MAX_GRAPH_HEIGHT,
        .src = @src(),
    });
    errdefer graph_view.deinit();

    var self: Self = .{
        .concept = opts.concept,
        .core = opts.core,
        .graph_view = graph_view,
        .graph_arena = .init(opts.gpa),
    };
    try self.updateGraph();
    return self;
}

pub fn deinit(self: *Self) void {
    self.graph_view.deinit();
    self.graph_arena.deinit();
}

pub fn updateGraph(self: *Self) !void {
    var renderer = self.graph_view.renderer;
    const graph = self.graph_view.graph();
    const arena = self.graph_arena.allocator();

    renderer.clear();
    _ = self.graph_arena.reset(.retain_capacity);

    try renderer.highlighted.put(self.concept.id.uuid, {});
    try ilm.concept.fillAncestorGraph(self.core, graph, arena, self.concept);
    // try renderer.layout("neato");
    try renderer.layout("dotx");
    try self.graph_view.update();
}

pub fn render(self: *Self) void {
    var box = dvui.box(@src(), .{}, .{ .expand = .both });
    defer box.deinit();

    if (self.graph_view.render(.{
        .expand = .ratio,
        .margin = .all(10.0),
    }) catch |err| {
        return utils.toastErr(@src(), err, "Failed to render graph", .{});
    }) |action| {
        switch (action) {
            .node_select => {},
        }
    }
}
