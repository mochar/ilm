const std = @import("std");
const dvui = @import("dvui");
const sqlite = @import("sqlite");

const core_mod = @import("core");
const Core = core_mod.Core;
const Concept = Core.Concept;
const Graph = core_mod.Graph;
const Id = Core.Id;
const Self = @This();

const MAX_GRAPH_WIDTH: u32 = 2048;
const MAX_GRAPH_HEIGHT: u32 = 2048;
const BUFFER_STRIDE: usize = MAX_GRAPH_WIDTH * 4;

core: *Core,
arena: std.heap.ArenaAllocator,
render_arena: std.heap.ArenaAllocator,
concepts: []Concept = &.{},
selected: ?*Concept = null,
graph: Graph,
graph_buffer: []u8,
graph_texture: dvui.Texture,
rendered_width: u32 = 0,
rendered_height: u32 = 0,
needs_rebuild: bool = true,

pub fn init(gpa: std.mem.Allocator, core: *Core) !Self {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    const render_arena = std.heap.ArenaAllocator.init(gpa);
    errdefer render_arena.deinit();

    const graph_buffer = try arena.allocator().alloc(u8, MAX_GRAPH_WIDTH * MAX_GRAPH_HEIGHT * 4);
    @memset(graph_buffer, 0);

    const graph_texture = try dvui.Texture.create(@ptrCast(graph_buffer), .{
        .width = MAX_GRAPH_WIDTH,
        .height = MAX_GRAPH_HEIGHT,
    });
    const graph = try Graph.init(gpa, .{
        .width = MAX_GRAPH_WIDTH,
        .height = MAX_GRAPH_HEIGHT,
    });

    var self: Self = .{
        .core = core,
        .arena = arena,
        .render_arena = render_arena,
        .graph = graph,
        .graph_buffer = graph_buffer,
        .graph_texture = graph_texture,
    };
    self.getConcepts();
    if (self.concepts.len > 0) {
        self.selected = &self.concepts[0];
        self.needs_rebuild = true;
    }
    return self;
}

pub fn deinit(self: *Self) void {
    self.graph.deinit();
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

    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer hbox.deinit();

    // Left sidebar scrolls independently:
    {
        var scroll = dvui.scrollArea(@src(), .{}, .{
            .expand = .vertical,
            .min_size_content = .{ .w = 200 },
        });
        defer scroll.deinit();

        for (self.concepts, 0..) |*concept, i| {
            var c_box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i, .expand = .horizontal });
            defer c_box.deinit();
            if (dvui.labelClick(@src(), "{s}", .{concept.name}, .{}, .{})) {
                self.selectConcept(concept);
            }
        }
    }

    // 3. Right pane: Expands to fill the rest of the window
    if (self.selected) |concept| {
        var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
        defer vbox.deinit();

        dvui.label(@src(), "{s}", .{concept.name}, .{});

        var tex_box = dvui.box(@src(), .{}, .{
            .expand = .both,
            .min_size_content = .{ .w = 100, .h = 100 },
        });
        defer tex_box.deinit();

        const rs = tex_box.data().contentRectScale();
        const target_w = std.math.clamp(@as(u32, @intFromFloat(@max(100.0, rs.r.w))), 100, MAX_GRAPH_WIDTH);
        const target_h = std.math.clamp(@as(u32, @intFromFloat(@max(100.0, rs.r.h))), 100, MAX_GRAPH_HEIGHT);

        if (self.needs_rebuild or target_w != self.rendered_width or target_h != self.rendered_height) {
            self.updateGraph(concept, target_w, target_h);
        }

        if (self.rendered_width > 0 and self.rendered_height > 0) {
            const u_scale = @as(f32, @floatFromInt(self.rendered_width)) / @as(f32, @floatFromInt(MAX_GRAPH_WIDTH));
            const v_scale = @as(f32, @floatFromInt(self.rendered_height)) / @as(f32, @floatFromInt(MAX_GRAPH_HEIGHT));

            dvui.renderTexture(self.graph_texture, rs, .{
                .uv = .{ .x = 0, .y = 0, .w = u_scale, .h = v_scale },
            }) catch |err| {
                return self.toastErr(@src(), err, "Failed to render graph texture", .{});
            };
        }
    }
}

fn selectConcept(self: *Self, concept: *Concept) void {
    if (self.selected != concept) {
        self.selected = concept;
        self.needs_rebuild = true;
    }
}

fn updateGraph(self: *Self, concept: *Concept, width: u32, height: u32) void {
    self.graph.clear();
    self.graph.setDimensions(width, height, 96.0) catch |err| {
        return self.toastErr(@src(), err, "Failed to set graph dimensions", .{});
    };

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
    self.graph.renderToBuffer(self.graph_buffer, .{ .stride_bytes = BUFFER_STRIDE }) catch |err| {
        return self.toastErr(@src(), err, "Failed to render graph", .{});
    };
    self.graph_texture.updateSubRect(self.graph_buffer.ptr, 0, 0, width, height) catch |err| {
        return self.toastErr(@src(), err, "Failed to update graph texture", .{});
    };

    self.rendered_width = width;
    self.rendered_height = height;
    self.needs_rebuild = false;
}
