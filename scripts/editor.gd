extends Control
## The app's main screen: pick a recording (.jsonl + .wav), preview it with
## audio and a scrub timeline, tune the style, then Generate a video.
## Generate starts a second Godot process (renderer.tscn) with --fixed-fps and
## follows its progress through a small status file.
## All choices persist in user://settings.json (see RenderJob).

const OverlayScene := preload("res://scenes/overlay.tscn")
const FPS_CHOICES := [60, 30]
const STATUS_POLL_SECONDS := 0.25
## Seconds jumped by the Left/Right arrow keys.
const SKIP_SECONDS := 5.0

@onready var preview_viewport: SubViewport = %PreviewViewport
@onready var preview_rect: TextureRect = %PreviewRect
@onready var play_button: Button = %PlayButton
@onready var time_label: Label = %TimeLabel
@onready var timeline: HSlider = %Timeline
@onready var track_strip: Control = %TrackStrip
@onready var data_path_edit: LineEdit = %DataPath
@onready var audio_path_edit: LineEdit = %AudioPath
@onready var session_info: Label = %SessionInfo
@onready var background_path_edit: LineEdit = %BackgroundPath
@onready var font_option_button: OptionButton = %FontOptionButton
@onready var decks_option_button: OptionButton = %DecksOptionButton
@onready var low_color_picker: ColorPickerButton = %LowColorPicker
@onready var mid_color_picker: ColorPickerButton = %MidColorPicker
@onready var high_color_picker: ColorPickerButton = %HighColorPicker
@onready var accent_color_picker: ColorPickerButton = %AccentColorPicker
@onready var shader_toggles: VBoxContainer = %ShaderToggles
@onready var output_path_edit: LineEdit = %OutputPath
@onready var resolution_option: OptionButton = %ResolutionOption
@onready var fps_option: OptionButton = %FpsOption
@onready var encoder_option: OptionButton = %EncoderOption
@onready var quality_spin: SpinBox = %QualitySpin
@onready var range_start_spin: SpinBox = %RangeStartSpin
@onready var range_end_spin: SpinBox = %RangeEndSpin
@onready var audio_offset_spin: SpinBox = %AudioOffsetSpin
@onready var audio_offset_frames: Label = %AudioOffsetFrames
@onready var ffmpeg_path_edit: LineEdit = %FfmpegPath
@onready var ffmpeg_status: Label = %FfmpegStatus
@onready var generate_button: Button = %GenerateButton
@onready var cancel_button: Button = %CancelButton
@onready var render_progress: ProgressBar = %RenderProgress
@onready var render_status: Label = %RenderStatus

var _job: Dictionary
var _overlay: Overlay
var _player := AudioStreamPlayer.new()

var _time := 0.0
var _duration := 0.0
var _playing := false

var _load_thread: Thread
var _loading_recording: MixRecording
var _loading_audio: AudioStreamWAV

## Encoders that passed a test encode with the current ffmpeg.
var _ffmpeg_encoders: PackedStringArray = []
var _encoder_thread: Thread

var _render_pid := -1
var _render_status_path := ""
var _render_cancel_path := ""
var _status_poll_timer := 0.0


func _ready() -> void:
	process_priority = -1000 # seek MixData before the overlay's nodes read it
	add_child(_player)
	_job = RenderJob.load_saved()
	# Each session starts empty: style and output settings carry over, inputs don't.
	_job["data_path"] = ""
	_job["audio_path"] = ""

	_overlay = OverlayScene.instantiate()
	preview_viewport.add_child(_overlay)
	preview_rect.texture = preview_viewport.get_texture()
	RenderJob.apply_style(_job["style"], _overlay)

	_init_session_controls()
	_init_style_controls()
	_init_output_controls()


func _exit_tree() -> void:
	if _load_thread != null:
		_load_thread.wait_to_finish()
	if _encoder_thread != null:
		_encoder_thread.wait_to_finish()


# --- Session -----------------------------------------------------------------

func _init_session_controls() -> void:
	data_path_edit.text = _job["data_path"]
	audio_path_edit.text = _job["audio_path"]
	%DataButton.pressed.connect(%DataDialog.popup_centered)
	%AudioButton.pressed.connect(%AudioDialog.popup_centered)
	%DataDialog.file_selected.connect(_on_data_file_selected)
	%AudioDialog.file_selected.connect(func(path): _start_loading(_job["data_path"], path))
	play_button.pressed.connect(_toggle_play)
	timeline.value_changed.connect(_seek)
	track_strip.seek_requested.connect(_seek)


