extends Node
# 003-color-garden headless 测试套件
#
# 运行：
#   & "C:\Hub\program\godot-4\Godot_v4.7.2-stable_win64_console.exe" --headless `
#       --path "C:\Hub\workspace\godot-game-practice\003-color-garden" `
#       --log-file "$env:TEMP\cg.log" res://tests/test_scene.tscn
#
# 断言的是**行为**，不是"节点存在"。
# 边界值一律用**字面量**（不拿被测量的常量比自己，避免同义反复断言）。

const LOG_PATH := "user://test_runner.log"
const TIMEOUT_SEC := 30

const TEST_SAVE := "user://test_art.json"
const TEST_BAD_JSON := "user://test_bad.json"
const TEST_BAD_ARRAY := "user://test_bad_array.json"
const TEST_BAD_PATTERN := "user://test_bad_pattern.json"
const TEST_PNG := "user://test_export.png"

var _pass := 0
var _fail := 0
var _total := 0
var _fail_lines: Array[String] = []
var _log: FileAccess = null
var _finished := false
var _canvas: CanvasView = null


func _say(line: String) -> void:
	print(line)
	if _log != null:
		_log.store_line(line)
		_log.flush()


## 看门狗：若某个测试函数漏写 await，协程会永久停在 await 处，
## 汇总行与 quit() 都不会执行 —— 进程挂死或被误判成"全绿"。
## 契约 §13.1 要求用 _finished 守卫，但"置真后立刻检查"是空的，所以这里做真正的超时兜底。
func _start_watchdog() -> void:
	var t0 := Time.get_ticks_msec()
	while not _finished:
		await get_tree().process_frame
		if Time.get_ticks_msec() - t0 > TIMEOUT_SEC * 1000:
			print("FAIL 测试超过 %d 秒仍未跑到汇总行 —— 很可能有测试函数漏写 await" % TIMEOUT_SEC)
			if _log != null:
				_log.store_line("FAIL TIMEOUT after %d s" % TIMEOUT_SEC)
				_log.close()
				_log = null
			get_tree().quit(1)
			return


func _ready() -> void:
	_start_watchdog()
	_log = FileAccess.open(LOG_PATH, FileAccess.WRITE)
	await get_tree().process_frame

	_say("=== 003-color-garden headless test suite ===")
	_say("Godot: %s" % Engine.get_version_info().get("string", "?"))

	await _test_schema_data()
	await _test_palette_math()
	await _test_paint_state()
	await _test_point_query()
	await _test_additive()
	await _test_persistence()
	await _test_export()
	await _test_tween()
	await _test_ui()
	await _test_main_scene()

	_cleanup()
	_summary()


func _summary() -> void:
	_say("")
	_say("TESTS: %d/%d passed" % [_pass, _total])
	if _fail > 0:
		_say("FAILURES: %d" % _fail)
		for l in _fail_lines:
			_say("  FAIL %s" % l)
	else:
		_say("ALL PASS")
	_finished = true
	if _log != null:
		_log.close()
		_log = null
	get_tree().quit(0 if _fail == 0 else 1)


func _cleanup() -> void:
	PaintState.reset_all()
	for p in [TEST_SAVE, TEST_BAD_JSON, TEST_BAD_ARRAY, TEST_BAD_PATTERN, TEST_PNG]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


# ============================================================ 断言原语

func _check(cond: bool, label: String) -> void:
	_total += 1
	if cond:
		_pass += 1
		_say("PASS %s" % label)
	else:
		_fail += 1
		_fail_lines.append(label)
		_say("FAIL %s" % label)


func _eq(actual: Variant, expected: Variant, label: String) -> void:
	_check(actual == expected, "%s | expected=%s actual=%s" % [label, str(expected), str(actual)])


func _near(actual: float, expected: float, tol: float, label: String) -> void:
	_check(absf(actual - expected) <= tol,
		"%s | expected=%.4f(±%.4f) actual=%.4f" % [label, expected, tol, actual])


## 自旋等真实时间。不要用 create_timer 等短间隔：headless 首帧 delta 只走 0~2ms。
func _spin(msec: int) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < msec:
		await get_tree().process_frame


