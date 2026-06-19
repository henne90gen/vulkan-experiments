const std = @import("std");

const models = @import("models.zig");

const t = std.testing;
test "loads simple triangle model" {
    try std.testing.expect(false);

    const model = try models.Model.from_memory(t.allocator,
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
    defer model.deinit(t.allocator);

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

    const data = try model.to_interleaved_data(t.allocator);
    defer t.allocator.free(data);
    try t.expectEqual(3, data.len);
}

test "loads suzanne.obj" {
    const suzanne = @embedFile("assets/suzanne.obj");
    const model = try models.Model.from_memory(t.allocator, suzanne);
    defer model.deinit(t.allocator);

    try t.expectEqual(511, model.vertices.len);
    try t.expectEqual(0.4375, model.vertices[0][0]);
    try t.expectEqual(0.164063, model.vertices[0][1]);
    try t.expectEqual(0.765625, model.vertices[0][2]);
    try t.expectEqual(1.0, model.vertices[0][3]);

    try t.expectEqual(590, model.texture_coordinates.len);
    try t.expectEqual(0.315596, model.texture_coordinates[0][0]);
    try t.expectEqual(0.792535, model.texture_coordinates[0][1]);
    try t.expectEqual(0.0, model.texture_coordinates[0][2]);

    try t.expectEqual(507, model.normals.len);
    try t.expectEqual(0.189764, model.normals[0][0]);
    try t.expectEqual(-0.003571, model.normals[0][1]);
    try t.expectEqual(0.981811, model.normals[0][2]);

    try t.expectEqual(968, model.faces.len);

    const data = try model.to_interleaved_data(t.allocator);
    defer t.allocator.free(data);
    try t.expectEqual(2904, data.len);
}
