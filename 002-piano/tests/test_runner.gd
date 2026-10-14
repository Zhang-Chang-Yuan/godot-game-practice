extends Node
## headless 自动化测试驱动（002-piano）。
## 挂载场景：tests/test_scene.tscn，运行方式见 docs/INTERFACES.md 第 9 节：
##   godot --headless --path . res://tests/test_scene.tscn
##
## 本文件只测试公开契约（第 2~7 节），不修改任何被测模块。
## 两条硬纪律：
##   1. Godot 的退出码不可靠（SCRIPT ERROR 时仍返回 0），所以失败必须自己 get_tree().quit(1)；
##      同时 PowerShell 侧还要 grep 输出里的 "SCRIPT ERROR" / "ERROR:"（见第 9.2 节）。
##   2. 需要"真实时间间隔"的断言一律自旋等待 Time.get_ticks_msec()，
##      绝不用 create_timer —— headless 首帧的 create_timer(0.05) 只走 0~2ms 真实时间（实测）。
##
## 注意：--check-only 对引用 autoload 的脚本是假阴性（第 9.1 节），验证唯一标准是真实运行本场景。

const KeyboardScript := preload("res://scripts/keyboard.gd")

const TEST_GOOD_PATH := "user://test_rec.json"
const TEST_BAD_PATH := "user://test_bad.json"
const TEST_ARRAY_PATH := "user://test_bad_array.json"

const LOG_PATH := "user://test_runner.log"

const TIMEOUT_SEC := 30    # 看门狗超时：超过即判定"没跑到汇总行"并以失败退出

var _pass := 0
var _fail := 0
var _total := 0
var _fail_lines: Array[String] = []
var _log: FileAccess = null
var _finished := false     # 是否真的跑到了汇总行


## 双写：stdout（契约第 9 节要求全部打印）+ user://test_runner.log。
## 之所以要写文件：Godot 的 stdout 与 stderr 在管道里交错、且 quit() 后可能丢尾部，
## 文件是"这一次运行到底跑了哪些断言"的确定性证据。
func _say(line: String) -> void:
	print(line)
	if _log != null:
		_log.store_line(line)
		_log.flush()


## 假绿 / 挂死兜底。
##
## 若某个测试函数漏写 await，_ready() 会永久停在那个 await 处，
## 汇总行与 quit() 都不会执行 —— 进程挂死，或被误判成"全绿"。
## 注意：`if _fail > 0 or not _finished` 那种写法是**空的**（_finished 在上一行才置真），
## 所以这里用独立协程做真正的超时兜底。
func _start_watchdog() -> void:
	var t0 := Time.get_ticks_msec()
	while not _finished:
		await get_tree().process_frame
		if Time.get_ticks_msec() - t0 > TIMEOUT_SEC * 1000:
			print("FAIL 测试超过 %d 秒仍未跑到汇总行 —— 很可能有测试函数漏写 await，协程停在 await 处" % TIMEOUT_SEC)
			if _log != null:
				_log.store_line("FAIL TIMEOUT after %d s" % TIMEOUT_SEC)
				_log.close()
				_log = null
			get_tree().quit(1)
			return


func _ready() -> void:
	# 先起看门狗（它是独立协程，会立刻让出，不影响下面的流程）
	_start_watchdog()
	_log = FileAccess.open(LOG_PATH, FileAccess.WRITE)

	# autoload 在场景加载前已就绪；等一帧让 _ready 链全部走完。
	await get_tree().process_frame

	_say("=== 002-piano headless test suite ===")
	_say("Godot: %s" % Engine.get_version_info().get("string", "?"))
	_say("PianoEngine.POLYPHONY=%d  Metronome bpm=%s  Recorder events=%d" % [
		PianoEngine.POLYPHONY, str(Metronome.bpm), Recorder.event_count(),
	])

	# 音频存在性放最前面：note_on 在采样缺失时会提前 return 且不发 note_started，
	# 后续所有发声相关断言都会连带失败（契约第 3 节 + 任务说明第 7 条）。
	#
	# 【实测陷阱 · 必须 await 每个测试函数】
	# 若只写 _test_xxx() 而不 await，那些协程会永久停在第一个 await 处：
	# _ready() 正常返回后本次运行立即结束（退出码 0、无任何报错、无 SCRIPT ERROR），
	# 于是这些测试既不打印也不计入总数 —— 表面"全绿"，实际根本没跑。
	# 隔离探针实测：同一结构里所有 await 全部停在第一次让出，进程 0.3s 退出码 0；
	# 改成 await 每个函数后全部恢复，总耗时 1.42s。
	# 因此这里必须逐个 await，让 _ready() 全程保持挂起，main loop 才会继续推进帧。
	await _test_audio_resources()
	await _test_music_theory()
	await _test_piano_engine()
	await _test_keyboard()
	await _test_recorder()
	await _test_metronome()

	_cleanup()

	_say("")
	_say("TESTS: %d/%d passed" % [_pass, _total])
	if _fail > 0:
		_say("FAILURES: %d" % _fail)
		for line in _fail_lines:
			_say("  FAIL %s" % line)
	else:
		_say("ALL PASS")
	_finished = true
	if _log != null:
		_log.close()
		_log = null

	# 退出码只允许在"确实跑到汇总行"时才为 0。
	# 否则一旦运行被提前截断（例如测试协程卡在 await 上根本没跑），
	# 进程会以 0 退出并看起来"全绿" —— 这正是契约第 9.2 节说的陷阱。
	# 注意：真正的兜底是 PowerShell 侧必须 grep "TESTS:" 是否存在，
	# 不能只看退出码；这里只是让驱动侧多一道自检。
	if _fail > 0 or not _finished:
		get_tree().quit(1)
	else:
		get_tree().quit(0)


# ============================================================
# 断言原语
# ============================================================

func _check(cond: bool, label: String) -> void:
	_total += 1
	if cond:
		_pass += 1
		_say("PASS %s" % label)
	else:
		_fail += 1
		_fail_lines.append(label)
		_say("FAIL %s" % label)


## 相等断言：失败时打印期望值与实际值，便于定位
func _eq(actual: Variant, expected: Variant, label: String) -> void:
	_total += 1
	# 用 == 比较：Variant 的 == 对 null / 对象 / 数值都按值语义工作
	if actual == expected:
		_pass += 1
		_say("PASS %s" % label)
	else:
		_fail += 1
		var msg := "%s | expected=%s actual=%s" % [label, str(expected), str(actual)]
		_fail_lines.append(msg)
		_say("FAIL %s" % msg)


