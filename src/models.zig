const std = @import("std");

pub const Model = struct {
    vertices: [][3]f32,
    texture_coordinates: [][2]f32,
    normals: [][3]f32,
    indices: []i32,

    pub fn from_memory(gpa: std.mem.Allocator, file_content: []const u8) !Model {
        var vertices = std.ArrayList([3]f32).empty;
        var texture_coordinates = std.ArrayList([2]f32).empty;
        var normals = std.ArrayList([3]f32).empty;
        var indices = std.ArrayList(i32).empty;

        var last_line_start: usize = 0;
        for (0..file_content.len) |i| {
            if (file_content[i] != '\n' and i != file_content.len - 1) {
                continue;
            }

            var idx = i;
            if (file_content[idx] != '\n') {
                idx += 1;
            }

            const line = file_content[last_line_start..idx];
            if (line.len < 3) {
                continue;
            }

            std.debug.print("{s}\n", .{line});

            if (std.mem.eql(u8, "v ", line[0..2])) {
                const coordiantes = [_]f32{0} ** 3;
                // TODO parse coordinates
                try vertices.append(gpa, coordiantes);
            }

            if (std.mem.eql(u8, "vt ", line[0..3])) {
                const coordiantes = [_]f32{0} ** 2;
                // TODO parse coordinates
                try texture_coordinates.append(gpa, coordiantes);
            }

            if (std.mem.eql(u8, "n ", line[0..2])) {
                const coordiantes = [_]f32{0} ** 3;
                // TODO parse coordinates
                try normals.append(gpa, coordiantes);
            }

            last_line_start = idx + 1;
        }

        return .{
            .vertices = try vertices.toOwnedSlice(gpa),
            .texture_coordinates = try texture_coordinates.toOwnedSlice(gpa),
            .normals = try normals.toOwnedSlice(gpa),
            .indices = try indices.toOwnedSlice(gpa),
        };
    }

    pub fn from_file(_: []const u8) !Model {
        return error.TODO;
    }

    pub fn deinit(self: *const Model, gpa: std.mem.Allocator) void {
        gpa.free(self.vertices);
        gpa.free(self.texture_coordinates);
        gpa.free(self.normals);
        gpa.free(self.indices);
    }
};

const t = std.testing;
test "loads simple triangle model" {
    var allocator = std.heap.DebugAllocator(.{}){};
    defer _ = allocator.deinit();
    const gpa = allocator.allocator();

    const model = try Model.from_memory(gpa,
        \\v 0.0 -0.5 0
        \\v 0.5 0.5 0
        \\v -0.5 0.5 0
    );
    defer model.deinit(gpa);
    try t.expectEqual(3, model.vertices.len);
}
