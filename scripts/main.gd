extends Control
## Wires up one DeckPanel per active deck + the master meter.
## Adding another deck is just adding its id here — nothing else is deck-count-specific.

const DeckPanelScene := preload("res://scenes/deck_panel.tscn")

@onready var top_deck_slot: Control = %TopDeckSlot
@onready var bottom_deck_slot: Control = %BottomDeckSlot
@onready var background: BackgroundFx = %Background
@onready var settings_menu: Control = %SettingsMenu
@onready var select_background_button: Button = %SelectBackgroundButton
@onready var background_file_dialog: FileDialog = %BackgroundFileDialog
@onready var font_option_button: OptionButton = %FontOptionButton
@onready var low_color_picker: ColorPickerButton = %LowColorPicker
@onready var mid_color_picker: ColorPickerButton = %MidColorPicker
@onready var high_color_picker: ColorPickerButton = %HighColorPicker
@onready var accent_color_picker: ColorPickerButton = %AccentColorPicker
@onready var shader_toggles: VBoxContainer = %ShaderToggles

const ACTIVE_DECKS := ["[Channel1]", "[Channel2]"]


func _ready() -> void:
	BackgroundManager.background_changed.connect(_on_background_changed)
	select_background_button.pressed.connect(_on_select_background_pressed)
	background_file_dialog.file_selected.connect(_on_background_file_selected)
	theme = Theme.new()
	FontManager.font_changed.connect(_on_font_changed)
	for font_name in FontManager.FONTS.keys():
		font_option_button.add_item(font_name)
	font_option_button.select(FontManager.FONTS.keys().find(FontManager.current_font_name))
	_on_font_changed(FontManager.FONTS[FontManager.current_font_name])
	font_option_button.item_selected.connect(_on_font_item_selected)
	low_color_picker.color = BackgroundManager.current_colors["low"]
	mid_color_picker.color = BackgroundManager.current_colors["mid"]
	high_color_picker.color = BackgroundManager.current_colors["high"]
	accent_color_picker.color = BackgroundManager.current_colors["accent"]
	low_color_picker.color_changed.connect(func(c): BackgroundManager.set_color("low", c))
	mid_color_picker.color_changed.connect(func(c): BackgroundManager.set_color("mid", c))
	high_color_picker.color_changed.connect(func(c): BackgroundManager.set_color("high", c))
	accent_color_picker.color_changed.connect(func(c): BackgroundManager.set_color("accent", c))
	_build_shader_toggles()
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
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F11:
		_toggle_fullscreen()
		get_viewport().set_input_as_handled()


func _toggle_fullscreen() -> void:
	if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)


func _on_select_background_pressed() -> void:
	background_file_dialog.popup_centered()


func _on_background_file_selected(path: String) -> void:
	BackgroundManager.set_background(path)
	settings_menu.visible = false


func _on_background_changed(_image: Image, texture: ImageTexture) -> void:
	background.texture = texture


func _on_font_item_selected(index: int) -> void:
	FontManager.set_font(font_option_button.get_item_text(index))


func _on_font_changed(font: Font) -> void:
	theme.default_font = font


## One master "All shaders" switch plus one per effect in background_fx.gd's
## EFFECTS. Per-effect switches grey out while the master is off.
func _build_shader_toggles() -> void:
	var all_toggle := CheckButton.new()
	all_toggle.text = "All shaders"
	all_toggle.button_pressed = background.is_all_enabled()
	shader_toggles.add_child(all_toggle)

	var effect_toggles: Array[CheckButton] = []
	for effect in background.EFFECTS.keys():
		var toggle := CheckButton.new()
		toggle.text = effect
		toggle.button_pressed = background.is_effect_enabled(effect)
		toggle.disabled = not all_toggle.button_pressed
		toggle.toggled.connect(func(on): background.set_effect_enabled(effect, on))
		shader_toggles.add_child(toggle)
		effect_toggles.append(toggle)

	all_toggle.toggled.connect(func(on):
		background.set_all_enabled(on)
		for toggle in effect_toggles:
			toggle.disabled = not on
	)