## 自旋等待真实毫秒。headless 首帧附近 create_timer 不可用（首帧 delta 含引擎启动耗时）。
func _spin_wait(msec: int) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < msec:
		await get_tree().process_frame


## 清空引擎状态，避免上一个用例污染下一个
func _reset_engine() -> void:
	PianoEngine.all_notes_off()
	PianoEngine.set_sustain(false)


func _cleanup() -> void:
	Recorder.stop_playback()
	if Recorder.is_recording():
		Recorder.stop_recording()
	Metronome.stop()
	PianoEngine.all_notes_off()
	PianoEngine.set_sustain(false)
	for path in [TEST_GOOD_PATH, TEST_BAD_PATH, TEST_ARRAY_PATH]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
			_say("cleaned: %s" % path)


# ============================================================
# B. 音频资源（契约第 2/3 节）
# ============================================================

func _test_audio_resources() -> void:
	_say("")
	_say("--- B. 音频资源 ---")

	var missing: Array[int] = []
	for midi in range(MusicTheory.MIDI_LOWEST, MusicTheory.MIDI_HIGHEST + 1):
		if not ResourceLoader.exists(MusicTheory.sample_path(midi)):
			missing.append(midi)
	_eq(missing.size(), 0, "B.88 个 MusicTheory.sample_path() 全部 ResourceLoader.exists()（缺失=%s）" % str(missing))

	var null_streams: Array[int] = []
	var not_audio: Array[int] = []
	for midi in range(MusicTheory.MIDI_LOWEST, MusicTheory.MIDI_HIGHEST + 1):
		var s := PianoEngine.get_stream(midi)
		if s == null:
			null_streams.append(midi)
		elif not (s is AudioStream):
			not_audio.append(midi)
	_eq(null_streams.size(), 0, "B.88 个 get_stream() 全部非 null（null=%s）" % str(null_streams))
	_eq(not_audio.size(), 0, "B.88 个 get_stream() 全部 is AudioStream（非音频=%s）" % str(not_audio))

	# 抽查缓存：同一对象（is_same 是引用比较，== 对 Resource 也是引用比较，用 is_same 更明确）
	_check(PianoEngine.get_stream(60) != null and is_same(PianoEngine.get_stream(60), PianoEngine.get_stream(60)),
		"B.get_stream(60) 命中缓存（同对象）")
	_check(is_same(PianoEngine.get_stream(21), PianoEngine.get_stream(21)),
		"B.get_stream(21) 命中缓存（同对象）")
	_check(is_same(PianoEngine.get_stream(108), PianoEngine.get_stream(108)),
		"B.get_stream(108) 命中缓存（同对象）")
	_check(PianoEngine.get_stream(20) == null and PianoEngine.get_stream(109) == null,
		"B.get_stream() 对越界 midi 返回 null")

	var p60 := MusicTheory.sample_path(60)
	_eq(p60, "res://audio/piano/C4.mp3", "B.sample_path(60)")
	_eq(MusicTheory.sample_path(22), "res://audio/piano/As0.mp3", "B.sample_path(22) 用 s 代替 #")


# ============================================================
# A. MusicTheory（契约第 2 节）
# ============================================================

func _test_music_theory() -> void:
	_say("")
	_say("--- A. MusicTheory ---")

	var bad_roundtrip: Array[int] = []
	var bad_filename: Array[int] = []
	for midi in range(MusicTheory.MIDI_LOWEST, MusicTheory.MIDI_HIGHEST + 1):
		if MusicTheory.name_to_midi(MusicTheory.midi_to_name(midi)) != midi:
			bad_roundtrip.append(midi)
		if MusicTheory.midi_to_filename(midi).contains("#"):
			bad_filename.append(midi)
	_eq(bad_roundtrip.size(), 0, "A.88 个音名往返 name_to_midi(midi_to_name(m)) == m（失败=%s）" % str(bad_roundtrip))
	_eq(bad_filename.size(), 0, "A.midi_to_filename 全部不含 '#'（含 # 的=%s）" % str(bad_filename))

	# 边界
	_eq(MusicTheory.midi_to_name(21), "A0", "A.midi_to_name(21) == \"A0\"")
	_eq(MusicTheory.midi_to_name(108), "C8", "A.midi_to_name(108) == \"C8\"")
	_eq(MusicTheory.midi_to_name(60), "C4", "A.midi_to_name(60) == \"C4\"")
	_eq(MusicTheory.midi_to_name(22), "A#0", "A.midi_to_name(22) == \"A#0\"")
	_eq(MusicTheory.midi_to_filename(22), "As0", "A.midi_to_filename(22) == \"As0\"")
	_eq(MusicTheory.name_to_midi("A0"), 21, "A.name_to_midi(\"A0\") == 21")
	_eq(MusicTheory.name_to_midi("C8"), 108, "A.name_to_midi(\"C8\") == 108")
	_eq(MusicTheory.name_to_midi("C4"), 60, "A.name_to_midi(\"C4\") == 60")
	_eq(MusicTheory.name_to_midi("A#0"), 22, "A.name_to_midi(\"A#0\") == 22")
	_eq(MusicTheory.name_to_midi("As0"), 22, "A.name_to_midi(\"As0\") == 22")

	# 黑键判定：C D E F G A B 为白键，其余为黑键
	var expected_black: Array[int] = [1, 3, 6, 8, 10]
	for pc in 12:
		var midi := 60 + pc
		var want: bool = expected_black.has(pc)
		if MusicTheory.is_black_key(midi) != want:
			_check(false, "A.is_black_key(%d) 期望 %s" % [midi, str(want)])
	_check(MusicTheory.is_black_key(61) and not MusicTheory.is_black_key(60)
		and MusicTheory.is_black_key(22) and not MusicTheory.is_black_key(21),
		"A.is_black_key 采样点（61/22 黑，60/21 白）")

	# 白键总数 52
	_eq(MusicTheory.white_key_count(), 52, "A.white_key_count() == 52")
	_eq(MusicTheory.KEY_COUNT, 88, "A.KEY_COUNT == 88")
	_eq(MusicTheory.MIDI_HIGHEST - MusicTheory.MIDI_LOWEST + 1, 88, "A.MIDI_HIGHEST-MIDI_LOWEST+1 == 88")
	var white := 0
	var black := 0
	for midi in range(MusicTheory.MIDI_LOWEST, MusicTheory.MIDI_HIGHEST + 1):
		if MusicTheory.is_black_key(midi):
			black += 1
		else:
			white += 1
	_eq(white, 52, "A.21..108 实际数出 52 个白键")
	_eq(black, 36, "A.21..108 实际数出 36 个黑键")

	# white_index_of：黑键 -1，白键按下标递增
	_eq(MusicTheory.white_index_of(22), -1, "A.white_index_of(22) 黑键返回 -1")
	_eq(MusicTheory.white_index_of(61), -1, "A.white_index_of(61) 黑键返回 -1")
	_eq(MusicTheory.white_index_of(21), 0, "A.white_index_of(21) == 0")
	_eq(MusicTheory.white_index_of(108), 51, "A.white_index_of(108) == 51")
	var wseq: Array[int] = []
	for midi in range(MusicTheory.MIDI_LOWEST, MusicTheory.MIDI_HIGHEST + 1):
		if not MusicTheory.is_black_key(midi):
			wseq.append(MusicTheory.white_index_of(midi))
	var want_seq: Array[int] = []
	for i in 52:
		want_seq.append(i)
	_eq(str(wseq), str(want_seq), "A.白键 white_index_of 恰好覆盖 0..51 且无重复")

	# octave / pitch_class / is_valid_midi
	_eq(MusicTheory.octave_of(21), 0, "A.octave_of(21) == 0")
	_eq(MusicTheory.octave_of(60), 4, "A.octave_of(60) == 4")
	_eq(MusicTheory.octave_of(108), 8, "A.octave_of(108) == 8")
	_eq(MusicTheory.pitch_class(60), 0, "A.pitch_class(60) == 0")
	_eq(MusicTheory.pitch_class(61), 1, "A.pitch_class(61) == 1")
	_eq(MusicTheory.pitch_class(71), 11, "A.pitch_class(71) == 11")
	_check(MusicTheory.is_valid_midi(21) and MusicTheory.is_valid_midi(108)
		and not MusicTheory.is_valid_midi(20) and not MusicTheory.is_valid_midi(109),
		"A.is_valid_midi 边界 21/108 真，20/109 假")


