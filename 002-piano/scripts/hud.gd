extends Control
# 顶栏 HUD 控制面板（002-piano）
# 契约：docs/INTERFACES.md 第 7 节。
# 全部控件由代码创建，不依赖任何手写 .tscn 子节点。
# 依赖 autoload：PianoEngine / Metronome / Recorder（并行开发中，缺失时降级不崩溃）。
#
# 快捷键：Space=延音踏板开关，Ctrl+R=录制/停止录制，Ctrl+P=回放/停止回放。
# 录制/回放必须带 Ctrl：裸 R 是琴键映射里的 F5（MIDI 77），裸 P 同理放行，绝不能抢占。
# 注意：绝不处理琴键映射用的字母与数字（Z S X D C V G B H N J M Q W E T Y U L / 2 3 5 6 7 / , . ; /）。

## 顶栏高度（契约建议 96~120）
const BAR_HEIGHT := 112.0
## 节拍指示灯的暗色（未闪烁时）
const TICK_DIM_COLOR := Color(0.22, 0.24, 0.30)
## 重音指示灯颜色（橙红）
const TICK_ACCENT_COLOR := Color(1.0, 0.45, 0.2)
## 弱拍指示灯颜色（青蓝）
const TICK_WEAK_COLOR := Color(0.35, 0.75, 1.0)
## 指示灯闪烁时长（秒）
const TICK_FLASH_SEC := 0.16
## Tap Tempo：两次点击超过该间隔则重新开始计数
const TAP_TIMEOUT_MSEC := 2000
## Tap Tempo 平均间隔的取样上限
const TAP_MAX_INTERVALS := 4
## 拍号选项（契约要求 2/4 3/4 4/4 6/8）
const TIME_SIGNATURES := [2, 3, 4, 6]
# 显示标签。6 拍的小节按惯例记作 6/8（与 README / 契约一致）。
# 注意这只是记谱习惯：本节的"拍"就是 BPM 所指的那一拍，代码不区分音符时值。
const TIME_SIGNATURE_LABELS := ["2/4", "3/4", "4/4", "6/8"]

# ---- autoload（弱类型引用，缺失时降级）----
var _engine: Node = null
var _metronome: Node = null
var _recorder: Node = null

# ---- 控件引用 ----
var _root_panel: PanelContainer
var _tick_indicator: ColorRect
var _metro_button: Button
var _bpm_label: Label
var _bpm_minus: Button
var _bpm_plus: Button
var _bpm_slider: HSlider
var _beats_option: OptionButton
var _tap_button: Button
var _sustain_button: Button
var _loop_check: CheckBox
var _record_button: Button
var _play_button: Button
var _clear_button: Button
var _save_button: Button
var _load_button: Button
var _rec_info_label: Label
var _volume_slider: HSlider
var _status_label: Label

# ---- 运行时状态 ----
var _tap_times: Array[int] = []          # Tap Tempo 各次点击的时间戳（毫秒）
var _tap_intervals: Array[float] = []    # 相邻点击间隔（毫秒）
var _tick_tween: Tween = null
var _bpm_slider_guard := false           # 防止程序化改 slider 触发回环
var _loop_check_guard := false           # 防止程序化改 CheckBox 触发回环
var _warned_methods: Dictionary = {}     # 已警告过的缺失方法，避免刷屏

# ---- 缓存（避免每帧写属性导致无谓重绘）----
var _cache_sustain_text := ""
var _cache_sustain_on := false
var _cache_metro_button_text := ""
var _cache_record_text := ""
var _cache_play_text := ""
var _cache_playing := false
var _cache_has_events := false
var _cache_rec_count := -1
var _cache_rec_duration := -1
var _cache_progress := -1
var _cache_progress_cached := -2
var _cache_bpm := -1
var _cache_voice_count := -1
var _cache_metro_running := false
var _cache_playing_cached := false
var _cache_tick_color := Color(-1, -1, -1, -1)


