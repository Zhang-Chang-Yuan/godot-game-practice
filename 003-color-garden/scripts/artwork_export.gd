class_name ArtworkExport
extends RefCounted
# 把图案 + 已累积的颜色光栅化成 Image 并导出 PNG。
# **纯逻辑扫描线填充**，不依赖 GPU 截图 —— 这样 headless 下也能测试与导出。

## 光栅化：背景 = PaletteDef.BASE_COLOR，按 z 升序把每个区域用 even-odd 扫描线填成它的颜色。
static func rasterize(pattern: Dictionary, colors: Dictionary, size: Vector2i) -> Image:
	var img := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
	img.fill(PaletteDef.BASE_COLOR)

	var rv: Variant = pattern.get("regions", [])
	if not (rv is Array):
		return img

	var list: Array = (rv as Array).duplicate()
	list.sort_custom(func(a: Variant, b: Variant) -> bool:
		var za := int((a as Dictionary).get("z", 0)) if a is Dictionary else 0
		var zb := int((b as Dictionary).get("z", 0)) if b is Dictionary else 0
		return za < zb
	)

	for item in list:
		if not (item is Dictionary):
			continue
		var rd := item as Dictionary
		var rid := String(rd.get("id", ""))
		var poly := PatternSchema.to_packed(rd.get("polygon", []))
		if poly.size() < 3:
			continue
		var col := PaletteDef.BASE_COLOR
		if colors.has(rid):
			var cv: Variant = colors[rid]
			if cv is Color:
				col = cv as Color
		_fill_polygon(img, poly, col, size)

	return img


## even-odd 扫描线填充单个多边形
static func _fill_polygon(img: Image, poly: PackedVector2Array, col: Color, size: Vector2i) -> void:
	var n := poly.size()
	if n < 3:
		return

	var min_y := INF
	var max_y := -INF
	for p in poly:
		min_y = minf(min_y, p.y)
		max_y = maxf(max_y, p.y)
	if min_y == INF or max_y == -INF:
		return

	var y_from := maxi(int(floor(min_y)), 0)
	var y_to := mini(int(ceil(max_y)), size.y - 1)

	for y in range(y_from, y_to + 1):
		var sy := float(y) + 0.5
		var xs: Array[float] = []
		var j := n - 1
		for i in n:
			var pi := poly[i]
			var pj := poly[j]
			if (pi.y > sy) != (pj.y > sy):
				var t := (sy - pi.y) / (pj.y - pi.y)
				xs.append(pi.x + t * (pj.x - pi.x))
			j = i
		if xs.size() < 2:
			continue
		xs.sort()
		var k := 0
		while k + 1 < xs.size():
			var x_from := maxi(int(ceil(xs[k] - 0.5)), 0)
			var x_to := mini(int(floor(xs[k + 1] - 0.5)), size.x - 1)
			for x in range(x_from, x_to + 1):
				img.set_pixel(x, y, col)
			k += 2


## 光栅化后存 PNG
static func export_png(pattern: Dictionary, colors: Dictionary, size: Vector2i, path: String) -> Error:
	var img := rasterize(pattern, colors, size)
	if img == null:
		return ERR_CANT_CREATE
	return img.save_png(path)


## 统计非背景色像素数（测试用）
static func painted_pixel_count(img: Image) -> int:
	if img == null:
		return 0
	var n := 0
	for y in img.get_height():
		for x in img.get_width():
			if not PaletteDef.is_base(img.get_pixel(x, y)):
				n += 1
	return n
