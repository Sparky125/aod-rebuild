extends Node
## Test/screenshot harness (no-op in normal play). Enabled via user args:
##   --smoke-test                 fast-forward + auto-player, PASS/FAIL exit
##   --wave=N                     start at wave N
##   --screenshot-after=N         capture the viewport N frames in
##   --screenshot=path.png        where to save it
##   --quit-after=T               quit T seconds in
##   --bgeditor                   R14-17 graphical bg-piece editor overlay
##                                (needs --sandbox: --sandbox --bgeditor);
##                                drag pieces, E exports bg pieces to
##                                data/bg_piece_overrides.json.  R14-18:
##                                also edits the map fixture pieces (moon +
##                                pit trio).  R14-19: torch flames export to
##                                data/torch_overrides.json (their glow
##                                pools ride the drag), masks are pickable
##                                like everything else, labels carry kind
##                                tags — every scenery sprite is editable.
##                                R14-20: D deletes/restores the selected
##                                piece (riders hide with it; a torch rank
##                                exports "enabled": false), V clones it
##                                (topmost copy, re-grabbed; both files gain
##                                a top-level "clones" array)
##   --bgmasks                    no-op since R14-19 (masks always editable);
##                                accepted for launch compatibility
##   --bgauto=leaf:dx:dy[:act]    with --bgeditor: scripted drag through the
##                                real input path (QA shots; prints the
##                                verdict; leaf may be any piece incl.
##                                torch_<rank>).  act (R14-20): "" drag only,
##                                "d" click+DELETE+E, "dr" +RESTORE, "v"
##                                click+CLONE (the drag moves the clone)
##   --gatetest                   R14-23 gate-assembly probe (run under
##                                --smoke-test --wave=1): stages one sword
##                                skeleton outside the gate's strike band
##                                and asserts it walks to the cage's CURRENT
##                                seat (gate.x + weapon_range) and hits it
##                                there — proves gate_dx moves the enemy
##                                target; --screenshot captures the strike

var args := {}
var _frames := 0
var _wall_t := 0.0
var _sim_time := 0.0
var _last_report := 0.0
var _bot_tick := 0.0
var _main: Node2D
var _shot := false
var _finished := false
var _pit_t := 1.0
var _spell_t := 0.0
var _cast_t := 0.0
var _vdump_t := 0.0  # --vortexdump wall timer (fires at 4.0, after a :3 cast)
var _menu_t := 0.0
var _last_melee_state := -1  # T35 switch watcher: -1 unset / 0 gun / 1 melee
# --healertest probe state
var _ht_staged := false
var _ht_wm: Unit = null
var _ht_patient: Unit = null
var _ht_skel: Unit = null
var _ht_frames := 0
var _ht_enemy_max := 0.0
var _ht_fail := false
# --newgameflow probe state
var _ngf_step := 0
var _ngf_t := 0.0
var _ngf_fail := false
# --ashtrack probe state: min/max Ash x sampled every 0.5 s wall (pair with --cam-x to command the walkable extremes).
var _track_t := 0.0
var _ash_min_x := 1e12
var _ash_max_x := -1e12
# --gatetest probe state: one staged skeleton vs the Necronomicon gate
var _gt_skel: Unit = null
var _gt_t := 0.0
var _gt_total := 0.0
var _gt_done := false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS  # keep running while the pause menu holds the tree
	for a: String in OS.get_cmdline_user_args():
		if not a.begins_with("--"):
			continue
		var kv := a.substr(2).split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "true"
	if not args.is_empty():
		# cap to 60fps so the frame-based flags (--screenshot-after/--quit-after/--killat) keep their 60fps meaning — an uncapped windowed run renders ~2.4x faster and every frame-timed aid fires early.
		Engine.max_fps = 60
	if args.has("smoke-test"):
		GameState.reset_run()
		Engine.time_scale = 12.0
		if args.has("wave"):
			GameState.current_wave = int(args["wave"])
		# fake meta progression: by wave N a player has earlier-wave gold spent on upgrades.
		var w: int = GameState.current_wave
		for t in ["peasant", "swordsman", "archer", "spearman", "ash", "necronomicon"]:
			GameState.set_type_level(t, clampi(w, 1, 10))
		GameState.set_type_level("inner_wall_archer", clampi(w / 7, 0, 4))
		GameState.set_type_level("smithy", clampi(w / 10 + 1, 1, 3))
		GameState.set_type_level("catapults", clampi(w / 21, 0, 3))
		# seed the wave-9 auto-select end-state so the bot's summons pass summon_ally's selected_units gate (the TRAY still renders only unlocked units); without this seed wave 1 times out — the bot summoned nothing.
		GameState.selected_units = ["peasant", "swordsman", "spearman", "archer", "swordboy"]
		# --ashmelee[=chainsaw|iron_fist]: grant the melee weapon for this run (fresh locks keep Ash gun-only).
		if args.has("ashmelee"):
			var wn := str(args["ashmelee"])
			if wn == "true":
				wn = "chainsaw"
			GameState.weapon_locks[wn] = false
	if args.has("keyprobe"):
		# keyboard-binding probe: smoke-style memory isolation + fake progression but WITHOUT --smoke-test — the 12x bot's summons/casts would race the probe's counts; runs at 1x, save-inert like every harness run.
		GameState.reset_run()
		Engine.time_scale = 1.0
		var kw: int = int(args["wave"]) if args.has("wave") else 6
		GameState.current_wave = kw
		for t in ["peasant", "swordsman", "archer", "spearman", "ash", "necronomicon"]:
			GameState.set_type_level(t, clampi(kw, 1, 10))
		GameState.set_type_level("smithy", 1)
		GameState.selected_units = ["peasant", "swordsman", "spearman", "archer", "swordboy"]
	if args.has("fresh"):
		# --fresh: memory-only reset — the persisted save file itself is never touched.
		GameState.clear_save()
	if args.has("pausetest"):
		# wave-label probe: boots at wave 22 (pass --wave so the title screen is skipped), asserts the per-open label re-bake, the stale-52 -> 51 endless pin and the "Wave ∞" sentinel; save-inert, 1x, quit(0/1) after the optional capture.
		GameState.reset_run()
		Engine.time_scale = 1.0
		GameState.current_wave = int(args["wave"]) if args.has("wave") else 22
		for t in ["peasant", "swordsman", "archer", "spearman", "ash", "necronomicon"]:
			GameState.set_type_level(t, clampi(GameState.current_wave, 1, 10))
		GameState.set_type_level("smithy", 1)
		GameState.selected_units = ["peasant", "swordsman", "spearman", "archer", "swordboy"]
	if args.has("devcastle"):
		# force castle defenses on (AFTER fresh's reset so the forced levels survive a --fresh run).
		GameState.set_type_level("inner_wall_archer", 4)
		GameState.set_type_level("catapults", 2)
		GameState.add_gold(5000)
	if args.has("bgeditor") and not args.has("sandbox"):
		print("[bgeditor] --bgeditor needs --sandbox: relaunch with --sandbox --bgeditor")
	if args.has("seed"):
		# --seed=N: deterministic RNG for reproducible debris-pick traces
		seed(int(args["seed"]))
	# keyprobe/pausetest isolate themselves above — the real save must not even be READ into runs whose assertions assume the seeded progression.
	if not args.has("smoke-test") and not args.has("fresh") \
			and not args.has("keyprobe") and not args.has("pausetest"):
		GameState.load_save()

