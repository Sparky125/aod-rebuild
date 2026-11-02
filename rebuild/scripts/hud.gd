extends CanvasLayer
## HUD rebuilt to the original footage layout (all values /2 for the 960x640 viewport); the bottom-right corner stays empty like the original.

var main: Node2D

var ash_life_fill: ColorRect
var score_plate: TextureRect
var score_label: Label
var wave_bar: Control
var wave_fill: TextureRect
var unit_buttons := {}
var smith_lvl_label: Label
var smith_bar_fill: ColorRect
var smith_bar_back: TextureRect   # full-width smith_bar_back art inside the clip
var smith_bar_frame: TextureRect  # full-width smith_bar frame inside the clip
var smith_recess: Control        # bar container, clip-revealed to level/4
var smith_iron_label: Label
var smith_popout: TextureRect  # UPGRADE plate shown while the chip is hovered
var smith_chip: TextureButton
var smith_fill_cur := 0.0      # animated bar reveal fraction, level/4
var _smith_pop_shown := false  # last known UPGRADE affordability
var _smith_pop_tween: Tween
var spell_buttons: Array = []
var overlay: Control
var overlay_dim: ColorRect      # phase-2 black dimmer (Lua alpha 0.5)
var overlay_banner: TextureRect
var overlay_button: TextureButton
var _tally_nodes: Array = []    # rows + coin icons + coin_box plate (win and defeat)
var _over_tween: Tween          # the banner -> phase-2 sequence
var push_label: Label
var msg_label: Label
var push_art: TextureRect
var wave_num_override := 0  # banner screen: show the wave just played
var _danger_icons: Array = []  # per-push wave-bar skulls, in push order
var _push_anim := 0.0
var _msg_anim := 0.0
var _blood: Control            # screen-edge blood overlay (4 art strips)
var _blood_tween: Tween
var protect_icon: TextureRect  # "Protect the book!" left-edge warning icon
var _protect_t := 0.0          # pulse clock (Lua alpha loop 0.5 <-> 1.0)

const HUD_ART := "res://assets/ui/hud/"
# unit_type -> icon art leaf, built from units.json icon_texture at ready
var UNIT_ICONS := {}
const SPELL_ICONS := {
	"arrow_volley": "arrow_volley_button", "super_boomstick_blast": "super_boomstick_button",
	"vortex": "vortex_button", "magic_words": "words_button",
	"catapults_spell": "catapult_volley_button", "deathcoaster_spell": "deathcoster_button",
}
# native spell button art sizes — the plates draw at real aspect x SPELL_BTN_SCALE; a square slot squashed the wider-than-tall art.
const SPELL_SIZES := {
	"super_boomstick_blast": Vector2(151, 119), "vortex": Vector2(151, 120),
	"arrow_volley": Vector2(151, 119), "magic_words": Vector2(151, 112),
	"catapults_spell": Vector2(151, 117), "deathcoaster_spell": Vector2(151, 109),
}
const SPELL_BTN_SCALE := 0.75

# --- footage-measured geometry at 960x640 ---
const WAVE_POS := Vector2(315, 11)  # wave bar slot (f3 victory frame, clean)
const WAVE_SIZE := Vector2(435, 39) # art 384x62

# --- smithy chip geometry: every art at ratio 480/1024, bars x0.95, doubled into the 2x screen ---
const SMITH_RATIO := 480.0 / 1024.0
const SMITH_CHIP_SIZE := Vector2(133.0, 128.0) * SMITH_RATIO * 2.0       # 124.7x120
const SMITH_BAR_SIZE := Vector2(299.0, 69.0) * SMITH_RATIO * 0.95 * 2.0  # 266.3x61.4
const SMITH_POP_SIZE := Vector2(257.0, 82.0) * SMITH_RATIO * 0.95 * 2.0  # 228.1x73.2

# --- ash life bar: art at ART_PX, anchor offsets in WORLD units (world * 2 = screen px, y-up flipped); z order back < fill < frame < icon ---
const ART_PX := SMITH_RATIO * 2.0   # native texture px -> screen px
const WORLD_PX := 2.0               # world unit -> screen px
const PORTRAIT_POS := Vector2(2.0, 0.0) * WORLD_PX
const PORTRAIT_SIZE := Vector2(109.0, 106.0) * ART_PX
const LB_POS := Vector2(PORTRAIT_POS.x + PORTRAIT_SIZE.x - 5.0 * WORLD_PX,
	PORTRAIT_POS.y + 2.0 * WORLD_PX)
const LB_SIZE := Vector2(181.0, 69.0) * ART_PX
# the fill deliberately over-runs UNDER the frame's stone caps at both ends — that masking is the authentic look and darkens the green through the frame's translucent core.
const LB_FILL_SIZE := LB_SIZE * Vector2(0.88, 0.48)
# +3 px right — deliberate deviation; revert this constant to restore 1:1.
const LB_FILL_POS := Vector2(LB_POS.x + 2.0 * WORLD_PX + 3.0,
	LB_POS.y + LB_SIZE.y * 0.5 - 0.5 * WORLD_PX - LB_FILL_SIZE.y * 0.5)

# --- win/lose overlay geometry, Lua-exact: world *2 with y flipped ---
const VICTORY_BANNER_SIZE := Vector2(621.0, 169.0) * ART_PX
const DEFEAT_BANNER_SIZE := Vector2(659.0, 162.0) * ART_PX
const BANNER_BOTTOM_Y := 230.0                 # 45 world above centre
const TALLY_ROW_PITCH := 84.0                  # 26 + 8 + 8 = 42 world
const TALLY_TOP_LEFT := Vector2(230.0, 242.0)  # gold_window TL
const TALLY_LABEL_W := 140.0 * WORLD_PX        # Lua max_width 140 world
const TALLY_AMOUNT_RIGHT := TALLY_TOP_LEFT.x + 250.0 * WORLD_PX \
	- 35.16 * WORLD_PX                         # window TR - coin width
