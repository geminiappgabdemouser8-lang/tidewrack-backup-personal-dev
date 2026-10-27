extends Node2D
## Game — the vertical-slice level: the ground floor of Cape Marrow Light.
## Builds the room, player, interactables, HUD prompt, dialogue box, and a
## pause overlay in code.
##
## Pausing uses the SceneTree pause: this node keeps processing so Esc still
## closes the menu, while the player and dialogue box are PAUSABLE and freeze.
## After a load, _apply_resume() puts the player back where they were and
## re-opens any conversation that was in progress.

const DIALOGUE := "res://data/dialogue/keeper_intro.json"
const INTERACT_RADIUS := 90.0
const ROOM := Rect2(120, 140, 1040, 460)

var _player: Player
var _interactables: Array[Interactable] = []
var _prompt: Label
var _nearest: Interactable = null
var _paused: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS  # so the pause menu can be closed
	_build_room()
	_build_player()
	_build_interactables()
	_build_hud()

	var dialogue_box := preload("res://scenes/ui/dialogue_box.tscn").instantiate()
	dialogue_box.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(dialogue_box)

	DialogueManager.dialogue_started.connect(func(): _set_movement(false))
	DialogueManager.dialogue_finished.connect(func(): _set_movement(true))

	if GameState.resume_pending:
		_apply_resume()


## Put the player back where the save left them.
func _apply_resume() -> void:
	GameState.resume_pending = false
	if typeof(GameState.player_pos) == TYPE_VECTOR2:
		_player.position = GameState.player_pos
	var dialogue := GameState.dialogue
	if not dialogue.is_empty():
		# Deferred so the dialogue box and camera have finished entering the tree.
		DialogueManager.call_deferred("start", str(dialogue["path"]), str(dialogue["node"]))


func _build_room() -> void:
	var bg := ColorRect.new()
	bg.color = Color("#0f1a22")
	bg.size = Vector2(1280, 720)
	add_child(bg)

	var floor_rect := ColorRect.new()
	floor_rect.color = Color("#1c2b34")
	floor_rect.position = ROOM.position
	floor_rect.size = ROOM.size
	add_child(floor_rect)

	var title := Label.new()
	title.text = "Cape Marrow Light — ground floor"
	title.position = Vector2(ROOM.position.x, ROOM.position.y - 34)
	title.modulate = Color(1, 1, 1, 0.5)
	add_child(title)


func _build_player() -> void:
	_player = Player.new()
	_player.process_mode = Node.PROCESS_MODE_PAUSABLE
	_player.bounds = ROOM.grow(-30)
	_player.position = Vector2(ROOM.position.x + ROOM.size.x * 0.5, ROOM.position.y + ROOM.size.y - 60)
	add_child(_player)

	var camera := Camera2D.new()
	camera.position_smoothing_enabled = true
	_player.add_child(camera)
	camera.make_current()


func _build_interactables() -> void:
	_add_interactable("Logbook", "Read the keeper's log", "logbook",
		Vector2(ROOM.position.x + 160, ROOM.position.y + 120), Color("#8a6f4b"))
	_add_interactable("Radio set", "Call the mainland", "radio",
		Vector2(ROOM.position.x + ROOM.size.x - 180, ROOM.position.y + 130), Color("#4b6f8a"))
	_add_interactable("Lamp-room stair", "Climb toward the light", "door",
		Vector2(ROOM.position.x + ROOM.size.x * 0.5, ROOM.position.y + 60), Color("#3a4a54"))


func _add_interactable(label: String, prompt: String, start_id: String, pos: Vector2, color: Color) -> void:
	var item := Interactable.new()
	item.id = start_id
	item.label = label
	item.prompt_text = prompt
	item.dialogue_path = DIALOGUE
	item.dialogue_start = start_id
	item.color = color
	item.position = pos
	add_child(item)
	item.setup()
	item.restore_used(GameState.is_examined(start_id))
	_interactables.append(item)


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	_prompt = Label.new()
	_prompt.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_prompt.offset_top = -70
	_prompt.offset_left = -200
	_prompt.offset_right = 200
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt.add_theme_font_size_override("font_size", 20)
	_prompt.modulate = Color("#ffd466")
	_prompt.hide()
	layer.add_child(_prompt)


func _process(_delta: float) -> void:
	if _paused or DialogueManager.is_active:
		_prompt.hide()
		return
	_nearest = _find_nearest()
	if _nearest != null:
		_prompt.text = "[ Enter ] %s" % _nearest.prompt_text
		_prompt.show()
	else:
		_prompt.hide()


func _find_nearest() -> Interactable:
	var best: Interactable = null
	var best_dist := INTERACT_RADIUS
	for item in _interactables:
		if not item.can_interact():
			continue
		var dist := _player.position.distance_to(item.position)
		if dist <= best_dist:
			best_dist = dist
			best = item
	return best


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		# Allowed mid-dialogue: the box is PAUSABLE and freezes with the tree,
		# and a save taken here resumes the conversation at the same line.
		_toggle_pause()
		get_viewport().set_input_as_handled()
		return
	if _paused or DialogueManager.is_active:
		return
	if event.is_action_pressed("ui_accept") and _nearest != null:
		_nearest.interact()
		get_viewport().set_input_as_handled()


func _set_movement(enabled: bool) -> void:
	if _player != null:
		_player.can_move = enabled and not _paused and not DialogueManager.is_active


func _toggle_pause() -> void:
	if _paused:
		_resume()
	else:
		_paused = true
		get_tree().paused = true
		_set_movement(false)
		_show_pause_menu()


func _resume() -> void:
	var layer := get_node_or_null("PauseLayer")
	if layer != null:
		layer.queue_free()
	_paused = false
	get_tree().paused = false
	_set_movement(true)


func _show_pause_menu() -> void:
	var overlay := Control.new()
	overlay.name = "PauseOverlay"
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	var layer := CanvasLayer.new()
	layer.layer = 20
	layer.name = "PauseLayer"
	layer.add_child(overlay)
	add_child(layer)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(center)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	center.add_child(vbox)

	var resume := _menu_button("Resume")
	resume.pressed.connect(_resume)
	vbox.add_child(resume)

	var save := _menu_button("Save")
	save.pressed.connect(func():
		GameState.current_scene = scene_file_path
		GameState.player_pos = _player.position
		var ok := GameState.save_game()
		save.text = "Saved ✓" if ok else "Save failed")
	vbox.add_child(save)

	var settings := _menu_button("Settings")
	settings.pressed.connect(func():
		overlay.add_child(preload("res://scenes/ui/settings.tscn").instantiate()))
	vbox.add_child(settings)

	var menu := _menu_button("Main Menu")
	menu.pressed.connect(func():
		get_tree().paused = false
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn"))
	vbox.add_child(menu)

	resume.grab_focus()


func _menu_button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(200, 40)
	button.add_theme_font_size_override("font_size", 20)
	return button
