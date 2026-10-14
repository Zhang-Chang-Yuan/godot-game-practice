extends Control
# 单个琴键：只负责"画"，不处理输入、不碰 PianoEngine。
# 键面 / 边框 / 按下态 / 高亮态 / 音名文字全部在 _draw() 里画出来。

# ---- 尺寸参数（由 keyboard.gd 写入）----
var white_key_width: float = 36.0   # 用于自适应字号
var key_height: float = 220.0       # 实际键高（黑键比白键矮）

# ---- 契约要求的公开字段 ----
var midi: int = 60
var is_black: bool = false
var label: String = ""

# ---- 视觉状态（由 keyboard.gd 写入）----
var pressed: bool = false           # 按下态
var highlighted: bool = false       # 回放高亮态

# ---- 配色 ----
const WHITE_FACE := Color(0.98, 0.98, 0.96)
const WHITE_PRESSED := Color(0.72, 0.73, 0.78)
const BLACK_FACE := Color(0.10, 0.10, 0.12)
const BLACK_PRESSED := Color(0.40, 0.41, 0.46)
const HIGHLIGHT_COLOR := Color(0.20, 0.75, 1.00)
const BORDER_COLOR := Color(0.15, 0.15, 0.18)
const WHITE_TEXT_COLOR := Color(0.25, 0.25, 0.28)
const BLACK_TEXT_COLOR := Color(0.85, 0.85, 0.88)


func _ready() -> void:
	# 琴键自己不抢事件，鼠标命中由 keyboard.gd 统一按坐标换算处理
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## 设置按下态（不触发发声，发声由 keyboard.gd 负责）
func set_pressed(on: bool) -> void:
	if pressed == on:
		return
	pressed = on
	queue_redraw()


## 设置回放高亮态（纯视觉）
func set_highlighted(on: bool) -> void:
	if highlighted == on:
		return
	highlighted = on
	queue_redraw()


func _draw() -> void:
	var w := size.x
	var h := size.y
	if w <= 0.0 or h <= 0.0:
		return

	# 1) 键面
	var face := BLACK_FACE if is_black else WHITE_FACE
	if pressed:
		face = BLACK_PRESSED if is_black else WHITE_PRESSED
	draw_rect(Rect2(Vector2.ZERO, Vector2(w, h)), face, true)

	# 2) 高亮描边：画在键内，避免越界被裁掉
	if highlighted:
		var bw := clampf(w * 0.14, 2.0, 5.0)
		draw_rect(Rect2(Vector2.ZERO, Vector2(w, h)), HIGHLIGHT_COLOR, false, bw)

	# 3) 边框
	draw_rect(Rect2(Vector2.ZERO, Vector2(w, h)), BORDER_COLOR, false, 1.0)

	# 4) 音名：白键画在底部居中；黑键画在键内底部居中（浅色）
	if w < 22.0 or label.is_empty():
		return
	var font := ThemeDB.fallback_font
	if font == null:
		return

	var font_size := int(clampf(white_key_width * 0.34, 7.0, 14.0))
	var text_size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	var baseline_y := h - 6.0 - (h - font_size) * 0.06
	draw_string(
		font,
		Vector2((w - text_size.x) * 0.5, baseline_y),
		label,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		font_size,
		BLACK_TEXT_COLOR if is_black else WHITE_TEXT_COLOR
	)
