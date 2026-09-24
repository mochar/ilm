const std = @import("std");
const dvui = @import("dvui");
const sqlite = @import("sqlite");

const ilm = @import("ilm");
const Core = ilm.Core;
const Concept = ilm.concept.Concept;
const GraphRenderer = ilm.GraphRenderer;
const Id = ilm.Id;
const Self = @This();

const log = std.log.scoped(.concepts_view);

const MAX_GRAPH_WIDTH: u32 = 2048;
const MAX_GRAPH_HEIGHT: u32 = 2048;

var debug_window: bool = false;

core: *Core,
arena: std.heap.ArenaAllocator,
render_arena: std.heap.ArenaAllocator,
concepts: []Concept = &.{},
selected: ?*Concept = null,
graph_renderer: GraphRenderer,
graph_texture: dvui.Texture,
rendered_width: u32 = 0,
rendered_height: u32 = 0,

pub fn init(gpa: std.mem.Allocator, core: *Core) !Self {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    const render_arena = std.heap.ArenaAllocator.init(gpa);
    errdefer render_arena.deinit();

    const graph_renderer = try GraphRenderer.init(.{
        .gpa = gpa,
        .io = core.io,
        .graph_options = .{},
        .buffer_stride = MAX_GRAPH_WIDTH,
        .buffer_height = MAX_GRAPH_HEIGHT,
    });
    const graph_texture = try dvui.Texture.create(@ptrCast(graph_renderer.buffer), .{
        .width = MAX_GRAPH_WIDTH,
        .height = MAX_GRAPH_HEIGHT,
        .interpolation = .nearest,
    });

    var self: Self = .{
        .core = core,
        .arena = arena,
        .render_arena = render_arena,
        .graph_renderer = graph_renderer,
        .graph_texture = graph_texture,
    };
    self.getConcepts();
    if (self.concepts.len > 0) {
        // self.selectConcept(&self.concepts[0]);
        self.updateGraphContent();
        self.updateGraphTexture();
    }
    return self;
}

pub fn deinit(self: *Self) void {
    self.graph_renderer.deinit();
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

    if (ilm.concept.getAll(self.core, arena)) |concepts| {
        self.concepts = self.arena.allocator().dupe(Concept, concepts) catch {
            return dvui.toast(@src(), .{ .message = "Failed to allocate concepts" });
        };
    } else |_| {
        dvui.toast(@src(), .{ .message = "Failed to get concepts" });
    }
}

pub fn render(self: *Self) void {
    defer _ = self.render_arena.reset(.retain_capacity);

    {
        var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .font = .theme(.title) });
        defer tl.deinit();
        tl.format("Found {d} concepts", .{self.concepts.len}, .{});
    }

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

    if (debug_window) {
        const os_win = dvui.osWindow(
            @src(),
            .{ .title = "Child os window (or so I hope)", .size = .{ .w = 500, .h = 300 } },
            .{ .open_flag = &debug_window },
        );
        defer os_win.deinit();

        const b = dvui.box(@src(), .{}, .{ .background = true, .corners = .{
            .tl = .square,
            .tr = .square,
            .br = .default,
            .bl = .default,
        }, .expand = .both });
        defer b.deinit();

        dvui.structUI(@src(), "state", &self.graph_renderer.state, 3, .{}, .{ .expand = .both });
    }
}

fn renderSidebar(self: *Self, is_wide: bool) void {
    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = if (is_wide) .vertical else .both,
        .min_size_content = .{ .w = 200 },
    });
    defer scroll.deinit();

    const selected_id: ?u128 = if (self.selected) |c| c.id.uuid else null;
    for (self.concepts, 0..) |*concept, i| {
        const is_selected = concept.id.uuid == selected_id;
        var c_box = dvui.box(
            @src(),
            .{ .dir = .horizontal },
            .{
                .id_extra = i,
                .expand = .horizontal,
                .background = true,
                .style = if (is_selected) .highlight else null,
            },
        );
        defer c_box.deinit();
        if (dvui.labelClick(@src(), "{s}", .{concept.name}, .{}, .{ .expand = .both })) {
            if (is_selected) self.unselect() else self.selectConcept(concept);
        }
    }
}

fn renderGraph(self: *Self) void {
    var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer vbox.deinit();

    {
        var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .font = .theme(.title) });
        defer tl.deinit();
        if (self.selected) |concept| {
            tl.format("{s}", .{concept.name}, .{});
        } else {
            tl.format("All concepts", .{}, .{});
        }
    }

    var texture_box = dvui.box(@src(), .{}, .{
        .expand = .both,
        .min_size_content = .{ .w = 100, .h = 100 },
    });
    defer texture_box.deinit();

    // _ = dvui.spacer(@src(), .{ .expand = .both });

    // Get available width and height and clamp it to max graph dimensions
    const rs = texture_box.data().contentRectScale();
    const target_w = std.math.clamp(@as(u32, @intFromFloat(@max(1.0, rs.r.w))), 1, @max(1, MAX_GRAPH_WIDTH));
    const target_h = std.math.clamp(@as(u32, @intFromFloat(@max(1.0, rs.r.h))), 1, @max(1, MAX_GRAPH_HEIGHT));

    // Update graph renderer and texture if the available space has changed
    if (target_w != self.rendered_width or target_h != self.rendered_height) {
        self.rendered_width = target_w;
        self.rendered_height = target_h;
        self.updateGraphTexture();
    }

    self.handleEvents(texture_box.data(), rs);

    // Render the graph texture. Set uv to only view the rendered part of
    // the buffer.
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

