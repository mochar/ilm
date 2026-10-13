const std = @import("std");
const Allocator = std.mem.Allocator;
const dvui = @import("dvui");

const ilm = @import("ilm");
const Core = ilm.Core;
const Concept = ilm.concept.Concept;
const Id = ilm.Id;
const DbWriter = ilm.database.DbWriter;

const GraphView = @import("GraphView.zig");
const ConceptView = @import("ConceptView.zig");
const gui = @import("gui.zig");
const Self = @This();

const log = std.log.scoped(.concepts_view);

const MAX_GRAPH_WIDTH: u32 = 2048;
const MAX_GRAPH_HEIGHT: u32 = 2048;

core: *Core,
gpa: Allocator,

concepts: ConceptManager,

viewing: ?struct {
    concept: *Concept,
    view: *ConceptView,

    pub fn deinit(self: *@This()) void {
        self.view.destroy();
    }
} = null,

db_writes_buf: []DbWriter.Write,
db_writes_queue: std.Io.Queue(DbWriter.Write),

graph_view: GraphView,
/// To allocate graph content, reset every time we fill the graph.
graph_arena: std.heap.ArenaAllocator,

pub fn create(gpa: Allocator, core: *Core) !*Self {
    var self = try gpa.create(Self);
    errdefer gpa.destroy(self);

    const db_writes_buf = try gpa.alloc(DbWriter.Write, 12);
    errdefer gpa.free(db_writes_buf);

    var graph_view: GraphView = try .init(.{
        .gpa = gpa,
        .io = core.io,
        .max_width = MAX_GRAPH_WIDTH,
        .max_height = MAX_GRAPH_HEIGHT,
        .src = @src(),
    });
    errdefer graph_view.deinit();

    var concepts: ConceptManager = .init(core, gpa);
    errdefer concepts.deinit();

    self.* = .{
        .core = core,
        .gpa = gpa,
        .concepts = concepts,
        .db_writes_buf = db_writes_buf,
        .db_writes_queue = .init(db_writes_buf),
        .graph_view = graph_view,
        .graph_arena = .init(gpa),
    };
    errdefer self.destroy();

    try core.db_writer.subscribe(.{ .cb = dbWriteCallback, .ctx = @ptrCast(self) });

    self.getAllConcepts();
    self.updateGraphContent(.reset);
    return self;
}

pub fn destroy(self: *Self) void {
    self.db_writes_queue.close(self.core.io);
    self.gpa.free(self.db_writes_buf);

    self.graph_view.deinit();
    self.graph_arena.deinit();

    if (self.viewing) |*v| v.deinit();
    self.concepts.deinit();

    self.gpa.destroy(self);
}

fn dbWriteCallback(self_opaque: *anyopaque, result: DbWriter.WriteResult) void {
    const write = result.write catch return;
    switch (write.table_id) {
        .concept, .concept_rel, .crsql_changes => {
            const self: *Self = @ptrCast(@alignCast(self_opaque));
            self.db_writes_queue.putOneUncancelable(self.core.io, write) catch |err| {
                log.err("Failed to add concept db write: {t}", .{err});
            };
        },
        else => {},
    }
}

pub fn render(self: *Self) void {
    const screen_size: gui.ScreenSize = .get();
    const is_wide = screen_size.width != .compact;
    var hbox = dvui.box(@src(), .{
        .dir = if (is_wide) .horizontal else .vertical,
        .equal_space = !is_wide,
    }, .{ .expand = .both });
    defer hbox.deinit();

    // Process writes buffer
    var write: DbWriter.Write = undefined;
    while (self.db_writes_queue.getUncancelable(self.core.io, @ptrCast(&write), 0) catch 0 != 0) {
        switch (write.table_id) {
            .concept => |id| {
                switch (write.op) {
                    .update => {
                        self.getAllConcepts();
                        self.updateGraphContent(.retain_state);
                    },
                    .insert => {
                        self.getAllConcepts();
                        self.updateGraphContent(.retain_state);
                        self.viewConceptById(id.int);
                    },
                    .delete => {
                        self.getAllConcepts();
                        self.updateGraphContent(.reset);
                        self.unviewConcept();
                    },
                }
            },
            .concept_rel => |ids| {
                _ = ids;
                self.updateGraphContent(.retain_state);
            },
            .crsql_changes => {
                self.getAllConcepts();
                self.updateGraphContent(.reset);
                self.unviewConcept();
            },
            else => {},
        }
    }

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
    if (self.viewing == null) {
        self.renderActions();
        self.renderConceptList();
    } else {
        self.renderConceptView();
    }
}

