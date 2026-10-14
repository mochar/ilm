//! Render a Graph to a pixel buffer with a 2D camera viewport.
//!
//! The pixel buffer has a fixed capacity (buffer_stride * buffer_height). The visible
//! viewport is defined by (view_width, view_height). Moving around or zooming the graph
//! simply moves the camera within world space without altering graph layout coordinates.
const std = @import("std");
const c = @import("c");
const graphviz = @import("graphviz");
pub const Graph = graphviz.Graph;
pub const Node = graphviz.Node;
const plutovg = @import("plutovg");
const Self = @This();

const log = std.log.scoped(.graph_renderer);

gpa: std.mem.Allocator,
/// For getting time to limit render fps
io: std.Io,
graph: Graph,
padding: f32,
hovered: ?Node = null,
// highlighted: std.AutoHashMap(u128, graphviz.Node),
highlighted: std.AutoHashMap(u128, void),
state: State = .{},
canvas: plutovg.Canvas,
/// ARGB32 pixel buffer.
buffer: []u8,
/// Buffer stride in pixels
stride: usize,
height: usize,
/// Visible viewport width in pixels (<= stride)
view_width: u32,
/// Visible viewport height in pixels (<= height)
view_height: u32,
/// Camera in world coordinates
camera: Camera,
/// If true, buffer allocation is managed internally.
managed: bool,

const TARGET_FPS = 60;
const FRAMES_NS = 1_000_000_000 / TARGET_FPS;

const Camera = struct {
    /// Center of the camera in world coordinates
    center_x: f32 = 0.0,
    center_y: f32 = 0.0,
    /// Zoom scale factor (1.0 = 100%)
    zoom: f32 = 1.0,
    // Dynamic zoom limits relative to graph bounding box and viewport
    max_zoom: f32 = 10.0,
    min_zoom: f32 = 0.1,
};

pub const MouseButton = enum { left, right, middle };

const Drag = struct {
    start_pos: [2]f32 = .{ 0.0, 0.0 },
    mode: union(enum) {
        pan_camera,
        drag_node: Node,
        assign_parent: struct {
            child: Node,
            parent: ?Node = null,
        },
    },
};

const State = struct {
    dirty: bool = false,
    last_render_ns: i96 = 0,
    mouse: struct {
        /// Which button is currently pressed
        down: ?MouseButton = null,
        last_pos: [2]f32 = .{ 0.0, 0.0 },
        last_click: ?struct {
            pos: [2]f32,
            time_ns: i96,
        } = null,
        drag: ?Drag = null,
    } = .{},
    pinching: bool = false,
    animateTarget: ?struct {
        start_time: std.Io.Timestamp,
        duration: std.Io.Duration,
        x: f32,
        y: f32,
        zoom: f32,
    } = null,
};

pub const Options = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    graph_options: Graph.Options = .{},
    padding: f32 = 20.0,
    /// Viewport width in pixels. If 0, uses buffer_stride.
    view_width: u32 = 0,
    /// Viewport height in pixels. If 0, uses buffer_height.
    view_height: u32 = 0,
    /// Buffer stride in pixels
    buffer_stride: u32,
    /// Number of rows in the buffer
    buffer_height: u32,
    /// ARGB32 pixel buffer. If null, buffer allocation is managed internally.
    buffer: ?[]u8 = null,
    camera: Camera = .{},
};

