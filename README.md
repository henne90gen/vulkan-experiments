# Vulkan Example Project

## Dependencies

```sh
pacman -S vulkan-validation-layers vulkan-utility-libraries
```

## Plan

- [x] render points on click
- [x] connect points with lines
- [x] add mouse wheel zooming
- [ ] add mouse controls for camera movement
- [ ] add keyboard controls for camera movement

## Cross Compilation

To cross compile for Windows from Linux, install the Vulkan SDK using wine and use the following command:

```sh
zig build -Dtarget=x86_64-windows -Dvulkan-sdk-path=/opt/VulkanSDK_Windows/1.4.335.0 run
```
