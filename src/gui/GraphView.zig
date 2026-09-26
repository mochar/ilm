const std = @import("std");
const dvui = @import("dvui");
const ilm = @import("ilm");
const Core = ilm.Core;
const GraphRenderer = ilm.GraphRenderer;
const Graph = GraphRenderer.Graph;
const Node = GraphRenderer.Node;

const log = std.log.scoped(.graph_view);

const Self = @This();
const SelectFn = *const fn (*Self, u128) void;

var debug_window: bool = false;

renderer: GraphRenderer,
texture: dvui.Texture,
max_width: u32,
max_height: u32,
rendered_width: u32 = 0,
rendered_height: u32 = 0,
on_node_select: ?SelectFn = null,

pub const Options = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    max_width: u32 = 2048,
    max_height: u32 = 2048,
    on_node_select: ?SelectFn = null,
};

pub fn init(opts: Options) !Self {
    var renderer = try GraphRenderer.init(.{
        .gpa = opts.gpa,
        .io = opts.io,
        .graph_options = .{},
        .buffer_stride = opts.max_width,
        .buffer_height = opts.max_height,
    });
    errdefer renderer.deinit();

    const texture = try dvui.Texture.create(@ptrCast(renderer.buffer), .{
        .width = opts.max_width,
        .height = opts.max_height,
        .interpolation = .nearest,
    });

    return .{
        .renderer = renderer,
        .texture = texture,
        .max_width = opts.max_width,
        .max_height = opts.max_height,
        .on_node_select = opts.on_node_select,
    };
}

pub fn deinit(self: *Self) void {
    self.renderer.deinit();
    // self.texture.destroyLater();
}

pub fn graph(self: *Self) *Graph {
    return &self.renderer.graph;
}

pub fn render(self: *Self) !void {
    var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer vbox.deinit();

    var texture_box = dvui.box(@src(), .{}, .{
        .expand = .both,
        .min_size_content = .{ .w = 100, .h = 100 },
    });
    defer texture_box.deinit();

    // Get available width and height and clamp it to max graph dimensions
    const rs = texture_box.data().contentRectScale();
    const target_w = std.math.clamp(@as(u32, @intFromFloat(@max(1.0, rs.r.w))), 1, @max(1, self.max_width));
    const target_h = std.math.clamp(@as(u32, @intFromFloat(@max(1.0, rs.r.h))), 1, @max(1, self.max_height));

    // Update graph renderer and texture if the available space has changed
    if (target_w != self.rendered_width or target_h != self.rendered_height) {
        self.rendered_width = target_w;
        self.rendered_height = target_h;
        try self.update();
    }

    self.handleEvents(texture_box.data(), rs);

    // Render the graph texture. Set uv to only view the rendered part
    // of the buffer.
    if (self.rendered_width > 0 and self.rendered_height > 0) {
        const u_scale = @as(f32, @floatFromInt(self.rendered_width)) / @as(f32, @floatFromInt(self.max_width));
        const v_scale = @as(f32, @floatFromInt(self.rendered_height)) / @as(f32, @floatFromInt(self.max_height));

        try dvui.renderTexture(self.texture, rs, .{
            .uv = .{ .x = 0, .y = 0, .w = u_scale, .h = v_scale },
        });
    }

    if (debug_window) {
        const debug_win = dvui.osWindow(
            @src(),
            .{ .title = "Graph", .size = .{ .w = 500, .h = 300 } },
            .{ .open_flag = &debug_window },
        );
        defer debug_win.deinit();

        const b = dvui.box(@src(), .{}, .{ .background = true, .corners = .{
            .tl = .square,
            .tr = .square,
            .br = .default,
            .bl = .default,
        }, .expand = .both });
        defer b.deinit();

        dvui.structUI(@src(), "state", &self.renderer.state, 3, .{}, .{ .expand = .both });
    }
}

/// React to mouse, touch and key events on the graph.
///
/// Since DVUI exposes all the events that occured within a frame,
/// rerendering the graph immediately will cause frequent rerenders
/// making it slow. Instead the events only update the internal state
/// of the graph renderer (such as mouse position) and then mark it as
/// dirty. DVUI's "position" event is always exposed once per frame,
/// which we then use to check if the graph is dirty, and if so
/// rerender.
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
                        // log.info("Press: {t}", .{me.button});
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
                            _ = self.renderer.mouseDown(x, y, b);
                        }
                    },
                    .release => {
                        // log.info("Release: {t}", .{me.button});
                        if (dvui.captured(wd.id)) {
                            e.handle(@src(), wd);
                            dvui.captureMouse(null, e.num);
                            if (self.renderer.hovered) |*node| {
                                if (self.on_node_select) |on_select| {
                                    const id = node.getId() catch unreachable;
                                    on_select(self, id);
                                }
                            }
                            _ = self.renderer.mouseUp(x, y);
                        }
                    },
                    .motion => {
                        // log.info("Motion", .{});
                        e.handle(@src(), wd);
                        _ = self.renderer.mouseMove(x, y);
                    },
                    .wheel_y => {
                        log.info("Wheel_y: {d}", .{me.action.wheel_y});
                        e.handle(@src(), wd);
                        const factor: f32 = @exp(me.action.wheel_y / 180);
                        _ = self.renderer.mouseScroll(factor);
                    },
                    .position => {
                        // log.info("Position", .{});
                        // This event gets called once per frame at
                        // the end of the frame. We use this to check
                        // if the renderer is dirty, and if so to
                        // render the new graph and sync it to the
                        // texture.
                        if (self.renderer.state.dirty) {
                            self.renderer.render() catch continue;
                            self.syncTexture() catch continue;
                        }
                        if (self.renderer.hovered != null) {
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

/// Compute new layout, render to buffer, and update the texture
pub fn update(self: *Self) !void {
    if (self.rendered_width == 0 or self.rendered_height == 0) return;
    self.renderer.resize(self.rendered_width, self.rendered_height);
    self.renderer.fitToGraph();
    try self.renderer.render();
    try self.syncTexture();
}

fn syncTexture(self: *Self) !void {
    if (self.rendered_width == 0 or self.rendered_height == 0) return;
    self.texture.updateSubRect(self.renderer.buffer.ptr, 0, 0, self.rendered_width, self.rendered_height) catch |err| {
        log.err("Failed to update graph texture: {t}", .{err});
        return err;
    };
}
