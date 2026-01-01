# Vulkan Example Project

## Dependencies

### Linux

```sh
pacman -S vulkan-validation-layers vulkan-utility-libraries
```

### Windows

Install the Vulkan SDK from https://vulkan.lunarg.com/sdk/home

## Running the app

### Linux

```sh
zig build run
```

### Windows

```sh
zig build -Dvulkan-sdk-path="C:/VulkanSDK/1.4.328.1" run
```

## Plan

- [x] render points on click
- [x] connect points with lines
- [x] add mouse wheel zooming
- [x] add mouse controls for camera movement
- [x] add ability to select primitives
- [x] add texture atlas with icons
- [x] add UI overlay
  - [x] create custom UI system
- [ ] add keyboard controls for camera movement
- [ ] implement constraint solver
  - [ ] add debug tools
    - [x] export of constraint graph to DOT file format
    - [ ] export to DOT during the different processing steps

## Cross Compilation

To cross compile for Windows from Linux, install the Vulkan SDK using wine and use the following command:

```sh
zig build -Dtarget=x86_64-windows -Dvulkan-sdk-path=/opt/VulkanSDK_Windows/1.4.335.0 run
```

## Icons

Icons were copied from: https://github.com/AntonEvmenenko/2d_geometric_constraint_solver
