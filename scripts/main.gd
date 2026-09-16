extends Control
## Wires up one DeckPanel per active deck + the master meter.
## Adding another deck is just adding its id here — nothing else is deck-count-specific.

const DeckPanelScene := preload("res://scenes/deck_panel.tscn")

const DEFAULT_BACKGROUND_PATH := "res://ant.jpg"

@onready var top_deck_slot: Control = %TopDeckSlot
@onready var bottom_deck_slot: Control = %BottomDeckSlot
@onready var background: TextureRect = %Background

const ACTIVE_DECKS := ["[Channel1]", "[Channel2]"]


func _ready() -> void:
	set_background_image(DEFAULT_BACKGROUND_PATH)
	var slots := [top_deck_slot, bottom_deck_slot]
	for i in ACTIVE_DECKS.size():
		var panel := DeckPanelScene.instantiate()
		panel.deck_id = ACTIVE_DECKS[i]
		# Top deck's labels sit at the bottom of its waveform, bottom deck's at the
		# top, so both label rows meet near the screen's vertical center.
		panel.reversed = (i == 0)
		slots[i].add_child(panel)


## Loads an image from disk (res:// or an absolute user path) and shows it full-screen behind the UI.
func set_background_image(path: String) -> void:
	var image := Image.new()
	var err := image.load(path)
	if err != OK:
		push_error("Could not load background image '%s': %s" % [path, err])
		return
	background.texture = ImageTexture.create_from_image(image)