func _ready() -> void:
	# 顶部通栏：占满宽度，高度固定，不把自己撑满全屏（main.gd 负责放在顶部）
	set_anchors_preset(Control.PRESET_TOP_WIDE)
	custom_minimum_size = Vector2(0.0, BAR_HEIGHT)
	mouse_filter = Control.MOUSE_FILTER_PASS

	_engine = _find_autoload("PianoEngine")
	_metronome = _find_autoload("Metronome")
	_recorder = _find_autoload("Recorder")

	_build_ui()

	# 根节点是纯 Control，不会把子节点的高度计入自身最小尺寸；
	# 而 _root_panel 是 PanelContainer，会随内容长高。
	# 若不上抬根节点的最小高度，内容就会溢出外层 VBoxContainer 分配的高度，
	# 被下面的键盘区压住/裁掉（实测：延音分区第三行「延音踏板开关…」被切掉）。
	custom_minimum_size = Vector2(
		0.0,
		maxf(BAR_HEIGHT, _root_panel.get_combined_minimum_size().y)
	)

	_connect_signals()
	_sync_all()
	print("[hud] ready（控件由代码创建，高度 %dpx）" % int(custom_minimum_size.y))


# ============================================================
# autoload 防御式访问
# ============================================================

## 取 autoload 节点；不存在返回 null 并警告一次
func _find_autoload(autoload_name: String) -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	var node := tree.root.get_node_or_null(NodePath(autoload_name))
	if node == null:
		_warn_once("autoload:" + autoload_name, "缺少 autoload `%s`，HUD 对应功能降级" % autoload_name)
	return node


## 只在该方法存在时调用；不存在则警告一次并返回 null（核心路径不受影响）
func _call_if(obj: Object, method: StringName, args: Array = []) -> Variant:
	if obj == null:
		return null
	if not obj.has_method(method):
		_warn_once("method:%s" % String(method), "对象缺少方法 `%s()`，已跳过调用" % String(method))
		return null
	return obj.callv(method, args)


## 读属性（缺失时返回默认值）
func _get_prop(obj: Object, prop: StringName, fallback: Variant) -> Variant:
	if obj == null:
		return fallback
	var value: Variant = obj.get(prop)
	return fallback if value == null else value


func _warn_once(key: String, msg: String) -> void:
	if _warned_methods.has(key):
		return
	_warned_methods[key] = true
	push_warning("[hud] " + msg)


# ============================================================
# 构建 UI
# ============================================================

func _build_ui() -> void:
	_root_panel = PanelContainer.new()
	_root_panel.name = "HudPanel"
	_root_panel.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_root_panel.custom_minimum_size = Vector2(0.0, BAR_HEIGHT)
	_root_panel.add_theme_stylebox_override("panel", _make_panel_style())
	add_child(_root_panel)

	var margin := MarginContainer.new()
	margin.name = "HudMargin"
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	_root_panel.add_child(margin)

	# 分两行：控件行 + 状态行。
	# 5 个分区的最小宽度之和 > 1350px，而可用宽度只有 1256px，
	# 若全部挤在一行，最右侧的状态栏会被压成 0 宽而完全不可见（实测截图确认）。
	var stack := VBoxContainer.new()
	stack.name = "HudStack"
	stack.add_theme_constant_override("separation", 6)
	margin.add_child(stack)

	var row := HBoxContainer.new()
	row.name = "HudRow"
	row.add_theme_constant_override("separation", 10)
	stack.add_child(row)

	_build_metronome_section(row)
	row.add_child(_make_separator("SepMetronome"))
	_build_sustain_section(row)
	row.add_child(_make_separator("SepSustain"))
	_build_record_section(row)
	row.add_child(_make_separator("SepRecord"))
	_build_volume_section(row)

	_build_status_section(stack)


