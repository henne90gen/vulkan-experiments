const std = @import("std");

const glfw = @import("glfw.zig");
const vk = @import("vulkan.zig");

const shader_vert = @embedFile("shader.vert.spv");
const shader_frag = @embedFile("shader.frag.spv");

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

    var swap_chain = try vk.createSwapChain(gpa, physical_device, &device, surface);
    defer swap_chain.deinit(gpa, &device);

    std.debug.print("Swap chain images count: {}\n", .{swap_chain.images.len});

    var image_views = try vk.createImageViews(gpa, &device, &swap_chain);
    defer vk.destroyImageViews(gpa, &device, image_views);

    std.debug.print("Image views count: {}\n", .{image_views.len});

    const pipeline = try vk.createGraphicsPipeline(gpa, &device, &swap_chain, shader_vert, shader_frag);
    defer pipeline.deinit(&device);

    var framebuffers = try vk.createFramebuffers(gpa, &device, &pipeline, &swap_chain, image_views);
    defer vk.destroyFramebuffers(gpa, &device, framebuffers);

    const command_pool = try vk.createCommandPool(gpa, physical_device, surface, &device);
    defer vk.destroyCommandPool(&device, command_pool);

    const command_buffer = try vk.createCommandBuffer(&device, command_pool);
    defer vk.destroyCommandBuffer(&device, command_pool, command_buffer);

    const sync_objects = try vk.createSyncObjects(&device);
    defer sync_objects.deinit(&device);

    while (!glfw.windowShouldClose(window)) {
        glfw.pollEvents();

        const should_recreate_swap_chain = try drawFrame(&device, &sync_objects, &swap_chain, &pipeline, framebuffers, command_buffer);
        if (should_recreate_swap_chain) {
            const result = try vk.recreateSwapChain(
                gpa,
                physical_device,
                &device,
                &pipeline,
                surface,
                &swap_chain,
                image_views,
                framebuffers,
            );
            swap_chain = result.swap_chain;
            image_views = result.image_views;
            framebuffers = result.framebuffers;
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
    sync_objects: *const vk.SyncObjects,
    swap_chain: *const vk.SwapChain,
    pipeline: *const vk.Pipeline,
    framebuffers: []vk.c.VkFramebuffer,
    command_buffer: vk.c.VkCommandBuffer,
) !bool {
    const start = std.time.nanoTimestamp();

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

    try vk.recordCommandBuffer(swap_chain, pipeline, framebuffers, command_buffer, image_index);

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

    const end = std.time.nanoTimestamp();
    const frame_time_ms = @as(f32, @floatFromInt(end - start)) / 1_000_000.0;
    std.debug.print("Frame time: {d:.2} ms - {d} fps\n", .{ frame_time_ms, 1000.0 / frame_time_ms });

    return false;
}