func _process(dt: float) -> void:
	_frames += 1
	_wall_t += dt

	# --shot-at=S: capture S process-seconds in (the frame-based --screenshot-after misfires in uncapped windowed runs).
	if args.has("shot-at") and _wall_t >= float(args["shot-at"]) and not _shot:
		_shot = true
		_capture(args.get("screenshot", "screenshot.png"))

	if args.has("screenshot-after") and _frames >= int(args["screenshot-after"]) and not _shot:
		_shot = true
		_capture(args.get("screenshot", "screenshot.png"))

	# --hitprobe=X,Y: print every visible, input-eating Control covering each game-space point (tree order = draw order; the LAST match wins input).
	if args.has("hitprobe") and _frames == 60:
		for part in str(args["hitprobe"]).split(";"):
			var pp := part.split(",")
			var hp := Vector2(float(pp[0]), float(pp[1]))
			print("[hitprobe] point ", hp)
			_probe_total = 0
			_hitprobe_walk(get_tree().root, hp, 0)
			print("[hitprobe]   controls walked: ", _probe_total)
			var hud: Node = get_tree().current_scene.get("hud") if get_tree().current_scene != null else null
			print("[hitprobe]   hud=", hud, " hud_class=", hud.get_class() if hud != null else "-",
				" hud_visible=", hud.visible if hud != null and "visible" in hud else "-")

	# --push=N: fire the horde push (banner + crest pulse) once at frame N — screenshot aid.
	if args.has("push"):
		var pm: Node2D = get_tree().current_scene
		if pm != null and pm.get("hud") != null and pm.hud != null:
			if _frames >= int(args["push"]):
				args.erase("push")  # once
				print("[dbg] push fired at frame ", _frames)
				pm.hud.flash_push()

	if args.has("quit-after") and _frames / 60.0 >= float(args["quit-after"]):
		get_tree().quit(0)

	# --cam-x=X: walk Ash to x (works in smoke too).
	if args.has("cam-x"):
		var mc: Node2D = get_tree().current_scene
		if mc != null and mc.get("ash") != null and mc.ash != null and mc.ash.state != Unit.State.DEAD:
			mc.ash.walk_in_x = float(args["cam-x"])
			mc.ash.state = Unit.State.WALK_IN

	# --ashtrack: sample Ash's x every 0.5 s wall clock and keep min/max (final line prints on quit-after).
	if args.has("ashtrack"):
		var am: Node2D = get_tree().current_scene
		if am != null and am.get("ash") != null and am.ash != null \
				and is_instance_valid(am.ash) and am.ash.state != Unit.State.DEAD:
			_ash_min_x = minf(_ash_min_x, am.ash.position.x)
			_ash_max_x = maxf(_ash_max_x, am.ash.position.x)
			_track_t += dt
			if _track_t >= 0.5:
				_track_t = 0.0
				print("[ashtrack] t=%.1f x=%.1f walk_in_x=%.1f state=%d min=%.1f max=%.1f" % [
					_sim_time, am.ash.position.x, am.ash.walk_in_x, am.ash.state,
					_ash_min_x, _ash_max_x])

	# on every hero melee/gun transition, print the center-to-center switch distance (any mode with --ashmelee).
	if args.has("ashmelee"):
		var wm: Node2D = get_tree().current_scene
		if wm != null and wm.get("ash") != null and wm.ash != null \
				and wm.ash.state != Unit.State.DEAD and wm.ash.target != null \
				and is_instance_valid(wm.ash.target):
			var wdx: float = absf(wm.ash.target.position.x - wm.ash.position.x)
			if int(wm.ash._active_melee) != _last_melee_state:
				_last_melee_state = int(wm.ash._active_melee)
				print("[t35] switch -> %s at adx=%.1f (melee_range=%.0f gun_range=%.0f)" % [
					"MELEE" if _last_melee_state == 1 else "GUN", wdx,
					wm.ash.melee_range, wm.ash.weapon_range])

	# --duel=F[:dist[:ashx]]: at frame F send Ash to x=ashx and spawn an L7 sword skeleton dist to his RIGHT (the [t35] watcher prints the gun/melee transitions).
	if args.has("duel"):
		var dm: Node2D = get_tree().current_scene
		if dm != null and dm.get("spawner") != null and dm.get("ash") != null \
				and dm.ash != null and dm.ash.state != Unit.State.DEAD \
				and _frames >= int(str(args["duel"]).split(":")[0]):
			var sp := str(args["duel"]).split(":")
			var dist := 260.0
			if sp.size() > 1:
				dist = float(sp[1])
			var base_x: float = dm.ash.position.x
			if sp.size() > 2:
				base_x = float(sp[2])
				dm.ash.walk_in_x = base_x
				dm.ash.state = Unit.State.WALK_IN
			args.erase("duel")
			var sk: Unit = dm.spawn_enemy("sword_skeleton", 7)
			sk.position.x = base_x + dist
			sk.walk_in_x = base_x + 20.0
			print("[t35] duel skeleton spawned at x=%.0f (ash->%.0f, melee=%s mr=%.0f gr=%.0f)" % [
				base_x + dist, base_x, dm.ash.melee_weapon_name, dm.ash.melee_range, dm.ash.weapon_range])

	# --ashdie=F: kill Ash at frame F — the died hook must run the defeat flow, not leave an immortal hero (frame-based so it works under smoke too).
	if args.has("ashdie"):
		var ad: Node2D = get_tree().current_scene
		if ad != null and ad.get("ash") != null and _frames >= int(str(args["ashdie"])):
			args.erase("ashdie")
			if ad.ash != null and is_instance_valid(ad.ash) \
					and ad.ash.state != Unit.State.DEAD:
				print("[dbg] ashdie at frame %d" % _frames)
				ad.ash.take_damage(999999, null)

	# --ashhp=F: hold Ash's health at fraction F of max every frame (life-bar screenshot aid).
	if args.has("ashhp"):
		var ah: Node2D = get_tree().current_scene
		if ah != null and ah.get("ash") != null and ah.ash != null \
				and is_instance_valid(ah.ash) and ah.ash.state != Unit.State.DEAD:
			ah.ash.health = maxf(ah.ash.max_health \
				* clampf(float(args["ashhp"]), 0.0, 1.0), 1.0)

	# --defeatflow=F: press the result banner's CONTINUE at frame F and print the routing (defeat: shop at wave > 1, restart at wave 1; victory chains You-Unlocked -> upgrades), plus the tray/chip mouse filters.
	if args.has("defeatflow"):
		var df: Node2D = get_tree().current_scene
		if df != null and df.get("hud") != null and df.hud.overlay != null \
				and _frames >= int(str(args["defeatflow"])):
			args.erase("defeatflow")
			var tray_btn: TextureButton = null
			if not df.hud.unit_buttons.is_empty():
				tray_btn = df.hud.unit_buttons.values()[0]["btn"]
			print("[dbg] defeatflow: wave=%d won=%s overlay=%s tray_filter=%d chip_filter=%d" % [
				GameState.current_wave, df.wave_won, df.hud.overlay.visible,
				tray_btn.mouse_filter if tray_btn != null else -1,
				df.hud.smith_chip.mouse_filter \
				if df.hud.smith_chip != null and is_instance_valid(df.hud.smith_chip) else -1])
			df.hud._on_overlay_button()
			print("[dbg] defeatflow: menus.state=%s wave_over=%s overlay=%s" % [
				df.menus.state, df.wave_over, df.hud.overlay.visible])

	# --healertest (under --smoke-test --wave=3): stage a Wise Man, a damaged swordsman patient past his staff range and a sword skeleton; he must WALK to the out-of-range patient, fire heal shots only at allies, never push past the healed front line; FAIL exit on an enemy heal target or the skeleton's health rising.
	if args.has("healertest"):
		_healertest_tick()

	# --gatetest: gate-assembly probe, run under --smoke-test --wave=1 (docs in _gatetest_tick).
	if args.has("gatetest"):
		_gatetest_tick(dt)

	if not args.has("smoke-test"):
		# --menupreview: open the between-wave screens on demand (screenshots)
		if args.has("menupreview"):
			var mm: Node2D = get_tree().current_scene
			if mm != null and mm.get("menus") != null:
				_menu_t += dt
				if _menu_t >= 1.0 and mm.menus.state == "":
					print("[dbg] menupreview opening upgrades")
					mm.menus.open_upgrades()
					if args.has("menutab"):
						mm.menus._set_tab(str(args["menutab"]))
				# --menuscroll=N: scroll the open shop's list to offset N once (inert without --menupreview).
				if args.has("menuscroll") and _menu_t >= 2.0 \
						and mm.menus.state == "upgrades" \
						and mm.menus._shop_scroll != null:
					mm.menus._shop_scroll.scroll_vertical = int(str(args["menuscroll"]))
					print("[dbg] menuscroll=%d applied (bar max=%d thumb y=%.0f visible=%s)" % [
						int(str(args["menuscroll"])),
						int(mm.menus._shop_scroll.get_v_scroll_bar().max_value),
						mm.menus._shop_thumb.position.y,
						str(mm.menus._shop_thumb.visible)])
					args.erase("menuscroll")
				# --menubuy=OFFSET: scroll the open shop to OFFSET, top gold up IN MEMORY, drive the REAL _buy on the first buyable non-weapon row, print the post-purchase offset (inert without --menupreview).
				if args.has("menubuy") and _menu_t >= 2.5 \
						and mm.menus.state == "upgrades":
					var buy_off := int(str(args["menubuy"]))
					args.erase("menubuy")
					var menus: Node = mm.menus
					if menus._shop_scroll != null:
						menus._shop_scroll.scroll_vertical = buy_off
						print("[dbg] menubuy: scrolled to %d on tab=%s (gold=%d)" % [
							buy_off, menus._tab, GameState.gold])
						GameState.gold = maxi(GameState.gold, 100000)
						var gold_before := GameState.gold
						for eid in menus._tab_entries():
							# skip weapon rows: a weapon buy REMOVES its row, and the offset demo wants an exact match.
							if menus._category_for(eid) == "weapons":
								continue
							var pre := GameState.gold
							menus._buy(str(eid), menus._tab)
							if GameState.gold < pre:
								print("[dbg] menubuy: _buy(%s) charged %d" % [
									str(eid), pre - GameState.gold])
								break
						if GameState.gold == gold_before:
							print("[dbg] menubuy: FAIL nothing bought on tab=%s" % menus._tab)
						var tree := mm.get_tree()
						tree.create_timer(0.25).timeout.connect(func() -> void:
							var now: int = menus._shop_scroll.scroll_vertical \
								if menus._shop_scroll != null else -1
							print("[dbg] menubuy verdict: post-purchase scroll=%d (wanted %d) -> %s" % [
								now, buy_off,
								"PASS" if now == buy_off else "FAIL"]))
				if _menu_t >= 6.0 and mm.menus.state == "upgrades":
					if args.has("menudetail"):
						mm.menus._open_detail(str(args["menudetail"]),
							str(args.get("menutab", "ash")))
					else:
						mm.menus.open_troops()
						print("[dbg] menupreview opening troops (state=%s)" % mm.menus.state)
		# --creditspreview: open the credits roll 1.0 s in (pair with --creditsspeed=N and --shot-at for captures).
		if args.has("creditspreview"):
			var cp: Node2D = get_tree().current_scene
			if cp != null and cp.get("menus") != null:
				_menu_t += dt
				if _menu_t >= 1.0 and cp.menus.state != "credits":
					print("[dbg] creditspreview opening credits (state=%s)" % cp.menus.state)
					cp.menus.open_credits()
		# --optionspreview: open the options screen 1.0 s in; --resetpopup also opens the RESET confirm at 2.0 s; --optcredits presses CREDITS at 3.0 s.
		if args.has("optionspreview"):
			var op: Node2D = get_tree().current_scene
			if op != null and op.get("menus") != null:
				_menu_t += dt
				if _menu_t >= 1.0 and op.menus.state == "main_menu":
					print("[dbg] optionspreview opening options")
					op.menus.open_options()
				if args.has("resetpopup") and _menu_t >= 2.0 \
						and op.menus.state == "options" \
						and not op.menus.reset_popup_open():
					print("[dbg] optionspreview opening reset popup")
					op.menus._open_reset_popup()
				if args.has("optcredits") and _menu_t >= 3.0 \
						and op.menus.state == "options":
					args.erase("optcredits")
					print("[dbg] optionspreview pressing CREDITS")
					op.menus._on_options_credits()
		# --unlockedpreview=WAVE: open the You-Unlocked screen 1.0 s in as if wave WAVE had just been won — the REAL chain minus the battle.
		if args.has("unlockedpreview"):
			var uv: Node2D = get_tree().current_scene
			if uv != null and uv.get("menus") != null:
				_menu_t += dt
				if _menu_t >= 1.0 and uv.menus.state == "main_menu":
					GameState.current_wave = int(str(args["unlockedpreview"]))
					print("[dbg] unlockedpreview: wave=%d -> You Unlocked" % GameState.current_wave)
					uv.menus.on_wave_won()
					uv.menus.open_upgrades()
		# --newgameflow: the reset-flow probe — memory-only, never a disk wipe; boots onto the real main menu, seeds progression IN MEMORY, then drives the real handlers: OPTIONS -> reset -> CANCEL (assert nothing wiped) -> RESET (assert every persisted field fresh + PLAY menu), then the real wave-2 CONTINUE chain from the EMPTY selection and a wave-6 auto-select top-up; quit(0/1).
		if args.has("newgameflow"):
			_newgameflow_tick(dt)
		# --routeprobe=WAVE:win|lose — force the result-banner CONTINUE at frame 30 and print where it lands (the FINAL_WAVE+1 win must open credits and unlock endless; any other win keeps the You-Unlocked -> upgrades chain).
		if args.has("routeprobe"):
			var rp: Node2D = get_tree().current_scene
			if rp != null and rp.get("hud") != null and _frames >= 30:
				var rsp: PackedStringArray = str(args["routeprobe"]).split(":")
				args.erase("routeprobe")
				GameState.current_wave = int(rsp[0])
				var won := rsp.size() > 1 and rsp[1] == "win"
				rp.wave_won = won
				if won:
					rp.menus.on_wave_won()  # main._finish_wave does this on a win
				rp.hud._on_overlay_button()
				print("[dbg] routeprobe: wave=%d won=%s -> menus.state=%s endless_unlocked=%s" % [
					GameState.current_wave, won, rp.menus.state,
					GameState.endless_unlocked])
				get_tree().quit(0)
		# --banner=win|lose[:awarded:collected]: show the result banner on demand — once only; re-firing restarts the tally tweens and keeps their labels at alpha 0.
		if args.has("banner"):
			var bm: Node2D = get_tree().current_scene
			if bm != null and bm.get("hud") != null and bm.hud != null:
				_menu_t += dt
				if _menu_t >= 1.0 and not bm.hud.overlay.visible:
					var bparts := str(args["banner"]).split(":")
					var bawarded := int(bparts[1]) if bparts.size() > 2 else 0
					var bcollected := int(bparts[2]) if bparts.size() > 2 else 0
					bm.hud.show_wave_over(bparts[0] != "lose", bawarded, bcollected)

		# --spell: auto-cast equipped spells for screenshots (at ~10s and ~16s)
		if args.has("spell"):
			var sm: Node2D = get_tree().current_scene
			if sm != null and sm.get("spawner") != null and not sm.wave_over \
					and sm.ash != null and sm.ash.state != Unit.State.DEAD:
				_spell_t += dt
				var equipped: Array = sm.equipped_spells()
				for i in 2:
					var at := 10.0 + 6.0 * float(i)
					if _spell_t >= at and _spell_t - dt < at and i < equipped.size():
						print("[dbg] casting ", equipped[i])
						sm.cast_spell(equipped[i], sm.ash.position.x + 200.0)

		# --cast=<id>[:<sim-s>]: cast one named spell (screenshot aid for spell art that never auto-equips); under --smoke-test all dbg timers run in 12x-scaled sim time.
		if args.has("cast"):
			var smc: Node2D = get_tree().current_scene
			if smc != null and smc.get("spawner") != null and not smc.wave_over \
					and smc.ash != null and smc.ash.state != Unit.State.DEAD:
				var spec: PackedStringArray = str(args["cast"]).split(":")
				var at: float = float(spec[1]) if spec.size() > 1 else 8.0
				_cast_t += dt
				if _cast_t >= at and _cast_t - dt < at:
					print("[dbg] casting ", spec[0])
					smc.cast_spell(spec[0], smc.ash.position.x + 200.0)
		# --vortexdump[=path]: dump the live VortexSuck 3D actor geometry and save the actor's raw SubViewport image, 4 wall-s in (pair with --cast=vortex:3).
		if args.has("vortexdump"):
			var vd: Node2D = get_tree().current_scene
			if vd != null and vd.get("fx_layer") != null:
				_vdump_t += dt
				if _vdump_t >= 4.0:
					args.erase("vortexdump")
					for c2 in vd.fx_layer.get_children():
						var b3d2: Variant = c2.get("_book3d")
						if b3d2 == null or not is_instance_valid(b3d2):
							continue
						var vi2: Image = b3d2._vp.get_texture().get_image()
						vi2.save_png(str(args.get("screenshot", "vortex_vp.png")).get_basename()
							+ "_vp.webp")
						print("[vortexdump] vp image saved")
						var sk2: Node = b3d2._skeleton
						if sk2 != null:
							for bi in [0, 1, 14, 3, 5]:
								print("[vortexdump] bone %d (%s) animated global origin=%s rest=%s" % [
									bi, sk2.get_bone_name(bi),
									(sk2.get_bone_global_pose(bi).origin as Vector3).snapped(Vector3(0.1, 0.1, 0.1)),
									(sk2.get_bone_global_rest(bi).origin as Vector3).snapped(Vector3(0.1, 0.1, 0.1))])
		# --killat=N: kill every battlefield unit at frame N (remains/death-pose checks).
		if args.has("killat"):
			var km: Node2D = get_tree().current_scene
			if km != null and km.get("units_layer") != null:
				if _frames >= int(args["killat"]):
					args.erase("killat")  # once
					var n := 0
					for u in km.units_layer.get_children():
						if u is Unit and u.state != Unit.State.DEAD and not u.is_prop \
								and not u.is_gate and not u.is_hero:
							# gate/hero deaths trigger the defeat flow — skip them so corpse-pose checks stay on the field.
							u.take_damage(999999, null)
							n += 1
					print("[dbg] killat fired at frame %d, killed %d" % [_frames, n])
				return
			else:
				print("[dbg] killat: no units_layer on scene ", km)
		# --burntest=N: ignite every unit at frame N (burn-flame visual checks)
		if args.has("burntest"):
			var bm2: Node2D = get_tree().current_scene
			if bm2 != null and bm2.get("units_layer") != null:
				if _frames >= int(args["burntest"]):
					args.erase("burntest")
					var bn := 0
					for u in bm2.units_layer.get_children():
						if u is Unit and u.state != Unit.State.DEAD and not u.is_prop:
							u.ignite(8.0, null)
							bn += 1
					print("[dbg] burntest ignited %d" % bn)
			else:
				print("[dbg] burntest: no units_layer")
		# (--sandbox-spawn=type,x,team,level already lives in main._start_sandbox)
		# --hitat=F[:N[:DMG]]: bonk up to 2 living enemies for DMG at frame F and every 72 frames after, N times total (killat's non-lethal sibling).
		if args.has("hitat"):
			var hm2: Node2D = get_tree().current_scene
			if hm2 != null and hm2.get("units_layer") != null:
				var hsp: PackedStringArray = str(args["hitat"]).split(":")
				if _frames >= int(hsp[0]):
					var remain := int(hsp[1]) if hsp.size() > 1 else 1
					var hdmg := int(hsp[2]) if hsp.size() > 2 else 12
					var nbonk := 0
					for u in hm2.units_layer.get_children():
						if nbonk >= 2:
							break
						if u is Unit and u.state != Unit.State.DEAD \
								and u.team == Unit.Team.ENEMY and not u.is_prop \
								and not u.is_gate and not u.is_hero:
							u.take_damage(hdmg, null)
							nbonk += 1
					print("[dbg] hitat fired at frame %d: %d bonked for %d" % [_frames, nbonk, hdmg])
					remain -= 1
					if remain <= 0:
						args.erase("hitat")
					else:
						# keep the optional dmg in the reschedule spec
						args["hitat"] = "%d:%d:%d" % [int(hsp[0]) + 72, remain, hdmg]
		# --pausemenu=N: open the ESC pause menu at frame N (screenshot aid)
		if args.has("pausemenu"):
			var km2: Node2D = get_tree().current_scene
			if km2 != null and km2.get("pause_menu") != null and \
					_frames >= int(args["pausemenu"]) and not km2.pause_menu.is_open():
				args.erase("pausemenu")
				km2.pause_menu.toggle()
		# --pausetest: wave-label probe (boot docs in _ready; pair with --wave=22).
		if args.has("pausetest"):
			_pausetest_tick(dt)
		# --keyprobe: injects real InputEventKey presses through the input pipeline and asserts the HUD routes 1-5/6/Q/E (boot docs in _ready; quit(0/1)).
		if args.has("keyprobe"):
			_keyprobe_tick(dt)
		# --ironup=N: press the HUD smithy chip's iron-cap upgrade at frame N.
		if args.has("ironup"):
			var iu: Node2D = get_tree().current_scene
			if iu != null and iu.get("hud") != null and _frames >= int(args["ironup"]):
				args.erase("ironup")
				iu.iron = 100.0
				print("[dbg] ironup pressed, was L", iu.iron_level)
				iu.upgrade_iron_cap()
				iu.hud._on_smith_hover(true)  # leave the UPGRADE pop-out visible
		# --archers=N: force the wall-archer castle upgrade to level N and respawn (posts #1..N by spawn_index).
		if args.has("archers"):
			var am: Node2D = get_tree().current_scene
			if am != null and am.get("wall_archer_posts") != null and _frames >= 5:
				var alvl := clampi(int(str(args["archers"])), 0, 8)
				args.erase("archers")
				print("[dbg] archers level -> ", alvl)
				GameState.set_type_level("inner_wall_archer", alvl)
				am._spawn_wall_archers()
		# --ashmelee[=chainsaw|iron_fist]: grant the melee weapon now (switch threshold + saw/fist bake).
		if args.has("ashmelee"):
			var am2: Node2D = get_tree().current_scene
			if am2 != null and am2.get("ash") != null and am2.ash != null \
					and am2.ash.state != Unit.State.DEAD:
				var wname := str(args["ashmelee"])
				if wname == "true":
					wname = "chainsaw"
				args.erase("ashmelee")
				GameState.weapon_locks[wname] = false
				am2.ash.equip_melee(wname)
				print("[dbg] ashmelee -> %s range=%.0f gun_range=%.0f" % [
					wname, am2.ash.melee_range, am2.ash.weapon_range])
		# --newgame=N: fire the pause menu's RESTART at frame N.
		if args.has("newgame"):
			var ng: Node2D = get_tree().current_scene
			if ng != null and ng.get("pause_menu") != null and _frames >= int(args["newgame"]):
				args.erase("newgame")
				print("[dbg] pause RESTART fired")
				ng.pause_menu._on_restart()
		# --necktie=F: show Ash's magic-words necktie at frame F (bone_tie Sprite3D attach).
		if args.has("necktie"):
			var nt: Node2D = get_tree().current_scene
			if nt != null and nt.get("ash") != null and nt.ash != null \
					and nt.ash.state != Unit.State.DEAD and _frames >= int(str(args["necktie"])):
				args.erase("necktie")
				print("[dbg] necktie shown at frame ", _frames)
				nt.ash.show_necktie()
		if args.has("pitdemo"):
			var pm: Node2D = get_tree().current_scene
			if pm != null and pm.get("spawner") != null and not pm.wave_over:
				_pit_t -= dt
				if _pit_t <= 0.0:
					_pit_t = 2.0
					var u: Unit = pm.spawn_enemy("sword_skeleton", 1)
					u.position.x = pm.pit_x - 180.0
					u.walk_in_x = pm.pit_x - 120.0
					u.take_damage(1, null, 5.0)
		return

	_sim_time += dt
	_main = get_tree().current_scene
	if _main == null or not (_main is Node2D) or _main.get("spawner") == null:
		return
	if _finished:
		return

	if _sim_time - _last_report >= 15.0:
		_last_report = _sim_time
		print("[smoke] t=%.0fs wave=%d iron=%d enemies=%d killed=%d spawned=%d over=%s" % [
			_sim_time, GameState.current_wave, int(_main.iron), _main.enemies_alive(),
			_main.enemies_killed, _main.enemies_spawned_alive, _main.wave_over])
		if _sim_time < 20.0:
			for u in _main.units_layer.get_children():
				if u is Unit:
					print("  [dbg] %-16s team=%d state=%d x=%.0f hp=%.0f range=%.0f tgt=%s" % [
						u.unit_type, u.team, u.state, u.position.x, u.health, u.weapon_range,
						str(u.target)])
			print("  [dbg] probe boomstick range=", DB.get_stat("weapons", "boomstick", "range", 1),
				" ash weapon=", _main.ash.weapon_name,
				" skel weapon=", DB.get_stat("units", "sword_skeleton", "weapon", 7),
				" skel range=", DB.get_stat("weapons", str(DB.get_stat("units", "sword_skeleton", "weapon", 7)), "range", 7),
				" weapons table size=", DB.table("weapons").size())

	# simple player bot: cheap peasants early, then melee + archer
	_bot_tick += dt
	if _bot_tick >= 4.0:
		_bot_tick = 0.0
		for t in ["peasant", "swordsman", "archer", "peasant", "swordsman"]:
			_main.summon_ally(t)
		# skip the casts on a freed hero — after a --defeatflow press, teardown_battle has freed Ash.
		for id: String in _main.equipped_spells():
			if _main.spell_cooldowns.get(id, 0.0) <= 0.0 \
					and _main.ash != null and is_instance_valid(_main.ash):
				_main.cast_spell(id, _main.ash.position.x + 200.0)

	if _main.get("endless_mode") and _main.endless != null:
		# endless never completes: PASS = survived the budget with groups streaming in; wave_over here means gate/Ash fell.
		if _main.wave_over:
			_finished = true
			print("[smoke] FAIL: endless lost at t=%.0fs score=%d challenge=%d" % [
				_sim_time, int(_main.endless.score), _main.endless.challenge])
			get_tree().quit(1)
		elif (_sim_time >= 45.0 and _main.endless.spawned_count >= 5
				and (_shot or not args.has("screenshot-after"))):
			_finished = true
			print("[smoke] PASS: endless survived %.0fs, spawned=%d score=%d challenge=%d killed=%d" % [
				_sim_time, _main.endless.spawned_count, int(_main.endless.score),
				_main.endless.challenge, _main.enemies_killed])
			get_tree().quit(0)
		elif _sim_time > 240.0:
			_finished = true
			print("[smoke] FAIL: endless timeout, spawned=%d" % _main.endless.spawned_count)
			get_tree().quit(1)
		return
	if _main.wave_over:
		# --menu: step through the between-wave screens for screenshots
		if args.has("menu") and _main.menus != null:
			_menu_t += dt
			if _menu_t >= 2.0 and _main.menus.state == "upgrades":
				print("[dbg] opening troops screen")
				_main.menus.open_troops()
		# a pending --screenshot waits for its frame (end-of-wave shots) before the PASS/FAIL quit fires.
		if _shot or not args.has("screenshot-after"):
			_finished = true
			if _main.wave_won:
				print("[smoke] PASS: wave %d cleared, killed=%d/%d, gold=%d, t=%.1fs" % [
					GameState.current_wave - 1, _main.enemies_killed, _main.get_wave_unit_total(GameState.current_wave - 1),
					GameState.gold, _sim_time])
				get_tree().quit(0)
			else:
				print("[smoke] FAIL: lost the wave (killed=%d/%d)" % [
					_main.enemies_killed, _main.get_wave_unit_total(GameState.current_wave)])
				get_tree().quit(1)
	elif _sim_time > 240.0:
		_finished = true
		print("[smoke] FAIL: timeout, killed=%d/%d spawned=%d" % [
			_main.enemies_killed, _main.get_wave_unit_total(), _main.enemies_spawned_alive])
		get_tree().quit(1)

