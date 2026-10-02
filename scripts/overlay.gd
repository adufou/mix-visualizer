class_name Overlay
extends Control
## The rendered picture, and nothing else: background + one DeckPanel per shown
## deck + master meter. Designed at 1920x1080. Hosted in a SubViewport by both
## the editor (preview) and the renderer (video frames), so no UI ends up in it.

const DeckPanelScene := preload("res://scenes/deck_panel.tscn")

## Used until a recording says which decks actually played.
const DEFAULT_DECKS := ["[Channel1]", "[Channel2]"]

@onready var top_deck_slot: Control = %TopDeckSlot
@onready var bottom_deck_slot: Control = %BottomDeckSlot
@onready var background: BackgroundFx = %Background


func _ready() -> void:
	theme = Theme.new()
	BackgroundManager.background_changed.connect(_on_background_changed)
	FontManager.font_changed.connect(_on_font_changed)
	MixData.recording_changed.connect(_build_deck_panels)
	if BackgroundManager.current_texture != null:
		background.texture = BackgroundManager.current_texture
	_on_font_changed(FontManager.FONTS[FontManager.current_font_name])
	_build_deck_panels()


## Two slots: the first two decks (by deck number) that had a track loaded
## during the recording.
func _build_deck_panels() -> void:
	var shown: Array = DEFAULT_DECKS
	if MixData.has_recording():
		var used := MixData.recording.used_decks()
		if not used.is_empty():
			shown = Array(used).slice(0, 2)

	var slots := [top_deck_slot, bottom_deck_slot]
	for slot in slots:
		for child in slot.get_children():
			child.queue_free()
	for i in shown.size():
		var panel := DeckPanelScene.instantiate()
		panel.deck_id = shown[i]
		# Top deck's labels sit at the bottom of its waveform, bottom deck's at the
		# top, so both label rows meet near the screen's vertical center.
		panel.reversed = (i == 0)
		slots[i].add_child(panel)


func _on_background_changed(_image: Image, texture: ImageTexture) -> void:
	background.texture = texture


func _on_font_changed(font: Font) -> void:
	theme.default_font = font
