extends Control
## Wires up one DeckPanel per active deck + the master meter.
## Adding another deck is just adding its id here — nothing else is deck-count-specific.

const DeckPanelScene := preload("res://scenes/deck_panel.tscn")

const DEFAULT_BACKGROUND_PATH := "res://ant.jpg"

@onready var deck_container: Control = %DeckContainer
@onready var background: TextureRect = %Background

const ACTIVE_DECKS := ["[Channel1]", "[Channel2]"]


func _ready() -> void:
	set_background_image(DEFAULT_BACKGROUND_PATH)
	for deck_id in ACTIVE_DECKS:
		var panel := DeckPanelScene.instantiate()
		panel.deck_id = deck_id
		deck_container.add_child(panel)


## Loads an image from disk (res:// or an absolute user path) and shows it full-screen behind the UI.
func set_background_image(path: String) -> void:
	var image := Image.new()
	var err := image.load(path)
	if err != OK:
		push_error("Could not load background image '%s': %s" % [path, err])
		return
	background.texture = ImageTexture.create_from_image(image)
