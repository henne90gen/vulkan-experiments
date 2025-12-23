#version 450

layout(binding = 0) uniform UniformBufferObject {
    float aspect_ratio;
    float zoom;
    vec2 offset;
} ubo;

layout(location = 0) in vec3 position;
layout(location = 1) in int geometry_type;
layout(location = 2) in float rotation;
layout(location = 3) in vec2 translation;
layout(location = 4) in vec2 scale;
layout(location = 5) in int texture_index;
layout(location = 6) in uint render_hints;

layout(location = 0) out int frag_geometry_type;
layout(location = 1) out vec2 frag_position;
layout(location = 2) out float frag_radius;
layout(location = 3) out int frag_texture_index;
layout(location = 4) out uint frag_render_hints;

vec2 applyTransformations(vec2 pos, float rot, vec2 scl, vec2 trans) {
    vec2 scaled_position = pos * scl;
    vec2 rotated_position = vec2(
            scaled_position.x * cos(rot) - scaled_position.y * sin(rot),
            scaled_position.x * sin(rot) + scaled_position.y * cos(rot)
        );
    vec2 transformed_position = vec2(rotated_position + trans);
    transformed_position.y *= -1.0;
    return transformed_position;
}

vec2 applyZoomAndAspectRatio(vec2 pos, float zoom, float aspect_ratio) {
    vec2 transformed_position = pos * zoom;
    if (aspect_ratio > 1.0) {
        transformed_position = vec2(transformed_position.x / aspect_ratio, transformed_position.y);
    } else {
        transformed_position = vec2(transformed_position.x, transformed_position.y * aspect_ratio);
    }
    return transformed_position;
}

void main() {
    vec2 transformed_position = applyTransformations(
            position.xy,
            rotation,
            scale,
            translation + ubo.offset
        );
    transformed_position = applyZoomAndAspectRatio(transformed_position, ubo.zoom, ubo.aspect_ratio);
    gl_Position = vec4(transformed_position, 0.0, 1.0);

    frag_geometry_type = geometry_type;
    frag_position = position.xy;
    frag_radius = scale.x;
    frag_texture_index = texture_index;
    frag_render_hints = render_hints;
}