## 节拍器分区
func _build_metronome_section(row: HBoxContainer) -> void:
	var section := _make_section("MetronomeSection")
	var column: VBoxContainer = section.get_node("SectionColumn")

	var top := HBoxContainer.new()
	top.name = "MetronomeTopRow"
	top.add_theme_constant_override("separation", 6)
	column.add_child(top)

	_metro_button = _make_button("MetronomeToggleButton", "▶ 节拍器", 96.0)
	_metro_button.tooltip_text = "启动 / 停止节拍器"
	_metro_button.pressed.connect(_on_metronome_toggle_pressed)
	top.add_child(_metro_button)

	_bpm_label = _make_label("BpmLabel", "120 BPM", HORIZONTAL_ALIGNMENT_CENTER, 76.0)
	top.add_child(_bpm_label)

	_bpm_minus = _make_button("BpmMinusButton", "-", 32.0)
	_bpm_minus.tooltip_text = "BPM -5"
	_bpm_minus.pressed.connect(_on_bpm_minus_pressed)
	top.add_child(_bpm_minus)

	_bpm_plus = _make_button("BpmPlusButton", "+", 32.0)
	_bpm_plus.tooltip_text = "BPM +5"
	_bpm_plus.pressed.connect(_on_bpm_plus_pressed)
	top.add_child(_bpm_plus)

	_bpm_slider = HSlider.new()
	_bpm_slider.name = "BpmSlider"
	_bpm_slider.min_value = 20.0
	_bpm_slider.max_value = 300.0
	_bpm_slider.step = 1.0
	_bpm_slider.value = 120.0
	_bpm_slider.custom_minimum_size = Vector2(130.0, 24.0)
	_bpm_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_bpm_slider.tooltip_text = "BPM 20 ~ 300"
	_bpm_slider.value_changed.connect(_on_bpm_slider_changed)
	top.add_child(_bpm_slider)

	_beats_option = OptionButton.new()
	_beats_option.name = "BeatsOptionButton"
	_beats_option.custom_minimum_size = Vector2(76.0, 0.0)
	_beats_option.tooltip_text = "拍号"
	for i in TIME_SIGNATURES.size():
		_beats_option.add_item(TIME_SIGNATURE_LABELS[i])
		_beats_option.set_item_metadata(i, int(TIME_SIGNATURES[i]))
	_beats_option.item_selected.connect(_on_beats_option_selected)
	top.add_child(_beats_option)

	var bottom := HBoxContainer.new()
	bottom.name = "MetronomeBottomRow"
	bottom.add_theme_constant_override("separation", 6)
	column.add_child(bottom)

	_tick_indicator = ColorRect.new()
	_tick_indicator.name = "BeatIndicator"
	_tick_indicator.custom_minimum_size = Vector2(26.0, 22.0)
	_tick_indicator.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_tick_indicator.color = TICK_DIM_COLOR
	_tick_indicator.tooltip_text = "节拍指示灯（重音橙红 / 弱拍青蓝）"
	bottom.add_child(_tick_indicator)

	_tap_button = _make_button("TapTempoButton", "Tap Tempo", 96.0)
	_tap_button.tooltip_text = "连续点击取平均间隔换算 BPM（间隔 < 2 秒才计入）"
	_tap_button.pressed.connect(_on_tap_tempo_pressed)
	bottom.add_child(_tap_button)

	var hint := _make_label("MetronomeHintLabel", "重音橙红 / 弱拍青蓝", HORIZONTAL_ALIGNMENT_LEFT, 150.0)
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color(0.62, 0.66, 0.76))
	bottom.add_child(hint)

	row.add_child(section)


## 延音分区
func _build_sustain_section(row: HBoxContainer) -> void:
	var section := _make_section("SustainSection")
	var column: VBoxContainer = section.get_node("SectionColumn")

	_sustain_button = _make_button("SustainToggleButton", "延音 OFF", 108.0)
	_sustain_button.toggle_mode = true
	_sustain_button.tooltip_text = "延音踏板开关（快捷键：空格 / 鼠标右键）"
	_sustain_button.toggled.connect(_on_sustain_toggled)
	column.add_child(_sustain_button)

	_loop_check = CheckBox.new()
	_loop_check.name = "SustainLoopCheckBox"
	_loop_check.text = "延音尾音循环"
	_loop_check.button_pressed = false
	_loop_check.focus_mode = Control.FOCUS_NONE
	_loop_check.tooltip_text = "开启后延音时循环采样尾音（增强长延音）"
	_loop_check.toggled.connect(_on_sustain_loop_toggled)
	column.add_child(_loop_check)

	var hint := _make_label("SustainHintLabel", "空格 / 右键切换", HORIZONTAL_ALIGNMENT_LEFT, 108.0)
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color(0.62, 0.66, 0.76))
	column.add_child(hint)

	row.add_child(section)


