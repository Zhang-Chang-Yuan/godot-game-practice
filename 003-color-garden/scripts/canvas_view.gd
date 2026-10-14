class_name CanvasView
extends Node2D
# 区域容器 + 点击检测。
# demo 重点 1：点击检测必须走 PhysicsPointQuery（intersect_point），不是自己遍历多边形。

## hit_ids = 本次点查询命中的**全部** region_id；painted_id = 其中最上层的一个（"" = 没命中）
signal region_hit(hit_ids: Array, painted_id: String)
signal canvas_rebuilt(region_count: int)

const MAX_HITS := 32
const HIT_MASK := 1 << (ColorRegion.LAYER - 1)

var _regions: Dictionary = {}     # region_id -> ColorRegion
var _order: Array[String] = []    # 添加顺序（z 升序）


func build_from_pattern(d: Dictionary) -> void:
	clear_regions()

	var rv: Variant = d.get("regions", [])
	if not (rv is Array):
		canvas_rebuilt.emit(0)
		return

	# 按 z 升序添加子节点：后加的在上
	var list: Array = (rv as Array).duplicate()
	list.sort_custom(func(a: Variant, b: Variant) -> bool:
		var za := int((a as Dictionary).get("z", 0)) if a is Dictionary else 0
		var zb := int((b as Dictionary).get("z", 0)) if b is Dictionary else 0
		return za < zb
	)

	for item in list:
		if not (item is Dictionary):
			continue
		var reg := ColorRegion.new()
		reg.setup(item as Dictionary)
		add_child(reg)
		_regions[reg.region_id] = reg
		_order.append(reg.region_id)
		reg.set_fill_color(PaintState.region_color(reg.region_id))

	canvas_rebuilt.emit(_regions.size())


func clear_regions() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_regions.clear()
	_order.clear()


func region_count() -> int:
	return _regions.size()


func region_node(region_id: String) -> ColorRegion:
	return _regions.get(region_id, null) as ColorRegion


func region_ids() -> Array[String]:
	var out: Array[String] = []
	for rid in _order:
		out.append(rid)
	return out


## demo 重点 1 的核心：用 PhysicsPointQueryParameters2D 做点查询。
## 一次会返回**所有**包含该点的区域（可能多个），这正是我们要演示的能力。
func pick_region_ids(world_pos: Vector2) -> Array[String]:
	var out: Array[String] = []
	var space := get_world_2d().direct_space_state
	if space == null:
		return out

	var params := PhysicsPointQueryParameters2D.new()
	params.position = world_pos
	params.collide_with_areas = true
	params.collide_with_bodies = false
	params.collision_mask = HIT_MASK

	var hits := space.intersect_point(params, MAX_HITS)
	for h in hits:
		if not (h is Dictionary):
			continue
		var col: Variant = (h as Dictionary).get("collider", null)
		if col is ColorRegion:
			var rid := (col as ColorRegion).region_id
			if not out.has(rid):
				out.append(rid)
	return out


## 点查询 + 上色。命中多个区域时**每个都加一遍**颜色（加色混合，demo 重点 3）。
## 返回被涂的 region_id（命中多个时返回 z 最大的那个；"" = 没命中）。
func paint_at(world_pos: Vector2) -> String:
	var hits := pick_region_ids(world_pos)
	if hits.is_empty():
		region_hit.emit([], "")
		return ""

	PaintState.apply_to_regions(hits)

	var top := ""
	var top_z := -2147483648
	for rid in hits:
		var reg := region_node(rid)
		if reg == null:
			continue
		reg.set_fill_color(PaintState.region_color(rid))
		reg.play_fill_flash()
		if reg.z_order > top_z:
			top_z = reg.z_order
			top = rid

	region_hit.emit(hits, top)
	return top


## 把全局坐标换算成本 Node2D 的局部坐标
func to_local_pos(global_pos: Vector2) -> Vector2:
	return get_global_transform().affine_inverse() * global_pos


## 高亮若干区域（其余熄灭）
func highlight_only(ids: Array) -> void:
	for rid in _regions:
		var reg := _regions[rid] as ColorRegion
		if reg != null:
			reg.set_highlight(ids.has(rid))
