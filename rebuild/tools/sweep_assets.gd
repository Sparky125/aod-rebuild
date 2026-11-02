extends SceneTree
## Full asset-load sweep. Two modes:
##   1. SOURCE mode (run with --path rebuild): walks res://assets + res://data
##      on disk and loads every file.
##   2. PACK mode: env PCK_LIST points at a newline list of pck entry names
##      and PCK_MOUNT at a .pck to mount first; loads every listed entry.
## Prints every failure; exit code 1 if any fail.

var _fails: Array[String] = []
var _ok := 0

func _initialize() -> void:
	var mount := OS.get_environment("PCK_MOUNT")
	var list_path := OS.get_environment("PCK_LIST")
	var raw_exts := [".json", ".txt", ".obj"]

	if mount != "":
		var ok := ProjectSettings.load_resource_pack(mount, true)
		print("[sweep] mount %s -> %s" % [mount, ok])
		if not ok:
			quit(1)
			return

	var paths: Array[String] = []
	if list_path != "":
		var f := FileAccess.open(list_path, FileAccess.READ)
		while not f.eof_reached():
			var line := f.get_line().strip_edges()
			if line != "":
				paths.append(line if line.begins_with("res://") else "res://" + line)
	else:
		_walk("res://assets", paths)
		_walk("res://data", paths)

	var skipped := 0
	for p in paths:
		if p.ends_with(".import") or p.ends_with(".uid") or p.ends_with("/"):
			skipped += 1
			continue
		if p.begins_with("res://scripts/") or p.begins_with("res://index.") \
				or p.begins_with("res://.godot/exported/") \
				or p.ends_with("project.binary") or p.contains("global_script_class_cache"):
			# code/manifest entries: exercise the whole-project browser run instead
			skipped += 1
			continue
		var is_raw := false
		for e in raw_exts:
			if p.ends_with(e):
				is_raw = true
				break
		if is_raw:
			var txt := FileAccess.get_file_as_string(p)
			if txt.is_empty():
				_fails.append(p + "  (raw read empty)")
			else:
				_ok += 1
			continue
		if p.ends_with(".json"):
			var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
			if parsed == null:
				_fails.append(p + "  (json parse failed)")
			else:
				_ok += 1
			continue
		if not ResourceLoader.exists(p):
			_fails.append(p + "  (exists=false)")
			continue
		var res := load(p)
		if res == null:
			_fails.append(p + "  (load=null)")
		else:
			_ok += 1

	print("[sweep] OK=%d  FAIL=%d  skipped(sidecars/dirs)=%d" % [_ok, _fails.size(), skipped])
	for f in _fails:
		print("[sweep] FAIL: ", f)
	quit(1 if _fails.size() > 0 else 0)

func _walk(dir_path: String, out: Array[String]) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		_fails.append(dir_path + "  (dir open failed)")
		return
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		var full := dir_path + "/" + n
		if d.current_is_dir():
			_walk(full, out)
		else:
			out.append(full)
		n = d.get_next()
	d.list_dir_end()
