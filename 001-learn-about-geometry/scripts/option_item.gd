class_name OptionItem
extends Button
## 一个答题选项 = 按钮 + 内嵌 3D 模型预览。
## 对外发 option_selected 信号（自定义信号解耦：quiz 只管收，不关心里面怎么画）

signal option_selected(shape_path: String)

## 这个选项对应的模型路径，quiz 用它来判题
@export var shape_path: String = ""

## 场景里以子场景形式放了一个 ShapePreview
@onready var preview: ShapePreview = $ShapePreview


func _ready() -> void:
	pressed.connect(_on_pressed)


## 设置这个选项显示哪个模型（quiz 每次出题调用 4 次）
func set_shape(packed: PackedScene, path: String) -> void:
	shape_path = path
	preview.set_shape(packed)


func _on_pressed() -> void:
	option_selected.emit(shape_path)


## 答题后的反馈：correct = 这是否是答案；chosen = 玩家点的是否是它
func show_result(correct: bool, chosen: bool) -> void:
	var target := Color.WHITE
	if correct:
		target = Color(0.62, 0.92, 0.62)   # 答案：绿
	elif chosen:
		target = Color(0.95, 0.6, 0.6)     # 选错的：红
	var tween := create_tween()
	tween.tween_property(self, "modulate", target, 0.15)
	tween.tween_property(self, "scale", Vector2(1.05, 1.05), 0.08)
	tween.tween_property(self, "scale", Vector2.ONE, 0.16)


## 下一题前恢复原状
func reset_style() -> void:
	modulate = Color.WHITE
	scale = Vector2.ONE
