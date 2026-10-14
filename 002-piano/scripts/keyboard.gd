extends Control
# 88 键键盘容器：全部节点在代码里生成，不依赖手写 .tscn 子节点。
# 负责：布局、鼠标交互（含拖动连奏）、电脑键盘映射、press_note/release_note 唯一入口。

const PianoKeyScript := preload("res://scripts/piano_key.gd")

# ---- 契约常量 ----
const WHITE_KEY_WIDTH := 36.0
const WHITE_KEY_HEIGHT := 220.0
const BLACK_KEY_WIDTH_RATIO := 0.62
const BLACK_KEY_HEIGHT_RATIO := 0.62

# ---- 层叠顺序：黑键必须盖在白键之上 ----
const WHITE_Z := 0
const BLACK_Z := 10

# ---- 契约状态 ----
var white_key_width: float = WHITE_KEY_WIDTH
var fit_to_width: bool = false
var computer_keyboard_enabled: bool = true

# ---- 契约信号 ----
signal key_pressed(midi: int)
signal key_released(midi: int)

# ---- 内部状态 ----
var _key_nodes: Dictionary = {}       # midi -> PianoKey(Control)
var _physical_map: Dictionary = {}    # physical_keycode -> midi
var _held: Dictionary = {}            # midi -> true（防重复发声）
var _mouse_pressed: bool = false      # 鼠标左键是否按住
var _mouse_midi: int = -1             # 当前鼠标音，-1 表示没有
var _highlighted: Dictionary = {}     # midi -> true（回放高亮）
var _last_fit_width: float = -1.0     # 上次 fit 算出的宽度，用于防抖


func _ready() -> void:
	_build_physical_map()
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_exited.connect(_on_mouse_exited)
	if _key_nodes.is_empty():
		build()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_RESIZED:
			if fit_to_width:
				_apply_fit()
		NOTIFICATION_WM_WINDOW_FOCUS_OUT:
			# 窗口失焦：停掉鼠标音与所有电脑键盘按住的音，避免"卡住不松"
			_release_mouse_note()
			_mouse_pressed = false
			for midi in _held.keys():
				release_note(int(midi))


# ============================================================
# 构建
# ============================================================

## 构建 88 个键（幂等，可重复调用：先清空旧子节点）
func build() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_key_nodes.clear()
	_mouse_midi = -1
	_mouse_pressed = false
	_held.clear()

	# 1) 先建 52 个白键（按下标依次排列）
	var white_index := 0
	for midi in range(MusicTheory.MIDI_LOWEST, MusicTheory.MIDI_HIGHEST + 1):
		if MusicTheory.is_black_key(midi):
			continue
		var key := _make_key(midi, false)
		key.position = Vector2(white_index * white_key_width, 0.0)
		key.size = Vector2(white_key_width, WHITE_KEY_HEIGHT)
		white_index += 1

	# 2) 再建 36 个黑键，水平中心骑在"前一个白键的右边界"上
	var black_width := white_key_width * BLACK_KEY_WIDTH_RATIO
	var black_height := WHITE_KEY_HEIGHT * BLACK_KEY_HEIGHT_RATIO
	for midi in range(MusicTheory.MIDI_LOWEST, MusicTheory.MIDI_HIGHEST + 1):
		if not MusicTheory.is_black_key(midi):
			continue
		var key := _make_key(midi, true)
		var x_center := (float(MusicTheory.white_index_of(midi - 1)) + 1.0) * white_key_width
		key.position = Vector2(x_center - black_width * 0.5, 0.0)
		key.size = Vector2(black_width, black_height)

	# 3) 最小尺寸
	custom_minimum_size = Vector2(
		float(MusicTheory.white_key_count()) * white_key_width,
		WHITE_KEY_HEIGHT
	)