pub fn init(options: Options) !Self {
    const gpa = options.gpa;

    var graph = try Graph.init(gpa, options.graph_options);
    errdefer graph.deinit();

    const stride = options.buffer_stride;
    const height = options.buffer_height;
    var buffer: []u8 = undefined;
    if (options.buffer) |buf| {
        if (buf.len < stride * height * 4) return error.BufferTooSmol;
        buffer = buf;
    } else {
        buffer = try gpa.alloc(u8, stride * height * 4);
        errdefer gpa.free(buffer);
        @memset(buffer, 0);
    }

    const view_w: u32 = if (options.view_width > 0)
        @min(options.view_width, @as(u32, @intCast(stride)))
    else
        @intCast(stride);

    const view_h: u32 = if (options.view_height > 0)
        @min(options.view_height, @as(u32, @intCast(height)))
    else
        @intCast(height);

    if (view_w > 0 and view_h > 0) {
        graph.setRatio(@as(f32, @floatFromInt(view_h)) / @as(f32, @floatFromInt(view_w)));
    }

    const canvas = try plutovg.Canvas.initForData(buffer.ptr, view_w, view_h, stride);
    errdefer canvas.deinit();

    var self: Self = .{
        .gpa = gpa,
        .io = options.io,
        .graph = graph,
        .padding = options.padding,
        .highlighted = .init(gpa),
        .buffer = buffer,
        .stride = stride,
        .height = height,
        .view_width = view_w,
        .view_height = view_h,
        .canvas = canvas,
        .camera = options.camera,
        .managed = options.buffer == null,
    };
    self.updateZoomLimits();
    return self;
}

pub fn deinit(self: *Self) void {
    self.highlighted.deinit();
    self.graph.deinit();
    if (self.managed) {
        self.gpa.free(self.buffer);
    }
    self.canvas.deinit();
}

pub fn clear(self: *Self) void {
    self.graph.clear();
    self.highlighted.clearRetainingCapacity();
    self.hovered = null;
    self.state = .{};
}

pub fn assigningToParent(self: *const Self) ?struct { child: Node, parent: Node } {
    const drag = self.state.mouse.drag;
    if (drag == null) return null;
    if (drag.?.mode != .assign_parent) return null;
    const assign = drag.?.mode.assign_parent;
    if (assign.parent == null) return null;
    return .{ .child = assign.child, .parent = assign.parent.? };
}

pub fn mouseDown(self: *Self, screen_x: f32, screen_y: f32, button: MouseButton) bool {
    self.state.mouse.last_pos = .{ screen_x, screen_y };
    self.state.mouse.drag = null;
    self.state.animateTarget = null;
    if (!self.state.pinching) self.state.mouse.down = button;
    return self.state.dirty;
}

pub fn mouseMove(self: *Self, screen_x: f32, screen_y: f32) bool {
    if (self.state.pinching) return false;
    
    const last_pos = self.state.mouse.last_pos;
    defer self.state.mouse.last_pos = .{ screen_x, screen_y };

    if (self.state.mouse.down == null) {
        // No mouse button down, so we react on hover events.
        if (self.getNodeAt(screen_x, screen_y)) |node| {
            if (self.hovered == null or self.hovered.?.cnode != node.cnode) {
                self.hovered = node;
                self.state.dirty = true;
            }
        } else if (self.hovered != null) {
            self.hovered = null;
            self.state.dirty = true;
        }
    } else if (self.state.mouse.drag) |*drag| {
        // We are in the middle of dragging
        switch (drag.mode) {
            .pan_camera => {
                self.pan(screen_x - last_pos[0], screen_y - last_pos[1]);
            },
            .drag_node => {
                return false;
            },
            .assign_parent => |*assign| {
                blk: {
                    if (self.getNodeAt(screen_x, screen_y)) |node| {
                        if (assign.child.cnode != node.cnode) {
                            assign.parent = node;
                            break :blk;
                        }
                    }
                    assign.parent = null;
                }

                self.state.dirty = true;
                return true;
            },
        }
    } else {
        // Mouse button down but not dragging yet -> start dragging
        var drag: Drag = undefined;
        drag.start_pos = .{ screen_x, screen_y };
        if (self.getNodeAt(screen_x, screen_y)) |node| {
            switch (self.state.mouse.down.?) {
                .left => drag = .{ .mode = .{ .assign_parent = .{ .child = node } } },
                else => drag = .{ .mode = .{ .drag_node = node } },
            }
        } else {
            drag = .{ .mode = .pan_camera };
        }
        self.state.mouse.drag = drag;
        self.state.dirty = true;
    }

    return self.state.dirty;
}

