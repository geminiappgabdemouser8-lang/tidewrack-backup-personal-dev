extends Node
## Journal — discovered-logs system.
##
## Autoloaded as `Journal` (project.godot). Dialogue nodes with a
## `"discover": "<entry id>"` key record an entry here as they are entered;
## GameState persists the entry list in the save file. Storage only — the
## reader screen is still to come.

signal entry_added(id: String)

var _entries: Array[String] = []


func discover(id: String) -> void:
	if id == "" or id in _entries:
		return
	_entries.append(id)
	entry_added.emit(id)


func entries() -> Array[String]:
	return _entries.duplicate()


func has(id: String) -> bool:
	return id in _entries


## Replace the entry list wholesale (used by GameState on load / new game).
func restore(ids: Array) -> void:
	_entries.clear()
	for id in ids:
		if str(id) != "" and not str(id) in _entries:
			_entries.append(str(id))