## Picking a .jsonl also picks its audio: the header names the WAV that sits
## next to it.
func _on_data_file_selected(path: String) -> void:
	var audio_path := ""
	var file := FileAccess.open(path, FileAccess.READ)
	if file != null:
		var header = JSON.parse_string(file.get_line())
		if header is Dictionary and header.get("type") == "header":
			var candidate := path.get_base_dir().path_join(str(header.get("audio_file", "")))
			if FileAccess.file_exists(candidate):
				audio_path = candidate
	_job["output"]["path"] = path.get_basename() + ".mp4"
	output_path_edit.text = _job["output"]["path"]
	_job["output"]["range_start"] = 0.0
	_job["output"]["range_end"] = 0.0
	_start_loading(path, audio_path)


func _start_loading(data_path: String, audio_path: String) -> void:
	if _load_thread != null:
		return
	_set_playing(false)
	_job["data_path"] = data_path
	_job["audio_path"] = audio_path
	data_path_edit.text = data_path
	audio_path_edit.text = audio_path
	_save()
	%DataButton.disabled = true
	%AudioButton.disabled = true
	_loading_recording = MixRecording.new()
	_loading_audio = null
	_load_thread = Thread.new()
	_load_thread.start(_load_in_thread.bind(_loading_recording, data_path, audio_path))


## Worker thread: parse the data file, then decode the WAV for preview playback.
func _load_in_thread(recording: MixRecording, data_path: String, audio_path: String) -> String:
	var error := recording.load_file(data_path)
	if error.is_empty() and not audio_path.is_empty():
		_loading_audio = AudioStreamWAV.load_from_file(audio_path)
	return error


func _poll_loading() -> void:
	if _load_thread == null:
		return
	if _load_thread.is_alive():
		session_info.text = "Loading... %d%%" % int(_loading_recording.progress * 100.0)
		return
	var error: String = _load_thread.wait_to_finish()
	_load_thread = null
	%DataButton.disabled = false
	%AudioButton.disabled = false
	if not error.is_empty():
		session_info.text = error
		return

	var recording := _loading_recording
	MixData.set_recording(recording)
	_player.stream = _loading_audio
	_duration = _loading_audio.get_length() if _loading_audio != null else recording.last_t
	timeline.max_value = _duration
	range_start_spin.max_value = _duration
	range_end_spin.max_value = _duration
	_apply_range_to_controls()
	track_strip.set_recording(recording, _duration)
	_seek(0.0)

	var titles := {}
	for event in recording.track_events:
		titles[event["load_id"]] = true
	session_info.text = "%s · %d track loads · decks %s%s" % [
		_format_time(_duration), titles.size(), ", ".join(recording.used_decks()),
		"" if _loading_audio != null else "\nNo audio: preview is silent and the video will have no sound."]


# --- Playback ----------------------------------------------------------------

func _process(delta: float) -> void:
	_poll_loading()
	_poll_encoder_probe()
	_poll_render(delta)
	if not MixData.has_recording():
		return
	if _playing:
		if _player.stream != null:
			# Playback position only moves once per mix chunk; this smooths it.
			var t := _player.get_playback_position() + AudioServer.get_time_since_last_mix() - AudioServer.get_output_latency()
			_time = max(_time, t)
			if not _player.playing:
				_set_playing(false)
		else:
			_time += delta # silent preview only; renders never use delta for time
		if _time >= _duration:
			_time = _duration
			_set_playing(false)
	MixData.seek(_time - _audio_offset_seconds())
	timeline.set_value_no_signal(_time)
	time_label.text = "%s / %s" % [_format_time(_time, true), _format_time(_duration)]


func _toggle_play() -> void:
	_set_playing(not _playing)


func _set_playing(playing: bool) -> void:
	if playing and not MixData.has_recording():
		return
	if playing and _time >= _duration:
		_time = 0.0
	_playing = playing
	play_button.text = "Pause" if playing else "Play"
	if _player.stream == null:
		return
	if playing:
		_player.play(_time)
	else:
		_player.stop()


func _seek(t: float) -> void:
	_time = clamp(t, 0.0, _duration)
	if _playing and _player.stream != null:
		_player.play(_time)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed):
		return
	match event.keycode:
		KEY_SPACE:
			_toggle_play()
		KEY_LEFT:
			_seek(_time - SKIP_SECONDS)
		KEY_RIGHT:
			_seek(_time + SKIP_SECONDS)
		KEY_F11:
			var fullscreen := DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED if fullscreen else DisplayServer.WINDOW_MODE_FULLSCREEN)
		_:
			return
	get_viewport().set_input_as_handled()


