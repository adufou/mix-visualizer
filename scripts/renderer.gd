extends Control
## Offline renderer, run in its own Godot process (started by the editor's
## Generate button) with `--fixed-fps <fps>` so every frame advances `delta`
## and shader TIME by exactly 1/fps, however long it takes to draw.
## Each frame: t = range_start + frame_index / fps -> MixData.seek(t) -> the
## overlay draws into a SubViewport -> its pixels are piped into ffmpeg, which
## muxes them with the recorded audio straight into the output file.
##
##   godot --path <project> --fixed-fps 60 -- --render <job.json>

## Frames rendered (but not written) before range_start, so the overlay's
## delta-based smoothing and beat-pulse state settle as in normal playback.
const WARMUP_SECONDS := 0.5
## Overlay layout size; bigger outputs scale the canvas up (crisp, not stretched).
const DESIGN_SIZE := Vector2i(1920, 1080)
const STATUS_EVERY_FRAMES := 15

@onready var sub_viewport: SubViewport = %SubViewport
@onready var preview_rect: TextureRect = %PreviewRect
@onready var status_label: Label = %StatusLabel

var _job: Dictionary
var _overlay: Overlay
var _fps := 60
var _range_start := 0.0
var _warmup_frames := 0
var _total_frames := 0
## Frame being processed; frames < _warmup_frames are not written.
var _frame := 0
var _frame_pending := false
var _ffmpeg: Dictionary = {}
var _started_msec := 0
var _status_path := ""
var _cancel_path := ""
var _finished := false


func _ready() -> void:
	process_priority = -1000 # seek before any overlay node reads MixData
	var args := OS.get_cmdline_user_args()
	var job_path := args[args.find("--render") + 1]
	_job = RenderJob.read(job_path)
	_status_path = _job.get("render", {}).get("status_path", "")
	_cancel_path = _job.get("render", {}).get("cancel_path", "")
	var error := _prepare()
	if not error.is_empty():
		_fail(error)
		return
	_started_msec = Time.get_ticks_msec()
	RenderingServer.frame_post_draw.connect(_on_frame_post_draw)


func _prepare() -> String:
	_write_status("loading", "Loading data...")
	var output: Dictionary = _job["output"]
	_fps = int(output["fps"])
	var size := RenderJob.output_size(_job)
	sub_viewport.size = size
	sub_viewport.size_2d_override = DESIGN_SIZE
	sub_viewport.size_2d_override_stretch = true

	_overlay = preload("res://scenes/overlay.tscn").instantiate()
	sub_viewport.add_child(_overlay)
	preview_rect.texture = sub_viewport.get_texture()

	var recording := MixRecording.new()
	var error := recording.load_file(_job["data_path"])
	if not error.is_empty():
		return error
	MixData.set_recording(recording)
	RenderJob.apply_style(_job["style"], _overlay)

	var audio_path: String = _job["audio_path"]
	var audio_duration := WavInfo.duration(audio_path) if not audio_path.is_empty() else -1.0
	var end := audio_duration if audio_duration > 0.0 else recording.last_t
	if float(output["range_end"]) > 0.0:
		end = min(end, float(output["range_end"]))
	_range_start = clamp(float(output["range_start"]), 0.0, end)
	_total_frames = int(ceil((end - _range_start) * _fps))
	_warmup_frames = int(WARMUP_SECONDS * _fps)
	if _total_frames <= 0:
		return "Empty range: %.2fs to %.2fs" % [_range_start, end]

	var ffmpeg_args := _ffmpeg_args(size, audio_path if audio_duration > 0.0 else "", end - _range_start)
	_ffmpeg = OS.execute_with_pipe(output["ffmpeg"], ffmpeg_args, true)
	if _ffmpeg.is_empty():
		return "Could not start ffmpeg ('%s'). Check the ffmpeg path setting." % output["ffmpeg"]
	print("Renderer: ffmpeg %s" % " ".join(ffmpeg_args))
	return ""


