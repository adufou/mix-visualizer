class_name RenderJob
extends RefCounted
## Everything a render needs, as one plain Dictionary: input files, style,
## output settings. The editor keeps it in user://settings.json (so the last
## session comes back on launch) and hands a copy to the renderer process as
## a job file. Same shape both ways, so a job can also be run from the CLI.

const SETTINGS_PATH := "user://settings.json"

## Output heights offered in the editor; width follows 16:9.
const HEIGHTS := [1080, 1440, 2160]
const ENCODERS := ["libx264", "h264_nvenc", "hevc_nvenc"]


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
			"encoder": "libx264",
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


static func output_size(job: Dictionary) -> Vector2i:
	var height := int(job["output"]["height"])
	return Vector2i(height * 16 / 9, height)


static func _merge(into: Dictionary, from: Dictionary) -> void:
	for key in from.keys():
		if into.get(key) is Dictionary and from[key] is Dictionary:
			_merge(into[key], from[key])
		else:
			into[key] = from[key]
