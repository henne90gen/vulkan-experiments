#version 450

layout(binding = 1) uniform sampler2D tex_sampler;

layout(location = 0) flat in int frag_geometry_type;

layout(location = 0) out vec4 out_color;

void main() {
    out_color = vec4(1.0, 0.0, 0.0, 1.0);
}
