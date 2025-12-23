const std = @import("std");
const builtin = @import("builtin");

pub const c = @cImport({
    @cInclude("vulkan/vulkan.h");
    @cInclude("vulkan/vk_enum_string_helper.h");
});

const is_debug_build = switch (builtin.mode) {
    .ReleaseFast => false,
    .ReleaseSmall => false,
    else => true,
};

const REQUIRED_EXTENSIONS = [_][]const u8{
    "VK_KHR_swapchain",
};

const QueueFamilyIndices = struct {
    graphics_family: ?u32 = null,
    present_family: ?u32 = null,

    pub fn is_complete(self: *const QueueFamilyIndices) bool {
        return self.graphics_family != null and self.present_family != null;
    }
};

pub const Device = struct {
    device: c.VkDevice,
    queue_family_indices: QueueFamilyIndices,
    graphics_queue: c.VkQueue,
    present_queue: c.VkQueue,

    pub fn deinit(self: *const Device) void {
        c.vkDestroyDevice(self.device, null);
    }
};

pub const SwapChain = struct {
    swap_chain: c.VkSwapchainKHR = undefined,
    images: []c.VkImage = undefined,
    surface_format: c.VkSurfaceFormatKHR = .{},
    present_mode: c.VkPresentModeKHR = c.VK_PRESENT_MODE_FIFO_KHR,
    extent: c.VkExtent2D = .{},

    pub fn deinit(self: *const SwapChain, gpa: std.mem.Allocator, device: *const Device) void {
        gpa.free(self.images);
        c.vkDestroySwapchainKHR(device.device, self.swap_chain, null);
    }
};

const SwapChainSupportDetails = struct {
    capabilities: c.VkSurfaceCapabilitiesKHR = .{},
    formats: []c.VkSurfaceFormatKHR = &.{},
    present_modes: []c.VkPresentModeKHR = &.{},

    pub fn deinit(self: *const SwapChainSupportDetails, gpa: std.mem.Allocator) void {
        gpa.free(self.formats);
        gpa.free(self.present_modes);
    }
};

pub const Pipeline = struct {
    pipeline_layout: c.VkPipelineLayout = undefined,
    render_pass: c.VkRenderPass = undefined,
    pipeline: c.VkPipeline = undefined,

    pub fn deinit(self: *const Pipeline, device: *const Device) void {
        c.vkDestroyPipelineLayout(device.device, self.pipeline_layout, null);
        c.vkDestroyRenderPass(device.device, self.render_pass, null);
        c.vkDestroyPipeline(device.device, self.pipeline, null);
    }
};

pub const SyncObjects = struct {
    in_flight_fence: c.VkFence = undefined,
    image_available_semaphore: c.VkSemaphore = undefined,
    render_finished_semaphore: c.VkSemaphore = undefined,

    pub fn deinit(self: *const SyncObjects, device: *const Device) void {
        c.vkDestroySemaphore(device.device, self.image_available_semaphore, null);
        c.vkDestroySemaphore(device.device, self.render_finished_semaphore, null);
        c.vkDestroyFence(device.device, self.in_flight_fence, null);
    }
};

pub const VertexDescription = struct {
    binding_descriptions: []const c.VkVertexInputBindingDescription,
    attribute_descriptions: []const c.VkVertexInputAttributeDescription,
};

pub const Image = struct {
    image: c.VkImage,
    memory: c.VkDeviceMemory,
    image_view: ?c.VkImageView,

    pub fn deinit(self: *const Image, device: *const Device) void {
        c.vkDestroyImage(device.device, self.image, null);
        c.vkFreeMemory(device.device, self.memory, null);
        c.vkDestroyImageView(device.device, self.image_view.?, null);
    }
};

pub fn createInstance(gpa: std.mem.Allocator, required_extensions: [][*:0]const u8) !c.VkInstance {
    var app_info = c.VkApplicationInfo{};
    app_info.sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app_info.pApplicationName = "Hello Triangle";
    app_info.applicationVersion = c.VK_MAKE_VERSION(0, 0, 1);
    app_info.pEngineName = "No Engine";
    app_info.engineVersion = c.VK_MAKE_VERSION(0, 0, 1);
    app_info.apiVersion = c.VK_API_VERSION_1_0;

    var create_info = c.VkInstanceCreateInfo{};
    create_info.sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    create_info.pApplicationInfo = &app_info;
    create_info.enabledLayerCount = 0;

    var extensions = try std.ArrayList([*:0]const u8).initCapacity(gpa, required_extensions.len);
    defer extensions.deinit(gpa);
    for (required_extensions) |extension_name| {
        try extensions.append(gpa, extension_name);
    }

    if (is_debug_build) {
        try extensions.append(gpa, c.VK_EXT_DEBUG_UTILS_EXTENSION_NAME);
        std.debug.print("Enabling required extensions:\n", .{});
        for (extensions.items) |extension_name| {
            std.debug.print("  {s}\n", .{extension_name});
        }
    }
    create_info.enabledExtensionCount = @intCast(extensions.items.len);
    create_info.ppEnabledExtensionNames = @ptrCast(extensions.items);

    var debug_create_info = defaultDebugUtilsMessengerCreateInfo();
    if (is_debug_build) {
        create_info.pNext = &debug_create_info;

        const validation_layer_name = "VK_LAYER_KHRONOS_validation";
        if (!try checkValidationLayerSupport(gpa, validation_layer_name)) {
            std.debug.print("Missing '{s}'. Install vulkan validation layers (e.g. 'sudo pacman -S vulkan-validation-layers')\n", .{validation_layer_name});
            return error.VulkanValidationLayerNotAvailable;
        }

        create_info.enabledLayerCount = 1;
        create_info.ppEnabledLayerNames = @ptrCast(&validation_layer_name);
    }

    var instance: c.VkInstance = null;
    const result = c.vkCreateInstance(&create_info, null, &instance);
    if (result != c.VK_SUCCESS) {
        std.debug.print("Failed to create vulkan instance: {s}\n", .{c.string_VkResult(result)});
        return error.VulkanInstanceCreationFailed;
    }
    return instance;
}

pub fn destroyInstance(instance: c.VkInstance) void {
    c.vkDestroyInstance(instance, null);
}

fn checkValidationLayerSupport(gpa: std.mem.Allocator, layer_name: [:0]const u8) !bool {
    var layer_count: u32 = 0;
    if (c.vkEnumerateInstanceLayerProperties(&layer_count, null) != c.VK_SUCCESS) {
        return error.VulkanLayerEnumerationFailed;
    }

    var available_layers = try gpa.alloc(c.VkLayerProperties, layer_count);
    defer gpa.free(available_layers);
    if (c.vkEnumerateInstanceLayerProperties(&layer_count, &available_layers[0]) != c.VK_SUCCESS) {
        return error.VulkanLayerEnumerationFailed;
    }

    for (available_layers) |layer_prop| {
        if (std.mem.eql(u8, layer_name, layer_prop.layerName[0..layer_name.len])) {
            return true;
        }
    }

    return false;
}

fn defaultDebugUtilsMessengerCreateInfo() c.VkDebugUtilsMessengerCreateInfoEXT {
    return .{
        .sType = c.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
        .messageSeverity = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
        .messageType = c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
        .pfnUserCallback = debugCallback,
        .pUserData = null,
    };
}

pub fn setupDebugMessenger(instance: c.VkInstance) !c.VkDebugUtilsMessengerEXT {
    if (!is_debug_build) {
        return null;
    }

    var create_info = defaultDebugUtilsMessengerCreateInfo();
    var debug_messenger: c.VkDebugUtilsMessengerEXT = null;
    const func_opt: c.PFN_vkCreateDebugUtilsMessengerEXT = @ptrCast(c.vkGetInstanceProcAddr(instance, "vkCreateDebugUtilsMessengerEXT"));
    const func = func_opt orelse return error.VulkanExtensionFunctionNotFound;
    const result = func(instance, &create_info, null, &debug_messenger);
    if (result != c.VK_SUCCESS) {
        return error.VulkanDebugMessengerCreationFailed;
    }

    return debug_messenger;
}

