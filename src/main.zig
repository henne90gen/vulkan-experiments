const std = @import("std");
const zm = @import("zmath");

const glfw = @import("glfw.zig");
const vk = @import("vulkan.zig");
const bmp = @import("bitmap.zig");
const utils = @import("utils.zig");
const rd = @import("renderer.zig");

test {
    std.testing.refAllDeclsRecursive(@This());
}

const INITIAL_GEOMETRY_INSTANCE_COUNT = 1;

const WindowState = struct {
    allocator: std.mem.Allocator,
    geometry_instances: std.ArrayList(rd.GeometryInstance),
    zoom: f32,

    rotation: f32,

    pub fn deinit(self: *WindowState) void {
        self.geometry_instances.deinit(self.allocator);
    }
};

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}){};
    defer {
        const result = debug_allocator.deinit();
        switch (result) {
            std.heap.Check.leak => std.debug.print("Memory leak detected!\n", .{}),
            else => {},
        }
    }
    const allocator = debug_allocator.allocator();

    try glfw.init();
    defer glfw.terminate();

    const window = try glfw.createWindow(800, 600, "Hello World");
    defer glfw.destroyWindow(window);

    var window_state = WindowState{
        .allocator = allocator,
        .geometry_instances = std.ArrayList(rd.GeometryInstance).empty,
        .zoom = 0.1,
        .rotation = 0.0,
    };
    defer window_state.deinit();

    glfw.setWindowUserPointer(window, &window_state);
    glfw.setKeyCallback(window, keyCallback);
    glfw.setMouseButtonCallback(window, mouseButtonCallback);
    glfw.setScrollCallback(window, scrollCallback);

    var renderer = try rd.Renderer.init(allocator, window);
    defer renderer.deinit();

    const rectangle_vertex_data = [_]rd.Vertex{
        .{ .position = .{ 0.5, -0.5, 0.0 } },
        .{ .position = .{ -0.5, 0.5, 0.0 } },
        .{ .position = .{ 0.5, 0.5, 0.0 } },
        .{ .position = .{ 0.5, -0.5, 0.0 } },
        .{ .position = .{ -0.5, -0.5, 0.0 } },
        .{ .position = .{ -0.5, 0.5, 0.0 } },
    };
    const rectangle_buffer_size = @sizeOf(@TypeOf(rectangle_vertex_data[0])) * rectangle_vertex_data.len;
    const rectangle_vertex_buffer = try vk.createBuffer(&renderer.device, vk.c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, rectangle_buffer_size);
    defer vk.destroyBuffer(&renderer.device, rectangle_vertex_buffer);

    const rectangle_vertex_buffer_memory = try vk.createBufferMemory(&renderer.device, rectangle_vertex_buffer, vk.c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    defer vk.destroyBufferMemory(&renderer.device, rectangle_vertex_buffer_memory);

    try vk.mapMemory(&renderer.device, rectangle_vertex_buffer_memory, @ptrCast(&rectangle_vertex_data));

    var current_geometry_instance_count: usize = INITIAL_GEOMETRY_INSTANCE_COUNT;
    var instance_buffer_size = @sizeOf(rd.GeometryInstance) * current_geometry_instance_count;
    var instance_buffer = try vk.createBuffer(&renderer.device, vk.c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, instance_buffer_size);
    defer vk.destroyBuffer(&renderer.device, instance_buffer);

    var instance_buffer_memory = try vk.createBufferMemory(&renderer.device, instance_buffer, vk.c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    defer vk.destroyBufferMemory(&renderer.device, instance_buffer_memory);

    const per_frame_vk_data = try renderer.createPerFrameVkData();
    defer renderer.destroyPerFrameVkData(per_frame_vk_data);

    try window_state.geometry_instances.append(window_state.allocator, .{
        .geometry_type = 1,
        .rotation = window_state.rotation,
        .translation = [2]f32{ 0.0, 0.0 },
        .scale = [2]f32{ 1.0, 1.0 },
    });

    var current_frame: u32 = 0;
    while (!glfw.windowShouldClose(window)) {
        glfw.pollEvents();
        const start = std.time.nanoTimestamp();

        const new_framebuffer_size = glfw.getFramebufferSize(window);

        window_state.rotation += 0.01;

        const ubo = rd.UniformBufferObject{
            .aspect_ratio = @as(f32, @floatFromInt(new_framebuffer_size.width)) / @as(f32, @floatFromInt(new_framebuffer_size.height)),
            .zoom = window_state.zoom,
        };

        for (window_state.geometry_instances.items) |*geometry_instance| {
            geometry_instance.rotation += 0.01;
        }

        if (window_state.geometry_instances.items.len > current_geometry_instance_count) {
            _ = vk.c.vkDeviceWaitIdle(renderer.device.device);

            current_geometry_instance_count = window_state.geometry_instances.items.len;
            vk.destroyBufferMemory(&renderer.device, instance_buffer_memory);
            vk.destroyBuffer(&renderer.device, instance_buffer);
            instance_buffer_size = window_state.geometry_instances.items.len * @sizeOf(rd.GeometryInstance);
            instance_buffer = try vk.createBuffer(&renderer.device, vk.c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, instance_buffer_size);
            instance_buffer_memory = try vk.createBufferMemory(&renderer.device, instance_buffer, vk.c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        }
        try vk.mapMemory(&renderer.device, instance_buffer_memory, @ptrCast(window_state.geometry_instances.items));

        const vk_data = per_frame_vk_data[current_frame];
        try renderer.drawFrame(
            window,
            &vk_data,
            &ubo,
            rectangle_vertex_buffer,
            rectangle_vertex_data.len,
            instance_buffer,
            window_state.geometry_instances.items.len,
        );

        current_frame = (current_frame + 1) % @as(u32, @intCast(per_frame_vk_data.len));

        const end = std.time.nanoTimestamp();
        const frame_time_ns = end - start;
        const frame_time_ms = @as(f32, @floatFromInt(frame_time_ns)) / 1_000_000.0;
        const new_title = try std.fmt.allocPrintSentinel(allocator, "Vulkan - Frame time: {d:.2} ms - {d:.2} fps", .{ frame_time_ms, 1000.0 / frame_time_ms }, 0);
        defer allocator.free(new_title);
        glfw.setWindowTitle(window, new_title);

        const target_frame_time_ns: u64 = 16 * 1_000_000;
        if (frame_time_ns < target_frame_time_ns) {
            std.Thread.sleep(@intCast(target_frame_time_ns - frame_time_ns));
        }
    }

    const err = vk.c.vkDeviceWaitIdle(renderer.device.device);
    if (err != vk.c.VK_SUCCESS) {
        std.debug.print("Failed to wait for device idle: {s}\n", .{vk.c.string_VkResult(err)});
        return;
    }
}

export fn keyCallback(window: ?*glfw.c.GLFWwindow, key: i32, scancode: i32, action: i32, mods: i32) void {
    _ = scancode;
    _ = mods;
    if (window == null) {
        return;
    }

    var window_state = glfw.getWindowUserPointer(window.?, WindowState);
    if (window_state == null) {
        return;
    }

    if (key == glfw.c.GLFW_KEY_ESCAPE and action == glfw.c.GLFW_PRESS) {
        glfw.setWindowShouldClose(window.?, true);
    }

    if (key == glfw.c.GLFW_KEY_SPACE and action == glfw.c.GLFW_PRESS) {
        var prng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
        const rand = prng.random();
        const x = rand.float(f32);
        const y = rand.float(f32);
        window_state.?.geometry_instances.append(window_state.?.allocator, .{
            .geometry_type = 1,
            .rotation = window_state.?.rotation,
            .translation = [2]f32{ x, y },
            .scale = [2]f32{ 1.0, 1.0 },
        }) catch {
            std.debug.print("Failed to append geometry instance\n", .{});
        };
        std.debug.print("Geometry instance appended: {} rotation={}\n", .{ window_state.?.geometry_instances.items.len, window_state.?.rotation });
    }
}

export fn mouseButtonCallback(window: ?*glfw.c.GLFWwindow, button: i32, action: i32, mods: i32) void {
    _ = mods;
    if (window == null) {
        return;
    }

    var window_state = glfw.getWindowUserPointer(window.?, WindowState);
    if (window_state == null) {
        return;
    }

    if (button == glfw.c.GLFW_MOUSE_BUTTON_RIGHT and action == glfw.c.GLFW_PRESS) {
        const mousePosition = glfw.getMousePosition(window.?);
        const scaled = mapMousePositionToObjectSpace(window.?, window_state.?, mousePosition);
        window_state.?.geometry_instances.append(window_state.?.allocator, .{
            .geometry_type = 1,
            .rotation = window_state.?.rotation,
            .translation = [2]f32{ @floatCast(scaled[0]), @floatCast(scaled[1]) },
            .scale = [2]f32{ 1.0, 1.0 },
        }) catch {
            std.debug.print("Failed to append geometry instance\n", .{});
        };
        std.debug.print("Geometry instance appended: {} rotation={}\n", .{ window_state.?.geometry_instances.items.len, window_state.?.rotation });
    }
}

fn mapMousePositionToObjectSpace(window: *glfw.c.GLFWwindow, window_state: *WindowState, mousePosition: glfw.MousePosition) [2]f32 {
    const framebuffer_size = glfw.getFramebufferSize(window);
    const aspect_ratio = @as(f64, @floatFromInt(framebuffer_size.width)) / @as(f64, @floatFromInt(framebuffer_size.height));
    var scaled_x = (mousePosition.x / @as(f64, @floatFromInt(framebuffer_size.width))) * 2.0 - 1.0;
    var scaled_y = -((mousePosition.y / @as(f64, @floatFromInt(framebuffer_size.height))) * 2.0 - 1.0);

    scaled_x /= @as(f64, window_state.zoom);
    scaled_y /= @as(f64, window_state.zoom);

    if (aspect_ratio > 1.0) {
        scaled_x *= aspect_ratio;
    } else {
        scaled_y /= aspect_ratio;
    }
    return [2]f32{ @floatCast(scaled_x), @floatCast(scaled_y) };
}

export fn scrollCallback(window: ?*glfw.c.GLFWwindow, xoffset: f64, yoffset: f64) void {
    _ = xoffset;
    if (window == null) {
        return;
    }

    var window_state = glfw.getWindowUserPointer(window.?, WindowState);
    if (window_state == null) {
        return;
    }

    window_state.?.zoom *= @floatCast(1.0 + yoffset * 0.1);
    if (window_state.?.zoom < 0.01) {
        window_state.?.zoom = 0.01;
    }
    std.debug.print("Zoom: {d}\n", .{window_state.?.zoom});
}