## 创建一个琴键节点（加入本控件）
func _make_key(midi: int, black: bool) -> Control:
	var key: Control = PianoKeyScript.new()
	key.name = "Key%d" % midi
	key.midi = midi
	key.is_black = black
	key.label = MusicTheory.midi_to_name(midi)
	key.white_key_width = white_key_width
	key.key_height = WHITE_KEY_HEIGHT if not black else WHITE_KEY_HEIGHT * BLACK_KEY_HEIGHT_RATIO
	key.z_index = BLACK_Z if black else WHITE_Z
	add_child(key)
	_key_nodes[midi] = key
	return key


## 拿到某个 midi 对应的琴键节点，无则 null
func get_key(midi: int) -> Control:
	if _key_nodes.has(midi):
		return _key_nodes[midi]
	return null


# ============================================================
# 适应宽度
# ============================================================

func _apply_fit() -> void:
	if not fit_to_width:
		return
	var available := size.x
	if available <= 0.0:
		available = get_parent_area_size().x
	if available <= 0.0:
		return
	var count := float(MusicTheory.white_key_count())
	if count <= 0.0:
		return
	var new_width := available / count
	if new_width < 1.0:
		return
	# 防抖：宽度没变（差异 < 0.5px）就不重建，避免 custom_minimum_size 引发的循环
	if absf(new_width - _last_fit_width) < 0.5 and not _key_nodes.is_empty():
		return
	_last_fit_width = new_width
	white_key_width = new_width
	build()


# ============================================================
# 发声入口（测试与回放的唯一入口）
# ============================================================

## 程序化按下：校验 -> 去重 -> PianoEngine -> 信号
func press_note(midi: int, velocity: float = 0.8) -> void:
	if not MusicTheory.is_valid_midi(midi):
		push_warning("[Keyboard] press_note 收到非法 midi: %d" % midi)
		return
	if _held.has(midi):
		return  # 已按下，不重复发声
	_held[midi] = true
	_set_key_pressed(midi, true)
	PianoEngine.note_on(midi, velocity)
	emit_signal("key_pressed", midi)


## 程序化松开
func release_note(midi: int) -> void:
	if not MusicTheory.is_valid_midi(midi):
		push_warning("[Keyboard] release_note 收到非法 midi: %d" % midi)
		return
	if not _held.has(midi):
		return  # 未按下，忽略
	_held.erase(midi)
	_set_key_pressed(midi, false)
	PianoEngine.note_off(midi)
	emit_signal("key_released", midi)


## 高亮某个音（供回放显示），纯视觉，不发声
func set_note_highlight(midi: int, on: bool) -> void:
	if not MusicTheory.is_valid_midi(midi):
		return
	if on:
		_highlighted[midi] = true
	else:
		_highlighted.erase(midi)
	var key := get_key(midi)
	if key != null:
		key.set_highlighted(on)


## 视觉：设置某个键的按下态
func _set_key_pressed(midi: int, on: bool) -> void:
	var key := get_key(midi)
	if key != null:
		key.set_pressed(on)


# ============================================================
# 鼠标交互（统一在这里处理，琴键自己不抢事件）
# ============================================================

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			# 右键 = 延音踏板切换，不发声
			PianoEngine.set_sustain(not PianoEngine.sustain_enabled)
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_mouse_pressed = true
				_press_mouse_at(mb.position)
			else:
				_mouse_pressed = false
				_release_mouse_note()
			accept_event()
	elif event is InputEventMouseMotion:
		if _mouse_pressed:
			var mm := event as InputEventMouseMotion
			_press_mouse_at(mm.position)


## 鼠标移到某个位置：命中变化时先松旧再按新（连奏）
func _press_mouse_at(local_pos: Vector2) -> void:
	var midi := _key_at(local_pos)
	if midi == _mouse_midi:
		return
	_release_mouse_note()
	if midi >= 0:
		_mouse_midi = midi
		press_note(midi)


func _release_mouse_note() -> void:
	if _mouse_midi >= 0:
		release_note(_mouse_midi)
		_mouse_midi = -1


