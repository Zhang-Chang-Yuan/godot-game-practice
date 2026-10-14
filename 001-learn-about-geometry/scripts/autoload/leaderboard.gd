extends Node
## Leaderboard 单例：排行榜的存档中枢。
## 存哪：user://leaderboard.json（注意：res:// 只读，运行时只能写 user://）
## 排序：分数降序；同分比用时，少者（快者）优先

const SAVE_PATH := "user://leaderboard.json"
const MAX_RECORDS := 20   # 只保留前 20 名

var records: Array = []


func _ready() -> void:
	_load_records()


# ---------- 读写 ----------

func _load_records() -> void:
	records = []
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		return
	var text := file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary and parsed.has("records") and parsed["records"] is Array:
		records = parsed["records"]


func _save_records() -> void:
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_error("排行榜写入失败：%s" % SAVE_PATH)
		return
	file.store_string(JSON.stringify({"records": records}))
	file.close()


# ---------- 对外 ----------

## 记一局：得分 + 总毫秒；排序后只留前 20 名
func add_record(score: int, msec: int) -> void:
	records.append({
		"score": score,
		"msec": msec,
		"date": Time.get_datetime_string_from_system(),
	})
	_sort_records()
	if records.size() > MAX_RECORDS:
		records.resize(MAX_RECORDS)
	_save_records()


func clear_records() -> void:
	records = []
	_save_records()


## 自定义比较器：先比分数（降序），同分比毫秒（升序）
func _sort_records() -> void:
	records.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["score"]) == int(b["score"]):
			return int(a["msec"]) < int(b["msec"])
		return int(a["score"]) > int(b["score"]))
