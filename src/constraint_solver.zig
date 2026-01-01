const std = @import("std");

pub const Node = struct {
    data: NodeData,
    metadata: NodeMetadata = .{},
};

pub const NodeMetadata = struct {
    label: []const u8 = "",
};

pub const NodeData = union(enum) {
    point: Point,
    line: struct { start: Point, end: Point },
};

pub const Point = struct { x: f32, y: f32 };

pub const Edge = union(enum) {
    distance_dimension: struct { distance: f32 },
    angle_dimension: struct { angle: f32 },
    parallel_constraint,
    perpendicular_constraint,
    coincidence_constraint,
};

pub const EdgeKey = struct {
    node_id_1: usize,
    node_id_2: usize,
};

pub const Solver = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(Node),
    edges: std.AutoHashMap(EdgeKey, Edge),

    pub fn init(allocator: std.mem.Allocator) Solver {
        return Solver{
            .allocator = allocator,
            .nodes = std.ArrayList(Node).empty,
            .edges = std.AutoHashMap(EdgeKey, Edge).init(allocator),
        };
    }

    pub fn deinit(self: *Solver, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);
        self.edges.deinit();
    }

    pub fn clear(self: *Solver) void {
        self.nodes.clearRetainingCapacity();
        self.edges.clearRetainingCapacity();
    }

    pub fn addPrimitive(self: *Solver, node: Node) !void {
        try self.nodes.append(self.allocator, node);
    }

    pub fn addConstraint(self: *Solver, node_id_1: usize, node_id_2: usize, edge: Edge) !void {
        try self.edges.put(.{ .node_id_1 = node_id_1, .node_id_2 = node_id_2 }, edge);
        try self.edges.put(.{ .node_id_1 = node_id_2, .node_id_2 = node_id_1 }, edge);
    }

    pub fn solve(self: *Solver) void {
        std.debug.print("Solving constraints\n", .{});
        std.debug.print("Nodes: {} Edges: {}\n", .{ self.nodes.items.len, self.edges.count() });
        std.debug.print("Solving constraints - Done\n", .{});
    }

    pub fn exportToDot(self: *Solver, allocator: std.mem.Allocator) ![]const u8 {
        var dot = std.ArrayList(u8).empty;
        defer dot.deinit(allocator);

        try dot.appendSlice(allocator, "graph G {\n");
        try dot.appendSlice(allocator, "    rankdir=LR;\n");

        for (self.nodes.items, 0..) |node, idx| {
            const label = if (node.metadata.label.len == 0) switch (node.data) {
                .point => try std.fmt.allocPrint(allocator, "Point ({d:.2},{d:.2})", .{ node.data.point.x, node.data.point.y }),
                .line => try std.fmt.allocPrint(allocator, "Line ({d:.2},{d:.2}) -> ({d:.2},{d:.2})", .{ node.data.line.start.x, node.data.line.start.y, node.data.line.end.x, node.data.line.end.y }),
            } else node.metadata.label;
            defer {
                if (node.metadata.label.len == 0) {
                    allocator.free(label);
                }
            }
            const text = try std.fmt.allocPrint(allocator, "    {d} [label=\"{s}\"];\n", .{ idx, label });
            defer allocator.free(text);
            try dot.appendSlice(allocator, text);
        }

        var itr = self.edges.iterator();
        while (itr.next()) |element| {
            const edge = element.value_ptr;
            const label = switch (edge.*) {
                .distance_dimension => "Distance",
                .angle_dimension => "Angle",
                .parallel_constraint => "Parallel",
                .perpendicular_constraint => "Perpendicular",
                .coincidence_constraint => "Coincidence",
            };
            const text = try std.fmt.allocPrint(
                allocator,
                "    {d} -- {d} [label=\"{s}\"];\n",
                .{ element.key_ptr.*.node_id_1, element.key_ptr.*.node_id_2, label },
            );
            defer allocator.free(text);
            try dot.appendSlice(allocator, text);
        }

        try dot.appendSlice(allocator, "}\n");
        return dot.toOwnedSlice(allocator);
    }
};
