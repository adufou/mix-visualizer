extends Control
## Timeline strip under the preview: one row per shown deck, one block per
## track load (from its load until the next load on that deck), plus the
## playhead. Click or drag to seek.

signal seek_requested(t: float)

const ROW_GAP := 2.0
const BLOCK_COLORS := [Color(0.25, 0.45, 0.75), Color(0.3, 0.6, 0.45)]

var duration := 0.0
## deck_id -> Array of { start, end, label }
var _rows: Dictionary = {}


func set_recording(recording: MixRecording, new_duration: float) -> void:
	duration = new_duration
	_rows.clear()
	if recording != null:
		for deck_id in recording.used_decks():
			var blocks: Array = []
			for event in recording.track_events:
				if event["deck"] != deck_id:
					continue
				if not blocks.is_empty() and blocks[-1]["load_id"] == event["load_id"]:
					continue # waveform update of the same load
				if not blocks.is_empty():
					blocks[-1]["end"] = event["t"]
				var label := "%s - %s" % [event["artist"], event["title"]]
				blocks.append({"load_id": event["load_id"], "start": event["t"], "end": duration, "label": label})
			_rows[deck_id] = blocks
	queue_redraw()


func _process(_delta: float) -> void:
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	var pressed: bool = event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT
	var dragged: bool = event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0
	if (pressed or dragged) and duration > 0.0:
		seek_requested.emit(clamp(event.position.x / size.x, 0.0, 1.0) * duration)
		accept_event()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.1, 0.1, 0.1))
	if duration <= 0.0 or _rows.is_empty():
		return
	var font := get_theme_default_font()
	var font_size := get_theme_default_font_size()
	var row_height := (size.y - ROW_GAP * (_rows.size() - 1)) / _rows.size()
	var row_index := 0
	for deck_id in _rows.keys():
		var y := row_index * (row_height + ROW_GAP)
		var color: Color = BLOCK_COLORS[row_index % BLOCK_COLORS.size()]
		for block in _rows[deck_id]:
			var x0: float = block["start"] / duration * size.x
			var x1: float = block["end"] / duration * size.x
			var rect := Rect2(x0, y, max(1.0, x1 - x0 - 1.0), row_height)
			draw_rect(rect, color)
			if rect.size.x > 30.0:
				draw_string(font, Vector2(x0 + 4.0, y + (row_height + font_size) * 0.5 - 2.0), block["label"],
						HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 8.0, font_size, Color.WHITE)
		row_index += 1
	var playhead_x := MixData.time / duration * size.x
	draw_line(Vector2(playhead_x, 0.0), Vector2(playhead_x, size.y), Color.WHITE, 2.0)
