// Shared helpers for the background FX stages.

const vec3 LUMA_WEIGHTS = vec3(0.299, 0.587, 0.114);

float luma(vec3 c) {
	return dot(c, LUMA_WEIGHTS);
}

// Better-distributed hash than sin/dot — avoids the visible banding that
// hash produces at grain scale.
float rand(vec2 co) {
	vec3 p3 = fract(vec3(co.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

// Smooth value noise (bilinear-interpolated hash lattice) — gives the heat
// wobble an organic, non-repeating drift instead of a clean sine ripple.
float value_noise(vec2 co) {
	vec2 i = floor(co);
	vec2 f = fract(co);
	float a = rand(i);
	float b = rand(i + vec2(1.0, 0.0));
	float c = rand(i + vec2(0.0, 1.0));
	float d = rand(i + vec2(1.0, 1.0));
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Two-octave fbm: cheap enough for per-pixel use, enough detail to break up
// the single-frequency look of raw value noise.
float fbm(vec2 co) {
	float n = value_noise(co) * 0.6;
	n += value_noise(co * 2.3 + 11.0) * 0.4;
	return n;
}
