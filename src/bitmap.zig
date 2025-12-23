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

        if (bitmap_info.bits_per_pixel % 8 != 0) {
            return error.BitsPerPixelNotByteAligned;
        }

        const bytes_per_pixel = bitmap_info.bits_per_pixel / 8;
        const pixels = try gpa.alloc(u8, @intCast(bytes_per_pixel * bitmap_info.width * bitmap_info.height));

        const row_size = @divFloor(bitmap_info.width * bitmap_info.bits_per_pixel + 31, 32) * 4;
        for (0..@intCast(bitmap_info.height)) |row| {
            for (0..@intCast(bitmap_info.width)) |col| {
                for (0..bitmap_info.bits_per_pixel / 8) |bpp_idx| {
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

const Header = extern struct {
    signature: u16 align(1),
    file_size: u32 align(1),
    reserved: u32 align(1),
    data_offset: u32 align(1),
};

const BitmapInfoHeader = extern struct {
    header_size: u32 align(1),
    width: i32 align(1),
    height: i32 align(1),
    planes: u16 align(1),
    bits_per_pixel: u16 align(1),
    compression: u32 align(1),
    image_size: u32 align(1),
    x_pixels_per_meter: i32 align(1),
    y_pixels_per_meter: i32 align(1),
    colors_used: u32 align(1),
    important_colors: u32 align(1),
};

const t = std.testing;
test "load bmp file from memory" {
    const image_data = @embedFile("assets/greenland_grid_velo.bmp");
    const bmp = try Bitmap.from_memory(t.allocator, image_data);
    defer bmp.deinit(t.allocator);

    try t.expectEqual(762, bmp.width);
    try t.expectEqual(1309, bmp.height);
    try t.expectEqual(0xFF, bmp.pixels[0]); // B
    try t.expectEqual(0xFF, bmp.pixels[1]); // G
    try t.expectEqual(0xFF, bmp.pixels[2]); // R
}
