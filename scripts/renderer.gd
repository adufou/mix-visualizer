extends Control
## Offline renderer, run in its own Godot process (started by the editor's
## Generate button) with `--fixed-fps <fps>` so every frame advances `delta`
## and shader TIME by exactly 1/fps, however long it takes to draw.
## Each frame: t = range_start + (frame_index - audio_offset_frames) / fps -> MixData.seek(t) -> the
## overlay draws into a SubViewport -> its pixels are piped into ffmpeg, which
## muxes them with the recorded audio straight into the output file.
##
##   godot --path <project> --fixed-fps 60 --disable-vsync -- --render <job.json>
##
## Extra user args: --profile (print per-stage timings), --sync-readback
## (old blocking get_image path). Output path "<x>.framemd5" writes per-frame
## checksums instead of a video, "<x>.lossless.mkv" writes exact pixels (FFV1)
## for before/after comparisons, "null" discards frames (speed tests).

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
## Audio delay in frames (see RenderJob): frame i shows the data of frame i - this.
var _audio_offset_frames := 0
var _warmup_frames := 0
var _total_frames := 0
## Frame being processed; frames < _warmup_frames are not written.
var _frame := 0
var _frame_pending := false
## Output frames whose pixels were requested from the GPU / written to ffmpeg.
var _requested := 0
var _written := 0
## Frames read back but not written yet (written strictly in index order).
var _readback_done: Dictionary = {}
## Async readback: the GPU copies each frame out while the next ones are
## drawn, instead of the CPU waiting on every frame (get_image). Null when the
## renderer has no RenderingDevice (Compatibility) or with --sync-readback.
var _rd: RenderingDevice
var _ffmpeg: Dictionary = {}
var _started_msec := 0
var _status_path := ""
var _cancel_path := ""
var _finished := false

## --profile: microseconds spent per stage, summed over written frames.
var _profile := false
var _profile_us := {"frame": 0, "readback": 0, "store_buffer": 0}
var _profile_last_us := 0


func _ready() -> void:
	process_priority = -1000 # seek before any overlay node reads MixData
	var args := OS.get_cmdline_user_args()
	var job_path := args[args.find("--render") + 1]
	_job = RenderJob.read(job_path)
	_profile = args.has("--profile")
	if not args.has("--sync-readback"):
		_rd = RenderingServer.get_rendering_device()
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
	_audio_offset_frames = int(output["audio_offset_frames"])
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
	# Epsilon: 30.05 - 30.0 is 0.0500000000000007, which would round up one frame too many.
	_total_frames = int(ceil((end - _range_start) * _fps - 1e-6))
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
	var video_input := PackedStringArray([
		"-y", "-loglevel", "error", "-nostats",
		"-f", "rawvideo", "-pix_fmt", "rgba", "-s", "%dx%d" % [size.x, size.y],
		"-r", str(_fps), "-i", "-",
	])
	var out_path := str(output["path"])
	# Test outputs: per-frame checksums of the exact pixels sent (regression
	# check for frame order/timing), or a discard sink (speed measurements).
	if out_path.ends_with(".framemd5"):
		return video_input + PackedStringArray(["-f", "framemd5", out_path])
	if out_path == "null":
		return video_input + PackedStringArray(["-f", "null", "-"])
	if out_path.ends_with(".lossless.mkv"):
		return video_input + PackedStringArray(["-c:v", "ffv1", out_path])

	var args := video_input.duplicate()
	if not audio_path.is_empty():
		args.append_array(["-ss", "%.6f" % _range_start, "-t", "%.6f" % duration, "-i", audio_path,
				"-map", "0:v", "-map", "1:a", "-c:a", "aac", "-b:a", "320k", "-shortest"])
	args.append_array(RenderJob.encoder_args(str(output["encoder"]), int(output["quality"])))
	args.append_array(["-movflags", "+faststart", out_path])
	return args


func _process(delta: float) -> void:
	# Once every frame is requested, only wait for the last readbacks.
	if _finished or _total_frames <= 0 or _requested >= _total_frames:
		return
	if _frame == 1 and abs(delta - 1.0 / _fps) > 1e-6:
		push_warning("Renderer: delta is %f, not 1/%d. Start with --fixed-fps %d for frame-exact smoothing." % [delta, _fps, _fps])
	MixData.seek(_range_start + float(_frame - _warmup_frames - _audio_offset_frames) / _fps)
	_frame_pending = true


func _on_frame_post_draw() -> void:
	if _finished or not _frame_pending:
		return
	_frame_pending = false
	var index := _frame - _warmup_frames
	_frame += 1
	if index < 0:
		return
	_requested = index + 1
	var t0 := Time.get_ticks_usec()
	if _rd != null:
		var texture := RenderingServer.texture_get_rd_texture(sub_viewport.get_texture().get_rid())
		var error := _rd.texture_get_data_async(texture, 0, _on_frame_read.bind(index))
		if error != OK:
			_fail("GPU readback failed for frame %d: %s" % [index, error_string(error)])
			return
		_profile_us["readback"] += Time.get_ticks_usec() - t0
	else:
		var image := sub_viewport.get_texture().get_image()
		if image.get_format() != Image.FORMAT_RGBA8:
			image.convert(Image.FORMAT_RGBA8)
		_profile_us["readback"] += Time.get_ticks_usec() - t0
		_on_frame_read(image.get_data(), index)


## Readbacks can complete a frame or two after their request. Writes go out
## strictly in frame order, whatever order the data arrives in.
func _on_frame_read(data: PackedByteArray, index: int) -> void:
	if _finished:
		return
	_readback_done[index] = data
	while _readback_done.has(_written):
		var frame_data: PackedByteArray = _readback_done[_written]
		_readback_done.erase(_written)
		var size := sub_viewport.size
		if frame_data.size() != size.x * size.y * 4:
			_fail("Frame %d has %d bytes, expected %d (RGBA8 %dx%d)" % [_written, frame_data.size(), size.x * size.y * 4, size.x, size.y])
			return
		var t0 := Time.get_ticks_usec()
		# Blocking pipe: when ffmpeg encodes slower than we draw, this waits.
		var stored: bool = _ffmpeg["stdio"].store_buffer(frame_data)
		var t1 := Time.get_ticks_usec()
		_profile_us["store_buffer"] += t1 - t0
		if _profile_last_us > 0:
			_profile_us["frame"] += t1 - _profile_last_us
		_profile_last_us = t1
		if not stored or not OS.is_process_running(_ffmpeg["pid"]):
			_fail("ffmpeg stopped while writing frame %d: %s" % [_written, _read_ffmpeg_errors()])
			return
		_written += 1
		if _written % STATUS_EVERY_FRAMES == 0:
			_write_status("rendering")
			if not _cancel_path.is_empty() and FileAccess.file_exists(_cancel_path):
				_finish("cancelled")
				return
		if _written >= _total_frames:
			_finish("done")
			return


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
	if _profile:
		var frames: int = max(1, _written)
		var parts: PackedStringArray = []
		for stage in _profile_us.keys():
			parts.append("%s %.2f ms" % [stage, _profile_us[stage] / 1000.0 / frames])
		print("Renderer profile (avg per frame): " + ", ".join(parts))
	print("Renderer: %s, %d frames in %.1fs (%s readback)" % [state, _written, (Time.get_ticks_msec() - _started_msec) / 1000.0, "sync" if _rd == null else "async"])
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
	var written := _written
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
