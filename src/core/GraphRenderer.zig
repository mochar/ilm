//! Render a Graph to a pixel buffer with a 2D camera viewport.
//!
//! The pixel buffer has a fixed capacity (buffer_stride * buffer_height). The visible
//! viewport is defined by (view_width, view_height). Moving around or zooming the graph
//! simply moves the camera within world space without altering graph layout coordinates.
const std = @import("std");
const c = @import("c");
const graphviz = @import("graphviz");
const Graph = graphviz.Graph;
const Node = graphviz.Node;
const plutovg = @import("plutovg");
const Self = @This();

const log = std.log.scoped(.graph_renderer);

gpa: std.mem.Allocator,
/// For getting time to limit render fps
io: std.Io,
graph: Graph,
padding: f32,
hovered: ?Node = null,
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
};

pub const MouseButton = enum { left, right, middle };

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
        drag: ?struct {
            // start_pos: [2]f32 = .{ 0.0, 0.0 },
            mode: union(enum) {
                pan_camera,
                drag_node: Node,
            },
        } = null,
    } = .{},
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

    const stride = options.buffer_stride;
    const height = options.buffer_height;
    var buffer: []u8 = undefined;
    if (options.buffer) |buf| {
        if (buf.len < stride * height * 4) return error.BufferTooSmol;
        buffer = buf;
    } else {
        buffer = try gpa.alloc(u8, stride * height * 4);
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

    return .{
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

pub fn mouseDown(self: *Self, screen_x: f32, screen_y: f32, button: MouseButton) bool {
    self.state.mouse.last_pos = .{ screen_x, screen_y };
    self.state.mouse.down = button;
    self.state.mouse.drag = null;
    return self.state.dirty;
}

pub fn mouseMove(self: *Self, screen_x: f32, screen_y: f32) bool {
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
    } else if (self.state.mouse.drag) |drag| {
        // We are in the middle of dragging
        switch (drag.mode) {
            .pan_camera => {
                self.pan(screen_x - last_pos[0], screen_y - last_pos[1]);
            },
            .drag_node => {
                return false;
            },
        }
    } else {
        // Mouse button down but not dragging yet -> start dragging
        if (self.getNodeAt(screen_x, screen_y)) |node| {
            self.state.mouse.drag = .{ .mode = .{ .drag_node = node } };
        } else {
            self.state.mouse.drag = .{ .mode = .pan_camera };
        }
        self.state.dirty = true;
    }
    
    return self.state.dirty;
}

pub fn mouseUp(self: *Self, screen_x: f32, screen_y: f32) bool {
    self.state.mouse.last_pos = .{ screen_x, screen_y };
    const was_dragging = self.state.mouse.drag != null;
    self.state.mouse.drag = null;
    self.state.mouse.down = null;

    if (!was_dragging) {
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
    return self.state.dirty;
}

/// Layout graph with aspect ratio set to match current viewport.
pub fn layout(self: *Self, engine: []const u8) !void {
    if (self.view_width > 0 and self.view_height > 0) {
        const target_ratio = @as(f32, @floatFromInt(self.view_height)) / @as(f32, @floatFromInt(self.view_width));
        self.graph.setRatio(target_ratio);
    }
    try self.graph.layout(engine);
    self.state.dirty = true;
}

/// Resize the visible viewport dimensions within buffer bounds, and rerender.
pub fn resize(self: *Self, width: u32, height: u32) void {
    const max_w: u32 = @intCast(self.stride);
    const max_h: u32 = @intCast(self.height);
    self.view_width = @max(1, @min(width, max_w));
    self.view_height = @max(1, @min(height, max_h));
    self.graph.setRatio(@as(f32, @floatFromInt(self.view_height)) / @as(f32, @floatFromInt(self.view_width)));

    self.state.dirty = true;
}

/// Fit camera to current graph's bounding box and center it in the viewport.
pub fn fitToGraph(self: *Self) void {
    const bb = self.graph.boundingBox();
    const gw = bb.width();
    const gh = bb.height();
    const vw = @max(1.0, @as(f32, @floatFromInt(self.view_width)) - self.padding * 2.0);
    const vh = @max(1.0, @as(f32, @floatFromInt(self.view_height)) - self.padding * 2.0);

    self.camera.zoom = @min(vw / gw, vh / gh);
    self.camera.center_x = bb.centerX();
    self.camera.center_y = bb.centerY();

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
    const old_zoom = self.camera.zoom;
    const new_zoom = std.math.clamp(old_zoom * factor, 0.001, 1000.0);
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

pub fn shouldRender(self: *const Self) bool {
    const now_ns = std.Io.Clock.real.now(self.io).nanoseconds;
    return self.state.dirty and (now_ns - self.state.last_render_ns) > FRAMES_NS;
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

    // Draw edge splines and arrowheads
    var maybe_node = c.agfstnode(graph.g);
    while (maybe_node) |node| : (maybe_node = c.agnxtnode(graph.g, node)) {
        var maybe_edge = c.agfstout(graph.g, node);
        while (maybe_edge) |edge| : (maybe_edge = c.agnxtout(graph.g, edge)) {
            try drawEdgeSpline(canvas, edge);
        }
    }

    // Draw nodes and their labels
    maybe_node = c.agfstnode(graph.g);
    while (maybe_node) |node| : (maybe_node = c.agnxtnode(graph.g, node)) {
        const node_id = try Node.getNodeId(node);
        const node_info = graphviz.nodeInfo(node);
        const cx: f32 = @floatCast(node_info.coord.x);
        const cy: f32 = @floatCast(node_info.coord.y);
        const h: f32 = @floatCast(node_info.height * 72.0 * 0.5);

        // Draw node body
        canvas.circle(cx, cy, h / 2);
        if (self.highlighted.contains(node_id)) {
            canvas.setRGBA(0.8, 0.85, 1.0, 1.0);
        } else if (self.hovered != null and self.hovered.?.cnode == node) {
            canvas.setRGBA(0.3, 0.3, 0.0, 1.0);
        } else {
            canvas.setRGBA(0.0, 0.0, 0.0, 0.0);
        }
        canvas.fillPreserve();

        // Draw node border
        canvas.setRGBA(0.8, 0.85, 1.0, 1.0);
        canvas.setLineWidth(1.5);
        canvas.stroke();

        // Label
        const label: []const u8 = std.mem.span(node_info.label.*.text);
        const font_size: f32 = 12.0;

        if (plutovg.plutovg_font != null) {
            canvas.save();

            // Translate to node center and flip Y back to right-side up
            canvas.translate(cx, cy - h / 3);
            canvas.scale(1.0, -1.0);

            canvas.drawText(label, font_size);
            canvas.restore();
        }
    }
}

/// Render graphviz edge's Bezier splines and arrowheads
fn drawEdgeSpline(canvas: *const plutovg.Canvas, edge: *c.struct_Agedge_s) !void {
    // Each bezier structure has a list field pointing to an array containing
    // the control points and a size field giving the number of points in list,
    // which will always have the form (3 ∗ n + 1).
    //
    // In addition, there are fields for specifying arrowheads:
    //
    // If bp points to a bezier structure and the bp->sflag field is true, there
    // should be an arrowhead attached to the beginning of the bezier.
    //
    // The field bp->sp gives the point where the nominal tip of the arrowhead
    // would touch the tail node. (If there is no arrowhead, bp->list[0] will
    // touch the node.) Thus, the length and direction of the arrowhead is
    // determined by the vector going from bp->list[0] to bp->sp.
    //
    // The actual shape and width of the arrowhead is determined by the
    // arrowtail and arrowsize attributes.
    //
    // Analogously, an arrowhead at the head node is specified by bp->eflag and
    // the vector from bp->list[bp->size-1] to bp->ep.
    const edge_info = graphviz.edgeInfo(edge);
    const splines = edge_info.*.spl.*;

    if (splines.size == 0) return;

    for (0..@intCast(splines.size)) |spline_i| {
        const bezier = splines.list[spline_i];
        const num_ctrl_points: usize = @intCast(bezier.size); // always (3 * n + 1)
        const ctrl_points = bezier.list;

        canvas.setRGBA(0.7, 0.75, 0.85, 0.9);
        canvas.setLineWidth(2.0);
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
        canvas.stroke();

        // Draw end arrowhead
        if (bezier.eflag == 1) {
            canvas.setRGBA(0.7, 0.75, 0.85, 0.9);
            drawArrow(
                canvas,
                @floatCast(ctrl_points[num_ctrl_points - 1].x),
                @floatCast(ctrl_points[num_ctrl_points - 1].y),
                @floatCast(bezier.ep.x),
                @floatCast(bezier.ep.y),
                8.0,
            );
        }

        // Draw start arrowhead (if bi-directional)
        if (bezier.sflag == 1) {
            canvas.setRGBA(0.7, 0.75, 0.85, 0.9);
            drawArrow(
                canvas,
                @floatCast(ctrl_points[0].x),
                @floatCast(ctrl_points[0].y),
                @floatCast(bezier.sp.x),
                @floatCast(bezier.sp.y),
                8.0,
            );
        }
    }
}

/// Draw a solid triangular arrowhead
fn drawArrow(canvas: *const plutovg.Canvas, from_x: f32, from_y: f32, to_x: f32, to_y: f32, size: f32) void {
    // TODO: The actual shape and width of the arrowhead is determined by the
    // arrowtail and arrowsize attributes
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
    canvas.fill();
}

test "Graph buffer rendering, camera panning, zooming, and hit testing" {
    const allocator = std.testing.allocator;

    var renderer = try init(.{
        .gpa = allocator,
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
