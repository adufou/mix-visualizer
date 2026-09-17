shader_type canvas_item;
// Combined heat-distortion (low) / glow (mid) / grain (high) effect for the
// background image, each stage's strength driven by one of master's 3 band
// levels. Reads the node's own TEXTURE rather than SCREEN_TEXTURE, so it
// doesn't depend on backbuffer-copy timing across nodes.

uniform float low_intensity : hint_range(0.0, 1.0) = 0.0;
uniform float mid_intensity : hint_range(0.0, 1.0) = 0.0;
uniform float high_intensity : hint_range(0.0, 1.0) = 0.0;

uniform float distort_speed = 1.5;
uniform float distort_frequency = 12.0;
uniform float glow_threshold : hint_range(0.0, 1.0) = 0.55;
uniform vec4 glow_tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float grain_size = 1.6;

// Better-distributed hash than sin/dot — avoids the visible banding that
// hash produces at grain scale.
float rand(vec2 co) {
	vec3 p3 = fract(vec3(co.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void fragment() {
	// Low band: heat rises, so distortion is strongest at the bottom, fading
	// out near the top.
	float rise = 1.0 - UV.y;
	float wobble_x = sin(UV.y * distort_frequency + TIME * distort_speed) * 0.012
			+ sin(UV.y * distort_frequency * 2.3 - TIME * distort_speed * 1.7) * 0.006;
	float wobble_y = sin(UV.x * distort_frequency * 0.8 - TIME * distort_speed * 1.3) * 0.008
			+ sin(UV.x * distort_frequency * 1.9 + TIME * distort_speed * 0.6) * 0.004;
	vec2 uv = UV + vec2(wobble_x, wobble_y) * rise * low_intensity;
	vec4 base = texture(TEXTURE, uv);

	// Mid band: cheap ring-sample bloom on top of the (already distorted) uv.
	vec2 texel = TEXTURE_PIXEL_SIZE * 3.0;
	vec2 offsets[8] = vec2[](
		vec2(1.0, 0.0), vec2(-1.0, 0.0), vec2(0.0, 1.0), vec2(0.0, -1.0),
		vec2(0.7, 0.7), vec2(-0.7, 0.7), vec2(0.7, -0.7), vec2(-0.7, -0.7)
	);
	vec3 bloom = vec3(0.0);
	for (int i = 0; i < 8; i++) {
		bloom += texture(TEXTURE, uv + offsets[i] * texel).rgb;
	}
	bloom /= 8.0;
	float luma = dot(bloom, vec3(0.299, 0.587, 0.114));
	vec3 bright = max(bloom - glow_threshold, 0.0) / max(1.0 - glow_threshold, 0.0001) * luma;
	vec3 col = base.rgb + bright * glow_tint.rgb * mid_intensity * 6.0;

	// High band: animated film grain. Reseed the hash wholesale each frame
	// (rather than translating the uv) so it doesn't read as a sliding
	// pattern, just flicker — like real film grain.
	vec2 grain_uv = FRAGCOORD.xy / grain_size;
	float noise = rand(grain_uv + fract(TIME) * 197.0) - 0.5;
	col += noise * high_intensity * 6.0; // TEMP: cranked for visibility test

	COLOR = vec4(col, base.a);
}