pub fn destroyDebugMessenger(instance: c.VkInstance, debugMessenger: c.VkDebugUtilsMessengerEXT) void {
    if (!is_debug_build) {
        return;
    }

    const func_opt: c.PFN_vkDestroyDebugUtilsMessengerEXT = @ptrCast(c.vkGetInstanceProcAddr(instance, "vkDestroyDebugUtilsMessengerEXT"));
    const func = func_opt orelse return;
    func(instance, debugMessenger, null);
}

export fn debugCallback(messageSeverity: c.VkDebugUtilsMessageSeverityFlagBitsEXT, messageType: c.VkDebugUtilsMessageTypeFlagsEXT, pCallbackData: [*c]const c.VkDebugUtilsMessengerCallbackDataEXT, pUserData: ?*anyopaque) c.VkBool32 {
    _ = messageSeverity;
    _ = messageType;
    _ = pUserData;
    std.debug.print("[VK] {s}\n", .{pCallbackData[0].pMessage});
    return c.VK_FALSE;
}

pub fn pickPhysicalDevice(gpa: std.mem.Allocator, instance: c.VkInstance, surface: c.VkSurfaceKHR) !c.VkPhysicalDevice {
    var device_count: u32 = 0;
    if (c.vkEnumeratePhysicalDevices(instance, &device_count, null) != c.VK_SUCCESS) {
        return error.VulkanPhysicalDeviceEnumerationFailed;
    }
    if (device_count == 0) {
        std.debug.print("Failed to find GPUs with Vulkan support!\n", .{});
        return error.VulkanNoSuitableGPUFound;
    }

    var devices = try gpa.alloc(c.VkPhysicalDevice, device_count);
    defer gpa.free(devices);
    if (c.vkEnumeratePhysicalDevices(instance, &device_count, &devices[0]) != c.VK_SUCCESS) {
        return error.VulkanPhysicalDeviceEnumerationFailed;
    }

    std.debug.print("Found {d} GPU(s) with Vulkan support:\n", .{device_count});

    for (devices[0..device_count]) |device| {
        const isSuitable = try isDeviceSuitable(gpa, device, surface);
        var device_properties: c.VkPhysicalDeviceProperties = undefined;
        c.vkGetPhysicalDeviceProperties(device, &device_properties);
        const device_name: [:0]const u8 = @ptrCast(&device_properties.deviceName);
        std.debug.print("  - {s} (suitable={})\n", .{ device_name, isSuitable });
        if (isSuitable) {
            std.debug.print("Selected GPU: {s}\n", .{device_name});
            return device;
        }
    }

    return error.VulkanNoSuitableGPUFound;
}

fn isDeviceSuitable(gpa: std.mem.Allocator, device: c.VkPhysicalDevice, surface: c.VkSurfaceKHR) !bool {
    const indices = try findQueueFamilies(gpa, device, surface);
    const extensionsSupported = try checkDeviceExtensionSupport(gpa, device);
    var swapChainAdequate = false;
    if (extensionsSupported) {
        const swap_chain_support = try querySwapChainSupport(gpa, device, surface);
        defer swap_chain_support.deinit(gpa);
        swapChainAdequate = swap_chain_support.formats.len != 0 and swap_chain_support.present_modes.len != 0;
    }
    return indices.is_complete() and extensionsSupported;
}

fn checkDeviceExtensionSupport(gpa: std.mem.Allocator, device: c.VkPhysicalDevice) !bool {
    var extension_count: u32 = 0;
    var result = c.vkEnumerateDeviceExtensionProperties(device, null, &extension_count, null);
    if (result != c.VK_SUCCESS) {
        std.debug.print("Failed to enumerate device extension properties: {s}\n", .{c.string_VkResult(result)});
        return error.VulkanDeviceExtensionEnumerationFailed;
    }

    const available_extensions = try gpa.alloc(c.VkExtensionProperties, extension_count);
    defer gpa.free(available_extensions);
    result = c.vkEnumerateDeviceExtensionProperties(device, null, &extension_count, &available_extensions[0]);
    if (result != c.VK_SUCCESS) {
        std.debug.print("Failed to enumerate device extension properties: {s}\n", .{c.string_VkResult(result)});
        return error.VulkanDeviceExtensionEnumerationFailed;
    }

    var found_all_extensions = true;
    for (REQUIRED_EXTENSIONS) |extension_name| {
        var found_extesion = false;
        for (available_extensions) |extension| {
            if (std.mem.eql(u8, extension_name, extension.extensionName[0..extension_name.len])) {
                found_extesion = true;
                break;
            }
        }
        if (!found_extesion) {
            std.debug.print("Failed to find extension '{s}'\n", .{extension_name});
            found_all_extensions = false;
            break;
        }
    }

    return found_all_extensions;
}

fn findQueueFamilies(gpa: std.mem.Allocator, device: c.VkPhysicalDevice, surface: c.VkSurfaceKHR) !QueueFamilyIndices {
    var queue_family_count: u32 = 0;
    c.vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, null);

    var queue_families = try gpa.alloc(c.VkQueueFamilyProperties, queue_family_count);
    defer gpa.free(queue_families);
    c.vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, &queue_families[0]);

    var indices = QueueFamilyIndices{};
    for (0..queue_family_count) |i| {
        const queue_family = queue_families[i];
        if ((queue_family.queueFlags & c.VK_QUEUE_GRAPHICS_BIT) != 0) {
            indices.graphics_family = @intCast(i);
        }

        var present_support: c.VkBool32 = c.VK_FALSE;
        const result = c.vkGetPhysicalDeviceSurfaceSupportKHR(device, @intCast(i), surface, &present_support);
        if (result != c.VK_SUCCESS) {
            std.debug.print("Failed to query for physical device surface support: {s}\n", .{c.string_VkResult(result)});
            return error.VulkanSurfaceSupportQueryFailed;
        }
        if (present_support == c.VK_TRUE) {
            indices.present_family = @intCast(i);
        }

        if (indices.is_complete()) {
            break;
        }
    }

    if (!indices.is_complete()) {
        return error.VulkanRequiredQueueFamiliesNotFound;
    }

    return indices;
}

pub fn createLogicalDevice(gpa: std.mem.Allocator, physical_device: c.VkPhysicalDevice, surface: c.VkSurfaceKHR) !Device {
    const indices = try findQueueFamilies(gpa, physical_device, surface);

    var unique_queue_families = std.AutoHashMap(u32, void).init(gpa);
    defer unique_queue_families.deinit();
    if (indices.graphics_family != null) {
        _ = try unique_queue_families.put(indices.graphics_family.?, {});
    }
    if (indices.present_family != null) {
        _ = try unique_queue_families.put(indices.present_family.?, {});
    }

    var queue_create_infos = std.ArrayList(c.VkDeviceQueueCreateInfo).empty;
    defer queue_create_infos.deinit(gpa);
    const queue_priority: f32 = 1.0;
    var iter = unique_queue_families.keyIterator();
    while (iter.next()) |queue_family| {
        const queue_create_info = c.VkDeviceQueueCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .queueFamilyIndex = queue_family.*,
            .queueCount = 1,
            .pQueuePriorities = &queue_priority,
        };
        try queue_create_infos.append(gpa, queue_create_info);
    }

    const device_features = c.VkPhysicalDeviceFeatures{};
    const create_info = c.VkDeviceCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = @intCast(queue_create_infos.items.len),
        .pQueueCreateInfos = @ptrCast(queue_create_infos.items),
        .pEnabledFeatures = &device_features,
        .enabledExtensionCount = REQUIRED_EXTENSIONS.len,
        .ppEnabledExtensionNames = @ptrCast(&REQUIRED_EXTENSIONS[0]),
        .enabledLayerCount = 0,
    };

    var device: c.VkDevice = null;
    const result = c.vkCreateDevice(physical_device, &create_info, null, &device);
    if (result != c.VK_SUCCESS) {
        std.debug.print("Failed to create logical device: {s}\n", .{c.string_VkResult(result)});
        return error.VulkanLogicalDeviceCreationFailed;
    }

    var graphics_queue: c.VkQueue = undefined;
    c.vkGetDeviceQueue(device, indices.graphics_family.?, 0, &graphics_queue);

    var present_queue: c.VkQueue = undefined;
    c.vkGetDeviceQueue(device, indices.present_family.?, 0, &present_queue);

    return .{
        .device = device,
        .queue_family_indices = indices,
        .graphics_queue = graphics_queue,
        .present_queue = present_queue,
    };
}

