const std = @import("std");

const vk = @import("vulkan.zig");
const glfw = @import("glfw.zig");
const bmp = @import("bitmap.zig");

const shader_vert = @embedFile("shader.vert.spv");
const shader_frag = @embedFile("shader.frag.spv");
const greenland_grid_velo = @embedFile("assets/greenland_grid_velo.bmp");

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    instance: vk.c.VkInstance,
    debug_messenger: vk.c.VkDebugUtilsMessengerEXT,
    surface: vk.c.VkSurfaceKHR,
    device: vk.Device,
    swap_chain: vk.SwapChain,
    image_views: []vk.c.VkImageView,
    descriptor_set_layout: vk.c.VkDescriptorSetLayout,
    pipeline: vk.Pipeline,
    depth_image: vk.ImageResource,
    framebuffers: []vk.c.VkFramebuffer,
    command_pool: vk.c.VkCommandPool,

    pub fn init(allocator: std.mem.Allocator, window: glfw.c.GLFWwindow) !Renderer {
        const requiredExtensions = glfw.getRequiredInstanceExtensions();
        const instance = try vk.createInstance(allocator, requiredExtensions);
        errdefer vk.destroyInstance(instance);

        const debug_messenger = try vk.setupDebugMessenger(instance);
        errdefer vk.destroyDebugMessenger(instance, debug_messenger);

        const surface = createWindowSurface(instance, window);
        errdefer vk.destroySurface(instance, surface);

        const device = try vk.Device.init(allocator, instance, surface);
        errdefer device.deinit();

        const framebuffer_size = glfw.getFramebufferSize(window);
        const swap_chain = try vk.SwapChain.init(allocator, &device, surface, .{ .width = @intCast(framebuffer_size.width), .height = @intCast(framebuffer_size.height) });
        errdefer swap_chain.deinit(allocator, &device);

        std.debug.print("Swap chain images count: {}\n", .{swap_chain.images.len});

        const image_views = try vk.createImageViews(allocator, &device, &swap_chain);
        errdefer vk.destroyImageViews(allocator, &device, image_views);

        std.debug.print("Image views count: {}\n", .{image_views.len});

        const descriptor_set_layout = try vk.createDescriptorSetLayout(&device);
        errdefer vk.destroyDescriptorSetLayout(&device, descriptor_set_layout);

        const vertex_desription = vertexDescription();
        const pipeline = try vk.createGraphicsPipeline(allocator, &device, &swap_chain, shader_vert, shader_frag, descriptor_set_layout, vertex_desription);
        errdefer pipeline.deinit(&device);

        const depth_image = try vk.createDepthResources(&device, .{ .width = @intCast(framebuffer_size.width), .height = @intCast(framebuffer_size.height) });
        errdefer depth_image.deinit(&device);

        const framebuffers = try vk.createFramebuffers(allocator, &device, &pipeline, &swap_chain, image_views, &depth_image);
        errdefer vk.destroyFramebuffers(allocator, &device, framebuffers);

        const command_pool = try vk.createCommandPool(allocator, surface, &device);
        errdefer vk.destroyCommandPool(&device, command_pool);

        { // load image texture
            const bitmap = try bmp.Bitmap.from_memory(allocator, greenland_grid_velo);
            errdefer bitmap.deinit(allocator);

            const texture_image = try vk.createTextureImage(&device, command_pool, bitmap.pixels, bitmap.width, bitmap.height, bitmap.bytes_per_pixel);
            errdefer texture_image.deinit(&device);

            const texture_sampler = try vk.createTextureSampler(&device);
            errdefer vk.destroyTextureSampler(&device, texture_sampler);
        }

        return Renderer{
            .allocator = allocator,
            .instance = instance,
            .debug_messenger = debug_messenger,
            .surface = surface,
            .device = device,
            .swap_chain = swap_chain,
            .image_views = image_views,
            .descriptor_set_layout = descriptor_set_layout,
            .pipeline = pipeline,
            .depth_image = depth_image,
            .framebuffers = framebuffers,
            .command_pool = command_pool,
        };
    }

    pub fn deinit(self: *const Renderer) void {
        vk.destroyCommandPool(&self.device, self.command_pool);
        vk.destroyFramebuffers(self.allocator, &self.device, self.framebuffers);
        self.depth_image.deinit(&self.device);
        self.pipeline.deinit(&self.device);
        vk.destroyDescriptorSetLayout(&self.device, self.descriptor_set_layout);
        vk.destroyImageViews(self.allocator, &self.device, self.image_views);
        self.swap_chain.deinit(self.allocator, &self.device);
        self.device.deinit();
        vk.destroySurface(self.instance, self.surface);
        vk.destroyDebugMessenger(self.instance, self.debug_messenger);
        vk.destroyInstance(self.instance);
    }
};

pub const PerFrameVulkanData = struct {
    command_buffer: vk.c.VkCommandBuffer,
    sync_objects: vk.SyncObjects,
    uniform_buffer: vk.c.VkBuffer = undefined,
    uniform_buffer_memory: vk.c.VkDeviceMemory = undefined,
    uniform_buffer_mapped: *void = undefined,
    descriptor_set: vk.c.VkDescriptorSet = undefined,
};

pub const UniformBufferObject = extern struct {
    aspect_ratio: f32 align(4),
    zoom: f32 align(4),
};

pub const Vertex = extern struct {
    position: [3]f32 align(16),
};

pub const GeometryInstance = extern struct {
    geometry_type: f32 align(4),
    rotation: f32 align(4),
    translation: [2]f32 align(8),
    scale: [2]f32 align(8),
};

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

fn recordCommandBuffer(
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