fn renderActions(self: *Self) void {
    if (dvui.buttonLabelAndIcon(
        @src(),
        .{
            .label = "Add concept",
            .tvg_bytes = dvui.entypo.plus,
        },
        .{ .expand = .horizontal },
    )) {
        if (ilm.concept.add(self.core, "New concept", &.{})) |child_id| {
            _ = child_id;
        } else |err| {
            gui.toastErr(@src(), err, "Failed to create concept", .{});
        }
    }
}

fn renderConceptList(self: *Self) void {
    // Search bar
    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hbox.deinit();

        var search_entry = dvui.textEntry(
            @src(),
            .{
                .placeholder = "Search",
                .text = .{
                    .array_list = .{
                        .allocator = self.gpa,
                        .backing = &self.concepts.search.query,
                    },
                },
            },
            .{ .expand = .horizontal },
        );
        const search_changed = search_entry.text_changed;
        search_entry.deinit();
        defer if (search_changed) {
            log.info("Search changed to: {s}", .{self.concepts.search.query.items});
            self.getMatchingConcepts();
        };

        if (self.concepts.isSearching())
            dvui.label(@src(), "{d}/{d}", .{ self.concepts.getVisible().items.len, self.concepts.all.items.len }, .{ .gravity_y = 0.5 })
        else
            dvui.label(@src(), "{d}", .{self.concepts.all.items.len}, .{ .gravity_y = 0.5 });
    }

    // Selection controls
    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hbox.deinit();

        if (dvui.button(@src(), "Select all", .{}, .{ .background = false, .margin = .all(0.0) })) {
            self.concepts.selectAll() catch |err| {
                gui.toastErr(@src(), err, "Failed to select all", .{});
            };
        }

        if (dvui.button(@src(), "Deselect all", .{}, .{ .background = false, .margin = .all(0.0) })) {
            self.concepts.deselectAll() catch |err| {
                gui.toastErr(@src(), err, "Failed to deselect all", .{});
            };
        }

        _ = dvui.spacer(@src(), .{ .expand = .horizontal });

        // TODO This should take into account the queried concepts
        const visible = self.concepts.getVisible();
        dvui.label(@src(), "{d}/{d}", .{ visible.selection.ids.size, visible.items.len }, .{ .color_text = .{ .color = .gray } });
    }

    // Selection actions
    // const n_visible_concepts = if (self.selection_inverted) 1 - self.selection_ids.count()
    // const has_selection = if (self.selection_inverted) self.selection_ids.len ==
    // if (self.selection_ids) {
    //     var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    //     defer hbox.deinit();

    //     if (dvui.buttonLabelAndIcon(
    //         @src(),
    //         .{
    //             .label = "Delete",
    //             .tvg_bytes = dvui.entypo.trash,
    //         },
    //         .{
    //             .expand = .horizontal,
    //             // .color_fill = .red,
    //             .background = false,
    //             .margin = .all(0.0),
    //         },
    //     )) {}
    // }

    // Concept list
    {
        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
        defer scroll.deinit();

        const viewing_id = self.viewingId();
        for (self.concepts.getVisible().items, 0..) |*concept, i| {
            _ = i;
            const is_viewing = concept.id.int == viewing_id;

            var c_box = dvui.box(
                @src(),
                .{ .dir = .horizontal },
                .{
                    .id_extra = @truncate(concept.id.int),
                    .expand = .horizontal,
                    .background = true,
                    .style = if (is_viewing) .highlight else null,
                },
            );
            defer c_box.deinit();

            if (gui.manualCheckbox(@src(), self.concepts.isSelected(concept), .{})) {
                self.concepts.toggleSelected(concept);
            }

            if (dvui.labelClick(@src(), "{s}", .{concept.name}, .{}, .{ .expand = .both })) {
                if (is_viewing) self.unviewConcept() else self.viewConcept(concept);
            }
        }
    }
}

