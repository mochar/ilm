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

db_writes_buf: []DbWriter.WriteResult,
db_writes_queue: std.Io.Queue(DbWriter.WriteResult),

graph_view: GraphView,
/// To allocate graph content, reset every time we fill the graph.
graph_arena: std.heap.ArenaAllocator,

pub fn create(gpa: Allocator, core: *Core) !*Self {
    var self = try gpa.create(Self);
    errdefer gpa.destroy(self);

    const db_writes_buf = try gpa.alloc(DbWriter.WriteResult, 12);
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
    self.updateGraphContent(.clear_all);
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
    if (result.err != null) return;
    if (!result.cmd.affectsTables(&.{ .concept, .concept_rel, .crsql_changes })) return;
    const self: *Self = @ptrCast(@alignCast(self_opaque));
    self.db_writes_queue.putOneUncancelable(self.core.io, result) catch |err| {
        log.err("Failed to add concept db write: {t}", .{err});
    };
}

pub fn render(self: *Self) void {
    // Process writes buffer
    var write: DbWriter.WriteResult = undefined;
    while (self.db_writes_queue.getUncancelable(self.core.io, @ptrCast(&write), 0) catch 0 != 0) {
        if (write.cmd.affectsTables(&.{ .concept, .crsql_changes })) self.getAllConcepts();
        self.updateGraphContent(.clear_all);
        switch (write.cmd) {
            .add_concept => |payload| self.viewConceptById(payload.id.int),
            .delete_concepts, .apply_changes => self.unviewConcept(),
            else => {},
        }
    }

    const screen_size: gui.ScreenSize = .get();
    const is_wide = screen_size.width != .compact;
    var hbox = dvui.box(@src(), .{
        .dir = if (is_wide) .horizontal else .vertical,
        .equal_space = !is_wide,
    }, .{ .expand = .both });
    defer hbox.deinit();

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
            dvui.label(@src(), "{d}/{d}", .{ self.concepts.getVisible().items.len, self.concepts.getAll().items.len }, .{ .gravity_y = 0.5 })
        else
            dvui.label(@src(), "{d}", .{self.concepts.getAll().items.len}, .{ .gravity_y = 0.5 });
    }

    // Selection controls
    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hbox.deinit();

        if (dvui.button(@src(), "Select all", .{}, .{ .background = false, .margin = .all(0.0) })) {
            self.selectAll() catch {};
        }

        if (dvui.button(@src(), "Deselect all", .{}, .{ .background = false, .margin = .all(0.0) })) {
            self.deselectAll() catch {};
        }

        _ = dvui.spacer(@src(), .{ .expand = .horizontal });

        const visible = self.concepts.getVisible();
        dvui.label(
            @src(),
            "{d}/{d}",
            .{ visible.selectionSize(), visible.items.len },
            .{ .color_text = .{ .color = .gray } },
        );
    }

    // Selection actions
    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .all(8.0) });
        defer hbox.deinit();

        var scalef: f32 = 0.8;
        var scale = dvui.scale(@src(), .{ .scale = &scalef }, .{ .expand = .horizontal });
        defer scale.deinit();

        const has_selection = self.concepts.selectionSize() > 0;

        if (dvui.buttonLabelAndIcon(
            @src(),
            .{ .label = " Delete", .tvg_bytes = dvui.entypo.trash, .icon_first = true, .button_opts = .{ .grayed = !has_selection } },
            .{
                .background = false,
                .margin = .all(0.0),
                .border = .all(1.0),
            },
        ) and has_selection) {
            self.deleteSelection() catch {};
        }
    }

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
                self.toggleSelection(concept);
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
            .select => |id| {
                if (self.viewing != null and self.viewing.?.concept.id.int == id) {
                    self.unviewConcept();
                } else {
                    self.viewConceptById(id);
                }
            },
            .assign_parent => |assign| {
                if (ilm.concept.addParent(self.core, .{ .int = assign.child }, .{ .int = assign.parent })) {
                    self.updateGraphContent(.clear_all);
                } else |err| {
                    gui.toastErr(@src(), err, "Failed to assign", .{});
                }
                dvui.currentWindow().refreshWindow(@src(), null);
            },
            .selection => {
                self.concepts.search.query.clearRetainingCapacity();
                self.concepts.all.deselectAll();
                var selected_ids = self.graph_view.renderer.selection.keyIterator();
                while (selected_ids.next()) |selected_id| {
                    _ = self.concepts.all.toggleSelected(selected_id.*);
                }
                dvui.currentWindow().refreshWindow(@src(), null);
            },
        }
    }
}

