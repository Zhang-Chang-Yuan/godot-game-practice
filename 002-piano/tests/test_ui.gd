extends Node
# UI 层测试：HUD 控制面板（hud.gd）+ 主装配接线（main.gd）
#
# 为什么单独一个场景：契约第 9 节的 tests/test_scene.tscn 只测 A–F 六个模块，
# **不加载 main.tscn**（所以 HUD 与 main 的接线不在它的覆盖范围内）。
# 本场景加载 main.tscn，验证「用户实际点的那些按钮」真的接通了底层功能。
#
# 运行：
#   godot --headless --path . res://tests/test_ui.tscn

const TIMEOUT_SEC := 30    # 看门狗超时：超过即判定"没跑到汇总行"并以失败退出

var _pass := 0
var _fail := 0
var _finished := false

var _main: Node = null
var _hud: Node = null
var _kb: Control = null
var _fit: CheckBox = null
var _scroll: ScrollContainer = null


func _ready() -> void:
	# 先起看门狗（独立协程，会立刻让出，不影响下面的流程）
	_start_watchdog()
	_main = load("res://scenes/main.tscn").instantiate()
	add_child(_main)
	await _run()
	_finish()


## 假绿 / 挂死兜底。
##
## 若某个测试函数漏写 await，协程会永久停在那个 await 处，_finish() 永远不会执行，
## 汇总行不会打印、进程会挂住。契约 §9.3 要求用 _finished 守卫，
## 但"置真后立刻检查"是空的——这里用独立协程做真正的超时兜底。
func _start_watchdog() -> void:
	var t0 := Time.get_ticks_msec()
	while not _finished:
		await get_tree().process_frame
		if Time.get_ticks_msec() - t0 > TIMEOUT_SEC * 1000:
			print("FAIL UI 测试超过 %d 秒仍未跑到汇总行 —— 很可能有测试函数漏写 await" % TIMEOUT_SEC)
			get_tree().quit(1)
			return


func _ck(cond: bool, label: String) -> void:
	if cond:
		_pass += 1
		print("PASS ", label)
	else:
		_fail += 1
		print("FAIL ", label)


func _eq(actual: Variant, expected: Variant, label: String) -> void:
	_ck(actual == expected, "%s | expected=%s actual=%s" % [label, str(expected), str(actual)])


func _spin(msec: int) -> void:
	# 必须自旋等真实时间：headless 首帧 delta 只走 0~2ms，create_timer 会 flaky
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < msec:
		await get_tree().process_frame


func _run() -> void:
	for i in 15:
		await get_tree().process_frame

	_hud = _main.get_node_or_null("Margin/Root/Hud")
	_kb = _main.get_node_or_null("Margin/Root/Scroll/KeyArea/Keyboard")
	_fit = _main.get_node_or_null("Margin/Root/TitleBar/FitToWidth")
	_scroll = _main.get_node_or_null("Margin/Root/Scroll")

	await _test_assembly()
	await _test_fit_to_width()
	await _test_highlight_wiring()
	await _test_esc_panic()
	await _test_hud_metronome()
	await _test_hud_sustain()
	await _test_hud_recorder()
	await _test_hud_volume_and_keys()


# ---------------------------------------------------------------- main.gd 装配

func _test_assembly() -> void:
	_ck(_hud != null, "main 装配出 HUD")
	_ck(_kb != null, "main 装配出 Keyboard")
	_ck(_fit != null and _scroll != null, "main 装配出 FitToWidth 与 Scroll")


