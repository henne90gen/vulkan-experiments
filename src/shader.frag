#version 450

layout(binding = 1) uniform sampler2D tex_sampler;

layout(location = 0) flat in int frag_geometry_type;
layout(location = 1) in vec2 frag_position;
layout(location = 2) flat in vec2 frag_center;
layout(location = 3) flat in float frag_radius;

layout(location = 0) out vec4 out_color;

void main() {
    float distance_from_center = distance(frag_position, frag_center);
    float t = distance_from_center / frag_radius;
    
    // Nice gradient from deep blue center to cyan edges
    vec4 center_color = vec4(0.2, 0.3, 0.7, 1.0);  // Deep blue
    vec4 edge_color = vec4(0.3, 0.6, 0.8, 1.0);    // Cyan
    
    // Smooth falloff for anti-aliased edges
    float edge_start = 0.4;
    float edge_end = 0.5;
    float alpha = 1.0 - smoothstep(edge_start, edge_end, t);
    
    if (t > edge_end) {
        discard;
    } else {
        vec4 color = mix(center_color, edge_color, t * 2.0);
        out_color = vec4(color.rgb, alpha);
    }
}
