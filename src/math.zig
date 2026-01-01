const glfw = @import("glfw.zig");
const zm = @import("zmath");

pub fn rectangleContainsPoint(rect_position: [2]f32, rect_size: [2]f32, point: [2]f32) bool {
    const half_size = [2]f32{ rect_size[0] * 0.5, rect_size[1] * 0.5 };
    const min_x = rect_position[0] - half_size[0];
    const max_x = rect_position[0] + half_size[0];
    const min_y = rect_position[1] - half_size[1];
    const max_y = rect_position[1] + half_size[1];

    return point[0] >= min_x and point[0] <= max_x and point[1] >= min_y and point[1] <= max_y;
}

pub fn circleContainsPoint(circle_center: [2]f32, circle_radius: f32, point: [2]f32) bool {
    const distance_squared = zm.lengthSq2(zm.loadArr2(point) - zm.loadArr2(circle_center));
    return distance_squared[0] <= circle_radius * circle_radius;
}

pub fn mapMousePositionToObjectSpace(window: *glfw.c.GLFWwindow, zoom: f32, mousePosition: glfw.MousePosition, offset: [2]f32) [2]f32 {
    var scaled = mapMousePositionToScreenSpace(window, zoom, mousePosition);

    scaled[0] -= offset[0];
    scaled[1] -= offset[1];

    return scaled;
}

pub fn mapMousePositionToScreenSpace(window: *glfw.c.GLFWwindow, zoom: f32, mousePosition: glfw.MousePosition) [2]f32 {
    const framebuffer_size = glfw.getFramebufferSize(window);
    const framebuffer_size_vec = zm.f32x4(@floatFromInt(framebuffer_size.width), @floatFromInt(framebuffer_size.height), 0.0, 0.0);

    var scaled = zm.f32x4(@floatCast(mousePosition.x), @floatCast(mousePosition.y), 0.0, 0.0);
    scaled /= framebuffer_size_vec;
    scaled *= zm.splat(zm.F32x4, 2.0);
    scaled -= zm.splat(zm.F32x4, 1.0);
    scaled *= zm.f32x4(1.0, -1.0, 0.0, 0.0);
    scaled /= zm.splat(zm.F32x4, zoom);

    const aspect_ratio = @as(f64, @floatFromInt(framebuffer_size.width)) / @as(f64, @floatFromInt(framebuffer_size.height));
    if (aspect_ratio > 1.0) {
        scaled[0] *= @floatCast(aspect_ratio);
    } else {
        scaled[1] /= @floatCast(aspect_ratio);
    }

    return [2]f32{ scaled[0], scaled[1] };
}
