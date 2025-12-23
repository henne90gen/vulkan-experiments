#version 450

layout(binding = 0) uniform UniformBufferObject {
    float aspect_ratio;
} ubo;

layout(location = 0) in vec2 position;
layout(location = 1) in float geometry_type;
layout(location = 2) in float rotation;
layout(location = 3) in vec2 translation;
layout(location = 4) in vec2 scale;

layout(location = 0) out int frag_geometry_type;

void main() {
    vec2 rotated_position = vec2(
            position.x * cos(rotation) - position.y * sin(rotation),
            position.x * sin(rotation) + position.y * cos(rotation)
        );
    vec2 transformed_position = vec2(rotated_position * scale + translation);
    if (ubo.aspect_ratio > 1.0) {
        gl_Position = vec4(transformed_position.x / ubo.aspect_ratio, transformed_position.y, 0.0, 1.0);
    } else {
        gl_Position = vec4(transformed_position.x, transformed_position.y * ubo.aspect_ratio, 0.0, 1.0);
    }
    frag_geometry_type = int(geometry_type);
}
