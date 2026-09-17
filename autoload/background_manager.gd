extends Node
## Autoload singleton: owns the current background image and the 4
## user-chosen accent colors (low/mid/high band + text/bar) picked via the
## esc menu's color pickers.

signal background_changed(image: Image, texture: ImageTexture)
signal colors_changed(colors: Dictionary)

var current_path: String = ""
var current_image: Image
var current_texture: ImageTexture

var current_colors: Dictionary = {
	"low": Color(0.9, 0.45, 0.15),
	"mid": Color(0.85, 0.15, 0.15),
	"high": Color(0.95, 0.85, 0.25),
	"accent": Color(1, 1, 1),
}


## Loads an image from disk (res:// or an absolute user path) and broadcasts it.
func set_background(path: String) -> bool:
	var image := Image.new()
	var err := image.load(path)
	if err != OK:
		push_error("BackgroundManager: could not load '%s': %s" % [path, err])
		return false

	current_path = path
	current_image = image
	current_texture = ImageTexture.create_from_image(image)
	background_changed.emit(current_image, current_texture)
	return true


## `band` is one of "low", "mid", "high", "accent".
func set_color(band: String, color: Color) -> void:
	current_colors[band] = color
	colors_changed.emit(current_colors)
