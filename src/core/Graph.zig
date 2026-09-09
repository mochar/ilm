//! Wrapper for the Graphviz library
const std = @import("std");
const c = @cImport({
    @cInclude("graphviz/cgraph.h");
    @cInclude("graphviz/gvc.h");
    @cInclude("plutovg.h");
});

const Graph = @This();

gpa: std.mem.Allocator,
gvc: *c.GVC_t,
g: *c.Agraph_t,
width: u32,
height: u32,
has_layout: bool = false,

pub const GraphOptions = struct {
    width: u32,
    height: u32,
    /// Resolution in pixels per inch
    dpi: f32 = 96.0,
};

pub fn init(gpa: std.mem.Allocator, options: GraphOptions) !Graph {
    const gvc = c.gvContext() orelse return error.GVCFailed;
    const g = agopen(@constCast("graph"), Agdirected, null) orelse return error.OpenFailed;
    _ = c.agsafeset(g, @constCast("bgcolor"), @constCast("transparent"), @constCast(""));
    var graph: Graph = .{
        .gpa = gpa,
        .gvc = gvc,
        .g = g,
        .width = options.width,
        .height = options.height,
        .has_layout = false,
    };
    try setDimensions(&graph, options.width, options.height, options.dpi);
    return graph;
}

pub fn deinit(graph: *const Graph) void {
    if (graph.has_layout) {
        _ = c.gvFreeLayout(graph.gvc, graph.g);
    }
    _ = c.agclose(graph.g);
    _ = c.gvFreeContext(graph.gvc);
}

/// Set the graph dimensions given pixel width and height, and dpi.
pub fn setDimensions(graph: *Graph, width_px: u32, height_px: u32, dpi: f32) !void {
    const w_in = @as(f32, @floatFromInt(width_px)) / dpi;
    const h_in = @as(f32, @floatFromInt(height_px)) / dpi;

    var size_buf: [64]u8 = undefined;
    const size_str = try std.fmt.bufPrintZ(&size_buf, "{d:.3},{d:.3}!", .{ w_in, h_in });

    var dpi_buf: [32]u8 = undefined;
    const dpi_str = try std.fmt.bufPrintZ(&dpi_buf, "{d:.1}", .{dpi});

    _ = c.agsafeset(graph.g, @constCast("size"), @constCast(size_str.ptr), @constCast(""));
    _ = c.agsafeset(graph.g, @constCast("dpi"), @constCast(dpi_str.ptr), @constCast(""));
    _ = c.agsafeset(graph.g, @constCast("ratio"), @constCast("fill"), @constCast(""));

    graph.width = width_px;
    graph.height = height_px;
}