fn renderConceptView(self: *Self) void {
    if (self.viewing) |*selected| {
        var view = selected.view;
        if (view.render()) |action| {
            switch (action) {
                .quit => self.unviewConcept(),
                .node_select => |id| self.viewConceptById(id),
                else => {},
            }
        }
    }
}

fn renderGraph(self: *Self) void {
    if (self.graph_view.render(.{ .expand = .both }) catch |err| {
        return gui.toastErr(@src(), err, "Failed to render graph", .{});
    }) |action| {
        switch (action) {
            .node_select => |id| {
                if (self.viewing != null and self.viewing.?.concept.id.int == id) {
                    self.unviewConcept();
                } else {
                    self.viewConceptById(id);
                }
            },
            .assign_parent => |assign| {
                if (ilm.concept.addParent(self.core, .{ .int = assign.child }, .{ .int = assign.parent })) {
                    self.updateGraphContent(.reset);
                } else |err| {
                    gui.toastErr(@src(), err, "Failed to assign", .{});
                }
            },
        }
    }
}

fn getAllConcepts(self: *Self) void {
    self.concepts.fetchAll() catch |err| {
        gui.toastErr(@src(), err, "Failed to get all concepts", .{});
    };
}

fn getMatchingConcepts(self: *Self) void {
    self.concepts.fetchMatching() catch |err| {
        gui.toastErr(@src(), err, "Failed to get queried concepts", .{});
    };
}

pub fn viewingId(self: *Self) ?u128 {
    return if (self.viewing) |v| v.concept.id.int else null;
}

fn viewConceptById(self: *Self, id: u128) void {
    if (self.viewing) |s| if (s.concept.id.int == id) return;
    for (self.concepts.all.items) |*concept| {
        if (concept.id.int == id) {
            self.viewConcept(concept);
            return;
        }
    }
    dvui.toast(@src(), .{ .message = "Failed to find concept" });
}

fn viewConcept(self: *Self, concept: *Concept) void {
    if (self.viewing) |*viewing| {
        if (viewing.concept == concept) return;
        
        // TODO Duplicate code in unviewConcept()
        viewing.view.destroy();
        self.viewing = null;
        
        self.graph_view.renderer.highlighted.clearRetainingCapacity();
    }

    const concept_view = ConceptView.create(.{
        .concept_id = concept.id,
        .core = self.core,
        .gpa = self.core.gpa,
        .io = self.core.io,
    }) catch |err| {
        log.err("Error init concept view: {t}", .{err});
        gui.toastErr(@src(), err, "Error init concept view", .{});
        self.viewing = null;
        return;
    };

    self.viewing = .{ .concept = concept, .view = concept_view };

    self.graph_view.animateToNode(concept.id.int) catch {};
    self.graph_view.renderer.highlighted.put(concept.id.int, {}) catch {};
}

fn unviewConcept(self: *Self) void {
    if (self.viewing) |*viewing| {
        viewing.view.destroy();
        self.viewing = null;
        
        self.graph_view.animateFitToGraph() catch {};
        self.graph_view.renderer.highlighted.clearRetainingCapacity();
    }
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

    ilm.concept.fillFullGraph(self.core, graph, arena, self.concepts.all.items) catch |err| {
        return gui.toastErr(@src(), err, "Failed to fill graph ({t})", .{err});
    };
    renderer.layout("neato") catch |err| {
        return gui.toastErr(@src(), err, "Failed to layout graph", .{});
    };
    self.graph_view.renderGraph() catch |err| {
        return gui.toastErr(@src(), err, "Failed to update graph", .{});
    };
}

