extends Control
# 002-piano 主装配层：标题栏 + HUD 控制面板 + 88 键键盘
# 只负责"摆位置"和"接线"，不含任何业务逻辑。

const KeyboardScript := preload("res://scripts/keyboard.gd")
const HudScript := preload("res://scripts/hud.gd")

const DEFAULT_WHITE_KEY_WIDTH := 36.0
const MIN_WHITE_KEY_WIDTH := 9.0
const MAX_WHITE_KEY_WIDTH := 60.0

var keyboard: Control = null
var hud: Control = null

var _bg: ColorRect = null
var _root: VBoxContainer = null
var _scroll: ScrollContainer = null
var _key_area: Control = null
var _fit_check: CheckBox = null

# 正在发声的琴键（含被延音挂住的），用于回放时点亮
var _lit: Dictionary = {}

var _relayout_queued := false


func _ready() -> void:
	_build_ui()
	_connect_engine()
	_queue_relayout()
	print("[main] Piano 88 ready")


# ============================================================
# 构建界面
# ============================================================
func _build_ui() -> void:
	# ---- 背景 ----
	_bg = ColorRect.new()
	_bg.name = "Background"
	_bg.color = Color(0.07, 0.08, 0.11)
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 10)
	add_child(margin)

	_root = VBoxContainer.new()
	_root.name = "Root"
	_root.add_theme_constant_override("separation", 8)
	margin.add_child(_root)

	_build_title_bar()
	_build_hud()
	_build_keyboard()


func _build_title_bar() -> void:
	var bar := HBoxContainer.new()
	bar.name = "TitleBar"
	bar.add_theme_constant_override("separation", 12)
	bar.custom_minimum_size.y = 34
	_root.add_child(bar)

	var title := Label.new()
	title.name = "Title"
	title.text = "Piano 88"
	title.add_theme_font_size_override("font_size", 22)
	bar.add_child(title)

	var spacer := Control.new()
	spacer.name = "Spacer"
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)

	var hint := Label.new()
	hint.name = "Hint"
	hint.text = "琴键 Z S X D C V G B H N J M ／ Q 2 W 3 E R 5 T 6 Y 7 U ／ , L . ; /      空格 = 延音    Ctrl+R = 录制    Ctrl+P = 回放    Esc = 全部停止"
	hint.add_theme_font_size_override("font_size", 12)
	hint.modulate = Color(1, 1, 1, 0.55)
	bar.add_child(hint)

	_fit_check = CheckBox.new()
	_fit_check.name = "FitToWidth"
	_fit_check.text = "适应宽度"
	_fit_check.button_pressed = true
	_fit_check.toggled.connect(_on_fit_toggled)
	bar.add_child(_fit_check)


func _build_hud() -> void:
	hud = HudScript.new()
	hud.name = "Hud"
	hud.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_root.add_child(hud)


func _build_keyboard() -> void:
	_scroll = ScrollContainer.new()
	_scroll.name = "Scroll"
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.resized.connect(_queue_relayout)
	_root.add_child(_scroll)

	# ScrollContainer 会把直接子节点拉伸到容器尺寸，所以套一层"承载区"，
	# 键盘本体按自己的最小尺寸定位在承载区里（宽度不够时横向滚动）。
	_key_area = Control.new()
	_key_area.name = "KeyArea"
	_key_area.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scroll.add_child(_key_area)

	keyboard = KeyboardScript.new()
	keyboard.name = "Keyboard"
	keyboard.fit_to_width = false  # 由本脚本统一驱动宽度，避免双重计算打架
	_key_area.add_child(keyboard)

	keyboard.minimum_size_changed.connect(_sync_key_area)
	_key_area.resized.connect(_sync_key_area)


# ============================================================
# 接线
# ============================================================
func _connect_engine() -> void:
	PianoEngine.note_started.connect(_on_note_started)
	PianoEngine.note_stopped.connect(_on_note_stopped)


func _on_note_started(midi: int, _velocity: float) -> void:
	_lit[midi] = true
	if keyboard != null:
		keyboard.set_note_highlight(midi, true)


func _on_note_stopped(midi: int) -> void:
	_lit.erase(midi)
	if keyboard != null:
		keyboard.set_note_highlight(midi, false)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			# 紧急制动：把所有正在响的音全部掐掉（含延音挂住的）
			PianoEngine.all_notes_off()
			_lit.clear()
			get_viewport().set_input_as_handled()


# ============================================================
# 布局
# ============================================================
func _on_fit_toggled(_pressed: bool) -> void:
	if _scroll != null:
		_scroll.scroll_horizontal = 0
	_queue_relayout()


func _queue_relayout() -> void:
	# 合并同一帧内的多次重排请求，避免 ScrollContainer 尺寸变化引发的递归
	if _relayout_queued:
		return
	_relayout_queued = true
	_deferred_relayout.call_deferred()


func _deferred_relayout() -> void:
	_relayout_queued = false
	_relayout()


func _relayout() -> void:
	if keyboard == null or _scroll == null:
		return

	var fit: bool = _fit_check != null and _fit_check.button_pressed
	if fit:
		var avail: float = _scroll.size.x - 8.0
		if avail < 100.0:
			avail = size.x - 40.0
		var want: float = clampf(
			avail / float(MusicTheory.white_key_count()),
			MIN_WHITE_KEY_WIDTH,
			MAX_WHITE_KEY_WIDTH
		)
		# 只有宽度真的变了才重建，否则会在 resized 里反复重建 88 个节点
		if absf(keyboard.white_key_width - want) > 0.01:
			keyboard.white_key_width = want
			keyboard.build()
	else:
		if absf(keyboard.white_key_width - DEFAULT_WHITE_KEY_WIDTH) > 0.01:
			keyboard.white_key_width = DEFAULT_WHITE_KEY_WIDTH
			keyboard.build()

	_sync_key_area()


func _sync_key_area() -> void:
	if _key_area == null or keyboard == null:
		return
	var want: Vector2 = keyboard.custom_minimum_size
	if want.x <= 0.0 or want.y <= 0.0:
		return
	if not _key_area.custom_minimum_size.is_equal_approx(want):
		_key_area.custom_minimum_size = want
	if not keyboard.size.is_equal_approx(want):
		keyboard.size = want
	# 用 ScrollContainer 的"可视高度"来垂直居中，而不是承载区 _key_area 的高度：
	# ScrollContainer 不会在禁用滚动的轴上把子节点拉伸到容器尺寸，
	# 所以 _key_area.size.y 只等于键盘自身高度，用它居中会恒为 0（实测键盘贴在顶部、下方留 330px 死区）。
	var view_h: float = _scroll.size.y if _scroll != null else _key_area.size.y
	keyboard.position = Vector2(0.0, maxf(0.0, (view_h - want.y) * 0.5))