pub fn destroySurface(instance: c.VkInstance, surface: c.VkSurfaceKHR) void {
    c.vkDestroySurfaceKHR(instance, surface, null);
}

fn querySwapChainSupport(gpa: std.mem.Allocator, device: c.VkPhysicalDevice, surface: c.VkSurfaceKHR) !SwapChainSupportDetails {
    var result = SwapChainSupportDetails{};
    var err = c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(device, surface, &result.capabilities);
    if (err != c.VK_SUCCESS) {
        std.debug.print("Failed to get physical device surface capabilities: {s}\n", .{c.string_VkResult(err)});
        return error.VulkanSurfaceCapabilitiesQueryFailed;
    }

    var format_count: u32 = 0;
    err = c.vkGetPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, null);
    if (err != c.VK_SUCCESS) {
        std.debug.print("Failed to get physical device surface formats: {s}\n", .{c.string_VkResult(err)});
        return error.VulkanSurfaceFormatsQueryFailed;
    }

    if (format_count != 0) {
        var formats = try gpa.alloc(c.VkSurfaceFormatKHR, format_count);
        errdefer gpa.free(formats);
        err = c.vkGetPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, &formats[0]);
        if (err != c.VK_SUCCESS) {
            std.debug.print("Failed to get physical device surface formats: {s}\n", .{c.string_VkResult(err)});
            return error.VulkanSurfaceFormatsQueryFailed;
        }

        result.formats = formats;
    }

    var present_mode_count: u32 = 0;
    err = c.vkGetPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_mode_count, null);
    if (err != c.VK_SUCCESS) {
        std.debug.print("Failed to get physical device surface present modes: {s}\n", .{c.string_VkResult(err)});
        return error.VulkanSurfaceFormatsQueryFailed;
    }

    if (present_mode_count != 0) {
        var present_modes = try gpa.alloc(c.VkPresentModeKHR, present_mode_count);
        errdefer gpa.free(present_modes);
        err = c.vkGetPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_mode_count, &present_modes[0]);
        if (err != c.VK_SUCCESS) {
            std.debug.print("Failed to get physical device surface present modes: {s}\n", .{c.string_VkResult(err)});
            return error.VulkanSurfaceFormatsQueryFailed;
        }

        result.present_modes = present_modes;
    }

    return result;
}

fn chooseSwapSurfaceFormat(available_formats: []c.VkSurfaceFormatKHR) c.VkSurfaceFormatKHR {
    for (available_formats) |format| {
        if (format.format == c.VK_FORMAT_B8G8R8A8_SRGB and format.colorSpace == c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
            return format;
        }
    }
    return available_formats[0];
}

fn chooseSwapPresentMode(available_present_modes: []c.VkPresentModeKHR) c.VkPresentModeKHR {
    for (available_present_modes) |present_mode| {
        if (present_mode == c.VK_PRESENT_MODE_MAILBOX_KHR) {
            return present_mode;
        }
    }

    return c.VK_PRESENT_MODE_FIFO_KHR;
}

fn chooseSwapExtent(capabilities: c.VkSurfaceCapabilitiesKHR, extent: c.VkExtent2D) c.VkExtent2D {
    if (capabilities.currentExtent.width != std.math.maxInt(u32)) {
        return capabilities.currentExtent;
    }

    var actual_extent = extent;
    actual_extent.width = std.math.clamp(actual_extent.width, capabilities.minImageExtent.width, capabilities.maxImageExtent.width);
    actual_extent.height = std.math.clamp(actual_extent.height, capabilities.minImageExtent.height, capabilities.maxImageExtent.height);
    return actual_extent;
}

pub fn createSwapChain(gpa: std.mem.Allocator, physical_device: c.VkPhysicalDevice, device: *const Device, surface: c.VkSurfaceKHR, extent: c.VkExtent2D) !SwapChain {
    const swap_chain_support = try querySwapChainSupport(gpa, physical_device, surface);
    defer swap_chain_support.deinit(gpa);

    var swap_chain = SwapChain{
        .surface_format = chooseSwapSurfaceFormat(swap_chain_support.formats),
        .present_mode = chooseSwapPresentMode(swap_chain_support.present_modes),
        .extent = chooseSwapExtent(swap_chain_support.capabilities, extent),
    };
    var image_count = swap_chain_support.capabilities.minImageCount + 1;
    if (swap_chain_support.capabilities.maxImageCount > 0 and image_count > swap_chain_support.capabilities.maxImageCount) {
        image_count = swap_chain_support.capabilities.maxImageCount;
    }

    var create_info = c.VkSwapchainCreateInfoKHR{
        .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = surface,
        .minImageCount = image_count,
        .imageFormat = swap_chain.surface_format.format,
        .imageColorSpace = swap_chain.surface_format.colorSpace,
        .imageExtent = swap_chain.extent,
        .imageArrayLayers = 1,
        .imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .preTransform = swap_chain_support.capabilities.currentTransform,
        .compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        .presentMode = swap_chain.present_mode,
        .clipped = c.VK_TRUE,
        .oldSwapchain = @ptrCast(c.VK_NULL_HANDLE),
    };

    const indices = try findQueueFamilies(gpa, physical_device, surface);
    const queue_family_indices = [_]u32{
        indices.graphics_family.?,
        indices.present_family.?,
    };

    if (indices.graphics_family != indices.present_family) {
        create_info.imageSharingMode = c.VK_SHARING_MODE_CONCURRENT;
        create_info.queueFamilyIndexCount = 2;
        create_info.pQueueFamilyIndices = @ptrCast(&queue_family_indices[0]);
    } else {
        create_info.imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        create_info.queueFamilyIndexCount = 0;
        create_info.pQueueFamilyIndices = null;
    }

    const err = c.vkCreateSwapchainKHR(device.device, &create_info, null, &swap_chain.swap_chain);
    if (err != c.VK_SUCCESS) {
        std.debug.print("Failed to create swap chain: {s}\n", .{c.string_VkResult(err)});
        return error.VulkanSwapChainCreationFailed;
    }

    swap_chain.images = try getSwapChainImages(gpa, device, swap_chain.swap_chain);

    return swap_chain;
}

fn getSwapChainImages(gpa: std.mem.Allocator, device: *const Device, swap_chain: c.VkSwapchainKHR) ![]c.VkImage {
    var image_count: u32 = 0;
    var result = c.vkGetSwapchainImagesKHR(device.device, swap_chain, &image_count, null);
    if (result != c.VK_SUCCESS) {
        std.debug.print("Failed to get swap chain images count: {s}\n", .{c.string_VkResult(result)});
        return error.VulkanSwapChainImageRetrievalFailed;
    }

    var images = try gpa.alloc(c.VkImage, image_count);
    errdefer gpa.free(images);
    result = c.vkGetSwapchainImagesKHR(device.device, swap_chain, &image_count, &images[0]);
    if (result != c.VK_SUCCESS) {
        std.debug.print("Failed to get swap chain images: {s}\n", .{c.string_VkResult(result)});
        return error.VulkanSwapChainImageRetrievalFailed;
    }

    return images;
}