# --- Style -------------------------------------------------------------------

func _init_style_controls() -> void:
	var style: Dictionary = _job["style"]
	background_path_edit.text = style["background_path"]
	%BackgroundButton.pressed.connect(%BackgroundDialog.popup_centered)
	%BackgroundDialog.file_selected.connect(_on_background_selected)

	for font_name in FontManager.FONTS.keys():
		font_option_button.add_item(font_name)
	font_option_button.select(FontManager.FONTS.keys().find(FontManager.current_font_name))
	font_option_button.item_selected.connect(func(index):
		FontManager.set_font(font_option_button.get_item_text(index))
		style["font"] = FontManager.current_font_name
		_save())

	var pairs := Overlay.DECK_PAIRS.keys()
	for pair in pairs:
		decks_option_button.add_item(pair)
	decks_option_button.select(max(pairs.find(_overlay.deck_pair), 0))
	decks_option_button.item_selected.connect(func(index):
		_overlay.set_deck_pair(decks_option_button.get_item_text(index))
		style["decks"] = _overlay.deck_pair
		_save())

	var pickers := {"low": low_color_picker, "mid": mid_color_picker, "high": high_color_picker, "accent": accent_color_picker}
	for band in pickers.keys():
		var picker: ColorPickerButton = pickers[band]
		picker.color = BackgroundManager.current_colors[band]
		picker.color_changed.connect(func(color):
			BackgroundManager.set_color(band, color)
			style["colors"][band] = color.to_html(false))
		picker.popup_closed.connect(_save)

	_build_waveform_height_row()
	_build_shader_toggles()


func _on_background_selected(path: String) -> void:
	if BackgroundManager.set_background(path):
		_job["style"]["background_path"] = path
		background_path_edit.text = path
		_save()


## Waveform height slider with a reset button, right above the shader settings.
func _build_waveform_height_row() -> void:
	var style: Dictionary = _job["style"]
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = "Wave height"
	label.custom_minimum_size.x = 80
	row.add_child(label)
	var slider := _add_slider(row, 0.25, 2.5, 0.05, _overlay.waveform_height, func(value):
		_overlay.set_waveform_height(value)
		style["waveform_height"] = value
		_save())
	var reset := _make_reset_button()
	reset.pressed.connect(func(): slider.value = Overlay.DEFAULT_WAVEFORM_HEIGHT)
	row.add_child(reset)
	shader_toggles.get_parent().add_child(row)
	shader_toggles.get_parent().move_child(row, shader_toggles.get_index())


## One master "All shaders" switch plus one per effect in background_fx.gd's
## EFFECTS, each followed by sliders for its EFFECT_PARAMS. Per-effect
## controls grey out while the master is off.
func _build_shader_toggles() -> void:
	var background := _overlay.background
	var style: Dictionary = _job["style"]
	var all_toggle := CheckButton.new()
	all_toggle.text = "All shaders"
	all_toggle.button_pressed = background.is_all_enabled()
	shader_toggles.add_child(all_toggle)

	var effect_toggles: Array[CheckButton] = []
	var param_rows: Array[Control] = []
	for effect in background.EFFECTS.keys():
		var toggle := CheckButton.new()
		toggle.text = effect
		toggle.button_pressed = background.is_effect_enabled(effect)
		toggle.disabled = not all_toggle.button_pressed
		toggle.toggled.connect(func(on):
			background.set_effect_enabled(effect, on)
			style["effects"][effect] = on
			_save())
		shader_toggles.add_child(toggle)
		effect_toggles.append(toggle)
		for param in background.EFFECT_PARAMS.get(effect, []):
			var row := _build_param_row(param)
			shader_toggles.add_child(row)
			param_rows.append(row)

	var set_rows_enabled := func(on: bool):
		for row in param_rows:
			row.modulate.a = 1.0 if on else 0.4
			row.propagate_call("set_editable", [on])
			row.propagate_call("set_disabled", [not on])
	var reset_all := Button.new()
	reset_all.text = "Reset shader settings"
	reset_all.tooltip_text = "Put every shader slider back to its default"
	reset_all.pressed.connect(func():
		for row in param_rows:
			# Last child of each row is its own reset button.
			(row.get_child(-1) as Button).pressed.emit())
	reset_all.disabled = not all_toggle.button_pressed
	shader_toggles.add_child(reset_all)
	set_rows_enabled.call(all_toggle.button_pressed)

	all_toggle.toggled.connect(func(on):
		background.set_all_enabled(on)
		style["shaders_enabled"] = on
		for toggle in effect_toggles:
			toggle.disabled = not on
		set_rows_enabled.call(on)
		reset_all.disabled = not on
		_save())


