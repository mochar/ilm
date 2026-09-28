const std = @import("std");
const dvui = @import("dvui");

const ilm = @import("ilm");
const Core = ilm.Core;
const Concept = ilm.concept.Concept;
const Id = ilm.Id;

const GraphView = @import("GraphView.zig");
const ConceptView = @import("ConceptView.zig");
const utils = @import("utils.zig");
const Self = @This();

const log = std.log.scoped(.concepts_view);

const MAX_GRAPH_WIDTH: u32 = 2048;
const MAX_GRAPH_HEIGHT: u32 = 2048;

core: *Core,
gpa: std.mem.Allocator,
all_concepts: []Concept = &.{},
selected: ?struct {
    concept: *Concept,
    view: *ConceptView,
} = null,

search_query: std.ArrayList(u8) = .empty,
/// Matched concepts (the structs themselves and the strings within)
/// are allocated using this arena. It is reset each time the search
/// query is changed.
search_arena: std.heap.ArenaAllocator,
matched_concepts: []Concept = &.{},

graph_view: GraphView,
/// To allocate graph content, reset every time we fill the graph.
graph_arena: std.heap.ArenaAllocator,

pub fn create(gpa: std.mem.Allocator, core: *Core) !*Self {
    var self = try gpa.create(Self);
    errdefer gpa.destroy(self);
    
    var graph_view: GraphView = try .init(.{
        .gpa = gpa,
        .io = core.io,
        .max_width = MAX_GRAPH_WIDTH,
        .max_height = MAX_GRAPH_HEIGHT,
        .src = @src(),
    });
    errdefer graph_view.deinit();

    self.* = .{
        .core = core,
        .gpa = gpa,
        .search_arena = .init(gpa),
        .graph_view = graph_view,
        .graph_arena = .init(gpa),
    };
    errdefer self.destroy();
    
    try core.db_pub.subscribe(.{.cb = dbEventCallback, .ctx = @ptrCast(self) });

    self.getAllConcepts();
    self.updateGraphContent(.reset);
    return self;
}

pub fn destroy(self: *Self) void {
    self.graph_view.deinit();
    self.graph_arena.deinit();
    self.gpa.free(self.all_concepts);
    self.search_query.deinit(self.gpa);
    self.search_arena.deinit();
    if (self.selected) |*s| {
        s.view.deinit();
        self.gpa.destroy(s.view);
    }
}

fn dbEventCallback(self_opaque: *anyopaque, event: ilm.database.EventPub.Event) void {
    const self: *Self = @ptrCast(@alignCast(self_opaque));
    // _ = self;
    const win = dvui.currentWindow();
    dvui.toast(@src(), .{ .window = win, .message = std.fmt.allocPrint(win.arena(), "Concepts: {d}", .{self.all_concepts.len}) catch "OOM" });
    const msg = std.fmt.allocPrint(win.arena(), "DB event: {t}, {t}, {d}", .{event.op, event.table, event.rowid}) catch "OOM";
    dvui.toast(@src(), .{ .window = win, .message = msg });
}

fn getAllConcepts(self: *Self) void {
    if (ilm.concept.getAll(self.core, self.gpa)) |concepts| {
        self.gpa.free(self.all_concepts);
        self.all_concepts = concepts;
    } else |_| {
        dvui.toast(@src(), .{ .message = "Failed to get all concepts" });
    }
}

fn getMatchedConcepts(self: *Self) void {
    log.info("Getting matching concepts", .{});
    const query = self.search_query.items;
    _ = self.search_arena.reset(.retain_capacity);
    if (ilm.concept.getByNameMatch(self.core, self.search_arena.allocator(), query)) |concepts| {
        self.matched_concepts = concepts;
    } else |_| {
        self.matched_concepts = &.{};
        dvui.toast(@src(), .{ .message = "Failed to get matched concepts" });
    }
}

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
        self.renderGraph();
    } else {
        self.renderGraph();
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
    if (self.selected == null) {
        self.renderSearch();
    } else {
        self.renderConceptView();
    }
}

