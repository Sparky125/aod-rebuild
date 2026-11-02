extends SceneTree
## One-shot PNG -> WebP converter for the itch.io size pass.
##
## Run later by the human (from the repo root, the folder that contains rebuild/):
##   godot --headless --path rebuild --script tools/convert_png_to_webp.gd
##
## Per-directory / per-unit safety filter (substring match on the res:// path):
##   ONLY=unit_frames        godot --headless --path rebuild --script tools/convert_png_to_webp.gd
##   ONLY=unit_frames/ash    (a single unit)
##   ONLY=ui                 (just the UI art)
## The filter is read from the ONLY environment variable, e.g. in bash:
##   ONLY=unit_frames/ash godot --headless --path rebuild --script tools/convert_png_to_webp.gd
##
## Behaviour:
##   * Converts each .png to a .webp NEXT TO it (lossy, quality 0.85).
##   * Does NOT delete or modify the source .png (delete manually after
##     verification; also delete the orphaned *.png.import sidecars then, or
##     let `godot --headless --path rebuild --import` clean them up).
##   * Appends every converted path to tools/webp_converted.txt (one res://
##     path per line, deduplicated across runs) — that manifest feeds
##     tools/rewrite_png_refs.sh.
##   * Prints a per-top-directory summary table and exits 0.
##
## NOTE ON API: Godot 4 removed the Godot-3 instance methods
## Image.load_png()/load_jpg()/load_webp(); the replacement is the static
## Image.load_from_file(). Saving keeps the instance form
## Image.save_webp(path, lossy, quality). No Godot executable is run while
## authoring this script; it is only executed by the human afterwards.

const DIRS: Array[String] = [
	"res://assets/unit_frames",
	"res://assets/ui",
	"res://assets/map",
	"res://assets/units",
	"res://assets/ammo",
	"res://assets/debris",
	"res://assets/fx",
	"res://assets/items",
]

## Textures parked at the assets/ root (not inside a subdirectory). They are
## included so that after conversion the ENTIRE assets tree is webp — that is
## what lets tools/rewrite_png_refs.sh safely rewrite bare basenames such as
## "gate.png" (both assets/gate.png and assets/map/gate.png become .webp).
const EXTRA_FILES: Array[String] = [
	"res://assets/gate.png",
	"res://assets/menu_bg.png",
]

## Never touched: assets/models (.glb), assets/audio, assets/video, assets/fonts.
const MANIFEST_PATH := "res://tools/webp_converted.txt"
const WEBP_QUALITY := 0.85

# per-top-directory stats: label -> {count, before, after}
var _stats: Dictionary = {}


