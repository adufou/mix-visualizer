class_name FfmpegLocator
extends RefCounted
## Finds an ffmpeg that can actually encode video. A bare `ffmpeg` isn't
## enough on Windows: other apps put their own (sometimes audio-only) copy on
## PATH, and winget's Gyan.FFmpeg install folder name changes with each version.


## Video encoders from RenderJob.ENCODERS that `path` supports; empty if the
## file can't run or has none (e.g. an audio-only build).
static func video_encoders(path: String) -> PackedStringArray:
	var found: PackedStringArray = []
	if path.is_empty() or (path.is_absolute_path() and not FileAccess.file_exists(path)):
		return found
	var output: Array = []
	if OS.execute(path, ["-hide_banner", "-encoders"], output, true) != 0 or output.is_empty():
		return found
	for encoder in RenderJob.ENCODERS:
		if (" %s " % encoder) in str(output[0]):
			found.append(encoder)
	return found


## The subset of video_encoders(path) that really works on this machine:
## ffmpeg lists GPU encoders it was built with even when the GPU, driver or
## generation (e.g. AV1 needs an RTX 40) isn't there. Each one encodes a few
## blank frames with the exact args a render would use. ~2 s total: call it
## from a worker thread.
static func working_encoders(path: String) -> PackedStringArray:
	var working: PackedStringArray = []
	for encoder in video_encoders(path):
		var args: PackedStringArray = ["-hide_banner", "-loglevel", "error",
				"-f", "lavfi", "-i", "color=black:s=640x360:r=60", "-frames:v", "3"]
		args.append_array(RenderJob.encoder_args(encoder, 20))
		args.append_array(["-f", "null", "-"])
		if OS.execute(path, args, [], true) == 0:
			working.append(encoder)
	return working


## First candidate with libx264, or "" if none.
static func find() -> String:
	for candidate in _candidates():
		if video_encoders(candidate).has("libx264"):
			return candidate
	return ""


## Every ffmpeg.exe on PATH (in PATH order), then winget's install folders.
static func _candidates() -> PackedStringArray:
	var candidates: PackedStringArray = []
	var output: Array = []
	if OS.execute("where.exe", ["ffmpeg"], output, true) == 0 and not output.is_empty():
		for line in str(output[0]).split("\n", false):
			candidates.append(line.strip_edges().replace("\\", "/"))

	var local_app_data := OS.get_environment("LOCALAPPDATA").replace("\\", "/")
	candidates.append(local_app_data + "/Microsoft/WinGet/Links/ffmpeg.exe")
	var packages_dir := local_app_data + "/Microsoft/WinGet/Packages"
	for package in DirAccess.get_directories_at(packages_dir):
		if not package.begins_with("Gyan.FFmpeg"):
			continue
		# Gyan.FFmpeg_<source>/ffmpeg-<version>-full_build/bin/ffmpeg.exe
		for build in DirAccess.get_directories_at(packages_dir.path_join(package)):
			candidates.append(packages_dir.path_join(package).path_join(build).path_join("bin/ffmpeg.exe"))
	return candidates
