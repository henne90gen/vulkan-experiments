const std = @import("std");
const zm = @import("zmath");

const glfw = @import("glfw.zig");
const vk = @import("vulkan.zig");
const bmp = @import("bitmap.zig");
const utils = @import("utils.zig");

const shader_vert = @embedFile("shader.vert.spv");
const shader_frag = @embedFile("shader.frag.spv");
const greenland_grid_velo = @embedFile("assets/greenland_grid_velo.bmp");

test {
    std.testing.refAllDeclsRecursive(@This());
}

const MAX_FRAMES_IN_FLIGHT = 2;
const INITIAL_GEOMETRY_INSTANCE_COUNT = 1;

const PerFrameVulkanData = struct {
    command_buffer: vk.c.VkCommandBuffer,
    sync_objects: vk.SyncObjects,
    uniform_buffer: vk.c.VkBuffer = undefined,
    uniform_buffer_memory: vk.c.VkDeviceMemory = undefined,
    uniform_buffer_mapped: *void = undefined,
    descriptor_set: vk.c.VkDescriptorSet = undefined,
};

const UniformBufferObject = extern struct {
    aspect_ratio: f32 align(4),
};

const Vertex = struct {
    position: [2]f32 align(8),
};

const GeometryInstance = struct {
    geometry_type: f32 align(4),
    rotation: f32 align(4),
    translation: [2]f32 align(8),
    scale: [2]f32 align(8),
};