const TALLY_FONT_PX := 52                      # Georgia/Helvetica-Bold 26 world
const COIN_BOX_POS := Vector2(205.3, 399.5)
const COIN_BOX_SIZE := Vector2(586.0, 88.0) * ART_PX
const CONTINUE_POS := Vector2(480.0 - 118.125, 542.0 - 43.125)
const CONTINUE_SIZE := Vector2(252.0, 92.0) * ART_PX
const TALLY_FADE_DELAY := 3.0                  # LuaAction(3.0) -> phase 2

# --- endless score plate: coin_box art minus (96, 6), flush to the screen top-centre; font em 40 px ---
const SCORE_PLATE_SIZE := Vector2(586.0, 88.0) * ART_PX - Vector2(96.0, 6.0) * WORLD_PX
const SCORE_PLATE_POS := Vector2((960.0 - SCORE_PLATE_SIZE.x) * 0.5, 0.0)
const SCORE_FONT_PX := 40

func _ready() -> void:
	layer = 10
	for type_name: String in DB.table("units").keys():
		var uri: String = str(DB.entry("units", type_name).get("icon_texture", ""))
		if uri.begins_with("texture/UI/"):
			UNIT_ICONS[type_name] = uri.rsplit("/", 1)[-1]

	# top-left: opaque back -> flat green fill -> stone frame; the fill grows from the left via its width in _process.
	var portrait := TextureRect.new()
	portrait.texture = load(HUD_ART + "ash_life_icon.webp")
	portrait.position = PORTRAIT_POS
		# set expand/stretch BEFORE size: with the default EXPAND_KEEP_SIZE the control's minimum IS the texture size, so an early size assignment clamps UP to native px and never re-shrinks.
	portrait.stretch_mode = TextureRect.STRETCH_SCALE
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.size = PORTRAIT_SIZE
	portrait.z_index = 1  # Lua ash_life_icon z=1: the ring covers the bar's cap
	add_child(portrait)

	var bar_back := TextureRect.new()
	bar_back.texture = load(HUD_ART + "ash_lifebar_back.webp")
	bar_back.position = LB_POS
	bar_back.stretch_mode = TextureRect.STRETCH_SCALE
	bar_back.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bar_back.size = LB_SIZE
	bar_back.z_index = -4  # Lua background z=-4: behind the icon
	add_child(bar_back)
	ash_life_fill = ColorRect.new()
	ash_life_fill.color = Color(0.0, 1.0, 0.0)
	ash_life_fill.position = LB_FILL_POS
	ash_life_fill.size = LB_FILL_SIZE
	ash_life_fill.z_index = -3  # child of the z=-4 back, under the icon
	add_child(ash_life_fill)
	var bar_frame := TextureRect.new()
	bar_frame.texture = load(HUD_ART + "ash_lifebar.webp")
	bar_frame.position = LB_POS
	bar_frame.stretch_mode = TextureRect.STRETCH_SCALE
	bar_frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bar_frame.size = LB_SIZE
	bar_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar_frame.z_index = -2  # frame over fill, still under the icon ring
	add_child(bar_frame)

	var pause_btn := _tb("pause_button", Vector2(1.0, 45.0) * WORLD_PX,
		Vector2(87.0, 80.0) * ART_PX)
	pause_btn.pressed.connect(func() -> void: main.pause_menu.toggle())
	pause_btn.mouse_entered.connect(func() -> void:
		pause_btn.modulate = Color(0.7, 0.7, 0.7, 1.0))
	pause_btn.mouse_exited.connect(func() -> void: pause_btn.modulate = Color.WHITE)
	add_child(pause_btn)

	# top-center: wave bar — purple fill RIGHT-ANCHORED growing left (native insets 18.5/17 of the 384x62 art), frame over.
	wave_bar = Control.new()
	wave_bar.position = WAVE_POS
	wave_bar.size = WAVE_SIZE
	add_child(wave_bar)
	var ep_back := TextureRect.new()
	ep_back.texture = load(HUD_ART + "enemy_progress_back.webp")
	ep_back.stretch_mode = TextureRect.STRETCH_SCALE
	ep_back.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ep_back.set_anchors_preset(Control.PRESET_FULL_RECT)
	ep_back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wave_bar.add_child(ep_back)
	wave_fill = TextureRect.new()
	wave_fill.texture = load(HUD_ART + "enemy_progress_mid.webp")
	wave_fill.stretch_mode = TextureRect.STRETCH_SCALE
	wave_fill.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	wave_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wave_bar.add_child(wave_fill)
	var ep_front := TextureRect.new()
	ep_front.texture = load(HUD_ART + "enemy_progress_front.webp")
	ep_front.stretch_mode = TextureRect.STRETCH_SCALE
	ep_front.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ep_front.set_anchors_preset(Control.PRESET_FULL_RECT)
	ep_front.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wave_bar.add_child(ep_front)
	score_plate = TextureRect.new()
	score_plate.texture = load(HUD_ART + "coin_box.webp")
	# never preserve aspect — the art is stretched non-uniformly (shrunk more in x than y).
	score_plate.stretch_mode = TextureRect.STRETCH_SCALE
	score_plate.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	score_plate.position = SCORE_PLATE_POS
	score_plate.size = SCORE_PLATE_SIZE
	score_plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	score_plate.visible = false
	add_child(score_plate)
	score_label = _num_label(SCORE_FONT_PX, Color.WHITE)
	score_label.position = SCORE_PLATE_POS + Vector2(0.0, -3.0)
	score_label.size = SCORE_PLATE_SIZE
	score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	score_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	score_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	score_label.visible = false
	add_child(score_label)

	for i in 2:
		var sb := _tb("icon_blank", Vector2.ZERO,
			Vector2(151, 120) * ART_PX * SPELL_BTN_SCALE)
		sb.pressed.connect(_on_spell_button.bind(i))
		add_child(sb)
		var cd_label := _mk_label(roundi(15.0 * SPELL_BTN_SCALE), Color.WHITE)
		cd_label.set_anchors_preset(Control.PRESET_FULL_RECT)
		cd_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cd_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		cd_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		sb.add_child(cd_label)
		spell_buttons.append({"btn": sb, "cd": cd_label, "icon": ""})
	_layout_spell_buttons()

	push_art = TextureRect.new()
	push_art.texture = load(HUD_ART + "danger_popup.webp")
	push_art.position = Vector2(72, 170)
	push_art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	push_art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	push_art.size = Vector2(816, 254)
	push_art.modulate.a = 0.0
	add_child(push_art)

	push_label = _mk_label(20, Color(1, 0.4, 0.3))
	push_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	push_label.position = Vector2(110, 190)
	push_label.modulate.a = 0.0
	add_child(push_label)

	msg_label = _mk_label(13, Color(1, 0.95, 0.65))
	msg_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	msg_label.position = Vector2(60, 250)
	msg_label.modulate.a = 0.0
	add_child(msg_label)

	# z_index 50 is load-bearing: _rebuild_unit_bar() runs later, making the tray plates later siblings that would draw over and steal CONTINUE clicks (the tray stays VISIBLE under the overlay, like the Lua).
	overlay = Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.z_index = 50
	overlay.visible = false
	add_child(overlay)
	overlay_dim = ColorRect.new()
	overlay_dim.color = Color(0, 0, 0, 0.5)
	overlay_dim.modulate.a = 0.0
	overlay_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(overlay_dim)
	overlay_banner = TextureRect.new()
	overlay_banner.stretch_mode = TextureRect.STRETCH_SCALE
	overlay_banner.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	overlay_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(overlay_banner)
	overlay_button = _tb("continue_button", CONTINUE_POS, CONTINUE_SIZE)
	overlay_button.modulate.a = 0.0
	overlay_button.pressed.connect(_on_overlay_button)
	overlay.add_child(overlay_button)

	# blood overlay: 4 rotated screen-edge strips, shown when Ash takes a hit under half health.
	_build_blood_overlay()

	# --- Necro warning icon (maingamewindow.lua:377-436): the
	# protect_the_book_icon art at the window's left edge, v-centred,
	# z 2; pulsing alpha 0.5 -> 1.0 (0.5 s each way, looping); driven by
	# gate damage recency + off-screen-left check every frame in _process
	protect_icon = TextureRect.new()
	protect_icon.texture = load(HUD_ART + "protect_the_book_icon.webp")
	protect_icon.stretch_mode = TextureRect.STRETCH_SCALE
	protect_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	protect_icon.size = Vector2(153.0, 157.0) * ART_PX
	protect_icon.position = Vector2(0.0, 320.0 - protect_icon.size.y * 0.5)
	protect_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	protect_icon.visible = false
	add_child(protect_icon)

	_rebuild_unit_bar()

