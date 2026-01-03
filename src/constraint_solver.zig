const std = @import("std");

pub const Node = struct {
    id: usize,
    data: NodeData,
    metadata: NodeMetadata = .{},
};

pub const NodeMetadata = struct {
    label: []const u8 = "",
};

pub const NodeData = union(enum) {
    point: struct {
        input: Point,
        result: ?Point = null,
    },
    line: struct {
        input_start: Point,
        input_end: Point,
        result_closest_to_origin: ?Point = null,
    },
};

pub const Point = struct { x: f32, y: f32 };

pub const Edge = union(enum) {
    distance_dimension: struct { distance: f32 },
    angle_dimension: struct { angle: f32 },
    parallel_constraint,
    perpendicular_constraint,
    coincidence_constraint,
    anchor_constraint,
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
        if (node_id_1 < node_id_2) {
            try self.edges.put(.{ .node_id_1 = node_id_1, .node_id_2 = node_id_2 }, edge);
        } else {
            try self.edges.put(.{ .node_id_1 = node_id_2, .node_id_2 = node_id_1 }, edge);
        }
    }

    fn getConstraint(self: *Solver, node_id_1: usize, node_id_2: usize) ?Edge {
        if (node_id_1 < node_id_2) {
            return self.edges.get(.{ .node_id_1 = node_id_1, .node_id_2 = node_id_2 });
        } else {
            return self.edges.get(.{ .node_id_1 = node_id_2, .node_id_2 = node_id_1 });
        }
    }

    pub fn solve(self: *Solver) !void {
        std.debug.print("Solving constraints\n", .{});
        std.debug.print("Nodes: {} Edges: {}\n", .{ self.nodes.items.len, self.edges.count() });

        const start_time = std.time.nanoTimestamp();

        // process anchor constraints
        var edge_itr = self.edges.iterator();
        while (edge_itr.next()) |edge| {
            switch (edge.value_ptr.*) {
                .anchor_constraint => {
                    var node = self.nodes.items[edge.key_ptr.*.node_id_1];
                    switch (node.data) {
                        .point => |*p| p.result = p.input,
                        .line => |*l| l.result_closest_to_origin = lineConvertToClosestToOrigin(l.input_start, l.input_end),
                    }
                    std.debug.print("applying anchor node: {} {}\n", .{node.id, node.data});
                },
                else => {},
            }
        }


        var adjacency_map = try AdjacencyMap.init(self.allocator, &self.nodes, &self.edges);
        defer adjacency_map.deinit(self.allocator);

        var changed = true;
        while(changed) {
            changed = false;
            for (self.nodes.items) | *node| {
                std.debug.print("looking at node: {}\n", .{node.id});
                const neighbors = adjacency_map.backing_map.get(node.id);
                if (neighbors == null) {
                    continue;
                }

                const degrees_of_freedom: usize = switch (node.data) {
                    .point => 2,
                    .line => 2,
                };

                const known_neighbors: usize = 0;
                for (neighbors.?.items)|neighbor| {
                    std.debug.print("  neighbor: {}\n", .{neighbor.id});


                }

                if (known_neighbors < degrees_of_freedom) {
                    std.debug.print("  not all neighbors are fully known\n", .{});
                    continue;
                }

                std.debug.print("  all neighbors are fully known\n", .{});
            }
        }

        const end_time = std.time.nanoTimestamp();
        const time_ns = end_time - start_time;
        const time_ms = @as(f32, @floatFromInt(time_ns)) / 1_000_000.0;
        std.debug.print("Time taken: {d:.2}ms\n", .{time_ms});
        std.debug.print("Solving constraints - Done\n", .{});
    }

    pub fn exportToDot(self: *Solver, allocator: std.mem.Allocator) ![]const u8 {
        var dot = std.ArrayList(u8).empty;
        defer dot.deinit(allocator);

        try dot.appendSlice(allocator, "graph G {\n");
        try dot.appendSlice(allocator, "    rankdir=LR;\n");

        for (self.nodes.items, 0..) |node, idx| {
            const label = if (node.metadata.label.len == 0) switch (node.data) {
                .point => |point| try std.fmt.allocPrint(allocator, "Point {d} ({d:.2},{d:.2})", .{ node.id, point.input.x, point.input.y }),
                .line => |line| try std.fmt.allocPrint(allocator, "Line {d} ({d:.2},{d:.2}) -> ({d:.2},{d:.2})", .{ node.id, line.input_start.x, line.input_start.y, line.input_end.x, line.input_end.y }),
            } else try std.fmt.allocPrint(allocator, "{s} {d}", .{ node.metadata.label, node.id });
            defer allocator.free(label);

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
                .anchor_constraint => "Anchor",
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

const AdjacencyMap = struct {
    backing_map: std.AutoHashMap(usize, std.ArrayList(*Node)),

    pub fn init(allocator: std.mem.Allocator, nodes: *const std.ArrayList(Node), edges: *const std.AutoHashMap(EdgeKey, Edge)) !AdjacencyMap {
        var result = AdjacencyMap{
            .backing_map = std.AutoHashMap(usize, std.ArrayList(*Node)).init(allocator),
        };

        var edge_itr = edges.keyIterator();
        while (edge_itr.next()) |edge| {
            const node_id_1 = edge.node_id_1;
            const node_id_2 = edge.node_id_2;

            var node_list_1 = try result.backing_map.getOrPut(node_id_1);
            if (!node_list_1.found_existing) {
                node_list_1.value_ptr.* = std.ArrayList(*Node).empty;
            }
            try node_list_1.value_ptr.append(allocator, &nodes.items[node_id_2]);

            if (node_id_1 == node_id_2) {
                continue;
            }

            var node_list_2 = try result.backing_map.getOrPut(node_id_2);
            if (!node_list_2.found_existing) {
                node_list_2.value_ptr.* = std.ArrayList(*Node).empty;
            }
            try node_list_2.value_ptr.append(allocator, &nodes.items[node_id_1]);
        }

        var itr = result.backing_map.iterator();
        while (itr.next()) |element| {
            std.debug.print("Node: {} Adjacent Nodes: ", .{element.key_ptr.*});
            for (element.value_ptr.items) |node| {
                std.debug.print("{} ", .{node.id});
            }
            std.debug.print("\n", .{});
        }

        return result;
    }

    pub fn deinit(self: *AdjacencyMap, allocator: std.mem.Allocator) void {
        var itr = self.backing_map.valueIterator();
        while (itr.next()) |node_list| {
            node_list.deinit(allocator);
        }
        self.backing_map.deinit();
    }
};

pub fn lineConvertToClosestToOrigin(start: Point, end: Point) Point {
    _ = start;
    _ = end;
    // TODO find point the is closest to the line given by it's start and end points
    return Point{ .x = 0.0, .y = 0.0 };
}