const ConceptManager = struct {
    core: *Core,
    gpa: Allocator,

    all: Concepts,

    search: struct {
        query: std.ArrayList(u8) = .empty,
        concepts: Concepts,

        pub fn init(gpa: Allocator) @This() {
            return .{ .concepts = .init(gpa) };
        }

        pub fn deinit(self: *@This(), gpa: Allocator) void {
            self.query.deinit(gpa);
            self.concepts.deinit(gpa);
        }
    },

    pub fn init(core: *Core, gpa: Allocator) ConceptManager {
        return .{
            .core = core,
            .gpa = gpa,
            .all = .init(gpa),
            .search = .init(gpa),
        };
    }

    pub fn deinit(self: *ConceptManager) void {
        self.all.deinit(self.gpa);
        self.search.deinit(self.gpa);
    }

    pub fn fetchAll(self: *ConceptManager) !void {
        try self.all.fetchAll(self.core);
    }

    pub fn fetchMatching(self: *ConceptManager) !void {
        try self.search.concepts.fetchMatching(self.core, self.search.query.items);
        try self.search.concepts.copySelection(self.gpa, &self.all);
    }

    pub fn isSearching(self: *ConceptManager) bool {
        return self.search.query.items.len > 0;
    }

    pub fn getVisible(self: *ConceptManager) Concepts {
        return if (self.isSearching()) self.search.concepts else self.all;
    }

    pub fn isSelected(self: *ConceptManager, concept: *const Concept) bool {
        return if (self.isSearching())
            self.search.concepts.isSelected(concept)
        else
            self.all.isSelected(concept);
    }

    pub fn toggleSelected(self: *ConceptManager, concept: *const Concept) void {
        self.all.toggleSelected(self.gpa, concept);
        if (self.isSearching()) {
            self.search.concepts.toggleSelected(self.gpa, concept);
        }
    }

    pub fn selectAll(self: *ConceptManager) !void {
        self.search.concepts.selectAll(self.gpa);
        if (self.isSearching()) {
            try self.all.copySelection(self.gpa, &self.search.concepts);
        } else {
            self.all.selectAll(self.gpa);
        }
    }

    pub fn deselectAll(self: *ConceptManager) !void {
        if (self.isSearching()) {
            for (self.search.concepts.items) |*search_concept| {
                if (self.all.selection.inverted) {
                    try self.all.selection.ids.put(self.gpa, search_concept.id.int, {});
                } else {
                    _ = self.all.selection.ids.remove(search_concept.id.int);
                }
            }

            self.search.concepts.deselectAll(self.gpa);
        } else {
            self.all.deselectAll(self.gpa);
            self.search.concepts.deselectAll(self.gpa);
        }
    }
};

const Concepts = struct {
    arena: std.heap.ArenaAllocator,
    items: []Concept,

    selection: struct {
        // TODO Shorten to u68
        ids: std.AutoHashMapUnmanaged(u128, void) = .empty,
        inverted: bool = false,

        pub fn deinit(self: *@This(), gpa: Allocator) void {
            self.ids.deinit(gpa);
        }
    },

    pub fn init(gpa: Allocator) Concepts {
        return .{
            .arena = .init(gpa),
            .items = &.{},
            .selection = .{},
        };
    }

    pub fn deinit(self: *Concepts, gpa: Allocator) void {
        self.selection.deinit(gpa);
        self.arena.deinit();
    }

    pub fn fetchAll(self: *Concepts, core: *Core) !void {
        _ = self.arena.reset(.retain_capacity);
        const concepts = try ilm.concept.getAll(core, self.arena.allocator());
        self.items = concepts;
    }

    pub fn fetchMatching(self: *Concepts, core: *Core, query: []const u8) !void {
        _ = self.arena.reset(.retain_capacity);
        const concepts = try ilm.concept.getByNameMatch(core, self.arena.allocator(), query);
        self.items = concepts;
    }

    pub fn copySelection(self: *Concepts, gpa: Allocator, other: *Concepts) !void {
        self.selection.ids.clearRetainingCapacity();
        self.selection.inverted = false;
        for (other.items) |*c| {
            if (other.isSelected(c)) {
                try self.selection.ids.put(gpa, c.id.int, {});
            }
        }
    }

    pub fn isSelected(self: *Concepts, concept: *const Concept) bool {
        const in_selection = self.selection.ids.contains(concept.id.int);
        return if (self.selection.inverted) !in_selection else in_selection;
    }

    pub fn toggleSelected(self: *Concepts, gpa: Allocator, concept: *const Concept) void {
        const in_selection = self.selection.ids.contains(concept.id.int);
        if (in_selection) {
            _ = self.selection.ids.remove(concept.id.int);
        } else {
            self.selection.ids.put(gpa, concept.id.int, {}) catch {};
        }
    }

    pub fn selectAll(self: *Concepts, gpa: Allocator) void {
        self.selection.inverted = true;
        self.selection.ids.clearAndFree(gpa);
    }

    pub fn deselectAll(self: *Concepts, gpa: Allocator) void {
        self.selection.inverted = false;
        self.selection.ids.clearAndFree(gpa);
    }
};
