const std = @import("std");

const utils = @import("utils.zig");

pub const Bitmap = struct {
    width: usize,
    height: usize,
    bytes_per_pixel: usize,
    pixels: []const u8, // RGBA format

    pub fn from_memory(gpa: std.mem.Allocator, file_content: []const u8) !Bitmap {
        const header: *const Header = @ptrCast(@alignCast(&file_content[0]));
        const bitmap_info: *const BitmapInfoHeader = @ptrCast(@alignCast(&file_content[@sizeOf(Header)]));
        const src_bytes_per_pixel = bitmap_info.bits_per_pixel / 8;
        const dst_bytes_per_pixel = 4;
        const pixels = try gpa.alloc(u8, @intCast(dst_bytes_per_pixel * bitmap_info.width * bitmap_info.height));
        errdefer gpa.free(pixels);

        var color_table: [4]i32 = undefined;
        if (bitmap_info.bits_per_pixel == 24) {
            color_table = [_]i32{ 2, 1, 0, 0 };
        } else if (bitmap_info.bits_per_pixel == 32) {
            color_table = [_]i32{ 2, 1, 0, 3 };
        } else {
            std.debug.print("Unsupported color format: {}\n", .{bitmap_info.bits_per_pixel});
            return error.UnsupportedColorFormat;
        }

        const row_size = @divFloor(bitmap_info.width * bitmap_info.bits_per_pixel + 31, 32) * 4;
        for (0..@intCast(bitmap_info.height)) |row| {
            for (0..@intCast(bitmap_info.width)) |col| {
                const row_: i32 = @intCast(row);
                const col_: i32 = @intCast(col);
                for (0..src_bytes_per_pixel) |bpp_idx| {
                    const data_offset: i32 = @intCast(header.data_offset);
                    const bpp_idx_: i32 = @intCast(bpp_idx);
                    const src_idx = data_offset + row_ * row_size + col_ * src_bytes_per_pixel + bpp_idx_;
                    const dst_idx = (bitmap_info.height - row_ - 1) * bitmap_info.width * dst_bytes_per_pixel + col_ * dst_bytes_per_pixel + color_table[@intCast(bpp_idx_)];
                    pixels[@intCast(dst_idx)] = file_content[@intCast(src_idx)];
                }

                if (src_bytes_per_pixel == 3) {
                    const dst_idx = row_ * bitmap_info.width * dst_bytes_per_pixel + col_ * dst_bytes_per_pixel + 3;
                    pixels[@intCast(dst_idx)] = 255;
                }
            }
        }

        return Bitmap{
            .width = @intCast(bitmap_info.width),
            .height = @intCast(bitmap_info.height),
            .bytes_per_pixel = dst_bytes_per_pixel,
            .pixels = pixels,
        };
    }

    pub fn deinit(self: *const Bitmap, gpa: std.mem.Allocator) void {
        gpa.free(self.pixels);
    }
};

const Header = utils.MemoryMappedStruct(struct {
    signature: u16,
    file_size: u32,
    reserved: u32,
    data_offset: u32,
});

const BitmapInfoHeader = utils.MemoryMappedStruct(struct {
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

const t = std.testing;
test "load bmp file from memory" {
    const image_data = @embedFile("assets/icons_set_128x128.bmp");
    const bmp = try Bitmap.from_memory(t.allocator, image_data);
    defer bmp.deinit(t.allocator);

    try t.expectEqual(640, bmp.width);
    try t.expectEqual(640, bmp.height);
    try t.expectEqual(1638400, bmp.pixels.len);
    try t.expectEqual(0, bmp.pixels[0]); // R
    try t.expectEqual(0, bmp.pixels[1]); // G
    try t.expectEqual(0, bmp.pixels[2]); // B
    try t.expectEqual(0, bmp.pixels[3]); // A
}
