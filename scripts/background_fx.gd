extends TextureRect
## Drives background_fx.gdshader's 3 intensity uniforms from master's
## low/mid/high band levels (MixxxClient.master), with light lerp/decay
## toward each new value — same smoothing approach as master_meter.gd.

const DECAY_SPEED := 10.0

var _display_low := 0.0
var _display_mid := 0.0
var _display_high := 0.0


func _process(delta: float) -> void:
	var t: float = clamp(delta * DECAY_SPEED, 0.0, 1.0)
	_display_low = lerp(_display_low, clamp(float(MixxxClient.master.get("low", 0.0)), 0.0, 1.0), t)
	_display_mid = lerp(_display_mid, clamp(float(MixxxClient.master.get("mid", 0.0)), 0.0, 1.0), t)
	_display_high = lerp(_display_high, clamp(float(MixxxClient.master.get("high", 0.0)), 0.0, 1.0), t)

	material.set_shader_parameter("low_intensity", _display_low)
	material.set_shader_parameter("mid_intensity", _display_mid)
	material.set_shader_parameter("high_intensity", _display_high)
