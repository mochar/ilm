//! Wrapper for the Graphviz library
const std = @import("std");
const c = @import("c");
const Graph = @This();

/// Resolution of graph in pixels per inch. Explanation:
/// https://stackoverflow.com/a/20536144
/// No point in making this variable.
const GRAPHVIZ_DPI: f32 = 100.0;
const GRAPHVIZ_DPI_STR = "100.0";

/// Allocates when building the graph and resets when cleared.
arena: std.heap.ArenaAllocator,
gvc: *c.GVC_t,
g: *c.Agraph_t,
width: u32,
height: u32,
has_layout: bool = false,

pub const GraphOptions = struct {
    width: ?u32 = null,
    height: ?u32 = null,
};

pub const BoundingBox = struct {
    llx: f32,
    lly: f32,
    urx: f32,
    ury: f32,

    pub fn width(self: BoundingBox) f32 {
        return @max(1.0, self.urx - self.llx);
    }

    pub fn height(self: BoundingBox) f32 {
        return @max(1.0, self.ury - self.lly);
    }

    pub fn centerX(self: BoundingBox) f32 {
        return (self.llx + self.urx) / 2.0;
    }

    pub fn centerY(self: BoundingBox) f32 {
        return (self.lly + self.ury) / 2.0;
    }
};

pub fn init(allocator: std.mem.Allocator, options: GraphOptions) !Graph {
    const g = agopen(@constCast("graph"), Agdirected, null) orelse return error.OpenFailed;
    _ = c.agsafeset(g, @constCast("bgcolor"), @constCast("transparent"), @constCast(""));
    _ = c.agsafeset(g, @constCast("margin"), @constCast("0.0"), @constCast(""));
    _ = c.agsafeset(g, @constCast("pad"), @constCast("0.0"), @constCast(""));
    _ = c.agsafeset(g, @constCast("dpi"), @constCast(GRAPHVIZ_DPI_STR), @constCast(""));

    var graph: Graph = .{
        .arena = .init(allocator),
        .gvc = c.gvContext() orelse return error.GVCFailed,
        .g = g,
        .width = options.width orelse 0,
        .height = options.height orelse 0,
        .has_layout = false,
    };

    if (options.width != null and options.height != null) {
        graph.setDimensions(options.width.?, options.height.?);
    }

    return graph;
}

pub fn deinit(graph: *const Graph) void {
    if (graph.has_layout) {
        _ = c.gvFreeLayout(graph.gvc, graph.g);
    }
    _ = c.agclose(graph.g);
    _ = c.gvFreeContext(graph.gvc);
    graph.arena.deinit();
}

/// Set target aspect ratio (height / width) for Graphviz layout algorithm.
pub fn setRatio(graph: *Graph, ratio: f32) void {
    if (ratio <= 0.0) return;
    var buf: [32]u8 = undefined;
    const ratio_str = std.fmt.bufPrintZ(&buf, "{d:.4}", .{ratio}) catch unreachable;
    _ = c.agsafeset(graph.g, @constCast("ratio"), @constCast(ratio_str.ptr), @constCast(""));
}

/// Set the graph dimensions given pixel width and height.
pub fn setDimensions(graph: *Graph, width_px: u32, height_px: u32) void {
    if (width_px == 0 or height_px == 0) return;

    graph.width = width_px;
    graph.height = height_px;
    graph.setRatio(@as(f32, @floatFromInt(height_px)) / @as(f32, @floatFromInt(width_px)));
}

/// Get the bounding box of the graph from its layout.
pub fn boundingBox(graph: *const Graph) BoundingBox {
    const info = graphInfo(graph.g);
    return .{
        .llx = @floatCast(info.bb.LL.x),
        .lly = @floatCast(info.bb.LL.y),
        .urx = @floatCast(info.bb.UR.x),
        .ury = @floatCast(info.bb.UR.y),
    };
}

