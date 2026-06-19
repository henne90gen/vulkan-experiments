const std = @import("std");
const zm = @import("zmath");

const glfw = @import("glfw.zig");
const vk = @import("vulkan.zig");
const bmp = @import("bitmap.zig");
const utils = @import("utils.zig");
const rd = @import("renderer.zig");
const math = @import("math.zig");
const cs = @import("constraint_solver.zig");

test {
    std.testing.refAllDecls(@This());
}

const WindowState = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    zoom: f32,
    center: [2]f32 = .{ 0.0, 0.0 },

    primitives: std.ArrayList(Primitive) = std.ArrayList(Primitive).empty,
    constraints: std.ArrayList(Constraint) = std.ArrayList(Constraint).empty,
    ui_elements: std.ArrayList(UiElement) = std.ArrayList(UiElement).empty,

    buttons: Buttons = .{},

    mode: InteractionMode = .{ .navigation = .{} },

    pub fn deinit(self: *WindowState) void {
        self.primitives.deinit(self.allocator);
        self.constraints.deinit(self.allocator);
        self.ui_elements.deinit(self.allocator);
    }

    pub fn toggleMode(self: *WindowState, new_mode: InteractionMode) void {
        self.mode = new_mode;
        self.btn(self.buttons.navigation_btn_idx).render_hints.selected = new_mode == .navigation;
        self.btn(self.buttons.create_point_btn_idx).render_hints.selected = new_mode == .creating_point;
        self.btn(self.buttons.create_line_btn_idx).render_hints.selected = new_mode == .creating_line;
        self.btn(self.buttons.create_horizontal_btn_idx).render_hints.selected = new_mode == .creating_horizontal;
        self.btn(self.buttons.create_vertical_btn_idx).render_hints.selected = new_mode == .creating_vertical;
    }

    fn btn(self: *WindowState, idx: usize) *Button {
        return &self.ui_elements.items[idx].button;
    }
};

const Buttons = struct {
    navigation_btn_idx: usize = undefined,
    create_point_btn_idx: usize = undefined,
    create_line_btn_idx: usize = undefined,
    create_horizontal_btn_idx: usize = undefined,
    create_vertical_btn_idx: usize = undefined,
    solve_constraints_btn_idx: usize = undefined,
};

const InteractionMode = union(enum) {
    navigation: NavigationData,
    creating_point,
    creating_line: LineCreationData,
    creating_horizontal,
    creating_vertical,
};

const LineCreationData = struct {
    start: ?[2]f32 = null,
    start_idx: ?usize = null,
};

const NavigationData = struct {
    left_mouse_button_down: bool = false,
    last_cursor_position: ?[2]f32 = null,
};

const Primitive = union(enum) {
    point: PointPrimitive,
    line: LinePrimitive,
};

const PointPrimitive = struct {
    data: [2]f32,
    render_hints: rd.RenderHints = .{},
};

const LinePrimitive = struct {
    start: [2]f32,
    end: [2]f32,
    render_hints: rd.RenderHints = .{},
};

const Constraint = union(enum) {
    point_on_line: struct {
        point_idx: usize,
        line_idx: usize,
    },
    point_anchor: struct {
        point_idx: usize,
    },
    line_horizontal: struct {
        line_idx: usize,
    },
    line_vertical: struct {
        line_idx: usize,
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
    Horizontal = 10,
    Vertical = 11,
};

pub fn main(init: std.process.Init) !void {
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
        .io = init.io,
        .allocator = allocator,
        .zoom = 0.1,
    };
    defer window_state.deinit();

    try initUI(&window_state);

    try addExampleDrawing(&window_state);

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
        const start_time = nanoTimestamp();

        const framebuffer_size = glfw.getFramebufferSize(window);
        const ubo = rd.UniformBufferObject{
            .aspect_ratio = @as(f32, @floatFromInt(framebuffer_size.width)) / @as(f32, @floatFromInt(framebuffer_size.height)),
            .zoom = window_state.zoom,
            .offset = window_state.center,
        };

        geometry_instances.clearRetainingCapacity();
        try renderPrimitives(allocator, &window_state, &geometry_instances);
        try renderConstraints(allocator, &window_state, &geometry_instances);
        try renderModeSpecificGeometry(allocator, &window_state, &geometry_instances, window);
        try renderUI(allocator, &window_state, &geometry_instances);

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

        const end_time = nanoTimestamp();
        const frame_time_ns = end_time - start_time;
        const frame_time_ms = @as(f32, @floatFromInt(frame_time_ns)) / 1_000_000.0;
        const new_title = try std.fmt.allocPrintSentinel(allocator, "Vulkan - Frame time: {d:.2} ms - {d:.2} fps", .{ frame_time_ms, 1000.0 / frame_time_ms }, 0);
        defer allocator.free(new_title);
        glfw.setWindowTitle(window, new_title);

        const target_frame_time_ns: u64 = 16 * 1_000_000;
        if (frame_time_ns < target_frame_time_ns) {
            const remaining_ns: u64 = @intCast(target_frame_time_ns - frame_time_ns);
           try std.Io.sleep(init.io, std.Io.Duration.fromNanoseconds(remaining_ns), .real);
        }
    }

    const err = vk.c.vkDeviceWaitIdle(renderer.device.device);
    if (err != vk.c.VK_SUCCESS) {
        std.debug.print("Failed to wait for device idle: {s}\n", .{vk.c.string_VkResult(err)});
        return;
    }
}

