const std = @import("std");
const zm = @import("zmath");

const glfw = @import("glfw.zig");
const vk = @import("vulkan.zig");
const bmp = @import("bitmap.zig");
const utils = @import("utils.zig");
const rd = @import("renderer.zig");
const math = @import("math.zig");

test {
    std.testing.refAllDeclsRecursive(@This());
}

const WindowState = struct {
    allocator: std.mem.Allocator,
    zoom: f32,
    center: [2]f32 = .{ 0.0, 0.0 },

    primitives: std.ArrayList(Primitive),
    ui_elements: std.ArrayList(UiElement),

    buttons: Buttons = .{},

    mode: InteractionMode = .{ .navigation = .{} },

    pub fn deinit(self: *WindowState) void {
        self.primitives.deinit(self.allocator);
        self.ui_elements.deinit(self.allocator);
    }

    pub fn toggleMode(self: *WindowState, new_mode: InteractionMode) void {
        self.mode = new_mode;
        self.buttons.navigation_btn.render_hints.selected = new_mode == .navigation;
        self.buttons.create_point_btn.render_hints.selected = new_mode == .creating_point;
        self.buttons.create_line_btn.render_hints.selected = new_mode == .creating_line;
    }
};

const Buttons = struct {
    navigation_btn: *Button = undefined,
    create_point_btn: *Button = undefined,
    create_line_btn: *Button = undefined,
};

const InteractionMode = union(enum) {
    navigation: NavigationData,
    creating_point,
    creating_line: LineCreationData,
};

const LineCreationData = struct {
    start: ?[2]f32 = null,
};

const NavigationData = struct {
    left_mouse_button_down: bool = false,
    last_cursor_position: ?[2]f32 = null,
};

const Primitive = union(enum) {
    point: struct {
        data: [2]f32,
        render_hints: rd.RenderHints = .{},
    },
    line: struct {
        start: [2]f32,
        end: [2]f32,
        render_hints: rd.RenderHints = .{},
    },
};

const UiElement = union(enum) {
    button: Button,
};

const Button = struct {
    position: [2]f32,
    size: [2]f32,
    image: ButtonImage,
    render_hints: rd.RenderHints = .{ .ui_element = true },
    on_click: *const fn (btn: *Button, window: *glfw.c.GLFWwindow, window_state: *WindowState) void,
};

const ButtonImage = enum(i32) {
    Navigation = 0,
    Point = 1,
    Line = 2,
    Arc = 3,
    Circle = 4,
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
        .ui_elements = std.ArrayList(UiElement).empty,
    };
    defer window_state.deinit();

    try initUI(&window_state);

    try window_state.primitives.append(window_state.allocator, .{ .point = .{ .data = [2]f32{ 2.0, 2.0 } } });
    try window_state.primitives.append(window_state.allocator, .{ .point = .{ .data = [2]f32{ 2.0, -2.0 } } });
    try window_state.primitives.append(window_state.allocator, .{ .point = .{ .data = [2]f32{ -2.0, -2.0 } } });
    try window_state.primitives.append(window_state.allocator, .{ .point = .{ .data = [2]f32{ -2.0, 2.0 } } });

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
        try addPrimitives(allocator, &window_state, &geometry_instances);
        try addModeSpecificGeometry(allocator, &window_state, &geometry_instances, window);
        try addUI(allocator, &window_state, &geometry_instances);

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

fn navigationClicked(_: *Button, _: *glfw.c.GLFWwindow, window_state: *WindowState) void {
    window_state.toggleMode(.{ .navigation = .{} });
}

fn createPointClicked(_: *Button, _: *glfw.c.GLFWwindow, window_state: *WindowState) void {
    window_state.toggleMode(.creating_point);
}

fn createLineClicked(_: *Button, _: *glfw.c.GLFWwindow, window_state: *WindowState) void {
    window_state.toggleMode(.{ .creating_line = .{} });
}

fn initUI(window_state: *WindowState) !void {
    const btn_size = 0.15;
    var position_x: f32 = -1.0 + btn_size / 2.0;
    const position_y: f32 = 1.0 - btn_size / 2.0;

    try window_state.ui_elements.append(window_state.allocator, .{
        .button = .{
            .position = .{ position_x, position_y },
            .size = .{ btn_size, btn_size },
            .image = .Navigation,
            .on_click = &navigationClicked,
            .render_hints = .{ .selected = true, .ui_element = true },
        },
    });
    window_state.buttons.navigation_btn = &window_state.ui_elements.items[window_state.ui_elements.items.len - 1].button;

    position_x += btn_size;
    try window_state.ui_elements.append(window_state.allocator, .{
        .button = .{
            .position = .{ position_x, position_y },
            .size = .{ btn_size, btn_size },
            .image = .Point,
            .on_click = &createPointClicked,
        },
    });
    window_state.buttons.create_point_btn = &window_state.ui_elements.items[window_state.ui_elements.items.len - 1].button;

    position_x += btn_size;
    try window_state.ui_elements.append(window_state.allocator, .{
        .button = .{
            .position = .{ position_x, position_y },
            .size = .{ btn_size, btn_size },
            .image = .Line,
            .on_click = &createLineClicked,
        },
    });
    window_state.buttons.create_line_btn = &window_state.ui_elements.items[window_state.ui_elements.items.len - 1].button;
}

