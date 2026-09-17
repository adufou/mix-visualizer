extends Node
## Autoload singleton: owns the hardcoded list of selectable fonts and the
## current pick made via the esc menu's font dropdown.

signal font_changed(font: Font)

const FONTS: Dictionary = {
	"Bebas Neue": preload("res://assets/fonts/BebasNeue-Regular.ttf"),
	"Bitwise": preload("res://assets/fonts/Bitwise.ttf"),
	"Checkbook": preload("res://assets/fonts/CHECKBK0.TTF"),
	"Video Phreak": preload("res://assets/fonts/VideoPhreak.ttf"),
	"Compacta BT": preload("res://assets/fonts/CompactaBT.ttf"),
	"Unicode Serpents": preload("res://assets/fonts/unicode.serpents.ttf"),
}

var current_font_name: String = "Unicode Serpents"


func set_font(font_name: String) -> void:
	if not FONTS.has(font_name):
		push_error("FontManager: unknown font '%s'" % font_name)
		return
	current_font_name = font_name
	font_changed.emit(FONTS[font_name])