## 建一个画布。**必须先释放上一个画布**：所有画布的区域都注册在同一个物理空间里、
## 坐标还完全重叠，留着旧画布会让点查询跨画布命中（这正是 PhysicsPointQuery 的真实特性，
## 但测试之间必须隔离，否则 painted_count 会莫名多出几个）。
func _make_canvas(pattern_name: String) -> CanvasView:
	if _canvas != null and is_instance_valid(_canvas):
		remove_child(_canvas)
		_canvas.free()
		_canvas = null
		await get_tree().physics_frame

	PaintState.load_pattern(pattern_name)
	_canvas = CanvasView.new()
	add_child(_canvas)
	_canvas.build_from_pattern(PaintState.pattern)
	# 让形状注册进物理空间
	await get_tree().physics_frame
	await get_tree().physics_frame
	return _canvas


# ============================================================ A. schema 与数据

func _test_schema_data() -> void:
	_say("")
	_say("--- A. schema 与图案数据 ---")

	var names := PatternData.list_patterns()
	_eq(names.size(), 7, "A.图案数 == 7（字面量）")

	var counts := {
		"flower": 9, "grass": 7, "butterfly": 7, "dog": 13,
		"bee": 10, "cat": 13, "pig": 14,
	}

	for n in names:
		var d := PatternData.load_pattern(n)
		_check(not d.is_empty(), "A.%s 能加载" % n)
		if d.is_empty():
			continue
		var errs := PatternSchema.validate_pattern(d)
		_eq(errs.size(), 0, "A.%s validate_pattern 返回空错误数组（%s）" % [n, ", ".join(errs)])
		_eq(int(d.get("width", 0)), 512, "A.%s width == 512" % n)
		_eq(int(d.get("height", 0)), 512, "A.%s height == 512" % n)
		_eq(int(d.get("version", 0)), 1, "A.%s version == 1" % n)

		var regions: Array = d.get("regions", [])
		_eq(regions.size(), int(counts[n]), "A.%s 区域数 == %d" % [n, int(counts[n])])
		_check(regions.size() >= 6 and regions.size() <= 16, "A.%s 区域数在 6~16" % n)

		var ids := {}
		var dup := false
		var out_of_bounds := 0
		var nonpositive_area := 0
		var centroid_outside := 0
		var holes := 0
		var too_few_pts := 0
		for r in regions:
			var rd := r as Dictionary
			var rid := String(rd.get("id", ""))
			if ids.has(rid):
				dup = true
			ids[rid] = true
			if rd.has("holes"):
				holes += 1
			var poly := PatternSchema.to_packed(rd.get("polygon", []))
			if poly.size() < 3:
				too_few_pts += 1
				continue
			for p in poly:
				if p.x < 0.0 or p.x > 512.0 or p.y < 0.0 or p.y > 512.0:
					out_of_bounds += 1
			if PatternSchema.polygon_area(poly) <= 0.0:
				nonpositive_area += 1
			if not PatternSchema.point_in_polygon(PatternSchema.polygon_centroid(poly), poly):
				centroid_outside += 1

		_check(not dup, "A.%s 所有 id 唯一" % n)
		_eq(out_of_bounds, 0, "A.%s 无越界坐标" % n)
		_eq(nonpositive_area, 0, "A.%s 所有区域面积 > 0" % n)
		_eq(centroid_outside, 0, "A.%s 所有形心落在自身多边形内" % n)
		_eq(holes, 0, "A.%s 无 holes（CollisionPolygon2D 不支持挖洞）" % n)
		_eq(too_few_pts, 0, "A.%s 每个区域 >= 3 顶点" % n)

	# 非法输入
	_eq(PatternSchema.validate_pattern({}).size() > 0, true, "A.空字典校验失败")
	_check(not PatternData.exists("nope"), "A.不存在的图案 exists() 为假")
	_eq(PatternData.load_pattern("nope").size(), 0, "A.非法名返回空字典")
	_eq(PatternSchema.display_name("pig"), "小猪", "A.display_name(pig) == 小猪")
	_eq(PatternSchema.pattern_path("bee"), "res://assets/patterns/bee.json", "A.pattern_path(bee)")


# ============================================================ B. 加色数学