pub fn mouseUp(self: *Self, screen_x: f32, screen_y: f32) bool {
    // if (self.state.pinching) return false;
    
    self.state.mouse.last_pos = .{ screen_x, screen_y };
    const was_dragging = self.state.mouse.drag != null;
    self.state.mouse.drag = null;
    self.state.mouse.down = null;

    if (was_dragging) {
        self.state.dirty = true;
    } else {
        // Register mouse click.
        const now_ns = std.Io.Clock.real.now(self.io).nanoseconds;

        if (self.state.mouse.last_click) |last_click| {
            // Check if its a double click.
            const dt_ns = now_ns - last_click.time_ns;
            const dx = screen_x - last_click.pos[0];
            const dy = screen_y - last_click.pos[1];
            if (dt_ns <= 400 * std.time.ns_per_ms and (dx * dx + dy * dy <= 25.0)) {
                self.state.mouse.last_click = null;
                self.fitToGraph();
                return true;
            }
        }
        self.state.mouse.last_click = .{
            .pos = .{ screen_x, screen_y },
            .time_ns = now_ns,
        };
    }

    return self.state.dirty;
}

pub fn mouseScroll(self: *Self, factor: f32) bool {
    self.zoomBy(factor, self.state.mouse.last_pos[0], self.state.mouse.last_pos[1]);
    self.state.animateTarget = null;
    return self.state.dirty;
}

pub fn pinchBegin(self: *Self) bool {
    // self.mouseUp(screen_x: f32, screen_y: f32)
    self.state.pinching = true;
    self.state.dirty = true;
    return true;
}

pub fn pinchEnd(self: *Self) bool {
    self.state.pinching = false;
    self.state.dirty = true;
    return true;
}

pub fn pinchUpdate(self: *Self, scale: f32) bool {
    return self.mouseScroll(scale);
}

/// Layout graph with aspect ratio set to match current viewport.
pub fn layout(self: *Self, engine: []const u8) !void {
    if (self.view_width > 0 and self.view_height > 0) {
        const target_ratio = @as(f32, @floatFromInt(self.view_height)) / @as(f32, @floatFromInt(self.view_width));
        self.graph.setRatio(target_ratio);
    }
    try self.graph.layout(engine);
    self.updateZoomLimits();
    self.state.dirty = true;
}

/// Resize the visible viewport dimensions within buffer bounds, and rerender.
pub fn resize(self: *Self, width: u32, height: u32) void {
    const max_w: u32 = @intCast(self.stride);
    const max_h: u32 = @intCast(self.height);
    self.view_width = @max(1, @min(width, max_w));
    self.view_height = @max(1, @min(height, max_h));
    self.graph.setRatio(@as(f32, @floatFromInt(self.view_height)) / @as(f32, @floatFromInt(self.view_width)));
    self.updateZoomLimits();

    self.state.dirty = true;
}

fn graphFittedCamera(self: *const Self) Camera {
    const bb = self.graph.boundingBox();
    const gw = bb.width();
    const gh = bb.height();
    const vw = @max(1.0, @as(f32, @floatFromInt(self.view_width)) - self.padding * 2.0);
    const vh = @max(1.0, @as(f32, @floatFromInt(self.view_height)) - self.padding * 2.0);
    const fit_zoom = @min(vw / gw, vh / gh);
    return .{
        .zoom = fit_zoom,
        .center_x = bb.centerX(),
        .center_y = bb.centerY(),
        .min_zoom = @min(0.1, fit_zoom * 0.5),
        .max_zoom = @max(10.0, fit_zoom * 15.0),
    };
}

/// Update camera min_zoom and max_zoom relative to current graph bounding box and viewport.
pub fn updateZoomLimits(self: *Self) void {
    const cam = self.graphFittedCamera();
    self.camera.min_zoom = cam.min_zoom;
    self.camera.max_zoom = cam.max_zoom;
}

