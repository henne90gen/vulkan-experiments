const std = @import("std");

const models = @import("models.zig");

const t = std.testing;
test "loads simple triangle model" {
    var allocator = std.heap.DebugAllocator(.{}){};
    defer _ = allocator.deinit();
    const gpa = allocator.allocator();

    const model = try models.Model.from_memory(gpa,
        \\v 0.0 -0.5 0.0
        \\v 0.5 0.5 0.0
        \\v -0.5 0.5 0.0
        \\vt 0.5 1.0
        \\vt 1.0 0.0
        \\vt 0.0 0.0
        \\vn 1.0 0.0 0.0
        \\vn 0.0 1.0 0.0
        \\vn 0.0 0.0 1.0
        \\f 1/1/1 2/2/2 3/3/3
    );
    defer model.deinit(gpa);

    try t.expectEqual(3, model.vertices.len);
    try t.expectEqual(0.0, model.vertices[0][0]);
    try t.expectEqual(-0.5, model.vertices[0][1]);
    try t.expectEqual(0.0, model.vertices[0][2]);
    try t.expectEqual(0.5, model.vertices[1][0]);
    try t.expectEqual(0.5, model.vertices[1][1]);
    try t.expectEqual(0.0, model.vertices[1][2]);
    try t.expectEqual(-0.5, model.vertices[2][0]);
    try t.expectEqual(0.5, model.vertices[2][1]);
    try t.expectEqual(0.0, model.vertices[2][2]);

    try t.expectEqual(3, model.texture_coordinates.len);
    try t.expectEqual(0.5, model.texture_coordinates[0][0]);
    try t.expectEqual(1.0, model.texture_coordinates[0][1]);
    try t.expectEqual(1.0, model.texture_coordinates[1][0]);
    try t.expectEqual(0.0, model.texture_coordinates[1][1]);
    try t.expectEqual(0.0, model.texture_coordinates[2][0]);
    try t.expectEqual(0.0, model.texture_coordinates[2][1]);

    try t.expectEqual(3, model.normals.len);
    try t.expectEqual(1.0, model.normals[0][0]);
    try t.expectEqual(0.0, model.normals[0][1]);
    try t.expectEqual(0.0, model.normals[0][2]);
    try t.expectEqual(0.0, model.normals[1][0]);
    try t.expectEqual(1.0, model.normals[1][1]);
    try t.expectEqual(0.0, model.normals[1][2]);
    try t.expectEqual(0.0, model.normals[2][0]);
    try t.expectEqual(0.0, model.normals[2][1]);
    try t.expectEqual(1.0, model.normals[2][2]);

    try t.expectEqual(1, model.faces.len);

    const data = try model.to_interleaved_data(gpa);
    defer gpa.free(data);
    try t.expectEqual(3, data.len);
}