func _test_palette_math() -> void:
	_say("")
	_say("--- B. 加色混合数学 ---")

	_eq(PaletteDef.palette_size(), 16, "B.色板 16 色（字面量）")

	var base := Color(0.0, 0.0, 0.0)
	var red := Color(1.0, 0.0, 0.0)
	var green := Color(0.0, 1.0, 0.0)
	var blue := Color(0.0, 0.0, 1.0)

	# 逐通道相加
	var rg := PaletteDef.add_color(PaletteDef.add_color(base, red, 1.0), green, 1.0)
	_near(rg.r, 1.0, 0.001, "B.红+绿 -> r")
	_near(rg.g, 1.0, 0.001, "B.红+绿 -> g")
	_near(rg.b, 0.0, 0.001, "B.红+绿 -> b（=黄）")

	var rb := PaletteDef.add_color(PaletteDef.add_color(base, red, 1.0), blue, 1.0)
	_near(rb.r, 1.0, 0.001, "B.红+蓝 -> r")
	_near(rb.b, 1.0, 0.001, "B.红+蓝 -> b（=品红）")

	var gb := PaletteDef.add_color(PaletteDef.add_color(base, green, 1.0), blue, 1.0)
	_near(gb.g, 1.0, 0.001, "B.绿+蓝 -> g")
	_near(gb.b, 1.0, 0.001, "B.绿+蓝 -> b（=青）")

	var rgb := PaletteDef.add_many(base, [red, green, blue], 1.0)
	_near(rgb.r, 1.0, 0.001, "B.三色加满 -> r")
	_near(rgb.g, 1.0, 0.001, "B.三色加满 -> g")
	_near(rgb.b, 1.0, 0.001, "B.三色加满 -> b（=白）")

	# 夹到 1.0
	var over := PaletteDef.add_color(Color(0.9, 0.9, 0.9), Color(1.0, 1.0, 1.0), 1.0)
	_near(over.r, 1.0, 0.0001, "B.超出后夹到 1.0")

	# add_many 等价于依次 add_color
	var seq := PaletteDef.add_color(PaletteDef.add_color(base, red, 0.5), green, 0.5)
	var many := PaletteDef.add_many(base, [red, green], 0.5)
	_near(many.r, seq.r, 0.0001, "B.add_many 等价于依次 add_color (r)")
	_near(many.g, seq.g, 0.0001, "B.add_many 等价于依次 add_color (g)")

	# 强度夹取
	_near(PaletteDef.add_color(base, red, 5.0).r, 1.0, 0.0001, "B.强度 >1 被夹到 1")
	_near(PaletteDef.add_color(base, red, -3.0).r, 0.0, 0.0001, "B.强度 <0 被夹到 0")

	_check(PaletteDef.is_base(PaletteDef.BASE_COLOR), "B.is_base(BASE_COLOR) 为真")
	_check(not PaletteDef.is_base(Color(1.0, 0.0, 0.0)), "B.is_base(纯红) 为假")

	# 脏数据
	var c := PaletteDef.array_to_color("not an array")
	_check(c.is_equal_approx(PaletteDef.BASE_COLOR), "B.array_to_color(脏数据) 返回底色不崩溃")
	_check(PaletteDef.array_to_color([0.1, 0.2]).is_equal_approx(PaletteDef.BASE_COLOR), "B.array_to_color(只有 2 个元素) 返回底色")

	# 往返
	var src := Color(0.25, 0.5, 0.75, 1.0)
	var back := PaletteDef.array_to_color(PaletteDef.color_to_array(src))
	_check(back.is_equal_approx(src), "B.color_to_array/array_to_color 往返一致")

	# 调色板前 7 个是 demo 色
	var demo_count := 0
	for i in PaletteDef.palette_size():
		if bool(PaletteDef.PALETTE[i].get("demo", false)):
			demo_count += 1
	_eq(demo_count, 7, "B.标记为 demo 的色板项 == 7（字面量）")


# ============================================================ C. PaintState

