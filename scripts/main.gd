extends Control
## Wires up one DeckPanel per active deck (POC: just "[Channel1]") + the master meter.
## Adding another deck is just instantiating another DeckPanel with a different deck_id.

const DeckPanelScene := preload("res://scenes/deck_panel.tscn")

@onready var deck_container: Control = %DeckContainer

const ACTIVE_DECKS := ["[Channel1]"]


func _ready() -> void:
	for deck_id in ACTIVE_DECKS:
		var panel := DeckPanelScene.instantiate()
		panel.deck_id = deck_id
		deck_container.add_child(panel)
