extends Node
## PianoEngine：88 键钢琴的复音发声引擎 + 延音踏板（autoload 名 PianoEngine）。
## 契约见 docs/INTERFACES.md 第 3 节。
##
## 设计要点：逻辑状态（_active）与 AudioStreamPlayer 完全解耦。
## headless（Dummy 音频驱动）下 player.playing / player.finished 都不可靠，
## 因此 is_note_active() / active_voice_count() / sustained_note_count()
## 一律只读 _active，保证自动化测试在任何音频驱动下都能断言。

const POLYPHONY := 32              # 同时发声上限
const SAMPLE_FORMAT := "mp3"       # audio/piano/ 下的扩展名
const RELEASE_FADE_SEC := 0.06     # 松键淡出，防爆音

# —— 内部常量（不属于公开契约） ——
const _BUS_NAME := "Master"           # 声部挂载的音频总线
const _SILENT_DB := -80.0             # 总音量为 0 时写入总线的分贝
const _VOICE_SILENT_DB := -60.0       # 淡出终点 / velocity 为 0 时的分贝
const _LOOP_OFFSET_RATIO := 0.55      # 延音循环起点 = 采样长度 * 0.55

# 电平补偿：FluidR3_GM 的采样被母带处理得极其保守——实测原始峰值仅 0.0889（-21.0 dBFS）。
# 若不做补偿，即使总音量拉满也只有 -21 dBFS，比常规媒体安静约 20 dB。
# 这里补 +6 dB，让单音与轻织体达到正常可听电平；密集和弦的叠加溢出
# 由 _install_limiter() 挂在 Master 总线上的限制器兜住，避免硬削波失真。
const _VOICE_GAIN := 2.0              # +6.02 dB
const _LIMITER_CEILING_DB := -1.0     # 限制器天花板

var master_volume: float = 0.8            # 0.0 ~ 1.0
var sustain_enabled: bool = false         # 延音踏板
var sustain_loop_enabled: bool = false    # 延音时循环采样尾音（增强长延音）

signal note_started(midi: int, velocity: float)
signal note_stopped(midi: int)
signal sustain_changed(on: bool)
signal voice_stealed(midi: int)     # 复音数用尽被抢占时

var _voices: Array[AudioStreamPlayer] = []   # 声部池 Voice0..Voice31
var _active: Dictionary = {}                 # midi -> 声部信息（唯一逻辑事实来源）
var _stream_cache: Dictionary = {}           # midi -> AudioStream
var _loop_cache: Dictionary = {}             # midi -> 开了 loop 的副本
var _fade_tweens: Dictionary = {}            # AudioStreamPlayer -> Tween
var _player_midi: Dictionary = {}            # AudioStreamPlayer -> 当前占用的 midi
var _player_gen: Dictionary = {}             # AudioStreamPlayer -> 复用代次（防旧 Tween 误伤新音）
var _voice_cursor: int = 0                   # 轮转分配起点，避免总复用同一批声部
var _serial: int = 0                         # 单调递增序号，抢占时打破同毫秒并列


func _ready() -> void:
	# 预建声部池：Voice0 .. Voice31，全部挂在 Master 总线
	for i in POLYPHONY:
		var player := AudioStreamPlayer.new()
		player.name = "Voice%d" % i
		player.bus = _BUS_NAME
		add_child(player)
		player.finished.connect(_on_voice_finished.bind(player))
		_voices.append(player)
		_player_gen[player] = 0
	# 应用初始总音量
	set_master_volume(master_volume)
	# 挂总线限制器，兜住密集和弦的叠加峰值
	_install_limiter()


## 发声。velocity 0.0~1.0。重复 note_on 同一音会先停旧声再起新声。
func note_on(midi: int, velocity: float = 0.8) -> void:
	if not MusicTheory.is_valid_midi(midi):
		push_warning("PianoEngine.note_on: MIDI %d 超出 88 键范围（21..108），已忽略。" % midi)
		return

	var stream := get_stream(midi)
	if stream == null:
		# 采样缺失：静默跳过，绝不进入 _active
		return

	# 同音重复触发：先停旧声（旧声确实"停声"了，补发 note_stopped 保证 on/off 配对）
	if _active.has(midi):
		_kill_active_voice(midi, true)

	var vel := clampf(velocity, 0.0, 1.0)
	var player := _acquire_voice()
	if player == null:
		# 声部池尚未建好（_ready 之前被调用）：静默跳过，绝不崩溃
		push_warning("PianoEngine.note_on: 声部池未就绪，已忽略 MIDI %d。" % midi)
		return
	_cancel_fade(player)
	player.stop()
	player.stream = stream
	player.volume_db = _velocity_to_db(vel)
	player.play()

	_serial += 1
	_player_gen[player] = int(_player_gen.get(player, 0)) + 1
	_player_midi[player] = midi
	_active[midi] = {
		"midi": midi,
		"player": player,
		"velocity": vel,
		"start_msec": Time.get_ticks_msec(),
		"pending_release": false,
		"serial": _serial,
		"stream": stream,
	}

	emit_signal("note_started", midi, vel)