pub fn createImageViews(gpa: std.mem.Allocator, device: *const Device, swap_chain: *const SwapChain) ![]c.VkImageView {
    var image_views = try gpa.alloc(c.VkImageView, swap_chain.images.len);
    errdefer gpa.free(image_views);
    for (0..swap_chain.images.len) |i| {
        image_views[i] = try createImageView(device, swap_chain.images[i], swap_chain.surface_format.format, c.VK_IMAGE_ASPECT_COLOR_BIT);
        errdefer {
            for (0..i) |j| {
                c.vkDestroyImageView(device.device, image_views[j], null);
            }
        }
    }

    return image_views;
}

fn createImageView(device: *const Device, image: c.VkImage, format: c.VkFormat, aspect_flags: c.VkImageAspectFlags) !c.VkImageView {
    const create_info = c.VkImageViewCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = image,
        .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
        .format = format,
        .components = .{
            .r = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            .g = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            .b = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            .a = c.VK_COMPONENT_SWIZZLE_IDENTITY,
        },
        .subresourceRange = .{
            .aspectMask = aspect_flags,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };

    var image_view: c.VkImageView = undefined;
    const err = c.vkCreateImageView(device.device, &create_info, null, &image_view);
    if (err != c.VK_SUCCESS) {
        std.debug.print("Failed to create image view: {s}\n", .{c.string_VkResult(err)});
        return error.VulkanImageViewCreationFailed;
    }

    return image_view;
}

pub fn destroyImageViews(gpa: std.mem.Allocator, device: *const Device, image_views: []c.VkImageView) void {
    for (image_views) |image_view| {
        c.vkDestroyImageView(device.device, image_view, null);
    }
    gpa.free(image_views);
}

pub fn createDescriptorSetLayout(device: *const Device) !c.VkDescriptorSetLayout {
    const ubo_layout_binding = c.VkDescriptorSetLayoutBinding{
        .binding = 0,
        .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .descriptorCount = 1,
        .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT,
        .pImmutableSamplers = null,
    };

    var layout_info = c.VkDescriptorSetLayoutCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = 1,
        .pBindings = &ubo_layout_binding,
    };

    var descriptor_set_layout: c.VkDescriptorSetLayout = null;
    const err = c.vkCreateDescriptorSetLayout(device.device, &layout_info, null, &descriptor_set_layout);
    if (err != c.VK_SUCCESS) {
        std.debug.print("Failed to create descriptor set layout: {s}\n", .{c.string_VkResult(err)});
        return error.VulkanDescriptorSetLayoutCreationFailed;
    }

    return descriptor_set_layout;
}

pub fn destroyDescriptorSetLayout(device: *const Device, descriptor_set_layout: c.VkDescriptorSetLayout) void {
    c.vkDestroyDescriptorSetLayout(device.device, descriptor_set_layout, null);
}

pub fn createGraphicsPipeline(
    gpa: std.mem.Allocator,
    physical_device: c.VkPhysicalDevice,
    device: *const Device,
    swap_chain: *const SwapChain,
    shader_vert: []const u8,
    shader_frag: []const u8,
    descriptor_set_layout: c.VkDescriptorSetLayout,
    vertex_description: VertexDescription,
) !Pipeline {
    const vert_shader_module = try createShaderModule(gpa, device, shader_vert);
    defer c.vkDestroyShaderModule(device.device, vert_shader_module, null);

    const frag_shader_module = try createShaderModule(gpa, device, shader_frag);
    defer c.vkDestroyShaderModule(device.device, frag_shader_module, null);

    const vert_shader_stage_info = c.VkPipelineShaderStageCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = c.VK_SHADER_STAGE_VERTEX_BIT,
        .module = vert_shader_module,
        .pName = "main",
    };

    const frag_shader_stage_info = c.VkPipelineShaderStageCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT,
        .module = frag_shader_module,
        .pName = "main",
    };

    const shader_stages = [_]c.VkPipelineShaderStageCreateInfo{
        vert_shader_stage_info,
        frag_shader_stage_info,
    };

    const dynamic_states = [_]c.VkDynamicState{
        c.VK_DYNAMIC_STATE_VIEWPORT,
        c.VK_DYNAMIC_STATE_SCISSOR,
    };

    const dynamic_state = c.VkPipelineDynamicStateCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .dynamicStateCount = @intCast(dynamic_states.len),
        .pDynamicStates = &dynamic_states[0],
    };

    const vertex_input_info = c.VkPipelineVertexInputStateCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .vertexBindingDescriptionCount = @intCast(vertex_description.binding_descriptions.len),
        .vertexAttributeDescriptionCount = @intCast(vertex_description.attribute_descriptions.len),
        .pVertexBindingDescriptions = &vertex_description.binding_descriptions[0],
        .pVertexAttributeDescriptions = &vertex_description.attribute_descriptions[0],
    };

    const input_assembly = c.VkPipelineInputAssemblyStateCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .primitiveRestartEnable = c.VK_FALSE,
    };

    const viewport_state = c.VkPipelineViewportStateCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1,
        .scissorCount = 1,
    };

    const rasterizer = c.VkPipelineRasterizationStateCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .depthClampEnable = c.VK_FALSE,
        .rasterizerDiscardEnable = c.VK_FALSE,
        .polygonMode = c.VK_POLYGON_MODE_FILL,
        .lineWidth = 1.0,
        .cullMode = c.VK_CULL_MODE_BACK_BIT,
        .frontFace = c.VK_FRONT_FACE_CLOCKWISE,
        .depthBiasEnable = c.VK_FALSE,
        .depthBiasConstantFactor = 0.0,
        .depthBiasClamp = 0.0,
        .depthBiasSlopeFactor = 0.0,
    };

    const multisampling = c.VkPipelineMultisampleStateCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .sampleShadingEnable = c.VK_FALSE,
        .rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT,
        .minSampleShading = 1.0,
        .pSampleMask = null,
        .alphaToCoverageEnable = c.VK_FALSE,
        .alphaToOneEnable = c.VK_FALSE,
    };

    const color_blend_attachment = c.VkPipelineColorBlendAttachmentState{
        .colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT,
        .blendEnable = c.VK_TRUE,
        .srcColorBlendFactor = c.VK_BLEND_FACTOR_SRC_ALPHA,
        .dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        .colorBlendOp = c.VK_BLEND_OP_ADD,
        .srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE,
        .dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ZERO,
        .alphaBlendOp = c.VK_BLEND_OP_ADD,
    };

    const depth_stencil_state = c.VkPipelineDepthStencilStateCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
        .depthTestEnable = c.VK_TRUE,
        .depthWriteEnable = c.VK_TRUE,
        .depthCompareOp = c.VK_COMPARE_OP_LESS,
        .depthBoundsTestEnable = c.VK_FALSE,
        .minDepthBounds = 0.0,
        .maxDepthBounds = 1.0,
        .stencilTestEnable = c.VK_FALSE,
        .front = .{},
        .back = .{},
    };

    const color_blending = c.VkPipelineColorBlendStateCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .logicOpEnable = c.VK_FALSE,
        .logicOp = c.VK_LOGIC_OP_COPY,
        .attachmentCount = 1,
        .pAttachments = &color_blend_attachment,
        .blendConstants = .{ 0.0, 0.0, 0.0, 0.0 },
    };

    const pipeline_layout_info = c.VkPipelineLayoutCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1,
        .pSetLayouts = &descriptor_set_layout,
        .pushConstantRangeCount = 0,
        .pPushConstantRanges = null,
    };

    var result = Pipeline{};
    var err = c.vkCreatePipelineLayout(device.device, &pipeline_layout_info, null, &result.pipeline_layout);
    if (err != c.VK_SUCCESS) {
        std.debug.print("Failed to create pipeline layout: {s}\n", .{c.string_VkResult(err)});
        return error.VulkanPipelineLayoutCreationFailed;
    }

    result.render_pass = try createRenderPass(physical_device, device, swap_chain);

    const pipeline_info = c.VkGraphicsPipelineCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .stageCount = 2,
        .pStages = &shader_stages[0],
        .pVertexInputState = &vertex_input_info,
        .pInputAssemblyState = &input_assembly,
        .pViewportState = &viewport_state,
        .pRasterizationState = &rasterizer,
        .pMultisampleState = &multisampling,
        .pDepthStencilState = &depth_stencil_state,
        .pColorBlendState = &color_blending,
        .pDynamicState = &dynamic_state,
        .layout = result.pipeline_layout,
        .renderPass = result.render_pass,
        .subpass = 0,
        .basePipelineHandle = @ptrCast(c.VK_NULL_HANDLE),
        .basePipelineIndex = -1,
    };

    err = c.vkCreateGraphicsPipelines(device.device, @ptrCast(c.VK_NULL_HANDLE), 1, &pipeline_info, null, &result.pipeline);
    if (err != c.VK_SUCCESS) {
        std.debug.print("Failed to create graphics pipeline: {s}\n", .{c.string_VkResult(err)});
        return error.VulkanGraphicsPipelineCreationFailed;
    }

    return result;
}

