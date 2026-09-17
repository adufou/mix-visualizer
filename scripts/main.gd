extends Control
## Wires up one DeckPanel per active deck + the master meter.
## Adding another deck is just adding its id here — nothing else is deck-count-specific.

const DeckPanelScene := preload("res://scenes/deck_panel.tscn")

@onready var top_deck_slot: Control = %TopDeckSlot
@onready var bottom_deck_slot: Control = %BottomDeckSlot
@onready var background: TextureRect = %Background
@onready var settings_menu: Control = %SettingsMenu
@onready var select_background_button: Button = %SelectBackgroundButton
@onready var background_file_dialog: FileDialog = %BackgroundFileDialog
@onready var low_color_picker: ColorPickerButton = %LowColorPicker
@onready var mid_color_picker: ColorPickerButton = %MidColorPicker
@onready var high_color_picker: ColorPickerButton = %HighColorPicker
@onready var accent_color_picker: ColorPickerButton = %AccentColorPicker

const ACTIVE_DECKS := ["[Channel1]", "[Channel2]"]


func _ready() -> void:
	BackgroundManager.background_changed.connect(_on_background_changed)
	select_background_button.pressed.connect(_on_select_background_pressed)
	background_file_dialog.file_selected.connect(_on_background_file_selected)
	low_color_picker.color = BackgroundManager.current_colors["low"]
	mid_color_picker.color = BackgroundManager.current_colors["mid"]
	high_color_picker.color = BackgroundManager.current_colors["high"]
	accent_color_picker.color = BackgroundManager.current_colors["accent"]
	low_color_picker.color_changed.connect(func(c): BackgroundManager.set_color("low", c))
	mid_color_picker.color_changed.connect(func(c): BackgroundManager.set_color("mid", c))
	high_color_picker.color_changed.connect(func(c): BackgroundManager.set_color("high", c))
	accent_color_picker.color_changed.connect(func(c): BackgroundManager.set_color("accent", c))
	var slots := [top_deck_slot, bottom_deck_slot]
	for i in ACTIVE_DECKS.size():
		var panel := DeckPanelScene.instantiate()
		panel.deck_id = ACTIVE_DECKS[i]
		# Top deck's labels sit at the bottom of its waveform, bottom deck's at the
		# top, so both label rows meet near the screen's vertical center.
		panel.reversed = (i == 0)
		slots[i].add_child(panel)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		settings_menu.visible = not settings_menu.visible
		get_viewport().set_input_as_handled()


func _on_select_background_pressed() -> void:
	background_file_dialog.popup_centered()


func _on_background_file_selected(path: String) -> void:
	BackgroundManager.set_background(path)
	settings_menu.visible = false


func _on_background_changed(_image: Image, texture: ImageTexture) -> void:
	background.texture = texture