/// Fit camera to current graph's bounding box and center it in the viewport.
pub fn fitToGraph(self: *Self) void {
    const cam = self.graphFittedCamera();
    self.camera.zoom = cam.zoom;
    self.camera.center_x = cam.center_x;
    self.camera.center_y = cam.center_y;
    self.camera.min_zoom = cam.min_zoom;
    self.camera.max_zoom = cam.max_zoom;
    self.state.dirty = true;
}

/// Move camera by a delta in screen pixels (e.g. from mouse drag).
pub fn pan(self: *Self, delta_screen_x: f32, delta_screen_y: f32) void {
    self.camera.center_x -= delta_screen_x / self.camera.zoom;
    self.camera.center_y += delta_screen_y / self.camera.zoom;
    self.state.dirty = true;
}

/// Zoom camera by a multiplication factor, optionally centered at a screen focus coordinate.
pub fn zoomBy(self: *Self, factor: f32, screen_focus_x: ?f32, screen_focus_y: ?f32) void {
    self.updateZoomLimits();
    const old_zoom = self.camera.zoom;
    const new_zoom = std.math.clamp(old_zoom * factor, self.camera.min_zoom, self.camera.max_zoom);
    if (screen_focus_x != null and screen_focus_y != null) {
        const focus_x = screen_focus_x.?;
        const focus_y = screen_focus_y.?;
        const cur_focus = self.screenToWorld(focus_x, focus_y);
        self.camera.zoom = new_zoom;
        const vw: f32 = @floatFromInt(self.view_width);
        const vh: f32 = @floatFromInt(self.view_height);
        self.camera.center_x = cur_focus.x - (focus_x - vw / 2.0) / new_zoom;
        self.camera.center_y = cur_focus.y + (focus_y - vh / 2.0) / new_zoom;
    } else {
        self.camera.zoom = new_zoom;
    }
    self.state.dirty = true;
}

/// Convert screen pixel coordinates (origin at top-left of viewport) to world coordinates.
pub fn screenToWorld(self: *const Self, screen_x: f32, screen_y: f32) struct { x: f32, y: f32 } {
    const vw: f32 = @floatFromInt(self.view_width);
    const vh: f32 = @floatFromInt(self.view_height);
    return .{
        .x = self.camera.center_x + (screen_x - vw / 2.0) / self.camera.zoom,
        .y = self.camera.center_y - (screen_y - vh / 2.0) / self.camera.zoom,
    };
}

/// Convert world coordinates to screen pixel coordinates.
pub fn worldToScreen(self: *const Self, world_x: f32, world_y: f32) struct { x: f32, y: f32 } {
    const vw: f32 = @floatFromInt(self.view_width);
    const vh: f32 = @floatFromInt(self.view_height);
    return .{
        .x = (world_x - self.camera.center_x) * self.camera.zoom + vw / 2.0,
        .y = (self.camera.center_y - world_y) * self.camera.zoom + vh / 2.0,
    };
}

/// Find node under the given screen coordinates, if any.
pub fn getNodeAt(self: *const Self, screen_x: f32, screen_y: f32) ?Node {
    const world_pt = self.screenToWorld(screen_x, screen_y);
    return self.graph.getNodeAt(world_pt.x, world_pt.y);
}

pub fn animateToNode(self: *Self, node_id: u128, duration: std.Io.Duration) !void {
    const node = self.graph.getNode(node_id) orelse return error.NodeNotFound;
    const pos = node.getPosF32();
    self.state.animateTarget = .{
        .start_time = .now(self.io, .real),
        .duration = duration,
        .x = pos[0],
        .y = pos[1],
        .zoom = 3.0,
    };
}

pub fn animateFitToGraph(self: *Self, duration: std.Io.Duration) !void {
    self.updateZoomLimits();
    const cam = self.graphFittedCamera();
    self.state.animateTarget = .{
        .start_time = .now(self.io, .real),
        .duration = duration,
        .x = cam.center_x,
        .y = cam.center_y,
        .zoom = cam.zoom,
    };
}

