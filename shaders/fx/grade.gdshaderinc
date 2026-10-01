// Grade stage: per-pixel color ops, no texture reads.
// Needs common.gdshaderinc.

// Pushes color away from grey rather than adding brightness. amount 0 is
// identity.
vec3 saturate_color(vec3 col, float amount) {
	return mix(vec3(luma(col)), col, 1.0 + amount);
}
