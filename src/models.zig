const std = @import("std");

const vk = @import("vulkan.zig");

test {
    _ = @import("models_test.zig");
}

const Face = struct {
    vertices: []i32,
    texture_coordinates: []i32,
    normals: []i32,

    pub fn deinit(self: *const Face, gpa: std.mem.Allocator) void {
        gpa.free(self.vertices);
        gpa.free(self.texture_coordinates);
        gpa.free(self.normals);
    }
};

pub const Vertex = struct {
    position: [4]f32,
    texture_coordinate: [3]f32,
    normal: [3]f32,
};

pub const Model = struct {
    vertices: [][4]f32,
    texture_coordinates: [][3]f32,
    normals: [][3]f32,
    faces: []Face,

    pub fn from_memory(gpa: std.mem.Allocator, file_content: []const u8) !Model {
        var vertices = std.ArrayList([4]f32).empty;
        errdefer vertices.deinit(gpa);
        var texture_coordinates = std.ArrayList([3]f32).empty;
        errdefer texture_coordinates.deinit(gpa);
        var normals = std.ArrayList([3]f32).empty;
        errdefer normals.deinit(gpa);
        var faces = std.ArrayList(Face).empty;
        errdefer faces.deinit(gpa);

        var last_line_start: usize = 0;
        for (0..file_content.len) |i| {
            if (file_content[i] != '\n' and i != file_content.len - 1) {
                continue;
            }

            var idx = i;
            if (file_content[idx] != '\n') {
                idx += 1;
            }

            var line = file_content[last_line_start..idx];
            if (line.len < 3) {
                continue;
            }

            if (line[line.len - 1] == '\r') {
                line = line[0 .. line.len - 1];
            }

            if (std.mem.eql(u8, "v ", line[0..2])) {
                var coordinates = [_]f32{1.0} ** 4;
                var local_idx: usize = 2;
                coordinates[0] = try parseFloat(line, &local_idx);
                coordinates[1] = try parseFloat(line, &local_idx);
                coordinates[2] = try parseFloat(line, &local_idx);
                if (local_idx < line.len) {
                    coordinates[3] = try parseFloat(line, &local_idx);
                }
                try vertices.append(gpa, coordinates);
            }

            if (std.mem.eql(u8, "vt ", line[0..3])) {
                var coordinates = [_]f32{0} ** 3;
                var local_idx: usize = 3;
                coordinates[0] = try parseFloat(line, &local_idx);
                if (local_idx < line.len) {
                    coordinates[1] = try parseFloat(line, &local_idx);
                }
                if (local_idx < line.len) {
                    coordinates[2] = try parseFloat(line, &local_idx);
                }
                try texture_coordinates.append(gpa, coordinates);
            }

            if (std.mem.eql(u8, "vn ", line[0..3])) {
                var coordinates = [_]f32{0} ** 3;
                var local_idx: usize = 3;
                coordinates[0] = try parseFloat(line, &local_idx);
                coordinates[1] = try parseFloat(line, &local_idx);
                coordinates[2] = try parseFloat(line, &local_idx);
                try normals.append(gpa, coordinates);
            }

            if (std.mem.eql(u8, "f ", line[0..2])) {
                var local_idx: usize = 2;
                var vertex_indices = std.ArrayList(i32).empty;
                errdefer vertex_indices.deinit(gpa);
                var texture_coordinate_indices = std.ArrayList(i32).empty;
                errdefer texture_coordinate_indices.deinit(gpa);
                var normal_indices = std.ArrayList(i32).empty;
                errdefer normal_indices.deinit(gpa);
                while (local_idx < line.len and line[local_idx] != '\n') {
                    const v_idx = try parseInt(line, &local_idx);
                    local_idx += 1; // skip '/'
                    const tc_idx = try parseInt(line, &local_idx);
                    local_idx += 1; // skip '/'
                    const n_idx = try parseInt(line, &local_idx);
                    local_idx += 1; // skip ' '

                    try vertex_indices.append(gpa, v_idx - 1);
                    try texture_coordinate_indices.append(gpa, tc_idx - 1);
                    try normal_indices.append(gpa, n_idx - 1);
                }
                try faces.append(gpa, .{
                    .vertices = try vertex_indices.toOwnedSlice(gpa),
                    .texture_coordinates = try texture_coordinate_indices.toOwnedSlice(gpa),
                    .normals = try normal_indices.toOwnedSlice(gpa),
                });
            }

            last_line_start = idx + 1;
        }

        return .{
            .vertices = try vertices.toOwnedSlice(gpa),
            .texture_coordinates = try texture_coordinates.toOwnedSlice(gpa),
            .normals = try normals.toOwnedSlice(gpa),
            .faces = try faces.toOwnedSlice(gpa),
        };
    }

    pub fn from_file(gpa: std.mem.Allocator, file_path: []const u8) !Model {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();
        const file_content = try file.readToEndAlloc(gpa, 8192);
        return from_memory(gpa, file_content);
    }

    pub fn deinit(self: *const Model, gpa: std.mem.Allocator) void {
        gpa.free(self.vertices);
        gpa.free(self.texture_coordinates);
        gpa.free(self.normals);
        for (self.faces) |face| {
            face.deinit(gpa);
        }
        gpa.free(self.faces);
    }

    pub fn to_interleaved_data(self: *const Model, gpa: std.mem.Allocator) ![]Vertex {
        var vertex_count: usize = 0;
        for (self.faces) |face| {
            vertex_count += face.vertices.len;
        }

        var interleaved = try std.ArrayList(Vertex).initCapacity(gpa, vertex_count);
        errdefer interleaved.deinit(gpa);

        for (self.faces) |face| {
            for (face.vertices, face.texture_coordinates, face.normals) |v_idx, tc_idx, n_idx| {
                const vertex = self.vertices[@intCast(v_idx)];
                const texture_coordinate = self.texture_coordinates[@intCast(tc_idx)];
                const normal = self.normals[@intCast(n_idx)];
                try interleaved.append(gpa, .{
                    .position = vertex,
                    .texture_coordinate = texture_coordinate,
                    .normal = normal,
                });
            }
        }

        return interleaved.toOwnedSlice(gpa);
    }

    pub fn vertex_description(_: *const Model) vk.VertexDescription {
        const stride = @sizeOf(f32) * 10;
        return .{
            .binding_descriptions = &[_]vk.c.VkVertexInputBindingDescription{
                .{
                    .binding = 0,
                    .stride = stride,
                    .inputRate = vk.c.VK_VERTEX_INPUT_RATE_VERTEX,
                },
            },
            .attribute_descriptions = &[_]vk.c.VkVertexInputAttributeDescription{
                .{
                    .binding = 0,
                    .location = 0,
                    .format = vk.c.VK_FORMAT_R32G32B32A32_SFLOAT,
                    .offset = @offsetOf(Vertex, "position"),
                },
                .{
                    .binding = 0,
                    .location = 1,
                    .format = vk.c.VK_FORMAT_R32G32B32_SFLOAT,
                    .offset = @offsetOf(Vertex, "texture_coordinate"),
                },
                .{
                    .binding = 0,
                    .location = 2,
                    .format = vk.c.VK_FORMAT_R32G32B32_SFLOAT,
                    .offset = @offsetOf(Vertex, "normal"),
                },
            },
        };
    }
};

fn parseFloat(l: []const u8, index: *usize) !f32 {
    const start = index.*;
    while (index.* < l.len and (l[index.*] != ' ' and l[index.*] != '\n')) {
        index.* += 1;
    }
    const float_str = l[start..index.*];
    const result = try std.fmt.parseFloat(f32, float_str);
    index.* += 1;
    return result;
}

fn parseInt(l: []const u8, index: *usize) !i32 {
    const start = index.*;
    while (index.* < l.len and (l[index.*] != ' ' and l[index.*] != '\n' and l[index.*] != '/')) {
        index.* += 1;
    }
    const float_str = l[start..index.*];
    return try std.fmt.parseInt(i32, float_str, 10);
}
