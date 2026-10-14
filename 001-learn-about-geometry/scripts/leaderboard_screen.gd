extends Control
## 排行榜页：从 Leaderboard 单例读记录，动态生成行。
## 排序规则已在单例里保证：分数降序、同分用时升序。

@onready var rows_box: VBoxContainer = $ScrollContainer/RowsBox
@onready var empty_label: Label = $EmptyLabel


func _ready() -> void:
	_rebuild()


## 清空旧行 → 按记录数生成新行（代码动态造 UI）
func _rebuild() -> void:
	for child in rows_box.get_children():
		rows_box.remove_child(child)
		child.queue_free()

	var records: Array = Leaderboard.records
	empty_label.visible = records.is_empty()

	for i in records.size():
		var r: Dictionary = records[i]
		var secs := float(r["msec"]) / 1000.0
		var row := Label.new()
		row.text = "第 %d 名    得分 %d    用时 %.1f 秒    %s" % [
			i + 1, int(r["score"]), secs, String(r.get("date", ""))]
		row.add_theme_font_size_override("font_size", 36)
		row.add_theme_color_override("font_color", Color(0.2, 0.25, 0.32))
		rows_box.add_child(row)


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/start_screen.tscn")


func _on_clear_pressed() -> void:
	Leaderboard.clear_records()
	_rebuild()
