extends Control
## Live 3-band master level meter with light lerp/decay toward each new value.

const DECAY_SPEED := 12.0

@onready var low_bar: ColorRect = %LowBar
@onready var mid_bar: ColorRect = %MidBar
@onready var high_bar: ColorRect = %HighBar

var _display_low := 0.0
var _display_mid := 0.0
var _display_high := 0.0

const MAX_BAR_HEIGHT := 100.0 # matches each bar container's custom_minimum_size.y


func _process(delta: float) -> void:
	var t: float = clamp(delta * DECAY_SPEED, 0.0, 1.0)
	_display_low = lerp(_display_low, float(MixxxClient.master.get("low", 0.0)), t)
	_display_mid = lerp(_display_mid, float(MixxxClient.master.get("mid", 0.0)), t)
	_display_high = lerp(_display_high, float(MixxxClient.master.get("high", 0.0)), t)

	_apply_bar_height(low_bar, _display_low)
	_apply_bar_height(mid_bar, _display_mid)
	_apply_bar_height(high_bar, _display_high)


func _apply_bar_height(bar: ColorRect, value: float) -> void:
	var h: float = clamp(value, 0.0, 1.0) * MAX_BAR_HEIGHT
	bar.size.y = h
	bar.position.y = MAX_BAR_HEIGHT - h