## Label, control and reset button for one shader uniform: a slider for
## floats (range from the uniform's hint_range), a picker for colors.
func _build_param_row(param: String) -> Control:
	var background := _overlay.background
	var params: Dictionary = _job["style"]["shader_params"]
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = "    " + param.capitalize()
	label.custom_minimum_size.x = 120
	row.add_child(label)

	var reset := _make_reset_button()
	var default = background.get_param_default(param)
	if default is Color:
		var picker := ColorPickerButton.new()
		picker.color = background.get_param(param)
		picker.edit_alpha = false
		picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		picker.custom_minimum_size.y = 24
		picker.color_changed.connect(func(color):
			background.set_param(param, color)
			params[param] = color.to_html(false))
		picker.popup_closed.connect(_save)
		row.add_child(picker)
		reset.pressed.connect(func():
			picker.color = default
			background.set_param(param, default)
			params.erase(param)
			_save())
	else:
		var hint := String(background.get_param_info(param).get("hint_string", "0,1,0.01")).split(",")
		var step := float(hint[2]) if hint.size() > 2 else 0.01
		var slider := _add_slider(row, float(hint[0]), float(hint[1]), step, float(background.get_param(param)), func(value):
			background.set_param(param, value)
			params[param] = value
			_save())
		reset.pressed.connect(func():
			slider.value = float(default)
			params.erase(param)
			_save())
	row.add_child(reset)
	return row


## Adds a slider and a spin box mirroring it to `row`; on_change gets every
## new value. Returns the slider (set its value to drive both).
func _add_slider(row: HBoxContainer, min_value: float, max_value: float, step: float, value: float, on_change: Callable) -> HSlider:
	var spin := SpinBox.new()
	spin.min_value = min_value
	spin.max_value = max_value
	spin.step = step
	spin.custom_arrow_step = step
	var slider := HSlider.new()
	slider.min_value = min_value
	slider.max_value = max_value
	slider.step = step
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.value = value
	spin.value = value
	slider.value_changed.connect(func(new_value):
		spin.set_value_no_signal(new_value)
		on_change.call(new_value))
	spin.value_changed.connect(func(new_value): slider.value = new_value)
	row.add_child(slider)
	row.add_child(spin)
	return slider


func _make_reset_button() -> Button:
	var reset := Button.new()
	reset.text = "↺"
	reset.tooltip_text = "Reset to default"
	reset.flat = true
	return reset


# --- Output & Generate -------------------------------------------------------

func _init_output_controls() -> void:
	var output: Dictionary = _job["output"]
	output_path_edit.text = output["path"]
	output_path_edit.text_changed.connect(func(text):
		output["path"] = text
		_save())
	%OutputButton.pressed.connect(%OutputDialog.popup_centered)
	%OutputDialog.file_selected.connect(func(path):
		output["path"] = path
		output_path_edit.text = path
		_save())

	for height in RenderJob.HEIGHTS:
		resolution_option.add_item("%dp" % height)
	resolution_option.select(max(0, RenderJob.HEIGHTS.find(int(output["height"]))))
	resolution_option.item_selected.connect(func(index):
		output["height"] = RenderJob.HEIGHTS[index]
		_save())

	for fps in FPS_CHOICES:
		fps_option.add_item("%d fps" % fps)
	fps_option.select(max(0, FPS_CHOICES.find(int(output["fps"]))))
	fps_option.item_selected.connect(func(index):
		output["fps"] = FPS_CHOICES[index]
		_update_audio_offset_label()
		_save())

	# Filled once the background probe knows which encoders work here.
	encoder_option.item_selected.connect(func(index):
		output["encoder"] = encoder_option.get_item_metadata(index)
		_save())

	quality_spin.value = float(output["quality"])
	quality_spin.value_changed.connect(func(value):
		output["quality"] = int(value)
		_save())

	range_start_spin.value_changed.connect(func(value):
		output["range_start"] = value
		_save())
	range_end_spin.value_changed.connect(func(value):
		output["range_end"] = value
		_save())
	%SetInButton.pressed.connect(func(): range_start_spin.value = snapped(_time, 0.01))
	%SetOutButton.pressed.connect(func(): range_end_spin.value = snapped(_time, 0.01))
	%FullRangeButton.pressed.connect(func():
		range_start_spin.value = 0.0
		range_end_spin.value = 0.0)

	audio_offset_spin.value = float(output["audio_offset_ms"])
	audio_offset_spin.value_changed.connect(func(value):
		output["audio_offset_ms"] = int(value)
		_update_audio_offset_label()
		_save())
	_update_audio_offset_label()

	ffmpeg_path_edit.text = output["ffmpeg"]
	ffmpeg_path_edit.text_submitted.connect(_on_ffmpeg_path_changed)
	ffmpeg_path_edit.focus_exited.connect(func(): _on_ffmpeg_path_changed(ffmpeg_path_edit.text))
	%FfmpegButton.pressed.connect(%FfmpegDialog.popup_centered)
	%FfmpegDialog.file_selected.connect(func(path):
		ffmpeg_path_edit.text = path
		_on_ffmpeg_path_changed(path))
	_probe_ffmpeg()

	generate_button.pressed.connect(_on_generate_pressed)
	cancel_button.pressed.connect(_on_cancel_pressed)


