// Hum bug: CRT power-supply hum bar. Split across two stages — a horizontal
// sync-jitter in the warp stage, and bright edge lines + desaturation in the
// overlay stage — so it no longer re-samples the texture and wipes out the
// glow/grade/grain underneath it. The bar scrolls continuously off time, so
// its position isn't synced to the trigger (matches how a real hum bar drifts
// independent of content).
// Needs common.gdshaderinc.

float hum_bar_y(float time, float speed) {
	return fract(time * speed);
}

// Distance from the bar's center, wrapped across the 0/1 seam.
float hum_dist(float y, float bar_y) {
	float dist = abs(y - bar_y);
	return min(dist, 1.0 - dist);
}

vec2 hum_offset(float y, float time, float speed, float width, float strength) {
	float bar_y = hum_bar_y(time, speed);
	float amount = smoothstep(width, 0.0, hum_dist(y, bar_y)) * strength;
	return vec2(sin(bar_y * 40.0 + time * 8.0) * 0.01, 0.0) * amount;
}

vec3 hum_overlay(vec3 col, float y, float time, float speed, float width, float strength) {
	float dist = hum_dist(y, hum_bar_y(time, speed));
	float band = smoothstep(width, 0.0, dist);
	float edge = smoothstep(width, width * 0.4, dist) - smoothstep(width * 0.4, 0.0, dist);
	col *= mix(1.0, 1.35, edge * strength);
	return mix(col, vec3(luma(col)), 0.3 * band * strength);
}