const WindowState = struct {
    allocator: std.mem.Allocator,
    rotation: f32,
    geometry_instances: std.ArrayList(GeometryInstance),

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
        .rotation = 0.0,
        .geometry_instances = std.ArrayList(GeometryInstance).empty,
    };
    defer window_state.deinit();

    glfw.setWindowUserPointer(window, &window_state);
    glfw.setKeyCallback(window, keyCallback);

    const requiredExtensions = glfw.getRequiredInstanceExtensions();
    const instance = try vk.createInstance(allocator, requiredExtensions);
    defer vk.destroyInstance(instance);

    const debug_messenger = try vk.setupDebugMessenger(instance);
    defer vk.destroyDebugMessenger(instance, debug_messenger);

    const surface = createWindowSurface(instance, window);
    defer vk.destroySurface(instance, surface);

    const device = try vk.Device.init(allocator, instance, surface);
    defer device.deinit();

    var width: i32 = 0;
    var height: i32 = 0;
    glfw.getFramebufferSize(window, &width, &height);
    var swap_chain = try vk.SwapChain.init(allocator, &device, surface, .{ .width = @intCast(width), .height = @intCast(height) });
    defer swap_chain.deinit(allocator, &device);

    std.debug.print("Swap chain images count: {}\n", .{swap_chain.images.len});

    var image_views = try vk.createImageViews(allocator, &device, &swap_chain);
    defer vk.destroyImageViews(allocator, &device, image_views);

    std.debug.print("Image views count: {}\n", .{image_views.len});

    const bitmap = try bmp.Bitmap.from_memory(allocator, greenland_grid_velo);
    defer bitmap.deinit(allocator);

    const descriptor_set_layout = try vk.createDescriptorSetLayout(&device);
    defer vk.destroyDescriptorSetLayout(&device, descriptor_set_layout);

    const vertex_desription = vertexDescription();
    const pipeline = try vk.createGraphicsPipeline(allocator, &device, &swap_chain, shader_vert, shader_frag, descriptor_set_layout, vertex_desription);
    defer pipeline.deinit(&device);

    var depth_image = try vk.createDepthResources(&device, .{ .width = @intCast(width), .height = @intCast(height) });
    defer depth_image.deinit(&device);

    var framebuffers = try vk.createFramebuffers(allocator, &device, &pipeline, &swap_chain, image_views, &depth_image);
    defer vk.destroyFramebuffers(allocator, &device, framebuffers);

    const command_pool = try vk.createCommandPool(allocator, surface, &device);
    defer vk.destroyCommandPool(&device, command_pool);

    const texture_image = try vk.createTextureImage(&device, command_pool, bitmap.pixels, bitmap.width, bitmap.height, bitmap.bytes_per_pixel);
    defer texture_image.deinit(&device);

    const texture_sampler = try vk.createTextureSampler(&device);
    defer vk.destroyTextureSampler(&device, texture_sampler);

    const rectangle_vertex_data = [_]Vertex{
        .{ .position = .{ 0.5, -0.5 } },
        .{ .position = .{ 0.5, 0.5 } },
        .{ .position = .{ -0.5, 0.5 } },
        .{ .position = .{ 0.5, -0.5 } },
        .{ .position = .{ -0.5, 0.5 } },
        .{ .position = .{ -0.5, -0.5 } },

        .{ .position = .{ 0.5, -0.5 } },
        .{ .position = .{ -0.5, 0.5 } },
        .{ .position = .{ 0.5, 0.5 } },
        .{ .position = .{ 0.5, -0.5 } },
        .{ .position = .{ -0.5, -0.5 } },
        .{ .position = .{ -0.5, 0.5 } },
    };
    const rectangle_buffer_size = @sizeOf(@TypeOf(rectangle_vertex_data[0])) * rectangle_vertex_data.len;
    const rectangle_vertex_buffer = try vk.createBuffer(&device, vk.c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, rectangle_buffer_size);
    defer vk.destroyBuffer(&device, rectangle_vertex_buffer);

    const rectangle_vertex_buffer_memory = try vk.createBufferMemory(&device, rectangle_vertex_buffer, vk.c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    defer vk.destroyBufferMemory(&device, rectangle_vertex_buffer_memory);

    try vk.mapMemory(&device, rectangle_vertex_buffer_memory, @ptrCast(&rectangle_vertex_data));

    var current_geometry_instance_count: usize = INITIAL_GEOMETRY_INSTANCE_COUNT;
    var instance_buffer_size = @sizeOf(GeometryInstance) * current_geometry_instance_count;
    var instance_buffer = try vk.createBuffer(&device, vk.c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, instance_buffer_size);
    defer vk.destroyBuffer(&device, instance_buffer);

    var instance_buffer_memory = try vk.createBufferMemory(&device, instance_buffer, vk.c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    defer vk.destroyBufferMemory(&device, instance_buffer_memory);

    const descriptor_pool = try vk.createDescriptorPool(&device, MAX_FRAMES_IN_FLIGHT);
    defer vk.destroyDescriptorPool(&device, descriptor_pool);

    const descriptor_sets = try vk.createDescriptorSets(allocator, &device, descriptor_pool, descriptor_set_layout, MAX_FRAMES_IN_FLIGHT);
    defer vk.destroyDescriptorSets(allocator, descriptor_sets);

    var per_frame_vk_data = [_]PerFrameVulkanData{undefined} ** MAX_FRAMES_IN_FLIGHT;
    defer {
        for (per_frame_vk_data) |data| {
            vk.destroyCommandBuffer(&device, command_pool, data.command_buffer);
            data.sync_objects.deinit(&device);
            vk.destroyBufferMemory(&device, data.uniform_buffer_memory);
            vk.destroyBuffer(&device, data.uniform_buffer);
        }
    }
    for (0..per_frame_vk_data.len) |i| {
        var data = &per_frame_vk_data[i];
        data.descriptor_set = descriptor_sets[i];

        data.command_buffer = try vk.createCommandBuffer(&device, command_pool);
        data.sync_objects = try vk.createSyncObjects(&device);

        const ubo_size = @sizeOf(UniformBufferObject);
        data.uniform_buffer = try vk.createBuffer(&device, vk.c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, ubo_size);
        data.uniform_buffer_memory = try vk.createBufferMemory(&device, data.uniform_buffer, vk.c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        const err = vk.c.vkMapMemory(device.device, data.uniform_buffer_memory, 0, ubo_size, 0, @ptrCast(&data.uniform_buffer_mapped));
        if (err != vk.c.VK_SUCCESS) {
            std.debug.print("Failed to map memory: {s}\n", .{vk.c.string_VkResult(err)});
            return error.MapMemoryFailed;
        }

        const buffer_info = vk.c.VkDescriptorBufferInfo{
            .buffer = data.uniform_buffer,
            .offset = 0,
            .range = @sizeOf(UniformBufferObject), // could also be VK_WHOLE_SIZE
        };

        const image_info = vk.c.VkDescriptorImageInfo{
            .imageLayout = vk.c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .imageView = texture_image.image_view.?,
            .sampler = texture_sampler,
        };

        const descriptor_write = [_]vk.c.VkWriteDescriptorSet{
            .{
                .sType = vk.c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = data.descriptor_set,
                .dstBinding = 0,
                .dstArrayElement = 0,
                .descriptorType = vk.c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .descriptorCount = 1,
                .pBufferInfo = &buffer_info,
                .pImageInfo = null,
                .pTexelBufferView = null,
            },
            .{
                .sType = vk.c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = data.descriptor_set,
                .dstBinding = 1,
                .dstArrayElement = 0,
                .descriptorType = vk.c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .descriptorCount = 1,
                .pBufferInfo = null,
                .pImageInfo = &image_info,
                .pTexelBufferView = null,
            },
        };
        vk.c.vkUpdateDescriptorSets(device.device, descriptor_write.len, &descriptor_write[0], 0, null);
    }

    try window_state.geometry_instances.append(window_state.allocator, .{
        .geometry_type = 1,
        .rotation = window_state.rotation,
        .translation = [2]f32{ 0.0, 0.5 },
        .scale = [2]f32{ 1.0, 1.0 },
    });

    var current_frame: u32 = 0;
    while (!glfw.windowShouldClose(window)) {
        glfw.pollEvents();
        const start = std.time.nanoTimestamp();

        var new_width: i32 = 0;
        var new_height: i32 = 0;
        glfw.getFramebufferSize(window, &new_width, &new_height);

        window_state.rotation += 0.01;

        const ubo = UniformBufferObject{
            .aspect_ratio = @as(f32, @floatFromInt(new_width)) / @as(f32, @floatFromInt(new_height)),
        };

        for (window_state.geometry_instances.items) |*geometry_instance| {
            geometry_instance.rotation += 0.01;
        }

        if (window_state.geometry_instances.items.len > current_geometry_instance_count) {
            _ = vk.c.vkDeviceWaitIdle(device.device);

            current_geometry_instance_count = window_state.geometry_instances.items.len;
            vk.destroyBufferMemory(&device, instance_buffer_memory);
            vk.destroyBuffer(&device, instance_buffer);
            instance_buffer_size = window_state.geometry_instances.items.len * @sizeOf(GeometryInstance);
            instance_buffer = try vk.createBuffer(&device, vk.c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, instance_buffer_size);
            instance_buffer_memory = try vk.createBufferMemory(&device, instance_buffer, vk.c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        }
        try vk.mapMemory(&device, instance_buffer_memory, @ptrCast(window_state.geometry_instances.items));

        const vk_data = per_frame_vk_data[current_frame];
        const should_recreate_swap_chain = try drawFrame(
            &device,
            &swap_chain,
            &pipeline,
            framebuffers,
            &vk_data,
            &ubo,
            rectangle_vertex_buffer,
            rectangle_vertex_data.len,
            instance_buffer,
            window_state.geometry_instances.items.len,
        );
        if (should_recreate_swap_chain) {
            const result = try vk.recreateSwapChain(
                allocator,
                &device,
                &pipeline,
                surface,
                &swap_chain,
                image_views,
                &depth_image,
                framebuffers,
                .{ .width = @intCast(new_width), .height = @intCast(new_height) },
            );
            swap_chain = result.swap_chain;
            image_views = result.image_views;
            depth_image = result.depth_image;
            framebuffers = result.framebuffers;
        }

        current_frame = (current_frame + 1) % MAX_FRAMES_IN_FLIGHT;

        const end = std.time.nanoTimestamp();
        const frame_time_ns = end - start;
        const frame_time_ms = @as(f32, @floatFromInt(frame_time_ns)) / 1_000_000.0;
        if (false) {
            std.debug.print("Frame time: {d:.2} ms - {d} fps\n", .{ frame_time_ms, 1000.0 / frame_time_ms });
        }

        const target_frame_time_ns: u64 = 16 * 1_000_000;
        if (frame_time_ns < target_frame_time_ns) {
            std.Thread.sleep(@intCast(target_frame_time_ns - frame_time_ns));
        }
    }

    const err = vk.c.vkDeviceWaitIdle(device.device);
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

fn createWindowSurface(instance: vk.c.VkInstance, window: *glfw.c.GLFWwindow) vk.c.VkSurfaceKHR {
    var surface: vk.c.VkSurfaceKHR = undefined;
    if (glfw.c.glfwCreateWindowSurface(@ptrCast(instance), window, null, &surface) != vk.c.VK_SUCCESS) {
        return null;
    }
    return surface;
}

fn vertexDescription() vk.VertexDescription {
    const vertex_stride = @sizeOf(Vertex);
    const instance_stride = @sizeOf(GeometryInstance);
    return .{
        .binding_descriptions = &[_]vk.c.VkVertexInputBindingDescription{
            .{
                .binding = 0,
                .stride = vertex_stride,
                .inputRate = vk.c.VK_VERTEX_INPUT_RATE_VERTEX,
            },
            .{
                .binding = 1,
                .stride = instance_stride,
                .inputRate = vk.c.VK_VERTEX_INPUT_RATE_INSTANCE,
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
                .binding = 1,
                .location = 1,
                .format = vk.c.VK_FORMAT_R32_SFLOAT,
                .offset = @offsetOf(GeometryInstance, "geometry_type"),
            },
            .{
                .binding = 1,
                .location = 2,
                .format = vk.c.VK_FORMAT_R32_SFLOAT,
                .offset = @offsetOf(GeometryInstance, "rotation"),
            },
            .{
                .binding = 1,
                .location = 3,
                .format = vk.c.VK_FORMAT_R32G32_SFLOAT,
                .offset = @offsetOf(GeometryInstance, "translation"),
            },
            .{
                .binding = 1,
                .location = 4,
                .format = vk.c.VK_FORMAT_R32G32_SFLOAT,
                .offset = @offsetOf(GeometryInstance, "scale"),
            },
        },
    };
}

fn drawFrame(
    device: *const vk.Device,
    swap_chain: *const vk.SwapChain,
    pipeline: *const vk.Pipeline,
    framebuffers: []vk.c.VkFramebuffer,
    vk_data: *const PerFrameVulkanData,
    ubo: *const UniformBufferObject,
    vertex_buffer: vk.c.VkBuffer,
    vertex_count: usize,
    instance_buffer: vk.c.VkBuffer,
    instance_count: usize,
) !bool {
    var err = vk.c.vkWaitForFences(device.device, 1, &vk_data.sync_objects.in_flight_fence, vk.c.VK_TRUE, vk.c.UINT64_MAX);
    if (err != vk.c.VK_SUCCESS) {
        std.debug.print("Failed to wait for in-flight fence: {s}\n", .{vk.c.string_VkResult(err)});
        return false;
    }

    err = vk.c.vkResetFences(device.device, 1, &vk_data.sync_objects.in_flight_fence);
    if (err != vk.c.VK_SUCCESS) {
        std.debug.print("Failed to reset in-flight fence: {s}\n", .{vk.c.string_VkResult(err)});
        return false;
    }

    var image_index: u32 = 0;
    err = vk.c.vkAcquireNextImageKHR(device.device, swap_chain.swap_chain, vk.c.UINT64_MAX, vk_data.sync_objects.image_available_semaphore, @ptrCast(vk.c.VK_NULL_HANDLE), &image_index);
    if (err == vk.c.VK_ERROR_OUT_OF_DATE_KHR) {
        return true;
    } else if (err != vk.c.VK_SUCCESS and err != vk.c.VK_SUBOPTIMAL_KHR) {
        std.debug.print("Failed to acquire swap chain image: {s}\n", .{vk.c.string_VkResult(err)});
        return error.AcquiringSwapChainImageFailed;
    }

    err = vk.c.vkResetCommandBuffer(vk_data.command_buffer, 0);
    if (err != vk.c.VK_SUCCESS) {
        std.debug.print("Failed to reset command buffer: {s}\n", .{vk.c.string_VkResult(err)});
        return error.ResettingCommandBufferFailed;
    }

    try recordCommandBuffer(
        swap_chain,
        pipeline,
        framebuffers[image_index],
        vk_data.command_buffer,
        vk_data.descriptor_set,
        vertex_buffer,
        vertex_count,
        instance_buffer,
        instance_count,
    );

    const buf: *UniformBufferObject = @ptrCast(@alignCast(vk_data.uniform_buffer_mapped));
    buf.* = ubo.*;

    const wait_semaphores = [_]vk.c.VkSemaphore{vk_data.sync_objects.image_available_semaphore};
    const wait_stages = [_]vk.c.VkPipelineStageFlags{vk.c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT};
    const signal_semaphores = [_]vk.c.VkSemaphore{vk_data.sync_objects.render_finished_semaphore};
    const submit_info = vk.c.VkSubmitInfo{
        .sType = vk.c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &wait_semaphores[0],
        .pWaitDstStageMask = &wait_stages[0],
        .commandBufferCount = 1,
        .pCommandBuffers = &vk_data.command_buffer,
        .signalSemaphoreCount = 1,
        .pSignalSemaphores = &signal_semaphores[0],
    };

    err = vk.c.vkQueueSubmit(device.graphics_queue, 1, &submit_info, vk_data.sync_objects.in_flight_fence);
    if (err != vk.c.VK_SUCCESS) {
        std.debug.print("Failed to submit draw command buffer: {s}\n", .{vk.c.string_VkResult(err)});
        return error.SubmittingDrawCommandBufferFailed;
    }

    const swap_chains = [_]vk.c.VkSwapchainKHR{swap_chain.swap_chain};
    const present_info = vk.c.VkPresentInfoKHR{
        .sType = vk.c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &signal_semaphores[0],
        .swapchainCount = 1,
        .pSwapchains = &swap_chains[0],
        .pImageIndices = &image_index,
        .pResults = null,
    };

    err = vk.c.vkQueuePresentKHR(device.present_queue, &present_info);
    if (err == vk.c.VK_ERROR_OUT_OF_DATE_KHR or err == vk.c.VK_SUBOPTIMAL_KHR) {
        return true;
    } else if (err != vk.c.VK_SUCCESS) {
        std.debug.print("Failed to present swap chain image: {s}\n", .{vk.c.string_VkResult(err)});
        return error.PresentingSwapChainImageFailed;
    }

    return false;
}

pub fn recordCommandBuffer(
    swap_chain: *const vk.SwapChain,
    graphics_pipeline: *const vk.Pipeline,
    framebuffer: vk.c.VkFramebuffer,
    command_buffer: vk.c.VkCommandBuffer,
    descriptor_set: vk.c.VkDescriptorSet,
    vertex_buffer: vk.c.VkBuffer,
    vertex_count: usize,
    instance_buffer: vk.c.VkBuffer,
    instance_count: usize,
) !void {
    const begin_info = vk.c.VkCommandBufferBeginInfo{
        .sType = vk.c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = 0,
        .pInheritanceInfo = null,
    };

    var err = vk.c.vkBeginCommandBuffer(command_buffer, &begin_info);
    if (err != vk.c.VK_SUCCESS) {
        std.debug.print("Failed to begin recording command buffer: {s}\n", .{vk.c.string_VkResult(err)});
        return error.VulkanCommandBufferRecordingFailed;
    }

    const clear_values = [_]vk.c.VkClearValue{
        .{ .color = .{ .float32 = .{ 0.0, 0.0, 0.0, 1.0 } } },
        .{ .depthStencil = .{ .depth = 1.0, .stencil = 0.0 } },
    };
    const render_pass_info = vk.c.VkRenderPassBeginInfo{
        .sType = vk.c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .renderPass = graphics_pipeline.render_pass,
        .framebuffer = framebuffer,
        .renderArea = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = swap_chain.extent,
        },
        .clearValueCount = clear_values.len,
        .pClearValues = &clear_values[0],
    };

    vk.c.vkCmdBeginRenderPass(command_buffer, &render_pass_info, vk.c.VK_SUBPASS_CONTENTS_INLINE);

    vk.c.vkCmdBindPipeline(command_buffer, vk.c.VK_PIPELINE_BIND_POINT_GRAPHICS, graphics_pipeline.pipeline);

    const viewport = vk.c.VkViewport{
        .x = 0.0,
        .y = 0.0,
        .width = @floatFromInt(swap_chain.extent.width),
        .height = @floatFromInt(swap_chain.extent.height),
        .minDepth = 0.0,
        .maxDepth = 1.0,
    };
    vk.c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);

    const scissor = vk.c.VkRect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = swap_chain.extent,
    };
    vk.c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);

    vk.c.vkCmdBindDescriptorSets(command_buffer, vk.c.VK_PIPELINE_BIND_POINT_GRAPHICS, graphics_pipeline.pipeline_layout, 0, 1, &descriptor_set, 0, null);

    const offsets = [_]vk.c.VkDeviceSize{ 0, 0 };
    const vk_vertex_buffers = [_]vk.c.VkBuffer{ vertex_buffer, instance_buffer };
    vk.c.vkCmdBindVertexBuffers(command_buffer, 0, vk_vertex_buffers.len, &vk_vertex_buffers, &offsets);

    vk.c.vkCmdDraw(command_buffer, @intCast(vertex_count), @intCast(instance_count), 0, 0);

    vk.c.vkCmdEndRenderPass(command_buffer);

    err = vk.c.vkEndCommandBuffer(command_buffer);
    if (err != vk.c.VK_SUCCESS) {
        std.debug.print("Failed to end command buffer: {s}\n", .{vk.c.string_VkResult(err)});
        return error.VulkanCommandBufferRecordingFailed;
    }
}