fn addPrimitives(allocator: std.mem.Allocator, window_state: *WindowState, geometry_instances: *std.ArrayList(rd.GeometryInstance)) !void {
    for (window_state.primitives.items) |primitive| {
        switch (primitive) {
            .point => |point| {
                try geometry_instances.append(allocator, .{
                    .geometry_type = rd.GeometryType.Circle,
                    .rotation = 0.0,
                    .translation = point.data,
                    .scale = [2]f32{ 1.0, 1.0 },
                    .texture_index = 0,
                    .render_hints = point.render_hints,
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
                    .geometry_type = rd.GeometryType.Rectangle,
                    .rotation = angle,
                    .translation = midpoint,
                    .scale = [2]f32{ distance, 0.5 },
                    .texture_index = 0,
                    .render_hints = line.render_hints,
                });
            },
        }
    }
}

fn addModeSpecificGeometry(allocator: std.mem.Allocator, window_state: *WindowState, geometry_instances: *std.ArrayList(rd.GeometryInstance), window: *glfw.c.GLFWwindow) !void {
    switch (window_state.mode) {
        .creating_line => |*line_data| {
            if (line_data.start) |start| {
                const mousePosition = glfw.getMousePosition(window);
                const end = math.mapMousePositionToObjectSpace(window, window_state.zoom, mousePosition, window_state.center);
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
                    .geometry_type = rd.GeometryType.Rectangle,
                    .rotation = angle,
                    .translation = midpoint,
                    .scale = [2]f32{ distance, 0.5 },
                    .texture_index = 0,
                    .render_hints = .{},
                });
                try geometry_instances.append(allocator, .{
                    .geometry_type = rd.GeometryType.Circle,
                    .rotation = 0.0,
                    .translation = start,
                    .scale = [2]f32{ 1.0, 1.0 },
                    .texture_index = 0,
                    .render_hints = .{},
                });
                try geometry_instances.append(allocator, .{
                    .geometry_type = rd.GeometryType.Circle,
                    .rotation = 0.0,
                    .translation = end,
                    .scale = [2]f32{ 1.0, 1.0 },
                    .texture_index = 0,
                    .render_hints = .{},
                });
            }
        },
        else => {},
    }
}