fn createShaderModule(gpa: std.mem.Allocator, device: *const Device, code: []const u8) !c.VkShaderModule {
    const code_copy = try gpa.allocWithOptions(u8, code.len, std.mem.Alignment.of(u32), null);
    defer gpa.free(code_copy);
    std.mem.copyForwards(u8, code_copy, code);
    const create_info = c.VkShaderModuleCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = code.len,
        .pCode = @ptrCast(code_copy),
    };

    var shader_module: c.VkShaderModule = undefined;
    const err = c.vkCreateShaderModule(device.device, &create_info, null, &shader_module);
    if (err != c.VK_SUCCESS) {
        std.debug.print("Failed to create shader module: {s}\n", .{c.string_VkResult(err)});
        return error.VulkanShaderModuleCreationFailed;
    }

    return shader_module;
}

fn createRenderPass(physical_device: c.VkPhysicalDevice, device: *const Device, swap_chain: *const SwapChain) !c.VkRenderPass {
    const color_attachment = c.VkAttachmentDescription{
        .format = swap_chain.surface_format.format,
        .samples = c.VK_SAMPLE_COUNT_1_BIT,
        .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        .finalLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
    };

    const color_attachment_ref = c.VkAttachmentReference{
        .attachment = 0,
        .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };

    const depth_attachment = c.VkAttachmentDescription{
        .format = try findDepthFormat(physical_device),
        .samples = c.VK_SAMPLE_COUNT_1_BIT,
        .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        .finalLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    };

    const depth_attachment_ref = c.VkAttachmentReference{
        .attachment = 1,
        .layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    };

    const subpass = c.VkSubpassDescription{
        .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount = 1,
        .pColorAttachments = &color_attachment_ref,
        .pDepthStencilAttachment = &depth_attachment_ref,
    };

    const dependency = c.VkSubpassDependency{
        .srcSubpass = c.VK_SUBPASS_EXTERNAL,
        .dstSubpass = 0,
        .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | c.VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
        .srcAccessMask = c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
        .dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
        .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
    };
    const attachments = [_]c.VkAttachmentDescription{
        color_attachment,
        depth_attachment,
    };
    const render_pass_info = c.VkRenderPassCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = attachments.len,
        .pAttachments = &attachments[0],
        .subpassCount = 1,
        .pSubpasses = &subpass,
        .dependencyCount = 1,
        .pDependencies = &dependency,
    };

    var render_pass: c.VkRenderPass = undefined;
    const err = c.vkCreateRenderPass(device.device, &render_pass_info, null, &render_pass);
    if (err != c.VK_SUCCESS) {
        std.debug.print("Failed to create render pass: {s}\n", .{c.string_VkResult(err)});
        return error.VulkanRenderPassCreationFailed;
    }

    return render_pass;
}

pub fn createFramebuffers(
    gpa: std.mem.Allocator,
    device: *const Device,
    pipeline: *const Pipeline,
    swap_chain: *const SwapChain,
    image_views: []c.VkImageView,
    depth_image: *const Image,
) ![]c.VkFramebuffer {
    var framebuffers = try gpa.alloc(c.VkFramebuffer, image_views.len);
    for (0..image_views.len) |i| {
        const attachments = [_]c.VkImageView{
            image_views[i],
            depth_image.image_view.?,
        };
        const framebuffer_info = c.VkFramebufferCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .renderPass = pipeline.render_pass,
            .attachmentCount = attachments.len,
            .pAttachments = &attachments[0],
            .width = swap_chain.extent.width,
            .height = swap_chain.extent.height,
            .layers = 1,
        };

        const err = c.vkCreateFramebuffer(device.device, &framebuffer_info, null, &framebuffers[i]);
        if (err != c.VK_SUCCESS) {
            std.debug.print("Failed to create framebuffer: {s}\n", .{c.string_VkResult(err)});
            for (0..i) |j| {
                c.vkDestroyFramebuffer(device.device, framebuffers[j], null);
            }
            gpa.free(framebuffers);
            return error.VulkanFramebufferCreationFailed;
        }
    }
    return framebuffers;
}

pub fn destroyFramebuffers(gpa: std.mem.Allocator, device: *const Device, framebuffers: []c.VkFramebuffer) void {
    for (framebuffers) |framebuffer| {
        c.vkDestroyFramebuffer(device.device, framebuffer, null);
    }
    gpa.free(framebuffers);
}

pub fn createCommandPool(
    gpa: std.mem.Allocator,
    physical_device: c.VkPhysicalDevice,
    surface: c.VkSurfaceKHR,
    device: *const Device,
) !c.VkCommandPool {
    const indices = try findQueueFamilies(gpa, physical_device, surface);

    const pool_info = c.VkCommandPoolCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = indices.graphics_family.?,
    };

    var command_pool: c.VkCommandPool = undefined;
    const err = c.vkCreateCommandPool(device.device, &pool_info, null, &command_pool);
    if (err != c.VK_SUCCESS) {
        std.debug.print("Failed to create command pool: {s}\n", .{c.string_VkResult(err)});
        return error.VulkanCommandPoolCreationFailed;
    }

    return command_pool;
}

pub fn destroyCommandPool(device: *const Device, command_pool: c.VkCommandPool) void {
    c.vkDestroyCommandPool(device.device, command_pool, null);
}

pub fn createCommandBuffer(
    device: *const Device,
    command_pool: c.VkCommandPool,
) !c.VkCommandBuffer {
    const alloc_info = c.VkCommandBufferAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = command_pool,
        .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };

    var command_buffer: c.VkCommandBuffer = undefined;
    const err = c.vkAllocateCommandBuffers(device.device, &alloc_info, &command_buffer);
    if (err != c.VK_SUCCESS) {
        std.debug.print("Failed to allocate command buffer: {s}\n", .{c.string_VkResult(err)});
        return error.VulkanCommandBufferAllocationFailed;
    }

    return command_buffer;
}