/// Remove all nodes and edges, and clear the layout.
pub fn clear(graph: *Graph) void {
    defer _ = graph.arena.reset(.retain_capacity);
    if (graph.has_layout) {
        _ = c.gvFreeLayout(graph.gvc, graph.g);
        graph.has_layout = false;
    }

    var maybe_node = c.agfstnode(graph.g);
    while (maybe_node) |node| {
        const next_node = c.agnxtnode(graph.g, node);
        _ = c.agdelete(graph.g, node);
        maybe_node = next_node;
    }
}

/// Convert uuid to 0-terminated name string for use in graphviz.
///
/// Since graphviz uses u32 ids internally, we instead use the name to identify
/// the nodes, and use the node's label property to set the label.
pub fn idToName(id: u128, buf: *[33]u8) [:0]const u8 {
    return std.fmt.bufPrintZ(buf, "{x:0>32}", .{id}) catch unreachable;
}

/// Convert node hex string name back to a u128 id.
pub fn nameToId(name: []const u8) !u128 {
    return std.fmt.parseInt(u128, name, 16);
}

pub fn getNodeId(node: *c.Agnode_t) !u128 {
    const name_ptr = c.agnameof(node) orelse return error.MissingNodeName;
    const name = std.mem.span(name_ptr);
    return std.fmt.parseInt(u128, name, 16);
}

pub fn addNode(graph: *Graph, id: u128, label: []const u8) !void {
    var buf: [33]u8 = undefined;
    const name = idToName(id, &buf);

    var arena = graph.arena.allocator();
    const label_z = try arena.dupeZ(u8, label);
    defer arena.free(label_z);

    const node = c.agnode(graph.g, @constCast(name), 1) orelse return error.NodeFailed;
    _ = c.agsafeset(node, @constCast("label"), @ptrCast(@constCast(label_z)), @constCast(""));
    // Specifies space left around the node's label. By default, the value is 0.11,0.055.
    _ = c.agsafeset(node, @constCast("margin"), @constCast("0.0"), @constCast(""));
    _ = c.agsafeset(node, @constCast("width"), @constCast("0.1"), @constCast(""));
    _ = c.agsafeset(node, @constCast("height"), @constCast("0.1"), @constCast(""));
}

/// Get a cgraph node given the uuid
pub fn getNode(graph: *const Graph, id: u128) ?*c.Agnode_t {
    var buf: [33]u8 = undefined;
    const name = idToName(id, &buf);
    const node = c.agnode(graph.g, @constCast(name), 0);
    return node;
}

pub fn addEdge(graph: *const Graph, from: u128, to: u128) !void {
    const from_node = graph.getNode(from) orelse return error.NodeNotFound;
    const to_node = graph.getNode(to) orelse return error.NodeNotFound;
    _ = c.agedge(graph.g, from_node, to_node, null, 1) orelse return error.EdgeFailed;
}

/// Number of nodes in the graph
pub fn n_nodes(graph: *const Graph) usize {
    return c.agnnodes(graph.g);
}

/// Run the layout algorithm of an engine on the graph.
pub fn layout(graph: *Graph, engine: []const u8) !void {
    if (graph.has_layout) {
        _ = c.gvFreeLayout(graph.gvc, graph.g);
        graph.has_layout = false;
    }
    if (c.gvLayout(graph.gvc, graph.g, @ptrCast(@constCast(engine))) != 0) return error.LayoutFailed;
    // Writes layout coordinates into "pos" string attributes on all nodes/edges
    c.attach_attrs(graph.g);
    graph.has_layout = true;
}

/// Render the graph to a file. NOTE: Must run layout first!
pub fn renderToFile(graph: *const Graph, format: []const u8, filename: []const u8) !void {
    if (!graph.has_layout) return error.NoLayout;
    const rc = c.gvRenderFilename(
        graph.gvc,
        graph.g,
        @ptrCast(@constCast(format)),
        @ptrCast(@constCast(filename)),
    );
    if (rc != 0) return error.RenderFailed;
}

// ** Buffer renderer

const Camera = struct {
    /// Center of the camera in world coordinates
    center_x: f32 = 0.0,
    center_y: f32 = 0.0,
    /// Zoom scale factor (1.0 = 100%)
    zoom: f32 = 1.0,
};

pub const MouseButton = enum { left, right, middle };