# ============================================================
# C. PianoEngine（契约第 3 节）
# ============================================================

func _test_piano_engine() -> void:
	_say("")
	_say("--- C. PianoEngine ---")

	_reset_engine()

	# 声部池
	var voice_nodes := 0
	for child in PianoEngine.get_children():
		if child is AudioStreamPlayer:
			voice_nodes += 1
	# ⚠️ 必须用字面量 32，不能用 PianoEngine.POLYPHONY：
	# 拿常量比常量是同义反复——把 POLYPHONY 改成 8，这条断言照样成立。
	# 验收 Agent 的变异测试 M2（POLYPHONY 32→8）最初就是靠这个存活下来的。
	_eq(voice_nodes, 32, "C._ready() 预建 32 个 AudioStreamPlayer 声部（字面量，非 POLYPHONY）")

	# 无延音：on -> off 立刻释放
	PianoEngine.note_on(60)
	_check(PianoEngine.is_note_active(60), "C.note_on(60) 后 is_note_active(60) 为真")
	_eq(PianoEngine.active_voice_count(), 1, "C.note_on(60) 后 active_voice_count() == 1")
	PianoEngine.note_off(60)
	_check(not PianoEngine.is_note_active(60), "C.note_off(60)（无延音）后 is_note_active(60) 立刻为假")
	_eq(PianoEngine.active_voice_count(), 0, "C.note_off(60) 后 active_voice_count() == 0")

	# 同音重复不叠加
	PianoEngine.note_on(60)
	PianoEngine.note_on(60)
	_eq(PianoEngine.active_voice_count(), 1, "C.note_on(60) 连发两次 active_voice_count() 仍 == 1")
	PianoEngine.all_notes_off()

	# 延音踏板
	PianoEngine.set_sustain(true)
	_check(PianoEngine.sustain_enabled, "C.set_sustain(true) 后 sustain_enabled 为真")
	PianoEngine.note_on(60)
	PianoEngine.note_off(60)
	_check(PianoEngine.is_note_active(60), "C.延音中 note_off(60) 后 is_note_active(60) 仍为真")
	_check(PianoEngine.sustained_note_count() >= 1, "C.延音中 sustained_note_count() >= 1")
	_eq(PianoEngine.active_voice_count(), 1, "C.延音中 active_voice_count() == 1")
	PianoEngine.set_sustain(false)
	_check(not PianoEngine.is_note_active(60), "C.set_sustain(false) 后 is_note_active(60) 立刻为假")
	_eq(PianoEngine.sustained_note_count(), 0, "C.set_sustain(false) 后 sustained_note_count() == 0")
	_eq(PianoEngine.active_voice_count(), 0, "C.set_sustain(false) 后 active_voice_count() == 0")

	# 复音上限：21..60 共 40 个不同音
	# ⚠️ 全部用**字面量**断言，不能用 PianoEngine.POLYPHONY：
	# `active_voice_count() <= POLYPHONY` 是同义反复，把常量改小它永远成立。
	# 变异测试 M2（POLYPHONY 32→8）正是因此存活——现在这条能抓住它。
	_reset_engine()
	var stealed: Array = []
	var on_steal := func(midi: int) -> void: stealed.append(midi)
	PianoEngine.voice_stealed.connect(on_steal)
	for midi in range(21, 61):
		PianoEngine.note_on(midi)
	_eq(PianoEngine.active_voice_count(), 32,
		"C.连发 40 个不同音后 active_voice_count() 恰为 32（字面量，非 POLYPHONY）")
	_eq(stealed.size(), 8, "C.40 个音超出 32 复音 -> voice_stealed 触发 8 次")
	_check(stealed.size() > 0 and int(stealed[0]) == 21,
		"C.首个被抢占的是最早触发的 21 号（按 start_msec 抢占，非随机）")
	if PianoEngine.voice_stealed.is_connected(on_steal):
		PianoEngine.voice_stealed.disconnect(on_steal)

	# 非法 midi 被忽略且不进入 _active
	_reset_engine()
	PianoEngine.note_on(20)
	PianoEngine.note_on(109)
	_check(not PianoEngine.is_note_active(20), "C.note_on(20) 越界被忽略（未进入 _active）")
	_check(not PianoEngine.is_note_active(109), "C.note_on(109) 越界被忽略（未进入 _active）")
	_eq(PianoEngine.active_voice_count(), 0, "C.越界 note_on 后 active_voice_count() == 0（未崩溃）")
	PianoEngine.note_off(20)
	PianoEngine.note_off(109)
	_eq(PianoEngine.active_voice_count(), 0, "C.越界 note_off 后 active_voice_count() == 0（未崩溃）")

	# all_notes_off()：每个正在发声的音补发 note_stopped（契约第 3 节 + 主 Agent 要求的行为）
	var stopped: Array = []
	var cb := func(m: int) -> void:
		stopped.append(m)
	PianoEngine.note_stopped.connect(cb)
	_reset_engine()
	stopped.clear()
	for midi in [60, 62, 64]:
		PianoEngine.note_on(midi)
	_eq(PianoEngine.active_voice_count(), 3, "C.all_notes_off 前置：3 个音在发声")
	PianoEngine.all_notes_off()
	_eq(PianoEngine.active_voice_count(), 0, "C.all_notes_off() 后 active_voice_count() == 0")
	_eq(stopped.size(), 3, "C.all_notes_off() 补发的 note_stopped 数 == 之前发声数（3），实收 %d" % stopped.size())
	PianoEngine.note_stopped.disconnect(cb)

	# 音量夹取
	PianoEngine.set_master_volume(0.5)
	_check(absf(PianoEngine.master_volume - 0.5) < 0.0001,
		"C.set_master_volume(0.5) 后 master_volume == 0.5（实际 %s）" % str(PianoEngine.master_volume))
	PianoEngine.set_master_volume(2.0)
	_check(absf(PianoEngine.master_volume - 1.0) < 0.0001,
		"C.set_master_volume(2.0) 被夹到 1.0（实际 %s）" % str(PianoEngine.master_volume))
	PianoEngine.set_master_volume(-1.0)
	_check(absf(PianoEngine.master_volume - 0.0) < 0.0001,
		"C.set_master_volume(-1.0) 被夹到 0.0（实际 %s）" % str(PianoEngine.master_volume))
	PianoEngine.set_master_volume(0.8)

	_reset_engine()