pub fn destroyCommandBuffer(
    device: *const Device,
    command_pool: c.VkCommandPool,
    command_buffer: c.VkCommandBuffer,
) void {
    c.vkFreeCommandBuffers(device.device, command_pool, 1, &command_buffer);
}

pub fn recordCommandBuffer(
    swap_chain: *const SwapChain,
    graphics_pipeline: *const Pipeline,
    framebuffers: []c.VkFramebuffer,
    command_buffer: c.VkCommandBuffer,
    descriptor_set: c.VkDescriptorSet,
    vertex_buffer: c.VkBuffer,
    vertex_count: u32,
    image_index: u32,
) !void {
    const begin_info = c.VkCommandBufferBeginInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = 0,
        .pInheritanceInfo = null,
    };

    var err = c.vkBeginCommandBuffer(command_buffer, &begin_info);
    if (err != c.VK_SUCCESS) {
        std.debug.print("Failed to begin recording command buffer: {s}\n", .{c.string_VkResult(err)});
        return error.VulkanCommandBufferRecordingFailed;
    }

    const clear_values = [_]c.VkClearValue{
        .{ .color = .{ .float32 = .{ 0.0, 0.0, 0.0, 1.0 } } },
        .{ .depthStencil = .{ .depth = 1.0, .stencil = 0.0 } },
    };
    const render_pass_info = c.VkRenderPassBeginInfo{
        .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .renderPass = graphics_pipeline.render_pass,
        .framebuffer = framebuffers[image_index],
        .renderArea = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = swap_chain.extent,
        },
        .clearValueCount = clear_values.len,
        .pClearValues = &clear_values[0],
    };

    c.vkCmdBeginRenderPass(command_buffer, &render_pass_info, c.VK_SUBPASS_CONTENTS_INLINE);

    c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, graphics_pipeline.pipeline);

    const vertex_buffers = [_]c.VkBuffer{vertex_buffer};
    const offsets = [_]c.VkDeviceSize{0};
    c.vkCmdBindVertexBuffers(command_buffer, 0, 1, &vertex_buffers, &offsets);

    const viewport = c.VkViewport{
        .x = 0.0,
        .y = 0.0,
        .width = @floatFromInt(swap_chain.extent.width),
        .height = @floatFromInt(swap_chain.extent.height),
        .minDepth = 0.0,
        .maxDepth = 1.0,
    };
    c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);

    const scissor = c.VkRect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = swap_chain.extent,
    };
    c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);

    c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, graphics_pipeline.pipeline_layout, 0, 1, &descriptor_set, 0, null);

    c.vkCmdDraw(command_buffer, vertex_count, 1, 0, 0);

    c.vkCmdEndRenderPass(command_buffer);

    err = c.vkEndCommandBuffer(command_buffer);
    if (err != c.VK_SUCCESS) {
        std.debug.print("Failed to end command buffer: {s}\n", .{c.string_VkResult(err)});
        return error.VulkanCommandBufferRecordingFailed;
    }
}

pub fn createSyncObjects(device: *const Device) !SyncObjects {
    var semaphore_info = c.VkSemaphoreCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };

    const fence_info = c.VkFenceCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        .flags = c.VK_FENCE_CREATE_SIGNALED_BIT,
    };

    var result = SyncObjects{};
    var err = c.vkCreateFence(device.device, &fence_info, null, &result.in_flight_fence);
    if (err != c.VK_SUCCESS) {
        std.debug.print("Failed to create fence: {s}\n", .{c.string_VkResult(err)});
        return error.VulkanFenceCreationFailed;
    }

    err = c.vkCreateSemaphore(device.device, &semaphore_info, null, &result.image_available_semaphore);
    if (err != c.VK_SUCCESS) {
        std.debug.print("Failed to create image available semaphore: {s}\n", .{c.string_VkResult(err)});
        return error.VulkanSemaphoreCreationFailed;
    }

    err = c.vkCreateSemaphore(device.device, &semaphore_info, null, &result.render_finished_semaphore);
    if (err != c.VK_SUCCESS) {
        std.debug.print("Failed to create image available semaphore: {s}\n", .{c.string_VkResult(err)});
        return error.VulkanSemaphoreCreationFailed;
    }

    return result;
}

const SwapChainRecreateResult = struct {
    swap_chain: SwapChain,
    image_views: []c.VkImageView,
    depth_image: Image,
    framebuffers: []c.VkFramebuffer,
};

pub fn recreateSwapChain(
    gpa: std.mem.Allocator,
    physical_device: c.VkPhysicalDevice,
    device: *const Device,
    pipeline: *const Pipeline,
    surface: c.VkSurfaceKHR,
    swap_chain: *const SwapChain,
    image_views: []c.VkImageView,
    depth_image: *const Image,
    framebuffers: []c.VkFramebuffer,
    extent: c.VkExtent2D,
) !SwapChainRecreateResult {
    const err = c.vkDeviceWaitIdle(device.device);
    if (err != c.VK_SUCCESS) {
        std.debug.print("Failed to wait for device to become idle: {s}\n", .{c.string_VkResult(err)});
        return error.VulkanDeviceWaitIdleFailed;
    }

    depth_image.deinit(device);
    destroyFramebuffers(gpa, device, framebuffers);
    destroyImageViews(gpa, device, image_views);
    swap_chain.deinit(gpa, device);

    const new_swap_chain = try createSwapChain(gpa, physical_device, device, surface, extent);
    const new_image_views = try createImageViews(gpa, device, &new_swap_chain);
    const new_depth_image = try createDepthResources(physical_device, device, extent);
    const new_framebuffers = try createFramebuffers(gpa, device, pipeline, &new_swap_chain, new_image_views, &new_depth_image);

    return .{
        .swap_chain = new_swap_chain,
        .image_views = new_image_views,
        .depth_image = new_depth_image,
        .framebuffers = new_framebuffers,
    };
}

pub fn createBuffer(device: *const Device, usage: c.VkBufferUsageFlags, buffer_size: usize) !c.VkBuffer {
    const buffer_info = c.VkBufferCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = buffer_size,
        .usage = usage,
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
    };

    var buffer: c.VkBuffer = undefined;
    const err = c.vkCreateBuffer(device.device, &buffer_info, null, &buffer);
    if (err != c.VK_SUCCESS) {
        std.debug.print("Failed to create buffer: {s}\n", .{c.string_VkResult(err)});
        return error.VulkanVertexBufferCreationFailed;
    }

    return buffer;
}

pub fn destroyBuffer(device: *const Device, buffer: c.VkBuffer) void {
    c.vkDestroyBuffer(device.device, buffer, null);
}

fn findMemoryType(physical_device: c.VkPhysicalDevice, type_filter: u32, properties: c.VkMemoryPropertyFlags) !u32 {
    var memory_properties: c.VkPhysicalDeviceMemoryProperties = undefined;
    c.vkGetPhysicalDeviceMemoryProperties(physical_device, &memory_properties);

    for (0..memory_properties.memoryTypeCount) |i| {
        if (type_filter & (@as(u32, @intCast(1)) << @intCast(i)) != 0 and (memory_properties.memoryTypes[i].propertyFlags & properties) == properties) {
            return @intCast(i);
        }
    }

    return error.VulkanFindingMemoryTypeFailed;
}