fn addExampleDrawing(window_state: *WindowState) !void {
    const start_idx = window_state.primitives.items.len;

    try window_state.primitives.append(window_state.allocator, .{ .point = .{ .data = [2]f32{ 2.0, 2.0 } } });
    try window_state.primitives.append(window_state.allocator, .{ .point = .{ .data = [2]f32{ 2.0, -2.0 } } });
    try window_state.primitives.append(window_state.allocator, .{ .point = .{ .data = [2]f32{ -2.0, -2.0 } } });
    try window_state.primitives.append(window_state.allocator, .{ .point = .{ .data = [2]f32{ -2.0, 2.0 } } });

    try window_state.primitives.append(window_state.allocator, .{ .line = .{ .start = [2]f32{ 2.0, 2.0 }, .end = [2]f32{ 2.0, -2.0 } } });
    try window_state.primitives.append(window_state.allocator, .{ .line = .{ .start = [2]f32{ 2.0, -2.0 }, .end = [2]f32{ -2.0, -2.0 } } });
    try window_state.primitives.append(window_state.allocator, .{ .line = .{ .start = [2]f32{ -2.0, -2.0 }, .end = [2]f32{ -2.0, 2.0 } } });
    try window_state.primitives.append(window_state.allocator, .{ .line = .{ .start = [2]f32{ -2.0, 2.0 }, .end = [2]f32{ 2.0, 2.0 } } });

    try window_state.constraints.append(window_state.allocator, .{ .point_on_line = .{ .point_idx = start_idx + 0, .line_idx = start_idx + 4 } });
    try window_state.constraints.append(window_state.allocator, .{ .point_on_line = .{ .point_idx = start_idx + 1, .line_idx = start_idx + 4 } });
    try window_state.constraints.append(window_state.allocator, .{ .point_on_line = .{ .point_idx = start_idx + 1, .line_idx = start_idx + 5 } });
    try window_state.constraints.append(window_state.allocator, .{ .point_on_line = .{ .point_idx = start_idx + 2, .line_idx = start_idx + 5 } });
    try window_state.constraints.append(window_state.allocator, .{ .point_on_line = .{ .point_idx = start_idx + 2, .line_idx = start_idx + 6 } });
    try window_state.constraints.append(window_state.allocator, .{ .point_on_line = .{ .point_idx = start_idx + 3, .line_idx = start_idx + 6 } });
    try window_state.constraints.append(window_state.allocator, .{ .point_on_line = .{ .point_idx = start_idx + 3, .line_idx = start_idx + 7 } });
    try window_state.constraints.append(window_state.allocator, .{ .point_on_line = .{ .point_idx = start_idx + 0, .line_idx = start_idx + 7 } });

    try window_state.constraints.append(window_state.allocator, .{ .line_vertical = .{ .line_idx = start_idx + 4 } });
    try window_state.constraints.append(window_state.allocator, .{ .line_horizontal = .{ .line_idx = start_idx + 5 } });
    try window_state.constraints.append(window_state.allocator, .{ .line_vertical = .{ .line_idx = start_idx + 6 } });
    try window_state.constraints.append(window_state.allocator, .{ .line_horizontal = .{ .line_idx = start_idx + 7 } });
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

fn createHorizontalClicked(_: *Button, _: *glfw.c.GLFWwindow, window_state: *WindowState) void {
    window_state.toggleMode(.creating_horizontal);
}

fn createVerticalClicked(_: *Button, _: *glfw.c.GLFWwindow, window_state: *WindowState) void {
    window_state.toggleMode(.creating_vertical);
}

fn prepareSolver(window_state: *WindowState, solver: *cs.Solver) !void {
    for (window_state.primitives.items, 0..) |primitive, idx| {
        switch (primitive) {
            .point => |point| try solver.addPrimitive(cs.Node{
                .id = idx,
                .data = .{ .point = .{ .input = .{ .x = point.data[0], .y = point.data[1] } } },
            }),
            .line => |line| try solver.addPrimitive(cs.Node{
                .id = idx,
                .data = .{ .line = .{ .input_start = .{ .x = line.start[0], .y = line.start[1] }, .input_end = .{ .x = line.end[0], .y = line.end[1] } } },
            }),
        }
    }

    // x axis
    const x_axis_id = window_state.primitives.items.len;
    try solver.addPrimitive(cs.Node{ .id = x_axis_id, .data = .{ .line = .{ .input_start = .{ .x = 0.0, .y = 0.0 }, .input_end = .{ .x = 1.0, .y = 0.0 } } }, .metadata = .{ .label = "X Axis" } });
    try solver.addConstraint(x_axis_id, x_axis_id, .anchor_constraint);

    // y axis
    const y_axis_id = window_state.primitives.items.len + 1;
    try solver.addPrimitive(cs.Node{ .id = y_axis_id, .data = .{ .line = .{ .input_start = .{ .x = 0.0, .y = 0.0 }, .input_end = .{ .x = 0.0, .y = 1.0 } } }, .metadata = .{ .label = "Y Axis" } });
    try solver.addConstraint(y_axis_id, y_axis_id, .anchor_constraint);

    for (window_state.constraints.items) |constraint| {
        switch (constraint) {
            .point_on_line => |d| try solver.addConstraint(d.point_idx, d.line_idx, .coincidence_constraint),
            .point_anchor => |d| try solver.addConstraint(d.point_idx, d.point_idx, .anchor_constraint),
            .line_horizontal => |d| try solver.addConstraint(d.line_idx, x_axis_id, .parallel_constraint),
            .line_vertical => |d| try solver.addConstraint(d.line_idx, y_axis_id, .parallel_constraint),
        }
    }
}

fn saveDotFile(allocator: std.mem.Allocator, solver: *cs.Solver) !void {
    const dot_file_content = try solver.exportToDot(allocator);
    defer allocator.free(dot_file_content);
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "constraints.dot", .data = dot_file_content });
}