# ------------------------------------------------------- key probe

var _kp_t := 0.0
var _kp_fail := false

func _kp_check(cond: bool, what: String) -> void:
	print("[r1305] %s %s" % ["OK   " if cond else "FAIL", what])
	if not cond:
		_kp_fail = true

func _kp_key(keycode: int, echo := false) -> void:
	## injects one press (+ release) through the REAL input pipeline (Input.parse_input_event -> viewport routing -> hud._unhandled_input).
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.physical_keycode = keycode
	ev.pressed = true
	ev.echo = echo
	Input.parse_input_event(ev)
	var rl := InputEventKey.new()
	rl.keycode = keycode
	rl.physical_keycode = keycode
	rl.pressed = false
	Input.parse_input_event(rl)
	Input.flush_buffered_events()

func _kp_ally_count() -> int:
	var kp: Node2D = get_tree().current_scene
	var n := 0
	for u in kp.units_layer.get_children():
		if u is Unit and u.team == Unit.Team.ALLY and not u.is_gate \
				and not u.is_hero and not u.is_prop:
			n += 1
	return n

func _kp_count_type(type_name: String) -> int:
	var kp: Node2D = get_tree().current_scene
	var n := 0
	for u in kp.units_layer.get_children():
		if u is Unit and u.unit_type == type_name and u.team == Unit.Team.ALLY \
				and not u.is_gate and not u.is_hero and not u.is_prop:
			n += 1
	return n

