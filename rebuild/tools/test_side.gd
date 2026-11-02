extends SceneTree
func _initialize() -> void:
	var p := "res://assets/models/archer.aabb.json"
	print("exists=", FileAccess.file_exists(p))
	if FileAccess.file_exists(p):
		var s := FileAccess.get_file_as_string(p)
		print("len=", s.length(), " head=", s.substr(0, 60))
		var v: Variant = JSON.parse_string(s)
		print("parsed=", v != null, " min=", v.get("min") if v is Dictionary else null)
	quit(0)