func _test_fit_to_width() -> void:
	_ck(_fit.button_pressed, "「适应宽度」默认开启")
	var w_fit: float = _kb.white_key_width
	_ck(w_fit > 15.0 and w_fit < 30.0, "适应宽度下 white_key_width=%.2f（应约 24）" % w_fit)
	_ck(absf(_kb.custom_minimum_size.x - 52.0 * w_fit) < 0.5,
		"键盘最小宽度 == 52 * white_key_width")

	_fit.button_pressed = false
	await _spin(30)
	_ck(absf(_kb.white_key_width - 36.0) < 0.01,
		"关闭适应宽度 -> white_key_width=36（实际 %.2f）" % _kb.white_key_width)
	_ck(absf(_kb.custom_minimum_size.x - 1872.0) < 0.5,
		"键盘最小宽度 -> 1872（实际 %.1f）" % _kb.custom_minimum_size.x)
	_ck(_scroll.get_h_scroll_bar().max_value > 1800.0,
		"出现横向滚动范围（%.0f）" % _scroll.get_h_scroll_bar().max_value)

	_fit.button_pressed = true
	await _spin(30)
	_ck(absf(_kb.white_key_width - w_fit) < 0.5,
		"重新开启 -> 回到 %.2f" % w_fit)


func _test_highlight_wiring() -> void:
	var k60: Control = _kb.get_key(60)
	_ck(k60 != null and not k60.highlighted, "初始 C4 未高亮")
	PianoEngine.note_on(60, 1.0)
	await get_tree().process_frame
	_ck(k60.highlighted, "note_on(60) -> C4 被点亮（main.gd 接了 note_started）")
	PianoEngine.note_off(60)
	await get_tree().process_frame
	_ck(not k60.highlighted, "note_off(60) -> C4 熄灭")

	# 延音挂住的音要保持点亮
	PianoEngine.set_sustain(true)
	PianoEngine.note_on(64, 1.0)
	PianoEngine.note_on(67, 1.0)
	PianoEngine.note_off(64)
	await get_tree().process_frame
	_ck(_kb.get_key(64).highlighted, "延音挂住的 E4 仍点亮")
	_ck(_kb.get_key(67).highlighted, "仍在按的 G4 点亮")
	_ck(PianoEngine.sustained_note_count() >= 1, "sustained_note_count >= 1")


func _test_esc_panic() -> void:
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	_main._unhandled_input(esc)
	await get_tree().process_frame
	_eq(PianoEngine.active_voice_count(), 0, "Esc -> 所有音停止")
	_ck(not PianoEngine.sustain_enabled, "Esc -> 延音状态复位")
	_ck(not _kb.get_key(64).highlighted and not _kb.get_key(67).highlighted,
		"Esc -> 所有高亮被清除（无残留）")

	# 回归防线：all_notes_off() 必须补发 note_stopped，否则高亮会残留
	PianoEngine.note_on(72, 1.0)
	await get_tree().process_frame
	_ck(_kb.get_key(72).highlighted, "note_on(72) 点亮")
	PianoEngine.all_notes_off()
	await get_tree().process_frame
	_ck(not _kb.get_key(72).highlighted,
		"all_notes_off() -> 高亮清除（若引擎不补发 note_stopped 则残留，此为回归防线）")


# ---------------------------------------------------------------- HUD 控制面