func _test_paint_state() -> void:
	_say("")
	_say("--- C. PaintState 状态与上色 ---")

	_eq(PaintState.load_pattern("flower"), OK, "C.load_pattern(flower) 返回 OK")
	_eq(PaintState.pattern_name, "flower", "C.pattern_name == flower")
	_eq(PaintState.region_count(), 9, "C.region_count == 9")
	_eq(PaintState.painted_count(), 0, "C.初始 painted_count == 0")

	# 强度夹取
	PaintState.set_brush_strength(5.0)
	_near(PaintState.brush_strength, 1.0, 0.0001, "C.强度 5.0 夹到 1.0")
	PaintState.set_brush_strength(0.0)
	_near(PaintState.brush_strength, 0.05, 0.0001, "C.强度 0.0 夹到 0.05")
	PaintState.set_brush_strength(0.5)
	_near(PaintState.brush_strength, 0.5, 0.0001, "C.强度 0.5 保持")

	# 单区域加色
	PaintState.reset_all()
	PaintState.set_brush(Color(0.8, 0.2, 0.1))
	var base0 := PaintState.region_color("core")
	_check(base0.is_equal_approx(PaletteDef.BASE_COLOR), "C.未涂区域颜色 == 底色")
	var c1 := PaintState.apply_to_region("core")
	var exp1 := PaletteDef.add_color(base0, Color(0.8, 0.2, 0.1), 0.5)
	_near(c1.r, exp1.r, 0.0001, "C.apply_to_region 结果 == add_color (r)")
	_near(c1.g, exp1.g, 0.0001, "C.apply_to_region 结果 == add_color (g)")
	_eq(PaintState.painted_count(), 1, "C.painted_count == 1")

	# 连涂两次是相加不是覆盖
	var c2 := PaintState.apply_to_region("core")
	_check(c2.r > c1.r and c2.g > c1.g, "C.连涂两次是相加（不是覆盖）")
	var exp2 := PaletteDef.add_color(c1, Color(0.8, 0.2, 0.1), 0.5)
	_near(c2.r, exp2.r, 0.0001, "C.第二次结果 == 基于第一次再相加 (r)")

	# reset_region / reset_all
	PaintState.reset_region("core")
	_check(PaintState.region_color("core").is_equal_approx(PaletteDef.BASE_COLOR), "C.reset_region 复原")
	_eq(PaintState.painted_count(), 0, "C.reset_region 后 painted_count == 0")

	PaintState.apply_to_region("core")
	PaintState.apply_to_region("stem")
	_eq(PaintState.painted_count(), 2, "C.涂两个区域 -> painted_count == 2")
	PaintState.reset_all()
	_eq(PaintState.painted_count(), 0, "C.reset_all 清空")

	# apply_to_regions：每个区域各加一遍
	PaintState.reset_all()
	PaintState.set_brush(Color(1.0, 0.5, 0.0))
	PaintState.apply_to_regions(["core", "stem"])
	_check(not PaintState.region_color("core").is_equal_approx(PaletteDef.BASE_COLOR), "C.apply_to_regions 涂了 core")
	_check(not PaintState.region_color("stem").is_equal_approx(PaletteDef.BASE_COLOR), "C.apply_to_regions 涂了 stem")
	_eq(PaintState.painted_count(), 2, "C.apply_to_regions 命中 2 个 -> painted_count == 2")

	# mixed_preview
	var mp := PaintState.mixed_preview([Color(1.0, 0.0, 0.0), Color(0.0, 1.0, 0.0)])
	_near(mp.r, 1.0, 0.001, "C.mixed_preview 红+绿 -> r")
	_near(mp.g, 1.0, 0.001, "C.mixed_preview 红+绿 -> g")


# ============================================================ D. PhysicsPointQuery

func _test_point_query() -> void:
	_say("")
	_say("--- D. PhysicsPointQuery 点击检测（demo 重点 1）---")

	var cv := await _make_canvas("flower")
	_eq(cv.region_count(), 9, "D.画布区域数 == 9")
	_eq(cv.region_ids().size(), 9, "D.region_ids() 长度 == 9")

	# 形心命中
	var reg := cv.region_node("petal_0")
	_check(reg != null, "D.region_node(petal_0) 非 null")
	if reg != null:
		var hits := cv.pick_region_ids(reg.centroid())
		_check(hits.has("petal_0"), "D.形心点查询命中 petal_0（hits=%s）" % str(hits))

	# 空白处不命中
	var far := cv.pick_region_ids(Vector2(4.0, 4.0))
	_eq(far.size(), 0, "D.(4,4) 点查询命中 0 个")

	# 每个区域形心都能命中自己
	var miss := 0
	for rid in cv.region_ids():
		var r := cv.region_node(rid)
		if r == null:
			continue
		if not cv.pick_region_ids(r.centroid()).has(rid):
			miss += 1
	_eq(miss, 0, "D.全部 9 个区域的形心都能命中自己")

	# ★ 证明真的走物理形状：清掉 collision_layer 后应命中不到
	if reg != null:
		var before := cv.pick_region_ids(reg.centroid()).has("petal_0")
		reg.collision_layer = 0
		await get_tree().physics_frame
		await get_tree().physics_frame
		var after := cv.pick_region_ids(reg.centroid()).has("petal_0")
		_check(before and not after,
			"D.清掉 collision_layer 后命中不到（证明检测依赖物理形状，不是几何兜底）")
		reg.collision_layer = 1 << (ColorRegion.LAYER - 1)
		await get_tree().physics_frame
		await get_tree().physics_frame
		_check(cv.pick_region_ids(reg.centroid()).has("petal_0"), "D.恢复 layer 后又能命中")

	# 多命中：蜜蜂的条纹与身体有意重叠
	var bee := await _make_canvas("bee")
	var stripe := bee.region_node("stripe_1")
	_check(stripe != null, "D.bee 有 stripe_1")
	if stripe != null:
		var hits2 := bee.pick_region_ids(stripe.centroid())
		_check(hits2.size() >= 2,
			"D.蜜蜂条纹形心一次命中 >=2 个区域（多命中演示，hits=%s）" % str(hits2))
		_check(hits2.has("body") and hits2.has("stripe_1"),
			"D.多命中同时包含 body 与 stripe_1")

	# paint_at 返回值
	PaintState.reset_all()
	var painted := bee.paint_at(stripe.centroid() if stripe != null else Vector2(300.0, 252.0))
	_check(painted != "", "D.paint_at 返回被涂的 region_id（%s）" % painted)
	_eq(PaintState.painted_count(), 2, "D.多命中一次点击涂了 2 个区域")

	# 空点
	_eq(bee.paint_at(Vector2(4.0, 4.0)), "", "D.paint_at 空白处返回空字符串")


