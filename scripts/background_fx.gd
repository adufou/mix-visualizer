extends TextureRect
## Drives background_fx.gdshader's 3 intensity uniforms from master's
## low/mid/high band levels (MixxxClient.master), with light lerp/decay
## toward each new value — same smoothing approach as master_meter.gd.

const DECAY_SPEED := 10.0

## Heat (low band) envelope: snaps up almost instantly, then eases back down
## over ~100ms once the level drops, instead of tracking symmetrically.
const LOW_ATTACK_TAU := 0.01
const LOW_RELEASE_TAU := 0.1

var _display_low := 0.0
var _display_mid := 0.0
var _display_high := 0.0


func _process(delta: float) -> void:
	var t: float = clamp(delta * DECAY_SPEED, 0.0, 1.0)
	var low_target: float = clamp(float(MixxxClient.master.get("low", 0.0)), 0.0, 1.0)
	var tau: float = LOW_ATTACK_TAU if low_target > _display_low else LOW_RELEASE_TAU
	_display_low = lerp(_display_low, low_target, clamp(1.0 - exp(-delta / tau), 0.0, 1.0))
	_display_mid = lerp(_display_mid, clamp(float(MixxxClient.master.get("mid", 0.0)), 0.0, 1.0), t)
	_display_high = lerp(_display_high, clamp(float(MixxxClient.master.get("high", 0.0)), 0.0, 1.0), t)

	material.set_shader_parameter("low_intensity", _display_low)
	material.set_shader_parameter("mid_intensity", _display_mid)
	material.set_shader_parameter("high_intensity", _display_high)