const State = struct {
    mouse: struct {
        /// Which button is currently pressed
        down: ?MouseButton = null,
        last_pos: [2]f32 = .{ 0.0, 0.0 },
        drag: ?struct {
            // start_pos: [2]f32 = .{ 0.0, 0.0 },
            mode: union(enum) {
                pan_camera,
                drag_node: u128,
            },
        } = null,
    } = .{},
};

pub const RendererOptions = struct {
    gpa: std.mem.Allocator,
    graph_options: GraphOptions = .{},
    padding: f32 = 20.0,
    /// Viewport width in pixels. If 0, uses buffer_stride.
    view_width: u32 = 0,
    /// Viewport height in pixels. If 0, uses buffer_height.
    view_height: u32 = 0,
    /// Buffer stride in pixels
    buffer_stride: usize,
    /// Number of rows in the buffer
    buffer_height: usize,
    /// ARGB32 pixel buffer. If null, buffer allocation is managed internally.
    buffer: ?[]u8 = null,
    camera: Camera = .{},
};

/// Render a Graph to a pixel buffer with a 2D camera viewport.
///
/// The pixel buffer has a fixed capacity (buffer_stride * buffer_height). The visible
/// viewport is defined by (view_width, view_height). Moving around or zooming the graph
/// simply moves the camera within world space without altering graph layout coordinates.
pub const Renderer = struct {
    gpa: std.mem.Allocator,
    graph: Graph,
    padding: f32,
    highlighted: std.AutoHashMap(u128, void),
    state: State = .{},
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

    // Load the font and keep it in memory forever. Since it will be reused
    // there is no need to deallocate.
    const font_data = @embedFile("assets/DejaVuSans.ttf");
    var plutovg_font: ?*c.plutovg_font_face_t = null;

    pub fn init(options: RendererOptions) !Renderer {
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

        if (plutovg_font == null) {
            if (c.plutovg_font_face_load_from_data(
                font_data.ptr,
                font_data.len,
                0, // ttcindex (0 for standard .ttf)
                null, // destroy_func (null because memory is static)
                null, // closure
            )) |font| {
                plutovg_font = font;
            } else std.log.warn("Graph renderer font not loaded", .{});
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

        return .{
            .gpa = gpa,
            .graph = graph,
            .padding = options.padding,
            .highlighted = .init(gpa),
            .buffer = buffer,
            .stride = stride,
            .height = height,
            .view_width = view_w,
            .view_height = view_h,
            .camera = options.camera,
            .managed = options.buffer == null,
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.highlighted.deinit();
        self.graph.deinit();
        if (self.managed) {
            self.gpa.free(self.buffer);
        }
    }

    pub fn clear(self: *Renderer) void {
        self.graph.clear();
        self.highlighted.clearRetainingCapacity();
    }

    pub fn mouseDown(self: *Renderer, screen_x: f32, screen_y: f32, button: MouseButton) !bool {
        self.state.mouse.last_pos = .{ screen_x, screen_y };
        self.state.mouse.down = button;
        self.state.mouse.drag = null;
        return false;
    }

    pub fn mouseMove(self: *Renderer, screen_x: f32, screen_y: f32) !bool {
        const last_pos = self.state.mouse.last_pos;
        defer self.state.mouse.last_pos = .{ screen_x, screen_y };
        if (self.state.mouse.down == null) return false;
        if (self.state.mouse.drag) |drag| {
            switch (drag.mode) {
                .pan_camera => {
                    try self.pan(screen_x - last_pos[0], screen_y - last_pos[1]);
                },
                .drag_node => {},
            }
            return true;
        }

        if (self.getNodeAt(screen_x, screen_y)) |node_id| {
            self.state.mouse.drag = .{ .mode = .{ .drag_node = node_id } };
        } else {
            self.state.mouse.drag = .{ .mode = .pan_camera };
        }
        return true;
    }

    pub fn mouseUp(self: *Renderer, screen_x: f32, screen_y: f32) !bool {
        self.state.mouse.last_pos = .{ screen_x, screen_y };
        self.state.mouse.drag = null;
        self.state.mouse.down = null;
        return true;
    }

    /// Layout graph with aspect ratio set to match current viewport.
    pub fn layout(self: *Renderer, engine: []const u8) !void {
        if (self.view_width > 0 and self.view_height > 0) {
            const target_ratio = @as(f32, @floatFromInt(self.view_height)) / @as(f32, @floatFromInt(self.view_width));
            self.graph.setRatio(target_ratio);
        }
        try self.graph.layout(engine);
    }

    /// Resize the visible viewport dimensions within buffer bounds, and rerender.
    pub fn resize(self: *Renderer, width: u32, height: u32) !void {
        const max_w: u32 = @intCast(self.stride);
        const max_h: u32 = @intCast(self.height);
        self.view_width = @max(1, @min(width, max_w));
        self.view_height = @max(1, @min(height, max_h));
        self.graph.setRatio(@as(f32, @floatFromInt(self.view_height)) / @as(f32, @floatFromInt(self.view_width)));
        try self.render();
    }

    /// Fit camera to current graph's bounding box and center it in the viewport.
    pub fn fitToGraph(self: *Renderer) void {
        const bb = self.graph.boundingBox();
        const gw = bb.width();
        const gh = bb.height();
        const vw = @max(1.0, @as(f32, @floatFromInt(self.view_width)) - self.padding * 2.0);
        const vh = @max(1.0, @as(f32, @floatFromInt(self.view_height)) - self.padding * 2.0);

        self.camera.zoom = @min(vw / gw, vh / gh);
        self.camera.center_x = bb.centerX();
        self.camera.center_y = bb.centerY();
    }

    /// Move camera by a delta in screen pixels (e.g. from mouse drag).
    pub fn pan(self: *Renderer, delta_screen_x: f32, delta_screen_y: f32) !void {
        self.camera.center_x -= delta_screen_x / self.camera.zoom;
        self.camera.center_y += delta_screen_y / self.camera.zoom;
        try self.render();
    }

    /// Zoom camera by a multiplication factor, optionally centered at a screen focus coordinate.
    pub fn zoomBy(self: *Renderer, factor: f32, screen_focus_x: ?f32, screen_focus_y: ?f32) !void {
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
        try self.render();
    }

    /// Convert screen pixel coordinates (origin at top-left of viewport) to world coordinates.
    pub fn screenToWorld(self: *const Renderer, screen_x: f32, screen_y: f32) struct { x: f32, y: f32 } {
        const vw: f32 = @floatFromInt(self.view_width);
        const vh: f32 = @floatFromInt(self.view_height);
        return .{
            .x = self.camera.center_x + (screen_x - vw / 2.0) / self.camera.zoom,
            .y = self.camera.center_y - (screen_y - vh / 2.0) / self.camera.zoom,
        };
    }

    /// Convert world coordinates to screen pixel coordinates.
    pub fn worldToScreen(self: *const Renderer, world_x: f32, world_y: f32) struct { x: f32, y: f32 } {
        const vw: f32 = @floatFromInt(self.view_width);
        const vh: f32 = @floatFromInt(self.view_height);
        return .{
            .x = (world_x - self.camera.center_x) * self.camera.zoom + vw / 2.0,
            .y = (self.camera.center_y - world_y) * self.camera.zoom + vh / 2.0,
        };
    }

    /// Find node under the given screen coordinates, if any.
    pub fn getNodeAt(self: *const Renderer, screen_x: f32, screen_y: f32) ?u128 {
        const world_pt = self.screenToWorld(screen_x, screen_y);
        var maybe_node = c.agfstnode(self.graph.g);
        while (maybe_node) |node| : (maybe_node = c.agnxtnode(self.graph.g, node)) {
            const node_info = nodeInfo(node);
            const cx: f32 = @floatCast(node_info.coord.x);
            const cy: f32 = @floatCast(node_info.coord.y);
            const radius: f32 = @as(f32, @floatCast(node_info.height * 72.0 * 0.5)) / 2.0;
            const dx = world_pt.x - cx;
            const dy = world_pt.y - cy;
            if (dx * dx + dy * dy <= radius * radius) {
                if (getNodeId(node)) |id| {
                    return id;
                } else |_| {}
            }
        }
        return null;
    }

    /// Render the graph in the pixel buffer using current camera transformation.
    pub fn render(self: *Renderer) !void {
        const buffer = self.buffer;
        const graph = &self.graph;

        const render_w = self.view_width;
        const render_h = self.view_height;

        const surface = c.plutovg_surface_create_for_data(
            buffer.ptr,
            @intCast(render_w),
            @intCast(render_h),
            @intCast(self.stride * 4),
        ) orelse return error.SurfaceFailed;
        defer c.plutovg_surface_destroy(surface);

        const canvas = c.plutovg_canvas_create(surface) orelse return error.CanvasFailed;
        defer c.plutovg_canvas_destroy(canvas);

        // Clear background (dark theme background)
        c.plutovg_canvas_save(canvas);
        defer c.plutovg_canvas_restore(canvas);

        c.plutovg_canvas_set_rgba(canvas, 0.12, 0.12, 0.15, 1.0);
        c.plutovg_canvas_set_operator(canvas, c.PLUTOVG_OPERATOR_SRC);
        c.plutovg_canvas_paint(canvas);
        c.plutovg_canvas_set_operator(canvas, c.PLUTOVG_OPERATOR_SRC_OVER);

        // Apply camera transformation:
        // Viewport center -> zoom & flip Y (Graphviz Y-up -> PlutoVG Y-down) -> camera center
        const vw: f32 = @floatFromInt(render_w);
        const vh: f32 = @floatFromInt(render_h);
        c.plutovg_canvas_translate(canvas, vw / 2.0, vh / 2.0);
        c.plutovg_canvas_scale(canvas, self.camera.zoom, -self.camera.zoom);
        c.plutovg_canvas_translate(canvas, -self.camera.center_x, -self.camera.center_y);

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
            const node_id = try getNodeId(node);
            const node_info = nodeInfo(node);
            const cx: f32 = @floatCast(node_info.coord.x);
            const cy: f32 = @floatCast(node_info.coord.y);
            const h: f32 = @floatCast(node_info.height * 72.0 * 0.5);

            // Draw node body
            c.plutovg_canvas_circle(canvas, cx, cy, h / 2);
            if (self.highlighted.contains(node_id)) {
                c.plutovg_canvas_set_rgba(canvas, 0.8, 0.85, 1.0, 1.0);
            } else {
                c.plutovg_canvas_set_rgba(canvas, 0.0, 0.0, 0.0, 0.0);
            }
            c.plutovg_canvas_fill_preserve(canvas);

            // Draw node border
            c.plutovg_canvas_set_rgba(canvas, 0.8, 0.85, 1.0, 1.0);
            c.plutovg_canvas_set_line_width(canvas, 1.5);
            c.plutovg_canvas_stroke(canvas);

            // Label
            const label: []const u8 = std.mem.span(node_info.label.*.text);

            if (plutovg_font) |font| {
                c.plutovg_canvas_save(canvas);
                // Translate to node center and flip Y back to right-side up
                c.plutovg_canvas_translate(canvas, cx, cy - h / 3);
                c.plutovg_canvas_scale(canvas, 1.0, -1.0);

                const font_size: f32 = 12.0;
                c.plutovg_canvas_set_font(canvas, font, font_size);

                var extents: c.plutovg_rect_t = undefined;
                const adv = c.plutovg_font_face_text_extents(
                    font,
                    font_size,
                    label.ptr,
                    @intCast(label.len),
                    c.PLUTOVG_TEXT_ENCODING_UTF8,
                    &extents,
                );

                // Center horizontally and vertically
                const tx_label = -adv / 2.0;
                const ty_label = extents.h / 2.0;

                c.plutovg_canvas_set_rgba(canvas, 1.0, 1.0, 1.0, 1.0);
                _ = c.plutovg_canvas_fill_text(
                    canvas,
                    label.ptr,
                    @intCast(label.len),
                    c.PLUTOVG_TEXT_ENCODING_UTF8,
                    tx_label,
                    ty_label,
                );
                c.plutovg_canvas_restore(canvas);
            }
        }
    }

    /// Render graphviz edge's Bezier splines and arrowheads
    fn drawEdgeSpline(canvas: *c.plutovg_canvas_t, edge: *c.struct_Agedge_s) !void {
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
        const edge_info = edgeInfo(edge);
        const splines = edge_info.*.spl.*;

        if (splines.size == 0) return;

        for (0..@intCast(splines.size)) |spline_i| {
            const bezier = splines.list[spline_i];
            const num_ctrl_points: usize = @intCast(bezier.size); // always (3 * n + 1)
            const ctrl_points = bezier.list;

            c.plutovg_canvas_set_rgba(canvas, 0.7, 0.75, 0.85, 0.9);
            c.plutovg_canvas_set_line_width(canvas, 2.0);
            c.plutovg_canvas_move_to(canvas, @floatCast(ctrl_points[0].x), @floatCast(ctrl_points[0].y));

            var i: usize = 1;
            while (i + 2 < num_ctrl_points) : (i += 3) {
                c.plutovg_canvas_cubic_to(
                    canvas,
                    @floatCast(ctrl_points[i].x),
                    @floatCast(ctrl_points[i].y),
                    @floatCast(ctrl_points[i + 1].x),
                    @floatCast(ctrl_points[i + 1].y),
                    @floatCast(ctrl_points[i + 2].x),
                    @floatCast(ctrl_points[i + 2].y),
                );
            }
            c.plutovg_canvas_stroke(canvas);

            // Draw end arrowhead
            if (bezier.eflag == 1) {
                c.plutovg_canvas_set_rgba(canvas, 0.7, 0.75, 0.85, 0.9);
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
                c.plutovg_canvas_set_rgba(canvas, 0.7, 0.75, 0.85, 0.9);
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
    fn drawArrow(canvas: *c.plutovg_canvas_t, from_x: f32, from_y: f32, to_x: f32, to_y: f32, size: f32) void {
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

        c.plutovg_canvas_move_to(canvas, to_x, to_y);
        c.plutovg_canvas_line_to(canvas, base_x + px * half_w, base_y + py * half_w);
        c.plutovg_canvas_line_to(canvas, base_x - px * half_w, base_y - py * half_w);
        c.plutovg_canvas_close_path(canvas);
        c.plutovg_canvas_fill(canvas);
    }
};

// ** C interop

// Deal with bitmaps not being handled by translate-c
const Agdesc_t = packed struct(c_uint) {
    directed: u1 = 0,
    strict: u1 = 0,
    no_loop: u1 = 0,
    maingraph: u1 = 0,
    flatlock: u1 = 0,
    no_write: u1 = 0,
    has_attrs: u1 = 0,
    has_cmpnd: u1 = 0,
    _padding: u24 = 0,
};

extern var Agdirected: Agdesc_t;
extern var Agstrictdirected: Agdesc_t;
extern var Agundirected: Agdesc_t;
extern var Agstrictundirected: Agdesc_t;

pub extern "c" fn agopen(name: [*c]u8, desc: Agdesc_t, disc: ?*c.Agdisc_t) ?*c.Agraph_t;

// Layout-compatible header for Graphviz C objects
const Agtag = extern struct {
    tag_bits: u32,
    _pad: u32,
    id: u64,
};

const Agobj = extern struct {
    tag: Agtag,
    data: ?*c.Agrec_t,
};

pub inline fn AGDATA(obj: anytype) ?*c.Agrec_t {
    const o: *const Agobj = @ptrCast(@alignCast(obj));
    return o.data;
}

pub inline fn nodeInfo(node: *c.Agnode_t) *c.Agnodeinfo_t {
    return @ptrCast(@alignCast(AGDATA(node).?));
}

pub inline fn edgeInfo(edge: *c.Agedge_t) *c.Agedgeinfo_t {
    return @ptrCast(@alignCast(AGDATA(edge).?));
}

pub inline fn graphInfo(graph: *c.Agraph_t) *c.Agraphinfo_t {
    return @ptrCast(@alignCast(AGDATA(graph).?));
}

// ** Tests

test "Graph buffer rendering, camera panning, zooming, and hit testing" {
    const allocator = std.testing.allocator;

    var renderer = try Renderer.init(.{
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