# ============================================================ E. 加色上色

func _test_additive() -> void:
	_say("")
	_say("--- E. 画布加色混合（demo 重点 3）---")

	var cv := await _make_canvas("flower")
	PaintState.reset_all()

	var cen := cv.region_node("core").centroid()

	PaintState.set_brush(Color(1.0, 0.1, 0.1))
	PaintState.set_brush_strength(0.5)
	cv.paint_at(cen)
	var c_red := PaintState.region_color("core")
	_check(c_red.r > 0.4 and c_red.g < 0.2, "E.涂红后 r 高 g 低（r=%.3f g=%.3f）" % [c_red.r, c_red.g])

	PaintState.set_brush(Color(0.1, 1.0, 0.2))
	cv.paint_at(cen)
	var c_rg := PaintState.region_color("core")
	_check(c_rg.g > c_red.g, "E.再涂绿 -> g 上升（相加）")
	_check(c_rg.r >= c_red.r - 0.001, "E.再涂绿 -> r 不下降（不是覆盖）")
	_check(c_rg.g > 0.4 and c_rg.r > 0.4, "E.红绿叠加后两通道都高（r=%.3f g=%.3f）" % [c_rg.r, c_rg.g])

	# 涂到饱和不超 1.0
	for i in 10:
		cv.paint_at(cen)
	var sat := PaintState.region_color("core")
	_check(sat.r <= 1.0 and sat.g <= 1.0 and sat.b <= 1.0, "E.饱和后仍 <= 1.0")

	# 白色可把区域推到接近白
	PaintState.reset_all()
	PaintState.set_brush(Color(1.0, 1.0, 1.0))
	PaintState.set_brush_strength(1.0)
	for i in 4:
		cv.paint_at(cen)
	var white := PaintState.region_color("core")
	_near(white.r, 1.0, 0.02, "E.连续白色叠加 -> r 接近 1")
	_near(white.g, 1.0, 0.02, "E.连续白色叠加 -> g 接近 1")
	_near(white.b, 1.0, 0.02, "E.连续白色叠加 -> b 接近 1")


# ============================================================ F. 存盘