fn renderSearch(self: *Self) void {
    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    var search_entry = dvui.textEntry(
        @src(),
        .{
            .placeholder = "Search",
            .text = .{
                .array_list = .{
                    .allocator = self.gpa,
                    .backing = &self.search_query,
                },
            },
        },
        .{ .expand = .horizontal },
    );
    const search_changed = search_entry.text_changed;
    search_entry.deinit();
    defer if (search_changed) {
        log.info("Search changed to: {s}", .{self.search_query.items});
        self.getMatchedConcepts();
    };

    if (self.search_query.items.len == 0)
        dvui.label(@src(), "{d}", .{self.all_concepts.len}, .{ .gravity_y = 0.5 })
    else
        dvui.label(@src(), "{d}/{d}", .{ self.matched_concepts.len, self.all_concepts.len }, .{ .gravity_y = 0.5 });
    hbox.deinit();

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();

    const selected_id: ?u128 = if (self.selected) |s| s.concept.id.uuid else null;
    const concepts = if (self.search_query.items.len == 0) self.all_concepts else self.matched_concepts;
    for (concepts, 0..) |*concept, i| {
        _ = i;
        const is_selected = concept.id.uuid == selected_id;
        var c_box = dvui.box(
            @src(),
            .{ .dir = .horizontal },
            .{
                // .id_extra = i,
                .id_extra = @truncate(concept.id.uuid),
                .expand = .horizontal,
                .background = true,
                .style = if (is_selected) .highlight else null,
            },
        );
        if (dvui.labelClick(@src(), "{s}", .{concept.name}, .{}, .{ .expand = .both })) {
            if (is_selected) self.unselect() else self.selectConcept(concept);
        }
        c_box.deinit();
    }
}

fn renderConceptView(self: *Self) void {
    if (self.selected) |*selected| {
        // const concept = selected.concept;
        var view = selected.view;

        if (view.render()) |action| {
            switch (action) {
                .quit => self.unselect(),
                .node_select => |id| self.selectConceptById(id),
                .rename => {
                    self.getAllConcepts();
                    self.updateGraphContent(.retain_state);
                },
                .new => |id| {
                    self.getAllConcepts();
                    self.updateGraphContent(.retain_state);
                    self.selectConceptById(id.uuid);
                },
                .delete => {
                    self.getAllConcepts();
                    self.updateGraphContent(.reset);
                    self.unselect();
                },
            }
        }
    }
}

fn renderGraph(self: *Self) void {
    if (self.graph_view.render(.{ .expand = .both }) catch |err| {
        return utils.toastErr(@src(), err, "Failed to render graph", .{});
    }) |action| {
        switch (action) {
            .node_select => |id| self.selectConceptById(id),
        }
    }
}

fn selectConceptById(self: *Self, id: u128) void {
    if (self.selected) |s| if (s.concept.id.uuid == id) return;
    for (self.all_concepts) |*concept| {
        if (concept.id.uuid == id) {
            self.selectConcept(concept);
            return;
        }
    }
    dvui.toast(@src(), .{ .message = "Failed to find concept" });
}

fn selectConcept(self: *Self, concept: *Concept) void {
    if (self.selected) |*selected| {
        if (selected.concept == concept) return;
        // TODO Duplicate code in unselect()
        selected.view.deinit();
        self.gpa.destroy(selected.view);
        self.selected = null;
        self.graph_view.renderer.highlighted.clearRetainingCapacity();
    }

    const view = self.gpa.create(ConceptView) catch @panic("OOM");
    errdefer self.gpa.destroy(view);
    view.* = ConceptView.init(.{
        .concept_id = concept.id,
        .core = self.core,
        .gpa = self.core.gpa,
        .io = self.core.io,
    }) catch |err| {
        log.err("Error init concept view: {t}", .{err});
        utils.toastErr(@src(), err, "Error init concept view", .{});
        self.selected = null;
        return;
    };
    self.selected = .{ .concept = concept, .view = view };

    self.graph_view.animateToNode(concept.id.uuid) catch {};
    self.graph_view.renderer.highlighted.put(concept.id.uuid, {}) catch {};
}

fn unselect(self: *Self) void {
    if (self.selected) |*selected| {
        selected.view.deinit();
        self.gpa.destroy(selected.view);
        self.selected = null;
    }
    self.graph_view.animateFitToGraph() catch {};
    self.graph_view.renderer.highlighted.clearRetainingCapacity();
}

/// Replace the graph nodes and edges with that of self.selected
fn updateGraphContent(self: *Self, how: enum { reset, retain_state }) void {
    var renderer = &self.graph_view.renderer;
    const graph = self.graph_view.graph();
    const arena = self.graph_arena.allocator();

    switch (how) {
        .reset => renderer.clear(),
        .retain_state => renderer.graph.clear(),
    }

    _ = self.graph_arena.reset(.retain_capacity);

    ilm.concept.fillFullGraph(self.core, graph, arena, self.all_concepts) catch |err| {
        return utils.toastErr(@src(), err, "Failed to fill graph ({t})", .{err});
    };
    renderer.layout("neato") catch |err| {
        return utils.toastErr(@src(), err, "Failed to layout graph", .{});
    };
    self.graph_view.renderGraph() catch |err| {
        return utils.toastErr(@src(), err, "Failed to update graph", .{});
    };
}
