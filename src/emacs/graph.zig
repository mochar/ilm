const std = @import("std");
const ilm = @import("ilm");
const Core = ilm.Core;
const Id = ilm.Id;
const Graph = ilm.Graph;
const emacs = @import("emacs.zig");
const Context = emacs.Context;
const EmacsValue = emacs.EmacsValue;
const sqlite = @import("sqlite");

const c_allocator = std.heap.c_allocator;

pub fn refreshGraph(ctx: *Context, gr: *Graph.Renderer, canvas_spec: EmacsValue) !void {
    // TODO Should be &graph ?
    gr.graph.layout("dot") catch |err| return ctx.setError("Failed to layout graph: {t}", .{err});
    gr.render() catch |err| return ctx.setError("Failed to render graph: {t}", .{err});
    const refresh_sym = ctx.env.intern("canvas-refresh");
    _ = try ctx.env.funcall1(refresh_sym, canvas_spec);
}

pub const Funcs = struct {
    // const GraphContainer = struct {
    //     renderer: *Graph.Renderer,
    //     canvas_spec: EmacsValue,

    //     pub fn fromEmacsRepr(env: emacs.Env, q_container: EmacsValue) GraphContainer {

    //     }
    // };

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
        const graph_renderer = c_allocator.create(Graph.Renderer) catch |err| {
            ctx.setError("Failed to allocate Graph.Renderer: {t}", .{err});
            return err;
        };
        errdefer c_allocator.destroy(graph_renderer);
        graph_renderer.* = Graph.Renderer.init(.{
            .gpa = core.gpa,
            .graph_options = .{
                .width = view_width,
                .height = view_height,
            },
            .buffer = canvas_buffer,
            .buffer_stride = buffer_width,
            .buffer_height = buffer_height,
        }) catch |err| {
            ctx.setError("Failed to initialize Graph Renderer: {t}", .{err});
            return err;
        };

        // Construct response: a plist with
        const graph_user_ptr = ctx.env.makeUserPtr(Graph.Renderer, graph_renderer);
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

    /// Resize graph, refresh, and update the graph data with new width and height.
    pub fn resize(ctx: *Context, graph_data: EmacsValue, width: u32, height: u32) !void {
        const gr = try ctx.env.plistGet(graph_data, "graph-ptr", ctx.arena, *Graph.Renderer);
        const canvas_spec = try ctx.env.plistGet(graph_data, "canvas", ctx.arena, EmacsValue);
        try gr.resize(width, height);
        try ctx.env.plistSet(graph_data, "width", gr.graph.width);
        try ctx.env.plistSet(graph_data, "height", gr.graph.height);
        _ = try ctx.env.funcall1(ctx.env.intern("canvas-refresh"), canvas_spec);
    }

    /// Update the graph to match the width and height of graph data.
    pub fn update(ctx: *Context, graph_data: EmacsValue) !void {
        const gr = try ctx.env.plistGet(graph_data, "graph-ptr", ctx.arena, *Graph.Renderer);
        // const graph = &gr.graph;

        const view_width = try ctx.env.plistGet(graph_data, "width", ctx.arena, u32);
        const view_height = try ctx.env.plistGet(graph_data, "height", ctx.arena, u32);
        const canvas_spec = try ctx.env.plistGet(graph_data, "canvas", ctx.arena, EmacsValue);
        const canvas: emacs.Canvas = try .fromSpec(ctx.arena, ctx.env, canvas_spec);
        if (canvas.buffer.ptr != gr.buffer.ptr) {
            // If we decide to no longer parse the buffer from canvas_spec, we
            // can alternatively check if the buffer width and height matches,
            // since emacs creates a new buffer if :data-width or :data-height
            // changed.
            ctx.setError("Canvas buffer does not match graph buffer (resized?)", .{});
            return error.DifferentBuffers;
        }

        try gr.resize(view_width, view_height);
    }
};