/// Check if the graph requires a rererender. Conditions:
///   - Frame time
///   - State is dirty
///   - Animating
pub fn shouldRender(self: *const Self) bool {
    // const now_ns = std.Io.Clock.real.now(self.io).nanoseconds;
    // if ((now_ns - self.state.last_render_ns) < FRAMES_NS) return false;
    if (self.state.dirty) return true;
    if (self.state.animateTarget != null) return true;
    return false;
}

/// Render the graph if required, see shouldRender.
/// Returns whether we decided to render or not.
pub fn tryRender(self: *Self) !bool {
    if (self.shouldRender()) {
        try self.render();
        return true;
    }
    return false;
}

/// Render the graph in the pixel buffer using current camera transformation.
pub fn render(self: *Self) !void {
    defer {
        self.state.last_render_ns = std.Io.Clock.real.now(self.io).nanoseconds;
        self.state.dirty = false;
    }

    const graph = &self.graph;
    const canvas = &self.canvas;
    const render_w = self.view_width;
    const render_h = self.view_height;

    // Update camera if animating
    if (self.state.animateTarget) |target| {
        const sinceStart = target.start_time.untilNow(self.io, .real);
        const div = @as(f32, @floatFromInt(sinceStart.toMilliseconds())) / @as(f32, @floatFromInt(target.duration.toMilliseconds()));
        const progress = @min(1.0, div);
        self.camera.center_x = target.x - (1 - progress) * (target.x - self.camera.center_x);
        self.camera.center_y = target.y - (1 - progress) * (target.y - self.camera.center_y);
        self.camera.zoom = target.zoom - (1 - progress) * (target.zoom - self.camera.zoom);
        if (progress == 1.0) self.state.animateTarget = null;
    }

    // Clear background (dark theme background)
    canvas.save();
    defer canvas.restore();

    canvas.setRGBA(0.12, 0.12, 0.15, 1.0);
    canvas.setOperator(.src);
    canvas.paint();
    canvas.setOperator(.src_over);

    // Apply camera transformation:
    // Viewport center -> zoom & flip Y (Graphviz Y-up -> PlutoVG Y-down) -> camera center
    const vw: f32 = @floatFromInt(render_w);
    const vh: f32 = @floatFromInt(render_h);
    canvas.translate(vw / 2.0, vh / 2.0);
    canvas.scale(self.camera.zoom, -self.camera.zoom);
    canvas.translate(-self.camera.center_x, -self.camera.center_y);

    // Visible viewport in world coordinates for culling
    const half_vw = (vw / 2.0) / self.camera.zoom;
    const half_vh = (vh / 2.0) / self.camera.zoom;
    const view_min_x = self.camera.center_x - half_vw;
    const view_max_x = self.camera.center_x + half_vw;
    const view_min_y = self.camera.center_y - half_vh;
    const view_max_y = self.camera.center_y + half_vh;

    // Draw edge splines (batched in a single stroke)
    var has_splines = false;
    var maybe_node = c.agfstnode(graph.g);
    while (maybe_node) |node| : (maybe_node = c.agnxtnode(graph.g, node)) {
        var maybe_edge = c.agfstout(graph.g, node);
        while (maybe_edge) |edge| : (maybe_edge = c.agnxtout(graph.g, edge)) {
            const edge_info = graphviz.edgeInfo(edge);
            const splines = edge_info.*.spl.*;
            if (splines.size == 0) continue;

            for (0..@intCast(splines.size)) |spline_i| {
                const bezier = splines.list[spline_i];
                const num_ctrl_points: usize = @intCast(bezier.size);
                const ctrl_points = bezier.list;

                if (!isBezierVisible(ctrl_points, num_ctrl_points, view_min_x, view_max_x, view_min_y, view_max_y)) continue;

                canvas.moveTo(@floatCast(ctrl_points[0].x), @floatCast(ctrl_points[0].y));
                var i: usize = 1;
                while (i + 2 < num_ctrl_points) : (i += 3) {
                    canvas.cubicTo(
                        @floatCast(ctrl_points[i].x),
                        @floatCast(ctrl_points[i].y),
                        @floatCast(ctrl_points[i + 1].x),
                        @floatCast(ctrl_points[i + 1].y),
                        @floatCast(ctrl_points[i + 2].x),
                        @floatCast(ctrl_points[i + 2].y),
                    );
                }
                has_splines = true;
            }
        }
    }
    if (has_splines) {
        canvas.setRGBA(0.7, 0.75, 0.85, 0.9);
        canvas.setLineWidth(2.0);
        canvas.stroke();
    }

    // Draw edge arrowheads (batched in a single fill)
    var has_arrows = false;
    maybe_node = c.agfstnode(graph.g);
    while (maybe_node) |node| : (maybe_node = c.agnxtnode(graph.g, node)) {
        var maybe_edge = c.agfstout(graph.g, node);
        while (maybe_edge) |edge| : (maybe_edge = c.agnxtout(graph.g, edge)) {
            const edge_info = graphviz.edgeInfo(edge);
            const splines = edge_info.*.spl.*;
            if (splines.size == 0) continue;

            for (0..@intCast(splines.size)) |spline_i| {
                const bezier = splines.list[spline_i];
                const num_ctrl_points: usize = @intCast(bezier.size);
                const ctrl_points = bezier.list;

                if (!isBezierVisible(ctrl_points, num_ctrl_points, view_min_x, view_max_x, view_min_y, view_max_y)) continue;

                // End arrowhead
                if (bezier.eflag == 1) {
                    appendArrow(
                        canvas,
                        @floatCast(ctrl_points[num_ctrl_points - 1].x),
                        @floatCast(ctrl_points[num_ctrl_points - 1].y),
                        @floatCast(bezier.ep.x),
                        @floatCast(bezier.ep.y),
                        8.0,
                    );
                    has_arrows = true;
                }

                // Start arrowhead (if bi-directional)
                if (bezier.sflag == 1) {
                    appendArrow(
                        canvas,
                        @floatCast(ctrl_points[0].x),
                        @floatCast(ctrl_points[0].y),
                        @floatCast(bezier.sp.x),
                        @floatCast(bezier.sp.y),
                        8.0,
                    );
                    has_arrows = true;
                }
            }
        }
    }
    if (has_arrows) {
        canvas.setRGBA(0.7, 0.75, 0.85, 0.9);
        canvas.fill();
    }

    // Draw nodes and their labels
    {
        const assign = self.assigningToParent();
        const has_highlighted = self.highlighted.count() > 0;
        const font_size: f32 = 12.0;
        const render_labels = (font_size * self.camera.zoom >= 5.0) and (plutovg.plutovg_font != null);

        // 1. Fill special node bodies (highlighted, hovered, assigned parent)
        if (has_highlighted or self.hovered != null or assign != null) {
            maybe_node = c.agfstnode(graph.g);
            while (maybe_node) |node| : (maybe_node = c.agnxtnode(graph.g, node)) {
                const node_info = graphviz.nodeInfo(node);
                const cx: f32 = @floatCast(node_info.coord.x);
                const cy: f32 = @floatCast(node_info.coord.y);
                const h: f32 = @floatCast(node_info.height * 72.0 * 0.5);
                const radius = h / 2.0;
                const margin = @max(radius, 40.0);

                if (cx + margin < view_min_x or cx - margin > view_max_x or
                    cy + margin < view_min_y or cy - margin > view_max_y)
                {
                    continue;
                }

                const is_highlighted = if (has_highlighted) blk: {
                    const node_id = Node.getNodeId(node) catch break :blk false;
                    break :blk self.highlighted.contains(node_id);
                } else false;

                if (is_highlighted) {
                    canvas.circle(cx, cy, radius);
                    canvas.setRGBA(0.8, 0.85, 1.0, 1.0);
                    canvas.fill();
                } else if (self.hovered != null and self.hovered.?.cnode == node) {
                    canvas.circle(cx, cy, radius);
                    canvas.setRGBA(0.3, 0.3, 0.0, 1.0);
                    canvas.fill();
                } else if (assign != null and assign.?.parent.cnode == node) {
                    canvas.circle(cx, cy, radius);
                    canvas.setRGBA(0.0, 0.8, 0.3, 1.0);
                    canvas.fill();
                }
            }
        }

        // 2. Stroke all visible node borders in one single pass
        var has_borders = false;
        maybe_node = c.agfstnode(graph.g);
        while (maybe_node) |node| : (maybe_node = c.agnxtnode(graph.g, node)) {
            const node_info = graphviz.nodeInfo(node);
            const cx: f32 = @floatCast(node_info.coord.x);
            const cy: f32 = @floatCast(node_info.coord.y);
            const h: f32 = @floatCast(node_info.height * 72.0 * 0.5);
            const radius = h / 2.0;
            const margin = @max(radius, 40.0);

            if (cx + margin < view_min_x or cx - margin > view_max_x or
                cy + margin < view_min_y or cy - margin > view_max_y)
            {
                continue;
            }

            canvas.circle(cx, cy, radius);
            has_borders = true;
        }

        if (has_borders) {
            canvas.setRGBA(0.8, 0.85, 1.0, 1.0);
            canvas.setLineWidth(1.5);
            canvas.stroke();
        }

        // 3. Draw labels with LOD check
        if (render_labels) {
            maybe_node = c.agfstnode(graph.g);
            while (maybe_node) |node| : (maybe_node = c.agnxtnode(graph.g, node)) {
                const node_info = graphviz.nodeInfo(node);
                const cx: f32 = @floatCast(node_info.coord.x);
                const cy: f32 = @floatCast(node_info.coord.y);
                const h: f32 = @floatCast(node_info.height * 72.0 * 0.5);
                const radius = h / 2.0;
                const margin = @max(radius, 40.0);

                if (cx + margin < view_min_x or cx - margin > view_max_x or
                    cy + margin < view_min_y or cy - margin > view_max_y)
                {
                    continue;
                }

                const label: []const u8 = std.mem.span(node_info.label.*.text);
                canvas.save();
                canvas.setRGBA(0.8, 0.85, 1.0, 1.0);
                canvas.translate(cx, cy - h / 3.0);
                canvas.scale(1.0, -1.0);
                canvas.drawText(label, font_size);
                canvas.restore();
            }
        }
    }

    // Draw arrow if assigning parent
    if (self.state.mouse.drag) |drag| {
        switch (drag.mode) {
            .assign_parent => |*assign| {
                const node_pos = assign.child.getPosF32();
                const mouse_screen = self.state.mouse.last_pos;
                const mouse_pos = self.screenToWorld(mouse_screen[0], mouse_screen[1]);
                canvas.setRGBA(0.7, 0.75, 0.85, 0.9);
                canvas.setLineWidth(2.0);
                drawArrow(canvas, mouse_pos.x, mouse_pos.y, node_pos[0], node_pos[1], 8.0);
                canvas.moveTo(node_pos[0], node_pos[1]);
                canvas.lineTo(mouse_pos.x, mouse_pos.y);
                canvas.stroke();
            },
            else => {},
        }
    }
}

