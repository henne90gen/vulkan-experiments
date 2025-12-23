#version 450

layout(binding = 1) uniform sampler2D tex_sampler;

layout(location = 0) flat in int frag_geometry_type;
layout(location = 1) in vec2 frag_position;
layout(location = 2) flat in float frag_radius;
layout(location = 3) flat in int frag_texture_index;

layout(location = 0) out vec4 out_color;

void main() {
    if (frag_geometry_type == 0) { // circle
        vec4 fill_color = vec4(0.25, 0.4, 0.75, 1.0); // Deep blue fill
        vec4 border_color = vec4(0.15, 0.25, 0.55, 1.0); // Darker blue border

        float distance_from_center = length(frag_position);
        float t = distance_from_center / frag_radius;

        // Circle parameters (in normalized space where radius = 0.5)
        float outer_radius = 0.45;
        float border_width = 0.04;
        float inner_radius = outer_radius - border_width;
        float aa_width = 0.01;

        if (t > outer_radius + aa_width) {
            discard;
        }

        // Outer edge anti-aliasing (fade to transparent)
        float outer_aa = 1.0 - smoothstep(outer_radius - aa_width, outer_radius + aa_width, t);
        // Border region (transition from fill to border)
        float border_mix = smoothstep(inner_radius - aa_width, inner_radius + aa_width, t);
        // Mix fill and border colors
        vec4 color = mix(fill_color, border_color, border_mix);
        // Apply outer edge anti-aliasing
        out_color = vec4(color.rgb, color.a * outer_aa);
    } else if (frag_geometry_type == 1) { // rectangle
        // Solid green for rectangles
        out_color = vec4(0.0, 1.0, 0.0, 1.0);
    } else if (frag_geometry_type == 2) { // texture-mapped quad
        vec2 texture_coords = frag_position + 0.5; // Map from [-0.5, 0.5] to [0, 1]
        texture_coords.y = 1.0 - texture_coords.y; // Flip Y of texture coordinates
        int texture_atlas_size = 4; // Number of textures in the atlas horizontally/vertically
        vec2 offset = vec2(
                float(frag_texture_index % texture_atlas_size) / float(texture_atlas_size),
                float(frag_texture_index / texture_atlas_size) / float(texture_atlas_size)
            );
        texture_coords = texture_coords / float(texture_atlas_size) + offset;
        out_color = texture(tex_sampler, texture_coords);
    } else {
        // Magenta for unknown geometry types
        out_color = vec4(1.0, 0.0, 1.0, 1.0);
    }
}
