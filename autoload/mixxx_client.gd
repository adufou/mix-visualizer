extends Node
## Autoload singleton: TCP connection to Mixxx's Live Data Export feature.
## Owns the connection, JSON line framing, and all shared deck/master state.

@export var host := "127.0.0.1"
@export var port := 9090

const RECONNECT_INTERVAL := 2.0

signal track_loaded(deck_id: String)
signal cover_art_received(deck_id: String)
signal levels_updated()

## deck_id -> { artist, title, album, waveform_frame_count, waveform_sample_rate,
##              waveform_bytes: PackedByteArray, cover_texture: ImageTexture }
var decks: Dictionary = {}

## deck_id -> { pos, eq_low, eq_mid, eq_high, kill_low, kill_mid, kill_high }
var latest_levels: Dictionary = {}

## { low, mid, high }
var master: Dictionary = {"low": 0.0, "mid": 0.0, "high": 0.0}

var _socket := StreamPeerTCP.new()
var _connected := false
var _reconnect_timer := 0.0
var _recv_buffer := PackedByteArray()


func _process(delta: float) -> void:
	if not _connected:
		_reconnect_timer -= delta
		if _reconnect_timer <= 0.0:
			_try_connect()
		return

	_socket.poll()
	var status: StreamPeerTCP.Status = _socket.get_status()
	if status == StreamPeerTCP.STATUS_CONNECTING:
		return # still completing the handshake, not a failure
	if status != StreamPeerTCP.STATUS_CONNECTED:
		_on_disconnected()
		return

	var available: int = _socket.get_available_bytes()
	if available > 0:
		var chunk: PackedByteArray = _socket.get_data(available)[1]
		_recv_buffer.append_array(chunk)
		_drain_lines()


func _try_connect() -> void:
	_socket = StreamPeerTCP.new()
	var err: Error = _socket.connect_to_host(host, port)
	if err != OK:
		_reconnect_timer = RECONNECT_INTERVAL
		return
	# Give the non-blocking connect a moment; poll() below drives the handshake.
	_socket.poll()
	var status: StreamPeerTCP.Status = _socket.get_status()
	if status == StreamPeerTCP.STATUS_CONNECTED or status == StreamPeerTCP.STATUS_CONNECTING:
		_connected = true
		_recv_buffer.clear()
	else:
		_reconnect_timer = RECONNECT_INTERVAL


func _on_disconnected() -> void:
	_connected = false
	_reconnect_timer = RECONNECT_INTERVAL
	_socket.disconnect_from_host()


func _drain_lines() -> void:
	while true:
		var newline_index: int = _recv_buffer.find(10) # '\n'
		if newline_index == -1:
			break
		var line_bytes := _recv_buffer.slice(0, newline_index)
		_recv_buffer = _recv_buffer.slice(newline_index + 1)
		if line_bytes.is_empty():
			continue
		var line := line_bytes.get_string_from_utf8()
		var parsed = JSON.parse_string(line)
		if parsed is Dictionary:
			_handle_message(parsed)


func _handle_message(msg: Dictionary) -> void:
	var msg_type: String = msg.get("type", "")
	match msg_type:
		"track_loaded":
			_handle_track_loaded(msg)
		"cover_art":
			_handle_cover_art(msg)
		"levels":
			_handle_levels(msg)


func _handle_track_loaded(msg: Dictionary) -> void:
	var deck_id: String = msg.get("deck", "")
	if deck_id.is_empty():
		return
	var deck: Dictionary = decks.get(deck_id, {})

	for key in ["artist", "title", "album"]:
		if msg.has(key):
			deck[key] = msg[key]

	if msg.has("waveform_frame_count") and msg.has("waveform_sample_rate") and msg.has("waveform_low_mid_high_base64"):
		var frame_count: int = int(msg["waveform_frame_count"])
		var sample_rate: float = float(msg["waveform_sample_rate"])
		var waveform_data = msg["waveform_low_mid_high_base64"]

		if waveform_data == null or frame_count == 0:
			deck["waveform_frame_count"] = 0
			deck["waveform_sample_rate"] = sample_rate
			deck["waveform_bytes"] = PackedByteArray()
			print("mixxx_client: %s waveform not analyzed yet, cleared" % deck_id)
		else:
			var raw_bytes: PackedByteArray = Marshalls.base64_to_raw(waveform_data)

			if raw_bytes.size() != frame_count * 3:
				push_warning("mixxx_client: waveform byte count mismatch for %s: expected %d, got %d" % [deck_id, frame_count * 3, raw_bytes.size()])

			deck["waveform_frame_count"] = frame_count
			deck["waveform_sample_rate"] = sample_rate
			deck["waveform_bytes"] = raw_bytes

			var duration_sec := frame_count / sample_rate if sample_rate > 0.0 else 0.0
			print("mixxx_client: %s waveform ready — %d frames @ %.3f frames/sec = %.2fs track duration (cross-check against Mixxx)" % [deck_id, frame_count, sample_rate, duration_sec])

	decks[deck_id] = deck
	track_loaded.emit(deck_id)


func _handle_cover_art(msg: Dictionary) -> void:
	var deck_id: String = msg.get("deck", "")
	if deck_id.is_empty() or not msg.has("cover_png_base64"):
		return
	var png_bytes: PackedByteArray = Marshalls.base64_to_raw(msg["cover_png_base64"])
	var image := Image.new()
	var err: Error = image.load_png_from_buffer(png_bytes)
	if err != OK:
		push_warning("mixxx_client: failed to decode cover art for %s" % deck_id)
		return
	var texture := ImageTexture.create_from_image(image)

	var deck: Dictionary = decks.get(deck_id, {})
	deck["cover_texture"] = texture
	decks[deck_id] = deck
	cover_art_received.emit(deck_id)


func _handle_levels(msg: Dictionary) -> void:
	var decks_data: Dictionary = msg.get("decks", {})
	for deck_id in decks_data.keys():
		latest_levels[deck_id] = decks_data[deck_id]

	var master_data: Dictionary = msg.get("master", {})
	if master_data.has("low"):
		master["low"] = float(master_data["low"])
	if master_data.has("mid"):
		master["mid"] = float(master_data["mid"])
	if master_data.has("high"):
		master["high"] = float(master_data["high"])

	levels_updated.emit()
