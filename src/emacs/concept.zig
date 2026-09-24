const std = @import("std");
const ilm = @import("ilm");
const Core = ilm.Core;
const Id = ilm.Id;
const GraphRenderer = ilm.GraphRenderer;
const Concept = ilm.concept.Concept;
const ConceptAncestor = ilm.concept.ConceptAncestor;
const sqlite = @import("sqlite");
const emacs = @import("emacs.zig");
const Context = emacs.Context;
const EmacsValue = emacs.EmacsValue;

const refreshGraph = @import("graph.zig").refreshGraph;

pub const Funcs = struct {
    pub fn add(_: *Context, core: *Core, name: []u8, parent_ids: []Id) !Id.StrT {
        var id = try ilm.concept.add(core, name, parent_ids);
        return id.serialize();
    }

    pub fn addParent(_: *Context, core: *Core, child_id: Id, parent_id: Id) !void {
        try ilm.concept.addParent(core, child_id, parent_id);
    }

    pub fn removeParent(_: *Context, core: *Core, child_id: Id, parent_id: Id) !void {
        try ilm.concept.removeParent(core, child_id, parent_id);
    }

    pub fn getAll(ctx: *Context, core: *Core) ![]Concept {
        return try ilm.concept.getAll(core, ctx.arena);
    }

    pub fn getById(ctx: *Context, core: *Core, ids: []const Id) ![]Concept {
        return try ilm.concept.getById(core, ctx.arena, ids);
    }

    pub fn getAncestors(ctx: *Context, core: *Core, ids: []Id, direct_only: bool) ![]ConceptAncestor {
        return try ilm.concept.getAncestors(core, ctx.arena, .{ .ids = ids, .direct_only = direct_only });
    }

    pub fn setGraph(ctx: *Context, core: *Core, graph_data: EmacsValue, concept_id: Id) !void {
        const gr = try ctx.env.plistGet(graph_data, "graph-ptr", ctx.arena, *GraphRenderer);
        const graph = &gr.graph;
        gr.clear();

        const ids: [1]Id = .{concept_id};
        const concept = blk: {
            const concepts = try Funcs.getById(ctx, core, &ids);
            if (concepts.len == 0) {
                ctx.setError("Failed to get concept with id: {s}", .{concept_id.serialize()});
                return error.NotFound;
            }
            break :blk concepts[0];
        };

        graph.addNode(concept.id.uuid, concept.name) catch |err| {
            return ctx.setError("Failed to add node: {t}", .{err});
        };
        gr.highlighted.put(concept.id.uuid, {}) catch |err| {
            return ctx.setError("Failed to add graph highlight: {t}", .{err});
        };

        const ancestors = try ilm.concept.getAncestors(core, ctx.arena, .{ .ids = &ids });
        for (ancestors) |*ancestor| {
            graph.addNode(ancestor.id.uuid, ancestor.name) catch |err| {
                return ctx.setError("Failed to add node: {t}", .{err});
            };
        }
        for (ancestors) |*ancestor| {
            graph.addEdge(ancestor.id.uuid, ancestor.child_id.uuid) catch |err| {
                return ctx.setError("Failed to add edge: {t}", .{err});
            };
        }

        const canvas_spec = try ctx.env.plistGet(graph_data, "canvas", ctx.arena, EmacsValue);
        try refreshGraph(ctx, gr, canvas_spec);
    }
};
