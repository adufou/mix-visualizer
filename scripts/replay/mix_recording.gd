class_name MixRecording
extends RefCounted
## One Mixxx recording's data file (.jsonl), parsed into memory.
## High-rate `levels` lines become flat packed arrays (struct-of-arrays,
## deck-interleaved: value for sample i, deck d is at [i * deck_count + d]).
## Rare `track_loaded` / `cover_art` lines become a small sorted event list.
## Pure data: safe to load from a worker thread. No textures are created here.

const KNOWN_VERSION := 1
const COVER_MAX_SIZE := 512

var path := ""
var version := 0
var audio_file := ""
var sample_rate := 0
var deck_ids: PackedStringArray = []

## Sample times (seconds), strictly increasing (identical `t` deduped, last wins).
var ts := PackedFloat64Array()
var pos := PackedFloat32Array()
var volume := PackedFloat32Array()
var eq_low := PackedFloat32Array()
var eq_mid := PackedFloat32Array()
var eq_high := PackedFloat32Array()
var bpm := PackedFloat32Array()
var beat_distance := PackedFloat32Array()
## Bit 0 = kill_low, bit 1 = kill_mid, bit 2 = kill_high.
var kills := PackedByteArray()
var master_low := PackedFloat32Array()
var master_mid := PackedFloat32Array()
var master_high := PackedFloat32Array()

## { t, deck, load_id, artist, title, waveform_frame_count, waveform_sample_rate,
##   waveform_bytes: PackedByteArray }, sorted by t.
var track_events: Array[Dictionary] = []
## { t, deck, load_id, image: Image }, sorted by t.
var cover_events: Array[Dictionary] = []

## Parse statistics, for the validation report.
var line_count := 0
var skipped_lines := 0
var type_counts: Dictionary = {}
var last_t := 0.0

## 0..1 while loading, readable from another thread (approximate).
var progress := 0.0


func sample_count() -> int:
	return ts.size()


func deck_count() -> int:
	return deck_ids.size()


func deck_index(deck_id: String) -> int:
	return deck_ids.find(deck_id)


## Decks that had at least one track loaded during the recording.
func used_decks() -> PackedStringArray:
	var used: PackedStringArray = []
	for event in track_events:
		if not used.has(event["deck"]):
			used.append(event["deck"])
	used.sort()
	return used


## Parses `file_path` line by line. Returns an empty string on success,
## an error message otherwise. Unparseable lines (e.g. a truncated last
## line after a crash) are skipped, not fatal.
func load_file(file_path: String) -> String:
	var file := FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		return "Cannot open '%s': %s" % [file_path, error_string(FileAccess.get_open_error())]
	path = file_path
	var total_bytes: float = max(1.0, float(file.get_length()))
	var waveform_cache: Dictionary = {}

	while not file.eof_reached():
		var line := file.get_line()
		if line.is_empty():
			continue
		line_count += 1
		if line_count % 2000 == 0:
			progress = file.get_position() / total_bytes

		var msg = JSON.parse_string(line)
		if not msg is Dictionary:
			skipped_lines += 1
			continue
		var msg_type: String = str(msg.get("type", ""))
		type_counts[msg_type] = type_counts.get(msg_type, 0) + 1
		var t := float(msg.get("t", 0.0))
		last_t = max(last_t, t)

		match msg_type:
			"header":
				_parse_header(msg)
			"levels":
				_parse_levels(msg, t)
			"track_loaded":
				_parse_track_loaded(msg, t, waveform_cache)
			"cover_art":
				_parse_cover_art(msg, t)

	progress = 1.0
	if deck_ids.is_empty():
		return "No header line in '%s'" % file_path
	if ts.is_empty():
		return "No levels data in '%s'" % file_path
	return ""


func _parse_header(msg: Dictionary) -> void:
	version = int(msg.get("version", 0))
	if version != KNOWN_VERSION:
		push_warning("MixRecording: unknown format version %d (expected %d)" % [version, KNOWN_VERSION])
	audio_file = str(msg.get("audio_file", ""))
	sample_rate = int(msg.get("sample_rate", 0))
	deck_ids = PackedStringArray(msg.get("decks", []))