## 录制分区
func _build_record_section(row: HBoxContainer) -> void:
	var section := _make_section("RecordSection")
	var column: VBoxContainer = section.get_node("SectionColumn")

	var buttons := HBoxContainer.new()
	buttons.name = "RecordButtonRow"
	buttons.add_theme_constant_override("separation", 6)
	column.add_child(buttons)

	_record_button = _make_button("RecordButton", "● 录制", 104.0)
	_record_button.tooltip_text = "开始 / 停止录制（快捷键：Ctrl+R）"
	_record_button.pressed.connect(_on_record_pressed)
	buttons.add_child(_record_button)

	_play_button = _make_button("PlaybackButton", "▶ 回放", 104.0)
	_play_button.tooltip_text = "开始 / 停止回放（快捷键：Ctrl+P）"
	_play_button.pressed.connect(_on_playback_pressed)
	buttons.add_child(_play_button)

	_clear_button = _make_button("ClearButton", "清空", 60.0)
	_clear_button.tooltip_text = "清空已录制事件"
	_clear_button.pressed.connect(_on_clear_pressed)
	buttons.add_child(_clear_button)

	_save_button = _make_button("SaveButton", "保存", 60.0)
	_save_button.tooltip_text = "保存到 user://recording.json"
	_save_button.pressed.connect(_on_save_pressed)
	buttons.add_child(_save_button)

	_load_button = _make_button("LoadButton", "载入", 60.0)
	_load_button.tooltip_text = "从 user://recording.json 载入"
	_load_button.pressed.connect(_on_load_pressed)
	buttons.add_child(_load_button)

	_rec_info_label = _make_label("RecordInfoLabel", "事件 0 · 00:00.000", HORIZONTAL_ALIGNMENT_LEFT, 172.0)
	column.add_child(_rec_info_label)

	row.add_child(section)


## 音量分区
func _build_volume_section(row: HBoxContainer) -> void:
	var section := _make_section("VolumeSection")
	var column: VBoxContainer = section.get_node("SectionColumn")

	var top := HBoxContainer.new()
	top.name = "VolumeTopRow"
	top.add_theme_constant_override("separation", 6)
	column.add_child(top)

	top.add_child(_make_label("VolumeLabel", "音量", HORIZONTAL_ALIGNMENT_LEFT, 40.0))

	_volume_slider = HSlider.new()
	_volume_slider.name = "VolumeSlider"
	_volume_slider.min_value = 0.0
	_volume_slider.max_value = 100.0
	_volume_slider.step = 1.0
	_volume_slider.value = 80.0
	_volume_slider.custom_minimum_size = Vector2(150.0, 24.0)
	_volume_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_volume_slider.tooltip_text = "总音量 0 ~ 100"
	_volume_slider.value_changed.connect(_on_volume_changed)
	top.add_child(_volume_slider)

	var hint := _make_label("VolumeHintLabel", "0 ~ 100", HORIZONTAL_ALIGNMENT_LEFT, 56.0)
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color(0.62, 0.66, 0.76))
	column.add_child(hint)

	row.add_child(section)


## 状态栏：独占一整行（放在控件行下方）
func _build_status_section(parent: VBoxContainer) -> void:
	var bar := HBoxContainer.new()
	bar.name = "StatusBar"

	_status_label = _make_label("StatusLabel", "声部 0 · 节拍器 停止 · 回放 —", HORIZONTAL_ALIGNMENT_LEFT, 0.0)
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(_status_label)

	parent.add_child(bar)


# ---- 小控件工厂 ----

## 分区骨架：Label(标题) + VSeparator + VBoxContainer（名为 SectionColumn）
func _make_section(section_name: String) -> VBoxContainer:
	var section := VBoxContainer.new()
	section.name = section_name
	section.add_theme_constant_override("separation", 6)

	var title := _make_label(section_name + "Title", section_name.trim_suffix("Section"), HORIZONTAL_ALIGNMENT_LEFT, 0.0)
	title.add_theme_font_size_override("font_size", 12)
	title.add_theme_color_override("font_color", Color(0.58, 0.66, 0.86))
	section.add_child(title)

	section.add_child(_make_separator(section_name + "InnerSep"))

	var column := VBoxContainer.new()
	column.name = "SectionColumn"
	column.add_theme_constant_override("separation", 4)
	section.add_child(column)

	return section


func _make_label(label_name: String, text: String, alignment: int, min_width: float) -> Label:
	var label := Label.new()
	label.name = label_name
	label.text = text
	label.horizontal_alignment = alignment
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if min_width > 0.0:
		label.custom_minimum_size = Vector2(min_width, 0.0)
	return label