## 坐标 -> midi：黑键优先（黑键叠在白键之上）
func _key_at(local_pos: Vector2) -> int:
	if local_pos.x < 0.0 or local_pos.x >= custom_minimum_size.x:
		return -1
	if local_pos.y < 0.0 or local_pos.y > WHITE_KEY_HEIGHT:
		return -1

	var black_width := white_key_width * BLACK_KEY_WIDTH_RATIO
	var black_height := WHITE_KEY_HEIGHT * BLACK_KEY_HEIGHT_RATIO

	# 1) 黑键优先：用"水平中心 = 前一个白键右边界"反推包围盒
	if local_pos.y <= black_height:
		for midi in range(MusicTheory.MIDI_LOWEST, MusicTheory.MIDI_HIGHEST + 1):
			if not MusicTheory.is_black_key(midi):
				continue
			var x_center := (float(MusicTheory.white_index_of(midi - 1)) + 1.0) * white_key_width
			if absf(local_pos.x - x_center) <= black_width * 0.5:
				return midi

	# 2) 白键：按宽度取整
	var white_count := MusicTheory.white_key_count()
	var idx := int(local_pos.x / white_key_width)
	if idx < 0 or idx >= white_count:
		return -1
	for midi in range(MusicTheory.MIDI_LOWEST, MusicTheory.MIDI_HIGHEST + 1):
		if MusicTheory.is_black_key(midi):
			continue
		if MusicTheory.white_index_of(midi) == idx:
			return midi
	return -1


func _on_mouse_exited() -> void:
	# 拖出控件区域：释放当前鼠标音
	if _mouse_pressed:
		_release_mouse_note()


# ============================================================
# 电脑键盘映射
# ============================================================

## 在 _ready() 里构建 keycode -> midi 映射表
func _build_physical_map() -> void:
	_physical_map.clear()
	# Z S X D C V G B H N J M -> 60..71 (C4..B4)
	_physical_map[KEY_Z] = 60
	_physical_map[KEY_S] = 61
	_physical_map[KEY_X] = 62
	_physical_map[KEY_D] = 63
	_physical_map[KEY_C] = 64
	_physical_map[KEY_V] = 65
	_physical_map[KEY_G] = 66
	_physical_map[KEY_B] = 67
	_physical_map[KEY_H] = 68
	_physical_map[KEY_N] = 69
	_physical_map[KEY_J] = 70
	_physical_map[KEY_M] = 71
	# Q 2 W 3 E R 5 T 6 Y 7 U -> 72..83 (C5..B5)
	_physical_map[KEY_Q] = 72
	_physical_map[KEY_2] = 73
	_physical_map[KEY_W] = 74
	_physical_map[KEY_3] = 75
	_physical_map[KEY_E] = 76
	_physical_map[KEY_R] = 77
	_physical_map[KEY_5] = 78
	_physical_map[KEY_T] = 79
	_physical_map[KEY_6] = 80
	_physical_map[KEY_Y] = 81
	_physical_map[KEY_7] = 82
	_physical_map[KEY_U] = 83
	# , L . ; / -> 84..88 (C6..E6)
	_physical_map[KEY_COMMA] = 84
	_physical_map[KEY_L] = 85
	_physical_map[KEY_PERIOD] = 86
	_physical_map[KEY_SEMICOLON] = 87
	_physical_map[KEY_SLASH] = 88


## 电脑键盘：用 physical_keycode（中文输入法/非 US 布局下也稳定）
func _unhandled_input(event: InputEvent) -> void:
	if not computer_keyboard_enabled:
		return
	if not (event is InputEventKey):
		return
	var ke := event as InputEventKey
	if ke.echo:
		return  # 长按重复事件忽略
	var midi: int = int(_physical_map.get(ke.physical_keycode, -1))
	if midi < 0:
		return  # 不是音符键：不消费，留给 HUD / 其他模块
	if ke.pressed and not ke.is_command_or_control_pressed():
		press_note(midi)
		get_viewport().set_input_as_handled()
	elif not ke.pressed:
		release_note(midi)
		get_viewport().set_input_as_handled()


func _exit_tree() -> void:
	# 退出时确保不留下悬挂的发声状态（只调引擎，不再发信号）
	for midi in _held.keys():
		PianoEngine.note_off(int(midi))
	_held.clear()
