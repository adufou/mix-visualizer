class_name Overlay
extends Control
## The rendered picture, and nothing else: background + one DeckPanel per shown
## deck + master meter. Designed at 1920x1080. Hosted in a SubViewport by both
## the editor (preview) and the renderer (video frames), so no UI ends up in it.

const DeckPanelScene := preload("res://scenes/deck_panel.tscn")

## Selectable deck pairs (style "decks"). "Auto" = the first two decks (by
## deck number) that had a track loaded, or 1/2 until a recording says.
const DECK_PAIRS: Dictionary = {
	"Auto": [],
	"1/2": ["[Channel1]", "[Channel2]"],
	"3/4": ["[Channel3]", "[Channel4]"],
}

## Waveform bar height multiplier (style "waveform_height"), on top of the
## per-track level normalization. Same as WaveformDisplay.height_scale's default.
const DEFAULT_WAVEFORM_HEIGHT := 1.0

@onready var top_deck_slot: Control = %TopDeckSlot
@onready var bottom_deck_slot: Control = %BottomDeckSlot
@onready var background: BackgroundFx = %Background

var deck_pair := "Auto"
var waveform_height := DEFAULT_WAVEFORM_HEIGHT


func _ready() -> void:
	theme = Theme.new()
	BackgroundManager.background_changed.connect(_on_background_changed)
	FontManager.font_changed.connect(_on_font_changed)
	MixData.recording_changed.connect(_build_deck_panels)
	if BackgroundManager.current_texture != null:
		background.texture = BackgroundManager.current_texture
	_on_font_changed(FontManager.FONTS[FontManager.current_font_name])
	_build_deck_panels()


func set_deck_pair(pair: String) -> void:
	if not DECK_PAIRS.has(pair):
		push_error("Overlay: unknown deck pair '%s'" % pair)
		return
	deck_pair = pair
	if is_node_ready():
		_build_deck_panels()


func set_waveform_height(height: float) -> void:
	waveform_height = height
	if is_node_ready():
		for slot in [top_deck_slot, bottom_deck_slot]:
			for panel in slot.get_children():
				panel.waveform_display.height_scale = height


## Two slots, filled from deck_pair.
func _build_deck_panels() -> void:
	var shown: Array = DECK_PAIRS[deck_pair]
	if shown.is_empty():
		shown = DECK_PAIRS["1/2"]
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
		panel.waveform_display.height_scale = waveform_height


func _on_background_changed(_image: Image, texture: ImageTexture) -> void:
	background.texture = texture


func _on_font_changed(font: Font) -> void:
	theme.default_font = font