fn isBezierVisible(ctrl_points: [*c]c.pointf, num_ctrl_points: usize, min_x: f32, max_x: f32, min_y: f32, max_y: f32) bool {
    const margin: f32 = 10.0;
    var all_left = true;
    var all_right = true;
    var all_below = true;
    var all_above = true;
    for (0..num_ctrl_points) |i| {
        const x: f32 = @floatCast(ctrl_points[i].x);
        const y: f32 = @floatCast(ctrl_points[i].y);
        if (x >= min_x - margin) all_left = false;
        if (x <= max_x + margin) all_right = false;
        if (y >= min_y - margin) all_below = false;
        if (y <= max_y + margin) all_above = false;
    }
    return !(all_left or all_right or all_below or all_above);
}

/// Append a solid triangular arrowhead to the canvas path
fn appendArrow(canvas: *const plutovg.Canvas, from_x: f32, from_y: f32, to_x: f32, to_y: f32, size: f32) void {
    var dx = to_x - from_x;
    var dy = to_y - from_y;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 1e-4) return;
    dx /= len;
    dy /= len;

    const px = -dy;
    const py = dx;

    const base_x = to_x - dx * size;
    const base_y = to_y - dy * size;
    const half_w = size * 0.4;

    canvas.moveTo(to_x, to_y);
    canvas.lineTo(base_x + px * half_w, base_y + py * half_w);
    canvas.lineTo(base_x - px * half_w, base_y - py * half_w);
    canvas.closePath();
}