func _test_persistence() -> void:
	_say("")
	_say("--- F. 保存 / 载入作品 ---")

	var cv := await _make_canvas("dog")
	PaintState.reset_all()
	PaintState.set_brush(Color(0.3, 0.7, 0.9))
	PaintState.set_brush_strength(0.6)

	var ids := cv.region_ids()
	for i in mini(3, ids.size()):
		cv.paint_at(cv.region_node(ids[i]).centroid())
	_eq(PaintState.painted_count(), 3, "F.涂了 3 个区域")

	var snapshot := {}
	for rid in ids:
		snapshot[rid] = PaintState.region_color(rid)

	_eq(PaintState.save_artwork(TEST_SAVE), OK, "F.save_artwork 返回 OK")
	_check(FileAccess.file_exists(TEST_SAVE), "F.存档文件存在")

	PaintState.reset_all()
	_eq(PaintState.painted_count(), 0, "F.reset 后 painted_count == 0")

	_eq(PaintState.load_artwork(TEST_SAVE), OK, "F.load_artwork 返回 OK")
	_eq(PaintState.painted_count(), 3, "F.载入后 painted_count == 3")
	_eq(PaintState.pattern_name, "dog", "F.载入后 pattern_name == dog")

	var mismatch := 0
	for rid in ids:
		if not PaintState.region_color(rid).is_equal_approx(snapshot[rid]):
			mismatch += 1
	_eq(mismatch, 0, "F.全部 13 个区域颜色逐通道还原一致")

	# 脏数据
	_eq(PaintState.load_artwork("user://definitely_missing.json"), ERR_FILE_NOT_FOUND,
		"F.文件不存在 -> ERR_FILE_NOT_FOUND")

	var f := FileAccess.open(TEST_BAD_JSON, FileAccess.WRITE)
	f.store_string("{not json")
	f.close()
	_eq(PaintState.load_artwork(TEST_BAD_JSON), ERR_PARSE_ERROR, "F.坏 JSON -> ERR_PARSE_ERROR")

	var f2 := FileAccess.open(TEST_BAD_ARRAY, FileAccess.WRITE)
	f2.store_string("[]")
	f2.close()
	_eq(PaintState.load_artwork(TEST_BAD_ARRAY), ERR_PARSE_ERROR, "F.顶层数组 -> ERR_PARSE_ERROR")

	var f3 := FileAccess.open(TEST_BAD_PATTERN, FileAccess.WRITE)
	f3.store_string('{"version":1,"pattern":"nope","colors":{}}')
	f3.close()
	_eq(PaintState.load_artwork(TEST_BAD_PATTERN), ERR_INVALID_DATA, "F.非法 pattern -> ERR_INVALID_DATA")

	# 未知 id 与非法颜色被跳过，其余照常载入
	var mixed := {
		"version": 1,
		"pattern": "flower",
		"colors": {
			"core": [0.5, 0.25, 0.75, 1.0],
			"totally_unknown_id": [1.0, 0.0, 0.0, 1.0],
			"stem": "not an array",
		},
	}
	_eq(PaintState.from_dict(mixed), OK, "F.含脏项的字典仍返回 OK")
	_eq(PaintState.pattern_name, "flower", "F.脏项载入后 pattern_name == flower")
	_near(PaintState.region_color("core").r, 0.5, 0.001, "F.合法项被载入 (r)")
	_near(PaintState.region_color("core").b, 0.75, 0.001, "F.合法项被载入 (b)")
	_eq(PaintState.painted_count(), 1, "F.未知 id 与非法颜色被跳过 -> 只载入 1 个")


# ============================================================ G. 导出 PNG

func _test_export() -> void:
	_say("")
	_say("--- G. 导出 PNG ---")

	var cv := await _make_canvas("butterfly")
	PaintState.reset_all()

	# 空作品也应能导出（全是底色）
	_eq(PaintState.export_png(TEST_PNG), OK, "G.空作品 export_png 返回 OK")
	var img0 := Image.load_from_file(ProjectSettings.globalize_path(TEST_PNG))
	_check(img0 != null, "G.空作品 PNG 能读回")
	if img0 != null:
		_eq(img0.get_width(), 512, "G.PNG 宽 512")
		_eq(img0.get_height(), 512, "G.PNG 高 512")
		_eq(ArtworkExport.painted_pixel_count(img0), 0, "G.空作品无着色像素")

	# 涂色后导出
	PaintState.set_brush(Color(1.0, 0.6, 0.1))
	PaintState.set_brush_strength(1.0)
	cv.paint_at(cv.region_node("body").centroid())
	cv.paint_at(cv.region_node("wing_ul").centroid())
	_eq(PaintState.export_png(TEST_PNG), OK, "G.涂色后 export_png 返回 OK")

	var img := Image.load_from_file(ProjectSettings.globalize_path(TEST_PNG))
	_check(img != null, "G.PNG 能读回")
	if img != null:
		_eq(img.get_width(), 512, "G.涂色后 PNG 宽 512")
		_eq(img.get_height(), 512, "G.涂色后 PNG 高 512")
		_check(ArtworkExport.painted_pixel_count(img) > 0, "G.涂色后 PNG 有非背景像素")

		# 身体形心处的像素应等于该区域累积色
		var body := cv.region_node("body")
		var p := body.centroid()
		var px := img.get_pixel(int(p.x), int(p.y))
		var want := PaintState.region_color("body")
		_near(px.r, want.r, 0.02, "G.导出像素颜色 == 区域累积色 (r)")
		_near(px.g, want.g, 0.02, "G.导出像素颜色 == 区域累积色 (g)")
		_near(px.b, want.b, 0.02, "G.导出像素颜色 == 区域累积色 (b)")

		# 空白角落应为底色。注意：PNG 是 8bit/通道，底色会被量化（±1/255），
		# 所以必须用容差比较，不能用 is_equal_approx（那个精度太严）。
		var corner := img.get_pixel(2, 2)
		_near(corner.r, PaletteDef.BASE_COLOR.r, 0.01, "G.左上角像素 r == 底色（8bit 量化容差）")
		_near(corner.g, PaletteDef.BASE_COLOR.g, 0.01, "G.左上角像素 g == 底色")
		_near(corner.b, PaletteDef.BASE_COLOR.b, 0.01, "G.左上角像素 b == 底色")

	# rasterize 纯函数
	var img2 := ArtworkExport.rasterize(PaintState.pattern, PaintState.colors, PatternSchema.CANVAS_SIZE)
	_check(img2 != null, "G.rasterize 返回 Image")
	if img2 != null:
		_eq(img2.get_width(), 512, "G.rasterize 宽 512")
		_eq(img2.get_height(), 512, "G.rasterize 高 512")


