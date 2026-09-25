const std = @import("std");
const ilm = @import("ilm");
const Core = ilm.Core;
const Id = ilm.Id;
const GraphRenderer = ilm.GraphRenderer;
const graphviz = @import("graphviz");
const emacs = @import("emacs.zig");
const Context = emacs.Context;
const EmacsValue = emacs.EmacsValue;
const sqlite = @import("sqlite");

const c_allocator = std.heap.c_allocator;

pub fn layoutGraph(ctx: *Context, gr: *GraphRenderer, canvas_spec: EmacsValue) !void {
    gr.layout("neato") catch |err| return ctx.setError("Failed to layout graph: {t}", .{err});
    gr.fitToGraph();
    try renderGraph(ctx, gr, canvas_spec);
}

pub fn renderGraph(ctx: *Context, gr: *GraphRenderer, canvas_spec: EmacsValue) !void {
    gr.render() catch |err| return ctx.setError("Failed to render graph: {t}", .{err});
    try refreshGraph(ctx, canvas_spec);
}

pub fn refreshGraph(ctx: *Context, canvas_spec: EmacsValue) !void {
    _ = try ctx.env.funcall1(ctx.env.intern("canvas-refresh"), canvas_spec);
}

pub const Funcs = struct {
    pub fn make(ctx: *Context, core: *Core, q_id: EmacsValue, view_width: u32, view_height: u32, buffer_width: u32, buffer_height: u32) !EmacsValue {
        const q_list = ctx.env.intern("list");

        // Make canvas spec
        const canvas_spec = blk: {
            const args = [_]EmacsValue{
                ctx.env.intern("image"),
                ctx.env.intern(":type"),
                ctx.env.intern("canvas"),
                ctx.env.intern(":id"),
                q_id,
                ctx.env.intern(":data-width"),
                ctx.env.makeInteger(buffer_width),
                ctx.env.intern(":data-height"),
                ctx.env.makeInteger(buffer_height),
            };
            break :blk try ctx.env.funcall(q_list, &args);
        };

        // Pass emacs the canvas spec which returns the buffer
        const canvas_buffer = blk: {
            const raw_buf = try ctx.env.canvasData(canvas_spec);
            break :blk raw_buf[0 .. buffer_width * buffer_height * 4];
        };

        // Create graph renderer in heap
        const graph_renderer = c_allocator.create(GraphRenderer) catch |err| {
            ctx.setError("Failed to allocate Graph.Renderer: {t}", .{err});
            return err;
        };
        errdefer c_allocator.destroy(graph_renderer);
        graph_renderer.* = GraphRenderer.init(.{
            .gpa = core.gpa,
            .io = core.io,
            .graph_options = .{},
            .view_width = view_width,
            .view_height = view_height,
            .buffer = canvas_buffer,
            .buffer_stride = buffer_width,
            .buffer_height = buffer_height,
        }) catch |err| {
            ctx.setError("Failed to initialize Graph Renderer: {t}", .{err});
            return err;
        };

        // Construct response: a plist
        const graph_user_ptr = ctx.env.makeUserPtr(GraphRenderer, graph_renderer);
        const args = [_]EmacsValue{
            ctx.env.intern(":graph-ptr"),
            graph_user_ptr,
            ctx.env.intern(":canvas"),
            canvas_spec,
            ctx.env.intern(":width"),
            ctx.env.makeInteger(view_width),
            ctx.env.intern(":height"),
            ctx.env.makeInteger(view_height),
        };
        return try ctx.env.funcall(q_list, &args);
    }

    /// Resize visible viewport, refresh, and update the graph data with new width and height.
    pub fn resize(ctx: *Context, graph_data: EmacsValue, width: u32, height: u32) !void {
        const gr = try ctx.env.plistGet(graph_data, "graph-ptr", ctx.arena, *GraphRenderer);
        const canvas_spec = try ctx.env.plistGet(graph_data, "canvas", ctx.arena, EmacsValue);
        gr.resize(width, height);
        try ctx.env.plistSet(graph_data, "width", gr.view_width);
        try ctx.env.plistSet(graph_data, "height", gr.view_height);
        try renderGraph(ctx, gr, canvas_spec);
    }

    /// Update the graph to match the width and height of graph data.
    pub fn update(ctx: *Context, graph_data: EmacsValue) !void {
        const gr = try ctx.env.plistGet(graph_data, "graph-ptr", ctx.arena, *GraphRenderer);

        const view_width = try ctx.env.plistGet(graph_data, "width", ctx.arena, u32);
        const view_height = try ctx.env.plistGet(graph_data, "height", ctx.arena, u32);
        const canvas_spec = try ctx.env.plistGet(graph_data, "canvas", ctx.arena, EmacsValue);
        const canvas: emacs.Canvas = try .fromSpec(ctx.arena, ctx.env, canvas_spec);
        if (canvas.buffer.ptr != gr.buffer.ptr) {
            ctx.setError("Canvas buffer does not match graph buffer (resized?)", .{});
            return error.DifferentBuffers;
        }

        gr.resize(view_width, view_height);
        try renderGraph(ctx, gr, canvas_spec);
    }

    pub fn mouseDown(ctx: *Context, graph_data: EmacsValue, x: f32, y: f32, button: u32) !void {
        const gr = try ctx.env.plistGet(graph_data, "graph-ptr", ctx.arena, *GraphRenderer);
        if (gr.mouseDown(x, y, @enumFromInt(button))) {
            const canvas_spec = try ctx.env.plistGet(graph_data, "canvas", ctx.arena, EmacsValue);
            try renderGraph(ctx, gr, canvas_spec);
        }
        ctx.env.message("DOWN: {}", .{gr.state});
    }

    pub fn mouseUp(ctx: *Context, graph_data: EmacsValue, x: f32, y: f32) !void {
        const gr = try ctx.env.plistGet(graph_data, "graph-ptr", ctx.arena, *GraphRenderer);
        if (gr.mouseUp(x, y)) {
            const canvas_spec = try ctx.env.plistGet(graph_data, "canvas", ctx.arena, EmacsValue);
            try renderGraph(ctx, gr, canvas_spec);
        }
        ctx.env.message("UP: {}", .{gr.state});
    }

    pub fn mouseMove(ctx: *Context, graph_data: EmacsValue, x: f32, y: f32) !void {
        const gr = try ctx.env.plistGet(graph_data, "graph-ptr", ctx.arena, *GraphRenderer);
        if (gr.mouseMove(x, y)) {
            const canvas_spec = try ctx.env.plistGet(graph_data, "canvas", ctx.arena, EmacsValue);
            try renderGraph(ctx, gr, canvas_spec);
        }
        ctx.env.message("MOVE: {}", .{gr.state});
    }

    pub fn mouseScroll(ctx: *Context, graph_data: EmacsValue, factor: f32) !void {
        const gr = try ctx.env.plistGet(graph_data, "graph-ptr", ctx.arena, *GraphRenderer);
        _ = gr.mouseScroll(factor);
        const canvas_spec = try ctx.env.plistGet(graph_data, "canvas", ctx.arena, EmacsValue);
        try renderGraph(ctx, gr, canvas_spec);
    }

    /// Pan the camera by screen delta (dx, dy).
    pub fn pan(ctx: *Context, graph_data: EmacsValue, dx: f32, dy: f32) !void {
        const gr = try ctx.env.plistGet(graph_data, "graph-ptr", ctx.arena, *GraphRenderer);
        const canvas_spec = try ctx.env.plistGet(graph_data, "canvas", ctx.arena, EmacsValue);
        gr.pan(dx, dy);
        try renderGraph(ctx, gr, canvas_spec);
    }

    /// Zoom the camera by factor, centered at (focus_x, focus_y).
    /// If focus coordinates are negative, zoom is centered at current camera position.
    pub fn zoom(ctx: *Context, graph_data: EmacsValue, factor: f32, focus_x: f32, focus_y: f32) !void {
        const gr = try ctx.env.plistGet(graph_data, "graph-ptr", ctx.arena, *GraphRenderer);
        const canvas_spec = try ctx.env.plistGet(graph_data, "canvas", ctx.arena, EmacsValue);
        const fx: ?f32 = if (focus_x >= 0 and focus_y >= 0) focus_x else null;
        const fy: ?f32 = if (focus_x >= 0 and focus_y >= 0) focus_y else null;
        gr.zoomBy(factor, fx, fy);
        try renderGraph(ctx, gr, canvas_spec);
    }

    /// Fit camera to current graph's bounding box and refresh.
    pub fn fit(ctx: *Context, graph_data: EmacsValue) !void {
        const gr = try ctx.env.plistGet(graph_data, "graph-ptr", ctx.arena, *GraphRenderer);
        const canvas_spec = try ctx.env.plistGet(graph_data, "canvas", ctx.arena, EmacsValue);
        gr.fitToGraph();
        try renderGraph(ctx, gr, canvas_spec);
    }

    /// Query node id under screen coordinate (screen_x, screen_y).
    pub fn getNodeAt(ctx: *Context, graph_data: EmacsValue, screen_x: f32, screen_y: f32) !EmacsValue {
        const gr = try ctx.env.plistGet(graph_data, "graph-ptr", ctx.arena, *GraphRenderer);
        if (gr.getNodeAt(screen_x, screen_y)) |node| {
            const node_id = try node.getId();
            var buf: [33]u8 = undefined;
            const name = graphviz.Node.idToName(node_id, &buf);
            return try ctx.env.makeString(name);
        }
        return ctx.env.nil();
    }
};