func _test_hud_metronome() -> void:
	var btn: Button = _hud.find_child("MetronomeToggleButton", true, false)
	var minus: Button = _hud.find_child("BpmMinusButton", true, false)
	var plus: Button = _hud.find_child("BpmPlusButton", true, false)
	var slider: HSlider = _hud.find_child("BpmSlider", true, false)
	var beats: OptionButton = _hud.find_child("BeatsOptionButton", true, false)
	var tap: Button = _hud.find_child("TapTempoButton", true, false)

	_ck(btn != null and minus != null and plus != null and slider != null,
		"HUD 节拍器控件齐全")
	_ck(beats != null and tap != null, "HUD 拍号下拉与 Tap Tempo 齐全")
	if btn == null or beats == null:
		return

	# 回归防线（D3）：拍号标签必须与 README / 契约一致。
	# 曾经代码用 "%d/4" 生成出 "6/4"，而文档写 "6/8"——二者必有一错，靠这条钉住。
	var labels: Array[String] = []
	for i in beats.item_count:
		labels.append(beats.get_item_text(i))
	var want_labels: Array[String] = ["2/4", "3/4", "4/4", "6/8"]
	_ck(labels == want_labels,
		"拍号标签恰为 [2/4, 3/4, 4/4, 6/8]（实际 %s）" % str(labels))
	_ck(str([int(beats.get_item_metadata(0)), int(beats.get_item_metadata(1)),
			int(beats.get_item_metadata(2)), int(beats.get_item_metadata(3))]) == "[2, 3, 4, 6]",
		"拍号 metadata 恰为拍数 [2, 3, 4, 6]")

	Metronome.stop()
	btn.emit_signal("pressed")
	_ck(Metronome.is_running(), "点「节拍器」-> Metronome.is_running() 为真")
	btn.emit_signal("pressed")
	_ck(not Metronome.is_running(), "再点一次 -> 停止")

	Metronome.set_bpm(120.0)
	plus.emit_signal("pressed")
	_ck(absf(Metronome.bpm - 125.0) < 0.01, "BPM+ -> 125（实际 %s）" % Metronome.bpm)
	minus.emit_signal("pressed")
	_ck(absf(Metronome.bpm - 120.0) < 0.01, "BPM- -> 120（实际 %s）" % Metronome.bpm)

	slider.value = 200.0
	await get_tree().process_frame
	_ck(absf(Metronome.bpm - 200.0) < 0.01, "BPM 滑块=200 -> bpm=200（实际 %s）" % Metronome.bpm)

	if beats.item_count >= 2:
		beats.select(1)
		beats.emit_signal("item_selected", 1)
		await get_tree().process_frame
		var want := int(beats.get_item_metadata(1))
		_eq(Metronome.beats_per_bar, want, "拍号下拉第 2 项 -> beats_per_bar")

	# Tap Tempo：两次点击间隔约 500ms -> 约 120 BPM
	tap.emit_signal("pressed")
	await _spin(500)
	tap.emit_signal("pressed")
	await get_tree().process_frame
	_ck(Metronome.bpm > 100.0 and Metronome.bpm < 140.0,
		"Tap Tempo 两次点击间隔 500ms -> bpm 约 120（实际 %.2f）" % Metronome.bpm)
	Metronome.stop()


func _test_hud_sustain() -> void:
	var btn: Button = _hud.find_child("SustainToggleButton", true, false)
	var loop_check: CheckBox = _hud.find_child("SustainLoopCheckBox", true, false)
	_ck(btn != null and loop_check != null, "HUD 延音按钮与尾音循环勾选框齐全")
	if btn == null or loop_check == null:
		return

	PianoEngine.set_sustain(false)
	btn.button_pressed = true
	await get_tree().process_frame
	_ck(PianoEngine.sustain_enabled, "延音按钮打开 -> sustain_enabled 为真")
	btn.button_pressed = false
	await get_tree().process_frame
	_ck(not PianoEngine.sustain_enabled, "延音按钮关闭 -> sustain_enabled 为假")

	loop_check.button_pressed = true
	await get_tree().process_frame
	_ck(PianoEngine.sustain_loop_enabled, "尾音循环勾选 -> sustain_loop_enabled 为真")
	loop_check.button_pressed = false
	await get_tree().process_frame
	_ck(not PianoEngine.sustain_loop_enabled, "尾音循环取消 -> 为假")


