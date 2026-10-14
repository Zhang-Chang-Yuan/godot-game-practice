class_name PatternSchema
extends RefCounted
# 图案区域数据的 schema 与校验（主 Agent 提供的基础层）。
# 生成端（Blender bpy 脚本）与消费端（Godot）都以此为准。

## 7 个图案，顺序即 UI 里的展示顺序
const PATTERNS := [
	"flower", "grass", "butterfly", "dog", "bee", "cat", "pig",
]

const DISPLAY_NAMES := {
	"flower": "小花",
	"grass": "小草",
	"butterfly": "蝴蝶",
	"dog": "小狗",
	"bee": "蜜蜂",
	"cat": "小猫",
	"pig": "小猪",
}

## 画布逻辑尺寸（像素）。图案坐标一律以此为准，原点左上、y 向下。
const CANVAS_SIZE := Vector2i(512, 512)

const SCHEMA_VERSION := 1

## 每个图案至少要有这么多可涂色区域
const MIN_REGIONS := 3

## 区域数据允许的键（多余键会被忽略，但生成端不应写入）
const REGION_KEYS := ["id", "label", "polygon", "z"]


static func pattern_path(name: String) -> String:
	return "res://assets/patterns/%s.json" % name


static func display_name(name: String) -> String:
	return String(DISPLAY_NAMES.get(name, name))


static func is_valid_name(name: String) -> bool:
	return PATTERNS.has(name)


## 校验一个图案字典是否符合 schema。
## 返回错误信息数组；**空数组 = 合法**。绝不抛错、绝不崩溃。
static func validate_pattern(d: Dictionary) -> Array[String]:
	var errs: Array[String] = []

	if d.is_empty():
		errs.append("pattern 为空字典")
		return errs

	if int(d.get("version", -1)) != SCHEMA_VERSION:
		errs.append("version 应为 %d，实际 %s" % [SCHEMA_VERSION, str(d.get("version", "<缺失>"))])

	var nm := String(d.get("name", ""))
	if not is_valid_name(nm):
		errs.append("name 非法：'%s'（应为 %s 之一）" % [nm, ", ".join(PATTERNS)])

	var w := int(d.get("width", 0))
	var h := int(d.get("height", 0))
	if w != CANVAS_SIZE.x or h != CANVAS_SIZE.y:
		errs.append("画布尺寸应为 %dx%d，实际 %dx%d" % [CANVAS_SIZE.x, CANVAS_SIZE.y, w, h])

	var regions_v: Variant = d.get("regions", null)
	if not (regions_v is Array):
		errs.append("regions 必须是数组")
		return errs
	var regions := regions_v as Array
	if regions.size() < MIN_REGIONS:
		errs.append("regions 至少 %d 个，实际 %d" % [MIN_REGIONS, regions.size()])

	var seen := {}
	for i in regions.size():
		var tag := "regions[%d]" % i
		var rv: Variant = regions[i]
		if not (rv is Dictionary):
			errs.append("%s 不是字典" % tag)
			continue
		var rd := rv as Dictionary

		var rid := String(rd.get("id", ""))
		if rid.is_empty():
			errs.append("%s.id 为空" % tag)
		elif seen.has(rid):
			errs.append("%s.id 重复：%s" % [tag, rid])
		else:
			seen[rid] = true

		if String(rd.get("label", "")).is_empty():
			errs.append("%s.label 为空" % tag)

		if rd.has("holes"):
			errs.append("%s 不允许有 holes —— CollisionPolygon2D 不支持挖洞" % tag)

		var poly_v: Variant = rd.get("polygon", null)
		if not (poly_v is Array):
			errs.append("%s.polygon 必须是数组" % tag)
			continue
		var poly := poly_v as Array
		if poly.size() < 3:
			errs.append("%s.polygon 至少 3 个点，实际 %d" % [tag, poly.size()])
			continue
		for j in poly.size():
			var ptv: Variant = poly[j]
			if not (ptv is Array) or (ptv as Array).size() != 2:
				errs.append("%s.polygon[%d] 应为 [x, y]" % [tag, j])
				continue
			var x := float((ptv as Array)[0])
			var y := float((ptv as Array)[1])
			if x < 0.0 or x > float(w) or y < 0.0 or y > float(h):
				errs.append("%s.polygon[%d] 越界 (%s, %s)" % [tag, j, str(x), str(y)])

	return errs


## [x, y] 数组 -> PackedVector2Array
static func to_packed(poly_v: Variant) -> PackedVector2Array:
	var out := PackedVector2Array()
	if not (poly_v is Array):
		return out
	for ptv in (poly_v as Array):
		if ptv is Array and (ptv as Array).size() >= 2:
			out.append(Vector2(float((ptv as Array)[0]), float((ptv as Array)[1])))
	return out


## PackedVector2Array -> [[x, y], ...]（写 JSON 用）
static func from_packed(poly: PackedVector2Array) -> Array:
	var out := []
	for p in poly:
		out.append([p.x, p.y])
	return out


## 多边形面积（绝对值，鞋带公式）
static func polygon_area(poly: PackedVector2Array) -> float:
	if poly.size() < 3:
		return 0.0
	var acc := 0.0
	for i in poly.size():
		var p0 := poly[i]
		var p1 := poly[(i + 1) % poly.size()]
		acc += p0.cross(p1)
	return absf(acc) * 0.5


## 多边形形心（面积加权；退化时退化为顶点平均）
static func polygon_centroid(poly: PackedVector2Array) -> Vector2:
	if poly.is_empty():
		return Vector2.ZERO
	if poly.size() < 3:
		var s0 := Vector2.ZERO
		for p in poly:
			s0 += p
		return s0 / float(poly.size())

	var acc := 0.0
	var c := Vector2.ZERO
	for i in poly.size():
		var p0 := poly[i]
		var p1 := poly[(i + 1) % poly.size()]
		var cr := p0.cross(p1)
		acc += cr
		c += (p0 + p1) * cr

	if absf(acc) < 0.0001:
		var s := Vector2.ZERO
		for p in poly:
			s += p
		return s / float(poly.size())

	return c / (3.0 * acc)


## 点是否在多边形内（射线法，even-odd）。供测试与生成端自检使用；
## **游戏内的点击检测必须走 PhysicsPointQuery，不许用这个函数**（那正是 demo 重点 1）。
static func point_in_polygon(p: Vector2, poly: PackedVector2Array) -> bool:
	var n := poly.size()
	if n < 3:
		return false
	var inside := false
	var j := n - 1
	for i in n:
		var pi := poly[i]
		var pj := poly[j]
		if ((pi.y > p.y) != (pj.y > p.y)):
			var x_cross := (pj.x - pi.x) * (p.y - pi.y) / (pj.y - pi.y) + pi.x
			if p.x < x_cross:
				inside = not inside
		j = i
	return inside
