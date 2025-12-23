#version 450

layout(binding = 0) uniform UniformBufferObject {
    float aspect_ratio;
    float zoom;
} ubo;

layout(location = 0) in vec3 position;
layout(location = 1) in float geometry_type;
layout(location = 2) in float rotation;
layout(location = 3) in vec2 translation;
layout(location = 4) in vec2 scale;

layout(location = 0) out int frag_geometry_type;
layout(location = 1) out vec2 frag_position;
layout(location = 2) out vec2 frag_center;
layout(location = 3) out float frag_radius;

vec2 applyTransformations(vec2 pos, float rot, vec2 scl, vec2 trans) {
    vec2 rotated_position = vec2(
            pos.x * cos(rot) - pos.y * sin(rot),
            pos.x * sin(rot) + pos.y * cos(rot)
        );
    vec2 transformed_position = vec2(rotated_position * scl + trans);
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
            translation
        );
    vec2 transformed_center = applyTransformations(
            vec2(0.0, 0.0),
            rotation,
            scale,
            translation
        );
    gl_Position = vec4(applyZoomAndAspectRatio(transformed_position, ubo.zoom, ubo.aspect_ratio), 0.0, 1.0);
    frag_geometry_type = int(geometry_type);
    frag_position = transformed_position;
    frag_center = transformed_center;
    frag_radius = scale.x;
}
