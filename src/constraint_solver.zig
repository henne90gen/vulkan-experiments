const std = @import("std");

const Node = union(enum) {
    Point,
    Line,
};

const Edge = union(enum) {
    DistanceDimension: struct { distance: f32 },
    AngleDimension: struct { angle: f32 },
    ParallelConstraint,
    PerpendicularConstraint,
    CoincidenceConstraint,
};

pub const Solver = struct {
    nodes: std.ArrayList(Node),
    edges: std.AutoHashMap(u64, Edge),

    pub fn init(allocator: std.mem.Allocator) Solver {
        return Solver{
            .nodes = std.ArrayList(Node).empty,
            .edges = std.AutoHashMap(u64, Edge).init(allocator),
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
};