## 松键。若 sustain_enabled 为真，则不立即停声，进入"待释放"状态。
func note_off(midi: int) -> void:
	if not _active.has(midi):
		return

	var info: Dictionary = _active[midi]
	if sustain_enabled:
		# 延音中：只挂起，不停声、不发 note_stopped
		if not bool(info["pending_release"]):
			info["pending_release"] = true
			if sustain_loop_enabled:
				_apply_sustain_loop(midi, info)
		return

	_release_voice(midi)


## 切换延音踏板。关闭时立刻释放所有"待释放"的音。
func set_sustain(on: bool) -> void:
	if sustain_enabled == on:
		return  # 重复设置同一值：不重复发信号，保持状态与信号一致

	sustain_enabled = on
	if on:
		emit_signal("sustain_changed", true)
	else:
		# 先释放所有挂起的音（各自发 note_stopped），再发踏板信号
		_release_all_pending()
		emit_signal("sustain_changed", false)


## 立即停掉所有发声，清空所有状态（含延音状态复位）。
func all_notes_off() -> void:
	# 1) 先记下当前发声的音（_active 清空后就查不到了）
	var stopped: Array[int] = []
	for midi in _active:
		stopped.append(midi)
	stopped.sort()

	# 2) 所有声部立即静音并停播（含正在淡出的）
	for player in _voices:
		_cancel_fade(player)
		player.stop()
		_player_gen[player] = int(_player_gen.get(player, 0)) + 1

	# 3) 清空逻辑状态
	_active.clear()
	_player_midi.clear()

	# 4) 补发 note_stopped：状态变了就要通知观察者，
	#    否则 main.gd 的琴键高亮与 Recorder 的事件流都会残留脏状态。
	for midi in stopped:
		emit_signal("note_stopped", midi)

	# 5) 延音状态复位：仅当原本为 true 时补发信号
	if sustain_enabled:
		sustain_enabled = false
		emit_signal("sustain_changed", false)


## 该音当前是否在发声（含待释放）。只读 _active，与音频驱动无关。
func is_note_active(midi: int) -> bool:
	return _active.has(midi)


## 当前活跃声部数。只读 _active，与音频驱动无关。
func active_voice_count() -> int:
	return _active.size()


## 当前被延音踏板挂住的音（待释放）。
func sustained_note_count() -> int:
	var count := 0
	for midi in _active:
		if bool(_active[midi]["pending_release"]):
			count += 1
	return count


## 设置总音量 0.0~1.0。
func set_master_volume(v: float) -> void:
	master_volume = clampf(v, 0.0, 1.0)
	if AudioServer.get_bus_count() == 0:
		return
	if master_volume <= 0.0:
		AudioServer.set_bus_volume_db(0, _SILENT_DB)
	else:
		AudioServer.set_bus_volume_db(0, linear_to_db(master_volume))


## 加载采样，返回 AudioStream；失败返回 null。内部缓存，避免重复加载 88 个文件。
func get_stream(midi: int) -> AudioStream:
	if not MusicTheory.is_valid_midi(midi):
		push_warning("PianoEngine.get_stream: MIDI %d 超出 88 键范围（21..108）。" % midi)
		return null

	if _stream_cache.has(midi):
		return _stream_cache[midi] as AudioStream

	# 采样路径统一由 MusicTheory 生成：res://audio/piano/<name>.mp3
	var path := MusicTheory.sample_path(midi)
	if not ResourceLoader.exists(path):
		push_warning("PianoEngine: 采样缺失，已跳过：%s" % path)
		return null

	var res := ResourceLoader.load(path)
	if res == null or not (res is AudioStream):
		push_warning("PianoEngine: 采样加载失败或不是 AudioStream：%s" % path)
		return null

	var stream := res as AudioStream
	_stream_cache[midi] = stream
	return stream


