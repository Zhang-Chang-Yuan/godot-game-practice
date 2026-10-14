class_name PatternData
extends RefCounted
# 读 + 校验图案 JSON。任何失败都返回空字典并 push_warning，绝不崩溃。

static func exists(name: String) -> bool:
	if not PatternSchema.is_valid_name(name):
		return false
	return FileAccess.file_exists(PatternSchema.pattern_path(name))


## 读 + 校验；失败返回 {} 并 push_warning
static func load_pattern(name: String) -> Dictionary:
	if not PatternSchema.is_valid_name(name):
		push_warning("PatternData: 非法图案名 '%s'" % name)
		return {}

	var path := PatternSchema.pattern_path(name)
	if not FileAccess.file_exists(path):
		push_warning("PatternData: 图案文件不存在 %s" % path)
		return {}

	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("PatternData: 打不开 %s（%d）" % [path, FileAccess.get_open_error()])
		return {}
	var text := f.get_as_text()
	f.close()

	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		push_warning("PatternData: JSON 解析失败 %s" % path)
		return {}

	var d := parsed as Dictionary
	var errs := PatternSchema.validate_pattern(d)
	if not errs.is_empty():
		push_warning("PatternData: 校验失败 %s -> %s" % [path, ", ".join(errs)])
		return {}
	return d


## 7 个图案名（顺序同 PatternSchema.PATTERNS）
static func list_patterns() -> Array[String]:
	var out: Array[String] = []
	for n in PatternSchema.PATTERNS:
		out.append(String(n))
	return out


## 统计：{ "region_count": int, "total_area": float }
static func summarize(pattern: Dictionary) -> Dictionary:
	var count := 0
	var total := 0.0
	var rv: Variant = pattern.get("regions", [])
	if rv is Array:
		for r in (rv as Array):
			if r is Dictionary:
				count += 1
				total += PatternSchema.polygon_area(
					PatternSchema.to_packed((r as Dictionary).get("polygon", []))
				)
	return { "region_count": count, "total_area": total }


## 图案里全部 region_id 的集合（用于过滤存档里的未知 id）
static func region_id_set(pattern: Dictionary) -> Dictionary:
	var out := {}
	var rv: Variant = pattern.get("regions", [])
	if rv is Array:
		for r in (rv as Array):
			if r is Dictionary:
				out[String((r as Dictionary).get("id", ""))] = true
	return out