# ============================================================ H. Tween

func _test_tween() -> void:
	_say("")
	_say("--- H. Tween 动画（demo 重点 2）---")

	var cv := await _make_canvas("cat")
	var reg := cv.region_node("head")
	_check(reg != null, "H.cat 有 head 区域")

	if reg != null:
		# 单次
		reg.play_fill_flash()
		_eq(reg.active_tween_count(), 1, "H.单次 play_fill_flash -> 1 个活跃 tween")
		# 连调 3 次不堆叠
		reg.play_fill_flash()
		reg.play_fill_flash()
		reg.play_fill_flash()
		_eq(reg.active_tween_count(), 1, "H.连调 3 次 -> 仍只有 1 个活跃 tween（不堆叠）")

		# tween 结束后归零
		await _spin(400)
		_eq(reg.active_tween_count(), 0, "H.脉冲结束后活跃 tween 归零")

	# Fx 返回值
	var tw := Fx.fill_flash(reg, 0.2)
	_check(tw != null and tw.is_valid(), "H.Fx.fill_flash 返回有效 Tween")

	# 错峰入场总时长
	_near(Fx.stagger_total_duration(5, 0.02, 0.3), 0.38, 0.001, "H.stagger 总时长(5,0.02,0.3) == 0.38")
	_near(Fx.stagger_total_duration(1, 0.02, 0.3), 0.30, 0.001, "H.stagger 总时长(1,...) == duration")

	# 错峰入场是行为级的：等总时长后所有节点都完全不透明
	var nodes: Array = cv.get_children()
	var n := nodes.size()
	var step := 0.02
	var dur := 0.25
	var intro := Fx.stagger_intro(nodes, step, dur)
	_check(intro != null and intro.is_valid(), "H.Fx.stagger_intro 返回有效 Tween")
	# 起始应为全透明
	var alpha0 := (nodes[0] as CanvasItem).modulate.a
	_near(alpha0, 0.0, 0.01, "H.入场起始 alpha == 0")
	# 等 (n-1)*step + dur 之后应全部不透明
	await _spin(int(((n - 1) * step + dur) * 1000.0) + 250)
	var not_full := 0
	for node in nodes:
		if (node as CanvasItem).modulate.a < 0.99:
			not_full += 1
	_eq(not_full, 0, "H.等满总时长后 %d 个节点全部 alpha == 1" % n)

	# swatch_pop 返回有效 tween
	var probe := Button.new()
	probe.custom_minimum_size = Vector2(40.0, 30.0)
	add_child(probe)
	var pop := Fx.swatch_pop(probe, 0.18)
	_check(pop != null and pop.is_valid(), "H.Fx.swatch_pop 返回有效 Tween")


# ============================================================ I. UI

