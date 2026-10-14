extends Control
## 答题页：从 GameState 取当前题目 → 布置 4 个选项 → 判定得分 → 推进流程。
## 状态机：出题 → 等待作答(_answering=true) → 判定停顿 → 下一题 / 结算

const FEEDBACK_DELAY := 1.0        # 答题后停顿秒数
const SCORE_PER_QUESTION := 10     # 每题 10 分

@onready var score_label: Label = $TopBar/ScoreLabel
@onready var progress_label: Label = $TopBar/ProgressLabel
@onready var time_label: Label = $TopBar/TimeLabel
@onready var question_preview: ShapePreview = $QuestionArea/ShapePreview

var _options: Array[OptionItem] = []
var _answering := true


func _ready() -> void:
	# 收集 4 个选项并连上它们的自定义信号
	for child in $OptionsRow.get_children():
		if child is OptionItem:
			_options.append(child)
			child.option_selected.connect(_on_option_selected)

	if GameState.questions.is_empty():
		push_error("没有题目数据，回开始页")
		get_tree().change_scene_to_file("res://scenes/start_screen.tscn")
		return

	# 计时起点：用户看到第一题的时刻（不含切场景耗时）
	GameState.quiz_start_msec = Time.get_ticks_msec()
	GameState.total_msec = 0
	_setup_question()


## 出下一题
func _setup_question() -> void:
	_answering = true

	var q: Dictionary = GameState.get_current_question()
	var answer_path: String = q["answer"]
	var answer_packed: PackedScene = GameState.model_cache[answer_path]
	question_preview.set_shape(answer_packed)

	for opt in _options:
		opt.reset_style()
		opt.disabled = false

	var i := 0
	for path: String in q["options"]:
		if i < _options.size():
			var packed: PackedScene = GameState.model_cache[path]
			_options[i].set_shape(packed, path)
			i += 1

	_update_labels()


func _update_labels() -> void:
	score_label.text = "得分：%d" % GameState.score
	progress_label.text = "第 %d / %d 题" % [GameState.question_index + 1, GameState.questions.size()]


## 计时显示：每帧刷，但不影响逻辑（计时数据用毫秒时间戳）
func _process(_delta: float) -> void:
	if GameState.quiz_start_msec > 0:
		var secs := float(Time.get_ticks_msec() - GameState.quiz_start_msec) / 1000.0
		time_label.text = "用时：%.1f 秒" % secs


func _on_option_selected(chosen_path: String) -> void:
	if not _answering:
		return
	_answering = false  # 上锁，防止停顿期间连点

	var q: Dictionary = GameState.get_current_question()
	var answer_path: String = q["answer"]
	var is_correct: bool = chosen_path == answer_path
	if is_correct:
		GameState.score += SCORE_PER_QUESTION

	# 反馈：答案染绿，选错的染红，全部禁用
	for opt in _options:
		opt.disabled = true
		opt.show_result(opt.shape_path == answer_path, opt.shape_path == chosen_path)

	_update_labels()

	# 停顿一会儿，让玩家看清对错
	await get_tree().create_timer(FEEDBACK_DELAY).timeout

	GameState.question_index += 1
	if GameState.is_finished():
		_finish()
	else:
		_setup_question()


## 十题答完：结算 + 写排行榜 + 去结算页
func _finish() -> void:
	GameState.total_msec = Time.get_ticks_msec() - GameState.quiz_start_msec
	Leaderboard.add_record(GameState.score, GameState.total_msec)
	get_tree().change_scene_to_file("res://scenes/result_screen.tscn")
