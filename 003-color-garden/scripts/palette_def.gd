class_name PaletteDef
extends RefCounted
# 色板定义 + 加色混合数学（demo 重点 3 的核心，主 Agent 提供的基础层）。
# 全工程唯一的"颜色字典"，任何模块都不许自己再写一套加色公式。

## 加色混合的底色。
##
## 为什么是暗底：加色（additive）是**光**的混合方式——从白底出发，
## 任何颜色加上去都会立刻饱和成白色，什么也看不出来。
## 所以本作用近黑底 + 发光式涂色：红 + 绿 = 黄，红 + 蓝 = 品红，绿 + 蓝 = 青，三色加满 = 白。
## （颜料/印刷走的是减色 mixed，那才需要白底。这是本 demo 想讲清楚的一件事。）
const BASE_COLOR := Color(0.10, 0.10, 0.12)

## 三色加满的结果，用于 UI 提示与测试断言
const SATURATED_COLOR := Color(1.0, 1.0, 1.0)

## 16 色调色板。前 7 个专门服务于"加色混合"演示：
## 3 个原色 + 3 个两两混合结果 + 白（三色加满），它们的 RGB 值本身就是加色关系。
const PALETTE := [
	{ "name": "红",   "color": Color(1.00, 0.10, 0.10), "demo": true },
	{ "name": "绿",   "color": Color(0.10, 1.00, 0.20), "demo": true },
	{ "name": "蓝",   "color": Color(0.15, 0.30, 1.00), "demo": true },
	{ "name": "黄",   "color": Color(1.00, 0.95, 0.15), "demo": true },
	{ "name": "青",   "color": Color(0.10, 1.00, 0.90), "demo": true },
	{ "name": "品红", "color": Color(1.00, 0.15, 0.90), "demo": true },
	{ "name": "白",   "color": Color(1.00, 1.00, 1.00), "demo": true },
	{ "name": "橙",   "color": Color(1.00, 0.50, 0.10) },
	{ "name": "黄绿", "color": Color(0.55, 1.00, 0.20) },
	{ "name": "天蓝", "color": Color(0.20, 0.70, 1.00) },
	{ "name": "紫",   "color": Color(0.60, 0.30, 1.00) },
	{ "name": "粉",   "color": Color(1.00, 0.50, 0.70) },
	{ "name": "暖白", "color": Color(1.00, 0.90, 0.72) },
	{ "name": "暗红", "color": Color(0.55, 0.05, 0.05) },
	{ "name": "暗绿", "color": Color(0.05, 0.45, 0.15) },
	{ "name": "暗蓝", "color": Color(0.05, 0.12, 0.55) },
]

## 默认笔刷强度（每次涂色加到区域上的比例）
const DEFAULT_STRENGTH := 0.45


## 加色混合：逐通道相加并夹到 [0, 1]。alpha 保持 base 的 alpha 不变。
## 这是本工程唯一的加色公式，所有模块都必须调它。
static func add_color(base: Color, brush: Color, strength: float) -> Color:
	var s := clampf(strength, 0.0, 1.0)
	return Color(
		clampf(base.r + brush.r * s, 0.0, 1.0),
		clampf(base.g + brush.g * s, 0.0, 1.0),
		clampf(base.b + brush.b * s, 0.0, 1.0),
		base.a
	)


## 多个颜色依次相加。
## 对应「PhysicsPointQuery 一次命中多个重叠区域」的情形：命中的每个区域都被加一遍。
static func add_many(base: Color, brushes: Array, strength: float) -> Color:
	var out := base
	for b in brushes:
		if b is Color:
			out = add_color(out, b as Color, strength)
	return out


## 调色板里第 i 个颜色（越界返回 BASE_COLOR）
static func palette_color(i: int) -> Color:
	if i < 0 or i >= PALETTE.size():
		return BASE_COLOR
	return PALETTE[i]["color"] as Color


## 调色板里第 i 个名字
static func palette_name(i: int) -> String:
	if i < 0 or i >= PALETTE.size():
		return ""
	return String(PALETTE[i]["name"])


static func palette_size() -> int:
	return PALETTE.size()


## Color -> [r, g, b, a]（JSON 存盘用）
static func color_to_array(c: Color) -> Array:
	return [c.r, c.g, c.b, c.a]


## [r, g, b, a] -> Color；脏数据返回 BASE_COLOR（不崩溃）
static func array_to_color(a: Variant) -> Color:
	if not (a is Array):
		return BASE_COLOR
	var arr := a as Array
	if arr.size() < 3:
		return BASE_COLOR
	var alpha := 1.0
	if arr.size() > 3:
		alpha = clampf(float(arr[3]), 0.0, 1.0)
	return Color(
		clampf(float(arr[0]), 0.0, 1.0),
		clampf(float(arr[1]), 0.0, 1.0),
		clampf(float(arr[2]), 0.0, 1.0),
		alpha
	)


## 该颜色是否还是未涂色的底色（用于统计"已涂几个区域"）。
## 容差 0.01：底色存进 RGBA8 图片后会被量化（每通道 ±1/255 ≈ 0.004），
## 容差太紧（如 0.002）会把纯底色误判成"已涂"。
static func is_base(c: Color) -> bool:
	return absf(c.r - BASE_COLOR.r) < 0.01 \
		and absf(c.g - BASE_COLOR.g) < 0.01 \
		and absf(c.b - BASE_COLOR.b) < 0.01


## 两个颜色的感知差异（0~1），用于 UI 判断"这次涂色有没有明显变化"
static func color_distance(a: Color, b: Color) -> float:
	return Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length() / sqrt(3.0)
