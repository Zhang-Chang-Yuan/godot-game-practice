extends Node
# PaintState：单一状态源（autoload 名 PaintState）。
# 当前图案 / 笔刷 / 每个区域已累积的颜色 / 存盘与导出。
# 加色混合一律调 PaletteDef，本文件不自己写颜色公式。

signal pattern_loaded(pattern_name: String)
signal region_painted(region_id: String, new_color: Color, hit_ids: Array)
signal brush_changed(color: Color)
signal strength_changed(strength: float)
signal artwork_saved(path: String)
signal artwork_loaded(path: String)
signal artwork_exported(path: String)
signal state_reset()

const SAVE_PATH := "user://artwork.json"
const EXPORT_PATH := "user://artwork.png"
const SAVE_VERSION := 1
const MIN_STRENGTH := 0.05
const MAX_STRENGTH := 1.0

var pattern_name: String = ""
var pattern: Dictionary = {}
var brush_color: Color = PaletteDef.BASE_COLOR
var brush_strength: float = PaletteDef.DEFAULT_STRENGTH
var colors: Dictionary = {}          # region_id -> Color（已累积）


func _ready() -> void:
	brush_color = PaletteDef.palette_color(0)
	brush_strength = PaletteDef.DEFAULT_STRENGTH


# ---------------------------------------------------------------- 图案

func load_pattern(name: String) -> Error:
	var d := PatternData.load_pattern(name)
	if d.is_empty():
		return ERR_DOES_NOT_EXIST
	pattern = d
	pattern_name = name
	colors.clear()
	pattern_loaded.emit(pattern_name)
	return OK


func region_count() -> int:
	var rv: Variant = pattern.get("regions", [])
	return (rv as Array).size() if rv is Array else 0


func painted_count() -> int:
	var n := 0
	for rid in colors:
		if not PaletteDef.is_base(colors[rid] as Color):
			n += 1
	return n


# ---------------------------------------------------------------- 笔刷

func set_brush(color: Color) -> void:
	brush_color = color
	brush_changed.emit(brush_color)


func set_brush_strength(v: float) -> void:
	brush_strength = clampf(v, MIN_STRENGTH, MAX_STRENGTH)
	strength_changed.emit(brush_strength)


# ---------------------------------------------------------------- 上色

func region_color(region_id: String) -> Color:
	if colors.has(region_id):
		return colors[region_id] as Color
	return PaletteDef.BASE_COLOR


func apply_to_region(region_id: String) -> Color:
	var next := PaletteDef.add_color(region_color(region_id), brush_color, brush_strength)
	colors[region_id] = next
	region_painted.emit(region_id, next, [region_id])
	return next


## 命中多个区域时，**每个区域各自**加上一遍笔刷颜色（加色混合）。
## 返回第一个命中区域的新颜色。
func apply_to_regions(region_ids: Array) -> Color:
	if region_ids.is_empty():
		return PaletteDef.BASE_COLOR
	var first := PaletteDef.BASE_COLOR
	var hit_list: Array = []
	for rid_v in region_ids:
		var rid := String(rid_v)
		var next := PaletteDef.add_color(region_color(rid), brush_color, brush_strength)
		colors[rid] = next
		hit_list.append(rid)
		if first == PaletteDef.BASE_COLOR or rid == String(region_ids[0]):
			first = next
	region_painted.emit(String(region_ids[0]), first, hit_list)
	return first


## 多个颜色加色求和（调色板"混色预览"用）。等价于依次 add_color。
func mixed_preview(brushes: Array) -> Color:
	return PaletteDef.add_many(PaletteDef.BASE_COLOR, brushes, 1.0)


func reset_region(region_id: String) -> void:
	colors.erase(region_id)


func reset_all() -> void:
	colors.clear()
	state_reset.emit()


# ---------------------------------------------------------------- 存盘

func to_dict() -> Dictionary:
	var cols := {}
	for rid in colors:
		cols[String(rid)] = PaletteDef.color_to_array(colors[rid] as Color)
	return { "version": SAVE_VERSION, "pattern": pattern_name, "colors": cols }


func save_artwork(path: String = SAVE_PATH) -> Error:
	if pattern_name.is_empty():
		return ERR_UNCONFIGURED
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(to_dict(), "\t"))
	f.close()
	artwork_saved.emit(path)
	return OK


func load_artwork(path: String = SAVE_PATH) -> Error:
	if not FileAccess.file_exists(path):
		return ERR_FILE_NOT_FOUND
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return FileAccess.get_open_error()
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return ERR_PARSE_ERROR
	return from_dict(parsed as Dictionary)


## 从字典恢复。脏数据返回错误码，绝不崩溃。
func from_dict(d: Dictionary) -> Error:
	var pname := String(d.get("pattern", ""))
	if not PatternSchema.is_valid_name(pname):
		return ERR_INVALID_DATA

	var cols_v: Variant = d.get("colors", null)
	if not (cols_v is Dictionary):
		return ERR_PARSE_ERROR

	var loaded_pattern := PatternData.load_pattern(pname)
	if loaded_pattern.is_empty():
		return ERR_INVALID_DATA
	var known := PatternData.region_id_set(loaded_pattern)

	var loaded := {}
	for k in (cols_v as Dictionary):
		var rid := String(k)
		if not known.has(rid):
			continue                      # 未知 region_id：跳过
		var cv: Variant = (cols_v as Dictionary)[k]
		if not (cv is Array) or (cv as Array).size() < 3:
			continue                      # 非法颜色：跳过
		loaded[rid] = PaletteDef.array_to_color(cv)

	pattern = loaded_pattern
	pattern_name = pname
	colors = loaded
	pattern_loaded.emit(pattern_name)
	artwork_loaded.emit(SAVE_PATH)
	return OK


# ---------------------------------------------------------------- 导出

func export_png(path: String = EXPORT_PATH) -> Error:
	if pattern.is_empty():
		return ERR_UNCONFIGURED
	var err := ArtworkExport.export_png(pattern, colors, PatternSchema.CANVAS_SIZE, path)
	if err == OK:
		artwork_exported.emit(path)
	return err