/// Draw a solid triangular arrowhead
fn drawArrow(canvas: *const plutovg.Canvas, from_x: f32, from_y: f32, to_x: f32, to_y: f32, size: f32) void {
    appendArrow(canvas, from_x, from_y, to_x, to_y, size);
    canvas.fill();
}

test "Graph buffer rendering, camera panning, zooming, and hit testing" {
    const allocator = std.testing.allocator;

    var renderer = try init(.{
        .gpa = allocator,
        .io = std.testing.io,
        .view_width = 400,
        .view_height = 300,
        .buffer_stride = 512,
        .buffer_height = 512,
    });
    defer renderer.deinit();

    try renderer.graph.addNode(1, "Node A");
    try renderer.graph.addNode(2, "Node B");
    try renderer.graph.addEdge(1, 2);

    try renderer.layout("dot");
    renderer.fitToGraph();
    try renderer.render();

    // Verify coordinate conversion
    const bb = renderer.graph.boundingBox();
    const screen_center = renderer.worldToScreen(bb.centerX(), bb.centerY());
    try std.testing.expectApproxEqAbs(@as(f32, 200.0), screen_center.x, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 150.0), screen_center.y, 1.0);

    // Pan camera by 50px right
    const old_cam_x = renderer.camera.center_x;
    try renderer.pan(50, 0);
    try std.testing.expect(renderer.camera.center_x < old_cam_x);

    // Zoom camera
    const old_zoom = renderer.camera.zoom;
    try renderer.zoomBy(1.5, 200, 150);
    try std.testing.expectApproxEqAbs(old_zoom * 1.5, renderer.camera.zoom, 0.001);

    // Resize viewport
    try renderer.resize(450, 350);
    try std.testing.expectEqual(@as(u32, 450), renderer.view_width);
    try std.testing.expectEqual(@as(u32, 350), renderer.view_height);
}

test "Dynamic zoom limits for large graph" {
    const allocator = std.testing.allocator;

    var renderer = try init(.{
        .gpa = allocator,
        .io = std.testing.io,
        .view_width = 400,
        .view_height = 300,
        .buffer_stride = 512,
        .buffer_height = 512,
    });
    defer renderer.deinit();

    try renderer.graph.addNode(1, "Node A");
    try renderer.graph.addNode(2, "Node B");
    try renderer.graph.addEdge(1, 2);

    try renderer.layout("dot");

    const cam = renderer.graphFittedCamera();
    try std.testing.expect(renderer.camera.min_zoom < cam.zoom);

    // Zooming out all the way reaches min_zoom which is strictly smaller than fitted zoom
    renderer.zoomBy(0.001, null, null);
    try std.testing.expect(renderer.camera.zoom < cam.zoom);
    try std.testing.expectEqual(renderer.camera.min_zoom, renderer.camera.zoom);
}
