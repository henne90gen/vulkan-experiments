const std = @import("std");

pub const Bitmap = struct {
    width: usize,
    height: usize,
    pixels: []const u8, // RGBA format

    pub fn from_memory(gpa: std.mem.Allocator, file_content: []const u8) !Bitmap {
        const header: *const Header = @ptrCast(@alignCast(&file_content[0]));
        const bitmap_info: *const BitmapInfoHeader = @ptrCast(@alignCast(&file_content[@sizeOf(Header)]));
        if (bitmap_info.header_size != @sizeOf(BitmapInfoHeader)) {
            return error.UnsupportedBitmapFormat;
        }

        if (bitmap_info.bits_per_pixel != 24) {
            return error.UnsupportedColorFormat;
        }

        const bytes_per_pixel = bitmap_info.bits_per_pixel / 8;
        const pixels = try gpa.alloc(u8, @intCast(bytes_per_pixel * bitmap_info.width * bitmap_info.height));

        const row_size = @divFloor(bitmap_info.width * bitmap_info.bits_per_pixel + 31, 32) * 4;
        for (0..@intCast(bitmap_info.height)) |row| {
            for (0..@intCast(bitmap_info.width)) |col| {
                for (0..bytes_per_pixel) |bpp_idx| {
                    const data_offset: i32 = @intCast(header.data_offset);
                    const row_: i32 = @intCast(row);
                    const col_: i32 = @intCast(col);
                    const bpp_idx_: i32 = @intCast(bpp_idx);
                    const src_idx = data_offset + row_ * row_size + col_ * bytes_per_pixel + bpp_idx_;
                    const dst_idx = row_ * bitmap_info.width * bytes_per_pixel + col_ * bytes_per_pixel + bpp_idx_;
                    pixels[@intCast(dst_idx)] = file_content[@intCast(src_idx)];
                }
            }
        }

        return Bitmap{
            .width = @intCast(bitmap_info.width),
            .height = @intCast(bitmap_info.height),
            .pixels = pixels,
        };
    }

    pub fn deinit(self: *const Bitmap, gpa: std.mem.Allocator) void {
        gpa.free(self.pixels);
    }
};

const Header = MemoryMappedStruct(struct {
    signature: u16,
    file_size: u32,
    reserved: u32,
    data_offset: u32,
});

const BitmapInfoHeader = MemoryMappedStruct(struct {
    header_size: u32,
    width: i32,
    height: i32,
    planes: u16,
    bits_per_pixel: u16,
    compression: u32,
    image_size: u32,
    x_pixels_per_meter: i32,
    y_pixels_per_meter: i32,
    colors_used: u32,
    important_colors: u32,
});

fn MemoryMappedStruct(comptime T: type) type {
    const info = @typeInfo(T);

    if (info.@"struct".decls.len != 0) {
        @compileError("MemoryMappedStruct does not support structs with declarations (such as functions)");
    }

    var fields = [_]std.builtin.Type.StructField{.{
        .name = "",
        .type = T,
        .default_value_ptr = null,
        .is_comptime = false,
        .alignment = 1,
    }} ** info.@"struct".fields.len;

    for (0..info.@"struct".fields.len) |i| {
        fields[i] = .{
            .alignment = 1,
            .name = info.@"struct".fields[i].name,
            .type = info.@"struct".fields[i].type,
            .default_value_ptr = info.@"struct".fields[i].default_value_ptr,
            .is_comptime = info.@"struct".fields[i].is_comptime,
        };
    }

    return @Type(.{
        .@"struct" = .{
            .is_tuple = info.@"struct".is_tuple,
            .layout = .@"extern",
            .fields = &fields,
            .decls = &.{},
        },
    });
}

const t = std.testing;
test "load bmp file from memory" {
    const image_data = @embedFile("assets/greenland_grid_velo.bmp");
    const bmp = try Bitmap.from_memory(t.allocator, image_data);
    defer bmp.deinit(t.allocator);

    try t.expectEqual(762, bmp.width);
    try t.expectEqual(1309, bmp.height);
    try t.expectEqual(2992374, bmp.pixels.len);
    try t.expectEqual(0xFF, bmp.pixels[0]); // B
    try t.expectEqual(0xFF, bmp.pixels[1]); // G
    try t.expectEqual(0xFF, bmp.pixels[2]); // R
}
