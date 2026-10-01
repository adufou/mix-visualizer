// Warp stage, low band: rising-heat distortion. Returns a UV offset; the
// caller sums all warp offsets and samples the texture once.
// Needs common.gdshaderinc.

// Beat envelope: heat surges right after the beat hits (beat_phase near 0)
// and eases off approaching the next one, plus a sharp decaying kick on the
// beat itself — both driven by Mixxx's own phase, so no drift on
// scratch/loop/tempo change.
float heat_amplitude(float intensity, float beat_phase, float beat_pulse) {
	float beat_env = pow(1.0 - beat_phase, 2.0);
	return intensity * (0.6 + 0.4 * beat_env) + beat_pulse * 0.3 * intensity;
}

// Heat rises, so distortion is strongest at the bottom, fading out near the
// top. Flow-field drift instead of clean sine ripple — fbm's uneven lattice
// makes the wobble look like real rising heat instead of a repeating wave.
// x/y sample different regions of the noise (offset + opposite drift
// direction) so they decorrelate.
vec2 heat_offset(vec2 uv, float amp, float t, float frequency) {
	float rise = 1.0 - uv.y;
	vec2 flow_uv = uv * frequency * 0.25;
	float wobble_x = (fbm(flow_uv + vec2(t, -t * 0.6)) - 0.5) * 0.05;
	float wobble_y = (fbm(flow_uv + vec2(-t * 0.7, t * 0.5) + vec2(5.2, 1.7)) - 0.5) * 0.035;
	return vec2(wobble_x, wobble_y) * rise * amp;
}
