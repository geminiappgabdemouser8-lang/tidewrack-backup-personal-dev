extends SceneTree
## Headless save/load checks. Run from the project root:
##
##     godot --headless --path . -s tests/test_save_load.gd
##
## Exits 0 when every check passes, 1 otherwise. Uses user://save_test.json
## so it never touches a real save. Covers:
##   1. a version-1 file (the v0.2-demo-rc shape, tests/fixtures/save_v1.json)
##      still loads and its flags come through untouched;
##   2. a save with a scene path that no longer exists falls back to the
##      lighthouse instead of loading into nothing;
##   3. a full round trip: flags + journal + examined objects + player position
##      + a conversation in progress all survive save → new_game → load;
##   4. the write is atomic (no .tmp left behind, file is complete JSON).

const TEST_SAVE := "user://save_test.json"
const FIXTURE_V1 := "res://tests/fixtures/save_v1.json"

var _failures: Array[String] = []


func _initialize() -> void:
	GameState.save_path = TEST_SAVE
	_cleanup()

	_test_v1_fixture_loads()
	_test_missing_scene_falls_back()
	_test_round_trip()
	_test_atomic_write()

	_cleanup()
	if _failures.is_empty():
		print("✓ save/load: all checks passed")
		quit(0)
	else:
		for f in _failures:
			printerr("✗ " + f)
		printerr("%d check(s) failed" % _failures.size())
		quit(1)


# --- checks -----------------------------------------------------------------

func _test_v1_fixture_loads() -> void:
	var data := _read_json(FIXTURE_V1)
	_check(not data.is_empty(), "v1 fixture is readable")
	GameState.new_game()
	_check(GameState.apply_save_data(data), "v1 fixture applies")
	_check(GameState.flags == data.get("flags", {}), "v1 flags unchanged after load")
	_check(GameState.current_scene == GameState.DEFAULT_SCENE, "v1 scene is the lighthouse")
	_check(GameState.dialogue.is_empty(), "v1 has no dialogue to resume")
	_check(GameState.examined.is_empty(), "v1 has no examined objects")
	_check(GameState.player_pos == null, "v1 has no player position")
	_check(Journal.entries().is_empty(), "v1 has no journal entries")
	_check(GameState.resume_pending, "load marks resume pending")


func _test_missing_scene_falls_back() -> void:
	GameState.new_game()
	var data := {"version": 2, "scene": "res://scenes/does_not_exist.tscn", "flags": {}}
	GameState.apply_save_data(data)
	_check(GameState.current_scene == GameState.DEFAULT_SCENE,
		"unknown scene path falls back to the lighthouse")


func _test_round_trip() -> void:
	GameState.new_game()
	GameState.set_flag("trusted_edith", true)
	GameState.set_flag("skeptic", true)
	GameState.mark_examined("logbook")
	GameState.mark_examined("radio")
	GameState.player_pos = Vector2(412.5, 377.0)
	Journal.discover("entry_test_a")
	Journal.discover("entry_test_b")
	var started := DialogueManager.start("res://data/dialogue/keeper_intro.json", "logbook_2")
	_check(started, "test dialogue starts at logbook_2")
	var flags_before := GameState.flags.duplicate(true)

	_check(GameState.save_game(), "save_game succeeds")
	_check(DialogueManager.is_active, "saving does not end the conversation")

	GameState.new_game()
	_check(GameState.flags.is_empty() and Journal.entries().is_empty(),
		"new_game clears state before load")

	_check(GameState.load_game(), "load_game succeeds")
	_check(GameState.flags == flags_before, "flags survive the round trip unchanged")
	_check(GameState.examined == ["logbook", "radio"] as Array[String], "examined objects survive")
	_check(GameState.player_pos == Vector2(412.5, 377.0), "player position survives")
	_check(Journal.entries() == ["entry_test_a", "entry_test_b"] as Array[String],
		"journal entries survive")
	_check(GameState.dialogue.get("path", "") == "res://data/dialogue/keeper_intro.json"
		and GameState.dialogue.get("node", "") == "logbook_2",
		"conversation position survives")

	# Tidy: end the dialogue we started.
	while DialogueManager.is_active:
		DialogueManager.advance()
		if DialogueManager.is_active and DialogueManager.current_id() != "":
			DialogueManager.choose(0)


func _test_atomic_write() -> void:
	GameState.new_game()
	GameState.set_flag("believer", true)
	_check(GameState.save_game(), "second save succeeds")
	_check(not FileAccess.file_exists(TEST_SAVE + ".tmp"), "no .tmp left behind after save")
	var data := _read_json(TEST_SAVE)
	_check(data.get("version", 0) == GameState.SAVE_VERSION, "saved file is complete JSON at current version")
	_check(data.has("flags") and data.has("journal") and data.has("progress"),
		"saved file carries flags, journal and progress")


# --- helpers ----------------------------------------------------------------

func _check(ok: bool, what: String) -> void:
	if not ok:
		_failures.append(what)


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


func _cleanup() -> void:
	for p in [TEST_SAVE, TEST_SAVE + ".tmp"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