fn solveConstraintsClicked(_: *Button, _: *glfw.c.GLFWwindow, window_state: *WindowState) void {
    var solver = cs.Solver.init(window_state.allocator);
    defer solver.deinit(window_state.allocator);

    prepareSolver(window_state, &solver) catch |err| {
        std.debug.print("Error preparing solver: {}\n", .{err});
        return;
    };

    saveDotFile(window_state.allocator, &solver) catch |err| {
        std.debug.print("Error creating dot file: {}\n", .{err});
        return;
    };

    solver.solve(window_state.io) catch |err| {
        std.debug.print("Error solving constraints: {}\n", .{err});
        return;
    };

    // TODO copy primitive data back into window_state
}

fn initUI(window_state: *WindowState) !void {
    const btn_size = 0.15;
    var position_x: f32 = -1.0 + btn_size / 2.0;
    const position_y: f32 = 1.0 - btn_size / 2.0;

    window_state.buttons.navigation_btn_idx = window_state.ui_elements.items.len;
    try window_state.ui_elements.append(window_state.allocator, .{
        .button = .{
            .position = .{ position_x, position_y },
            .size = .{ btn_size, btn_size },
            .image = .Navigation,
            .on_click = &navigationClicked,
            .render_hints = .{ .selected = true, .ui_element = true },
        },
    });

    position_x += btn_size;
    window_state.buttons.create_point_btn_idx = window_state.ui_elements.items.len;
    try window_state.ui_elements.append(window_state.allocator, .{
        .button = .{
            .position = .{ position_x, position_y },
            .size = .{ btn_size, btn_size },
            .image = .Point,
            .on_click = &createPointClicked,
        },
    });

    position_x += btn_size;
    window_state.buttons.create_line_btn_idx = window_state.ui_elements.items.len;
    try window_state.ui_elements.append(window_state.allocator, .{
        .button = .{
            .position = .{ position_x, position_y },
            .size = .{ btn_size, btn_size },
            .image = .Line,
            .on_click = &createLineClicked,
        },
    });

    position_x += btn_size;
    window_state.buttons.create_horizontal_btn_idx = window_state.ui_elements.items.len;
    try window_state.ui_elements.append(window_state.allocator, .{
        .button = .{
            .position = .{ position_x, position_y },
            .size = .{ btn_size, btn_size },
            .image = .Horizontal,
            .on_click = &createHorizontalClicked,
        },
    });

    position_x += btn_size;
    window_state.buttons.create_vertical_btn_idx = window_state.ui_elements.items.len;
    try window_state.ui_elements.append(window_state.allocator, .{
        .button = .{
            .position = .{ position_x, position_y },
            .size = .{ btn_size, btn_size },
            .image = .Vertical,
            .on_click = &createVerticalClicked,
        },
    });

    position_x += btn_size * 2;
    window_state.buttons.solve_constraints_btn_idx = window_state.ui_elements.items.len;
    try window_state.ui_elements.append(window_state.allocator, .{
        .button = .{
            .position = .{ position_x, position_y },
            .size = .{ btn_size, btn_size },
            .image = .Navigation,
            .on_click = &solveConstraintsClicked,
        },
    });
}