fn getAllConcepts(self: *Self) void {
    self.concepts.fetchAll() catch |err| {
        gui.toastErr(@src(), err, "Failed to get all concepts", .{});
    };
    self.getMatchingConcepts();
}

fn getMatchingConcepts(self: *Self) void {
    self.concepts.fetchMatching() catch |err| {
        gui.toastErr(@src(), err, "Failed to get queried concepts", .{});
    };
}

fn syncSelectionToGraph(self: *Self) !void {
    self.graph_view.renderer.selection.clearRetainingCapacity();
    try self.graph_view.renderer.selection.ensureTotalCapacity(@intCast(self.concepts.selectionSize()));
    
    var sel_iter = self.concepts.selectionIter();
    while (sel_iter.next()) |concept| {
        self.graph_view.renderer.selection.putAssumeCapacity(concept.id.int, {});
    }
    
    try self.graph_view.renderGraph();
}

fn toggleSelection(self: *Self, concept: *const Concept) void {
    if (self.concepts.toggleSelected(concept.id.int)) {
        self.graph_view.renderer.selection.put(concept.id.int, {}) catch {};
    } else {
        _ = self.graph_view.renderer.selection.remove(concept.id.int);
    }
    self.graph_view.renderGraph() catch {};
}

fn selectAll(self: *Self) !void {
    try self.concepts.selectAll();
    try self.syncSelectionToGraph();
}

fn deselectAll(self: *Self) !void {
    try self.concepts.deselectAll();
    try self.syncSelectionToGraph();
}

fn deleteSelection(self: *Self) !void {
    try self.concepts.deleteSelection();
    try self.syncSelectionToGraph();
}

pub fn viewingId(self: *Self) ?u128 {
    return if (self.viewing) |v| v.concept.id.int else null;
}

