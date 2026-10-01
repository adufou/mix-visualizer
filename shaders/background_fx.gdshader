shader_type canvas_item;
// Background image FX chain. Each effect lives in shaders/fx/ as a pure
// function; this file only owns the uniforms and the stage order:
//   1. warp    — sum UV offsets (heat), sample once
//   2. sample  — effects reading neighbouring texels of the warped uv (glow)
//   3. grade   — per-pixel color ops (saturation)
//   4. overlay — screen-space layers drawn last (grain)
// Each effect has an *_enabled toggle, set from the esc menu.
// Strengths are driven by master's 3 band levels plus tempo sync, fed by
// background_fx.gd. Reads the node's own TEXTURE rather than SCREEN_TEXTURE,
// so it doesn't depend on backbuffer-copy timing across nodes.

#include "res://shaders/fx/common.gdshaderinc"
#include "res://shaders/fx/heat.gdshaderinc"
#include "res://shaders/fx/glow.gdshaderinc"
#include "res://shaders/fx/grade.gdshaderinc"
#include "res://shaders/fx/grain.gdshaderinc"

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

uniform bool heat_enabled = true;
uniform bool glow_enabled = true;
uniform bool saturation_enabled = true;
uniform bool grain_enabled = true;

void fragment() {
	// 1. Warp. Heat wobble speed tracks BPM (120 BPM = baseline speed), falling
	// back to baseline if no BPM yet.
	float tempo_scale = bpm > 0.0 ? bpm / 120.0 : 1.0;
	float heat_t = TIME * distort_speed * tempo_scale;
	float heat_amp = heat_amplitude(low_intensity, beat_phase, beat_pulse);
	vec2 uv = UV;
	if (heat_enabled) {
		uv += heat_offset(UV, heat_amp, heat_t, distort_frequency);
	}
	vec4 base = texture(TEXTURE, uv);
	vec3 col = base.rgb;

	// 2. Sample.
	if (glow_enabled) {
		col += glow(TEXTURE, uv, TEXTURE_PIXEL_SIZE, glow_threshold, glow_tint.rgb, mid_intensity);
	}

	// 3. Grade.
	if (saturation_enabled) {
		col = saturate_color(col, mid_intensity * saturation_boost);
	}

	// 4. Overlay.
	if (grain_enabled) {
		col = grain(col, FRAGCOORD.xy, TIME, grain_size, high_intensity);
	}

	COLOR = vec4(col, base.a);
}
