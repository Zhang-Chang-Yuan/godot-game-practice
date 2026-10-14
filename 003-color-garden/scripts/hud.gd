class_name ColorHud
extends Control
# 顶栏：图案选择 + 操作按钮 + 状态 + 「本次点查询命中」演示区（demo 重点 1 的可视化）。

signal pattern_selected(pattern_name: String)
signal action_pressed(action: String)

const BAR_HEIGHT := 76.0
const ACTION_NAMES := ["SaveButton", "LoadButton", "ExportButton", "ResetButton"]
const ACTION_LABELS := {
	"SaveButton": "保存",
	"LoadButton": "载入",
	"ExportButton": "导出PNG",
	"ResetButton": "重置",
}

var _pattern_buttons: Dictionary = {}     # pattern_name -> Button
var _action_buttons: Dictionary = {}      # node_name -> Button
var _status: Label = null
var _hit_label: Label = null
var _hit_ids: Array = []
var _status_cache := ""


func build() -> void:
	custom_minimum_size = Vector2(0.0, BAR_HEIGHT)

	var panel := PanelContainer.new()
	panel.name = "HudPanel"
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var psb := StyleBoxFlat.new()
	psb.bg_color = Color(0.13, 0.14, 0.18)
	psb.set_corner_radius_all(10)
	psb.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", psb)
	add_child(panel)

	var col := VBoxContainer.new()
	col.name = "HudColumn"
	col.add_theme_constant_override("separation", 6)
	panel.add_child(col)

	# --- 第一行：图案 + 操作 ---
	var row1 := HBoxContainer.new()
	row1.name = "HudRow1"
	row1.add_theme_constant_override("separation", 8)
	col.add_child(row1)

	var pl := Label.new()
	pl.name = "PatternLabel"
	pl.text = "图案"
	pl.add_theme_font_size_override("font_size", 13)
	row1.add_child(pl)

	for name in PatternSchema.PATTERNS:
		var b := Button.new()
		b.name = "Pattern_" + String(name)
		b.text = PatternSchema.display_name(String(name))
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(62.0, 30.0)
		b.pressed.connect(_on_pattern_pressed.bind(String(name)))
		row1.add_child(b)
		_pattern_buttons[String(name)] = b

	var spacer := Control.new()
	spacer.name = "HudSpacer"
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row1.add_child(spacer)

	for an in ACTION_NAMES:
		var ab := Button.new()
		ab.name = an
		ab.text = String(ACTION_LABELS[an])
		ab.focus_mode = Control.FOCUS_NONE
		ab.custom_minimum_size = Vector2(78.0, 30.0)
		ab.pressed.connect(_on_action_pressed.bind(an))
		row1.add_child(ab)
		_action_buttons[an] = ab

	# --- 第二行：状态 + 命中演示 ---
	var row2 := HBoxContainer.new()
	row2.name = "HudRow2"
	row2.add_theme_constant_override("separation", 14)
	col.add_child(row2)

	_status = Label.new()
	_status.name = "StatusLabel"
	_status.text = "—"
	_status.add_theme_font_size_override("font_size", 12)
	row2.add_child(_status)

	_hit_label = Label.new()
	_hit_label.name = "HitLabel"
	_hit_label.text = "本次命中 0 个区域"
	_hit_label.add_theme_font_size_override("font_size", 12)
	_hit_label.add_theme_color_override("font_color", Color(0.55, 0.85, 1.0))
	row2.add_child(_hit_label)


func _on_pattern_pressed(name: String) -> void:
	pattern_selected.emit(name)


func _on_action_pressed(action: String) -> void:
	action_pressed.emit(action)


# ---------------------------------------------------------------- 对外接口

## demo 重点 1 的可视化：把点查询命中的**全部**区域列出来
func set_hit_info(hit_ids: Array) -> void:
	_hit_ids = hit_ids.duplicate()
	if _hit_label == null:
		return
	if hit_ids.is_empty():
		_hit_label.text = "本次命中 0 个区域"
	else:
		var names: Array[String] = []
		for rid in hit_ids:
			names.append(String(rid))
		_hit_label.text = "本次命中 %d 个区域：%s" % [hit_ids.size(), ", ".join(names)]


func hit_ids() -> Array:
	return _hit_ids.duplicate()


func refresh() -> void:
	if _status == null:
		return
	var txt := "图案 %s ｜ 已涂 %d/%d ｜ 笔刷强度 %.2f" % [
		PatternSchema.display_name(PaintState.pattern_name) if not PaintState.pattern_name.is_empty() else "—",
		PaintState.painted_count(),
		PaintState.region_count(),
		PaintState.brush_strength,
	]
	if txt != _status_cache:
		_status_cache = txt
		_status.text = txt
	for name in _pattern_buttons:
		var b: Button = _pattern_buttons[name]
		b.disabled = (String(name) == PaintState.pattern_name)


func button(node_name: String) -> Button:
	return _action_buttons.get(node_name, null) as Button


func pattern_button(pattern_name: String) -> Button:
	return _pattern_buttons.get(pattern_name, null) as Button


func status_text() -> String:
	return _status_cache


func hit_text() -> String:
	return _hit_label.text if _hit_label != null else ""