# ============================================================
# F. Keyboard（契约第 6 节）
# ============================================================

func _test_keyboard() -> void:
	_say("")
	_say("--- F. Keyboard ---")

	var kb: Control = KeyboardScript.new()
	add_child(kb)          # 触发 _ready()（内部会 build()）
	await get_tree().process_frame
	kb.build()             # 幂等：再建一次，确保节点数为 88

	_eq(kb.get_child_count(), 88, "F.build() 后 get_child_count() == 88")

	var white := 0
	var black := 0
	var black_midis: Array[int] = []
	for midi in range(MusicTheory.MIDI_LOWEST, MusicTheory.MIDI_HIGHEST + 1):
		var key: Control = kb.get_key(midi)
		if key == null:
			continue
		if MusicTheory.is_black_key(midi):
			black += 1
			black_midis.append(midi)
		else:
			white += 1
	_eq(white, 52, "F.按 MusicTheory.is_black_key 分类：白键 52 个")
	_eq(black, 36, "F.按 MusicTheory.is_black_key 分类：黑键 36 个")

	_check(kb.get_key(21) != null, "F.get_key(21) 非 null")
	_check(kb.get_key(108) != null, "F.get_key(108) 非 null")
	_check(kb.get_key(60) != null, "F.get_key(60) 非 null")
	_check(kb.get_key(20) == null, "F.get_key(20) 为 null（越界）")

	# z_index：黑键 > 白键
	var z_ok := true
	var z_detail := ""
	for midi in range(MusicTheory.MIDI_LOWEST, MusicTheory.MIDI_HIGHEST + 1):
		var key: Control = kb.get_key(midi)
		if key == null:
			continue
		if MusicTheory.is_black_key(midi):
			if not (key.z_index > kb.get_key(60).z_index):
				z_ok = false
				z_detail = "黑键 %d z_index=%d 未高于白键 %d" % [midi, key.z_index, kb.get_key(60).z_index]
				break
	_check(z_ok, "F.黑键 z_index > 白键 z_index %s" % z_detail)

	# 最小尺寸
	_eq(str(kb.custom_minimum_size), str(Vector2(52.0 * kb.white_key_width, 220.0)),
		"F.custom_minimum_size == Vector2(52 * white_key_width, 220)")

	# 黑键位置：中心骑在前一个白键的右边界
	var pos_bad: Array[String] = []
	for midi in black_midis:
		var key: Control = kb.get_key(midi)
		var actual: float = key.position.x + key.size.x * 0.5
		var expected: float = (float(MusicTheory.white_index_of(midi - 1)) + 1.0) * kb.white_key_width
		if absf(actual - expected) > 0.01:
			pos_bad.append("midi=%d actual=%.4f expected=%.4f" % [midi, actual, expected])
	_eq(pos_bad.size(), 0, "F.36 个黑键中心 x 全部 ≈ (white_index_of(midi-1)+1)*white_key_width（偏差=%s）" % str(pos_bad))

	# 发声入口
	_reset_engine()
	kb.press_note(60)
	_check(PianoEngine.is_note_active(60), "F.press_note(60) 使 PianoEngine.is_note_active(60) 为真")
	_eq(PianoEngine.active_voice_count(), 1, "F.press_note(60) 后 active_voice_count() == 1")
	kb.press_note(60)
	_eq(PianoEngine.active_voice_count(), 1, "F.重复 press_note(60) 不叠加（active_voice_count() 仍 1）")
	kb.release_note(60)
	_check(not PianoEngine.is_note_active(60), "F.release_note(60) 后 is_note_active(60) 为假")
	_eq(PianoEngine.active_voice_count(), 0, "F.release_note(60) 后 active_voice_count() == 0")

	# 高亮纯视觉：不发声
	_reset_engine()
	kb.set_note_highlight(60, true)
	_check(not PianoEngine.is_note_active(60), "F.set_note_highlight(60, true) 不发声")
	var key60: Control = kb.get_key(60)
	_check(key60 != null and bool(key60.highlighted), "F.set_note_highlight(60, true) 后键的 highlighted 为真")
	kb.set_note_highlight(60, false)
	_check(key60 != null and not bool(key60.highlighted), "F.set_note_highlight(60, false) 后键的 highlighted 为假")

	# ---- 输入路径：电脑键盘映射 + 鼠标交互（伪造 InputEvent）----
	await _test_keyboard_keymap(kb)
	await _test_keyboard_mouse(kb)

	kb.queue_free()
	await get_tree().process_frame
	_reset_engine()


# ============================================================
# F2. Keyboard 输入路径 —— 电脑键盘映射（契约第 6 节硬性要求 4）
# ============================================================
# 驱动方式（隔离探针实测确认）：
#   * 直接调 kb._unhandled_input(ev) 能正常发声；kb._physical_map 是 29 项，与契约逐项一致。
#   * InputEventKey.is_command_or_control_pressed() 认事件上的 ctrl_pressed 标志（实测 false/true 正确翻转）。
#   * get_viewport().push_input(ev) 能把按键送进 kb._unhandled_input（实测 KEY_R 发声成功），
#     而且 push_input 每次会重置 "已消费" 标志 —— 所以"是否被消费"用 push_input 测才可隔离。
#   * 其余 27 个映射用直调（少走一遍视口，更快也更确定）。