fn renderPrimitives(allocator: std.mem.Allocator, window_state: *WindowState, geometry_instances: *std.ArrayList(rd.GeometryInstance)) !void {
    // Render lines
    for (window_state.primitives.items) |primitive| {
        switch (primitive) {
            .line => |line| {
                const sx = line.start[0];
                const sy = line.start[1];
                const ex = line.end[0];
                const ey = line.end[1];
                const length = zm.length2(zm.loadArr2(line.start) - zm.loadArr2(line.end));
                const midpoint = [2]f32{
                    (sx + ex) * 0.5,
                    (sy + ey) * 0.5,
                };
                const angle = std.math.atan2(ey - sy, ex - sx);
                try geometry_instances.append(allocator, .{
                    .geometry_type = rd.GeometryType.Rectangle,
                    .rotation = angle,
                    .translation = midpoint,
                    .scale = [2]f32{ length[0], 0.5 },
                    .texture_index = 0,
                    .render_hints = line.render_hints,
                });
            },
            else => {},
        }
    }

    // Render points
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
            else => {},
        }
    }
}

fn textureOnLine(allocator: std.mem.Allocator, geometry_instances: *std.ArrayList(rd.GeometryInstance), line: LinePrimitive, texture_index: i32) !void {
    const start = line.start;
    const end = line.end;
    const midpoint = [2]f32{
        (start[0] + end[0]) * 0.5,
        (start[1] + end[1]) * 0.5,
    };
    try geometry_instances.append(allocator, .{
        .geometry_type = rd.GeometryType.TexturedQuad,
        .rotation = 0.0,
        .translation = midpoint,
        .scale = [2]f32{ 0.75, 0.75 },
        .texture_index = texture_index,
        .render_hints = .{},
    });
}

fn renderConstraints(allocator: std.mem.Allocator, window_state: *WindowState, geometry_instances: *std.ArrayList(rd.GeometryInstance)) !void {
    for (window_state.constraints.items) |constraint| {
        switch (constraint) {
            .line_horizontal => |data| {
                const line = window_state.primitives.items[data.line_idx];
                try textureOnLine(allocator, geometry_instances, line.line, @intFromEnum(ButtonImage.Horizontal));
            },
            .line_vertical => |data| {
                const line = window_state.primitives.items[data.line_idx];
                try textureOnLine(allocator, geometry_instances, line.line, @intFromEnum(ButtonImage.Vertical));
            },
            else => {},
        }
    }
}

