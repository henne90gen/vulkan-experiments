const std = @import("std");

pub const c = @cImport({
    @cDefine("GLFW_INCLUDE_NONE", "1");
    @cDefine("GLFW_INCLUDE_VULKAN", "1");
    @cInclude("GLFW/glfw3.h");
});

pub fn init() !void {
    if (c.glfwInit() == 0) {
        return error.GlfwInitFailed;
    }
}

pub fn terminate() void {
    c.glfwTerminate();
}

pub fn createWindow(width: i32, height: i32, title: [:0]const u8) !*c.GLFWwindow {
    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
    c.glfwWindowHint(c.GLFW_RESIZABLE, c.GLFW_TRUE);
    return c.glfwCreateWindow(width, height, title.ptr, null, null) orelse error.GlfwCreateWindowFailed;
}

pub fn destroyWindow(window: *c.GLFWwindow) void {
    c.glfwDestroyWindow(window);
}

pub fn windowShouldClose(window: *c.GLFWwindow) bool {
    return c.glfwWindowShouldClose(window) != 0;
}

pub fn pollEvents() void {
    c.glfwPollEvents();
}

pub fn getRequiredInstanceExtensions() [][*:0]const u8 {
    var glfwExtensionCount: u32 = 0;
    const glfwExtensions = c.glfwGetRequiredInstanceExtensions(&glfwExtensionCount);
    return @ptrCast(glfwExtensions[0..glfwExtensionCount]);
}

pub fn setKeyCallback(window: *c.GLFWwindow, keyCallback: c.GLFWkeyfun) void {
    _ = c.glfwSetKeyCallback(window, keyCallback);
}

pub fn setMouseButtonCallback(window: *c.GLFWwindow, mouseButtonCallback: c.GLFWmousebuttonfun) void {
    _ = c.glfwSetMouseButtonCallback(window, mouseButtonCallback);
}

pub fn setScrollCallback(window: *c.GLFWwindow, scrollCallback: c.GLFWscrollfun) void {
    _ = c.glfwSetScrollCallback(window, scrollCallback);
}

pub fn setWindowShouldClose(window: *c.GLFWwindow, shouldClose: bool) void {
    c.glfwSetWindowShouldClose(window, @intFromBool(shouldClose));
}

const FramebufferSize = struct {
    width: i32 = 0,
    height: i32 = 0,
};
pub fn getFramebufferSize(window: *c.GLFWwindow) FramebufferSize {
    var framebuffer_size = FramebufferSize{};
    c.glfwGetFramebufferSize(window, &framebuffer_size.width, &framebuffer_size.height);
    return framebuffer_size;
}

pub fn setWindowUserPointer(window: *c.GLFWwindow, pointer: ?*anyopaque) void {
    c.glfwSetWindowUserPointer(window, pointer);
}

pub fn getWindowUserPointer(window: *c.GLFWwindow, T: type) ?*T {
    return @ptrCast(@alignCast(c.glfwGetWindowUserPointer(window)));
}

pub fn setWindowTitle(window: *c.GLFWwindow, title: [:0]const u8) void {
    c.glfwSetWindowTitle(window, title);
}

pub const MousePosition = struct {
    x: f64 = 0,
    y: f64 = 0,
};
pub fn getMousePosition(window: *c.GLFWwindow) MousePosition {
    var mousePosition = MousePosition{};
    c.glfwGetCursorPos(window, &mousePosition.x, &mousePosition.y);
    return mousePosition;
}
