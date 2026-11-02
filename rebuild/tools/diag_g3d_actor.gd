extends SceneTree
## Isolated GrannyActor3D render for one model (FINAL-03 vortex_book check).
## Run: Godot_console --path rebuild --script tools/diag_g3d_actor.gd
## env: MODEL=<uri or glb stem> TEX=<res path> OUT=<abs png>

func _find(n: Node, t: String) -> Node:
	if n.get_class() == t:
		return n
	for c in n.get_children():
		var r := _find(c, t)
		if r != null:
			return r
	return null

var g3d: Node2D
var _f := 0
var _out := ""

func _initialize() -> void:
	var model := OS.get_environment("MODEL")
	if model == "":
		model = "mesh/objects/spells/vortex_book.gr2"
	if not model.contains("/"):
		model = "mesh/objects/units/%s.gr2" % model
	var tex_path := OS.get_environment("TEX")
	if tex_path == "":
		tex_path = "res://assets/units/%s.png" % GrannyActor3D.glb_stem_for_model(model)
	_out = OS.get_environment("OUT")
	if _out == "":
		_out = ProjectSettings.globalize_path("res://../work/analysis/diag_g3d_actor.png")
	g3d = GrannyActor3D.new()
	var ok: bool = g3d.setup(model, load(tex_path))
	print("[diag] setup ok=", ok, " aabb=", g3d._frame_aabb)
	if ok and g3d._anim != null:
		print("[diag] clips=", g3d._anim.get_animation_list())
		if g3d._anim.has_animation("idle"):
			g3d.play_clip("idle", false)
	root.add_child(g3d)

func _process(_dt: float) -> bool:
	_f += 1
	# sample the idle clip at ~0.3 / 1.2 / 2.1 / 3.0 s: book presence timeline
	for i in 4:
		if _f == 20 + i * 55:
			var vp := _find(g3d, "SubViewport") as SubViewport
			if vp != null:
				var img := vp.get_texture().get_image()
				var out := _out.replace(".png", "_t%d.png" % i)
				img.save_png(out)
				var npx := 0
				for y in range(0, img.get_height(), 3):
					for x in range(0, img.get_width(), 3):
						if img.get_pixel(x, y).a > 0.1:
							npx += 1
				var ap: AnimationPlayer = _find(g3d, "AnimationPlayer")
				print("[diag] t%d f=%d animpos=%.2f opaque-sample-px=%d -> %s" % [
					i, _f, ap.current_animation_position if ap != null else -1.0,
					npx, out.get_file()])
	if _f < 190:
		return false
	quit(0)
	return true

func _collect_mi(n: Node, out: Array) -> void:
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		_collect_mi(c, out)
