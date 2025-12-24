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