func _parse_levels(msg: Dictionary, t: float) -> void:
	if deck_ids.is_empty():
		return
	var n := ts.size()
	# Several lines often share the same engine-buffer timestamp: keep the last.
	var i := n - 1 if n > 0 and ts[n - 1] == t else n
	if i == n:
		ts.append(t)
		var deck_n := deck_ids.size()
		pos.resize((n + 1) * deck_n)
		volume.resize((n + 1) * deck_n)
		eq_low.resize((n + 1) * deck_n)
		eq_mid.resize((n + 1) * deck_n)
		eq_high.resize((n + 1) * deck_n)
		bpm.resize((n + 1) * deck_n)
		beat_distance.resize((n + 1) * deck_n)
		kills.resize((n + 1) * deck_n)
		master_low.append(0.0)
		master_mid.append(0.0)
		master_high.append(0.0)

	var decks: Dictionary = msg.get("decks", {})
	for d in deck_ids.size():
		var k := i * deck_ids.size() + d
		var deck: Dictionary = decks.get(deck_ids[d], {})
		pos[k] = float(deck.get("pos", -1.0))
		volume[k] = float(deck.get("volume", 0.0))
		eq_low[k] = float(deck.get("eq_low", 1.0))
		eq_mid[k] = float(deck.get("eq_mid", 1.0))
		eq_high[k] = float(deck.get("eq_high", 1.0))
		bpm[k] = float(deck.get("bpm", 0.0))
		beat_distance[k] = float(deck.get("beat_distance", 0.0))
		kills[k] = (1 if deck.get("kill_low", false) else 0) \
				| (2 if deck.get("kill_mid", false) else 0) \
				| (4 if deck.get("kill_high", false) else 0)

	var master: Dictionary = msg.get("master", {})
	master_low[i] = float(master.get("low", 0.0))
	master_mid[i] = float(master.get("mid", 0.0))
	master_high[i] = float(master.get("high", 0.0))


func _parse_track_loaded(msg: Dictionary, t: float, waveform_cache: Dictionary) -> void:
	var deck_id := str(msg.get("deck", ""))
	if deck_id.is_empty():
		return
	var load_id := int(msg.get("load_id", -1))
	var frame_count := int(msg.get("waveform_frame_count", 0))
	var wave_rate := float(msg.get("waveform_sample_rate", 0.0))
	var waveform_data = msg.get("waveform_low_mid_high_base64")

	var bytes := PackedByteArray()
	if waveform_data is String and frame_count > 0:
		# One load sends the same waveform 1-2 times: decode each once.
		var cache_key := "%d:%d" % [load_id, frame_count]
		if waveform_cache.has(cache_key):
			bytes = waveform_cache[cache_key]
		else:
			bytes = Marshalls.base64_to_raw(waveform_data)
			if bytes.size() != frame_count * 3:
				push_warning("MixRecording: waveform size mismatch for load %d: expected %d, got %d" % [load_id, frame_count * 3, bytes.size()])
			waveform_cache[cache_key] = bytes
	else:
		frame_count = 0
		wave_rate = 0.0

	track_events.append({
		"t": t,
		"deck": deck_id,
		"load_id": load_id,
		"artist": str(msg.get("artist", "")),
		"title": str(msg.get("title", "")),
		"waveform_frame_count": frame_count,
		"waveform_sample_rate": wave_rate,
		"waveform_bytes": bytes,
	})


func _parse_cover_art(msg: Dictionary, t: float) -> void:
	var deck_id := str(msg.get("deck", ""))
	var cover_data = msg.get("cover_png_base64")
	if deck_id.is_empty() or not cover_data is String:
		return
	var image := Image.new()
	if image.load_png_from_buffer(Marshalls.base64_to_raw(cover_data)) != OK:
		push_warning("MixRecording: failed to decode cover for %s at t=%.3f" % [deck_id, t])
		return
	# Covers come at full resolution (several MB); the overlay draws them small.
	var longest: int = max(image.get_width(), image.get_height())
	if longest > COVER_MAX_SIZE:
		var scale := float(COVER_MAX_SIZE) / longest
		image.resize(int(image.get_width() * scale), int(image.get_height() * scale), Image.INTERPOLATE_LANCZOS)
	cover_events.append({
		"t": t,
		"deck": deck_id,
		"load_id": int(msg.get("load_id", -1)),
		"image": image,
	})
