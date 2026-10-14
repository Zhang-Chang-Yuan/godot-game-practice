class_name ShapePreview
extends Control
## 在 2D UI 里显示 3D 模型的关键技术 —— SubViewport 视图：
## SubViewportContainer 把子 Viewport 渲染出的 3D 画面当成一张贴图铺满自身，
## 于是任何 Control 界面上都能"嵌"一个旋转的 3D 模型。

## 要显示的模型（在编辑器里拖，或运行时用 set_shape()）
@export var shape_scene: PackedScene:
	set(value):
		shape_scene = value
		if is_node_ready():
			_refresh()

@onready var holder: Node3D = $SubViewportContainer/SubViewport/ShapeHolder
@onready var camera: Camera3D = $SubViewportContainer/SubViewport/Camera3D


func _ready() -> void:
	camera.look_at(Vector3.ZERO, Vector3.UP)
	_refresh()


## 运行时切换模型（答题页每题调用一次）
func set_shape(packed: PackedScene) -> void:
	shape_scene = packed


func _refresh() -> void:
	if shape_scene == null:
		return
	# 清掉旧模型（remove_child + queue_free：先从树移除，再安全释放）
	for child in holder.get_children():
		holder.remove_child(child)
		child.queue_free()
	var inst: Node3D = shape_scene.instantiate()
	holder.add_child(inst)


## 让模型缓慢自转，界面更生动
func _process(delta: float) -> void:
	if shape_scene != null and holder.get_child_count() > 0:
		holder.rotate_y(delta * 0.7)