func _test_keyboard_keymap(kb: Control) -> void:
	_say("")
	_say("--- F2. Keyboard 电脑键盘映射 ---")

	# 契约第 6 节要求 4 的 29 个映射，逐个显式列出，防止实现漏键或多键
	var expected_pairs := {
		KEY_Z: 60, KEY_S: 61, KEY_X: 62, KEY_D: 63, KEY_C: 64, KEY_V: 65,
		KEY_G: 66, KEY_B: 67, KEY_H: 68, KEY_N: 69, KEY_J: 70, KEY_M: 71,
		KEY_Q: 72, KEY_2: 73, KEY_W: 74, KEY_3: 75, KEY_E: 76, KEY_R: 77,
		KEY_5: 78, KEY_T: 79, KEY_6: 80, KEY_Y: 81, KEY_7: 82, KEY_U: 83,
		KEY_COMMA: 84, KEY_L: 85, KEY_PERIOD: 86, KEY_SEMICOLON: 87, KEY_SLASH: 88,
	}
	var got_pairs := {}
	for k in kb._physical_map:
		got_pairs[int(k)] = int(kb._physical_map[k])

	_eq(got_pairs.size(), 29, "F2._physical_map 共 29 个映射")
	var mismatch: Array[String] = []
	for k in expected_pairs:
		if not got_pairs.has(k):
			mismatch.append("缺少 keycode %d -> midi %d" % [k, expected_pairs[k]])
		elif int(got_pairs[k]) != int(expected_pairs[k]):
			mismatch.append("keycode %d 期望 midi %d 实际 %d" % [k, expected_pairs[k], got_pairs[k]])
	for k in got_pairs:
		if not expected_pairs.has(k):
			mismatch.append("多出 keycode %d -> midi %d" % [k, got_pairs[k]])
	_eq(mismatch.size(), 0, "F2.29 个 physical_keycode -> midi 映射与契约逐项一致（差异=%s）" % str(mismatch))

	# 逐项行为验证：pressed -> 发声；released -> 停声
	kb.computer_keyboard_enabled = true
	PianoEngine.set_sustain(false)
	PianoEngine.all_notes_off()

	var key_bad: Array[String] = []
	for k in expected_pairs:
		var midi: int = expected_pairs[k]
		PianoEngine.all_notes_off()

		var down := InputEventKey.new()
		down.physical_keycode = k
		down.pressed = true
		down.echo = false
		kb._unhandled_input(down)
		if not PianoEngine.is_note_active(midi):
			key_bad.append("keycode %d -> midi %d 按下未发声" % [k, midi])
			continue
		if PianoEngine.active_voice_count() != 1:
			key_bad.append("keycode %d -> midi %d 按下后 active_voice_count=%d（期望 1）" % [
				k, midi, PianoEngine.active_voice_count()])

		var up := InputEventKey.new()
		up.physical_keycode = k
		up.pressed = false
		up.echo = false
		kb._unhandled_input(up)
		if PianoEngine.is_note_active(midi):
			key_bad.append("keycode %d -> midi %d 松开后仍在发声" % [k, midi])
	_eq(key_bad.size(), 0, "F2.29 个映射逐项：按下发声、松开停声（失败=%s）" % str(key_bad))
	PianoEngine.all_notes_off()

	# echo 重复事件被忽略
	var down_r := InputEventKey.new()
	down_r.physical_keycode = KEY_R
	down_r.pressed = true
	down_r.echo = false
	kb._unhandled_input(down_r)
	var echo_ev := InputEventKey.new()
	echo_ev.physical_keycode = KEY_R
	echo_ev.pressed = true
	echo_ev.echo = true
	kb._unhandled_input(echo_ev)
	_eq(PianoEngine.active_voice_count(), 1, "F2.echo=true 重复事件被忽略（active_voice_count 仍 1）")
	_check(PianoEngine.is_note_active(77), "F2.echo=true 后 KEY_R 的音仍在发声（未被重复触发打断）")
	var up_r := InputEventKey.new()
	up_r.physical_keycode = KEY_R
	up_r.pressed = false
	up_r.echo = false
	kb._unhandled_input(up_r)
	_check(not PianoEngine.is_note_active(77), "F2.KEY_R 松开后停声")

	# Ctrl+R 不发声 —— 与 HUD 的 Ctrl+R（录制开关）共存的关键约定，必须锁住
	PianoEngine.all_notes_off()
	var ctrl_r := InputEventKey.new()
	ctrl_r.physical_keycode = KEY_R
	ctrl_r.pressed = true
	ctrl_r.echo = false
	ctrl_r.ctrl_pressed = true
	_check(ctrl_r.is_command_or_control_pressed(),
		"F2.前置：带 ctrl_pressed 的 InputEventKey.is_command_or_control_pressed() 为真")
	kb._unhandled_input(ctrl_r)
	_check(not PianoEngine.is_note_active(77), "F2.Ctrl+R 不发声（KEY_R=F5=77 未被触发）")
	_eq(PianoEngine.active_voice_count(), 0, "F2.Ctrl+R 后 active_voice_count() == 0")

	# computer_keyboard_enabled = false 时不响应任何音符键
	kb.computer_keyboard_enabled = false
	PianoEngine.all_notes_off()
	var disabled_bad: Array[String] = []
	for k in expected_pairs:
		var d := InputEventKey.new()
		d.physical_keycode = k
		d.pressed = true
		d.echo = false
		kb._unhandled_input(d)
		if PianoEngine.active_voice_count() != 0:
			disabled_bad.append("keycode %d 在 disabled 时仍发声" % k)
	_eq(disabled_bad.size(), 0, "F2.computer_keyboard_enabled=false 时不响应音符键（失败=%s）" % str(disabled_bad))
	kb.computer_keyboard_enabled = true
	PianoEngine.all_notes_off()

	# 非音符键不消费事件（否则 HUD 的 Space=延音 快捷键会失效）
	# 用 push_input 走真实路径：它每次会重置"已消费"标志，因此可隔离
	var space := InputEventKey.new()
	space.physical_keycode = KEY_SPACE
	space.pressed = true
	space.echo = false
	get_viewport().push_input(space)
	_check(not get_viewport().is_input_handled(),
		"F2.KEY_SPACE 未被琴键模块消费（get_viewport().is_input_handled() 仍为假，HUD 快捷键可用）")
	_eq(PianoEngine.active_voice_count(), 0, "F2.KEY_SPACE 未触发任何发声")

	# 音符键确实会被消费（与上面构成对照，证明该断言不是恒真）
	var r2 := InputEventKey.new()
	r2.physical_keycode = KEY_R
	r2.pressed = true
	r2.echo = false
	get_viewport().push_input(r2)
	_check(get_viewport().is_input_handled(), "F2.对照：音符键 KEY_R 经 push_input 会被消费（该断言非恒真）")
	_check(PianoEngine.is_note_active(77), "F2.对照：push_input(KEY_R) 经真实输入路径发声")
	var r2up := InputEventKey.new()
	r2up.physical_keycode = KEY_R
	r2up.pressed = false
	r2up.echo = false
	get_viewport().push_input(r2up)
	_check(not PianoEngine.is_note_active(77), "F2.对照：push_input 松开 KEY_R 后停声")
	PianoEngine.all_notes_off()


