class_name PalettePanel
extends Control
# 色板 UI（全代码创建）。16 个色块（4 列 × 4 行）+ 笔刷强度 + 两个预览色块。
# 前 7 个色块带金色描边，它们是 demo 重点 3「加色混合」的演示色。

signal color_selected(color: Color)
signal strength_changed(strength: float)

const COLUMNS := 4
const SWATCH_SIZE := Vector2(66.0, 44.0)
const DEMO_BORDER := Color(1.0, 0.85, 0.35)
const NORMAL_BORDER := Color(0.16, 0.17, 0.22)
const SELECT_BORDER := Color(1.0, 1.0, 1.0)
const MIN_STRENGTH := 0.05
const MAX_STRENGTH := 1.0

var _swatches: Array[Control] = []
var _boxes: Array[StyleBoxFlat] = []
var _selected := -1
var _selected_color: Color = PaletteDef.BASE_COLOR
var _strength: HSlider = null
var _brush_preview: ColorRect = null
var _region_preview: ColorRect = null
var _pop_tween: Tween = null


func build() -> void:
	var panel := PanelContainer.new()
	panel.name = "PalettePanelRoot"
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var psb := StyleBoxFlat.new()
	psb.bg_color = Color(0.13, 0.14, 0.18)
	psb.set_corner_radius_all(10)
	psb.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", psb)
	add_child(panel)

	var col := VBoxContainer.new()
	col.name = "PaletteColumn"
	col.add_theme_constant_override("separation", 10)
	panel.add_child(col)

	var title := Label.new()
	title.name = "PaletteTitle"
	title.text = "色板"
	title.add_theme_font_size_override("font_size", 18)
	col.add_child(title)

	var demo_hint := Label.new()
	demo_hint.name = "DemoHint"
	demo_hint.text = "金框 = 加色三原色与混色\n（红+绿=黄  红+蓝=品红  绿+蓝=青）"
	demo_hint.add_theme_font_size_override("font_size", 11)
	demo_hint.add_theme_color_override("font_color", Color(0.95, 0.82, 0.42))
	col.add_child(demo_hint)

	var grid := GridContainer.new()
	grid.name = "SwatchGrid"
	grid.columns = COLUMNS
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	col.add_child(grid)

	for i in PaletteDef.palette_size():
		var b := _make_swatch(i)
		grid.add_child(b)
		_swatches.append(b)

	# 预览区
	var preview_row := HBoxContainer.new()
	preview_row.name = "PreviewRow"
	preview_row.add_theme_constant_override("separation", 10)
	col.add_child(preview_row)

	_brush_preview = _make_preview("BrushPreview", "笔刷")
	preview_row.add_child(_brush_preview.get_parent())
	_region_preview = _make_preview("RegionPreview", "区域")
	preview_row.add_child(_region_preview.get_parent())

	# 笔刷强度
	var strength_label := Label.new()
	strength_label.name = "StrengthLabel"
	strength_label.text = "笔刷强度"
	strength_label.add_theme_font_size_override("font_size", 12)
	col.add_child(strength_label)

	_strength = HSlider.new()
	_strength.name = "StrengthSlider"
	_strength.min_value = MIN_STRENGTH
	_strength.max_value = MAX_STRENGTH
	_strength.step = 0.01
	_strength.value = PaletteDef.DEFAULT_STRENGTH
	_strength.custom_minimum_size = Vector2(0.0, 24.0)
	_strength.value_changed.connect(_on_strength_changed)
	col.add_child(_strength)

	_apply_selection(0, false)


func _make_swatch(i: int) -> Button:
	var c: Color = PaletteDef.palette_color(i)
	var is_demo: bool = bool(PaletteDef.PALETTE[i].get("demo", false))

	var b := Button.new()
	b.name = "Swatch%d" % i
	b.text = PaletteDef.palette_name(i)
	b.custom_minimum_size = SWATCH_SIZE
	b.focus_mode = Control.FOCUS_NONE
	b.tooltip_text = "%s  RGB(%.2f, %.2f, %.2f)" % [PaletteDef.palette_name(i), c.r, c.g, c.b]

	var sb := StyleBoxFlat.new()
	sb.bg_color = c
	sb.set_corner_radius_all(6)
	sb.set_border_width_all(2)
	sb.border_color = DEMO_BORDER if is_demo else NORMAL_BORDER
	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_stylebox_override("hover", sb)
	b.add_theme_stylebox_override("pressed", sb)
	b.add_theme_stylebox_override("focus", sb)
	b.add_theme_color_override("font_color", Color(0.06, 0.06, 0.09))
	b.add_theme_color_override("font_hover_color", Color(0.06, 0.06, 0.09))
	b.add_theme_color_override("font_pressed_color", Color(0.06, 0.06, 0.09))
	b.add_theme_font_size_override("font_size", 12)

	b.pressed.connect(_on_swatch_pressed.bind(i))
	_boxes.append(sb)
	return b


func _make_preview(node_name: String, label_text: String) -> ColorRect:
	var box := VBoxContainer.new()
	box.name = node_name + "Box"
	var lab := Label.new()
	lab.text = label_text
	lab.add_theme_font_size_override("font_size", 11)
	box.add_child(lab)
	var rect := ColorRect.new()
	rect.name = node_name
	rect.color = PaletteDef.BASE_COLOR
	rect.custom_minimum_size = Vector2(96.0, 28.0)
	box.add_child(rect)
	return rect


func _on_swatch_pressed(i: int) -> void:
	_apply_selection(i, true)


## emit_signal = false 时只更新外观，用于外部同步（避免与 PaintState.brush_changed 形成回环）
func _apply_selection(i: int, emit_signal_flag: bool) -> void:
	if i < 0 or i >= _swatches.size():
		return
	_selected = i
	_selected_color = PaletteDef.palette_color(i)
	for k in _boxes.size():
		var is_demo: bool = bool(PaletteDef.PALETTE[k].get("demo", false))
		_boxes[k].border_color = SELECT_BORDER if k == i else (DEMO_BORDER if is_demo else NORMAL_BORDER)
		_boxes[k].set_border_width_all(3 if k == i else 2)
	if _brush_preview != null:
		_brush_preview.color = _selected_color
	if emit_signal_flag:
		_play_pop(_swatches[i])
		color_selected.emit(_selected_color)


func _play_pop(node: Control) -> void:
	if _pop_tween != null and _pop_tween.is_valid():
		_pop_tween.kill()
	_pop_tween = Fx.swatch_pop(node, 0.18)


func _on_strength_changed(v: float) -> void:
	strength_changed.emit(v)


# ---------------------------------------------------------------- 对外接口

## 外部同步选中态（不触发 color_selected 信号）
func set_selected(color: Color) -> void:
	for i in _swatches.size():
		if PaletteDef.palette_color(i).is_equal_approx(color):
			_apply_selection(i, false)
			return


func set_region_preview(c: Color) -> void:
	if _region_preview != null:
		_region_preview.color = c


func set_strength(v: float) -> void:
	if _strength != null:
		_strength.set_value_no_signal(v)


func swatch_count() -> int:
	return _swatches.size()


func swatch_at(i: int) -> Control:
	if i < 0 or i >= _swatches.size():
		return null
	return _swatches[i]


func selected_color() -> Color:
	return _selected_color


func selected_index() -> int:
	return _selected


func strength() -> float:
	if _strength == null:
		return PaletteDef.DEFAULT_STRENGTH
	return _strength.value
