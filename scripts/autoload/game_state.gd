extends Node
## GameState — global save/load and story flags.
##
## Autoloaded as `GameState`. Holds the narrative flags set by dialogue
## choices plus everything "Continue" needs to put the player back where they
## were, and persists it all to user://save.json.
##
## Save file (version 2). `flags` is unchanged from version 1 and version-1
## files still load — every other key is optional.
##   { "version": 2,
##     "scene":    "res://scenes/game.tscn",
##     "flags":    { "trusted_edith": true, ... },
##     "dialogue": { "path": "res://data/dialogue/keeper_intro.json", "node": "logbook_2" } | null,
##     "journal":  [ "entry_id", ... ],
##     "progress": { "player_pos": {"x": 640.0, "y": 540.0}, "examined": ["logbook"] } }

signal state_changed

const SAVE_PATH := "user://save.json"
const SAVE_VERSION := 2
const DEFAULT_SCENE := "res://scenes/game.tscn"

## Where the save lives. Overridable so tests never touch the real save.
var save_path: String = SAVE_PATH

## Story flags set during play, e.g. {"trusted_edith": true}.
var flags: Dictionary = {}
## Path of the scene the player should resume into.
var current_scene: String = DEFAULT_SCENE

## --- Resume state (written by the level, read back by it after a load) ---
## Where the player was standing. Null until the level reports it.
var player_pos: Variant = null
## Ids of interactables the player has already examined, in order.
var examined: Array[String] = []
## Conversation in progress at save time: {"path": String, "node": String}, or
## empty when the player was not in a dialogue.
var dialogue: Dictionary = {}
## True right after a successful load_game(); the level clears it once it has
## applied the resume state, so New Game never inherits a stale position.
var resume_pending: bool = false


func set_flag(name: String, value: Variant) -> void:
	flags[name] = value
	state_changed.emit()


func get_flag(name: String, default: Variant = false) -> Variant:
	return flags.get(name, default)


func mark_examined(id: String) -> void:
	if id == "" or id in examined:
		return
	examined.append(id)
	state_changed.emit()


func is_examined(id: String) -> bool:
	return id in examined


func new_game() -> void:
	flags.clear()
	current_scene = DEFAULT_SCENE
	player_pos = null
	examined.clear()
	dialogue = {}
	resume_pending = false
	var journal := _journal()
	if journal != null:
		journal.restore([])
	state_changed.emit()


func has_save() -> bool:
	return FileAccess.file_exists(save_path)


## Snapshot the in-progress conversation (if any) so it can be resumed.
func capture_dialogue() -> void:
	if DialogueManager.is_active and DialogueManager.current_path() != "":
		dialogue = {"path": DialogueManager.current_path(), "node": DialogueManager.current_id()}
	else:
		dialogue = {}


func save_game() -> bool:
	capture_dialogue()
	var journal := _journal()
	var payload := {
		"version": SAVE_VERSION,
		"scene": current_scene,
		"flags": flags,
		"dialogue": dialogue if not dialogue.is_empty() else null,
		"journal": journal.entries() if journal != null else [],
		"progress": {
			"player_pos": _vec_to_dict(player_pos),
			"examined": examined,
		},
	}
	return _write_atomic(JSON.stringify(payload, "\t"))


## Write to a temp file and rename it over the real one, so save.json is
## always either the previous complete save or the new complete save — never a
## truncated one if the window is closed mid-write.
func _write_atomic(text: String) -> bool:
	var tmp_path := save_path + ".tmp"
	var file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		push_error("GameState: could not open save file for writing.")
		return false
	file.store_string(text)
	file.close()
	var err := DirAccess.rename_absolute(
		ProjectSettings.globalize_path(tmp_path),
		ProjectSettings.globalize_path(save_path))
	if err != OK:
		push_error("GameState: could not replace save file (error %d)." % err)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp_path))
		return false
	return true


func load_game() -> bool:
	if not has_save():
		return false
	var file := FileAccess.open(save_path, FileAccess.READ)
	if file == null:
		push_error("GameState: could not open save file for reading.")
		return false
	var text := file.get_as_text()
	file.close()

	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("GameState: save file is corrupt.")
		return false
	return apply_save_data(parsed)


## Apply a parsed save dictionary. Split out from load_game() so it can be
## tested without touching the user:// directory. Accepts version 1 and 2.
func apply_save_data(data: Dictionary) -> bool:
	# Scene: fall back to the lighthouse if the stored path no longer exists,
	# so a stale or hand-edited save can never drop the player into an empty scene.
	var scene := str(data.get("scene", DEFAULT_SCENE))
	current_scene = scene if ResourceLoader.exists(scene) else DEFAULT_SCENE

	# Flags: unchanged from version 1.
	var loaded_flags: Variant = data.get("flags", {})
	flags = loaded_flags if typeof(loaded_flags) == TYPE_DICTIONARY else {}

	# Dialogue in progress.
	var loaded_dialogue: Variant = data.get("dialogue", null)
	dialogue = {}
	if typeof(loaded_dialogue) == TYPE_DICTIONARY:
		var path := str(loaded_dialogue.get("path", ""))
		var node := str(loaded_dialogue.get("node", ""))
		if path != "" and node != "" and FileAccess.file_exists(path):
			dialogue = {"path": path, "node": node}

	# Journal entries.
	var journal := _journal()
	if journal != null:
		journal.restore(_string_array(data.get("journal", [])))

	# Level progress.
	var progress: Variant = data.get("progress", {})
	if typeof(progress) != TYPE_DICTIONARY:
		progress = {}
	player_pos = _dict_to_vec(progress.get("player_pos", null))
	examined = _string_array(progress.get("examined", []))

	resume_pending = true
	state_changed.emit()
	return true


func delete_save() -> void:
	if has_save():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path))


## --- helpers ---

func _journal() -> Node:
	# Looked up rather than referenced by name so GameState also works in the
	# headless test harness, where no autoloads are registered.
	return get_node_or_null("/root/Journal")


static func _vec_to_dict(v: Variant) -> Variant:
	if typeof(v) != TYPE_VECTOR2:
		return null
	return {"x": v.x, "y": v.y}


static func _dict_to_vec(d: Variant) -> Variant:
	if typeof(d) != TYPE_DICTIONARY or not d.has("x") or not d.has("y"):
		return null
	return Vector2(float(d["x"]), float(d["y"]))


static func _string_array(v: Variant) -> Array[String]:
	var out: Array[String] = []
	if typeof(v) == TYPE_ARRAY:
		for item in v:
			out.append(str(item))
	return out