fn addUI(allocator: std.mem.Allocator, window_state: *WindowState, geometry_instances: *std.ArrayList(rd.GeometryInstance)) !void {
    if (false) {
        // NOTE this renders a rectangle covering the whole area that the UI can use
        try geometry_instances.append(allocator, .{
            .geometry_type = rd.GeometryType.Rectangle,
            .rotation = 0.0,
            .translation = [2]f32{ 0.0, 0.0 },
            .scale = [2]f32{ 2.0, 2.0 },
            .texture_index = 0,
            .render_hints = .{ .ui_element = true },
        });
    }
    for (window_state.ui_elements.items) |ui_element| {
        switch (ui_element) {
            .button => |btn| {
                try geometry_instances.append(allocator, .{
                    .geometry_type = rd.GeometryType.TexturedQuad,
                    .rotation = 0.0,
                    .translation = btn.position,
                    .scale = btn.size,
                    .texture_index = @intFromEnum(btn.image),
                    .render_hints = btn.render_hints,
                });
            },
        }
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
        window_state.?.primitives.append(window_state.?.allocator, .{ .point = .{ .data = [2]f32{ x, y } } }) catch {
            std.debug.print("Failed to append geometry instance\n", .{});
        };
        std.debug.print("Point appended: ({},{}) -> primitives count = {}\n", .{ x, y, window_state.?.primitives.items.len });
    }

    if (key == glfw.c.GLFW_KEY_1 and action == glfw.c.GLFW_PRESS) {
        window_state.?.toggleMode(.{ .navigation = .{} });
    }
    if (key == glfw.c.GLFW_KEY_2 and action == glfw.c.GLFW_PRESS) {
        window_state.?.toggleMode(.creating_point);
    }
    if (key == glfw.c.GLFW_KEY_3 and action == glfw.c.GLFW_PRESS) {
        window_state.?.toggleMode(.{ .creating_line = .{} });
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

    const uiWasClicked = handleClickInUI(window.?, button, action, window_state.?);
    if (uiWasClicked) {
        return;
    }

    switch (window_state.?.mode) {
        .navigation => |*navigation_data| {
            handleNavigation(window.?, button, action, window_state.?, navigation_data);
        },
        .creating_point => {
            createPoint(window.?, button, action, window_state.?) catch {
                std.debug.print("Failed to create point\n", .{});
            };
        },
        .creating_line => |*line_data| {
            createLine(window.?, button, action, window_state.?, line_data) catch {
                std.debug.print("Failed to create line\n", .{});
            };
        },
    }
}

fn handleClickInUI(window: *glfw.c.GLFWwindow, button: i32, action: i32, window_state: *WindowState) bool {
    if (button != glfw.c.GLFW_MOUSE_BUTTON_1 or action != glfw.c.GLFW_PRESS) {
        return false;
    }

    const mousePosition = glfw.getMousePosition(window);
    const mouse_position = math.mapMousePositionToScreenSpace(window, 1.0, mousePosition);
    for (window_state.ui_elements.items) |*ui_elemnt| {
        switch (ui_elemnt.*) {
            .button => |*btn| {
                if (math.rectContainsPoint(btn.position, btn.size, mouse_position)) {
                    btn.on_click(btn, window, window_state);
                    return true;
                }
            },
        }
    }

    return false;
}

fn handleNavigation(window: *glfw.c.GLFWwindow, button: i32, action: i32, window_state: *WindowState, navigation_data: *NavigationData) void {
    navigation_data.left_mouse_button_down = (button == glfw.c.GLFW_MOUSE_BUTTON_LEFT and action == glfw.c.GLFW_PRESS);
    navigation_data.last_cursor_position = null;

    if (!navigation_data.left_mouse_button_down) {
        return;
    }

    const mousePosition = glfw.getMousePosition(window);
    const mouse_position = math.mapMousePositionToObjectSpace(window, window_state.zoom, mousePosition, window_state.center);
    const v0 = zm.f32x4(mouse_position[0], mouse_position[1], 0.0, 0.0);
    for (window_state.primitives.items) |*primitive| {
        switch (primitive.*) {
            .point => |*point| {
                const v1 = zm.f32x4(point.data[0], point.data[1], 0.0, 0.0);
                const diff = v0 - v1;
                const distance = zm.length2(diff)[0];
                if (distance < 0.5) {
                    point.render_hints.selected = !point.render_hints.selected;
                }
            },
            .line => continue,
        }
    }
}

fn createPoint(window: *glfw.c.GLFWwindow, button: i32, action: i32, window_state: *WindowState) !void {
    if (button != glfw.c.GLFW_MOUSE_BUTTON_LEFT or action != glfw.c.GLFW_PRESS) {
        return;
    }

    const mousePosition = glfw.getMousePosition(window);
    const mouse_position = math.mapMousePositionToObjectSpace(window, window_state.zoom, mousePosition, window_state.center);
    try window_state.primitives.append(window_state.allocator, .{ .point = .{ .data = mouse_position } });
    std.debug.print("Point added: ({}, {}) -> primitives count = {}\n", .{ mouse_position[0], mouse_position[1], window_state.primitives.items.len });
}

fn createLine(window: *glfw.c.GLFWwindow, button: i32, action: i32, window_state: *WindowState, line_data: *LineCreationData) !void {
    if (button != glfw.c.GLFW_MOUSE_BUTTON_LEFT or action != glfw.c.GLFW_PRESS) {
        return;
    }

    const mousePosition = glfw.getMousePosition(window);
    const mouse_position = math.mapMousePositionToObjectSpace(window, window_state.zoom, mousePosition, window_state.center);

    if (line_data.start) |start| {
        try window_state.primitives.append(window_state.allocator, .{ .line = .{ .start = start, .end = mouse_position } });
        try window_state.primitives.append(window_state.allocator, .{ .point = .{ .data = start } });
        try window_state.primitives.append(window_state.allocator, .{ .point = .{ .data = mouse_position } });
        std.debug.print("Line added: ({}, {}) - ({}, {}) -> primitives count = {}\n", .{ start[0], start[1], mouse_position[0], mouse_position[1], window_state.primitives.items.len });
        line_data.start = null;
    } else {
        line_data.start = mouse_position;
    }
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
                const current_cursor_position = math.mapMousePositionToScreenSpace(window.?, window_state.?.zoom, .{ .x = xpos, .y = ypos });
                if (navigation_data.last_cursor_position) |*last_cursor_position| {
                    const delta_x = current_cursor_position[0] - last_cursor_position[0];
                    const delta_y = current_cursor_position[1] - last_cursor_position[1];

                    window_state.?.center[0] += delta_x;
                    window_state.?.center[1] += delta_y;

                    last_cursor_position[0] = current_cursor_position[0];
                    last_cursor_position[1] = current_cursor_position[1];
                } else {
                    navigation_data.last_cursor_position = current_cursor_position;
                }
            }
        },
        else => {},
    }
}