func _keyprobe_tick(dt: float) -> void:
	var kp: Node2D = get_tree().current_scene
	if kp == null or kp.get("hud") == null or kp.hud == null:
		return
	if _frames < 30 or kp.wave_over:
		return
	_kp_t += dt
	# every inject is synchronous (parse + flush); the gaps just let cooldowns/tweens settle between steps.
	if _kp_t >= 0.5 and _kp_step_is(0):
		var tray: Array = kp.hud.unit_buttons.keys()
		var equipped: Array = kp.equipped_spells()
		print("[r1305] wave=%d tray=%s equipped=%s iron=%d iron_level=%d" % [
			GameState.current_wave, str(tray), str(equipped),
			int(kp.iron), kp.iron_level])
		_kp_check(tray == ["peasant", "swordsman", "spearman", "archer"],
			"wave-6 tray renders 4 gate-passing slots (got %s)" % str(tray))
		_kp_check(equipped == ["super_boomstick_blast", "vortex"],
			"2 spells equipped for Q/E (got %s)" % str(equipped))
		_kp_check(kp.hud.spell_buttons[0]["btn"].is_visible_in_tree()
			and kp.hud.spell_buttons[1]["btn"].is_visible_in_tree(),
			"both spell plates visible at wave 6")
		kp.iron = 100.0
		_kp_t = 0.0
		return
	# --- BANNER gate: the wave-over flag + the real defeat banner must kill every binding (upgrade_iron_cap/cast_spell do NOT self-gate wave_over).
	if _kp_t >= 0.4 and _kp_step_is(1):
		kp.wave_over = true
		kp.hud.show_wave_over(false, 0, 0)  # defeat banner: no gold/wave side effects
		var pre := _kp_ally_count()
		_kp_key(KEY_2)
		_kp_key(KEY_6)
		_kp_key(KEY_Q)
		_kp_check(_kp_ally_count() == pre and kp.iron_level == 1
			and kp.spell_cooldowns.get("super_boomstick_blast", 0.0) == 0.0
			and kp.spell_cooldowns.get("vortex", 0.0) == 0.0,
			"banner up: key 2/6/Q all dead (allies=%d iron_level=%d cds unset)" % [
			pre, kp.iron_level])
		kp.wave_over = false
		kp.hud.overlay.visible = false
		kp.hud._blood.visible = false
		_kp_t = 0.0
		return
	# --- MENU gate: the between-wave shop draws over the HUD
	if _kp_t >= 0.2 and _kp_step_is(2):
		kp.menus.open_upgrades()  # _from_win is false -> straight to the shop
		_kp_check(kp.menus.is_open(), "upgrades shop open (state=%s)" % kp.menus.state)
		var pre := _kp_ally_count()
		_kp_key(KEY_2)
		_kp_key(KEY_6)
		_kp_key(KEY_Q)
		_kp_check(_kp_ally_count() == pre and kp.iron_level == 1
			and kp.spell_cooldowns.get("super_boomstick_blast", 0.0) == 0.0,
			"menus open: key 2/6/Q all dead")
		kp.menus.close()
		_kp_t = 0.0
		return
	# --- PAUSE gate: a paused tree delivers the HUD no input at all
	if _kp_t >= 0.2 and _kp_step_is(3):
		kp.pause_menu.toggle()  # pauses the tree
		var pre := _kp_ally_count()
		_kp_key(KEY_2)
		_kp_check(_kp_ally_count() == pre and kp.pause_menu.is_open(),
			"pause menu up: key 2 dead")
		kp.pause_menu.toggle()  # unpauses
		_kp_t = 0.0
		return
	# --- TRAY keys 1-5: route through the RENDERED plates' pressed signals
	if _kp_t >= 0.2 and _kp_step_is(4):
		kp.iron = 100.0
		_kp_key(KEY_1)
		_kp_check(_kp_count_type("peasant") == 1, "key 1 summons slot 1 (peasant)")
		_kp_key(KEY_2)
		_kp_check(_kp_count_type("swordsman") == 1,
			"key 2 summons slot 2 (swordsman) when 2+ slots exist")
		_kp_key(KEY_2)  # the plate is on spawn cooldown now — click-equivalent
		_kp_check(_kp_count_type("swordsman") == 1,
			"key 2 re-press during cooldown does nothing (summon_ally gate)")
		_kp_key(KEY_5)  # slot 5 was never rendered (swordboy unlocks at 9)
		_kp_check(_kp_ally_count() == 2,
			"key 5 (unrendered slot) summons nothing (allies=%d)" % _kp_ally_count())
		_kp_key(KEY_4)
		_kp_check(_kp_count_type("archer") == 1, "key 4 summons the LAST rendered slot")
		_kp_t = 0.0
		return
	# --- SMITHY key 6: the chip spends IRON exactly like a click
	if _kp_t >= 0.2 and _kp_step_is(5):
		var lvl: int = kp.iron_level
		var price := int(DB.table("globals").get(
			"iron_level_cap_upgrade_price", [30, 50, 75])[lvl - 1])
		kp.iron = 100.0
		_kp_key(KEY_6)
		_kp_check(kp.iron_level == lvl + 1 and absf(kp.iron - (100.0 - price)) < 0.5,
			"key 6 upgrades the smithy chip (L%d->L%d, iron %.0f->%.0f, price %d)" % [
			lvl, kp.iron_level, 100.0, kp.iron, price])
		kp.iron = 5.0  # below the next tier's price -> the click rejection path
		_kp_key(KEY_6)
		_kp_check(kp.iron_level == lvl + 1 and kp.iron == 5.0,
			"key 6 unaffordable is rejected like a click (no spend)")
		_kp_t = 0.0
		return
	# --- SPELL keys Q/E: the two equipped plates
	if _kp_t >= 0.2 and _kp_step_is(6):
		_kp_key(KEY_Q)
		_kp_check(kp.spell_cooldowns.get("super_boomstick_blast", 0.0) > 0.0,
			"key Q fires spell 1 (super_boomstick_blast cd now %.1f)" % \
			kp.spell_cooldowns.get("super_boomstick_blast", 0.0))
		_kp_key(KEY_E)
		_kp_check(kp.spell_cooldowns.get("vortex", 0.0) > 0.0,
			"key E fires spell 2 (vortex cd now %.1f)" % \
			kp.spell_cooldowns.get("vortex", 0.0))
		_kp_t = 0.0
		return
	# --- SINGLE-SLOT tray (per-wave gate): rebuild at wave 2 -> [peasant] only
	if _kp_t >= 0.2 and _kp_step_is(7):
		GameState.current_wave = 2
		GameState.selected_units = ["peasant"]
		kp.hud._rebuild_unit_bar()
		_kp_check(kp.hud.unit_buttons.keys() == ["peasant"],
			"wave-2 rebuild renders a single slot")
		var pre := _kp_ally_count()
		_kp_key(KEY_2)
		_kp_check(_kp_ally_count() == pre,
			"key 2 with only 1 slot does NOTHING")
		kp.button_cooldowns["peasant"] = 0.0  # fresh-click parity: the step-4
		# clear the step-4 spawn cooldown so this assert tests ROUTING, not cooldown gating.
		kp.iron = 100.0
		_kp_key(KEY_1)
		_kp_check(_kp_ally_count() == pre + 1,
			"key 1 still routes on the single-slot tray")
		_kp_t = 0.0
		return
	# --- ECHO + hidden-HUD guards, then verdict
	if _kp_t >= 0.2 and _kp_step_is(8):
		var pre := _kp_ally_count()
		_kp_key(KEY_1, true)  # held-key echo repeat: pressed + echo
		_kp_check(_kp_ally_count() == pre, "echo repeat of key 1 is ignored")
		kp.hud.visible = false  # sandbox/menu-style hidden HUD
		_kp_key(KEY_1)
		_kp_check(_kp_ally_count() == pre, "hidden HUD: key 1 dead")
		kp.hud.visible = true
		print("[r1305] VERDICT: %s" % ("PASS" if not _kp_fail else "FAIL"))
		if args.has("screenshot"):
			_capture(str(args["screenshot"]))
		get_tree().quit(0 if not _kp_fail else 1)

