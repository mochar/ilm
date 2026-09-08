//! Wrapper for the Graphviz library
const std = @import("std");
const c = @cImport({
    @cInclude("graphviz/cgraph.h");
    @cInclude("graphviz/gvc.h");
    @cInclude("plutovg.h");
});

const Graph = @This();

gvc: *c.GVC_t,
g: *c.Agraph_t,
width: u32,
height: u32,

pub const GraphOptions = struct {
    width: u32,
    height: u32,
    dpi: f32 = 96.0,
};

pub fn init(options: GraphOptions) !Graph {
    const gvc = c.gvContext() orelse return error.GVCFailed;
    const g = agopen(@constCast("graph"), Agdirected, null) orelse return error.OpenFailed;
    _ = c.agsafeset(g, @constCast("bgcolor"), @constCast("transparent"), @constCast(""));
    var graph: Graph = .{
        .gvc = gvc,
        .g = g,
        .width = options.width,
        .height = options.height,
    };
    try setDimensions(&graph, options.width, options.height, options.dpi);
    return graph;
}

pub fn deinit(graph: *const Graph) void {
    _ = c.agclose(graph.g);
    _ = c.gvFreeLayout(graph.gvc, graph.g);
    _ = c.gvFreeContext(graph.gvc);
}

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

pub fn clear(graph: *const Graph) void {
    _ = c.gvFreeLayout(graph.gvc, graph.g);

    var maybe_node = c.agfstnode(graph.g);
    while (maybe_node) |node| {
        const next_node = c.agnxtnode(graph.g, node);
        _ = c.agdelete(graph.g, node);
        maybe_node = next_node;
    }
}

pub fn idToName(id: u128, buf: *[33]u8) [:0]const u8 {
    return std.fmt.bufPrintZ(buf, "{x:0>32}", .{id}) catch unreachable;
}

pub fn addNode(graph: *const Graph, id: u128, label: []const u8) !void {
    var buf: [33]u8 = undefined;
    const name = idToName(id, &buf);
    const node = c.agnode(graph.g, @constCast(name), 1) orelse return error.NodeFailed;
    _ = c.agsafeset(node, @constCast("label"), @ptrCast(@constCast(label)), @constCast(""));
}

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

pub fn n_nodes(graph: *const Graph) usize {
    return c.agnnodes(graph.g);
}

pub fn layout(graph: *const Graph, engine: []const u8) !void {
    if (c.gvLayout(graph.gvc, graph.g, @ptrCast(@constCast(engine))) != 0) return error.LayoutFailed;
    // Writes layout coordinates into "pos" string attributes on all nodes/edges
    c.attach_attrs(graph.g);
}

pub fn renderToFile(graph: *const Graph, format: []const u8, filename: []const u8) !void {
    if (c.gvRenderFilename(graph.gvc, graph.g, @ptrCast(@constCast(format)), @ptrCast(@constCast(filename))) != 0) return error.RenderFailed;
}

