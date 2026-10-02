extends Control
## Scrolling 3-band waveform for one deck, centered on the live playhead.
## The bars are drawn by shaders/waveform.gdshader (one pass on the GPU, from
## the track's waveform uploaded once as a texture); this script only feeds it
## the playhead position, EQ and colors each frame.

@export var deck_id := "[Channel1]"
@export var window_seconds := 5.0

const ALPHA_LOW := 0.85
const ALPHA_MID := 0.75
const ALPHA_HIGH := 0.65
const PLAYHEAD_COLOR := Color(1, 1, 1, 0.9)
const PLAYHEAD_WIDTH := 2.0
## Waveform texture row length (texels); tracks wrap onto more rows.
const TEXTURE_WIDTH := 4096
## Max EQ gain (+12 dB): a fully boosted band's bar is 4x the half height,
## so bars can reach 1.5 heights beyond the control above and below.
const MAX_EQ_GAIN := 4.0

## Mixxx's VisualPlayPosition is smoothed/interpolated for display and can
## overshoot slightly below 0 (or above 1) right at a track's edges. Only the
## literal -1.0 sentinel means "no track" — anything else gets clamped.
const NO_TRACK_POS_THRESHOLD := -0.5

var _bars := ColorRect.new()
var _playhead := ColorRect.new()
var _material := ShaderMaterial.new()
## Identifies the waveform currently uploaded: "<load_id>:<frame_count>".
var _texture_key := ""


func _ready() -> void:
	_material.shader = preload("res://shaders/waveform.gdshader")
	_material.set_shader_parameter("tex_width", TEXTURE_WIDTH)
	_bars.material = _material
	_bars.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bars.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_bars)
	resized.connect(_fit_bars_rect)
	_fit_bars_rect()

	# Same 2 px line the CPU version drew, on top of the bars.
	_playhead.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_playhead.anchor_left = 0.5
	_playhead.anchor_right = 0.5
	_playhead.anchor_bottom = 1.0
	_playhead.offset_left = -PLAYHEAD_WIDTH * 0.5
	_playhead.offset_right = PLAYHEAD_WIDTH * 0.5
	add_child(_playhead)

	BackgroundManager.colors_changed.connect(_on_colors_changed)
	_on_colors_changed(BackgroundManager.current_colors)


## The bars' rect covers everything a bar can reach outside the control (the
## CPU version drew unclipped): half a bar plus a pixel at the sides,
## (MAX_EQ_GAIN - 1) half heights above and below.
func _fit_bars_rect() -> void:
	var overflow_y := (MAX_EQ_GAIN - 1.0) * size.y * 0.5
	_bars.offset_left = -2.0
	_bars.offset_right = 2.0
	_bars.offset_top = -overflow_y
	_bars.offset_bottom = overflow_y


## Band accent colors, user-chosen via the editor's color pickers.
func _on_colors_changed(colors: Dictionary) -> void:
	_material.set_shader_parameter("color_low", Color(colors["low"], ALPHA_LOW))
	_material.set_shader_parameter("color_mid", Color(colors["mid"], ALPHA_MID))
	_material.set_shader_parameter("color_high", Color(colors["high"], ALPHA_HIGH))
	_playhead.color = Color(colors["accent"], PLAYHEAD_COLOR.a)


func _process(_delta: float) -> void:
	var deck: Dictionary = MixData.decks.get(deck_id, {})
	var levels: Dictionary = MixData.latest_levels.get(deck_id, {})
	var frame_count: int = deck.get("waveform_frame_count", 0)
	var sample_rate: float = deck.get("waveform_sample_rate", 0.0)
	var pos: float = levels.get("pos", -1.0)
	var bytes: PackedByteArray = deck.get("waveform_bytes", PackedByteArray())
	# Playhead alone when there's no track; nothing at all while a loaded
	# track's waveform is still missing (as the original CPU drawing did).
	var no_track := not deck.has("waveform_frame_count") or pos <= NO_TRACK_POS_THRESHOLD
	var no_waveform := frame_count <= 0 or sample_rate <= 0.0 or bytes.is_empty()
	_playhead.visible = no_track or not no_waveform
	if no_track or no_waveform:
		_bars.visible = false
		return
	_update_texture(deck)
	_bars.visible = true

	var center_frame := int(clamp(pos, 0.0, 1.0) * frame_count)
	var window_frames: int = max(1, int(window_seconds * sample_rate))
	var px_per_frame := size.x / float(2 * window_frames)
	_material.set_shader_parameter("rect_size", size)
	var to_screen := get_viewport().get_final_transform() * get_global_transform_with_canvas()
	_material.set_shader_parameter("screen_origin", to_screen.origin)
	_material.set_shader_parameter("screen_scale", to_screen.get_scale())
	_material.set_shader_parameter("center_frame", center_frame)
	_material.set_shader_parameter("start_frame", max(0, center_frame - window_frames))
	_material.set_shader_parameter("end_frame", min(frame_count - 1, center_frame + window_frames))
	_material.set_shader_parameter("px_per_frame", px_per_frame)
	_material.set_shader_parameter("window_frames", window_frames)
	_material.set_shader_parameter("bar_width", max(1.0, px_per_frame))
	_material.set_shader_parameter("eq", Vector3(
		0.0 if levels.get("kill_low", false) else levels.get("eq_low", 1.0),
		0.0 if levels.get("kill_mid", false) else levels.get("eq_mid", 1.0),
		0.0 if levels.get("kill_high", false) else levels.get("eq_high", 1.0)))


## Uploads the deck's waveform once per track (and again if its analysis
## arrives later): 3 bytes per frame -> one RGB texel, rows of TEXTURE_WIDTH.
func _update_texture(deck: Dictionary) -> void:
	var frame_count: int = deck["waveform_frame_count"]
	var key := "%d:%d" % [deck.get("load_id", -1), frame_count]
	if key == _texture_key:
		return
	_texture_key = key
	var rows := int(ceil(frame_count / float(TEXTURE_WIDTH)))
	var bytes: PackedByteArray = deck["waveform_bytes"].duplicate()
	bytes.resize(TEXTURE_WIDTH * rows * 3)
	var image := Image.create_from_data(TEXTURE_WIDTH, rows, false, Image.FORMAT_RGB8, bytes)
	_material.set_shader_parameter("wave", ImageTexture.create_from_image(image))