func _build_blood_overlay() -> void:
	_blood = Control.new()
	_blood.set_anchors_preset(Control.PRESET_FULL_RECT)
	_blood.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_blood.visible = false
	add_child(_blood)
	var tex: Texture2D = load(HUD_ART + "ui_blood_overlay.webp")
	var bar_h := 960.0 / 1024.0 * 145.0  # art 1024x145 at our 960 design width
	# the art's solid red base is its BOTTOM edge — each strip's base must sit ON the screen edge with splatter inward (+90 CW maps base to pos.x - bar_h; +270 to pos.x + bar_h).
	var strips := [
		{"rot": 0.0, "pos": Vector2(0, 640 - bar_h)},
		{"rot": PI, "pos": Vector2(960, bar_h)},
		{"rot": PI * 0.5, "pos": Vector2(bar_h, 0)},
		{"rot": PI * 1.5, "pos": Vector2(960.0 - bar_h, 640)},
	]
	for s: Dictionary in strips:
		var rot: float = s["rot"]
		var tr := TextureRect.new()
		tr.texture = tex
		# expand/stretch BEFORE size (same native-minimum clamp as the portrait).
		tr.stretch_mode = TextureRect.STRETCH_SCALE
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.size = Vector2(960, bar_h)
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tr.rotation = rot
		tr.position = s["pos"]
		if absf(fposmod(rot, PI) - PI * 0.5) < 0.1:
			tr.scale = Vector2(640.0 / 960.0, 1.0)
		_blood.add_child(tr)

func flash_blood_overlay() -> void:
	if _blood == null:
		return
	if _blood_tween != null and _blood_tween.is_valid():
		_blood_tween.kill()
	_blood.visible = true
	_blood.modulate.a = 1.0
	_blood_tween = create_tween()
	_blood_tween.tween_property(_blood, "modulate:a", 0.0, 0.75)
	_blood_tween.tween_callback(func() -> void: _blood.visible = false)

func hold_blood_overlay(alpha := 0.7) -> void:
	## the defeat flow holds the strips at a fixed alpha — no fade-out.
	if _blood == null:
		return
	if _blood_tween != null and _blood_tween.is_valid():
		_blood_tween.kill()
	_blood.visible = true
	_blood.modulate.a = alpha

func _tb(art: String, pos: Vector2, sz: Vector2) -> TextureButton:
	## ignore_texture_size must be set — it defaults false and every plate then draws at its native px regardless of size.
	var b := TextureButton.new()
	b.texture_normal = load(HUD_ART + art + ".webp")
	b.ignore_texture_size = true
	b.stretch_mode = TextureButton.STRETCH_SCALE
	b.position = pos
	b.size = sz
	return b

