shader_type canvas_item;
// Scrolling 3-band waveform, drawn per pixel on the GPU. Reproduces the
// previous CPU version exactly: one bar per waveform frame per band (1 px
// wide minimum, so 2-3 bars overlap per pixel column when zoomed out),
// blended in the same order (frame by frame, low -> mid -> high).

// Waveform frames as RGB = low/mid/high (0..255 -> 0..1), stored row by row
// in a texture `tex_width` texels wide.
uniform sampler2D wave : filter_nearest;
uniform int tex_width = 4096;
// The waveform control's size, and where its local origin sits on the render
// target (pixels) with its scale: maps FRAGCOORD (exact pixel centers) back
// to local space. This shader's own rect is bigger than the control because
// bars overflow it: half a bar at the sides, above/below when EQ boosts > 1x.
uniform vec2 rect_size;
uniform vec2 screen_origin;
uniform vec2 screen_scale = vec2(1.0);
uniform int center_frame;
uniform int start_frame;
uniform int end_frame;
uniform float px_per_frame;
// Frames shown on each side of the playhead (px_per_frame = width / (2 * this)).
uniform int window_frames = 1;
uniform float bar_width;
// EQ gain per band, 0 when the band is killed.
uniform vec3 eq = vec3(1.0);
uniform vec4 color_low;
uniform vec4 color_mid;
uniform vec4 color_high;

// Same coverage rule as the rasterizer, in render-target pixels: edges are
// snapped to 1/256 px (GPU subpixel precision), then a pixel belongs to a bar
// if its center is inside [start, end). `frag` is FRAGCOORD on that axis.
bool covers(float center, float half_size, float frag, float origin, float scale) {
	float start = round((origin + (center - half_size) * scale) * 256.0) / 256.0;
	float end = round((origin + (center + half_size) * scale) * 256.0) / 256.0;
	return frag >= start && frag < end;
}

void blend(inout vec3 premul, inout float transparency, vec4 color, float opacity) {
	float a = color.a * opacity;
	premul = premul * (1.0 - a) + color.rgb * a;
	transparency *= 1.0 - a;
}

void fragment() {
	// Inherited modulate (deck volume fade) arrives in COLOR; apply it per bar.
	float opacity = COLOR.a;
	vec2 p = (FRAGCOORD.xy - screen_origin) / screen_scale; // this pixel's center, local space
	float center_x = rect_size.x * 0.5;
	float half_height = rect_size.y * 0.5;
	float half_bar = bar_width * 0.5;

	// Bar i spans [x_i - half_bar, x_i + half_bar) with
	// x_i = center_x + (i - center_frame) * px_per_frame; only a few cover p.x.
	float first = (p.x - half_bar - center_x) / px_per_frame + float(center_frame);
	int i0 = max(start_frame, int(floor(first)) - 1);
	int i1 = min(end_frame, int(floor(first + bar_width / px_per_frame)) + 1);

	vec3 premul = vec3(0.0);
	float transparency = 1.0;
	for (int i = i0; i <= i1; i++) {
		// Multiply before dividing: exact when a bar lands on a whole pixel, so
		// those ties resolve like the CPU version's double-precision positions.
		float x = center_x + float(i - center_frame) * rect_size.x / float(2 * window_frames);
		if (!covers(x, half_bar, FRAGCOORD.x, screen_origin.x, screen_scale.x)) {
			continue;
		}
		vec3 amp = texelFetch(wave, ivec2(i % tex_width, i / tex_width), 0).rgb * eq;
		vec3 bar_height = amp * half_height;
		if (bar_height.x > 0.0 && covers(half_height, bar_height.x, FRAGCOORD.y, screen_origin.y, screen_scale.y)) {
			blend(premul, transparency, color_low, opacity);
		}
		if (bar_height.y > 0.0 && covers(half_height, bar_height.y, FRAGCOORD.y, screen_origin.y, screen_scale.y)) {
			blend(premul, transparency, color_mid, opacity);
		}
		if (bar_height.z > 0.0 && covers(half_height, bar_height.z, FRAGCOORD.y, screen_origin.y, screen_scale.y)) {
			blend(premul, transparency, color_high, opacity);
		}
	}
	float alpha = 1.0 - transparency;
	COLOR = alpha > 0.0 ? vec4(premul / alpha, alpha) : vec4(0.0);
}