## The audio is the clock (playback, timeline, range); the offset moves the
## data under it, like the renderer does.
func _audio_offset_seconds() -> float:
	return float(_job["output"]["audio_offset_ms"]) / 1000.0


func _update_audio_offset_label() -> void:
	var frames := _audio_offset_seconds() * float(_job["output"]["fps"])
	audio_offset_frames.text = "%+.1f fr" % frames


func _apply_range_to_controls() -> void:
	range_start_spin.set_value_no_signal(float(_job["output"]["range_start"]))
	range_end_spin.set_value_no_signal(float(_job["output"]["range_end"]))


func _on_ffmpeg_path_changed(path: String) -> void:
	if path == _job["output"]["ffmpeg"] and not _ffmpeg_encoders.is_empty():
		return
	_job["output"]["ffmpeg"] = path
	_save()
	_probe_ffmpeg()


## Finds a usable ffmpeg and test-encodes with each known encoder, in a
## worker thread (~2 s). If the saved ffmpeg can't encode H.264 (empty field,
## file gone after an update, audio-only build), it looks for one that can and
## keeps it in the settings.
func _probe_ffmpeg() -> void:
	if _encoder_thread != null:
		return
	_ffmpeg_encoders = []
	encoder_option.disabled = true
	ffmpeg_status.text = "Detecting encoders..."
	_encoder_thread = Thread.new()
	_encoder_thread.start(_probe_in_thread.bind(str(_job["output"]["ffmpeg"])))


func _probe_in_thread(path: String) -> Dictionary:
	if not FfmpegLocator.video_encoders(path).has("libx264"):
		var found := FfmpegLocator.find()
		if not found.is_empty():
			path = found
	return {"path": path, "encoders": FfmpegLocator.working_encoders(path)}


func _poll_encoder_probe() -> void:
	if _encoder_thread == null or _encoder_thread.is_alive():
		return
	var result: Dictionary = _encoder_thread.wait_to_finish()
	_encoder_thread = null
	var output: Dictionary = _job["output"]
	if result["path"] != output["ffmpeg"]:
		output["ffmpeg"] = result["path"]
		ffmpeg_path_edit.text = result["path"]
		_save()
	_ffmpeg_encoders = result["encoders"]

	encoder_option.clear()
	for encoder in RenderJob.ENCODERS.keys():
		if _ffmpeg_encoders.has(encoder):
			encoder_option.add_item(RenderJob.ENCODERS[encoder])
			encoder_option.set_item_metadata(encoder_option.item_count - 1, encoder)
	encoder_option.disabled = _ffmpeg_encoders.is_empty()
	if not _ffmpeg_encoders.is_empty() and not _ffmpeg_encoders.has(str(output["encoder"])):
		output["encoder"] = RenderJob.DEFAULT_ENCODER if _ffmpeg_encoders.has(RenderJob.DEFAULT_ENCODER) else _ffmpeg_encoders[0]
		_save()
	for i in encoder_option.item_count:
		if encoder_option.get_item_metadata(i) == output["encoder"]:
			encoder_option.select(i)

	if _ffmpeg_encoders.is_empty():
		ffmpeg_status.text = "No ffmpeg that can encode video was found. Install one (winget install Gyan.FFmpeg) or point to ffmpeg.exe."
	else:
		ffmpeg_status.text = "ffmpeg OK · %d encoders work on this PC" % _ffmpeg_encoders.size()