func _layout_spell_buttons() -> void:
	## TR-anchored row: the second slot's right edge flush with the screen, first adjacent left (no overlap); X from each button's CURRENT width.
	var x_right := 960.0
	for i in range(spell_buttons.size() - 1, -1, -1):
		var btn: TextureButton = spell_buttons[i]["btn"]
		x_right -= btn.size.x
		btn.position = Vector2(x_right, 6.0)

var _unit_bar: HBoxContainer

func _rebuild_unit_bar() -> void:
	# free the chip too — a chip left behind kept rendering its stale labels under the new one.
	if _unit_bar != null:
		_unit_bar.queue_free()
	if smith_chip != null and is_instance_valid(smith_chip):
		smith_chip.queue_free()
	unit_buttons.clear()
	var bar := HBoxContainer.new()
	_unit_bar = bar
	bar.position = Vector2(10, 640 - 100)
	bar.add_theme_constant_override("separation", 8)
	add_child(bar)
	# the tray re-gates the SELECTION per wave — an existing save can carry selected-but-locked troops, and this gate heals it on load; wave 1 legitimately shows ZERO unit buttons.
	for type_name: String in GameState.selected_units:
		if GameState.current_wave < int(DB.entry("units", type_name).get("unlock_wave", 1)):
			continue
		var btn := _tb(UNIT_ICONS.get(type_name, "icon_blank"), Vector2.ZERO, Vector2(100, 100))
		btn.custom_minimum_size = Vector2(100, 100)
		btn.pressed.connect(_on_unit_button.bind(type_name))
		bar.add_child(btn)
		var cost := _mk_label(18, Color.WHITE)
		cost.text = "5"
		cost.add_theme_constant_override("outline_size", 4)
		cost.add_theme_color_override("font_outline_color", Color(0.05, 0.05, 0.05))
		cost.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
		cost.offset_left = -36.0
		cost.offset_top = -30.0
		cost.offset_right = -6.0
		cost.offset_bottom = -4.0
		cost.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cost.mouse_filter = Control.MOUSE_FILTER_IGNORE
		btn.add_child(cost)
		unit_buttons[type_name] = {"btn": btn, "cost": cost}
	# the chip is pinned independently of the unit HBox (poking ~20px above the plate row is correct — never parented to the button row) and chip_x counts RENDERED buttons only — a gate-skipped locked entry must not push the chip right.
	var chip_x := 10.0 + float(unit_buttons.size()) * 108.0
	var chip := _tb("smith_button", Vector2(chip_x, 640.0 - SMITH_CHIP_SIZE.y), SMITH_CHIP_SIZE)
	chip.pressed.connect(_on_smith_chip)
	chip.mouse_entered.connect(_on_smith_hover.bind(true))
	chip.mouse_exited.connect(_on_smith_hover.bind(false))
	add_child(chip)
	smith_chip = chip
	smith_lvl_label = _num_label(28, Color.WHITE)
	smith_lvl_label.name = "SmithLevel"
	smith_lvl_label.text = "L1"
	smith_lvl_label.add_theme_constant_override("outline_size", 5)
	smith_lvl_label.add_theme_color_override("font_outline_color", Color(0.05, 0.05, 0.05))
	smith_lvl_label.position = Vector2(SMITH_CHIP_SIZE.x * 0.5 - 2.0,
		SMITH_CHIP_SIZE.y * 0.5 - 4.0 - 14.0)
	smith_lvl_label.size = Vector2(50, 28)
	smith_lvl_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	smith_lvl_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	smith_lvl_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.add_child(smith_lvl_label)
	smith_iron_label = _num_label(36, Color.WHITE)
	smith_iron_label.name = "SmithIron"
	smith_iron_label.text = "0"
	smith_iron_label.add_theme_constant_override("outline_size", 5)
	smith_iron_label.add_theme_color_override("font_outline_color", Color(0.05, 0.05, 0.05))
	smith_iron_label.position = Vector2(SMITH_CHIP_SIZE.x - 18.0 - 90.0,
		SMITH_CHIP_SIZE.y - 16.0 - 40.0)
	smith_iron_label.size = Vector2(90, 40)
	smith_iron_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	smith_iron_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	smith_iron_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.add_child(smith_iron_label)
	# the reveal is a CLIP: the recess shrinks while the full-width art inside slides LEFT, so the art's right stone cap ALWAYS ends the revealed slot (the old left-pinned clip cut it off at levels 1-3).
	smith_recess = Control.new()
	smith_recess.position = Vector2(SMITH_CHIP_SIZE.x - 18.0,
		SMITH_CHIP_SIZE.y - SMITH_BAR_SIZE.y)
	smith_recess.size = SMITH_BAR_SIZE
	smith_recess.pivot_offset = Vector2.ZERO
	smith_recess.clip_contents = true       # left-pinned reveal region
	smith_recess.show_behind_parent = true  # draws UNDER the wedge chip art
	smith_recess.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.add_child(smith_recess)
	var bar_back := TextureRect.new()
	bar_back.texture = load(HUD_ART + "smith_bar_back.webp")
	# expand/stretch BEFORE size (portrait clamp trap).
	bar_back.stretch_mode = TextureRect.STRETCH_SCALE
	bar_back.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bar_back.size = smith_recess.size
	bar_back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	smith_recess.add_child(bar_back)
	smith_bar_back = bar_back
	smith_bar_fill = ColorRect.new()
	smith_bar_fill.color = Color(0.0, 0.0, 1.0)
	var fill_h := SMITH_BAR_SIZE.y * 0.48
	smith_bar_fill.position = Vector2(2.0 * WORLD_PX,
		SMITH_BAR_SIZE.y * 0.5 - 0.5 * WORLD_PX - fill_h * 0.5)
	smith_fill_cur = clampf(float(main.iron_level) / 4.0, 0.0, 1.0)
	smith_bar_fill.size = Vector2(SMITH_BAR_SIZE.x * smith_fill_cur \
		* (0.79 + (float(main.iron_level) - 1.0) * 0.05) \
		* clampf(main.iron / float(maxi(main.iron_cap, 1)), 0.0, 1.0), fill_h)
	smith_bar_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	smith_recess.add_child(smith_bar_fill)
	var bar_frame := TextureRect.new()
	bar_frame.texture = load(HUD_ART + "smith_bar.webp")
	# expand/stretch BEFORE size (portrait clamp trap).
	bar_frame.stretch_mode = TextureRect.STRETCH_SCALE
	bar_frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bar_frame.size = smith_recess.size
	bar_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	smith_recess.add_child(bar_frame)
	smith_bar_frame = bar_frame
	# UPGRADE pop-out: z=-2 keeps its smeared left half hidden UNDER the wedge chip; affordability drives the scale.x 0<->1 reveal over 0.25 s.
	smith_popout = TextureRect.new()
	smith_popout.texture = load(HUD_ART + "smith_upgrade_bar.webp")
	smith_popout.position = Vector2(11.0 * WORLD_PX,
		SMITH_CHIP_SIZE.y * 0.5 - 10.0 * WORLD_PX - SMITH_POP_SIZE.y * 0.5)
	# expand/stretch BEFORE size (same latent clamp as the bar art above)
	smith_popout.stretch_mode = TextureRect.STRETCH_SCALE
	smith_popout.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	smith_popout.size = SMITH_POP_SIZE
	smith_popout.pivot_offset = Vector2(0.0, SMITH_POP_SIZE.y * 0.5)
	smith_popout.scale = Vector2(0.0, 1.0)
	smith_popout.show_behind_parent = true
	smith_popout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	smith_popout.visible = false
	chip.add_child(smith_popout)