# ============================================================
# F3. Keyboard 输入路径 —— 鼠标交互（契约第 6 节硬性要求 3）
# ============================================================
# 驱动方式（隔离探针实测确认）：
#   * 直调 kb._gui_input(ev) 能正确命中/发声/连奏/右键切延音/离开释放。
#   * push_input(InputEventMouseButton) 在 headless 下【不】会送到 kb._gui_input
#     （实测 active60=false），因为 headless 视口没有真实鼠标位置/GUI 拾取状态。
#     故鼠标路径一律直调 _gui_input —— 这是唯一可靠方式，如实说明。
#   * 坐标是键盘局部坐标（_gui_input 收到的本来就是局部坐标）。

func _test_keyboard_mouse(kb: Control) -> void:
	_say("")
	_say("--- F3. Keyboard 鼠标交互 ---")

	_check(kb.mouse_filter == Control.MOUSE_FILTER_STOP,
		"F3.前置：kb.mouse_filter == MOUSE_FILTER_STOP（_gui_input 能被投递的前提）")

	var w := float(kb.white_key_width)

	# 1) 左键按下白键 C4
	PianoEngine.set_sustain(false)
	PianoEngine.all_notes_off()
	var c4_x: float = (float(MusicTheory.white_index_of(60)) + 0.5) * w
	var c4_pos := Vector2(c4_x, 100.0)
	_eq(kb._key_at(c4_pos), 60, "F3._key_at(C4 中心) 命中 60")

	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = c4_pos
	kb._gui_input(down)
	_check(PianoEngine.is_note_active(60), "F3.左键按下白键 C4 -> is_note_active(60) 为真")
	_eq(PianoEngine.active_voice_count(), 1, "F3.左键按下后 active_voice_count() == 1")

	# 2) 黑键优先命中：在黑键矩形中心按下，必须命中黑键而不是它下面的白键
	PianoEngine.all_notes_off()
	var d4_x: float = (float(MusicTheory.white_index_of(62)) + 0.5) * w
	var black_midi := 63                                     # D#4
	var black_x: float = (float(MusicTheory.white_index_of(black_midi - 1)) + 1.0) * w
	var black_pos := Vector2(black_x, 10.0)                  # 黑键高度 = 220*0.62 = 136.4，y=10 在黑键内
	_eq(kb._key_at(black_pos), black_midi,
		"F3._key_at(黑键 D#4 中心) 命中黑键 %d（而非下面的白键）" % black_midi)
	_check(kb._key_at(black_pos) != 62 and kb._key_at(black_pos) != 64,
		"F3.黑键命中优先于相邻白键 D4(62)/E4(64)")
	# 同一 x 在 y=200（超出黑键高度）时应落到白键，证明上面的命中确实来自黑键层
	_check(kb._key_at(Vector2(black_x, 200.0)) != black_midi,
		"F3.同一 x 在 y=200（黑键下方）不再命中黑键（证明黑键命中来自黑键层而非白键）")

	var bdown := InputEventMouseButton.new()
	bdown.button_index = MOUSE_BUTTON_LEFT
	bdown.pressed = true
	bdown.position = black_pos
	kb._gui_input(bdown)
	_check(PianoEngine.is_note_active(black_midi), "F3.在黑键中心按下 -> 黑键 %d 发声" % black_midi)
	_check(not PianoEngine.is_note_active(62) and not PianoEngine.is_note_active(64),
		"F3.在黑键中心按下 -> 相邻白键 D4/E4 均未发声")
	_eq(PianoEngine.active_voice_count(), 1, "F3.黑键按下后同一时刻只有 1 个鼠标音")

	# 3) 拖动连奏（glissando）：按住移到另一个键，旧音释放、新音发声，且只有 1 个鼠标音
	PianoEngine.all_notes_off()
	kb._gui_input(down)                                      # 按住 C4
	_check(PianoEngine.is_note_active(60), "F3.连奏前置：按住 C4 发声")
	var d4_white_x: float = (float(MusicTheory.white_index_of(62)) + 0.5) * w
	var motion := InputEventMouseMotion.new()
	motion.position = Vector2(d4_white_x, 100.0)
	kb._gui_input(motion)
	_check(not PianoEngine.is_note_active(60), "F3.拖动到 D4 后旧音 C4 已释放")
	_check(PianoEngine.is_note_active(62), "F3.拖动到 D4 后新音 D4 在发声")
	_eq(PianoEngine.active_voice_count(), 1, "F3.拖动连奏期间同一时刻只有 1 个鼠标音（active_voice_count == 1）")

	# 再拖到第三个键，验证可连续连奏
	var e4_x: float = (float(MusicTheory.white_index_of(64)) + 0.5) * w
	var motion2 := InputEventMouseMotion.new()
	motion2.position = Vector2(e4_x, 100.0)
	kb._gui_input(motion2)
	_check(not PianoEngine.is_note_active(62), "F3.继续拖动到 E4 后 D4 已释放")
	_check(PianoEngine.is_note_active(64), "F3.继续拖动到 E4 后 E4 在发声")
	_eq(PianoEngine.active_voice_count(), 1, "F3.连续连奏期间仍只有 1 个鼠标音")

	# 4) 松开左键 -> 停止发声
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = Vector2(e4_x, 100.0)
	kb._gui_input(up)
	_check(not PianoEngine.is_note_active(64), "F3.松开左键后 E4 停止发声")
	_eq(PianoEngine.active_voice_count(), 0, "F3.松开左键后 active_voice_count() == 0")

	# 5) 右键切换延音且不发声
	PianoEngine.all_notes_off()
	PianoEngine.set_sustain(false)
	var rdown := InputEventMouseButton.new()
	rdown.button_index = MOUSE_BUTTON_RIGHT
	rdown.pressed = true
	rdown.position = c4_pos
	kb._gui_input(rdown)
	_check(PianoEngine.sustain_enabled, "F3.右键按下 -> sustain_enabled 翻转为真")
	_eq(PianoEngine.active_voice_count(), 0, "F3.右键按下不触发任何发声")

	kb._gui_input(rdown)                                     # 再按一次应翻回 false
	_check(not PianoEngine.sustain_enabled, "F3.再次右键 -> sustain_enabled 翻回假")
	_eq(PianoEngine.active_voice_count(), 0, "F3.再次右键仍不触发发声")
	PianoEngine.set_sustain(false)

	# 6) 鼠标离开控件释放当前音
	PianoEngine.all_notes_off()
	kb._gui_input(down)
	_check(PianoEngine.is_note_active(60), "F3.离开前置：按住 C4 发声")
	kb.emit_signal("mouse_exited")
	_check(not PianoEngine.is_note_active(60), "F3.mouse_exited 后当前鼠标音被释放")
	_eq(PianoEngine.active_voice_count(), 0, "F3.mouse_exited 后 active_voice_count() == 0")

	# 清理：复位鼠标按住态、延音与引擎
	var cleanup_up := InputEventMouseButton.new()
	cleanup_up.button_index = MOUSE_BUTTON_LEFT
	cleanup_up.pressed = false
	cleanup_up.position = Vector2(0.0, 0.0)
	kb._gui_input(cleanup_up)
	PianoEngine.set_sustain(false)
	PianoEngine.all_notes_off()


