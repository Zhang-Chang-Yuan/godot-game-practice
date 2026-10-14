class_name Fx
extends RefCounted
# Tween 工具（demo 重点 2）。
# 全部用 create_tween() 实现；调用方负责保存返回的 Tween，并在下次调用前 kill() 以避免堆叠。

## 填色脉冲：把节点 modulate 先推到过亮再回落，做出"点亮"的感觉。
## modulate 分量 > 1 会提亮，所以这里从 1.9 落回 1.0。
static func fill_flash(node: CanvasItem, duration := 0.25) -> Tween:
	if node == null or not is_instance_valid(node):
		return null
	node.modulate = Color(1.9, 1.9, 1.9, 1.0)
	var tw := node.create_tween()
	tw.tween_property(node, "modulate", Color(1.0, 1.0, 1.0, 1.0), duration) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	return tw


## 色板选中脉冲：scale 弹一下再回原样
static func swatch_pop(node: Control, duration := 0.18) -> Tween:
	if node == null or not is_instance_valid(node):
		return null
	node.pivot_offset = node.size * 0.5
	node.scale = Vector2.ONE
	var tw := node.create_tween()
	tw.tween_property(node, "scale", Vector2(1.18, 1.18), duration * 0.45) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(node, "scale", Vector2.ONE, duration * 0.55) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	return tw


## 错峰入场：第 i 个节点延迟 i*step 秒后从透明淡入。
## 总时长 = (有效节点数 - 1) * step + duration。
static func stagger_intro(nodes: Array, step := 0.02, duration := 0.3) -> Tween:
	var host: Node = null
	for n in nodes:
		if n is Node and is_instance_valid(n):
			host = n
			break
	if host == null:
		return null

	var tw := host.create_tween()
	tw.set_parallel(true)
	var i := 0
	for n in nodes:
		if not (n is CanvasItem) or not is_instance_valid(n):
			continue
		var ci := n as CanvasItem
		ci.modulate = Color(1.0, 1.0, 1.0, 0.0)
		tw.tween_property(ci, "modulate", Color(1.0, 1.0, 1.0, 1.0), duration) \
			.set_delay(float(i) * step)
		i += 1
	return tw


## 悬停呼吸：轻微上下浮动并循环
static func float_loop(node: Node2D, amplitude := 6.0, period := 1.6) -> Tween:
	if node == null or not is_instance_valid(node):
		return null
	var base_y := node.position.y
	var tw := node.create_tween()
	tw.set_loops()
	tw.tween_property(node, "position:y", base_y - amplitude, period * 0.5) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(node, "position:y", base_y + amplitude, period * 0.5) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(node, "position:y", base_y, period * 0.5) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	return tw


## 错峰入场的理论总时长（秒）。测试用它与实际等待时间对齐。
static func stagger_total_duration(count: int, step := 0.02, duration := 0.3) -> float:
	return float(maxi(count - 1, 0)) * step + duration