func _on_smith_chip() -> void:
	main.upgrade_iron_cap()

func _on_smith_hover(over: bool) -> void:
	# hover only dims — the pop-out and glow are affordability-driven in _process, not by hover.
	if smith_chip == null or not is_instance_valid(smith_chip):
		return
	smith_chip.modulate = Color(0.7, 0.7, 0.7, 1.0) if over else Color.WHITE

func _mk_label(size: int, color: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l

# DroidSans-Bold (staged) stands in for the engine's font://Helvetica-Bold HUD numerals.
const HUD_FONT_PATH := "res://assets/fonts/DroidSans-Bold.ttf"
var _hud_font: FontFile

func _num_label(size: int, color: Color) -> Label:
	var l := _mk_label(size, color)
	if _hud_font == null and ResourceLoader.exists(HUD_FONT_PATH):
		_hud_font = load(HUD_FONT_PATH)
	if _hud_font != null:
		l.add_theme_font_override("font", _hud_font)
	return l

func _process(dt: float) -> void:
	var in_endless: bool = main.endless_mode and main.endless != null
	# true hp ratio, full when Ash is absent — deliberate deviation from the Lua fuel gauge (0.75); revert to the gauge to restore 1:1.
	var ratio := 1.0
	if main.ash != null and is_instance_valid(main.ash) and main.ash.max_health > 0.0:
		ratio = clampf(main.ash.health / main.ash.max_health, 0.0, 1.0)
	ash_life_fill.size.x = LB_FILL_SIZE.x * ratio
	var red := 1.0 - ratio
	var green := ratio
	var mult := 1.0 / maxf(red, green)
	ash_life_fill.color = Color(red * mult, green * mult, 0.0, 1.0)
	if smith_recess != null:
		var reveal_target := clampf(float(main.iron_level) / 4.0, 0.0, 1.0)
		smith_fill_cur = move_toward(smith_fill_cur, reveal_target, dt * 2.0)
		smith_recess.size.x = SMITH_BAR_SIZE.x * smith_fill_cur
		var shift_x: float = -SMITH_BAR_SIZE.x * (1.0 - smith_fill_cur)
		if smith_bar_back != null and is_instance_valid(smith_bar_back):
			smith_bar_back.position.x = shift_x
		if smith_bar_frame != null and is_instance_valid(smith_bar_frame):
			smith_bar_frame.position.x = shift_x
		smith_bar_fill.size = Vector2(
			SMITH_BAR_SIZE.x * smith_fill_cur \
			* (0.79 + (float(main.iron_level) - 1.0) * 0.05) \
			* clampf(main.iron / float(maxi(main.iron_cap, 1)), 0.0, 1.0),
			SMITH_BAR_SIZE.y * 0.48)
		smith_iron_label.text = "%d" % int(main.iron)
		var lvl_text := "MAX" if main.iron_level >= 4 else "L%d" % main.iron_level
		if smith_lvl_label.text != lvl_text:
			smith_lvl_label.text = lvl_text
			smith_lvl_label.add_theme_font_size_override("font_size",
				18 if main.iron_level >= 4 else 28)
		var can_up: bool = main.can_upgrade_iron_cap()
		var chip_art := HUD_ART + ("smith_button_glow.webp" if can_up else "smith_button.webp")
		if smith_chip.texture_normal == null \
				or smith_chip.texture_normal.resource_path != chip_art:
			smith_chip.texture_normal = load(chip_art)
		if can_up != _smith_pop_shown:
			_smith_pop_shown = can_up
			if _smith_pop_tween != null and _smith_pop_tween.is_valid():
				_smith_pop_tween.kill()
			if can_up:
				smith_popout.visible = true
				_smith_pop_tween = create_tween()
				_smith_pop_tween.tween_property(smith_popout, "scale:x", 1.0, 0.25)
			else:
				_smith_pop_tween = create_tween()
				_smith_pop_tween.tween_property(smith_popout, "scale:x", 0.0, 0.25)
				_smith_pop_tween.tween_callback(func() -> void:
					smith_popout.visible = false)
	if in_endless:
		wave_bar.visible = false
		score_plate.visible = true
		score_label.visible = true
		var s := "%09d" % int(main.endless.score)
		var grouped := ""
		for i in range(0, s.length(), 3):
			grouped += s.substr(i, 3) + " "
		score_label.text = "Score: %s" % grouped.strip_edges()
	else:
		wave_bar.visible = true
		score_plate.visible = false
		score_label.visible = false
		var planned := 1
		if main.spawner != null:
			planned = maxi(main.spawner.total_planned(), 1)
		var p := clampf(float(main.enemies_killed) / float(planned), 0.0, 1.0)
		var fw := 347.0 * WAVE_SIZE.x / 384.0
		wave_fill.size = Vector2(fw * p, 28.0 * WAVE_SIZE.y / 62.0)
		wave_fill.position = Vector2(18.5 * WAVE_SIZE.x / 384.0 + fw * (1.0 - p),
			17.0 * WAVE_SIZE.y / 62.0)

	for type_name: String in unit_buttons:
		var b: Dictionary = unit_buttons[type_name]
		var cost := int(DB.get_stat("units", type_name, "iron_cost", 1))
		var cd: float = main.button_cooldowns.get(type_name, 0.0)
		b["cost"].text = str(cost)
		# stays grayed while its unique unit is alive on the field (the unique-lock, cleared by the unit's destroy).
		var locked_unique: bool = main.unique_locked(type_name)
		var usable: bool = cd <= 0.0 and not main.wave_over \
			and main.iron >= cost and not locked_unique
		(b["btn"] as TextureButton).modulate = Color(1, 1, 1, 1) if usable \
			else Color(0.45, 0.45, 0.45, 0.8)

	var equipped: Array = main.equipped_spells()
	for i in 2:
		var sb: Dictionary = spell_buttons[i]
		var btn: TextureButton = sb["btn"]
		if i < equipped.size():
			var id: String = equipped[i]
			if sb["icon"] != id:
				sb["icon"] = id
				var leaf: String = SPELL_ICONS.get(id, "icon_blank")
				btn.texture_normal = load(HUD_ART + leaf + ".webp")
				btn.size = (SPELL_SIZES.get(id, Vector2(151, 120)) as Vector2) \
					* ART_PX * SPELL_BTN_SCALE
				_layout_spell_buttons()
			var scd: float = main.spell_cooldowns.get(id, 0.0)
			(sb["cd"] as Label).text = ("%.0f" % scd) if scd > 0.0 else ""
			btn.modulate = Color(1, 1, 1, 1) if scd <= 0.0 else Color(0.5, 0.5, 0.5, 0.85)
		else:
			sb["icon"] = ""
			btn.texture_normal = load(HUD_ART + "icon_blank.webp")
			(sb["cd"] as Label).text = ""
			btn.modulate = Color(1, 1, 1, 0.4)

	if _push_anim > 0.0:
		_push_anim -= dt
		var a := clampf(_push_anim / 0.5, 0.0, 1.0)
		push_art.modulate.a = a
		# danger skulls latched red once — always reset to the art's own colors after the push.
		var flash_red := int(_push_anim * 12.0) % 2 == 0
		for icon: TextureRect in _danger_icons:
			if is_instance_valid(icon):
				icon.modulate = Color(1.0, 0.35, 0.35) if flash_red else Color.WHITE
		if _push_anim <= 0.0:
			for icon: TextureRect in _danger_icons:
				if is_instance_valid(icon):
					icon.modulate = Color.WHITE
			push_art.modulate.a = 0.0
		push_label.modulate.a = a
	if _msg_anim > 0.0:
		_msg_anim -= dt
		msg_label.modulate.a = clampf(_msg_anim / 0.6, 0.0, 1.0)

	# teardown_battle frees the gate while the HUD keeps processing — assign the typed local THROUGH the validity check, or assigning a freed instance to a typed Variable faults every frame.
	var gate_u: Unit = null
	if main.gate != null and is_instance_valid(main.gate):
		gate_u = main.gate
	var show_protect := false
	if gate_u != null and is_instance_valid(gate_u) \
			and gate_u.state != Unit.State.DEAD and main.gate_last_hit_at > 0:
		var since_hit := float(Time.get_ticks_msec() - main.gate_last_hit_at) / 1000.0
		if since_hit <= 2.0:
			var cam_left_x: float = main.camera.get_screen_center_position().x \
				- main.get_viewport_rect().size.x * 0.5 / main.camera.zoom.x
			show_protect = cam_left_x - gate_u.position.x > 60.0
	protect_icon.visible = show_protect
	if show_protect:
		_protect_t += dt
		var ph := fposmod(_protect_t, 1.0)
		protect_icon.modulate.a = 0.5 + 0.5 * ((ph / 0.5) if ph < 0.5 \
			else ((1.0 - ph) / 0.5))

func flash_message(text: String) -> void:
	msg_label.text = text
	_msg_anim = 2.2

func _on_unit_button(type_name: String) -> void:
	main.summon_ally(type_name)

func _set_tray_input(enabled: bool) -> void:
	## Godot GUI input walks children in reverse tree order and ignores z_index — drop the tray plates + smith chip to MOUSE_FILTER_IGNORE while the banner shows or they swallow CONTINUE clicks (the tray stays VISIBLE).
	var mf := Control.MOUSE_FILTER_STOP if enabled else Control.MOUSE_FILTER_IGNORE
	for type_name: String in unit_buttons:
		(unit_buttons[type_name]["btn"] as TextureButton).mouse_filter = mf
	if smith_chip != null and is_instance_valid(smith_chip):
		smith_chip.mouse_filter = mf

func _on_overlay_button() -> void:
	if main.wave_won:
		# gameOver already ran setCurrentWave(+1), so beating FINAL_WAVE lands here exactly once (== FINAL_WAVE + 1); endless wins never reach the banner, so it cannot re-fire.
		if GameState.current_wave == GameState.FINAL_WAVE + 1:
			GameState.unlock_endless()  # util.setEndlessModeUnlocked
			# checkpoint the unlock like main._finish_wave does — harness runs
			# (sandbox/smoke) never touch the real save
			if not main.sandbox and not Dbg.args.has("smoke-test"):
				GameState.save()
			main.menus.open_credits()
			overlay.visible = false
		else:
			main.menus.open_upgrades()
			overlay.visible = false
	else:
		# wave 1 restarts in place; wave > 1 opens the upgrade shop (a loss never advanced current_wave, so the shop's PLAY re-enters start_wave(current_wave)).
		if GameState.current_wave == 1:
			main.request_retry()
			return
		main.teardown_battle()
		# a loss must never chain the unlock screens — drop any stale _from_win flag first.
		main.menus._from_win = false
		main.menus.open_upgrades()
		overlay.visible = false
		if _blood != null:
			_blood.visible = false  # the held defeat blood clears with the banner

func _on_spell_button(slot: int) -> void:
	# castCurrentSpell: main computes the non-user-targeted landing point
	# (ash + 120 + the spell's auto_target_offset)
	var equipped: Array = main.equipped_spells()
	if slot < equipped.size():
		main.cast_spell(equipped[slot])

func _unhandled_input(event: InputEvent) -> void:
	## keys emit the same pressed signals as clicks, so the handlers' own gating applies; the extra guards cover what a click's environment provides (upgrade_iron_cap/cast_spell do NOT self-gate wave_over) — and _unhandled_input (not _input) so keys a focused Control eats never double-fire.
	if not visible or main == null:
		return
	if get_tree().paused or (main.menus != null and main.menus.is_open()) \
			or main.wave_over:
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key: int = event.keycode
	if key == KEY_NONE:
		key = event.physical_keycode  # synthetic events may only set physical
	match key:
		KEY_1, KEY_2, KEY_3, KEY_4, KEY_5:
			# unit_buttons fills in the HBox's add order, so values() IS the visible rendered order; later keys no-op on short trays.
			var slot := key - KEY_1
			var rendered := unit_buttons.values()
			if slot < rendered.size():
				var btn: TextureButton = rendered[slot]["btn"]
				if btn != null and is_instance_valid(btn) \
						and btn.is_visible_in_tree():
					btn.pressed.emit()
		KEY_6:
			if smith_chip != null and is_instance_valid(smith_chip) \
					and smith_chip.is_visible_in_tree():
				smith_chip.pressed.emit()
		KEY_Q:
			_press_spell_key(0)
		KEY_E:
			_press_spell_key(1)

func _press_spell_key(slot: int) -> void:
	## a hidden plate (the tutorial masks both at wave 1) is key-dead too; unequipped slots no-op in _on_spell_button.
	if slot < spell_buttons.size():
		var btn: TextureButton = spell_buttons[slot]["btn"]
		if btn != null and is_instance_valid(btn) and btn.is_visible_in_tree():
			btn.pressed.emit()

func on_wave_started(_n: int) -> void:
	if _over_tween != null and _over_tween.is_valid():
		_over_tween.kill()
	for c in _tally_nodes:
		c.queue_free()
	_tally_nodes.clear()
	overlay.visible = false
	if _blood != null:
		_blood.visible = false  # a held defeat overlay clears with the wave
	_set_tray_input(true)  # FINAL-09: restore the tray after the banner
	wave_num_override = 0
	set_spells_visible(true)
	_rebuild_unit_bar()  # loadout may have changed in the between-wave menus
	_rebuild_danger_icons()

func on_iron_changed() -> void:
	pass  # readouts refresh every frame

func set_spells_visible(shown: bool) -> void:
	for i in spell_buttons.size():
		set_spell_button_visible(i, shown)

func set_spell_button_visible(slot: int, shown: bool) -> void:
	if slot < 0 or slot >= spell_buttons.size():
		return
	(spell_buttons[slot]["btn"] as TextureButton).visible = shown

func _rebuild_danger_icons() -> void:
	## one skull per "push" entry; percent = the entry's 1-BASED index within the FULL unit_stat / the resolved-unit count; z = percent * 10 so later pushes draw on top.
	for c in _danger_icons:
		c.queue_free()
	_danger_icons.clear()
	# endless (wave_51) carries unit_stat as an empty DICT, not an array — a non-array (or missing) unit_stat just means no push skulls.
	var stats_v: Variant = DB.get_wave_data(GameState.current_wave).get("unit_stat", [])
	var stats: Array = stats_v if stats_v is Array else []
	var num_dudes: int = main.get_wave_unit_total(GameState.current_wave)
	for i in stats.size():
		if str(stats[i].get("tag", "")) != "push":
			continue
		var icon := TextureRect.new()
		icon.texture = load(HUD_ART + "enemy_progress_danger.webp")
		# expand/stretch BEFORE size (see the smith bar note above)
		icon.stretch_mode = TextureRect.STRETCH_SCALE
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.size = Vector2(75.0, 66.0) * ART_PX  # native * ratio * 2
		var percent := float(i + 1) / float(maxi(num_dudes, 1))
		icon.position = Vector2(WAVE_SIZE.x * (1.0 - percent), WAVE_SIZE.y * 0.5) \
			- icon.size * 0.5
		icon.pivot_offset = icon.size * 0.5
		icon.z_index = roundi(percent * 10.0)
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		wave_bar.add_child(icon)
		_danger_icons.append(icon)

func flash_push() -> void:
	_push_anim = 1.4
	push_label.text = ""
	var k := maxi(int(main.wave_push_count) - 1, 0)
	if k < _danger_icons.size():
		var icon: TextureRect = _danger_icons[k]
		var tw := create_tween()
		tw.set_loops(6)
		tw.tween_property(icon, "scale", Vector2.ONE * 1.1, 1.0 / 12.0) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		tw.tween_property(icon, "scale", Vector2.ONE, 1.0 / 12.0) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

# DroidSerif-Bold (staged) stands in for the original's Georgia Bold UI serif.
const SERIF_FONT_PATH := "res://assets/fonts/DroidSerif-Bold.ttf"
var _serif_font: FontFile

func show_wave_over(won: bool, awarded := 0, collected := 0) -> void:
	if _over_tween != null and _over_tween.is_valid():
		_over_tween.kill()
	for c in _tally_nodes:
		c.queue_free()
	_tally_nodes.clear()
	overlay.visible = true
	overlay.modulate.a = 1.0
	overlay_dim.modulate.a = 0.0
	_set_tray_input(false)  # FINAL-09: plates must not steal CONTINUE clicks
	var bsize := VICTORY_BANNER_SIZE if won else DEFEAT_BANNER_SIZE
	overlay_banner.texture = load("res://assets/ui/banner_victory.webp" if won
		else "res://assets/ui/banner_deadites_win.webp")
	overlay_banner.size = bsize
	overlay_banner.position = Vector2(480.0 - bsize.x * 0.5,
		BANNER_BOTTOM_Y - bsize.y)
	overlay_banner.modulate.a = 0.0
	overlay_button.texture_normal = load(HUD_ART + "continue_button.webp")
	overlay_button.modulate.a = 0.0
	overlay_button.visible = true
	if not won:
		hold_blood_overlay(0.7)
	_over_tween = create_tween()
	_over_tween.tween_property(overlay_banner, "modulate:a", 1.0, 0.25)
	_over_tween.tween_interval(TALLY_FADE_DELAY - 0.25)
	_over_tween.tween_callback(_overlay_phase_two.bind(won, awarded, collected))

func _overlay_phase_two(won: bool, awarded: int, collected: int) -> void:
	_over_tween = create_tween()
	_over_tween.tween_property(overlay_dim, "modulate:a", 1.0, 0.125)
	_over_tween.tween_property(overlay_button, "modulate:a", 1.0, 0.25)
	# no win gate on the tally — the defeat (endless) screen shows the collected row too.
	if awarded != 0 or collected != 0:
		_build_gold_tally(awarded, collected)

func _build_gold_tally(awarded: int, collected: int) -> void:
	## labels fade in WHITE (the Lua overwrites its gold), amounts right-aligned at TR-coin with the coin touching each amount's right edge.
	var rows := [
		["Awarded:", awarded],
		["Collected:", collected],
		["Total:", awarded + collected],
	]
	if _serif_font == null and ResourceLoader.exists(SERIF_FONT_PATH):
		_serif_font = load(SERIF_FONT_PATH)
	for i in rows.size():
		var row_top := TALLY_TOP_LEFT.y + TALLY_ROW_PITCH * float(i)
		var lab := Label.new()
		lab.text = str(rows[i][0])
		if _serif_font != null:
			lab.add_theme_font_override("font", _serif_font)
		lab.add_theme_font_size_override("font_size", TALLY_FONT_PX)
		lab.add_theme_color_override("font_color", Color.WHITE)
		lab.position = Vector2(TALLY_TOP_LEFT.x, row_top - 6.0)
		lab.size = Vector2(TALLY_LABEL_W, TALLY_FONT_PX + 8.0)
		lab.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lab.z_index = 1  # anchor z=1: the tally text layers OVER the coin_box
		overlay.add_child(lab)
		_tally_nodes.append(lab)
		var amount := Label.new()
		amount.text = "%d" % int(rows[i][1])
		if _hud_font == null and ResourceLoader.exists(HUD_FONT_PATH):
			_hud_font = load(HUD_FONT_PATH)
		if _hud_font != null:
			amount.add_theme_font_override("font", _hud_font)
		amount.add_theme_font_size_override("font_size", TALLY_FONT_PX)
		amount.add_theme_color_override("font_color", Color.WHITE)
		amount.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		amount.position = Vector2(TALLY_AMOUNT_RIGHT - 200.0, row_top - 6.0)
		amount.size = Vector2(200.0, TALLY_FONT_PX + 8.0)
		amount.mouse_filter = Control.MOUSE_FILTER_IGNORE
		amount.z_index = 1
		overlay.add_child(amount)
		_tally_nodes.append(amount)
		var coin := TextureRect.new()
		coin.texture = load("res://assets/ui/menu/upgrade_gold_coin.webp")
		coin.stretch_mode = TextureRect.STRETCH_SCALE
		coin.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		var csize := Vector2(75.0, 74.0) * ART_PX
		coin.size = csize
		coin.position = Vector2(TALLY_AMOUNT_RIGHT,
			row_top + TALLY_FONT_PX * 0.5 + 5.0 * WORLD_PX - csize.y * 0.5)
		coin.mouse_filter = Control.MOUSE_FILTER_IGNORE
		coin.z_index = 1
		overlay.add_child(coin)
		_tally_nodes.append(coin)
	var box := TextureRect.new()
	box.texture = load(HUD_ART + "coin_box.webp")
	box.stretch_mode = TextureRect.STRETCH_SCALE
	box.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	box.position = COIN_BOX_POS
	box.size = COIN_BOX_SIZE
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(box)
	_tally_nodes.append(box)
	for n: Control in _tally_nodes:
		n.modulate.a = 0.0
		_over_tween.parallel().tween_property(n, "modulate:a", 1.0, 0.25)