var _kp_step := 0

func _kp_step_is(n: int) -> bool:
	if _kp_step == n:
		_kp_step = n + 1
		return true
	return false

func _ngf_check(cond: bool, what: String) -> void:
	print("[newgameflow] %s %s" % ["OK   " if cond else "FAIL", what])
	if not cond:
		_ngf_fail = true

func _ngf_seed() -> void:
	## seeds a mid-campaign save state IN MEMORY so the reset assertions mean something; disk-safe — no GameState.save() call on this path and save() is a no-op under any cmdline user arg.
	GameState.current_wave = 12
	GameState.gold = 4321
	GameState.total_gold = 8000
	GameState.set_type_level("ash", 5)
	GameState.set_type_level("inner_wall_archer", 2)
	GameState.iron_cap_level = 3
	GameState.purchase_weapon("chainsaw")
	GameState.unlock_endless()
	GameState.endless_best = 9000
	GameState.seen_smithy_tutorial = true
	print("[newgameflow] seeded: wave=%d gold=%d ash=L%d iron_cap=L%d chainsaw unlocked=%s endless=%s" % [
		GameState.current_wave, GameState.gold,
		GameState.get_type_level("ash"), GameState.iron_cap_level,
		str(not GameState.weapon_locked("chainsaw")),
		str(GameState.endless_unlocked)])

