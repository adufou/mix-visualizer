extends Node
## Autoload singleton: owns the current background image.
## Keeps the raw Image (not just its texture) so future features
## (color extraction, palettes, etc.) can read pixel data without reloading.

signal background_changed(image: Image, texture: ImageTexture)

var current_path: String = ""
var current_image: Image
var current_texture: ImageTexture


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