# ============================ 内部实现 ============================


## 取一个可用声部；声部池满时抢占"最早触发"的声部。池为空（_ready 之前）返回 null。
func _acquire_voice() -> AudioStreamPlayer:
	if _voices.is_empty():
		return null

	var busy := {}
	for midi in _active:
		busy[_active[midi]["player"]] = true

	var count := _voices.size()
	for i in count:
		var idx := (_voice_cursor + i) % count
		var candidate: AudioStreamPlayer = _voices[idx]
		if not busy.has(candidate):
			_voice_cursor = (idx + 1) % count
			return candidate

	# 声部池已满：抢占 start_msec 最小（并列时 serial 最小，即更早触发）的声部
	var victim_midi := -1
	var victim_info: Dictionary = {}
	for midi in _active:
		var info: Dictionary = _active[midi]
		if victim_midi == -1:
			victim_midi = midi
			victim_info = info
			continue
		var cur_ms := int(info["start_msec"])
		var best_ms := int(victim_info["start_msec"])
		if cur_ms < best_ms or (cur_ms == best_ms and int(info["serial"]) < int(victim_info["serial"])):
			victim_midi = midi
			victim_info = info

	if victim_midi == -1:
		# 兜底：池满则 _active 必然非空，理论上到不了这里
		return _voices[0] if not _voices.is_empty() else null

	var player: AudioStreamPlayer = victim_info["player"]
	emit_signal("voice_stealed", victim_midi)
	# 被抢占的音确实"停声"了，补发 note_stopped 让 Recorder 的 on/off 保持配对
	_kill_active_voice(victim_midi, true)
	return player


## 立即停声并回收指定音（无淡出）。emit_stopped 控制是否补发 note_stopped。
func _kill_active_voice(midi: int, emit_stopped: bool) -> void:
	if not _active.has(midi):
		return
	var info: Dictionary = _active[midi]
	var player: AudioStreamPlayer = info["player"]
	_active.erase(midi)
	if int(_player_midi.get(player, -1)) == midi:
		_player_midi.erase(player)
	_cancel_fade(player)
	player.stop()
	if emit_stopped:
		emit_signal("note_stopped", midi)


## 开始释放：逻辑上立刻"已停声"，音频层面走 RELEASE_FADE_SEC 淡出后 stop()。
func _release_voice(midi: int) -> void:
	if not _active.has(midi):
		return
	var info: Dictionary = _active[midi]
	var player: AudioStreamPlayer = info["player"]

	# 先摘出 _active —— 保证 note_off 之后 is_note_active() 立刻为 false
	_active.erase(midi)
	if int(_player_midi.get(player, -1)) == midi:
		_player_midi.erase(player)

	# 契约要求"释放"语义：开始释放时立即发信号（Recorder 记到的时间点才准确）
	emit_signal("note_stopped", midi)

	# 音频层面：淡出，防爆音
	_start_release_fade(player)


## 释放所有 pending_release 的声部（按 midi 升序，结果可复现）。
func _release_all_pending() -> void:
	var pending: Array[int] = []
	for midi in _active:
		if bool(_active[midi]["pending_release"]):
			pending.append(midi)
	pending.sort()
	for midi in pending:
		_release_voice(midi)


## 淡出 RELEASE_FADE_SEC 秒后停播并回收声部。
func _start_release_fade(player: AudioStreamPlayer) -> void:
	_cancel_fade(player)
	var gen := int(_player_gen.get(player, 0))
	var tween := create_tween()
	_fade_tweens[player] = tween
	tween.tween_property(player, "volume_db", _VOICE_SILENT_DB, RELEASE_FADE_SEC)
	tween.tween_callback(_finish_release.bind(player, gen))


## 淡出结束：只有当声部没被复用时才真正 stop()。
func _finish_release(player: AudioStreamPlayer, gen: int) -> void:
	if int(_player_gen.get(player, -1)) != gen:
		return  # 声部已被新音复用，旧淡出不得再动它
	_fade_tweens.erase(player)
	player.stop()


## 杀掉某声部上仍在跑的淡出 Tween（避免多个 Tween 抢同一个 volume_db）。
func _cancel_fade(player: AudioStreamPlayer) -> void:
	var tween = _fade_tweens.get(player, null)
	if tween != null and is_instance_valid(tween) and tween.is_valid():
		tween.kill()
	_fade_tweens.erase(player)


