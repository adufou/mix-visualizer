class_name WavInfo
extends RefCounted
## Reads a WAV file's duration from its RIFF header, without loading the audio.


## Duration in seconds, or -1.0 if the file isn't a readable PCM WAV.
static func duration(path: String) -> float:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return -1.0
	if file.get_buffer(4).get_string_from_ascii() != "RIFF":
		return -1.0
	file.get_32() # RIFF size
	if file.get_buffer(4).get_string_from_ascii() != "WAVE":
		return -1.0

	var byte_rate := 0
	while file.get_position() + 8 <= file.get_length():
		var chunk_id := file.get_buffer(4).get_string_from_ascii()
		var chunk_size := file.get_32()
		var chunk_start := file.get_position()
		if chunk_id == "fmt ":
			file.get_16() # format tag
			file.get_16() # channels
			file.get_32() # sample rate
			byte_rate = file.get_32()
		elif chunk_id == "data":
			if byte_rate <= 0:
				return -1.0
			# A crashed recording can leave a size larger than what's on disk.
			var data_size: int = min(chunk_size, file.get_length() - chunk_start)
			return float(data_size) / byte_rate
		file.seek(chunk_start + chunk_size + (chunk_size & 1))
	return -1.0