/// Remove all nodes and edges, and clear the layout.
pub fn clear(graph: *Graph) void {
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

pub fn addNode(graph: *const Graph, id: u128, label: []const u8) !void {
    var buf: [33]u8 = undefined;
    const name = idToName(id, &buf);

    const label_z = try graph.gpa.dupeZ(u8, label);
    defer graph.gpa.free(label_z);

    const node = c.agnode(graph.g, @constCast(name), 1) orelse return error.NodeFailed;
    _ = c.agsafeset(node, @constCast("label"), @ptrCast(@constCast(label_z)), @constCast(""));
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

pub const RenderOptions = struct {
    /// Number of bytes that constitutes a row (e.g. max_width * 4).
    /// If null, defaults to graph.width * 4.
    stride_bytes: ?usize = null,
};

/// Render the graph in a pixel buffer.
pub fn renderToBuffer(graph: *const Graph, buf: []u8, options: RenderOptions) !void {
    if (graph.width == 0 or graph.height == 0) return;

    const stride = options.stride_bytes orelse (@as(usize, graph.width) * 4);
    const required_len = (@as(usize, graph.height) - 1) * stride + (@as(usize, graph.width) * 4);
    if (buf.len < required_len) return error.SizeMismatch;

    const surface = c.plutovg_surface_create_for_data(
        buf.ptr,
        @intCast(graph.width),
        @intCast(graph.height),
        @intCast(stride),
    ) orelse return error.SurfaceFailed;
    defer c.plutovg_surface_destroy(surface);

    const canvas = c.plutovg_canvas_create(surface) orelse return error.CanvasFailed;
    defer c.plutovg_canvas_destroy(canvas);

    // Load font for node labels (tries standard TTF font paths)
    var maybe_font = c.plutovg_font_face_load_from_file("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 0);
    if (maybe_font == null) {
        maybe_font = c.plutovg_font_face_load_from_file("/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf", 0);
    }
    defer if (maybe_font) |f| c.plutovg_font_face_destroy(f);

    // Clear background (dark theme background)
    c.plutovg_canvas_save(canvas);
    defer c.plutovg_canvas_restore(canvas);

    c.plutovg_canvas_set_rgba(canvas, 0.12, 0.12, 0.15, 1.0);
    c.plutovg_canvas_set_operator(canvas, c.PLUTOVG_OPERATOR_SRC);
    c.plutovg_canvas_paint(canvas);
    c.plutovg_canvas_set_operator(canvas, c.PLUTOVG_OPERATOR_SRC_OVER);

    // Compute bounding box auto-fit & centering
    const graph_info = graphInfo(graph.g);
    const bb_llx: f32 = @floatCast(graph_info.bb.LL.x);
    const bb_lly: f32 = @floatCast(graph_info.bb.LL.y);
    const bb_urx: f32 = @floatCast(graph_info.bb.UR.x);
    const bb_ury: f32 = @floatCast(graph_info.bb.UR.y);
    // graph_info.*.drawing.*.size.

    const graph_w = @max(1.0, bb_urx - bb_llx);
    const graph_h = @max(1.0, bb_ury - bb_lly);
    const canvas_w: f32 = @floatFromInt(graph.width);
    const canvas_h: f32 = @floatFromInt(graph.height);

    const padding: f32 = @min(24.0, @min(canvas_w, canvas_h) * 0.1);
    const avail_w = @max(1.0, canvas_w - padding * 2.0);
    const avail_h = @max(1.0, canvas_h - padding * 2.0);

    const zoom = @min(avail_w / graph_w, avail_h / graph_h);
    const tx = padding + (avail_w - graph_w * zoom) / 2.0 - bb_llx * zoom;
    const ty = padding + (avail_h - graph_h * zoom) / 2.0 - bb_lly * zoom;

    // Apply viewport transform (Graphviz Y-up -> PlutoVG Y-down)
    c.plutovg_canvas_translate(canvas, tx, canvas_h - ty);
    c.plutovg_canvas_scale(canvas, zoom, -zoom);

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
        const node_info = nodeInfo(node);
        const cx: f32 = @floatCast(node_info.coord.x);
        const cy: f32 = @floatCast(node_info.coord.y);
        // const w: f32 = @floatCast(node_info.width * 72.0);
        const h: f32 = @floatCast(node_info.height * 72.0);

        // Draw node body
        // c.plutovg_canvas_round_rect(canvas, cx - w / 2.0, cy - h / 2.0, w, h, 8.0, 8.0);
        c.plutovg_canvas_set_rgba(canvas, 0.2, 0.35, 0.65, 1.0);
        // c.plutovg_canvas_fill_preserve(canvas);
        c.plutovg_canvas_circle(canvas, cx, cy, h/3);

        // Draw node border
        c.plutovg_canvas_set_rgba(canvas, 0.8, 0.85, 1.0, 1.0);
        c.plutovg_canvas_set_line_width(canvas, 1.5);
        c.plutovg_canvas_stroke(canvas);

        // Label
        const label: []const u8 = std.mem.span(node_info.label.*.text);

        if (maybe_font) |font| {
            c.plutovg_canvas_save(canvas);
            // Translate to node center and flip Y back to right-side up
            // c.plutovg_canvas_translate(canvas, cx, cy);
            c.plutovg_canvas_translate(canvas, cx, cy-h/3);
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

test "Graph buffer rendering with custom stride" {
    const allocator = std.testing.allocator;

    var graph = try Graph.init(allocator, .{
        .width = 200,
        .height = 150,
    });
    defer graph.deinit();

    try graph.addNode(1, "Node A");
    try graph.addNode(2, "Node B");
    try graph.addEdge(1, 2);

    try graph.layout("neato");

    const max_w: usize = 512;
    const max_h: usize = 512;
    const stride: usize = max_w * 4;
    const buf = try allocator.alloc(u8, stride * max_h);
    defer allocator.free(buf);
    @memset(buf, 0);

    try graph.renderToBuffer(buf, .{ .stride_bytes = stride });

    // Verify dimensions can be updated dynamically
    try graph.setDimensions(300, 250, 96.0);
    try graph.layout("neato");
    try graph.renderToBuffer(buf, .{ .stride_bytes = stride });
}