func _ngf_assert_all_fresh() -> void:
	## the persisted save-schema fields must all read fresh-boot after a confirmed reset.
	_ngf_check(GameState.current_wave == 1, "current_wave==1 (got %d)" % GameState.current_wave)
	_ngf_check(GameState.gold == 0, "gold==0 (got %d)" % GameState.gold)
	_ngf_check(GameState.total_gold == 0, "total_gold==0 (got %d)" % GameState.total_gold)
	_ngf_check(GameState.get_type_level("ash") == 1, "ash type level==1 (got %d)" % GameState.get_type_level("ash"))
	_ngf_check(GameState.get_castle_level("inner_wall_archer") == 0, "inner_wall_archer castle level==0 (got %d)" % GameState.get_castle_level("inner_wall_archer"))
	_ngf_check(GameState.weapon_locked("chainsaw"), "chainsaw re-locked")
	_ngf_check(GameState.weapon_locked("iron_fist"), "iron_fist re-locked")
	_ngf_check(GameState.endless_unlocked == false, "endless_unlocked==false")
	_ngf_check(GameState.endless_best == 0, "endless_best==0 (got %d)" % GameState.endless_best)
	_ngf_check(GameState.seen_smithy_tutorial == false, "seen_smithy_tutorial==false")
	_ngf_check(GameState.iron_cap_level == 1, "iron_cap_level==1 (got %d) — the R10-04 gap" % GameState.iron_cap_level)
	_ngf_check(GameState.selected_units.is_empty(),
		"selected_units fresh-EMPTY (the original seeds no roster, engine.lua:266-278; got %s)" % str(GameState.selected_units))
	_ngf_check(GameState.selected_spells.is_empty(), "selected_spells empty")

func _newgameflow_tick(dt: float) -> void:
	var mf: Node2D = get_tree().current_scene
	if mf == null or mf.get("menus") == null:
		return
	_ngf_t += dt
	match _ngf_step:
		0:
			if _ngf_t >= 0.5:
				_ngf_step = 1
				_ngf_check(mf.menus.state == "main_menu",
					"boot lands on the real main menu (state=%s)" % mf.menus.state)
				_ngf_seed()
				print("[newgameflow] pressing the main-menu OPTIONS plate")
				mf.menus._on_menu_options()
		1:
			if _ngf_t >= 1.0:
				_ngf_step = 2
				_ngf_check(mf.menus.state == "options",
					"OPTIONS plate opens the options screen (state=%s)" % mf.menus.state)
				print("[newgameflow] pressing the RESET GAME plate")
				mf.menus._open_reset_popup()
		2:
			if _ngf_t >= 1.6:
				_ngf_step = 3
				_ngf_check(mf.menus.reset_popup_open(), "reset confirm popup is up")
				print("[newgameflow] pressing CANCEL (nothing may be wiped)")
				mf.menus._on_reset_cancel()
		3:
			if _ngf_t >= 2.4:
				_ngf_step = 4
				_ngf_check(not mf.menus.reset_popup_open(), "CANCEL closes the popup")
				_ngf_check(GameState.current_wave == 12 and GameState.gold == 4321 \
						and GameState.total_gold == 8000 and GameState.iron_cap_level == 3,
					"CANCEL wiped NOTHING (wave=%d gold=%d total=%d iron_cap=%d)" % [
						GameState.current_wave, GameState.gold, GameState.total_gold,
						GameState.iron_cap_level])
				print("[newgameflow] reopening the popup and pressing RESET")
				mf.menus._open_reset_popup()
		4:
			if _ngf_t >= 3.0:
				_ngf_step = 5
				_ngf_check(mf.menus.reset_popup_open(), "reset popup reopened")
				mf.menus._on_reset_confirm()
		5:
			if _ngf_t >= 3.8:
				_ngf_step = 6
				_ngf_check(mf.menus.state == "main_menu",
					"reset lands on a fresh main menu (state=%s)" % mf.menus.state)
				_ngf_check(not mf.menus.reset_popup_open(), "popup destroyed after reset")
				_ngf_check(GameState.is_endless_unlocked() == false,
					"main menu shows PLAY (not ENDLESS) after the reset")
				_ngf_assert_all_fresh()
				# keep driving — the fresh EMPTY selection must reach a playable wave-2 roster through the REAL between-wave chain; memory-only, the quit moves to the final step.
				GameState.current_wave = 2
				print("[newgameflow] entering wave 2 through the real CONTINUE chain")
				mf.menus.open_upgrades()
				mf.menus._on_continue()  # upgrades -> troops (hasAnyUnitsUnlocked: peasant @ 2)
		6:
			if _ngf_t >= 4.4:
				_ngf_step = 7
				_ngf_check(mf.menus.state == "troops",
					"wave-2 CONTINUE opens SELECT TROOPS (state=%s)" % mf.menus.state)
				_ngf_check(GameState.selected_units == ["peasant"],
					"auto-select fills [peasant] from EMPTY at wave 2 (got %s)" % str(GameState.selected_units))
				mf.menus._on_continue()  # troops -> spells (auto-selected boomstick)
		7:
			if _ngf_t >= 5.0:
				_ngf_step = 8
				_ngf_check(mf.menus.state == "spells",
					"troops CONTINUE slides into SELECT SKILLS (state=%s)" % mf.menus.state)
				mf.menus._on_continue()  # spells -> _launch_wave
		8:
			if _ngf_t >= 5.6:
				_ngf_step = 9
				_ngf_check(mf.menus.state == "",
					"spells CONTINUE launches wave 2 (state=%s)" % mf.menus.state)
				_ngf_check(mf.hud != null and mf.hud.unit_buttons.keys() == ["peasant"],
					"wave-2 tray renders exactly [peasant] (got %s)" % str(
						mf.hud.unit_buttons.keys() if mf.hud != null else []))
				# a save that round-tripped the OLD hardcoded trio must re-gate in the tray — the persisted list stays untouched, the buttons are filtered per wave.
				GameState.selected_units = ["peasant", "swordsman", "archer"]
				mf.hud._rebuild_unit_bar()
				var healed: Array = mf.hud.unit_buttons.keys()
				_ngf_check(healed == ["peasant"],
					"stale trio heals to a [peasant]-only tray (got %s)" % str(healed))
				_ngf_check(absf(mf.hud.smith_chip.position.x - 118.0) < 0.01,
					"smithy chip x counts RENDERED buttons (x=%.1f, want 118.0)" % mf.hud.smith_chip.position.x)
				GameState.selected_units = ["peasant"]  # restore the legit wave-2 list
				GameState.current_wave = 6
				print("[newgameflow] advancing to wave 6 for the auto-select top-up")
				mf.menus.open_upgrades()
				mf.menus._on_continue()  # upgrades -> troops
		9:
			if _ngf_t >= 6.2:
				_ngf_step = 10
				_ngf_check(mf.menus.state == "troops",
					"wave-6 CONTINUE opens SELECT TROOPS (state=%s)" % mf.menus.state)
				_ngf_check(GameState.selected_units == ["peasant", "swordsman", "spearman", "archer"],
					"wave-6 auto-select top-up (got %s)" % str(GameState.selected_units))
				print("[newgameflow] VERDICT: %s" % ("PASS" if not _ngf_fail else "FAIL"))
				get_tree().quit(0 if not _ngf_fail else 1)