func _validate_job() -> String:
	var output: Dictionary = _job["output"]
	if not MixData.has_recording():
		return "Load a recording first."
	if str(output["path"]).is_empty():
		return "Choose an output file."
	if not DirAccess.dir_exists_absolute(str(output["path"]).get_base_dir()):
		return "Output folder doesn't exist."
	if _encoder_thread != null:
		return "Still detecting encoders, try again in a second."
	if not _ffmpeg_encoders.has(str(output["encoder"])):
		return ffmpeg_status.text
	var end := float(output["range_end"]) if float(output["range_end"]) > 0.0 else _duration
	if end <= float(output["range_start"]):
		return "Range end must be after range start."
	return ""


func _on_generate_pressed() -> void:
	var error := _validate_job()
	if not error.is_empty():
		render_status.text = error
		return
	_set_playing(false)

	_render_status_path = ProjectSettings.globalize_path("user://render_status.json")
	_render_cancel_path = ProjectSettings.globalize_path("user://render_cancel")
	DirAccess.remove_absolute(_render_status_path)
	DirAccess.remove_absolute(_render_cancel_path)
	var job := _job.duplicate(true)
	job["render"] = {"status_path": _render_status_path, "cancel_path": _render_cancel_path}
	var job_path := ProjectSettings.globalize_path("user://render_job.json")
	RenderJob.write(job, job_path)

	var args := PackedStringArray()
	if OS.has_feature("editor"):
		args.append_array(["--path", ProjectSettings.globalize_path("res://")])
	# No vsync: frames are offline, so the screen refresh mustn't cap the render.
	args.append_array(["--fixed-fps", str(int(job["output"]["fps"])), "--disable-vsync", "--resolution", "960x540",
			"--", "--render", job_path])
	_render_pid = OS.create_process(OS.get_executable_path(), args)
	if _render_pid <= 0:
		render_status.text = "Could not start the renderer process."
		_render_pid = -1
		return
	generate_button.disabled = true
	cancel_button.disabled = false
	render_progress.value = 0.0
	render_status.text = "Starting renderer... Keep its window visible (not minimized)."


func _on_cancel_pressed() -> void:
	if _render_pid == -1:
		return
	var file := FileAccess.open(_render_cancel_path, FileAccess.WRITE)
	if file != null:
		file.store_string("cancel")
	render_status.text = "Cancelling..."


func _poll_render(delta: float) -> void:
	if _render_pid == -1:
		return
	_status_poll_timer -= delta
	if _status_poll_timer > 0.0:
		return
	_status_poll_timer = STATUS_POLL_SECONDS

	var running := OS.is_process_running(_render_pid)
	var status := _read_render_status()
	var state: String = status.get("state", "starting")
	var frame: int = status.get("frame", 0)
	var total: int = status.get("total", 0)
	var fps: float = status.get("fps", 0.0)
	if total > 0:
		render_progress.value = float(frame) / total
	match state:
		"rendering":
			var eta := (total - frame) / fps if fps > 0.0 else 0.0
			render_status.text = "Rendering %d / %d  ·  %.1f fps  ·  ETA %s" % [frame, total, fps, _format_time(eta)]
		"loading", "encoding":
			render_status.text = str(status.get("message", state))
		"done":
			render_status.text = "Done: %s" % status.get("message", "")
		"cancelled":
			render_status.text = "Cancelled. Partial file: %s" % status.get("message", "")
		"error":
			render_status.text = "Error: %s" % status.get("message", "")

	if not running:
		if state not in ["done", "cancelled", "error"]:
			render_status.text = "Renderer exited unexpectedly (state: %s)." % state
		_render_pid = -1
		generate_button.disabled = false
		cancel_button.disabled = true


func _read_render_status() -> Dictionary:
	var file := FileAccess.open(_render_status_path, FileAccess.READ)
	if file == null:
		return {}
	var status = JSON.parse_string(file.get_as_text())
	return status if status is Dictionary else {}


# --- Helpers -----------------------------------------------------------------

func _save() -> void:
	RenderJob.save(_job)


static func _format_time(seconds: float, with_hundredths := false) -> String:
	seconds = max(0.0, seconds)
	var minutes := int(seconds / 60.0)
	var hours := minutes / 60
	var text := ""
	if hours > 0:
		text = "%d:%02d:%02d" % [hours, minutes % 60, int(seconds) % 60]
	else:
		text = "%02d:%02d" % [minutes, int(seconds) % 60]
	if with_hundredths:
		text += ".%02d" % (int(seconds * 100.0) % 100)
	return text
