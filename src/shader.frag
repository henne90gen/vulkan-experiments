#version 450

layout(binding = 1) uniform sampler2D tex_sampler;

layout(location = 0) flat in int frag_geometry_type;
layout(location = 1) in vec2 frag_position;
layout(location = 2) flat in float frag_radius;
layout(location = 3) flat in int frag_texture_index;
layout(location = 4) flat in uint frag_render_hints;

layout(location = 0) out vec4 out_color;

void main() {
    bool is_hovered = (frag_render_hints & 2u) != 0u;
    bool is_selected = (frag_render_hints & 4u) != 0u;
    bool is_disabled = (frag_render_hints & 8u) != 0u;

    if (frag_geometry_type == 0) { // circle
        vec4 fill_color = is_selected ? vec4(0.9, 0.6, 0.2, 1.0) : vec4(0.25, 0.4, 0.75, 1.0); // Orange if selected, blue otherwise
        vec4 border_color = is_selected ? vec4(1.0, 0.8, 0.4, 1.0) : vec4(0.15, 0.25, 0.55, 1.0); // Brighter orange if selected, darker blue otherwise

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
        // Solid green for rectangles, yellow if selected
        out_color = is_selected ? vec4(1.0, 1.0, 0.0, 1.0) : vec4(0.0, 1.0, 0.0, 1.0);
    } else if (frag_geometry_type == 2) { // texture-mapped quad
        vec2 texture_coords = frag_position + 0.5; // Map from [-0.5, 0.5] to [0, 1]
        texture_coords.y = 1.0 - texture_coords.y; // Flip Y of texture coordinates
        int texture_atlas_size = 5; // Number of textures in the atlas horizontally/vertically
        vec2 offset = vec2(
                float(frag_texture_index % texture_atlas_size) / float(texture_atlas_size),
                float(frag_texture_index / texture_atlas_size) / float(texture_atlas_size)
            );
        texture_coords = texture_coords / float(texture_atlas_size) + offset;
        vec4 texture_color = texture(tex_sampler, texture_coords);

        // Tint selected textures with orange overlay
        if (is_selected) {
            vec4 selection_tint = vec4(1.0, 0.7, 0.3, 0.4);
            out_color = mix(texture_color, selection_tint, selection_tint.a);
        } else {
            out_color = texture_color;
        }
    } else {
        // Magenta for unknown geometry types
        out_color = vec4(1.0, 0.0, 1.0, 1.0);
    }
}
