extends Node
## Autoload singleton: the overlay's single source of truth. Holds the loaded
## MixRecording and exposes the deck/master state at the current time `t`.
## Nothing here reads a clock: whoever drives playback (editor preview from
## the audio position, renderer from the frame index) calls seek(t) once per
## frame, before the overlay's nodes process.

signal recording_changed()
signal track_loaded(deck_id: String)
signal cover_art_received(deck_id: String)
signal levels_updated()

## A pos jump bigger than this much track time between two samples is a seek,
## loop jump or track change: hold instead of interpolating across it.
const POS_DISCONTINUITY_SECONDS := 2.0

var recording: MixRecording
var time := 0.0

## deck_id -> { load_id, artist, title, waveform_frame_count, waveform_sample_rate,
##              waveform_bytes: PackedByteArray, cover_texture: Texture2D or null,
##              cover_load_id }
var decks: Dictionary = {}

## deck_id -> { pos, volume, eq_low, eq_mid, eq_high, kill_low, kill_mid, kill_high,
##              bpm, beat_distance }
## bpm: effective tempo, 0.0 if no track. beat_distance: 0..1 into the current
## beat, wraps 1 -> 0 on each beat hit. pos: 0..1 fraction of the track, -1 = none.
var latest_levels: Dictionary = {}

## { low, mid, high }: main mix RMS per band.
var master: Dictionary = {"low": 0.0, "mid": 0.0, "high": 0.0}

## load_id -> ImageTexture, built lazily on the main thread.
var _cover_textures: Dictionary = {}


func set_recording(new_recording: MixRecording) -> void:
	recording = new_recording
	decks.clear()
	latest_levels.clear()
	_cover_textures.clear()
	master = {"low": 0.0, "mid": 0.0, "high": 0.0}
	recording_changed.emit()
	seek(0.0)


func has_recording() -> bool:
	return recording != null


func seek(t: float) -> void:
	time = t
	if recording == null:
		return
	_apply_events(t)
	_apply_levels(t)
	levels_updated.emit()


## Per deck: the latest track_loaded with event.t <= t wins; its cover is the
## latest cover_art with the same load_id (event.t <= t).
func _apply_events(t: float) -> void:
	var latest_track: Dictionary = {}
	for event in recording.track_events:
		if event["t"] > t:
			break
		latest_track[event["deck"]] = event

	for deck_id in recording.deck_ids:
		var event: Dictionary = latest_track.get(deck_id, {})
		var deck: Dictionary = decks.get(deck_id, {})
		var load_id: int = event.get("load_id", -1)
		var frame_count: int = event.get("waveform_frame_count", 0)
		if deck.get("load_id", -1) != load_id or deck.get("waveform_frame_count", 0) != frame_count:
			deck["load_id"] = load_id
			deck["artist"] = event.get("artist", "")
			deck["title"] = event.get("title", "")
			deck["waveform_frame_count"] = frame_count
			deck["waveform_sample_rate"] = event.get("waveform_sample_rate", 0.0)
			deck["waveform_bytes"] = event.get("waveform_bytes", PackedByteArray())
			decks[deck_id] = deck
			track_loaded.emit(deck_id)

		var cover_load_id := -1
		var cover_image: Image = null
		for cover in recording.cover_events:
			if cover["t"] > t:
				break
			if cover["deck"] == deck_id and cover["load_id"] == load_id:
				cover_load_id = load_id
				cover_image = cover["image"]
		if deck.get("cover_load_id", -1) != cover_load_id or not deck.has("cover_texture"):
			deck["cover_load_id"] = cover_load_id
			deck["cover_texture"] = _cover_texture(cover_load_id, cover_image)
			decks[deck_id] = deck
			cover_art_received.emit(deck_id)


func _cover_texture(load_id: int, image: Image) -> Texture2D:
	if image == null:
		return null
	if not _cover_textures.has(load_id):
		_cover_textures[load_id] = ImageTexture.create_from_image(image)
	return _cover_textures[load_id]


func _apply_levels(t: float) -> void:
	var rec := recording
	var n := rec.sample_count()
	# Last sample with ts[i] <= t, clamped to the data range.
	var i: int = clamp(rec.ts.bsearch(t, false) - 1, 0, n - 1)
	var j: int = min(i + 1, n - 1)
	var w := 0.0
	if j != i and t > rec.ts[i]:
		w = clamp((t - rec.ts[i]) / (rec.ts[j] - rec.ts[i]), 0.0, 1.0)

	var deck_n := rec.deck_count()
	for d in deck_n:
		var deck_id: String = rec.deck_ids[d]
		var a := i * deck_n + d
		var b := j * deck_n + d
		var k: int = rec.kills[a]
		latest_levels[deck_id] = {
			"pos": _interp_pos(rec.pos[a], rec.pos[b], w, deck_id),
			"volume": lerp(rec.volume[a], rec.volume[b], w),
			"eq_low": lerp(rec.eq_low[a], rec.eq_low[b], w),
			"eq_mid": lerp(rec.eq_mid[a], rec.eq_mid[b], w),
			"eq_high": lerp(rec.eq_high[a], rec.eq_high[b], w),
			"kill_low": (k & 1) != 0,
			"kill_mid": (k & 2) != 0,
			"kill_high": (k & 4) != 0,
			"bpm": lerp(rec.bpm[a], rec.bpm[b], w),
			"beat_distance": _interp_beat(rec.beat_distance[a], rec.beat_distance[b], w),
		}

	master["low"] = lerp(rec.master_low[i], rec.master_low[j], w)
	master["mid"] = lerp(rec.master_mid[i], rec.master_mid[j], w)
	master["high"] = lerp(rec.master_high[i], rec.master_high[j], w)


func _interp_pos(p0: float, p1: float, w: float, deck_id: String) -> float:
	if w == 0.0 or p0 < -0.5 or p1 < -0.5:
		return p0
	var deck: Dictionary = decks.get(deck_id, {})
	var wave_rate: float = deck.get("waveform_sample_rate", 0.0)
	var frame_count: int = deck.get("waveform_frame_count", 0)
	if wave_rate <= 0.0 or frame_count <= 0:
		return p0 # unknown duration: can't tell playback from a jump
	var duration := frame_count / wave_rate
	if abs(p1 - p0) * duration > POS_DISCONTINUITY_SECONDS:
		return p0
	return lerp(p0, p1, w)


## Crossing a beat wraps ~1 -> ~0: interpolate through 1 and wrap back.
func _interp_beat(b0: float, b1: float, w: float) -> float:
	if b1 < b0 - 0.5:
		b1 += 1.0
	return fposmod(lerp(b0, b1, w), 1.0)