func _make_button(button_name: String, text: String, min_width: float) -> Button:
	var button := Button.new()
	button.name = button_name
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(min_width, 30.0)
	return button


func _make_separator(separator_name: String) -> VSeparator:
	var separator := VSeparator.new()
	separator.name = separator_name
	separator.custom_minimum_size = Vector2(2.0, 0.0)
	return separator


func _make_panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.13, 0.14, 0.18, 0.96)
	style.border_color = Color(0.28, 0.32, 0.42, 0.9)
	style.set_border_width_all(1)
	style.corner_radius_bottom_left = 6
	style.corner_radius_bottom_right = 6
	return style


func _make_sustain_on_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(1.0, 0.55, 0.22, 0.9)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	return style


# ============================================================
# 信号连接
# ============================================================

func _connect_signals() -> void:
	if _metronome != null:
		if _metronome.has_signal("tick"):
			_metronome.connect("tick", _on_metronome_tick)
		else:
			_warn_once("signal:tick", "Metronome 缺少信号 `tick`，节拍指示灯不闪烁")
		if _metronome.has_signal("started"):
			_metronome.connect("started", _on_metronome_started)
		if _metronome.has_signal("stopped"):
			_metronome.connect("stopped", _on_metronome_stopped)
	if _recorder != null:
		if _recorder.has_signal("playback_progress"):
			_recorder.connect("playback_progress", _on_playback_progress)
		else:
			_warn_once("signal:playback_progress", "Recorder 缺少信号 `playback_progress`，回放进度不可见")
		if _recorder.has_signal("recording_stopped"):
			_recorder.connect("recording_stopped", _on_recording_stopped)
		if _recorder.has_signal("playback_finished"):
			_recorder.connect("playback_finished", _on_playback_finished)


func _exit_tree() -> void:
	# 对称断开，避免自动加载单例残留对已释放节点的连接
	if _metronome != null:
		if _metronome.has_signal("tick") and _metronome.is_connected("tick", _on_metronome_tick):
			_metronome.disconnect("tick", _on_metronome_tick)
		if _metronome.has_signal("started") and _metronome.is_connected("started", _on_metronome_started):
			_metronome.disconnect("started", _on_metronome_started)
		if _metronome.has_signal("stopped") and _metronome.is_connected("stopped", _on_metronome_stopped):
			_metronome.disconnect("stopped", _on_metronome_stopped)
	if _recorder != null:
		if _recorder.has_signal("playback_progress") and _recorder.is_connected("playback_progress", _on_playback_progress):
			_recorder.disconnect("playback_progress", _on_playback_progress)
		if _recorder.has_signal("recording_stopped") and _recorder.is_connected("recording_stopped", _on_recording_stopped):
			_recorder.disconnect("recording_stopped", _on_recording_stopped)
		if _recorder.has_signal("playback_finished") and _recorder.is_connected("playback_finished", _on_playback_finished):
			_recorder.disconnect("playback_finished", _on_playback_finished)


# ============================================================
# 初始同步
# ============================================================

func _sync_all() -> void:
	# 音量：初始值取 PianoEngine.master_volume * 100
	var master: float = float(_get_prop(_engine, &"master_volume", 0.8))
	_set_if_changed(_volume_slider, &"value", clampf(master * 100.0, 0.0, 100.0))

	# BPM
	var bpm: float = float(_get_prop(_metronome, &"bpm", 120.0))
	_apply_bpm(bpm)

	# 拍号
	var beats: int = int(_get_prop(_metronome, &"beats_per_bar", 4))
	var index := TIME_SIGNATURES.find(beats)
	if index >= 0:
		_set_if_changed(_beats_option, &"selected", index)

	# 延音尾音循环
	_loop_check_guard = true
	_set_if_changed(_loop_check, &"button_pressed", bool(_get_prop(_engine, &"sustain_loop_enabled", false)))
	_loop_check_guard = false

	_sync_sustain_button()
	_sync_status()
	_sync_record_buttons()
	_sync_record_info()


# ============================================================
# 每帧同步（全部走缓存比较，避免无谓重绘）
# ============================================================

func _process(_delta: float) -> void:
	_sync_status()
	_sync_metronome_button()
	_sync_sustain_button()
	_sync_record_buttons()
	_sync_record_info()


