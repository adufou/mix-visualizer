// Overlay stage, high band: animated film grain in screen space. Reseeds the
// hash wholesale each frame (rather than translating the uv) so it doesn't
// read as a sliding pattern, just flicker — like real film grain.
// Needs common.gdshaderinc.

vec3 grain(vec3 col, vec2 fragcoord, float time, float size, float intensity) {
	float noise = rand(fragcoord / size + fract(time) * 197.0) - 0.5;
	return col + noise * intensity * 9.0; // TEMP: cranked for visibility test
}