func _test_hud_recorder() -> void:
	var rec: Button = _hud.find_child("RecordButton", true, false)
	var play: Button = _hud.find_child("PlaybackButton", true, false)
	var clear: Button = _hud.find_child("ClearButton", true, false)
	var save: Button = _hud.find_child("SaveButton", true, false)
	var load_btn: Button = _hud.find_child("LoadButton", true, false)
	_ck(rec != null and play != null and clear != null and save != null and load_btn != null,
		"HUD 录制组 5 个按钮齐全")
	if rec == null or play == null or clear == null or save == null or load_btn == null:
		return

	Recorder.clear()
	rec.emit_signal("pressed")
	await get_tree().process_frame
	_ck(Recorder.is_recording(), "点「录制」-> is_recording() 为真")

	PianoEngine.note_on(60, 1.0)
	await _spin(40)
	PianoEngine.note_off(60)
	rec.emit_signal("pressed")
	await get_tree().process_frame
	_ck(not Recorder.is_recording(), "再点「录制」-> 停止")
	_ck(Recorder.event_count() >= 2, "录制产生 >=2 条事件（实际 %d）" % Recorder.event_count())

	save.emit_signal("pressed")
	await get_tree().process_frame
	_ck(FileAccess.file_exists("user://recording.json"), "点「保存」-> user://recording.json 存在")

	var saved := Recorder.event_count()
	clear.emit_signal("pressed")
	await get_tree().process_frame
	_eq(Recorder.event_count(), 0, "点「清空」-> 事件清零")

	load_btn.emit_signal("pressed")
	await get_tree().process_frame
	_eq(Recorder.event_count(), saved, "点「载入」-> 事件恢复")

	play.emit_signal("pressed")
	await get_tree().process_frame
	_ck(Recorder.is_playing(), "点「回放」-> is_playing() 为真")
	play.emit_signal("pressed")
	await get_tree().process_frame
	_ck(not Recorder.is_playing(), "再点「回放」-> 停止")

	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://recording.json"))


func _test_hud_volume_and_keys() -> void:
	var vol: HSlider = _hud.find_child("VolumeSlider", true, false)
	var info: Label = _hud.find_child("RecordInfoLabel", true, false)
	var status: Label = _hud.find_child("StatusLabel", true, false)
	_ck(vol != null, "HUD 音量滑块存在")
	_ck(info != null and status != null, "HUD 事件信息标签与状态栏存在")
	if vol != null:
		vol.value = 40.0
		await get_tree().process_frame
		_ck(absf(PianoEngine.master_volume - 0.4) < 0.01,
			"音量滑块=40 -> master_volume=0.4（实际 %s）" % PianoEngine.master_volume)
		vol.value = 80.0
		await get_tree().process_frame

	# ---- 快捷键：Space 延音 ----
	PianoEngine.set_sustain(false)
	var space := InputEventKey.new()
	space.physical_keycode = KEY_SPACE
	space.pressed = true
	_hud._input(space)
	await get_tree().process_frame
	_ck(PianoEngine.sustain_enabled, "Space -> 延音开")
	_hud._input(space)
	await get_tree().process_frame
	_ck(not PianoEngine.sustain_enabled, "Space 再按 -> 延音关")

	# ---- Ctrl+R 录制；裸 R 必须放行给琴键（F5 = MIDI 77）----
	Recorder.stop_recording()
	var ctrl_r := InputEventKey.new()
	ctrl_r.physical_keycode = KEY_R
	ctrl_r.ctrl_pressed = true
	ctrl_r.pressed = true
	_hud._input(ctrl_r)
	await get_tree().process_frame
	_ck(Recorder.is_recording(), "Ctrl+R -> 开始录制")
	_hud._input(ctrl_r)
	await get_tree().process_frame
	_ck(not Recorder.is_recording(), "Ctrl+R 再按 -> 停止录制")

	var bare_r := InputEventKey.new()
	bare_r.physical_keycode = KEY_R
	bare_r.pressed = true
	_hud._input(bare_r)
	await get_tree().process_frame
	_ck(not Recorder.is_recording(),
		"裸 R 不触发录制（必须放行给琴键模块弹 F5，这是 _input 与 _unhandled_input 的共存约定）")

	PianoEngine.all_notes_off()
	Metronome.stop()
	Recorder.stop_playback()


# ---------------------------------------------------------------- 收尾

func _finish() -> void:
	_finished = true
	PianoEngine.all_notes_off()
	Metronome.stop()
	Recorder.stop_playback()
	print("UI_TESTS: %d/%d passed" % [_pass, _pass + _fail])
	# 只有确实执行到汇总行才允许退出码为 0（防"提前退出"伪装成全绿）
	get_tree().quit(0 if _fail == 0 else 1)
