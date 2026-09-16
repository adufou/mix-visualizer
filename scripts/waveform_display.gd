extends Control
## Scrolling 3-band waveform for one deck, centered on the live playhead.

@export var deck_id := "[Channel1]"
@export var window_seconds := 5.0

const COLOR_LOW := Color(0.9, 0.45, 0.15, 0.85)   # warm orange
const COLOR_MID := Color(0.85, 0.15, 0.15, 0.75)  # red
const COLOR_HIGH := Color(0.95, 0.85, 0.25, 0.65) # yellow-ish
const PLAYHEAD_COLOR := Color(1, 1, 1, 0.9)


func _ready() -> void:
	set_process(true)


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	var rect_size := size
	var center_x := rect_size.x * 0.5
	var half_height := rect_size.y * 0.5

	var deck: Dictionary = MixxxClient.decks.get(deck_id, {})
	if not deck.has("waveform_frame_count") or not deck.has("waveform_bytes"):
		draw_line(Vector2(center_x, 0), Vector2(center_x, rect_size.y), PLAYHEAD_COLOR, 2.0)
		return

	var levels: Dictionary = MixxxClient.latest_levels.get(deck_id, {})
	var pos: float = levels.get("pos", -1.0)
	if pos < 0.0:
		draw_line(Vector2(center_x, 0), Vector2(center_x, rect_size.y), PLAYHEAD_COLOR, 2.0)
		return

	var frame_count: int = deck["waveform_frame_count"]
	var sample_rate: float = deck["waveform_sample_rate"]
	var bytes: PackedByteArray = deck["waveform_bytes"]
	if frame_count <= 0 or sample_rate <= 0.0 or bytes.is_empty():
		return

	var center_frame := int(pos * frame_count)
	var window_frames: int = max(1, int(window_seconds * sample_rate))
	var start_frame: int = max(0, center_frame - window_frames)
	var end_frame: int = min(frame_count - 1, center_frame + window_frames)

	var eq_low: float = levels.get("eq_low", 1.0)
	var eq_mid: float = levels.get("eq_mid", 1.0)
	var eq_high: float = levels.get("eq_high", 1.0)
	var kill_low: bool = levels.get("kill_low", false)
	var kill_mid: bool = levels.get("kill_mid", false)
	var kill_high: bool = levels.get("kill_high", false)

	var px_per_frame := rect_size.x / float(2 * window_frames)

	for frame_i in range(start_frame, end_frame + 1):
		var byte_offset := frame_i * 3
		if byte_offset + 2 >= bytes.size():
			break
		var low_amp: float = 0.0 if kill_low else (bytes[byte_offset] / 255.0) * eq_low
		var mid_amp: float = 0.0 if kill_mid else (bytes[byte_offset + 1] / 255.0) * eq_mid
		var high_amp: float = 0.0 if kill_high else (bytes[byte_offset + 2] / 255.0) * eq_high

		var x := center_x + (frame_i - center_frame) * px_per_frame
		var bar_width: float = max(1.0, px_per_frame)

		_draw_band_bar(x, bar_width, low_amp, half_height, COLOR_LOW)
		_draw_band_bar(x, bar_width, mid_amp, half_height, COLOR_MID)
		_draw_band_bar(x, bar_width, high_amp, half_height, COLOR_HIGH)

	draw_line(Vector2(center_x, 0), Vector2(center_x, rect_size.y), PLAYHEAD_COLOR, 2.0)


func _draw_band_bar(x: float, width: float, amplitude: float, half_height: float, color: Color) -> void:
	var bar_height := amplitude * half_height
	if bar_height <= 0.0:
		return
	var rect := Rect2(x - width * 0.5, half_height - bar_height, width, bar_height * 2.0)
	draw_rect(rect, color, true)
