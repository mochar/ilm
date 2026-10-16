const std = @import("std");
const c = @import("c");

pub const Pos = struct {
    x: f32,
    y: f32,
};

pub const BoundingBox = struct {
    ll: Pos,
    ur: Pos,

    pub fn zeroArea(x: f32, y: f32) BoundingBox {
        return .{
            .ll = .{ .x = x, .y = y },
            .ur = .{ .x = x, .y = y },
        };
    }

    pub fn width(self: BoundingBox) f32 {
        return @max(1.0, self.ur.x - self.ll.x);
    }

    pub fn height(self: BoundingBox) f32 {
        return @max(1.0, self.ur.y - self.ll.y);
    }

    pub fn centerX(self: BoundingBox) f32 {
        return (self.ll.x + self.ur.x) / 2.0;
    }

    pub fn centerY(self: BoundingBox) f32 {
        return (self.ll.y + self.ur.y) / 2.0;
    }
};

pub const Node = struct {
    cnode: *c.Agnode_t,

    pub fn getId(node: *const Node) !u128 {
        return Node.getNodeId(node.cnode);
    }

    pub fn getNodeId(cnode: *c.Agnode_t) !u128 {
        const name_ptr = c.agnameof(cnode) orelse return error.MissingNodeName;
        // const name = std.mem.span(name_ptr);
        // return std.fmt.parseInt(u128, name, 16);
        return std.fmt.parseInt(u128, name_ptr[0..32], 16);
    }

    pub fn getInfo(node: *const Node) *c.Agnodeinfo_t {
        return nodeInfo(node.cnode);
    }

    pub fn getPos(node: *const Node) Pos {
        const info = node.getInfo();
        return .{ .x = @floatCast(info.coord.x), .y = @floatCast(info.coord.y) };
    }

    pub fn getHeight(node: *const Node) f32 {
        // Convert points and inches (72)
        return @floatCast(node.getInfo().height * 72.0);
    }

    /// Convert uuid to 0-terminated name string for use in graphviz.
    ///
    /// Since graphviz uses u32 ids internall.y, we instead use the name to identify
    /// the nodes, and use the node's label property to set the label.
    pub fn idToName(id: u128, buf: *[33]u8) [:0]const u8 {
        return std.fmt.bufPrintZ(buf, "{x:0>32}", .{id}) catch unreachable;
    }

    /// Convert node hex string name back to a u128 id.
    pub fn nameToId(name: []const u8) !u128 {
        return std.fmt.parseInt(u128, name, 16);
    }

    pub fn edgeIterator(node: *const Node, graph: *const Graph) EdgeIterator {
        return .init(graph.g, node.cnode);
    }
};

pub const NodeIterator = struct {
    graph: *c.Agraph_t,
    next_node: ?*c.Agnode_t = null,

    pub fn init(graph: *c.Agraph_t) NodeIterator {
        return .{ .graph = graph, .next_node = c.agfstnode(graph) };
    }

    pub fn next(self: *NodeIterator) ?Node {
        if (self.next_node) |next_node| {
            self.next_node = c.agnxtnode(self.graph, next_node);
            return .{ .cnode = next_node };
        }
        return null;
    }
};

pub const Edge = struct {
    cedge: *c.Agedge_t,

    pub fn getInfo(edge: *const Edge) *c.Agedgeinfo_t {
        return edgeInfo(edge.cedge);
    }
};

pub const EdgeIterator = struct {
    graph: *c.Agraph_t,
    next_edge: ?*c.Agedge_t = null,

    pub fn init(graph: *c.Agraph_t, node: *c.Agnode_t) EdgeIterator {
        return .{ .graph = graph, .next_edge = c.agfstout(graph, node) };
    }

    pub fn next(self: *EdgeIterator) ?Edge {
        if (self.next_edge) |next_edge| {
            self.next_edge = c.agnxtout(self.graph, next_edge);
            return .{ .cedge = next_edge };
        }
        return null;
    }
};

pub const Graph = struct {
    /// Allocates when building the graph and resets when cleared.
    arena: std.heap.ArenaAllocator,
    gvc: *c.GVC_t,
    g: *c.Agraph_t,
    width: u32,
    height: u32,
    has_layout: bool = false,

    pub const Options = struct {
        width: ?u32 = null,
        height: ?u32 = null,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !Graph {
        const g = agopen(@constCast("graph"), Agdirected, null) orelse return error.OpenFailed;
        _ = c.agsafeset(g, @constCast("bgcolor"), @constCast("transparent"), @constCast(""));
        _ = c.agsafeset(g, @constCast("margin"), @constCast("0.0"), @constCast(""));
        _ = c.agsafeset(g, @constCast("pad"), @constCast("0.0"), @constCast(""));
        _ = c.agsafeset(g, @constCast("rankdir"), @constCast("LR"), @constCast("LR"));

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

    pub fn setAttribute(graph: *Graph, name: [:0]const u8, value: [:0]const u8, default: [:0]const u8) void {
        _ = c.agsafeset(graph.g, @constCast(name), @constCast(value), @constCast(default));
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
        if (graph.n_nodes() == 0) return .{
            .ll = .{ .x = 0, .y = 0 },
            .ur = .{ .x = 100, .y = 100 },
        };
        const info = graphInfo(graph.g);
        return .{
            .ll = .{
                .x = @floatCast(info.bb.LL.x),
                .y = @floatCast(info.bb.LL.y),
            },
            .ur = .{
                .x = @floatCast(info.bb.UR.x),
                .y = @floatCast(info.bb.UR.y),
            },
        };
    }

    pub fn nodeIterator(graph: *const Graph) NodeIterator {
        return .init(graph.g);
    }

    /// Remove all nodes and edges, and clear the layout.
    pub fn clear(graph: *Graph) void {
        defer _ = graph.arena.reset(.retain_capacity);

        if (graph.has_layout) {
            _ = c.gvFreeLayout(graph.gvc, graph.g);
            graph.has_layout = false;
        }

        var node_iter = graph.nodeIterator();
        while (node_iter.next()) |node| {
            _ = c.agdelete(graph.g, node.cnode);
        }
    }

    pub fn addNode(graph: *Graph, id: u128, label: []const u8) !void {
        var buf: [33]u8 = undefined;
        const name = Node.idToName(id, &buf);

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
    pub fn getNodeById(graph: *const Graph, id: u128) ?Node {
        var buf: [33]u8 = undefined;
        const name = Node.idToName(id, &buf);
        if (c.agnode(graph.g, @constCast(name), 0)) |cnode| {
            return .{ .cnode = cnode };
        }
        return null;
    }

    pub fn addEdge(graph: *const Graph, from: u128, to: u128) !void {
        const from_node = graph.getNodeById(from) orelse return error.NodeNotFound;
        const to_node = graph.getNodeById(to) orelse return error.NodeNotFound;
        _ = c.agedge(graph.g, from_node.cnode, to_node.cnode, null, 1) orelse return error.EdgeFailed;
    }

    /// Number of nodes in the graph
    pub fn n_nodes(graph: *const Graph) usize {
        return @intCast(c.agnnodes(graph.g));
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

    /// Find node on the given coordinates.
    pub fn getNodeAt(self: *const Graph, x: f32, y: f32) ?Node {
        var node_iter = self.nodeIterator();
        while (node_iter.next()) |node| {
            const pos = node.getPos();
            const height = node.getHeight();
            const radius = height * 0.25;
            const dx = x - pos.x;
            const dy = y - pos.y;
            if (dx * dx + dy * dy <= radius * radius) {
                return node;
            }
        }
        return null;
    }
};

// ** C autogen patches

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