pub fn renderToBuffer(graph: *const Graph, buf: []u8) !void {
    if (buf.len != graph.width * graph.height * 4) return error.SizeMismatch;

    const surface = c.plutovg_surface_create_for_data(
        buf.ptr,
        @intCast(graph.width),
        @intCast(graph.height),
        @intCast(graph.width * 4),
    ) orelse return error.SurfaceFailed;
    defer c.plutovg_surface_destroy(surface);

    const canvas = c.plutovg_canvas_create(surface) orelse return error.CanvasFailed;
    defer c.plutovg_canvas_destroy(canvas);

    // Clear buffer to transparent (or background color)
    c.plutovg_canvas_save(canvas);
    defer c.plutovg_canvas_restore(canvas);

    // c.plutovg_canvas_set_rgba(canvas, 0, 0, 0, 0); // transparent (or 0.1, 0.1, 0.1, 1.0 for dark bg)
    c.plutovg_canvas_set_rgba(canvas, 0.5, 0.0, 0.0, 0.5);
    c.plutovg_canvas_set_operator(canvas, c.PLUTOVG_OPERATOR_SRC);
    c.plutovg_canvas_paint(canvas);
    c.plutovg_canvas_set_operator(canvas, c.PLUTOVG_OPERATOR_SRC_OVER);

    // Graphviz (0,0) is bottom-left, PlutoVG (0,0) is top-left -> flip Y axis
    // Read the graph's bounding box: "llx,lly,urx,ury"
    var bb_llx: f32 = 0;
    var bb_lly: f32 = 0;
    var bb_urx: f32 = @floatFromInt(graph.width);
    var bb_ury: f32 = @floatFromInt(graph.height);

    if (c.agget(graph.g, @constCast("bb"))) |bb_raw| {
        var it = std.mem.splitScalar(u8, std.mem.span(bb_raw), ',');
        if (it.next()) |s| bb_llx = std.fmt.parseFloat(f32, s) catch 0;
        if (it.next()) |s| bb_lly = std.fmt.parseFloat(f32, s) catch 0;
        if (it.next()) |s| bb_urx = std.fmt.parseFloat(f32, s) catch @floatFromInt(graph.width);
        if (it.next()) |s| bb_ury = std.fmt.parseFloat(f32, s) catch @floatFromInt(graph.height);
    }

    const graph_w = @max(1.0, bb_urx - bb_llx);
    const graph_h = @max(1.0, bb_ury - bb_lly);

    const canvas_w: f32 = @floatFromInt(graph.width);
    const canvas_h: f32 = @floatFromInt(graph.height);

    // Padding in pixels around the edges
    const padding: f32 = 20.0;
    const avail_w = @max(1.0, canvas_w - padding * 2.0);
    const avail_h = @max(1.0, canvas_h - padding * 2.0);

    // Uniform scale factor to fit all nodes and edges inside the buffer
    const zoom = @min(avail_w / graph_w, avail_h / graph_h);

    // Center the graph on the canvas
    const tx = padding + (avail_w - graph_w * zoom) / 2.0 - bb_llx * zoom;
    const ty = padding + (avail_h - graph_h * zoom) / 2.0 - bb_lly * zoom;

    // Apply translation and flip Y-axis for PlutoVG
    c.plutovg_canvas_translate(canvas, tx, canvas_h - ty);
    c.plutovg_canvas_scale(canvas, zoom, -zoom);

    // Draw Edges
    var maybe_node = c.agfstnode(graph.g);
    while (maybe_node) |node| : (maybe_node = c.agnxtnode(graph.g, node)) {
        var maybe_edge = c.agfstout(graph.g, node);
        while (maybe_edge) |edge| : (maybe_edge = c.agnxtout(graph.g, edge)) {
            // Read edge spline coordinates from attribute "pos"
            if (c.agget(edge, @constCast("pos"))) |pos_raw| {
                const pos_str = std.mem.span(pos_raw);
                try drawEdgeSpline(canvas, pos_str);
            }
        }
    }

    // Draw Nodes
    maybe_node = c.agfstnode(graph.g);
    while (maybe_node) |node| : (maybe_node = c.agnxtnode(graph.g, node)) {
        // Read node pos ("x,y"), width (inches), height (inches)
        const pos_raw = c.agget(node, @constCast("pos")) orelse continue;
        const pos_str = std.mem.span(pos_raw);

        var comma_it = std.mem.splitScalar(u8, pos_str, ',');
        const x_str = comma_it.next() orelse continue;
        const y_str = comma_it.next() orelse continue;

        const cx = try std.fmt.parseFloat(f32, x_str);
        const cy = try std.fmt.parseFloat(f32, y_str);

        // Graphviz width/height are in inches (72 points per inch)
        var w: f32 = 0.75 * 72.0;
        var h: f32 = 0.5 * 72.0;
        if (c.agget(node, @constCast("width"))) |w_raw| {
            if (std.fmt.parseFloat(f32, std.mem.span(w_raw))) |w_in| {
                w = w_in * 72.0;
            } else |_| {}
        }
        if (c.agget(node, @constCast("height"))) |h_raw| {
            if (std.fmt.parseFloat(f32, std.mem.span(h_raw))) |h_in| {
                h = h_in * 72.0;
            } else |_| {}
        }

        // Draw node background (rounded rectangle)
        const rx = w / 2.0;
        const ry = h / 2.0;
        c.plutovg_canvas_round_rect(canvas, cx - rx, cy - ry, w, h, 8.0, 8.0);
        c.plutovg_canvas_set_rgba(canvas, 0.2, 0.4, 0.8, 1.0); // Node fill
        c.plutovg_canvas_fill_preserve(canvas);

        // Draw node border
        c.plutovg_canvas_set_rgba(canvas, 1.0, 1.0, 1.0, 0.9); // Border color
        c.plutovg_canvas_set_line_width(canvas, 2.0);
        c.plutovg_canvas_stroke(canvas);
    }
}

/// Parses Graphviz edge "pos" string and draws Bézier curves on PlutoVG canvas
fn drawEdgeSpline(canvas: *c.plutovg_canvas_t, pos_str: []const u8) !void {
    c.plutovg_canvas_set_rgba(canvas, 0.7, 0.7, 0.7, 0.8);
    c.plutovg_canvas_set_line_width(canvas, 2.0);

    var points_it = std.mem.tokenizeScalar(u8, pos_str, ' ');
    var is_first = true;
    var control_points: [3][2]f32 = undefined;
    var cp_idx: usize = 0;

    while (points_it.next()) |token| {
        // Skip arrow endpoints ("s,x,y" or "e,x,y")
        if (std.mem.startsWith(u8, token, "s,") or std.mem.startsWith(u8, token, "e,")) continue;

        var comma_it = std.mem.splitScalar(u8, token, ',');
        const x_str = comma_it.next() orelse continue;
        const y_str = comma_it.next() orelse continue;

        const x = try std.fmt.parseFloat(f32, x_str);
        const y = try std.fmt.parseFloat(f32, y_str);

        if (is_first) {
            c.plutovg_canvas_move_to(canvas, x, y);
            is_first = false;
        } else {
            control_points[cp_idx] = .{ x, y };
            cp_idx += 1;
            if (cp_idx == 3) {
                // Every 3 points form a cubic Bézier segment
                c.plutovg_canvas_cubic_to(
                    canvas,
                    control_points[0][0],
                    control_points[0][1],
                    control_points[1][0],
                    control_points[1][1],
                    control_points[2][0],
                    control_points[2][1],
                );
                cp_idx = 0;
            }
        }
    }
    c.plutovg_canvas_stroke(canvas);
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
