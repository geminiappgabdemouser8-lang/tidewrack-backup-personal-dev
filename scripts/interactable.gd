extends Node2D
class_name Interactable
## Interactable — a point in the world the player can examine. Triggers a
## dialogue graph. Set `once` for items that should only fire a single time.

signal interacted(source: Interactable)

## Stable id used for save data (which objects have been examined).
var id: String = ""
var label: String = "Object"
var prompt_text: String = "Examine"
var dialogue_path: String = ""
var dialogue_start: String = "start"
var once: bool = false
var color: Color = Color("#5b7f8c")

var _used: bool = false


func setup() -> void:
	# Visual placeholder marker + name tag.
	var marker := ColorRect.new()
	marker.color = color
	marker.size = Vector2(40, 40)
	marker.position = Vector2(-20, -20)
	add_child(marker)

	var tag := Label.new()
	tag.text = label
	tag.position = Vector2(-40, 26)
	tag.add_theme_font_size_override("font_size", 14)
	tag.modulate = Color(1, 1, 1, 0.7)
	add_child(tag)


func can_interact() -> bool:
	return not (once and _used)


## Restore examined state after a load (so `once` items stay used).
func restore_used(used: bool) -> void:
	_used = used


func interact() -> void:
	if not can_interact():
		return
	_used = true
	GameState.mark_examined(id)
	interacted.emit(self)
	if dialogue_path != "":
		DialogueManager.start(dialogue_path, dialogue_start)