## 状态栏：活跃声部数 / 节拍器状态 / 回放进度
func _sync_status() -> void:
	var voices := 0
	if _engine != null and _engine.has_method(&"active_voice_count"):
		voices = int(_engine.call(&"active_voice_count"))
	var running := false
	if _metronome != null and _metronome.has_method(&"is_running"):
		running = bool(_metronome.call(&"is_running"))

	# 四项都未变则直接跳过，避免每帧拼字符串
	if voices == _cache_voice_count and running == _cache_metro_running \
			and _cache_playing == _cache_playing_cached and _cache_progress == _cache_progress_cached:
		return
	_cache_voice_count = voices
	_cache_metro_running = running
	_cache_playing_cached = _cache_playing
	_cache_progress_cached = _cache_progress

	var progress := "—"
	if _cache_playing:
		progress = _format_msec(maxi(_cache_progress, 0))

	var text := "声部 %d · 节拍器 %s · 回放 %s" % [voices, "运行中" if running else "停止", progress]
	_set_if_changed(_status_label, &"text", text)


## 节拍器按钮文案跟随 is_running()
func _sync_metronome_button() -> void:
	var running := false
	if _metronome != null and _metronome.has_method(&"is_running"):
		running = bool(_metronome.call(&"is_running"))
	var text := "■ 节拍器" if running else "▶ 节拍器"
	if text != _cache_metro_button_text:
		_cache_metro_button_text = text
		_metro_button.text = text


## 延音按钮：文案与高亮跟随 PianoEngine.sustain_enabled
func _sync_sustain_button() -> void:
	var on: bool = bool(_get_prop(_engine, &"sustain_enabled", false))
	if on != _cache_sustain_on:
		_cache_sustain_on = on

		var text := "延音 ON" if on else "延音 OFF"
		if text != _cache_sustain_text:
			_cache_sustain_text = text
			_sustain_button.text = text

		if on:
			_sustain_button.add_theme_stylebox_override("normal", _make_sustain_on_style())
			_sustain_button.modulate = Color(1.0, 0.92, 0.78)
		else:
			_sustain_button.remove_theme_stylebox_override("normal")
			_sustain_button.modulate = Color.WHITE

	# 防御：任何外部途径（键盘/右键/引擎自身）改动状态后，按钮按下态都要跟上
	_set_if_changed(_sustain_button, &"button_pressed", on)


## 录制/回放按钮：文案 + 禁用状态跟随 is_recording() / is_playing()
func _sync_record_buttons() -> void:
	var recording := false
	var playing := false
	if _recorder != null:
		if _recorder.has_method(&"is_recording"):
			recording = bool(_recorder.call(&"is_recording"))
		if _recorder.has_method(&"is_playing"):
			playing = bool(_recorder.call(&"is_playing"))

	_cache_playing = playing

	var record_text := "■ 停止录制" if recording else "● 录制"
	if record_text != _cache_record_text:
		_cache_record_text = record_text
		_record_button.text = record_text

	var play_text := "⏹ 停止回放" if playing else "▶ 回放"
	if play_text != _cache_play_text:
		_cache_play_text = play_text
		_play_button.text = play_text

	var has_events := false
	if _recorder != null and _recorder.has_method(&"event_count"):
		has_events = int(_recorder.call(&"event_count")) > 0
	_cache_has_events = has_events

	_set_if_changed(_record_button, &"disabled", playing)      # 回放中禁止录制
	_set_if_changed(_play_button, &"disabled", recording)      # 录制中禁止回放
	_set_if_changed(_clear_button, &"disabled", not has_events and not recording)
	_set_if_changed(_save_button, &"disabled", not has_events)
	_set_if_changed(_load_button, &"disabled", recording or playing)


## 录制信息：事件数 + 时长（mm:ss.mmm）
func _sync_record_info() -> void:
	var count := 0
	var duration := 0
	if _recorder != null:
		if _recorder.has_method(&"event_count"):
			count = int(_recorder.call(&"event_count"))
		if _recorder.has_method(&"duration_msec"):
			duration = int(_recorder.call(&"duration_msec"))

	# 两者都未变则跳过格式化
	if count == _cache_rec_count and duration == _cache_rec_duration:
		return
	_cache_rec_count = count
	_cache_rec_duration = duration

	var text := "事件 %d · %s" % [count, _format_msec(duration)]
	_set_if_changed(_rec_info_label, &"text", text)


