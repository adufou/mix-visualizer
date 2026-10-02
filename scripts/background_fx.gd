class_name BackgroundFx
extends TextureRect
## Drives background_fx.gdshader's 3 intensity uniforms from master's
## low/mid/high band levels (MixData.master), with light lerp/decay
## toward each new value — same smoothing approach as master_meter.gd.
## Also feeds the heat wobble a tempo sync (bpm, beat_phase, beat_pulse) taken
## from whichever deck currently dominates the mix (MixData.latest_levels).
## Exposes per-effect and master on/off toggles for the esc menu.

## Effect name -> the shader's bool uniform gating that stage.
const EFFECTS := {
	"Heat": "heat_enabled",
	"Glow": "glow_enabled",
	"Saturation": "saturation_enabled",
	"Grain": "grain_enabled",
}

const DECAY_SPEED := 10.0

## Heat (low band) envelope: snaps up almost instantly, then eases back down
## over ~100ms once the level drops, instead of tracking symmetrically.
const LOW_ATTACK_TAU := 0.01
const LOW_RELEASE_TAU := 0.1

## Decaying kick applied to the heat shader on each beat hit.
const BEAT_PULSE_DECAY_TAU := 0.15

var _display_low := 0.0
var _display_mid := 0.0
var _display_high := 0.0

var _beat_phase := 0.0
var _beat_pulse := 0.0
var _prev_beat_distance := 0.0
var _display_bpm := 0.0

## Kept so the master toggle can strip the material and put it back.
@onready var _fx_material: ShaderMaterial = material
var _effect_enabled := {}


func _ready() -> void:
	for effect in EFFECTS.keys():
		set_effect_enabled(effect, true)


func is_all_enabled() -> bool:
	return material != null


## Master toggle: off removes the material entirely (plain image, no shader
## cost) and stops feeding uniforms.
func set_all_enabled(enabled: bool) -> void:
	material = _fx_material if enabled else null
	set_process(enabled)


func is_effect_enabled(effect: String) -> bool:
	return _effect_enabled[effect]


func set_effect_enabled(effect: String, enabled: bool) -> void:
	_effect_enabled[effect] = enabled
	_fx_material.set_shader_parameter(EFFECTS[effect], enabled)


func _process(delta: float) -> void:
	var t: float = clamp(delta * DECAY_SPEED, 0.0, 1.0)
	var low_target: float = clamp(float(MixData.master.get("low", 0.0)), 0.0, 1.0)
	var tau: float = LOW_ATTACK_TAU if low_target > _display_low else LOW_RELEASE_TAU
	_display_low = lerp(_display_low, low_target, clamp(1.0 - exp(-delta / tau), 0.0, 1.0))
	_display_mid = lerp(_display_mid, clamp(float(MixData.master.get("mid", 0.0)), 0.0, 1.0), t)
	_display_high = lerp(_display_high, clamp(float(MixData.master.get("high", 0.0)), 0.0, 1.0), t)

	_update_beat_sync(delta)

	material.set_shader_parameter("low_intensity", _display_low)
	material.set_shader_parameter("mid_intensity", _display_mid)
	material.set_shader_parameter("high_intensity", _display_high)
	material.set_shader_parameter("beat_phase", _beat_phase)
	material.set_shader_parameter("beat_pulse", _beat_pulse)
	material.set_shader_parameter("bpm", _display_bpm)


## Tempo sync source: the loudest deck that's actually playing a track
## (bpm > 0). Mixed decks can't share one phase, so we follow whichever one
## currently dominates the mix.
func _pick_tempo_deck() -> Dictionary:
	var best: Dictionary = {}
	var best_volume := -1.0
	for deck_id in MixData.latest_levels.keys():
		var levels: Dictionary = MixData.latest_levels[deck_id]
		if float(levels.get("bpm", 0.0)) <= 0.0:
			continue
		var volume: float = float(levels.get("volume", 0.0))
		if volume > best_volume:
			best_volume = volume
			best = levels
	return best


func _update_beat_sync(delta: float) -> void:
	var deck: Dictionary = _pick_tempo_deck()
	if deck.is_empty():
		_display_bpm = 0.0
	else:
		_display_bpm = float(deck.get("bpm", 0.0))
		var beat_distance: float = float(deck.get("beat_distance", 0.0))
		if _prev_beat_distance > 0.9 and beat_distance < 0.1:
			_beat_pulse = 1.0
		_prev_beat_distance = beat_distance
		_beat_phase = beat_distance

	_beat_pulse = lerp(_beat_pulse, 0.0, clamp(1.0 - exp(-delta / BEAT_PULSE_DECAY_TAU), 0.0, 1.0))