pub fn createBufferMemory(physical_device: c.VkPhysicalDevice, device: *const Device, buffer: c.VkBuffer, properties: c.VkMemoryPropertyFlags) !c.VkDeviceMemory {
    var memory_requirements: c.VkMemoryRequirements = undefined;
    c.vkGetBufferMemoryRequirements(device.device, buffer, &memory_requirements);

    const memory_type_index = try findMemoryType(physical_device, memory_requirements.memoryTypeBits, properties);
    const alloc_info = c.VkMemoryAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = memory_requirements.size,
        .memoryTypeIndex = memory_type_index,
    };

    var buffer_memory: c.VkDeviceMemory = undefined;
    var err = c.vkAllocateMemory(device.device, &alloc_info, null, &buffer_memory);
    if (err != c.VK_SUCCESS) {
        std.debug.print("Failed to create buffer memory: {s}\n", .{c.string_VkResult(err)});
        return error.VulkanBufferMemoryCreationFailed;
    }

    err = c.vkBindBufferMemory(device.device, buffer, buffer_memory, 0);
    if (err != c.VK_SUCCESS) {
        std.debug.print("Failed to bind buffer memory: {s}\n", .{c.string_VkResult(err)});
        return error.VulkanBufferMemoryBindingFailed;
    }

    return buffer_memory;
}

pub fn destroyBufferMemory(device: *const Device, memory: c.VkDeviceMemory) void {
    c.vkFreeMemory(device.device, memory, null);
}

pub fn mapMemory(device: *const Device, buffer_memory: c.VkDeviceMemory, data_in: []const f32) !void {
    const buffer_size = @sizeOf(@TypeOf(data_in[0])) * data_in.len;
    var data: [*]f32 = undefined;
    const err = c.vkMapMemory(device.device, buffer_memory, 0, buffer_size, 0, @ptrCast(&data));
    if (err != c.VK_SUCCESS) {
        std.debug.print("Failed to map memory: {s}\n", .{c.string_VkResult(err)});
        return error.VulkanMapMemoryFailed;
    }

    const data_slice: []f32 = data[0..data_in.len];
    std.mem.copyForwards(f32, data_slice, data_in);

    c.vkUnmapMemory(device.device, buffer_memory);
}

pub fn createDescriptorPool(device: *const Device, descriptor_count: usize) !c.VkDescriptorPool {
    const pool_size = c.VkDescriptorPoolSize{
        .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .descriptorCount = @intCast(descriptor_count),
    };

    const pool_info = c.VkDescriptorPoolCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .poolSizeCount = 1,
        .pPoolSizes = &pool_size,
        .maxSets = @intCast(descriptor_count),
    };

    var descriptor_pool: c.VkDescriptorPool = null;
    const err = c.vkCreateDescriptorPool(device.device, &pool_info, null, &descriptor_pool);
    if (err != c.VK_SUCCESS) {
        std.debug.print("Failed to create descriptor pool: {s}\n", .{c.string_VkResult(err)});
        return error.VulkanDescriptorPoolCreationFailed;
    }

    return descriptor_pool;
}

pub fn destroyDescriptorPool(device: *const Device, descriptor_pool: c.VkDescriptorPool) void {
    c.vkDestroyDescriptorPool(device.device, descriptor_pool, null);
}

pub fn createDescriptorSets(gpa: std.mem.Allocator, device: *const Device, descriptor_pool: c.VkDescriptorPool, descriptor_set_layout: c.VkDescriptorSetLayout, descriptor_count: usize) ![]c.VkDescriptorSet {
    const layouts = try gpa.alloc(c.VkDescriptorSetLayout, descriptor_count);
    defer gpa.free(layouts);
    for (0..descriptor_count) |i| {
        layouts[i] = descriptor_set_layout;
    }
    const alloc_info = c.VkDescriptorSetAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = descriptor_pool,
        .descriptorSetCount = @intCast(descriptor_count),
        .pSetLayouts = &layouts[0],
    };

    var descriptor_sets: []c.VkDescriptorSet = try gpa.alloc(c.VkDescriptorSet, descriptor_count);
    const err = c.vkAllocateDescriptorSets(device.device, &alloc_info, &descriptor_sets[0]);
    if (err != c.VK_SUCCESS) {
        std.debug.print("Failed to allocate descriptor sets: {s}\n", .{c.string_VkResult(err)});
        return error.VulkanDescriptorSetAllocationFailed;
    }

    return descriptor_sets[0..descriptor_count];
}

pub fn destroyDescriptorSets(gpa: std.mem.Allocator, descriptor_sets: []c.VkDescriptorSet) void {
    // individual freeing of descriptor sets is not necessary, destroying the pool frees all sets
    gpa.free(descriptor_sets);
}

pub fn createDepthResources(
    physical_device: c.VkPhysicalDevice,
    device: *const Device,
    extent: c.VkExtent2D,
) !Image {
    const depth_format = try findDepthFormat(physical_device);

    return createImage(
        physical_device,
        device,
        extent.width,
        extent.height,
        depth_format,
        c.VK_IMAGE_ASPECT_DEPTH_BIT,
        c.VK_IMAGE_TILING_OPTIMAL,
        c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
        c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        true,
    );
}

fn findSupportedFormat(
    physical_device: c.VkPhysicalDevice,
    candidates: []const c.VkFormat,
    tiling: c.VkImageTiling,
    features: c.VkFormatFeatureFlags,
) !c.VkFormat {
    for (candidates) |format| {
        var props: c.VkFormatProperties = undefined;
        c.vkGetPhysicalDeviceFormatProperties(physical_device, format, &props);

        if (tiling == c.VK_IMAGE_TILING_LINEAR and (props.linearTilingFeatures & features) == features) {
            return format;
        } else if (tiling == c.VK_IMAGE_TILING_OPTIMAL and (props.optimalTilingFeatures & features) == features) {
            return format;
        }
    }
    return error.VulkanFindingSupportedFormatFailed;
}

fn findDepthFormat(physical_device: c.VkPhysicalDevice) !c.VkFormat {
    return findSupportedFormat(
        physical_device,
        &[_]c.VkFormat{ c.VK_FORMAT_D32_SFLOAT, c.VK_FORMAT_D32_SFLOAT_S8_UINT, c.VK_FORMAT_D24_UNORM_S8_UINT },
        c.VK_IMAGE_TILING_OPTIMAL,
        c.VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT,
    );
}

fn hasStencilComponent(format: c.VkFormat) bool {
    return format == c.VK_FORMAT_D32_SFLOAT_S8_UINT or format == c.VK_FORMAT_D24_UNORM_S8_UINT;
}

fn createImage(
    physical_device: c.VkPhysicalDevice,
    device: *const Device,
    width: u32,
    height: u32,
    format: c.VkFormat,
    aspect_flags: c.VkImageAspectFlags,
    tiling: c.VkImageTiling,
    usage: c.VkImageUsageFlags,
    properties: c.VkMemoryPropertyFlags,
    create_image_view: bool,
) !Image {
    const image_info = c.VkImageCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = c.VK_IMAGE_TYPE_2D,
        .extent = .{
            .width = width,
            .height = height,
            .depth = 1,
        },
        .mipLevels = 1,
        .arrayLayers = 1,
        .format = format,
        .tiling = tiling,
        .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        .usage = usage,
        .samples = c.VK_SAMPLE_COUNT_1_BIT,
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
    };

    var image: c.VkImage = undefined;
    var err = c.vkCreateImage(device.device, &image_info, null, &image);
    if (err != c.VK_SUCCESS) {
        std.debug.print("Failed to create image: {s}\n", .{c.string_VkResult(err)});
        return error.VulkanImageCreationFailed;
    }

    var memRequirements: c.VkMemoryRequirements = undefined;
    c.vkGetImageMemoryRequirements(device.device, image, &memRequirements);

    const alloc_info = c.VkMemoryAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = memRequirements.size,
        .memoryTypeIndex = try findMemoryType(physical_device, memRequirements.memoryTypeBits, properties),
    };

    var image_memory: c.VkDeviceMemory = undefined;
    err = c.vkAllocateMemory(device.device, &alloc_info, null, &image_memory);
    if (err != c.VK_SUCCESS) {
        std.debug.print("Failed to allocate image memory: {s}\n", .{c.string_VkResult(err)});
        return error.VulkanImageMemoryAllocationFailed;
    }

    err = c.vkBindImageMemory(device.device, image, image_memory, 0);
    if (err != c.VK_SUCCESS) {
        std.debug.print("Failed to bind image memory: {s}\n", .{c.string_VkResult(err)});
        return error.VulkanImageMemoryBindingFailed;
    }

    var image_view: c.VkImageView = null;
    if (create_image_view) {
        image_view = try createImageView(device, image, format, aspect_flags);
    }

    return .{
        .image = image,
        .memory = image_memory,
        .image_view = image_view,
    };
}

