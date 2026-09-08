const std = @import("std");
const dvui = @import("dvui");
const sqlite = @import("sqlite");

const core_mod = @import("core");
const Core = core_mod.Core;
const Concept = Core.Concept;
const Graph = core_mod.Graph;
const Id = Core.Id;
const Self = @This();

const GRAPH_WIDTH = 200;
const GRAPH_HEIGHT = 200;

core: *Core,
arena: std.heap.ArenaAllocator,
render_arena: std.heap.ArenaAllocator,
concepts: []Concept = &.{},
selected: ?*Concept = null,
graph: Graph,
graph_buffer: []u8,
graph_texture: dvui.Texture,

pub fn init(gpa: std.mem.Allocator, core: *Core) !Self {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    const render_arena = std.heap.ArenaAllocator.init(gpa);
    errdefer render_arena.deinit();
    
    const graph_buffer = try arena.allocator().alloc(u8, GRAPH_WIDTH * GRAPH_HEIGHT * 4);
    // @memset(graph_buffer, 100);
    const graph_texture = try dvui.Texture.create(@ptrCast(graph_buffer), .{
        .width = GRAPH_WIDTH,
        .height = GRAPH_HEIGHT,
    });
    const graph = try Graph.init(.{ .width = GRAPH_WIDTH, .height = GRAPH_HEIGHT });

    var self: Self = .{
        .core = core,
        .arena = arena,
        .render_arena = render_arena,
        .graph = graph,
        .graph_buffer = graph_buffer,
        .graph_texture = graph_texture,
    };
    self.getConcepts();
    if (self.concepts.len  > 0) self.selected = &self.concepts[0];
    return self;
}

pub fn deinit(self: *Self) void {
    self.graph.deinit();
    // self.graph_texture.destroyLater();
    self.arena.deinit();
    self.render_arena.deinit();
}

fn toastErr(self: *Self, src: std.builtin.SourceLocation, err: anyerror, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(self.render_arena.allocator(), "{t}: " ++ fmt, .{err} ++ args) catch "An error occurred";
    dvui.toast(src, .{ .message = msg });
    dvui.logError(src, err, fmt, args);
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

    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{});
    defer hbox.deinit();

    {
        var scroll = dvui.scrollArea(@src(), .{}, .{});
        defer scroll.deinit();
        for (self.concepts, 0..) |*concept, i| {
            var c_box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i });
            defer c_box.deinit();
            if (dvui.labelClick(@src(), "{s}", .{concept.name}, .{}, .{})) {
                self.selectConcept(concept);
            }
        }
    }

    if (self.selected) |concept| {
        var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
        defer vbox.deinit();
        
        dvui.label(@src(), "{s}", .{concept.name}, .{});

        var tex_box = dvui.box(@src(), .{}, .{
            .min_size_content = .{ .w = GRAPH_WIDTH, .h = GRAPH_HEIGHT },
        });
        defer tex_box.deinit();

        dvui.renderTexture(self.graph_texture, tex_box.data().contentRectScale(), .{}) catch |err| {
            return self.toastErr(@src(), err, "Failed to render graph texture", .{});
        };
    }
}

fn selectConcept(self: *Self, concept: *Concept) void {
    self.selected = concept;
    self.graph.clear();

    var diags: sqlite.Diagnostics = .{};
    const ids: [1]Id = .{concept.id};
    self.graph.addNode(concept.id.uuid, concept.name) catch |err| {
        return self.toastErr(@src(), err, "Failed to add node", .{});
    };
    const ancestors = self.core.getAncestors(self.arena.allocator(), &ids, false, &diags) catch |err| {
        return self.toastErr(@src(), err, "Failed to get ancestors", .{});
    };
    for (ancestors) |*ancestor| {
        self.graph.addNode(ancestor.id.uuid, ancestor.name) catch |err| {
            return self.toastErr(@src(), err, "Failed to add node", .{});
        };
    }
    for (ancestors) |*ancestor| {
        self.graph.addEdge(ancestor.id.uuid, ancestor.child_id.uuid) catch |err| {
            return self.toastErr(@src(), err, "Failed to add edge", .{});
        };
    }
    self.graph.layout("dot") catch |err| {
        return self.toastErr(@src(), err, "Failed to layout graph", .{});
    };
    self.graph.renderToFile("png", "/tmp/graph.png") catch |err| {
        return self.toastErr(@src(), err, "Failed to render graph", .{});
    };
    self.graph.renderToBuffer(self.graph_buffer) catch |err| {
        return self.toastErr(@src(), err, "Failed to render graph", .{});
    };
    self.graph_texture.update(@ptrCast(self.graph_buffer)) catch |err| {
        return self.toastErr(@src(), err, "Failed to update graph texture", .{});
    };
}