# ============================================================
# E. Recorder（契约第 5 节）
# ============================================================

func _test_recorder() -> void:
	_say("")
	_say("--- E. Recorder ---")

	# 预清理
	if FileAccess.file_exists(TEST_GOOD_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_GOOD_PATH))
	if FileAccess.file_exists(TEST_BAD_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_BAD_PATH))
	if FileAccess.file_exists(TEST_ARRAY_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_ARRAY_PATH))

	# ---- 录制 note_on + note_off ----
	_reset_engine()
	Recorder.start_recording()
	_check(Recorder.is_recording(), "E.start_recording() 后 is_recording() 为真")

	PianoEngine.note_on(60)
	await _spin_wait(30)                       # 自旋等待，保证真实时间戳严格递增
	PianoEngine.note_off(60)
	Recorder.stop_recording()
	_check(not Recorder.is_recording(), "E.stop_recording() 后 is_recording() 为假")
	_eq(Recorder.event_count(), 2, "E.录 note_on+note_off 后 event_count() == 2")

	if Recorder.event_count() >= 2:
		var e0: Dictionary = Recorder.events[0]
		var e1: Dictionary = Recorder.events[1]
		_eq(String(e0.get("type", "")), "on", "E.第 1 条事件 type == \"on\"")
		_eq(String(e1.get("type", "")), "off", "E.第 2 条事件 type == \"off\"")
		var t0 := int(e0.get("t", -1))
		var t1 := int(e1.get("t", -1))
		_check(t1 > t0, "E.第 2 条事件 t(%d) 严格大于第 1 条 t(%d)" % [t1, t0])
		_check(Recorder.duration_msec() > 0, "E.duration_msec() > 0（实际 %d）" % Recorder.duration_msec())
		_eq(Recorder.duration_msec(), t1, "E.duration_msec() == 最后一条事件的 t")
		_eq(int(e0.get("midi", -1)), 60, "E.第 1 条事件 midi == 60")
		_check(float(e0.get("velocity", 0.0)) > 0.0, "E.第 1 条事件 velocity > 0")
		var keys_ok := true
		var keys_detail := ""
		for i in Recorder.event_count():
			var ev: Dictionary = Recorder.events[i]
			var got := ev.keys()
			got.sort()
			var want: Array = ["midi", "t", "type", "value", "velocity"]
			want.sort()
			if str(got) != str(want):
				keys_ok = false
				keys_detail = "事件 %d 的键 = %s" % [i, str(got)]
				break
		_check(keys_ok, "E.事件字典严格只有 t/type/midi/velocity/value 五个键 %s" % keys_detail)
	else:
		_check(false, "E.事件数不足 2，后续事件字段断言无法执行")

	# ---- 存盘 / 读档 ----
	var saved_count := Recorder.event_count()
	var saved_t0 := int(Recorder.events[0].get("t", -1)) if saved_count > 0 else -1
	var saved_t1 := int(Recorder.events[-1].get("t", -1)) if saved_count > 0 else -1
	var err := Recorder.save_to_file(TEST_GOOD_PATH)
	_eq(err, OK, "E.save_to_file(\"user://test_rec.json\") 返回 OK（实际 %d）" % err)
	_check(FileAccess.file_exists(TEST_GOOD_PATH), "E.存盘文件确实存在")

	Recorder.clear()
	_eq(Recorder.event_count(), 0, "E.clear() 后 event_count() == 0")

	var lerr := Recorder.load_from_file(TEST_GOOD_PATH)
	_eq(lerr, OK, "E.load_from_file() 返回 OK（实际 %d）" % lerr)
	_eq(Recorder.event_count(), saved_count, "E.读档后 event_count() 与存盘前一致")
	if Recorder.event_count() > 0:
		_eq(int(Recorder.events[0].get("t", -1)), saved_t0, "E.读档后第 1 条 t 一致")
		_eq(int(Recorder.events[-1].get("t", -1)), saved_t1, "E.读档后最后一条 t 一致")
		_eq(String(Recorder.events[0].get("type", "")), "on", "E.读档后第 1 条 type 一致")
		_eq(int(Recorder.events[0].get("midi", -1)), 60, "E.读档后第 1 条 midi 一致")
		_eq(String(Recorder.events[-1].get("type", "")), "off", "E.读档后最后一条 type 一致")

	# ---- 脏数据容错 ----
	var f := FileAccess.open(TEST_BAD_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string("{not json")
		f.close()
	_eq(Recorder.load_from_file(TEST_BAD_PATH), ERR_PARSE_ERROR, "E.损坏 JSON(\"{not json\") 返回 ERR_PARSE_ERROR 且不崩溃")

	var f2 := FileAccess.open(TEST_ARRAY_PATH, FileAccess.WRITE)
	if f2 != null:
		f2.store_string("[]")
		f2.close()
	_eq(Recorder.load_from_file(TEST_ARRAY_PATH), ERR_PARSE_ERROR, "E.顶层非 Dictionary(\"[]\") 返回 ERR_PARSE_ERROR 且不崩溃")

	_eq(Recorder.load_from_file("user://test_definitely_missing.json"), ERR_FILE_NOT_FOUND,
		"E.不存在的文件返回 ERR_FILE_NOT_FOUND")

	# ---- 回放期间不录制（契约第 5 节硬性要求 2）----
	_reset_engine()
	Recorder.start_recording()
	PianoEngine.note_on(60)
	await _spin_wait(20)
	PianoEngine.note_off(60)
	Recorder.stop_recording()
	var before_count := Recorder.event_count()
	_check(before_count > 0, "E.回放前置：录制得到 %d 条事件" % before_count)

	Recorder.start_playback()
	_check(Recorder.is_playing(), "E.start_playback() 后 is_playing() 为真")
	await _spin_wait(200)
	_eq(Recorder.event_count(), before_count,
		"E.回放 200ms 期间 event_count() 没有增加（回放期间不录制）")
	Recorder.stop_playback()
	_check(not Recorder.is_playing(), "E.stop_playback() 后 is_playing() 为假")
	_eq(Recorder.event_count(), before_count, "E.stop_playback() 未改变 event_count()")

	# ---- 回放真正驱动引擎 ----
	_reset_engine()
	Recorder.start_recording()
	PianoEngine.note_on(60)
	await _spin_wait(30)
	PianoEngine.note_off(60)
	Recorder.stop_recording()
	_eq(Recorder.event_count(), 2, "E.回放用录制：2 条事件")
	_reset_engine()
	_check(not PianoEngine.is_note_active(60), "E.回放前置：all_notes_off() 后 60 未发声")

	Recorder.start_playback()
	await _spin_wait(20)
	_check(PianoEngine.is_note_active(60), "E.回放驱动引擎：start_playback() 后 20ms 内 is_note_active(60) 为真")
	Recorder.stop_playback()
	_reset_engine()


# ============================================================
# D. Metronome（契约第 4 节）
# ============================================================

func _test_metronome() -> void:
	_say("")
	_say("--- D. Metronome ---")

	Metronome.stop()

	# BPM 夹取
	Metronome.set_bpm(600)
	_eq(Metronome.bpm, 300.0, "D.set_bpm(600) 上夹到 300.0")
	Metronome.set_bpm(5)
	_eq(Metronome.bpm, 20.0, "D.set_bpm(5) 下夹到 20.0")

	# 拍号夹取
	Metronome.set_beats_per_bar(12)
	_eq(Metronome.beats_per_bar, 12, "D.set_beats_per_bar(12) == 12")
	Metronome.set_beats_per_bar(0)
	_eq(Metronome.beats_per_bar, 1, "D.set_beats_per_bar(0) 下夹到 1")

	# ---- beats_per_bar = 3：连续 trigger_tick() 6 次，重音落在第 0、3 拍 ----
	Metronome.set_beats_per_bar(3)
	Metronome.reset()
	var accents: Array = []
	var beats: Array = []
	var acc_cb := func(beat_index: int, is_accent: bool) -> void:
		beats.append(beat_index)
		accents.append(is_accent)
	Metronome.tick.connect(acc_cb)
	for i in 6:
		Metronome.trigger_tick()
	Metronome.tick.disconnect(acc_cb)
	_eq(str(accents), str([true, false, false, true, false, false]),
		"D.beats_per_bar=3 连发 6 拍：accent 在第 0、3 拍（实际 %s）" % str(accents))
	_eq(str(beats), str([0, 1, 2, 0, 1, 2]), "D.beats_per_bar=3 连发 6 拍的 beat_index 序列（实际 %s）" % str(beats))
	_eq(Metronome.bar_count, 2, "D.连发 6 拍后 bar_count == 2")
	Metronome.reset()
	Metronome.set_beats_per_bar(4)

	# ---- started 早于第一个 tick ----
	Metronome.set_bpm(120)
	Metronome.reset()
	var order: Array = []
	var ord_tick := func(_b: int, _a: bool) -> void:
		order.append("tick")
	var ord_started := func() -> void:
		order.append("started")
	Metronome.tick.connect(ord_tick)
	Metronome.started.connect(ord_started)
	Metronome.start()
	Metronome.tick.disconnect(ord_tick)
	Metronome.started.disconnect(ord_started)
	_check(order.size() >= 2 and order[0] == "started" and order[1] == "tick",
		"D.start() 时 emit started 早于第一个 tick（实际顺序 %s）" % str(order))
	Metronome.stop()

	# ---- 300 BPM：start() 同步发 1 拍，自旋等 1.1s 真实时间，累计 >= 5（理论 6）----
	Metronome.set_bpm(300)
	_eq(Metronome.bpm, 300.0, "D.set_bpm(300) 后 bpm == 300.0（周期 200ms）")
	var count: Array = []
	var cnt_cb := func(_b: int, _a: bool) -> void:
		count.append(1)
	Metronome.tick.connect(cnt_cb)
	Metronome.start()
	_eq(count.size(), 1, "D.start() 内同步发出第 1 拍（收到 %d 拍）" % count.size())
	_check(Metronome.is_running(), "D.start() 后 is_running() 为真")
	await _spin_wait(1100)
	_check(count.size() >= 5, "D.300BPM 自旋 1.1s 真实时间后累计 tick >= 5（实际 %d，理论 6）" % count.size())
	Metronome.tick.disconnect(cnt_cb)

	# ---- stop() 后不再 tick，且归零 ----
	Metronome.stop()
	_check(not Metronome.is_running(), "D.stop() 后 is_running() 为假")
	var after_stop: Array = []
	var as_cb := func(_b: int, _a: bool) -> void:
		after_stop.append(1)
	Metronome.tick.connect(as_cb)
	await _spin_wait(300)
	Metronome.tick.disconnect(as_cb)
	_eq(after_stop.size(), 0, "D.stop() 后自旋 300ms 内无新 tick")
	_eq(Metronome.current_beat, 0, "D.stop() 后 current_beat == 0")
	_eq(Metronome.bar_count, 0, "D.stop() 后 bar_count == 0")

	# ---- 证明按真实时间而非帧数：20 BPM（周期 3000ms）----
	Metronome.set_bpm(20)
	_eq(Metronome.bpm, 20.0, "D.set_bpm(20) 后 bpm == 20.0（周期 3000ms）")
	var slow: Array = []
	var slow_cb := func(_b: int, _a: bool) -> void:
		slow.append(1)
	Metronome.tick.connect(slow_cb)
	Metronome.start()
	await _spin_wait(1000)
	Metronome.tick.disconnect(slow_cb)
	_eq(slow.size(), 1, "D.20BPM start() 后自旋 1.0s 真实时间：tick 数 == 1（证明按真实时间而非帧数，实际 %d）" % slow.size())
	Metronome.stop()

	# 收尾：恢复合理默认值
	Metronome.set_bpm(120)
	Metronome.set_beats_per_bar(4)
	Metronome.stop()
