// Overlay stage, high band: animated film grain in screen space. Reseeds the
// hash wholesale each frame (rather than translating the uv) so it doesn't
// read as a sliding pattern, just flicker — like real film grain.
// Grain cells are snapped to a 1080p reference grid, so the grain keeps the
// same on-screen size at any output resolution (2x2 px cells at 2160p)
// instead of shrinking to invisible single pixels.
// Needs common.gdshaderinc.

vec3 grain(vec3 col, vec2 fragcoord, vec2 screen_pixel_size, float time, float size, float intensity) {
	vec2 cell = floor(fragcoord * 1080.0 * screen_pixel_size.y);
	float noise = rand(cell / size + fract(time) * 197.0) - 0.5;
	return col + noise * intensity * 9.0; // TEMP: cranked for visibility test
}
