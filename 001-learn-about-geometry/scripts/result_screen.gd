extends Control
## 结算页：显示本局得分与用时，提供 再来一局 / 看排行榜 / 回主菜单

@onready var score_label: Label = $ScoreLabel
@onready var time_label: Label = $TimeLabel


func _ready() -> void:
	score_label.text = "本局得分：%d / 100" % GameState.score
	var secs := float(GameState.total_msec) / 1000.0
	time_label.text = "本局用时：%.1f 秒" % secs


func _on_retry_pressed() -> void:
	# 再来一局 = 回加载页（loading 会重新生成 10 题、重新预载模型）
	get_tree().change_scene_to_file("res://scenes/loading_screen.tscn")


func _on_leaderboard_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/leaderboard.tscn")


func _on_home_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/start_screen.tscn")