func _test_ui() -> void:
	_say("")
	_say("--- I. UI（色板 + 顶栏）---")

	var pp := PalettePanel.new()
	pp.name = "TestPalette"
	add_child(pp)
	pp.build()

	_eq(pp.swatch_count(), 16, "I.色板色块数 == 16（字面量）")
	var null_swatch := 0
	for i in pp.swatch_count():
		if pp.swatch_at(i) == null:
			null_swatch += 1
	_eq(null_swatch, 0, "I.16 个色块全部可取到")

	# 选中态
	pp.set_selected(PaletteDef.palette_color(3))
	_check(pp.selected_color().is_equal_approx(PaletteDef.palette_color(3)), "I.set_selected 生效")
	_eq(pp.selected_index(), 3, "I.selected_index == 3")

	# 点第 5 个色块应发出 color_selected 并更新选中
	var got_color := [Color(0.0, 0.0, 0.0)]
	var cb := func(c: Color) -> void: got_color[0] = c
	pp.color_selected.connect(cb)
	var sw := pp.swatch_at(5) as Button
	_check(sw != null, "I.swatch_at(5) 是 Button")
	if sw != null:
		sw.emit_signal("pressed")
		_check((got_color[0] as Color).is_equal_approx(PaletteDef.palette_color(5)),
			"I.点色块 5 -> color_selected 发出该颜色")
		_eq(pp.selected_index(), 5, "I.点色块 5 -> selected_index == 5")
	pp.color_selected.disconnect(cb)

	# 区域预览
	pp.set_region_preview(Color(0.4, 0.5, 0.6))
	_check(pp.strength() > 0.0, "I.强度滑块有初值")

	# 顶栏
	var hud := ColorHud.new()
	hud.name = "TestHud"
	add_child(hud)
	hud.build()

	for bn in ["SaveButton", "LoadButton", "ExportButton", "ResetButton"]:
		_check(hud.button(bn) != null, "I.顶栏按钮 %s 存在" % bn)

	var missing := 0
	for pn in PatternSchema.PATTERNS:
		if hud.pattern_button(String(pn)) == null:
			missing += 1
	_eq(missing, 0, "I.7 个图案按钮全部存在")

	# 图案按钮发信号
	var got_pattern := [""]
	var cb2 := func(n: String) -> void: got_pattern[0] = n
	hud.pattern_selected.connect(cb2)
	var pb := hud.pattern_button("pig")
	if pb != null:
		pb.emit_signal("pressed")
		_eq(got_pattern[0], "pig", "I.点图案按钮 -> pattern_selected 发出 pig")
	hud.pattern_selected.disconnect(cb2)

	# 操作按钮发信号
	var got_action := [""]
	var cb3 := func(a: String) -> void: got_action[0] = a
	hud.action_pressed.connect(cb3)
	var sb := hud.button("ExportButton")
	if sb != null:
		sb.emit_signal("pressed")
		_eq(got_action[0], "ExportButton", "I.点导出按钮 -> action_pressed 发出 ExportButton")
	hud.action_pressed.disconnect(cb3)

	# 命中信息
	hud.set_hit_info(["body", "stripe_1"])
	_check(hud.hit_text().contains("2"), "I.set_hit_info 显示命中数 2")
	hud.set_hit_info([])
	_check(hud.hit_text().contains("0"), "I.set_hit_info([]) 显示 0")

	# refresh 不崩
	hud.refresh()
	_check(hud.status_text().length() > 0, "I.refresh 后有状态文本")

	pp.queue_free()
	hud.queue_free()


# ============================================================ J. 主场景装配

func _test_main_scene() -> void:
	_say("")
	_say("--- J. main.tscn 装配 ---")

	var packed := load("res://scenes/main.tscn")
	_check(packed != null, "J.main.tscn 能加载")
	if packed == null:
		return

	# main.tscn 自带一个 CanvasView，先释放测试用的画布，避免两个画布的区域同时注册在物理空间里
	if _canvas != null and is_instance_valid(_canvas):
		remove_child(_canvas)
		_canvas.free()
		_canvas = null
		await get_tree().physics_frame
		await get_tree().physics_frame

	var main = packed.instantiate()
	add_child(main)
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().physics_frame

	var hud = main.get_node_or_null("Hud")
	var palette = main.get_node_or_null("Palette")
	var area = main.get_node_or_null("CanvasArea")
	var cv = main.get_node_or_null("CanvasArea/CanvasView")

	_check(hud != null, "J.装配出 Hud")
	_check(palette != null, "J.装配出 Palette")
	_check(area != null, "J.装配出 CanvasArea")
	_check(cv != null, "J.装配出 CanvasView")

	_eq(PaintState.pattern_name, "flower", "J.启动自动加载 flower")
	if cv != null:
		_eq((cv as CanvasView).region_count(), 9, "J.画布建出 9 个区域")
		# 点查询在真实装配下同样可用（画布有偏移，验证坐标换算）
		var reg := (cv as CanvasView).region_node("core")
		if reg != null:
			var world := (cv as CanvasView).to_global(reg.centroid())
			var hits := (cv as CanvasView).pick_region_ids(world)
			_check(hits.has("core"), "J.装配后按世界坐标点查询命中 core（hits=%s）" % str(hits))

	main.queue_free()
	await get_tree().process_frame
