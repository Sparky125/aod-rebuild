extends Node
## Autoload (project.godot: WebStore) — registered there rather than as a
## global class ON PURPOSE: game_state.gd references WebStore during its own
## boot-time load_save(), and a global class only resolves after the editor
## has written the script class cache — which fresh clones don't have yet
## (their first --import failed on exactly that). An autoload resolves from
## project.godot on every machine, first import included.
## Durable mirror of the player's user:// saves/settings on the Web export.
##
## iOS Safari (and home-screen web apps) flush the engine's IndexedDB
## user:// partition unreliably — a page refresh or app relaunch could drop
## save.json entirely. localStorage there is synchronous and survives
## refreshes/restarts, so on Web every save/settings write is mirrored into
## it and the read side prefers the mirror, falling back to the user://
## file (and adopting it into the mirror) when the mirror is empty.
## Desktop/native is untouched: available() is false, every call is a no-op.

func available() -> bool:
	return OS.has_feature("web")

func put(key: String, value: String) -> void:
	if not available():
		return
	var ls: JavaScriptObject = JavaScriptBridge.get_interface("localStorage")
	ls.setItem("aod_" + key, value)

func get_item(key: String) -> String:
	if not available():
		return ""
	var ls: JavaScriptObject = JavaScriptBridge.get_interface("localStorage")
	var v: Variant = ls.getItem("aod_" + key)
	return "" if v == null else str(v)
