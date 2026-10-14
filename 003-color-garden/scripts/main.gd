extends Control
# 003-color-garden 装配层：背景 + 顶部 HUD + 左侧画布 + 右侧色板。
# 只负责摆位置和接线，业务逻辑都在各模块里。

const HUD_HEIGHT := 76.0
const PALETTE_WIDTH := 320.0
const MARGIN := 12.0

var _bg: ColorRect = null
var _hud: ColorHud = null
var _palette: PalettePanel = null
var _canvas_area: Control = null
var _canvas: CanvasView = null
var _intro_tween: Tween = null


func _ready() -> void:
	_build_ui()
	_connect_signals()
	# 启动即加载第一个图案
	PaintState.load_pattern(String(PatternSchema.PATTERNS[0]))
	_recenter_canvas.call_deferred()
	_refresh_all()


# ---------------------------------------------------------------- 构建

func _build_ui() -> void:
	_bg = ColorRect.new()
	_bg.name = "Background"
	_bg.color = Color(0.07, 0.08, 0.11)
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)

	# --- 顶部 HUD ---
	_hud = ColorHud.new()
	_hud.name = "Hud"
	_hud.anchor_left = 0.0
	_hud.anchor_right = 1.0
	_hud.anchor_top = 0.0
	_hud.anchor_bottom = 0.0
	_hud.offset_left = MARGIN
	_hud.offset_right = -MARGIN
	_hud.offset_top = MARGIN
	_hud.offset_bottom = MARGIN + HUD_HEIGHT
	add_child(_hud)
	_hud.build()

	# --- 右侧色板（右下角贴边，全高）---
	_palette = PalettePanel.new()
	_palette.name = "Palette"
	_palette.anchor_left = 1.0
	_palette.anchor_right = 1.0
	_palette.anchor_top = 0.0
	_palette.anchor_bottom = 1.0
	_palette.offset_left = -(MARGIN + PALETTE_WIDTH)
	_palette.offset_right = -MARGIN
	_palette.offset_top = MARGIN + HUD_HEIGHT + MARGIN
	_palette.offset_bottom = -MARGIN
	add_child(_palette)
	_palette.build()

	# --- 左侧画布区 ---
	_canvas_area = Control.new()
	_canvas_area.name = "CanvasArea"
	_canvas_area.anchor_left = 0.0
	_canvas_area.anchor_right = 1.0
	_canvas_area.anchor_top = 0.0
	_canvas_area.anchor_bottom = 1.0
	_canvas_area.offset_left = MARGIN
	_canvas_area.offset_right = -(MARGIN + PALETTE_WIDTH + MARGIN)
	_canvas_area.offset_top = MARGIN + HUD_HEIGHT + MARGIN
	_canvas_area.offset_bottom = -MARGIN
	_canvas_area.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_canvas_area)

	# 画布底板（让 512×512 的范围看得出来）
	var board := ColorRect.new()
	board.name = "Board"
	board.color = Color(0.10, 0.11, 0.145)
	board.size = Vector2(PatternSchema.CANVAS_SIZE)
	board.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas_area.add_child(board)

	_canvas = CanvasView.new()
	_canvas.name = "CanvasView"
	_canvas_area.add_child(_canvas)


func _connect_signals() -> void:
	_hud.pattern_selected.connect(_on_pattern_selected)
	_hud.action_pressed.connect(_on_action_pressed)
	_palette.color_selected.connect(_on_color_selected)
	_palette.strength_changed.connect(_on_strength_changed)
	_canvas.region_hit.connect(_on_region_hit)
	_canvas.canvas_rebuilt.connect(_on_canvas_rebuilt)
	_canvas_area.resized.connect(_recenter_canvas)
	PaintState.pattern_loaded.connect(_on_pattern_loaded)
	PaintState.region_painted.connect(_on_region_painted)
	PaintState.brush_changed.connect(_on_brush_changed)
	PaintState.state_reset.connect(_on_state_reset)
	PaintState.artwork_loaded.connect(_on_artwork_loaded)


func _recenter_canvas() -> void:
	if _canvas == null or _canvas_area == null:
		return
	var s := Vector2(PatternSchema.CANVAS_SIZE)
	var avail := _canvas_area.size
	var pos := Vector2(
		maxf((avail.x - s.x) * 0.5, 0.0),
		maxf((avail.y - s.y) * 0.5, 0.0)
	)
	_canvas.position = pos
	var board := _canvas_area.get_node_or_null("Board")
	if board is Control:
		(board as Control).position = pos
		(board as Control).size = s


# ---------------------------------------------------------------- 接线

func _on_pattern_selected(name: String) -> void:
	PaintState.load_pattern(name)


func _on_pattern_loaded(_name: String) -> void:
	_canvas.build_from_pattern(PaintState.pattern)
	_recenter_canvas()
	if _intro_tween != null and _intro_tween.is_valid():
		_intro_tween.kill()
	_intro_tween = Fx.stagger_intro(_canvas.get_children(), 0.02, 0.3)
	_refresh_all()


func _on_color_selected(c: Color) -> void:
	PaintState.set_brush(c)


func _on_brush_changed(c: Color) -> void:
	_palette.set_selected(c)


func _on_strength_changed(v: float) -> void:
	PaintState.set_brush_strength(v)


func _on_region_hit(hit_ids: Array, _painted: String) -> void:
	_hud.set_hit_info(hit_ids)
	_canvas.highlight_only(hit_ids)
	if not hit_ids.is_empty():
		_palette.set_region_preview(PaintState.region_color(String(hit_ids[0])))
	_refresh_all()


func _on_region_painted(_rid: String, _col: Color, _hits: Array) -> void:
	_refresh_all()


func _on_canvas_rebuilt(_n: int) -> void:
	_refresh_all()


func _on_state_reset() -> void:
	_sync_canvas_colors()
	_refresh_all()


func _on_artwork_loaded(_path: String) -> void:
	_sync_canvas_colors()
	_refresh_all()


func _on_action_pressed(action: String) -> void:
	match action:
		"SaveButton":
			PaintState.save_artwork()
		"LoadButton":
			PaintState.load_artwork()
		"ExportButton":
			PaintState.export_png()
		"ResetButton":
			PaintState.reset_all()
	_refresh_all()


func _sync_canvas_colors() -> void:
	if _canvas == null:
		return
	for rid in _canvas.region_ids():
		var reg := _canvas.region_node(rid)
		if reg != null:
			reg.set_fill_color(PaintState.region_color(rid))


func _refresh_all() -> void:
	if _hud != null:
		_hud.refresh()


# ---------------------------------------------------------------- 输入

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return

	# 用画布坐标系里的鼠标位置；物理点查询用的就是这套世界坐标
	var wpos := get_global_mouse_position()
	var rect := Rect2(_canvas_area.global_position, _canvas_area.size)
	if not rect.has_point(wpos):
		return

	_canvas.paint_at(wpos)
	get_viewport().set_input_as_handled()