func _healertest_tick() -> void:
	var ht: Node2D = get_tree().current_scene
	if ht == null or ht.get("units_layer") == null:
		return
	if not _ht_staged:
		if _frames < 30 or ht.ash == null:
			return
		_ht_staged = true
		_ht_wm = ht.summon_at("wiseman", 1, 200.0)
		_ht_wm.walk_in_x = 200.0  # stand there — straight into COMBAT
		_ht_patient = ht.summon_at("swordsman", 1, 520.0)
		_ht_patient.walk_in_x = 520.0
		_ht_patient.take_damage(50, null)  # 200 -> 150: the far fallback patient
		_ht_skel = ht.spawn_enemy("sword_skeleton", 1)
		_ht_skel.position.x = 560.0
		_ht_skel.walk_in_x = 560.0
		_ht_enemy_max = _ht_skel.max_health
		print("[ht] staged wiseman@%.0f patient@%.0f hp=%.0f/%.0f skeleton@%.0f" % [
			_ht_wm.position.x, _ht_patient.position.x, _ht_patient.health,
			_ht_patient.max_health, _ht_skel.position.x])
		# arrow scale must be 0.25 (the staged diffuse is 210 px for a 52.5-world-unit arrow).
		var atex: Texture2D = ht._ammo_texture("arrows", 1)
		if atex != null:
			print("[ht] arrow tex %dx%d scale=%.4f (expect 0.2500)" % [
				atex.get_width(), atex.get_height(),
				ht._ammo_sprite_scale("arrows", 1, atex)])
		else:
			print("[ht] FAIL: arrows texture missing")
			_ht_fail = true
		return
	if _ht_wm == null or not is_instance_valid(_ht_wm) or _ht_wm.state == Unit.State.DEAD:
		return
	_ht_frames += 1
	for p: Variant in ht._projectiles:
		if p.damage >= 0:
			continue
		var tp: Unit = p.target
		if tp == null or not is_instance_valid(tp):
			continue
		if tp.team == Unit.Team.ENEMY:
			print("[ht] FAIL: heal shot at ENEMY %s" % tp.unit_type)
			_ht_fail = true
		elif _ht_frames % 6 == 0:
			print("[ht] heal shot -> %s (ALLY)" % tp.unit_type)
	if is_instance_valid(_ht_skel) and _ht_skel.health > _ht_enemy_max + 0.01:
		print("[ht] FAIL: enemy healed %.0f > %.0f" % [_ht_skel.health, _ht_enemy_max])
		_ht_fail = true
	if _ht_frames % 10 == 0:
		print("[ht] f%d wiseman x=%.0f moving=%s patient hp=%.0f/%.0f skeleton hp=%.0f" % [
			_ht_frames, _ht_wm.position.x, _ht_wm.is_moving,
			_ht_patient.health if is_instance_valid(_ht_patient) else -1.0,
			_ht_patient.max_health if is_instance_valid(_ht_patient) else -1.0,
			_ht_skel.health if is_instance_valid(_ht_skel) else -1.0])
		if _ht_frames >= 30:
			var walked := _ht_wm.position.x - 200.0
			var ok_walk := walked > 40.0  # advanced on the OUT-OF-RANGE patient
			var ok_hold := _ht_wm.position.x < 520.0  # never pushed past the front line
			print("[ht] verdict: walked=%.0f (%s) held_behind_front=%s fail=%s -> %s" % [
				walked, "OK" if ok_walk else "FAIL", "OK" if ok_hold else "FAIL", _ht_fail,
				"PASS" if (ok_walk and ok_hold and not _ht_fail) else "FAIL"])
			get_tree().quit(0 if (ok_walk and ok_hold and not _ht_fail) else 1)

# ------------------------------------------------------ gate assembly

var _gt_printed := false

func _gatetest_tick(dt: float) -> void:
	## gate-assembly probe: stage ONE L1 sword skeleton 40 px outside the gate's strike band, standing; it must settle at gate.x + weapon_range and drop the gate's health — proving gate_dx moves the ENEMY TARGET. PASS quits 0 (optional capture at the strike); a dead skeleton or 12 s timeout quits 1.
	var gt: Node2D = get_tree().current_scene
	if gt == null or gt.get("units_layer") == null or _gt_done:
		return
	# stage at SIM t=1.5 — under 12x a frame gate would land after the bot's first summon batch.
	_gt_total += dt
	if _gt_skel == null:
		if _gt_total < 1.5 or gt.get("gate") == null or gt.gate == null \
				or gt.get("ash") == null or gt.ash == null:
			return
		var sk: Unit = gt.spawn_enemy("sword_skeleton", 1)
		sk.position.x = gt.gate.position.x + sk.weapon_range + 40.0
		sk.walk_in_x = sk.position.x
		_gt_skel = sk
		print("[gatetest] staged skeleton L1 at x=%.1f (gate x=%.1f, weapon_range=%.0f; ash x=%.1f)" % [
			sk.position.x, gt.gate.position.x, sk.weapon_range, gt.ash.position.x])
		return
	if not is_instance_valid(_gt_skel) or _gt_skel.state == Unit.State.DEAD:
		_gt_done = true
		print("[gatetest] FAIL: skeleton died before striking (gate hp=%.0f/%.0f)" % [
			gt.gate.health, gt.gate.max_health])
		get_tree().quit(1)
		return
	if _gt_total > 12.0:
		_gt_done = true
		print("[gatetest] FAIL: timeout (skel x=%.1f gate x=%.1f hp=%.0f/%.0f)" % [
			_gt_skel.position.x, gt.gate.position.x, gt.gate.health, gt.gate.max_health])
		get_tree().quit(1)
		return
	_gt_t += dt
	if _gt_t < 0.25:
		return
	_gt_t = 0.0
	var settled: bool = _gt_skel.state == Unit.State.COMBAT and not _gt_skel.is_moving
	var hit: bool = gt.gate.health < gt.gate.max_health
	var want_x: float = gt.gate.position.x + _gt_skel.weapon_range
	if not _gt_printed or (settled and hit):
		_gt_printed = true
		print("[gatetest] skel x=%.1f (want %.1f) state=%d moving=%s gate x=%.1f hp=%.0f/%.0f" % [
			_gt_skel.position.x, want_x, _gt_skel.state, _gt_skel.is_moving,
			gt.gate.position.x, gt.gate.health, gt.gate.max_health])
	if settled and hit:
		# the advance is frame-quantized (speed*dt per step, ~10 world px at 12x/60fps) — the settle may land up to ONE step past the band edge.
		var ok: bool = absf(want_x - _gt_skel.position.x) <= 10.0 \
			and _gt_skel.position.x > gt.gate.position.x
		_gt_done = true
		print("[gatetest] VERDICT: %s — skeleton struck the cage at x=%.1f (settled %.1f inside the band, frame-quantized)" % [
			"PASS" if ok else "FAIL", gt.gate.position.x, want_x - _gt_skel.position.x])
		if args.has("screenshot"):
			_capture(str(args["screenshot"]))
		get_tree().quit(0 if ok else 1)

