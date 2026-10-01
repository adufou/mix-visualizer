// Sample stage, mid band: cheap ring-sample bloom around the (already
// warped) uv. Returns the light to add on top of the base color.
// Needs common.gdshaderinc.

vec3 glow(sampler2D tex, vec2 uv, vec2 pixel_size, float threshold, vec3 tint, float intensity) {
	vec2 texel = pixel_size * 3.0;
	vec2 offsets[8] = vec2[](
		vec2(1.0, 0.0), vec2(-1.0, 0.0), vec2(0.0, 1.0), vec2(0.0, -1.0),
		vec2(0.7, 0.7), vec2(-0.7, 0.7), vec2(0.7, -0.7), vec2(-0.7, -0.7)
	);
	vec3 bloom = vec3(0.0);
	for (int i = 0; i < 8; i++) {
		bloom += texture(tex, uv + offsets[i] * texel).rgb;
	}
	bloom /= 8.0;
	vec3 bright = max(bloom - threshold, 0.0) / max(1.0 - threshold, 0.0001) * luma(bloom);
	return bright * tint * intensity * 9.0;
}