## 只有值变化时才写属性（避免每帧重绘）
func _set_if_changed(obj: Object, prop: StringName, value: Variant) -> void:
	if obj == null:
		return
	if obj.get(prop) == value:
		return
	obj.set(prop, value)


## 毫秒 -> "mm:ss.mmm"
func _format_msec(msec: int) -> String:
	var value := maxi(msec, 0)
	var minutes := value / 60000
	var seconds := (value / 1000) % 60
	var millis := value % 1000
	return "%02d:%02d.%03d" % [minutes, seconds, millis]


# ============================================================
# 节拍器
# ============================================================

func _apply_bpm(value: float) -> void:
	var bpm := clampf(value, 20.0, 300.0)
	_call_if(_metronome, &"set_bpm", [bpm])

	_bpm_slider_guard = true
	_set_if_changed(_bpm_slider, &"value", bpm)
	_bpm_slider_guard = false

	var shown := int(round(bpm))
	if shown != _cache_bpm:
		_cache_bpm = shown
		_bpm_label.text = "%d BPM" % shown


func _on_bpm_slider_changed(value: float) -> void:
	if _bpm_slider_guard:
		return
	_apply_bpm(value)


func _on_bpm_minus_pressed() -> void:
	_apply_bpm(float(_get_prop(_metronome, &"bpm", 120.0)) - 5.0)


func _on_bpm_plus_pressed() -> void:
	_apply_bpm(float(_get_prop(_metronome, &"bpm", 120.0)) + 5.0)


func _on_beats_option_selected(index: int) -> void:
	var beats: int = int(_beats_option.get_item_metadata(index))
	_call_if(_metronome, &"set_beats_per_bar", [beats])


func _on_metronome_toggle_pressed() -> void:
	_call_if(_metronome, &"toggle")
	_sync_metronome_button()


func _on_metronome_started() -> void:
	_sync_metronome_button()


func _on_metronome_stopped() -> void:
	_sync_metronome_button()


## Tap Tempo：连续点击取平均间隔换算 BPM
func _on_tap_tempo_pressed() -> void:
	var now := Time.get_ticks_msec()
	if _tap_times.is_empty():
		_tap_times.append(now)
		_tap_intervals.clear()
		_tap_button.text = "再点 1 次"
		return

	var gap := float(now - _tap_times[_tap_times.size() - 1])
	if gap <= 0.0 or gap > float(TAP_TIMEOUT_MSEC):
		# 间隔超时（>= 2 秒）或异常，重新开始计数
		_tap_times.clear()
		_tap_intervals.clear()
		_tap_times.append(now)
		_tap_button.text = "再点 1 次"
		return

	_tap_times.append(now)
	_tap_intervals.append(gap)
	while _tap_intervals.size() > TAP_MAX_INTERVALS:
		_tap_intervals.remove_at(0)

	# 至少 2 次点击（即至少 1 个间隔）后才改 BPM
	if _tap_intervals.size() >= 1:
		var total := 0.0
		for interval in _tap_intervals:
			total += interval
		var average := total / float(_tap_intervals.size())
		if average > 0.0:
			_apply_bpm(60000.0 / average)
		_tap_button.text = "Tap Tempo"


func _on_metronome_tick(beat_index: int, is_accent: bool) -> void:
	var running := true
	if _metronome != null and _metronome.has_method(&"is_running"):
		running = bool(_metronome.call(&"is_running"))
	if not running:
		return
	_flash_beat_indicator(is_accent)


## 每拍闪一下：重音橙红、弱拍青蓝，随后衰减回暗色
func _flash_beat_indicator(is_accent: bool) -> void:
	var color := TICK_ACCENT_COLOR if is_accent else TICK_WEAK_COLOR
	if color != _cache_tick_color:
		_cache_tick_color = color
		_tick_indicator.color = color

	if _tick_tween != null and _tick_tween.is_valid():
		_tick_tween.kill()
	_tick_indicator.modulate = Color.WHITE
	_tick_tween = create_tween()
	_tick_tween.tween_property(_tick_indicator, "modulate", Color(0.32, 0.32, 0.32), TICK_FLASH_SEC)


# ============================================================
# 延音
# ============================================================