# ------------------------------------------------- pause/menu labels

var _pt_step := 0
var _pt_t := 0.0
var _pt_fail := false
var _pt_n := 0

func _pt_check(cond: bool, what: String) -> void:
	_pt_n += 1
	print("[r1407] %s %s" % ["OK   " if cond else "FAIL", what])
	if not cond:
		_pt_fail = true

func _pt_menu_wave_label(menus: Node) -> String:
	## the live (not queue_free-d) "Wave..." header Label of the open menu screen.
	for c in menus._root.get_children():
		if c is Label and not c.is_queued_for_deletion() \
				and str(c.text).begins_with("Wave"):
			return str(c.text)
	return ""

func _pausetest_tick(dt: float) -> void:
	## one 0.5 s step per stage: pause-label freshness, the stale-52 -> 51 endless pin, the "Wave ∞" sentinel on pause/upgrades/troop-select, story headers, then a final capture.
	var pm: Node2D = get_tree().current_scene
	if pm == null or pm.get("pause_menu") == null or pm.get("menus") == null:
		return
	_pt_t += dt
	if _pt_t < 0.5:
		return
	_pt_t = 0.0
	match _pt_step:
		0:
			pm.pause_menu.toggle()
			_pt_check(pm.pause_menu.is_open(),
				"pause opens at boot wave %d" % GameState.current_wave)
			_pt_check(pm.pause_menu._wave_label.text == "Wave 22",
				"pause label bakes the boot wave (got \"%s\" want \"Wave 22\")" \
					% pm.pause_menu._wave_label.text)
			pm.pause_menu.toggle()
		1:
			GameState.current_wave = 35
			pm.pause_menu.toggle()
			_pt_check(pm.pause_menu._wave_label.text == "Wave 35",
				"pause label re-bakes per open (got \"%s\" want \"Wave 35\")" \
					% pm.pause_menu._wave_label.text)
			pm.pause_menu.toggle()
		2:
			GameState.current_wave = 52
			pm.start_wave(52)
			_pt_check(GameState.current_wave == 51,
				"start_wave(52) pins the endless sentinel (current_wave=%d)" \
					% GameState.current_wave)
			_pt_check(pm.endless_mode, "endless_mode engaged after the pin")
			pm.pause_menu.toggle()
			_pt_check(pm.pause_menu._wave_label.text == "Wave ∞",
				"endless pause label is the sentinel (got \"%s\" want \"Wave ∞\")" \
					% pm.pause_menu._wave_label.text)
			pm.pause_menu.toggle()
		3:
			pm.menus.open_upgrades()
			_pt_check(_pt_menu_wave_label(pm.menus) == "Wave ∞",
				"upgrades header in endless (got \"%s\" want \"Wave ∞\")" \
					% _pt_menu_wave_label(pm.menus))
			pm.menus.close()
			pm.menus.open_troops()
			_pt_check(_pt_menu_wave_label(pm.menus) == "Wave ∞",
				"troop-select header in endless (got \"%s\" want \"Wave ∞\")" \
					% _pt_menu_wave_label(pm.menus))
			pm.menus.close()
		4:
			GameState.current_wave = 22
			pm.menus.open_upgrades()
			_pt_check(_pt_menu_wave_label(pm.menus) == "Wave 22",
				"upgrades header in story (got \"%s\" want \"Wave 22\")" \
					% _pt_menu_wave_label(pm.menus))
			pm.menus.close()
			pm.menus.open_troops()
			_pt_check(_pt_menu_wave_label(pm.menus) == "Wave 22",
				"troop-select header in story (got \"%s\" want \"Wave 22\")" \
					% _pt_menu_wave_label(pm.menus))
			pm.menus.close()
		5:
			GameState.current_wave = 52
			pm.start_wave(52)
			_pt_check(GameState.current_wave == 51,
				"re-entry re-pins (current_wave=%d)" % GameState.current_wave)
			pm.pause_menu.toggle()
			_pt_check(pm.pause_menu.is_open(),
				"pause open for the final shot")
			_pt_check(pm.pause_menu._wave_label.text == "Wave ∞",
				"final pause label (got \"%s\" want \"Wave ∞\")" \
					% pm.pause_menu._wave_label.text)
		6:
			# capture on a LATER tick — a same-tick force_draw() can grab the stale PRE-pause frame.
			if args.has("screenshot"):
				_capture(str(args["screenshot"]))
			print("[r1407] %s (%d checks)" % ["FAIL" if _pt_fail else "PASS", _pt_n])
			get_tree().quit(1 if _pt_fail else 0)
	_pt_step += 1

func _capture(path: String) -> void:
	# force a synchronous draw — awaiting frame_post_draw can starve forever when the window is occluded/minimized.
	RenderingServer.force_draw()
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	print("[dbg] screenshot saved: ", path, " ", img.get_size())
	var m: Node2D = get_tree().current_scene
	if m != null and m.get("units_layer") != null:
		print("[dbg] camera=", m.camera.position, " cam_path_top=", m.camera.get_screen_center_position())
		for u in m.units_layer.get_children():
			if u is Unit:
				var info := ""
				if u.anim != null and u.anim.sprite_frames != null \
						and u.anim.sprite_frames.has_animation(u.anim.animation):
					var tr: Texture2D = u.anim.sprite_frames.get_frame_texture(u.anim.animation, 0)
					if tr != null:
						info = "anim=%s frame=%d/%d tex=%s scale=%s gscale=%s" % [
							u.anim.animation, u.anim.frame, u.anim.sprite_frames.get_frame_count(u.anim.animation),
							tr.get_size(), u.anim.scale, u.anim.get_global_transform().get_scale()]
						var at: Texture2D = tr.get("atlas") if tr is AtlasTexture else null
						if at != null:
							# which strip is actually bound (T42 swap checks)
							info += " atlas=" + at.resource_path.get_file()
					else:
						info = "anim=%s (frame texture null)" % u.anim.animation
				print("[dbg]   unit %-14s pos=%s vis=%s %s" % [u.unit_type, u.position, u.visible, info])
				if u.is_hero:
					print("[dbg]   hero pos=%s melee=%s melee_range=%.0f gun_range=%.0f active_melee=%s" % [
						u.position, u.melee_weapon_name, u.melee_range, u.weapon_range,
						str(u._active_melee)])
				if u.unit_type == "ash" and u.anim != null:
					var fr: Texture2D = u.anim.sprite_frames.get_frame_texture(u.anim.animation, u.anim.frame)
					var fim := fr.get_image()
					if fim != null:
						fim.save_png(ProjectSettings.globalize_path("res://assets/unit_frames/diag_runtime_frame.png"))
						var px := fim.get_pixel(fim.get_width() / 2, fim.get_height() / 2)
						print("[dbg]   ash frame img ", fim.get_size(), " center px=", px)

var _probe_total := 0

func _hitprobe_walk(node: Node, pt: Vector2, depth: int) -> void:
	## recurse the control tree; report every visible, input-eating Control whose rect covers pt (topmost wins input).
	for c in node.get_children():
		_probe_total += 1
		if c is Control:
			var ctl: Control = c
			if ctl.is_visible_in_tree() and ctl.mouse_filter != Control.MOUSE_FILTER_IGNORE \
					and Rect2(ctl.global_position, ctl.size).has_point(pt):
				print("[hitprobe]   depth=%d %s '%s' rect=%s x %s filter=%d" % [
					depth, ctl.get_class(), str(ctl.name).substr(0, 24),
					ctl.global_position, ctl.size, ctl.mouse_filter])
		_hitprobe_walk(c, pt, depth + 1)