fn viewConceptById(self: *Self, id: u128) void {
    if (self.viewing) |s| if (s.concept.id.int == id) return;
    for (self.concepts.getAll().items) |*concept| {
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

fn updateGraphContent(self: *Self, how: enum { clear_all, clear_graph }) void {
    var renderer = &self.graph_view.renderer;
    const graph = self.graph_view.graph();

    switch (how) {
        .clear_all => renderer.clear(),
        .clear_graph => renderer.graph.clear(),
    }
    _ = self.graph_arena.reset(.retain_capacity);

    const arena = self.graph_arena.allocator();
    ilm.concept.fillFullGraph(self.core, graph, arena, self.concepts.getAll().items) catch |err| {
        return gui.toastErr(@src(), err, "Failed to fill graph ({t})", .{err});
    };
    renderer.layout("neato") catch |err| {
        return gui.toastErr(@src(), err, "Failed to layout graph", .{});
    };
    // self.graph_view.renderGraph() catch |err| {
    self.graph_view.updateGraph() catch |err| {
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
            self.concepts.deinit();
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
        self.all.deinit();
        self.search.deinit(self.gpa);
    }

    pub fn fetchAll(self: *ConceptManager) !void {
        try self.all.fetchAll(self.core);
    }

    pub fn fetchMatching(self: *ConceptManager) !void {
        try self.search.concepts.fetchMatching(self.core, self.search.query.items);
        try self.search.concepts.copySelection(&self.all);
    }

    pub fn isSearching(self: *const ConceptManager) bool {
        return self.search.query.items.len > 0;
    }

    pub fn getAll(self: *ConceptManager) *Concepts {
        return &self.all;
    }

    pub fn getVisible(self: *ConceptManager) *Concepts {
        return if (self.isSearching()) &self.search.concepts else &self.all;
    }

    pub fn selectionSize(self: *ConceptManager) usize {
        return self.getVisible().selectionSize();
    }

    pub fn isSelected(self: *ConceptManager, concept: *const Concept) bool {
        return self.getVisible().isSelected(concept);
    }
    
    pub fn selectionIter(self: *ConceptManager) Concepts.SelectionIterator {
        return self.getVisible().selectionIter();
    }


    /// Returns the new toggle state
    pub fn toggleSelected(self: *ConceptManager, concept_id: u128) bool {
        const selected = self.all.toggleSelected(concept_id);
        if (self.isSearching()) {
            _ = self.search.concepts.toggleSelected(concept_id);
        }
        return selected;
    }

    pub fn selectAll(self: *ConceptManager) !void {
        self.search.concepts.selectAll();
        if (self.isSearching()) {
            try self.all.copySelection(&self.search.concepts);
        } else {
            self.all.selectAll();
        }
    }

    pub fn deselectAll(self: *ConceptManager) !void {
        if (self.isSearching()) {
            for (self.search.concepts.items) |*search_concept| {
                if (self.all.selection.inverted) {
                    try self.all.selection.ids.put(search_concept.id.int, {});
                } else {
                    _ = self.all.selection.ids.remove(search_concept.id.int);
                }
            }

            self.search.concepts.deselectAll();
        } else {
            self.all.deselectAll();
            self.search.concepts.deselectAll();
        }
    }

    pub fn deleteSelection(self: *ConceptManager) !void {
        const ids = try self.gpa.alloc(Id, self.selectionSize());
        defer self.gpa.free(ids);

        var sel_iter = self.selectionIter();
        var i: usize = 0;
        while (sel_iter.next()) |concept| {
            ids[i] = concept.id;
            i += 1;
        }

        try ilm.concept.deleteMany(self.core, ids);
    }
};

const Concepts = struct {
    arena: std.heap.ArenaAllocator,
    items: []Concept,
    selection: struct {
        // TODO Shorten to u68
        ids: std.AutoHashMap(u128, void),
        inverted: bool = false,

        pub fn deinit(self: *@This()) void {
            self.ids.deinit();
        }
    },

    pub fn init(gpa: Allocator) Concepts {
        return .{
            .arena = .init(gpa),
            .items = &.{},
            .selection = .{ .ids = .init(gpa) },
        };
    }

    pub fn deinit(self: *Concepts) void {
        self.selection.deinit();
        self.arena.deinit();
    }

    pub fn fetchAll(self: *Concepts, core: *Core) !void {
        _ = self.arena.reset(.retain_capacity);
        self.selection.ids.clearAndFree();

        const concepts = try ilm.concept.getAll(core, self.arena.allocator());
        self.items = concepts;
    }

    pub fn fetchMatching(self: *Concepts, core: *Core, query: []const u8) !void {
        _ = self.arena.reset(.retain_capacity);
        self.selection.ids.clearAndFree();

        const concepts = try ilm.concept.getByNameMatch(core, self.arena.allocator(), query);
        self.items = concepts;
    }

    pub fn selectionSize(self: *Concepts) usize {
        const size: usize = self.selection.ids.count();
        return if (self.selection.inverted) return self.items.len - size else size;
    }

    pub fn isSelected(self: *Concepts, concept: *const Concept) bool {
        const in_selection = self.selection.ids.contains(concept.id.int);
        return if (self.selection.inverted) !in_selection else in_selection;
    }

    pub fn copySelection(self: *Concepts, other: *Concepts) !void {
        self.selection.ids.clearRetainingCapacity();
        self.selection.inverted = false;
        for (other.items) |*c| {
            if (other.isSelected(c)) {
                try self.selection.ids.put(c.id.int, {});
            }
        }
    }

    /// Returns thne new toggle state
    pub fn toggleSelected(self: *Concepts, concept_id: u128) bool {
        const in_selection = self.selection.ids.contains(concept_id);
        if (in_selection) {
            _ = self.selection.ids.remove(concept_id);
            return false;
        } else {
            self.selection.ids.put(concept_id, {}) catch {};
            return true;
        }
    }

    pub fn selectAll(self: *Concepts) void {
        self.selection.inverted = true;
        self.selection.ids.clearAndFree();
    }

    pub fn deselectAll(self: *Concepts) void {
        self.selection.inverted = false;
        self.selection.ids.clearAndFree();
    }

    pub fn selectionIter(self: *Concepts) SelectionIterator {
        return .{ .concepts = self };
    }

    pub const SelectionIterator = struct {
        concepts: *Concepts,
        i_conc: usize = 0,
        i_sel: usize = 0,
        
        pub fn next(self: *@This()) ?*Concept {
            if (self.i_conc == self.concepts.items.len) return null;
            
            const n_selected = self.concepts.selectionSize();
            if (self.i_sel == n_selected) return null;

            for (self.concepts.items[self.i_conc..]) |*concept| {
                defer self.i_conc += 1;
                
                if (self.concepts.isSelected(concept)) {
                    self.i_sel += 1;
                    return concept;
                }
            }

            return null;
        }
    };
};
