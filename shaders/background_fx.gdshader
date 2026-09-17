shader_type canvas_item;
// Combined heat-distortion (low) / glow (mid) / grain (high) effect for the
// background image, each stage's strength driven by one of master's 3 band
// levels. Reads the node's own TEXTURE rather than SCREEN_TEXTURE, so it
// doesn't depend on backbuffer-copy timing across nodes.

uniform float low_intensity : hint_range(0.0, 1.0) = 0.0;
uniform float mid_intensity : hint_range(0.0, 1.0) = 0.0;
uniform float high_intensity : hint_range(0.0, 1.0) = 0.0;

// Tempo sync: beat_phase is Mixxx's own drift-free 0..1 phase into the current
// beat (wraps on each beat hit); beat_pulse is a decaying kick set to 1.0 by
// the client on that same wraparound. bpm 0.0 means no track loaded/analyzed.
uniform float beat_phase : hint_range(0.0, 1.0) = 0.0;
uniform float beat_pulse : hint_range(0.0, 1.0) = 0.0;
uniform float bpm = 0.0;

uniform float distort_speed = 1.0;
uniform float distort_frequency = 12.0;
uniform float glow_threshold : hint_range(0.0, 1.0) = 0.55;
uniform vec4 glow_tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float saturation_boost = 2.25;
uniform float grain_size = 1.6;

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

void fragment() {
	// Low band: heat rises, so distortion is strongest at the bottom, fading
	// out near the top. Wobble speed tracks BPM (120 BPM = baseline speed) so
	// faster tracks flicker faster; falls back to baseline speed if no BPM yet.
	float tempo_scale = bpm > 0.0 ? bpm / 120.0 : 1.0;
	float t = TIME * distort_speed * tempo_scale;
	float rise = 1.0 - UV.y;
	// Flow-field drift instead of clean sine ripple — same t (so speed still
	// tracks bpm), but fbm's uneven lattice makes the wobble look like real
	// rising heat instead of a repeating wave. x/y sample different regions
	// of the noise (offset + opposite drift direction) so they decorrelate.
	vec2 flow_uv = UV * distort_frequency * 0.25;
	float wobble_x = (fbm(flow_uv + vec2(t, -t * 0.6)) - 0.5) * 0.05;
	float wobble_y = (fbm(flow_uv + vec2(-t * 0.7, t * 0.5) + vec2(5.2, 1.7)) - 0.5) * 0.035;

	// Beat envelope: heat surges right after the beat hits (beat_phase near 0)
	// and eases off approaching the next one, plus a sharp decaying kick on
	// the beat itself — both driven by Mixxx's own phase, so no drift on
	// scratch/loop/tempo change.
	float beat_env = pow(1.0 - beat_phase, 2.0);
	float heat_amp = low_intensity * (0.6 + 0.4 * beat_env) + beat_pulse * 0.3 * low_intensity;

	vec2 uv = UV + vec2(wobble_x, wobble_y) * rise * heat_amp;
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
	vec3 col = base.rgb + bright * glow_tint.rgb * mid_intensity * 9.0;

	// Mid band, part 2: saturation boost stacked on top of the glow — pushes
	// color away from grey rather than adding brightness.
	float col_luma = dot(col, vec3(0.299, 0.587, 0.114));
	col = mix(vec3(col_luma), col, 1.0 + mid_intensity * saturation_boost);

	// High band: animated film grain. Reseed the hash wholesale each frame
	// (rather than translating the uv) so it doesn't read as a sliding
	// pattern, just flicker — like real film grain.
	vec2 grain_uv = FRAGCOORD.xy / grain_size;
	float noise = rand(grain_uv + fract(TIME) * 197.0) - 0.5;
	col += noise * high_intensity * 9.0; // TEMP: cranked for visibility test

	COLOR = vec4(col, base.a);
}
