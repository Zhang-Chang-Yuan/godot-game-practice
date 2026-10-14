class_name ColorRegion
extends Area2D
# 一个可涂色区域 = Area2D（碰撞层 2）+ CollisionPolygon2D + Polygon2D（填充）+ Line2D（描边）。
# 点击检测由 CanvasView 通过 PhysicsPointQuery 完成，本类不处理输入。

const LAYER := 2
const OUTLINE_COLOR := Color(0.75, 0.85, 1.0)
const OUTLINE_WIDTH := 2.5
const HIGHLIGHT_COLOR := Color(1.0, 0.95, 0.55)
const HIGHLIGHT_WIDTH := 4.5
const FLASH_SEC := 0.25

var region_id: String = ""
var label: String = ""
var polygon: PackedVector2Array = PackedVector2Array()
var z_order: int = 0

var _fill: Polygon2D = null
var _outline: Line2D = null
var _shape: CollisionPolygon2D = null
var _flash_tween: Tween = null
## 记录所有创建过的填色 tween，供 active_tween_count() 做**真实**计数。
## 早期版本只保留最后一个 tween、并把计数写死成"0 或 1"，
## 结果"不堆叠"的断言是同义反复 —— 变异测试（去掉 kill）都能存活。见 README 踩坑第 10 条。
var _flash_tweens: Array[Tween] = []
var _highlighted := false


func setup(region_dict: Dictionary) -> void:
	region_id = String(region_dict.get("id", ""))
	label = String(region_dict.get("label", ""))
	polygon = PatternSchema.to_packed(region_dict.get("polygon", []))
	z_order = int(region_dict.get("z", 0))

	name = "Region_" + region_id
	z_index = z_order

	# 只被 direct space state 的点查询使用，不需要 overlap 信号
	collision_layer = 1 << (LAYER - 1)
	collision_mask = 0
	monitoring = false
	monitorable = true

	_fill = Polygon2D.new()
	_fill.name = "Fill"
	_fill.polygon = polygon
	_fill.color = PaletteDef.BASE_COLOR
	_fill.antialiased = true
	add_child(_fill)

	_shape = CollisionPolygon2D.new()
	_shape.name = "Shape"
	_shape.polygon = polygon
	add_child(_shape)

	_outline = Line2D.new()
	_outline.name = "Outline"
	_outline.width = OUTLINE_WIDTH
	_outline.default_color = OUTLINE_COLOR
	_outline.joint_mode = Line2D.LINE_JOINT_ROUND
	_outline.begin_cap_mode = Line2D.LINE_CAP_ROUND
	_outline.end_cap_mode = Line2D.LINE_CAP_ROUND
	_outline.antialiased = true
	_outline.points = _closed(polygon)
	add_child(_outline)


func _closed(p: PackedVector2Array) -> PackedVector2Array:
	var out := p.duplicate()
	if out.size() > 0:
		out.append(out[0])
	return out


func set_fill_color(c: Color) -> void:
	if _fill != null:
		_fill.color = c


func fill_color() -> Color:
	if _fill == null:
		return PaletteDef.BASE_COLOR
	return _fill.color


## 高亮只改描边，不改填充色
func set_highlight(on: bool) -> void:
	if _highlighted == on:
		return
	_highlighted = on
	if _outline == null:
		return
	_outline.default_color = HIGHLIGHT_COLOR if on else OUTLINE_COLOR
	_outline.width = HIGHLIGHT_WIDTH if on else OUTLINE_WIDTH


func is_highlighted() -> bool:
	return _highlighted


## 填色脉冲。重复调用不堆叠：先 kill 掉上一个 tween。
func play_fill_flash() -> void:
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	_flash_tween = Fx.fill_flash(self, FLASH_SEC)

	# 真实记录：把已经跑完/被杀掉的清出去，再把新的放进来
	var live: Array[Tween] = []
	for t in _flash_tweens:
		if t != null and is_instance_valid(t) and t.is_running():
			live.append(t)
	if _flash_tween != null and _flash_tween.is_valid():
		live.append(_flash_tween)
	_flash_tweens = live


## 当前**真实**活跃的填色 tween 数。
## 不能写死成 0/1 —— 那样"不堆叠"就无法被证伪（变异测试会存活）。
func active_tween_count() -> int:
	var n := 0
	for t in _flash_tweens:
		if t != null and is_instance_valid(t) and t.is_running():
			n += 1
	return n


func centroid() -> Vector2:
	return PatternSchema.polygon_centroid(polygon)


func area() -> float:
	return PatternSchema.polygon_area(polygon)


## 该区域的碰撞形状（测试用：临时清掉 layer 以证明点查询真的依赖物理形状）
func collision_shape() -> CollisionPolygon2D:
	return _shape
