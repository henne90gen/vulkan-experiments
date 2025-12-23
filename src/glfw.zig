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

pub fn setKeyCallback(window: *c.GLFWwindow, keyCallback: fn (window: ?*c.GLFWwindow, key: i32, scancode: i32, action: i32, mods: i32) callconv(.c) void) void {
    _ = c.glfwSetKeyCallback(window, keyCallback);
}

pub fn setWindowShouldClose(window: *c.GLFWwindow, shouldClose: bool) void {
    c.glfwSetWindowShouldClose(window, @intFromBool(shouldClose));
}

pub fn getFramebufferSize(window: *c.GLFWwindow, width: *i32, height: *i32) void {
    c.glfwGetFramebufferSize(window, width, height);
}
