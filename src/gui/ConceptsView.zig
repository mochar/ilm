const std = @import("std");
const dvui = @import("dvui");

const ilm = @import("ilm");
const Core = ilm.Core;
const Concept = ilm.concept.Concept;
const Id = ilm.Id;

const GraphView = @import("GraphView.zig");
const utils = @import("utils.zig");
const Self = @This();

const log = std.log.scoped(.concepts_view);

const MAX_GRAPH_WIDTH: u32 = 2048;
const MAX_GRAPH_HEIGHT: u32 = 2048;

core: *Core,
gpa: std.mem.Allocator,
all_concepts: []Concept = &.{},
selected: ?*Concept = null,

search_query: std.ArrayList(u8) = .empty,
/// Matched concepts (the structs themselves and the strings within)
/// are allocated using this arena. It is reset each time the search
/// query is changed.
search_arena: std.heap.ArenaAllocator,
matched_concepts: []Concept = &.{},

graph_view: GraphView,
/// To allocate graph content, reset every time we fill the graph.
graph_arena: std.heap.ArenaAllocator,

pub fn init(gpa: std.mem.Allocator, core: *Core) !Self {
    var graph_view: GraphView = try .init(.{
        .gpa = gpa,
        .io = core.io,
        .max_width = MAX_GRAPH_WIDTH,
        .max_height = MAX_GRAPH_HEIGHT,
    });
    errdefer graph_view.deinit();

    var self: Self = .{
        .core = core,
        .gpa = gpa,
        .search_arena = .init(gpa),
        .graph_view = graph_view,
        .graph_arena = .init(gpa),
    };
    self.graph_view.on_node_select = selectConceptById;

    self.getAllConcepts();
    if (self.all_concepts.len > 0) {
        self.updateGraphContent();
    }
    return self;
}

pub fn deinit(self: *Self) void {
    self.graph_view.deinit();
    self.graph_arena.deinit();
    self.gpa.free(self.all_concepts);
    self.search_query.deinit(self.gpa);
    self.search_arena.deinit();
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

    const selected_id: ?u128 = if (self.selected) |c| c.id.uuid else null;
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

fn renderGraph(self: *Self) void {
    self.graph_view.render() catch |err| {
        utils.toastErr(@src(), err, "Failed to render graph", .{});
    };
}

fn selectConceptById(graph_view: *GraphView, id: u128) void {
    const self: *Self = @fieldParentPtr("graph_view", graph_view);
    if (self.selected) |s| if (s.id.uuid == id) return;
    for (self.all_concepts) |*concept| {
        if (concept.id.uuid == id) {
            self.selectConcept(concept);
            return;
        }
    }
    dvui.toast(@src(), .{ .message = "Failed to find concept" });
}

fn selectConcept(self: *Self, concept: *Concept) void {
    if (self.selected == concept) return;
    self.selected = concept;
    self.updateGraphContent();
}

fn unselect(self: *Self) void {
    if (self.selected == null) return;
    self.selected = null;
    self.updateGraphContent();
}

/// Replace the graph nodes and edges with that of self.selected
fn updateGraphContent(self: *Self) void {
    var renderer = self.graph_view.renderer;
    const graph = self.graph_view.graph();
    const arena = self.graph_arena.allocator();

    renderer.clear();
    _ = self.graph_arena.reset(.retain_capacity);

    // Fill graph
    if (self.selected) |concept| {
        renderer.highlighted.put(concept.id.uuid, {}) catch |err| {
            return utils.toastErr(@src(), err, "Failed to add graph highlight", .{});
        };
        ilm.concept.fillAncestorGraph(self.core, graph, arena, concept) catch |err| {
            return utils.toastErr(@src(), err, "Failed to fill graph ({t})", .{err});
        };
    } else {
        ilm.concept.fillFullGraph(self.core, graph, arena, self.all_concepts) catch |err| {
            return utils.toastErr(@src(), err, "Failed to fill graph ({t})", .{err});
        };
    }

    // Render
    renderer.layout("neato") catch |err| {
        return utils.toastErr(@src(), err, "Failed to layout graph", .{});
    };
    self.graph_view.update() catch |err| {
        return utils.toastErr(@src(), err, "Failed to update graph", .{});
    };
}
