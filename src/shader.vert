#version 450

layout(binding = 0) uniform UniformBufferObject {
    mat4 model;
    mat4 view;
    mat4 projection;
} ubo;

layout(location = 0) in vec4 position;
layout(location = 1) in vec3 texture_coordinate;
layout(location = 2) in vec3 normal;

layout(location = 0) out vec3 frag_color;
layout(location = 1) out vec2 frag_tex_coord;

void main() {
    gl_Position = ubo.projection * ubo.view * ubo.model * position;
    frag_color = normal;
    frag_tex_coord = texture_coordinate.xy;
}
