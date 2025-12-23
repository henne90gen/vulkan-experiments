const std = @import("std");
const zm = @import("zmath");

const glfw = @import("glfw.zig");
const vk = @import("vulkan.zig");
const models = @import("models.zig");
const bmp = @import("bitmap.zig");

const shader_vert = @embedFile("shader.vert.spv");
const shader_frag = @embedFile("shader.frag.spv");
const suzanne = @embedFile("assets/suzanne.obj");
const greenland_grid_velo = @embedFile("assets/greenland_grid_velo.bmp");

const MAX_FRAMES_IN_FLIGHT = 2;

const UniformBufferObject = struct {
    bla: f32 align(16),
    model: zm.Mat align(16),
    view: zm.Mat align(16),
    projection: zm.Mat align(16),
};

pub fn main() !void {
    var allocator = std.heap.DebugAllocator(.{}){};
    defer {
        const result = allocator.deinit();
        switch (result) {
            std.heap.Check.leak => std.debug.print("Memory leak detected!\n", .{}),
            else => {},
        }
    }
    const gpa = allocator.allocator();

    try glfw.init();
    defer glfw.terminate();

    const window = try glfw.createWindow(800, 600, "Hello World");
    defer glfw.destroyWindow(window);

    glfw.setKeyCallback(window, keyCallback);

    const requiredExtensions = glfw.getRequiredInstanceExtensions();
    const instance = try vk.createInstance(gpa, requiredExtensions);
    defer vk.destroyInstance(instance);

    const debug_messenger = try vk.setupDebugMessenger(instance);
    defer vk.destroyDebugMessenger(instance, debug_messenger);

    const surface = createWindowSurface(instance, window);
    defer vk.destroySurface(instance, surface);

    const physical_device = try vk.pickPhysicalDevice(gpa, instance, surface);

    const device = try vk.createLogicalDevice(gpa, physical_device, surface);
    defer device.deinit();

    var width: i32 = 0;
    var height: i32 = 0;
    glfw.getFramebufferSize(window, &width, &height);
    var swap_chain = try vk.createSwapChain(gpa, physical_device, &device, surface, .{ .width = @intCast(width), .height = @intCast(height) });
    defer swap_chain.deinit(gpa, &device);

    std.debug.print("Swap chain images count: {}\n", .{swap_chain.images.len});

    var image_views = try vk.createImageViews(gpa, &device, &swap_chain);
    defer vk.destroyImageViews(gpa, &device, image_views);

    std.debug.print("Image views count: {}\n", .{image_views.len});

    const model = try models.Model.from_memory(gpa, suzanne);
    defer model.deinit(gpa);

    const bitmap = try bmp.Bitmap.from_memory(gpa, greenland_grid_velo);
    defer bitmap.deinit(gpa);

    const descriptor_set_layout = try vk.createDescriptorSetLayout(&device);
    defer vk.destroyDescriptorSetLayout(&device, descriptor_set_layout);

    const vertex_desription = model.vertex_description();
    const pipeline = try vk.createGraphicsPipeline(gpa, physical_device, &device, &swap_chain, shader_vert, shader_frag, descriptor_set_layout, vertex_desription);
    defer pipeline.deinit(&device);

    var depth_image = try vk.createDepthResources(physical_device, &device, .{ .width = @intCast(width), .height = @intCast(height) });
    defer depth_image.deinit(&device);

    var framebuffers = try vk.createFramebuffers(gpa, &device, &pipeline, &swap_chain, image_views, &depth_image);
    defer vk.destroyFramebuffers(gpa, &device, framebuffers);

    const command_pool = try vk.createCommandPool(gpa, physical_device, surface, &device);
    defer vk.destroyCommandPool(&device, command_pool);

    var command_buffers = [_]vk.c.VkCommandBuffer{undefined} ** MAX_FRAMES_IN_FLIGHT;
    var sync_objects_list = [_]vk.SyncObjects{undefined} ** MAX_FRAMES_IN_FLIGHT;
    defer {
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            vk.destroyCommandBuffer(&device, command_pool, command_buffers[i]);
            sync_objects_list[i].deinit(&device);
        }
    }
    for (0..MAX_FRAMES_IN_FLIGHT) |i| {
        const command_buffer = try vk.createCommandBuffer(&device, command_pool);
        command_buffers[i] = command_buffer;

        const sync_objects = try vk.createSyncObjects(&device);
        sync_objects_list[i] = sync_objects;
    }

    const texture_image = try vk.createTextureImage(physical_device, &device, command_pool, bitmap.pixels, @intCast(bitmap.width), @intCast(bitmap.height), 3);
    defer texture_image.deinit(&device);

    const vertex_data = try model.to_interleaved_data(gpa);
    defer gpa.free(vertex_data);

    const buffer_size = @sizeOf(@TypeOf(vertex_data[0])) * vertex_data.len;
    const vertex_buffer = try vk.createBuffer(&device, vk.c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, buffer_size);
    defer vk.destroyBuffer(&device, vertex_buffer);

    const vertex_buffer_memory = try vk.createBufferMemory(physical_device, &device, vertex_buffer, vk.c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    defer vk.destroyBufferMemory(&device, vertex_buffer_memory);

    try vk.mapMemory(&device, vertex_buffer_memory, @ptrCast(vertex_data));

    var uniform_buffers = [_]vk.c.VkBuffer{undefined} ** MAX_FRAMES_IN_FLIGHT;
    var uniform_buffers_memory = [_]vk.c.VkDeviceMemory{undefined} ** MAX_FRAMES_IN_FLIGHT;
    var uniform_buffers_mapped = [_]*void{undefined} ** MAX_FRAMES_IN_FLIGHT;
    for (0..MAX_FRAMES_IN_FLIGHT) |i| {
        const ubo_size = @sizeOf(UniformBufferObject);
        uniform_buffers[i] = try vk.createBuffer(&device, vk.c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, ubo_size);
        uniform_buffers_memory[i] = try vk.createBufferMemory(physical_device, &device, uniform_buffers[i], vk.c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        const err = vk.c.vkMapMemory(device.device, uniform_buffers_memory[i], 0, ubo_size, 0, @ptrCast(&uniform_buffers_mapped[i]));
        if (err != vk.c.VK_SUCCESS) {
            std.debug.print("Failed to map memory: {s}\n", .{vk.c.string_VkResult(err)});
            return error.MapMemoryFailed;
        }
    }
    defer {
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            vk.destroyBufferMemory(&device, uniform_buffers_memory[i]);
            vk.destroyBuffer(&device, uniform_buffers[i]);
        }
    }

    const descriptor_pool = try vk.createDescriptorPool(&device, MAX_FRAMES_IN_FLIGHT);
    defer vk.destroyDescriptorPool(&device, descriptor_pool);

    const descriptor_sets = try vk.createDescriptorSets(gpa, &device, descriptor_pool, descriptor_set_layout, MAX_FRAMES_IN_FLIGHT);
    defer vk.destroyDescriptorSets(gpa, descriptor_sets);

    for (0..MAX_FRAMES_IN_FLIGHT) |i| {
        const buffer_info = vk.c.VkDescriptorBufferInfo{
            .buffer = uniform_buffers[i],
            .offset = 0,
            .range = @sizeOf(UniformBufferObject), // could also be VK_WHOLE_SIZE
        };

        const descriptor_write = vk.c.VkWriteDescriptorSet{
            .sType = vk.c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = descriptor_sets[i],
            .dstBinding = 0,
            .dstArrayElement = 0,
            .descriptorType = vk.c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .pBufferInfo = &buffer_info,
            .pImageInfo = null,
            .pTexelBufferView = null,
        };
        vk.c.vkUpdateDescriptorSets(device.device, 1, &descriptor_write, 0, null);
    }

    var rotation: f32 = 0.0;

    var current_frame: u32 = 0;
    while (!glfw.windowShouldClose(window)) {
        glfw.pollEvents();
        const start = std.time.nanoTimestamp();

        var new_width: i32 = 0;
        var new_height: i32 = 0;
        glfw.getFramebufferSize(window, &new_width, &new_height);

        rotation += 0.001;
        const object_to_world = zm.rotationY(rotation);
        const world_to_view = zm.lookAtRh(
            zm.f32x4(0.0, 0.0, 3.0, 1.0), // eye position
            zm.f32x4(0.0, 0.0, 0.0, 1.0), // focus point
            zm.f32x4(0.0, -1.0, 0.0, 0.0), // up direction ('w' coord is zero because this is a vector not a point)
        );
        const aspect_ratio: f32 = @as(f32, @floatFromInt(new_width)) / @as(f32, @floatFromInt(new_height));
        const view_to_clip = zm.perspectiveFovRh(0.25 * std.math.pi, aspect_ratio, 0.1, 20.0);

        const ubo = UniformBufferObject{
            .bla = 1.0,
            .model = object_to_world,
            .view = world_to_view,
            .projection = view_to_clip,
        };

        const command_buffer = command_buffers[current_frame];
        const sync_objects = &sync_objects_list[current_frame];
        const uniform_buffer_mapped = uniform_buffers_mapped[current_frame];
        const descriptor_set = descriptor_sets[current_frame];
        const should_recreate_swap_chain = try drawFrame(
            &device,
            &swap_chain,
            &pipeline,
            framebuffers,
            command_buffer,
            sync_objects,
            descriptor_set,
            vertex_buffer,
            vertex_data.len,
            uniform_buffer_mapped,
            &ubo,
        );
        if (should_recreate_swap_chain) {
            const result = try vk.recreateSwapChain(
                gpa,
                physical_device,
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
        const frame_time_ms = @as(f32, @floatFromInt(end - start)) / 1_000_000.0;
        std.debug.print("Frame time: {d:.2} ms - {d} fps\n", .{ frame_time_ms, 1000.0 / frame_time_ms });
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
    if (key == glfw.c.GLFW_KEY_ESCAPE and action == glfw.c.GLFW_PRESS) {
        glfw.setWindowShouldClose(window.?, true);
    }
}

fn createWindowSurface(instance: vk.c.VkInstance, window: *glfw.c.GLFWwindow) vk.c.VkSurfaceKHR {
    var surface: vk.c.VkSurfaceKHR = undefined;
    if (glfw.c.glfwCreateWindowSurface(@ptrCast(instance), window, null, &surface) != vk.c.VK_SUCCESS) {
        return null;
    }
    return surface;
}

fn drawFrame(
    device: *const vk.Device,
    swap_chain: *const vk.SwapChain,
    pipeline: *const vk.Pipeline,
    framebuffers: []vk.c.VkFramebuffer,
    command_buffer: vk.c.VkCommandBuffer,
    sync_objects: *const vk.SyncObjects,
    descriptor_set: vk.c.VkDescriptorSet,
    vertex_buffer: vk.c.VkBuffer,
    vertex_count: usize,
    uniform_buffer_mapped: *void,
    ubo: *const UniformBufferObject,
) !bool {
    var err = vk.c.vkWaitForFences(device.device, 1, &sync_objects.in_flight_fence, vk.c.VK_TRUE, vk.c.UINT64_MAX);
    if (err != vk.c.VK_SUCCESS) {
        std.debug.print("Failed to wait for in-flight fence: {s}\n", .{vk.c.string_VkResult(err)});
        return false;
    }

    err = vk.c.vkResetFences(device.device, 1, &sync_objects.in_flight_fence);
    if (err != vk.c.VK_SUCCESS) {
        std.debug.print("Failed to reset in-flight fence: {s}\n", .{vk.c.string_VkResult(err)});
        return false;
    }

    var image_index: u32 = 0;
    err = vk.c.vkAcquireNextImageKHR(device.device, swap_chain.swap_chain, vk.c.UINT64_MAX, sync_objects.image_available_semaphore, @ptrCast(vk.c.VK_NULL_HANDLE), &image_index);
    if (err == vk.c.VK_ERROR_OUT_OF_DATE_KHR) {
        return true;
    } else if (err != vk.c.VK_SUCCESS and err != vk.c.VK_SUBOPTIMAL_KHR) {
        std.debug.print("Failed to acquire swap chain image: {s}\n", .{vk.c.string_VkResult(err)});
        return error.AcquiringSwapChainImageFailed;
    }

    err = vk.c.vkResetCommandBuffer(command_buffer, 0);
    if (err != vk.c.VK_SUCCESS) {
        std.debug.print("Failed to reset command buffer: {s}\n", .{vk.c.string_VkResult(err)});
        return error.ResettingCommandBufferFailed;
    }

    try vk.recordCommandBuffer(swap_chain, pipeline, framebuffers, command_buffer, descriptor_set, vertex_buffer, @intCast(vertex_count), image_index);

    const buf: *UniformBufferObject = @ptrCast(@alignCast(uniform_buffer_mapped));
    buf.* = ubo.*;

    const wait_semaphores = [_]vk.c.VkSemaphore{sync_objects.image_available_semaphore};
    const wait_stages = [_]vk.c.VkPipelineStageFlags{vk.c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT};
    const signal_semaphores = [_]vk.c.VkSemaphore{sync_objects.render_finished_semaphore};
    const submit_info = vk.c.VkSubmitInfo{
        .sType = vk.c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &wait_semaphores[0],
        .pWaitDstStageMask = &wait_stages[0],
        .commandBufferCount = 1,
        .pCommandBuffers = &command_buffer,
        .signalSemaphoreCount = 1,
        .pSignalSemaphores = &signal_semaphores[0],
    };

    err = vk.c.vkQueueSubmit(device.graphics_queue, 1, &submit_info, sync_objects.in_flight_fence);
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

test {
    std.testing.refAllDeclsRecursive(@This());
}
