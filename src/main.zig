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

const WindowState = struct {
    allocator: std.mem.Allocator,
    zoom: f32,
    center: [2]f32 = .{ 0.0, 0.0 },

    primitives: std.ArrayList(Primitive),

    mode: union(enum) {
        navigation: NavigationData,
        creating_point,
        creating_line: LineCreationData,
    } = .{ .navigation = .{} },

    pub fn deinit(self: *WindowState) void {
        self.primitives.deinit(self.allocator);
    }
};

const LineCreationData = struct {
    start: ?[2]f32 = null,
};

const NavigationData = struct {
    left_mouse_button_down: bool = false,
};

const Primitive = union(enum) {
    point: [2]f32,
    line: struct {
        start: [2]f32,
        end: [2]f32,
    },
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
        .zoom = 0.1,
        .primitives = std.ArrayList(Primitive).empty,
    };
    defer window_state.deinit();

    glfw.setWindowUserPointer(window, &window_state);
    glfw.setKeyCallback(window, keyCallback);
    glfw.setMouseButtonCallback(window, mouseButtonCallback);
    glfw.setScrollCallback(window, scrollCallback);
    glfw.setCursorPosCallback(window, cursorPosCallback);

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

    var instance_buffer = try rd.InstanceBuffer.init(&renderer.device);
    defer instance_buffer.deinit();

    const per_frame_vk_data = try renderer.createPerFrameVkData();
    defer renderer.destroyPerFrameVkData(per_frame_vk_data);

    var geometry_instances = std.ArrayList(rd.GeometryInstance).empty;
    defer geometry_instances.deinit(allocator);
    var current_frame: u32 = 0;
    while (!glfw.windowShouldClose(window)) {
        glfw.pollEvents();
        const start_time = std.time.nanoTimestamp();

        const new_framebuffer_size = glfw.getFramebufferSize(window);

        const ubo = rd.UniformBufferObject{
            .aspect_ratio = @as(f32, @floatFromInt(new_framebuffer_size.width)) / @as(f32, @floatFromInt(new_framebuffer_size.height)),
            .zoom = window_state.zoom,
            .offset = window_state.center,
        };

        geometry_instances.clearRetainingCapacity();
        for (window_state.primitives.items) |primitive| {
            switch (primitive) {
                .point => |point| {
                    try geometry_instances.append(allocator, .{
                        .geometry_type = 0,
                        .rotation = 0.0,
                        .translation = point,
                        .scale = [2]f32{ 1.0, 1.0 },
                    });
                },
                .line => |line| {
                    const sx = line.start[0];
                    const sy = line.start[1];
                    const ex = line.end[0];
                    const ey = line.end[1];
                    const distance = zm.sqrt((ex - sx) * (ex - sx) + (ey - sy) * (ey - sy));
                    const midpoint = [2]f32{
                        (sx + ex) * 0.5,
                        (sy + ey) * 0.5,
                    };
                    const angle = std.math.atan2(ey - sy, ex - sx);
                    try geometry_instances.append(allocator, .{
                        .geometry_type = 1,
                        .rotation = angle,
                        .translation = midpoint,
                        .scale = [2]f32{ distance, 0.5 },
                    });
                },
            }
        }

        switch (window_state.mode) {
            .creating_line => |*line_data| {
                if (line_data.start) |start| {
                    const mousePosition = glfw.getMousePosition(window);
                    const end = mapMousePositionToObjectSpace(window, &window_state, mousePosition);
                    const sx = start[0];
                    const sy = start[1];
                    const ex = end[0];
                    const ey = end[1];
                    const distance = zm.sqrt((ex - sx) * (ex - sx) + (ey - sy) * (ey - sy));
                    const midpoint = [2]f32{
                        (sx + ex) * 0.5,
                        (sy + ey) * 0.5,
                    };
                    const angle = std.math.atan2(ey - sy, ex - sx);
                    try geometry_instances.append(allocator, .{
                        .geometry_type = 1,
                        .rotation = angle,
                        .translation = midpoint,
                        .scale = [2]f32{ distance, 0.5 },
                    });
                    try geometry_instances.append(allocator, .{
                        .geometry_type = 0,
                        .rotation = 0.0,
                        .translation = start,
                        .scale = [2]f32{ 1.0, 1.0 },
                    });
                    try geometry_instances.append(allocator, .{
                        .geometry_type = 0,
                        .rotation = 0.0,
                        .translation = end,
                        .scale = [2]f32{ 1.0, 1.0 },
                    });
                }
            },
            else => {},
        }

        try instance_buffer.update(@ptrCast(geometry_instances.items));

        const vk_data = per_frame_vk_data[current_frame];
        try renderer.drawFrame(
            window,
            &vk_data,
            &ubo,
            rectangle_vertex_buffer,
            rectangle_vertex_data.len,
            instance_buffer.instance_buffer,
            geometry_instances.items.len,
        );

        current_frame = (current_frame + 1) % @as(u32, @intCast(per_frame_vk_data.len));

        const end_time = std.time.nanoTimestamp();
        const frame_time_ns = end_time - start_time;
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
        const x = (rand.float(f32) * 2.0 - 1.0) / window_state.?.zoom;
        const y = (rand.float(f32) * 2.0 - 1.0) / window_state.?.zoom;
        window_state.?.primitives.append(window_state.?.allocator, .{ .point = [2]f32{ x, y } }) catch {
            std.debug.print("Failed to append geometry instance\n", .{});
        };
        std.debug.print("Point appended: ({},{}) -> primitives count = {}\n", .{ x, y, window_state.?.primitives.items.len });
    }

    if (key == glfw.c.GLFW_KEY_1 and action == glfw.c.GLFW_PRESS) {
        window_state.?.mode = .{ .navigation = .{} };
    }
    if (key == glfw.c.GLFW_KEY_2 and action == glfw.c.GLFW_PRESS) {
        window_state.?.mode = .creating_point;
    }
    if (key == glfw.c.GLFW_KEY_3 and action == glfw.c.GLFW_PRESS) {
        window_state.?.mode = .{ .creating_line = .{} };
    }
}