## 采样自然播完：回收声部并从 _active 移除。
func _on_voice_finished(player: AudioStreamPlayer) -> void:
	var midi := int(_player_midi.get(player, -1))
	if midi == -1:
		return
	if not _active.has(midi) or _active[midi]["player"] != player:
		return  # 已被释放/抢占，_active 里不再是这个声部
	_active.erase(midi)
	_player_midi.erase(player)
	_cancel_fade(player)
	player.stop()
	emit_signal("note_stopped", midi)


## 延音挂起时把 stream 换成开了 loop 的副本，延长尾音。失败则优雅降级。
func _apply_sustain_loop(midi: int, info: Dictionary) -> void:
	var player: AudioStreamPlayer = info["player"]
	var base: AudioStream = info.get("stream", null)
	if base == null:
		return

	var looped := _get_looped_stream(midi, base)
	if looped == null:
		return  # 该流不支持循环：保持原样继续播，不报错

	var length := 0.0
	if looped.has_method("get_length"):
		length = float(looped.get_length())
	var from_pos := length * _LOOP_OFFSET_RATIO if length > 0.0 else 0.0

	player.stream = looped
	player.play(from_pos)


## 取（并缓存）某音开了 loop 的采样副本；不支持循环时返回 null。
func _get_looped_stream(midi: int, base: AudioStream) -> AudioStream:
	if _loop_cache.has(midi):
		return _loop_cache[midi] as AudioStream
	var copy := _make_looped_copy(base)
	if copy == null:
		return null
	_loop_cache[midi] = copy
	return copy


## 复制采样并开启循环；属性不存在 / 类型不对时返回 null（调用方优雅降级）。
func _make_looped_copy(src: AudioStream) -> AudioStream:
	if src == null:
		return null
	var dup := src.duplicate()
	if not (dup is AudioStream):
		return null
	var copy := dup as AudioStream
	# AudioStreamMP3 有 loop / loop_offset；其他流可能没有 —— 先探测属性再赋值
	if not _has_property(copy, "loop"):
		return null
	copy.set("loop", true)
	if _has_property(copy, "loop_offset"):
		var length := 0.0
		if copy.has_method("get_length"):
			length = float(copy.get_length())
		if length > 0.0:
			copy.set("loop_offset", length * _LOOP_OFFSET_RATIO)
	return copy


## 属性探测：用 get_property_list() 而非硬编码类型，保证不存在的属性不会报错。
func _has_property(obj: Object, prop: String) -> bool:
	if obj == null:
		return false
	for entry in obj.get_property_list():
		if String(entry.get("name", "")) == prop:
			return true
	return false


## velocity(0..1) -> 分贝；0 视为静音。
## 注意：不能把 v * _VOICE_GAIN 夹到 1.0，否则满力度得不到任何增益
## （linear_to_db 接受 >1.0 的输入并返回正分贝，这正是我们要的补偿）。
func _velocity_to_db(velocity: float) -> float:
	var v := clampf(velocity, 0.0, 1.0)
	if v <= 0.0:
		return _VOICE_SILENT_DB
	return linear_to_db(maxf(v * _VOICE_GAIN, 0.0001))


## 在 Master 总线上挂一个限制器，兜住密集和弦的叠加峰值（防硬削波失真）。
## 用 ClassDB 探测 + 字符串比对类名，避免依赖某个版本才有的全局类而编译失败。
func _install_limiter() -> void:
	if AudioServer.get_bus_count() == 0:
		return
	# 幂等：已经挂过就不再重复添加
	for i in AudioServer.get_bus_effect_count(0):
		var existing := AudioServer.get_bus_effect(0, i)
		if existing == null:
			continue
		var cls := existing.get_class()
		if cls == "AudioEffectHardLimiter" or cls == "AudioEffectLimiter":
			return

	var fx: AudioEffect = null
	if ClassDB.class_exists("AudioEffectHardLimiter"):
		fx = ClassDB.instantiate("AudioEffectHardLimiter")
	elif ClassDB.class_exists("AudioEffectLimiter"):
		fx = ClassDB.instantiate("AudioEffectLimiter")
	if fx == null:
		return  # 该版本没有可用的限制器：静默降级，只是少了削波保护

	if fx.get("ceiling_db") != null:
		fx.set("ceiling_db", _LIMITER_CEILING_DB)
	AudioServer.add_bus_effect(0, fx)
