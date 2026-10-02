class_name RenderJob
extends RefCounted
## Everything a render needs, as one plain Dictionary: input files, style,
## output settings. The editor keeps it in user://settings.json (so the last
## session comes back on launch) and hands a copy to the renderer process as
## a job file. Same shape both ways, so a job can also be run from the CLI.

const SETTINGS_PATH := "user://settings.json"

## Output heights offered in the editor; width follows 16:9.
const HEIGHTS := [1080, 1440, 2160]
## Preselected when available: fast on the GPU, smaller files than H.264.
const DEFAULT_ENCODER := "hevc_nvenc"

## ffmpeg encoder -> dropdown label. Order = dropdown order. Only the ones
## that actually work on this machine are offered (see FfmpegLocator).
const ENCODERS := {
	"libx264": "H.264 · CPU (x264)",
	"h264_nvenc": "H.264 · NVIDIA GPU",
	"hevc_nvenc": "HEVC · NVIDIA GPU",
	"av1_nvenc": "AV1 · NVIDIA GPU",
	"h264_qsv": "H.264 · Intel GPU",
	"hevc_qsv": "HEVC · Intel GPU",
	"av1_qsv": "AV1 · Intel GPU",
	"h264_amf": "H.264 · AMD GPU",
	"hevc_amf": "HEVC · AMD GPU",
	"av1_amf": "AV1 · AMD GPU",
	"libx265": "HEVC · CPU (x265, slow)",
}


static func defaults() -> Dictionary:
	return {
		"data_path": "",
		"audio_path": "",
		"style": {
			"background_path": "",
			"font": FontManager.current_font_name,
			"colors": {
				"low": BackgroundManager.current_colors["low"].to_html(false),
				"mid": BackgroundManager.current_colors["mid"].to_html(false),
				"high": BackgroundManager.current_colors["high"].to_html(false),
				"accent": BackgroundManager.current_colors["accent"].to_html(false),
			},
			"shaders_enabled": true,
			"effects": {},
		},
		"output": {
			"path": "",
			"height": 1080,
			"fps": 60,
			"encoder": DEFAULT_ENCODER,
			"quality": 16,
			"range_start": 0.0,
			## 0 = until the end of the audio.
			"range_end": 0.0,
			"ffmpeg": "",
		},
	}


## Saved settings merged over the defaults (so new keys get default values).
static func load_saved() -> Dictionary:
	var job := defaults()
	var file := FileAccess.open(SETTINGS_PATH, FileAccess.READ)
	if file != null:
		var saved = JSON.parse_string(file.get_as_text())
		if saved is Dictionary:
			_merge(job, saved)
	return job


static func save(job: Dictionary) -> void:
	write(job, SETTINGS_PATH)


static func read(path: String) -> Dictionary:
	var job := defaults()
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("RenderJob: cannot read '%s'" % path)
		return job
	var saved = JSON.parse_string(file.get_as_text())
	if saved is Dictionary:
		_merge(job, saved)
	return job


static func write(job: Dictionary, path: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("RenderJob: cannot write '%s'" % path)
		return
	file.store_string(JSON.stringify(job, "\t"))


## Pushes the job's style into the autoload managers and the overlay's shaders.
static func apply_style(style: Dictionary, overlay: Overlay) -> void:
	var background_path: String = style.get("background_path", "")
	if not background_path.is_empty() and background_path != BackgroundManager.current_path:
		BackgroundManager.set_background(background_path)
	var colors: Dictionary = style.get("colors", {})
	for band in colors.keys():
		BackgroundManager.set_color(band, Color.html(colors[band]))
	var font: String = style.get("font", "")
	if FontManager.FONTS.has(font):
		FontManager.set_font(font)
	var effects: Dictionary = style.get("effects", {})
	for effect in overlay.background.EFFECTS.keys():
		overlay.background.set_effect_enabled(effect, effects.get(effect, true))
	overlay.background.set_all_enabled(style.get("shaders_enabled", true))


## ffmpeg output-side video args for `encoder` at `quality` (0-51, lower =
## better; CRF for CPU encoders, the closest constant-quality mode for GPUs).
static func encoder_args(encoder: String, quality: int) -> PackedStringArray:
	var q := str(quality)
	var args: PackedStringArray = ["-c:v", encoder]
	match encoder:
		"libx264":
			args.append_array(["-preset", "slow", "-crf", q])
		"libx265":
			args.append_array(["-preset", "medium", "-crf", q])
		"h264_nvenc", "hevc_nvenc", "av1_nvenc":
			# Without an explicit maxrate, NVENC caps VBR at a low default
			# (~15-40 Mbit/s) whatever -cq says, and smears fine detail like grain.
			args.append_array(["-preset", "p7", "-tune", "hq", "-rc", "vbr", "-cq", q, "-b:v", "0",
					"-maxrate", "800M", "-bufsize", "1600M"])
		"h264_qsv", "hevc_qsv", "av1_qsv":
			args.append_array(["-preset", "veryslow", "-global_quality", q])
		"h264_amf", "hevc_amf", "av1_amf":
			args.append_array(["-quality", "quality", "-rc", "cqp", "-qp_i", q, "-qp_p", q])
	# Quick Sync wants NV12 input; NV12 and yuv420p are the same 4:2:0 picture.
	args.append_array(["-pix_fmt", "nv12" if encoder.ends_with("_qsv") else "yuv420p"])
	if encoder.begins_with("hevc") or encoder == "libx265":
		args.append_array(["-tag:v", "hvc1"]) # so Apple players/QuickTime accept HEVC in .mp4
	return args


static func output_size(job: Dictionary) -> Vector2i:
	var height := int(job["output"]["height"])
	return Vector2i(height * 16 / 9, height)


static func _merge(into: Dictionary, from: Dictionary) -> void:
	for key in from.keys():
		if into.get(key) is Dictionary and from[key] is Dictionary:
			_merge(into[key], from[key])
		else:
			into[key] = from[key]