export fn mouseButtonCallback(window: ?*glfw.c.GLFWwindow, button: i32, action: i32, mods: i32) void {
    _ = mods;
    if (window == null) {
        return;
    }

    const window_state = glfw.getWindowUserPointer(window.?, WindowState);
    if (window_state == null) {
        return;
    }

    switch (window_state.?.mode) {
        .navigation => |*navigation_data| {
            navigation_data.left_mouse_button_down = (button == glfw.c.GLFW_MOUSE_BUTTON_LEFT and action == glfw.c.GLFW_PRESS);
            std.debug.print("Mouse button state: {}\n", .{navigation_data.left_mouse_button_down});
        },
        .creating_point => {
            createPoint(window.?, button, action, window_state.?);
        },
        .creating_line => |*line_data| {
            createLine(window.?, button, action, window_state.?, line_data);
        },
    }
}

fn createPoint(window: *glfw.c.GLFWwindow, button: i32, action: i32, window_state: *WindowState) void {
    if (button != glfw.c.GLFW_MOUSE_BUTTON_LEFT or action != glfw.c.GLFW_PRESS) {
        return;
    }

    const mousePosition = glfw.getMousePosition(window);
    const scaled = mapMousePositionToObjectSpace(window, window_state, mousePosition);
    window_state.primitives.append(window_state.allocator, .{ .point = scaled }) catch {
        std.debug.print("Failed to append point\n", .{});
    };
}

fn createLine(window: *glfw.c.GLFWwindow, button: i32, action: i32, window_state: *WindowState, line_data: *LineCreationData) void {
    if (button != glfw.c.GLFW_MOUSE_BUTTON_LEFT or action != glfw.c.GLFW_PRESS) {
        return;
    }

    const mousePosition = glfw.getMousePosition(window);
    const scaled = mapMousePositionToObjectSpace(window, window_state, mousePosition);

    if (line_data.start) |start| {
        window_state.primitives.append(window_state.allocator, .{ .line = .{
            .start = start,
            .end = scaled,
        } }) catch {
            std.debug.print("Failed to append line\n", .{});
        };
        window_state.primitives.append(window_state.allocator, .{ .point = start }) catch {
            std.debug.print("Failed to append point\n", .{});
        };
        window_state.primitives.append(window_state.allocator, .{ .point = scaled }) catch {
            std.debug.print("Failed to append point\n", .{});
        };
        std.debug.print("Line added: {}\n", .{window_state.primitives.items.len});
        line_data.start = null;
    } else {
        line_data.start = scaled;
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

export fn cursorPosCallback(window: ?*glfw.c.GLFWwindow, xpos: f64, ypos: f64) void {
    if (window == null) {
        return;
    }

    var window_state = glfw.getWindowUserPointer(window.?, WindowState);
    if (window_state == null) {
        return;
    }

    switch (window_state.?.mode) {
        .navigation => |*navigation_data| {
            if (navigation_data.left_mouse_button_down) {
                const scaled = mapMousePositionToObjectSpace(window.?, window_state.?, .{ .x = xpos, .y = ypos });
                const delta_x = scaled[0] - window_state.?.center[0];
                const delta_y = scaled[1] - window_state.?.center[1];

                // TODO this does not quite work yet
                std.debug.print("Cursor position: ({}, {}) -> ({}, {}) -> ({}, {})\n", .{ xpos, ypos, scaled[0], scaled[1], delta_x, delta_y });
                window_state.?.center[0] -= delta_x;
                window_state.?.center[1] -= delta_y;
            }
        },
        else => {},
    }
}