func _ffmpeg_args(size: Vector2i, audio_path: String, duration: float) -> PackedStringArray:
	var output: Dictionary = _job["output"]
	var args := PackedStringArray([
		"-y", "-loglevel", "error", "-nostats",
		"-f", "rawvideo", "-pix_fmt", "rgba", "-s", "%dx%d" % [size.x, size.y],
		"-r", str(_fps), "-i", "-",
	])
	if not audio_path.is_empty():
		args.append_array(["-ss", "%.6f" % _range_start, "-t", "%.6f" % duration, "-i", audio_path,
				"-map", "0:v", "-map", "1:a", "-c:a", "aac", "-b:a", "320k", "-shortest"])
	var quality := str(int(output["quality"]))
	match str(output["encoder"]):
		"h264_nvenc", "hevc_nvenc":
			args.append_array(["-c:v", output["encoder"], "-preset", "p7", "-rc", "vbr", "-cq", quality, "-b:v", "0"])
		_:
			args.append_array(["-c:v", "libx264", "-preset", "slow", "-crf", quality])
	args.append_array(["-pix_fmt", "yuv420p", "-movflags", "+faststart", output["path"]])
	return args


func _process(delta: float) -> void:
	if _finished or _total_frames <= 0:
		return
	if _frame == 1 and abs(delta - 1.0 / _fps) > 1e-6:
		push_warning("Renderer: delta is %f, not 1/%d. Start with --fixed-fps %d for frame-exact smoothing." % [delta, _fps, _fps])
	MixData.seek(_range_start + float(_frame - _warmup_frames) / _fps)
	_frame_pending = true


func _on_frame_post_draw() -> void:
	if _finished or not _frame_pending:
		return
	_frame_pending = false
	var written := _frame - _warmup_frames
	if written >= 0:
		var image := sub_viewport.get_texture().get_image()
		if image.get_format() != Image.FORMAT_RGBA8:
			image.convert(Image.FORMAT_RGBA8)
		var stdio: FileAccess = _ffmpeg["stdio"]
		# Blocking pipe: when ffmpeg encodes slower than we draw, this waits.
		if not stdio.store_buffer(image.get_data()) or not OS.is_process_running(_ffmpeg["pid"]):
			_fail("ffmpeg stopped while writing frame %d: %s" % [written, _read_ffmpeg_errors()])
			return
		written += 1
		if written % STATUS_EVERY_FRAMES == 0:
			_write_status("rendering")
			if not _cancel_path.is_empty() and FileAccess.file_exists(_cancel_path):
				_finish("cancelled")
				return
		if written >= _total_frames:
			_finish("done")
			return
	_frame += 1


## Closes ffmpeg's input so it finalizes the file, waits for it, then quits.
func _finish(state: String) -> void:
	_finished = true
	_write_status("encoding", "Finalizing file...")
	_ffmpeg["stdio"].close()
	while OS.is_process_running(_ffmpeg["pid"]):
		OS.delay_msec(50)
	var exit_code := OS.get_process_exit_code(_ffmpeg["pid"])
	if exit_code != 0 and state == "done":
		_fail("ffmpeg exited with code %d: %s" % [exit_code, _read_ffmpeg_errors()])
		return
	_write_status(state, _job["output"]["path"])
	print("Renderer: %s, %d frames in %.1fs" % [state, _frame - _warmup_frames + 1, (Time.get_ticks_msec() - _started_msec) / 1000.0])
	get_tree().quit(0)


func _fail(message: String) -> void:
	_finished = true
	printerr("Renderer: " + message)
	_write_status("error", message)
	if not _ffmpeg.is_empty():
		_ffmpeg["stdio"].close()
	get_tree().quit(1)


func _read_ffmpeg_errors() -> String:
	if _ffmpeg.is_empty():
		return ""
	var stderr: FileAccess = _ffmpeg["stderr"]
	return stderr.get_as_text().strip_edges()


## Status file polled by the editor: { state, frame, total, fps, message }.
func _write_status(state: String, message := "") -> void:
	var written: int = max(0, _frame - _warmup_frames + 1)
	var elapsed: float = max(0.001, (Time.get_ticks_msec() - _started_msec) / 1000.0)
	var render_fps := written / elapsed if _started_msec > 0 else 0.0
	status_label.text = "%s  %d / %d  (%.1f fps)  %s" % [state, written, _total_frames, render_fps, message]
	if _status_path.is_empty():
		return
	var file := FileAccess.open(_status_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({
			"state": state, "frame": written, "total": _total_frames,
			"fps": render_fps, "message": message,
		}))