fn renderModeSpecificGeometry(allocator: std.mem.Allocator, window_state: *WindowState, geometry_instances: *std.ArrayList(rd.GeometryInstance), window: *glfw.c.GLFWwindow) !void {
    switch (window_state.mode) {
        .creating_line => |*line_data| {
            if (line_data.start) |start| {
                const mouse_position_window_space = glfw.getMousePosition(window);
                const end = math.mapMousePositionToObjectSpace(window, window_state.zoom, mouse_position_window_space, window_state.center);
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
            if (line_data.start_idx) |start_idx| {
                const mouse_position_window_space = glfw.getMousePosition(window);
                const end = math.mapMousePositionToObjectSpace(window, window_state.zoom, mouse_position_window_space, window_state.center);
                const start = window_state.primitives.items[start_idx].point.data;
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

fn renderUI(allocator: std.mem.Allocator, window_state: *WindowState, geometry_instances: *std.ArrayList(rd.GeometryInstance)) !void {
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
        const seed = std.Io.Clock.now(.real, window_state.?.io).nanoseconds;
        var prng = std.Random.DefaultPrng.init(@intCast(seed));
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

fn findLineIdx(window_state: *WindowState, mouse_position: [2]f32) ?usize {
    for (window_state.primitives.items, 0..) |primitive, idx| {
        switch (primitive) {
            .line => |line| {
                const sx = line.start[0];
                const sy = line.start[1];
                const ex = line.end[0];
                const ey = line.end[1];
                const length = zm.length2(zm.loadArr2(line.start) - zm.loadArr2(line.end));
                const center = [2]f32{
                    (sx + ex) * 0.5,
                    (sy + ey) * 0.5,
                };
                const angle = std.math.atan2(ey - sy, ex - sx);
                const size = [2]f32{
                    length[0],
                    0.5,
                };
                if (math.rectangleContainsPoint(center, size, angle, mouse_position)) {
                    return idx;
                }
            },
            else => {},
        }
    }
    return null;
}

fn findPointIdx(window_state: *WindowState, mouse_position: [2]f32) ?usize {
    for (window_state.primitives.items, 0..) |primitive, idx| {
        switch (primitive) {
            .point => |point| {
                if (math.circleContainsPoint(point.data, 1.0, mouse_position)) {
                    return idx;
                }
            },
            else => {},
        }
    }
    return null;
}

fn createLineConstraint(window: *glfw.c.GLFWwindow, button: i32, action: i32, window_state: *WindowState, is_horizontal: bool) !void {
    if (button != glfw.c.GLFW_MOUSE_BUTTON_1 or action != glfw.c.GLFW_PRESS) {
        return;
    }

    const mouse_position_window_space = glfw.getMousePosition(window);
    const mouse_position_object_space = math.mapMousePositionToObjectSpace(window, window_state.zoom, mouse_position_window_space, window_state.center);
    const line_idx = findLineIdx(window_state, mouse_position_object_space);
    if (line_idx == null) {
        std.debug.print("Failed to find line\n", .{});
        return;
    }

    std.debug.print("Found line at idx={}\n", .{line_idx.?});

    // TODO remove other horizontal/vertical constraints for same line
    if (is_horizontal) {
        try window_state.constraints.append(window_state.allocator, .{ .line_horizontal = .{ .line_idx = line_idx.? } });
    } else {
        try window_state.constraints.append(window_state.allocator, .{ .line_vertical = .{ .line_idx = line_idx.? } });
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
        .creating_horizontal => {
            createLineConstraint(window.?, button, action, window_state.?, true) catch {
                std.debug.print("Failed to create horizontal line constraint\n", .{});
            };
        },
        .creating_vertical => {
            createLineConstraint(window.?, button, action, window_state.?, false) catch {
                std.debug.print("Failed to create vertical line constraint\n", .{});
            };
        },
    }
}

fn handleClickInUI(window: *glfw.c.GLFWwindow, button: i32, action: i32, window_state: *WindowState) bool {
    if (button != glfw.c.GLFW_MOUSE_BUTTON_1 or action != glfw.c.GLFW_PRESS) {
        return false;
    }

    const mouse_position_window_space = glfw.getMousePosition(window);
    const mouse_position_screen_space = math.mapMousePositionToScreenSpace(window, 1.0, mouse_position_window_space);
    for (window_state.ui_elements.items) |*ui_elemnt| {
        switch (ui_elemnt.*) {
            .button => |*btn| {
                if (math.rectangleContainsPoint(btn.position, btn.size, 0.0, mouse_position_screen_space)) {
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

    const mouse_position_window_space = glfw.getMousePosition(window);
    const mouse_position_object_space = math.mapMousePositionToObjectSpace(window, window_state.zoom, mouse_position_window_space, window_state.center);
    const v0 = zm.f32x4(mouse_position_object_space[0], mouse_position_object_space[1], 0.0, 0.0);
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

    const mouse_position_window_space = glfw.getMousePosition(window);
    const mouse_position_object_space = math.mapMousePositionToObjectSpace(window, window_state.zoom, mouse_position_window_space, window_state.center);
    try window_state.primitives.append(window_state.allocator, .{ .point = .{ .data = mouse_position_object_space } });
    std.debug.print("Point added: ({}, {}) -> primitives count = {}\n", .{ mouse_position_object_space[0], mouse_position_object_space[1], window_state.primitives.items.len });
}

fn createLine(window: *glfw.c.GLFWwindow, button: i32, action: i32, window_state: *WindowState, line_data: *LineCreationData) !void {
    if (button != glfw.c.GLFW_MOUSE_BUTTON_LEFT or action != glfw.c.GLFW_PRESS) {
        return;
    }

    const mouse_position_window_space = glfw.getMousePosition(window);
    const mouse_position_object_space = math.mapMousePositionToObjectSpace(window, window_state.zoom, mouse_position_window_space, window_state.center);

    const end_idx_opt = findPointIdx(window_state, mouse_position_object_space);

    if (line_data.start) |start| {
        var end: [2]f32 = [2]f32{ 0.0, 0.0 };

        if (end_idx_opt) |end_idx| {
            end = window_state.primitives.items[end_idx].point.data;

            const line_idx = window_state.primitives.items.len;
            try window_state.primitives.append(window_state.allocator, .{ .line = .{ .start = start, .end = end } });

            const point_1_idx = window_state.primitives.items.len;
            try window_state.primitives.append(window_state.allocator, .{ .point = .{ .data = start } });

            try window_state.constraints.append(window_state.allocator, .{ .point_on_line = .{ .point_idx = point_1_idx, .line_idx = line_idx } });
            try window_state.constraints.append(window_state.allocator, .{ .point_on_line = .{ .point_idx = end_idx, .line_idx = line_idx } });
        } else {
            end = mouse_position_object_space;

            const line_idx = window_state.primitives.items.len;
            try window_state.primitives.append(window_state.allocator, .{ .line = .{ .start = start, .end = end } });

            const point_1_idx = window_state.primitives.items.len;
            try window_state.primitives.append(window_state.allocator, .{ .point = .{ .data = start } });

            const point_2_idx = window_state.primitives.items.len;
            try window_state.primitives.append(window_state.allocator, .{ .point = .{ .data = end } });

            try window_state.constraints.append(window_state.allocator, .{ .point_on_line = .{ .point_idx = point_1_idx, .line_idx = line_idx } });
            try window_state.constraints.append(window_state.allocator, .{ .point_on_line = .{ .point_idx = point_2_idx, .line_idx = line_idx } });
        }

        std.debug.print("Line added: ({}, {}) - ({}, {}) -> primitives count = {}\n", .{ start[0], start[1], end[0], end[1], window_state.primitives.items.len });
        line_data.start = null;
        return;
    }

    if (line_data.start_idx) |start_idx| {
        const start = window_state.primitives.items[start_idx].point.data;
        var end: [2]f32 = [2]f32{ 0.0, 0.0 };

        if (end_idx_opt) |end_idx| {
            end = window_state.primitives.items[end_idx].point.data;

            const line_idx = window_state.primitives.items.len;
            try window_state.primitives.append(window_state.allocator, .{ .line = .{ .start = start, .end = end } });

            try window_state.constraints.append(window_state.allocator, .{ .point_on_line = .{ .point_idx = start_idx, .line_idx = line_idx } });
            try window_state.constraints.append(window_state.allocator, .{ .point_on_line = .{ .point_idx = end_idx, .line_idx = line_idx } });
        } else {
            end = mouse_position_object_space;

            const line_idx = window_state.primitives.items.len;
            try window_state.primitives.append(window_state.allocator, .{ .line = .{ .start = start, .end = end } });

            const point_2_idx = window_state.primitives.items.len;
            try window_state.primitives.append(window_state.allocator, .{ .point = .{ .data = end } });

            try window_state.constraints.append(window_state.allocator, .{ .point_on_line = .{ .point_idx = start_idx, .line_idx = line_idx } });
            try window_state.constraints.append(window_state.allocator, .{ .point_on_line = .{ .point_idx = point_2_idx, .line_idx = line_idx } });
        }

        std.debug.print("Line added: ({}, {}) - ({}, {}) -> primitives count = {}\n", .{ start[0], start[1], end[0], end[1], window_state.primitives.items.len });
        line_data.start_idx = null;
        return;
    }

    const point_idx_opt = findPointIdx(window_state, mouse_position_object_space);
    if (point_idx_opt) |point_idx| {
        std.debug.print("Point found at index {}\n", .{point_idx});
        line_data.start_idx = point_idx;
    } else {
        line_data.start = mouse_position_object_space;
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

fn nanoTimestamp() i128 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}