fn handleEvents(self: *Self, wd: *dvui.WidgetData, rs: dvui.RectScale) void {
    for (dvui.events()) |*e| {
        if (!dvui.eventMatchSimple(e, wd)) continue;

        switch (e.evt) {
            .mouse => |me| {
                // Map graph texture coordinates to screen coordinates
                const rs_w = @max(1.0, rs.r.w);
                const rs_h = @max(1.0, rs.r.h);
                const scale_x = @as(f32, @floatFromInt(self.rendered_width)) / rs_w;
                const scale_y = @as(f32, @floatFromInt(self.rendered_height)) / rs_h;
                const x = (me.p.x - rs.r.x) * scale_x;
                const y = (me.p.y - rs.r.y) * scale_y;

                switch (me.action) {
                    .press => {
                        log.info("Press: {t}", .{me.button});
                        var btn: ?GraphRenderer.MouseButton = switch (me.button) {
                            .left, .touch0, .touch1 => .left,
                            .right => .right,
                            .middle => .middle,
                            else => null,
                        };
                        if (me.button.touch()) btn = .left;
                        if (btn) |b| {
                            e.handle(@src(), wd);
                            dvui.captureMouse(wd, e.num);
                            if (self.graph_renderer.mouseDown(x, y, b)) |rerender| {
                                if (rerender) self.syncGraphTexture();
                            } else |err| {
                                self.toastErr(@src(), err, "Failed mouse down", .{});
                            }
                        }
                    },
                    .release => {
                        log.info("Release: {t}", .{me.button});
                        if (dvui.captured(wd.id)) {
                            e.handle(@src(), wd);
                            dvui.captureMouse(null, e.num);
                            if (self.graph_renderer.hovered) |node| {
                                self.selectConceptById(node.getId() catch unreachable);
                            } else if (self.graph_renderer.mouseUp(x, y)) |rerender| {
                                if (rerender) self.syncGraphTexture();
                            } else |err| {
                                self.toastErr(@src(), err, "Failed mouse up", .{});
                            }
                        }
                    },
                    .motion => {
                        log.info("Motion", .{});
                        if (dvui.captured(wd.id)) {
                        // if (true) {
                            e.handle(@src(), wd);
                            if (self.graph_renderer.mouseMove(x, y)) |rerender| {
                                if (rerender) self.syncGraphTexture();
                            } else |err| {
                                self.toastErr(@src(), err, "Failed mouse move", .{});
                            }
                        }
                    },
                    .wheel_y => {
                        log.info("Wheel_y: {d}", .{me.action.wheel_y});
                        e.handle(@src(), wd);
                        const factor: f32 = @exp(me.action.wheel_y / 180);
                        if (self.graph_renderer.mouseScroll(factor)) |rerender| {
                            if (rerender) self.syncGraphTexture();
                        } else |err| {
                            self.toastErr(@src(), err, "Failed to zoom graph", .{});
                        }
                    },
                    // always called once per frame
                    .position => {
                        log.info("Position", .{});
                        // because of fps limit, we need to "flush" the render
                        if (self.graph_renderer.shouldRender()) {
                            self.graph_renderer.render() catch {};
                            self.syncGraphTexture();
                        }
                        if (self.graph_renderer.hovered != null) {
                            dvui.cursorSet(.hand);
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
}

fn selectConceptById(self: *Self, id: u128) void {
    if (self.selected) |s| if (s.id.uuid == id) return;
    for (self.concepts) |*concept| {
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
    self.updateGraphTexture();
}

fn unselect(self: *Self) void {
    if (self.selected == null) return;
    self.selected = null;
    self.updateGraphContent();
    self.updateGraphTexture();
}

/// Replace the graph nodes and edges with that of self.selected
fn updateGraphContent(self: *Self) void {
    self.graph_renderer.clear();
    const graph = &self.graph_renderer.graph;
    const arena = self.arena.allocator();

    // Fill graph
    if (self.selected) |concept| {
        self.graph_renderer.highlighted.put(concept.id.uuid, {}) catch |err| {
            return self.toastErr(@src(), err, "Failed to add graph highlight", .{});
        };
        ilm.concept.fillAncestorGraph(self.core, graph, arena, concept) catch |err| {
            return self.toastErr(@src(), err, "Failed to fill graph ({t})", .{err});
        };
    } else {
        ilm.concept.fillFullGraph(self.core, graph, arena, self.concepts) catch |err| {
            return self.toastErr(@src(), err, "Failed to fill graph ({t})", .{err});
        };
    }

    // Render
    self.graph_renderer.layout("neato") catch |err| {
        return self.toastErr(@src(), err, "Failed to layout graph", .{});
    };
    self.graph_renderer.fitToGraph();
    self.graph_renderer.render() catch |err| {
        return self.toastErr(@src(), err, "Failed to render graph", .{});
    };
}

fn syncGraphTexture(self: *Self) void {
    if (self.rendered_width == 0 or self.rendered_height == 0) return;
    self.graph_texture.updateSubRect(self.graph_renderer.buffer.ptr, 0, 0, self.rendered_width, self.rendered_height) catch |err| {
        return self.toastErr(@src(), err, "Failed to update graph texture", .{});
    };
}

/// Compute new layout, render to buffer, and update the texture
fn updateGraphTexture(self: *Self) void {
    if (self.rendered_width == 0 or self.rendered_height == 0) return;
    self.graph_renderer.resize(self.rendered_width, self.rendered_height) catch |err| {
        return self.toastErr(@src(), err, "Failed to resize graph", .{});
    };
    self.graph_renderer.fitToGraph();
    self.graph_renderer.render() catch |err| {
        return self.toastErr(@src(), err, "Failed to render graph", .{});
    };
    self.syncGraphTexture();
}
