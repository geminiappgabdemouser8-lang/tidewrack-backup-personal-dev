extends Node
## Journal — discovered-logs system (Public Demo scaffold).
##
## Autoloaded as `Journal` (project.godot). As the player examines objects, the
## dialogue "set_flag" hooks will record discovered entries here; the journal
## screen renders them. Scaffold only: storage + a couple of helpers, no UI yet.

signal entry_added(id: String)

var _entries: Array[String] = []


func discover(id: String) -> void:
	if id in _entries:
		return
	_entries.append(id)
	entry_added.emit(id)


func entries() -> Array[String]:
	return _entries.duplicate()


func has(id: String) -> bool:
	return id in _entries
# TODO(demo): persist entries through GameState.save_game() and add the reader UI.