func _initialize() -> void:
	var only := OS.get_environment("ONLY")
	if only != "":
		print("ONLY filter: '%s' (substring match on res:// path)" % only)

	# --- collect .png files -------------------------------------------------
	var files: Array[String] = []
	for dir in DIRS:
		_walk(dir, files)
	for extra in EXTRA_FILES:
		if FileAccess.file_exists(extra):
			files.append(extra)
	files.sort()

	# --- load prior manifest so incremental ONLY= runs accumulate -----------
	var manifest: Dictionary = {}  # res:// png path -> true
	var mf := FileAccess.open(MANIFEST_PATH, FileAccess.READ)
	if mf != null:
		while not mf.eof_reached():
			var line := mf.get_line().strip_edges()
			if line != "":
				manifest[line] = true
		mf.close()

	var converted: Array = []       # of {png, rel, before, after}
	var skipped: int = 0
	var new_entries: Array[String] = []

	for res_path in files:
		var rel := res_path.trim_prefix("res://")
		if only != "" and rel.find(only) == -1:
			continue
		if manifest.has(res_path):
			print("SKIP (already in manifest, delete the entry if re-converting is wanted): %s" % rel)
			continue

		var png_gpath := ProjectSettings.globalize_path(res_path)
		var img := Image.load_from_file(png_gpath)
		if img == null:
			print("WARN: failed to load png, skipping: %s" % rel)
			skipped += 1
			continue

		var webp_res := res_path.trim_suffix(".png") + ".webp"
		var webp_gpath := ProjectSettings.globalize_path(webp_res)
		var before := _file_size(png_gpath)
		var err := img.save_webp(webp_gpath, true, WEBP_QUALITY)
		if err != OK:
			print("WARN: save_webp failed (%s), skipping: %s" % [error_string(err), rel])
			skipped += 1
			continue
		var after := _file_size(webp_gpath)

		converted.append({"png": res_path, "rel": rel, "before": before, "after": after})
		if not manifest.has(res_path):
			manifest[res_path] = true
			new_entries.append(res_path)
		_bump(rel, before, after)

	# --- rewrite the manifest (existing + new, sorted, one path per line) ---
	var all_paths: Array[String] = []
	for p in manifest.keys():
		all_paths.append(p)
	all_paths.sort()
	var mf_out := FileAccess.open(MANIFEST_PATH, FileAccess.WRITE)
	if mf_out == null:
		print("WARN: could not write manifest %s" % MANIFEST_PATH)
	else:
		for p in all_paths:
			mf_out.store_line(p)
		mf_out.close()

	# --- summary table ------------------------------------------------------
	print("")
	print("=== PNG -> WebP conversion summary (lossy q%.2f) ===" % WEBP_QUALITY)
	if only != "":
		print("(ONLY='%s' — only matching files were converted)" % only)
	print("%-24s %8s %12s %12s %8s %8s" % ["top dir", "count", "MB before", "MB after", "saved", "ratio"])
	var tot_before := 0
	var tot_after := 0
	var tot_count := 0
	var labels: Array[String] = []
	for k in _stats.keys():
		labels.append(k)
	labels.sort()
	for label in labels:
		var s: Dictionary = _stats[label]
		tot_before += int(s["before"])
		tot_after += int(s["after"])
		tot_count += int(s["count"])
		var saved := int(s["before"]) - int(s["after"])
		var ratio := 100.0 * float(saved) / maxf(1.0, float(s["before"]))
		print("%-24s %8d %12.2f %12.2f %7.2f %7.1f%%" % [
			label, s["count"], float(s["before"]) / 1048576.0,
			float(s["after"]) / 1048576.0, float(saved) / 1048576.0, ratio])
	var tot_saved := tot_before - tot_after
	var tot_ratio := 100.0 * float(tot_saved) / maxf(1.0, float(tot_before))
	print("%-24s %8d %12.2f %12.2f %7.2f %7.1f%%" % [
		"TOTAL", tot_count, float(tot_before) / 1048576.0,
		float(tot_after) / 1048576.0, float(tot_saved) / 1048576.0, tot_ratio])
	print("")
	print("Converted %d file(s); skipped %d; manifest %s now holds %d path(s) (%d new)."
		% [converted.size(), skipped, MANIFEST_PATH, all_paths.size(), new_entries.size()])
	print("Next step: review the table, then run tools/rewrite_png_refs.sh,")
	print("verify the game, THEN delete the .png files (and their .png.import")
	print("sidecars) and run: godot --headless --path rebuild --import")
	quit(0)


## Recursively append every .png under dir_path to out.
func _walk(dir_path: String, out: Array[String]) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		print("WARN: cannot open directory, skipping: %s" % dir_path)
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		var child := dir_path.path_join(name)
		if d.current_is_dir():
			if not name.begins_with("."):
				_walk(child, out)
		elif name.to_lower().ends_with(".png"):
			out.append(child)
		name = d.get_next()
	d.list_dir_end()


func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var len := f.get_length()
	f.close()
	return int(len)


## bucket = "assets/<first component>" (or "assets/<file>" for the root extras)
func _bump(rel: String, before: int, after: int) -> void:
	var parts := rel.split("/")
	var label := "assets"
	if parts.size() >= 2:
		label = "%s/%s" % [parts[0], parts[1]]
	if not _stats.has(label):
		_stats[label] = {"count": 0, "before": 0, "after": 0}
	_stats[label]["count"] += 1
	_stats[label]["before"] += before
	_stats[label]["after"] += after
