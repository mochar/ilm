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
    pub fn add(ctx: *Context, core: *Core, name: []u8, parent_ids: []Id) !Id.StrT {
        var diags: sqlite.Diagnostics = .{};
        var id = ilm.concept.add(core, name, parent_ids, .{ .diags = &diags }) catch |err| {
            if (diags.err) |sqlite_err| {
                ctx.setError("Sqlite error: {s}", .{sqlite_err.message});
            } else {
                ctx.setError("Failed to add concept: {t}", .{err});
            }
            return err;
        };
        return id.serialize();
    }

    pub fn addParent(ctx: *Context, core: *Core, child_id: Id, parent_id: Id) !void {
        var diags: sqlite.Diagnostics = .{};
        ilm.concept.addParent(core, child_id, parent_id, .{ .diags = &diags }) catch |err| {
            if (diags.err) |sqlite_err| {
                ctx.setError("Sqlite error: {s}", .{sqlite_err.message});
            } else {
                ctx.setError("Failed to add concept parent: {t}", .{err});
            }
            return err;
        };
    }

    pub fn removeParent(ctx: *Context, core: *Core, child_id: Id, parent_id: Id) !void {
        var diags: sqlite.Diagnostics = .{};
        ilm.concept.removeParent(core, child_id, parent_id, .{ .diags = &diags }) catch |err| {
            if (diags.err) |sqlite_err| {
                ctx.setError("Sqlite error: {s}", .{sqlite_err.message});
            } else {
                ctx.setError("Failed to remove concept parent: {t}", .{err});
            }
            return err;
        };
    }

    pub fn getAll(ctx: *Context, core: *Core) ![]Concept {
        var diags: sqlite.Diagnostics = .{};
        const concepts = ilm.concept.getAll(core, ctx.arena, .{ .diags = &diags }) catch |err| {
            if (diags.err) |sqlite_err| {
                ctx.setError("Sqlite error: {s}", .{sqlite_err.message});
            } else {
                ctx.setError("Failed to get concepts: {t}", .{err});
            }
            return err;
        };
        return concepts;
    }

    pub fn getById(ctx: *Context, core: *Core, ids: []const Id) ![]Concept {
        var diags: sqlite.Diagnostics = .{};
        const concepts = ilm.concept.getById(core, ctx.arena, ids, .{ .diags = &diags }) catch |err| {
            if (diags.err) |sqlite_err| {
                ctx.setError("Sqlite error: {s}", .{sqlite_err.message});
            } else {
                ctx.setError("Failed to get concepts: {t}", .{err});
            }
            return err;
        };
        ctx.env.message("Found {d} ids and {d} concepts", .{ ids.len, concepts.len });
        return concepts;
    }

    pub fn getAncestors(ctx: *Context, core: *Core, ids: []Id, direct_only: bool) ![]ConceptAncestor {
        var diags: sqlite.Diagnostics = .{};
        const ancestors = ilm.concept.getAncestors(core, ctx.arena, ids, direct_only, .{ .diags = &diags }) catch |err| {
            if (diags.err) |sqlite_err| {
                ctx.setError("Sqlite error: {s}", .{sqlite_err.message});
            } else {
                ctx.setError("Failed to get ancestors: {t}", .{err});
            }
            return err;
        };
        return ancestors;
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

        var diags: sqlite.Diagnostics = .{};
        const ancestors = ilm.concept.getAncestors(core, ctx.arena, &ids, false, .{ .diags = &diags }) catch |err| {
            return ctx.setError("Failed to get ancestors: {t}", .{err});
        };
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
