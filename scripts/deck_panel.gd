extends Control
## Track info + waveform display for a single deck. Instantiate once per deck.

@export var deck_id := "[Channel1]"
## When true, the label header is placed below the waveform instead of above it
## (used for the top deck so its labels sit next to the screen's vertical center).
@export var reversed := false

@onready var artist_label: Label = %ArtistLabel
@onready var title_label: Label = %TitleLabel
@onready var cover_rect: TextureRect = %CoverRect
@onready var waveform_display: Control = %WaveformDisplay
@onready var header: Control = %Header


func _ready() -> void:
	waveform_display.deck_id = deck_id
	cover_rect.texture = _make_placeholder_cover()

	if reversed:
		header.get_parent().move_child(header, header.get_index() + 1)

	MixxxClient.track_loaded.connect(_on_track_loaded)
	MixxxClient.cover_art_received.connect(_on_cover_art_received)

	if MixxxClient.decks.has(deck_id):
		_refresh_track_info()


func _on_track_loaded(loaded_deck_id: String) -> void:
	if loaded_deck_id != deck_id:
		return
	_refresh_track_info()


func _on_cover_art_received(loaded_deck_id: String) -> void:
	if loaded_deck_id != deck_id:
		return
	var deck: Dictionary = MixxxClient.decks.get(deck_id, {})
	if deck.has("cover_texture"):
		cover_rect.texture = deck["cover_texture"]


func _refresh_track_info() -> void:
	var deck: Dictionary = MixxxClient.decks.get(deck_id, {})
	artist_label.text = deck.get("artist", "")
	title_label.text = deck.get("title", "")


func _make_placeholder_cover() -> ImageTexture:
	var image := Image.create(64, 64, false, Image.FORMAT_RGB8)
	image.fill(Color(0.25, 0.25, 0.25))
	return ImageTexture.create_from_image(image)