func _toggle_sustain() -> void:
	if _engine == null or not _engine.has_method(&"set_sustain"):
		_warn_once("method:set_sustain", "PianoEngine 缺少 `set_sustain()`，延音开关不可用")
		return
	_engine.call(&"set_sustain", not bool(_get_prop(_engine, &"sustain_enabled", false)))
	_sync_sustain_button()


func _on_sustain_toggled(pressed: bool) -> void:
	_call_if(_engine, &"set_sustain", [pressed])
	_sync_sustain_button()


func _on_sustain_loop_toggled(pressed: bool) -> void:
	if _loop_check_guard:
		return
	if _engine == null:
		return
	_engine.set(&"sustain_loop_enabled", pressed)


# ============================================================
# 录制 / 回放
# ============================================================

func _toggle_recording() -> void:
	if _recorder == null:
		_warn_once("autoload:Recorder", "Recorder 不可用，录制开关无效")
		return
	var recording := false
	if _recorder.has_method(&"is_recording"):
		recording = bool(_recorder.call(&"is_recording"))
	if recording:
		_call_if(_recorder, &"stop_recording")
	else:
		_call_if(_recorder, &"start_recording")
	_sync_record_buttons()


func _toggle_playback() -> void:
	if _recorder == null:
		_warn_once("autoload:Recorder", "Recorder 不可用，回放开关无效")
		return
	var playing := false
	if _recorder.has_method(&"is_playing"):
		playing = bool(_recorder.call(&"is_playing"))
	if playing:
		_call_if(_recorder, &"stop_playback")
		_cache_progress = 0
	else:
		_cache_progress = 0
		_call_if(_recorder, &"start_playback")
	_sync_record_buttons()


func _on_record_pressed() -> void:
	_toggle_recording()


func _on_playback_pressed() -> void:
	_toggle_playback()


func _on_clear_pressed() -> void:
	_call_if(_recorder, &"clear")
	_cache_progress = 0
	_sync_record_info()
	_sync_record_buttons()


func _on_save_pressed() -> void:
	var result: Variant = _call_if(_recorder, &"save_to_file")
	if result is int:
		print("[hud] 保存录制：%s" % ("成功" if int(result) == OK else "失败（Error %d）" % int(result)))


func _on_load_pressed() -> void:
	var result: Variant = _call_if(_recorder, &"load_from_file")
	if result is int:
		print("[hud] 载入录制：%s" % ("成功" if int(result) == OK else "失败（Error %d）" % int(result)))
	_sync_record_info()
	_sync_record_buttons()


func _on_recording_stopped(_event_count: int) -> void:
	_sync_record_info()
	_sync_record_buttons()


func _on_playback_finished() -> void:
	_cache_progress = 0
	_sync_record_buttons()
	_sync_status()


func _on_playback_progress(msec: int) -> void:
	if msec == _cache_progress:
		return
	_cache_progress = msec
	_sync_status()


# ============================================================
# 音量
# ============================================================

func _on_volume_changed(value: float) -> void:
	_call_if(_engine, &"set_master_volume", [clampf(value / 100.0, 0.0, 1.0)])


# ============================================================
# 输入：只处理 Space / Ctrl+R / Ctrl+P 与鼠标右键，其余一律放行给键盘模块
# ============================================================

func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if not key_event.pressed or key_event.echo:
			return
		# 用 physical_keycode 而非 keycode：与 keyboard.gd 的音符映射保持同一判定基准，
		# 中文输入法 / 非 US 布局下不会因为字符差异而失灵。
		match key_event.physical_keycode:
			KEY_SPACE:
				_toggle_sustain()
				get_viewport().set_input_as_handled()
			KEY_R:
				# 必须带 Ctrl：裸 R 是 keyboard.gd 的 F5（MIDI 77）音符映射，不得抢占
				if key_event.is_command_or_control_pressed():
					_toggle_recording()
					get_viewport().set_input_as_handled()
			KEY_P:
				# 必须带 Ctrl：裸 P 同理放行给键盘模块
				if key_event.is_command_or_control_pressed():
					_toggle_playback()
					get_viewport().set_input_as_handled()
		return

	# 鼠标右键：延音踏板开关（契约第 7 节）
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.pressed and mouse_event.button_index == MOUSE_BUTTON_RIGHT:
			if visible and get_global_rect().has_point(mouse_event.position):
				_toggle_sustain()
				get_viewport().set_input_as_handled()