pub fn createTextureImage(
    physical_device: c.VkPhysicalDevice,
    device: *const Device,
    command_pool: c.VkCommandPool,
    pixels: []const u8,
    width: u32,
    height: u32,
    channels: u32,
) !Image {
    const image_size: c.VkDeviceSize = width * height * channels;
    const staging_buffer = try createBuffer(device, c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT, image_size);
    defer destroyBuffer(device, staging_buffer);
    const staging_buffer_memory = try createBufferMemory(physical_device, device, staging_buffer, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    defer destroyBufferMemory(device, staging_buffer_memory);

    var data: [*]u8 = undefined;
    const err = c.vkMapMemory(device.device, staging_buffer_memory, 0, image_size, 0, @ptrCast(&data));
    if (err != c.VK_SUCCESS) {
        std.debug.print("Failed to map memory for texture image: {s}\n", .{c.string_VkResult(err)});
        return error.VulkanMapMemoryFailed;
    }

    @memcpy(data[0..image_size], pixels[0..image_size]);
    c.vkUnmapMemory(device.device, staging_buffer_memory);

    const image = try createImage(
        physical_device,
        device,
        width,
        height,
        c.VK_FORMAT_R8G8B8_SRGB,
        c.VK_IMAGE_ASPECT_COLOR_BIT,
        c.VK_IMAGE_TILING_OPTIMAL,
        c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT,
        c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        true,
    );

    try transitionImageLayout(device, command_pool, &image, c.VK_FORMAT_R8G8B8_SRGB, c.VK_IMAGE_LAYOUT_UNDEFINED, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
    try copyBufferToImage(device, command_pool, staging_buffer, image.image, width, height);
    try transitionImageLayout(device, command_pool, &image, c.VK_FORMAT_R8G8B8_SRGB, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);

    return image;
}

pub fn beginSingleTimeCommands(device: *const Device, command_pool: c.VkCommandPool) !c.VkCommandBuffer {
    const allocInfo = c.VkCommandBufferAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandPool = command_pool,
        .commandBufferCount = 1,
    };

    var commandBuffer: c.VkCommandBuffer = undefined;
    var err = c.vkAllocateCommandBuffers(device.device, &allocInfo, &commandBuffer);
    if (err != c.VK_SUCCESS) {
        std.debug.print("Failed to allocate command buffer: {s}\n", .{c.string_VkResult(err)});
        return error.VulkanCommandBufferAllocationFailed;
    }

    const beginInfo = c.VkCommandBufferBeginInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };

    err = c.vkBeginCommandBuffer(commandBuffer, &beginInfo);
    if (err != c.VK_SUCCESS) {
        std.debug.print("Failed to begin recording command buffer: {s}\n", .{c.string_VkResult(err)});
        return error.VulkanCommandBufferBeginFailed;
    }

    return commandBuffer;
}

pub fn endSingleTimeCommands(
    device: *const Device,
    command_pool: c.VkCommandPool,
    command_buffer: c.VkCommandBuffer,
) !void {
    var err = c.vkEndCommandBuffer(command_buffer);
    if (err != c.VK_SUCCESS) {
        std.debug.print("Failed to end recording command buffer: {s}\n", .{c.string_VkResult(err)});
        return error.VulkanCommandBufferEndFailed;
    }

    const submit_info = c.VkSubmitInfo{
        .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1,
        .pCommandBuffers = &command_buffer,
    };

    err = c.vkQueueSubmit(device.graphics_queue, 1, &submit_info, @ptrCast(c.VK_NULL_HANDLE));
    if (err != c.VK_SUCCESS) {
        std.debug.print("Failed to submit command buffer: {s}\n", .{c.string_VkResult(err)});
        return error.VulkanCommandBufferSubmitFailed;
    }

    err = c.vkQueueWaitIdle(device.graphics_queue);
    if (err != c.VK_SUCCESS) {
        std.debug.print("Failed to wait for queue to become idle: {s}\n", .{c.string_VkResult(err)});
        return error.VulkanQueueWaitIdleFailed;
    }

    c.vkFreeCommandBuffers(device.device, command_pool, 1, &command_buffer);
}

pub fn copyBuffer(device: *const Device, command_pool: c.VkCommandPool, src_buffer: c.VkBuffer, dst_buffer: c.VkBuffer, size: c.VkDeviceSize) !void {
    const command_buffer = try beginSingleTimeCommands(device, command_pool);

    const copy_region = c.VkBufferCopy{
        .size = size,
    };
    c.vkCmdCopyBuffer(command_buffer, src_buffer, dst_buffer, 1, &copy_region);

    try c.endSingleTimeCommands(command_buffer);
}

pub fn transitionImageLayout(device: *const Device, command_pool: c.VkCommandPool, image: *const Image, format: c.VkFormat, old_layout: c.VkImageLayout, new_layout: c.VkImageLayout) !void {
    _ = format;

    const command_buffer = try beginSingleTimeCommands(device, command_pool);

    var src_access_mask: c.VkAccessFlags = 0;
    var dst_access_mask: c.VkAccessFlags = 0;
    var source_stage: c.VkPipelineStageFlags = 0;
    var destination_stage: c.VkPipelineStageFlags = 0;
    if (old_layout == c.VK_IMAGE_LAYOUT_UNDEFINED and new_layout == c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL) {
        src_access_mask = 0;
        dst_access_mask = c.VK_ACCESS_TRANSFER_WRITE_BIT;

        source_stage = c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
        destination_stage = c.VK_PIPELINE_STAGE_TRANSFER_BIT;
    } else if (old_layout == c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL and new_layout == c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) {
        src_access_mask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
        dst_access_mask = c.VK_ACCESS_SHADER_READ_BIT;

        source_stage = c.VK_PIPELINE_STAGE_TRANSFER_BIT;
        destination_stage = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
    } else {
        return error.VulkanUnsupportedLayoutTransition;
    }

    const barrier = c.VkImageMemoryBarrier{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .oldLayout = old_layout,
        .newLayout = new_layout,
        .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .image = image.image,
        .subresourceRange = .{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .srcAccessMask = src_access_mask,
        .dstAccessMask = dst_access_mask,
    };

    c.vkCmdPipelineBarrier(
        command_buffer,
        source_stage,
        destination_stage,
        0,
        0,
        null,
        0,
        null,
        1,
        &barrier,
    );

    try endSingleTimeCommands(device, command_pool, command_buffer);
}

pub fn copyBufferToImage(device: *const Device, command_pool: c.VkCommandPool, buffer: c.VkBuffer, image: c.VkImage, width: u32, height: u32) !void {
    const command_buffer = try beginSingleTimeCommands(device, command_pool);

    const region = c.VkBufferImageCopy{
        .bufferOffset = 0,
        .bufferRowLength = 0,
        .bufferImageHeight = 0,
        .imageSubresource = .{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
        .imageExtent = .{
            .width = width,
            .height = height,
            .depth = 1,
        },
    };

    c.vkCmdCopyBufferToImage(
        command_buffer,
        buffer,
        image,
        c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        1,
        &region,
    );

    try endSingleTimeCommands(device, command_pool, command_buffer);
}
