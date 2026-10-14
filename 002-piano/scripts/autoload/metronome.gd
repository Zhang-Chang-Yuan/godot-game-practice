extends Node
# 节拍器 autoload（名字：Metronome）。契约见 docs/INTERFACES.md 第 4 节。
# 时间基准：真实时间（Time.get_ticks_msec），绝不按帧计数——
# headless（Dummy 音频驱动）下帧率可达上千 FPS，按帧计数会让节拍飞快。

# ===== 常量 =====
const MIN_BPM := 20.0              # set_bpm 下夹
const MAX_BPM := 300.0             # set_bpm 上夹
const MIN_BEATS_PER_BAR := 1       # set_beats_per_bar 下夹
const MAX_BEATS_PER_BAR := 12      # set_beats_per_bar 上夹

const CLICK_MIX_RATE := 44100      # 点击音采样率 44.1kHz
const CLICK_DURATION := 0.04       # 点击音时长约 40ms
const CLICK_ACCENT_HZ := 1600.0    # 重音频率
const CLICK_WEAK_HZ := 900.0       # 弱拍频率
const CLICK_DECAY := 60.0          # 指数衰减：amp = exp(-t * 60)
const CLICK_PEAK := 0.85           # 峰值，留余量防削波
const CLICK_FADE_IN_SEC := 0.001   # 首部 1ms 淡入，防爆音
const CLICK_FADE_OUT_SEC := 0.003  # 尾部 3ms 淡出，防爆音
const SILENT_DB := -80.0           # click_volume 为 0 时的"静音"分贝

# ===== 状态（名字 / 类型与契约逐字一致）=====
var bpm: float = 120.0
var beats_per_bar: int = 4
var current_beat: int = 0          # 0-based，小节内位置
var bar_count: int = 0             # 已完整走过的小节数
var accent_first_beat: bool = true
var click_enabled: bool = true
var click_volume: float = 0.6      # 0.0 ~ 1.0

# ===== 信号 =====
signal tick(beat_index: int, is_accent: bool)
signal started()
signal stopped()

# ===== 内部状态（不属于公开契约）=====
var _running: bool = false                    # 是否正在走
var _accum: float = 0.0                       # 距上一拍累计的真实毫秒
var _last_msec: int = 0                       # 上次 _process 的真实时间戳
var _accent_player: AudioStreamPlayer = null  # 重音专用播放器
var _weak_player: AudioStreamPlayer = null    # 弱拍专用播放器
var _accent_stream: AudioStreamWAV = null     # 重音 PCM（缓存，只生成一次）
var _weak_stream: AudioStreamWAV = null       # 弱拍 PCM（缓存，只生成一次）


func _ready() -> void:
	# 生成并缓存两段点击音；两个 player 各持一段，避免换 stream 打断上一个点击音
	_accent_stream = _make_click_stream(CLICK_ACCENT_HZ)
	_weak_stream = _make_click_stream(CLICK_WEAK_HZ)

	_accent_player = AudioStreamPlayer.new()
	_accent_player.name = "AccentClick"
	_accent_player.stream = _accent_stream
	add_child(_accent_player)

	_weak_player = AudioStreamPlayer.new()
	_weak_player.name = "WeakClick"
	_weak_player.stream = _weak_stream
	add_child(_weak_player)

	_apply_click_volume()


func _process(_delta: float) -> void:
	# 只认真实时间差；_delta 在 headless 下极小且不稳定，不能用来计时
	if not _running:
		return

	var now := Time.get_ticks_msec()
	var elapsed := now - _last_msec
	_last_msec = now
	if elapsed <= 0:
		return

	_accum += float(elapsed)

	# 用 while 追帧：一次 _process 可能跨过多拍
	var period := _period_msec()
	while _accum >= period:
		_accum -= period
		trigger_tick()
		# 重算周期：监听者可能在 tick 回调里改了 bpm
		period = _period_msec()


# ===== 播放控制 =====

## 开始。先归零并置 _running，再发 started，最后立即 trigger_tick()（beat 0）。
## 顺序说明：先 started 后 tick，监听者可以"先初始化 UI，再收第一拍"。
func start() -> void:
	reset()                                  # 保证 start() 的首拍一定是 beat 0
	_running = true
	_accum = 0.0
	_last_msec = Time.get_ticks_msec()
	emit_signal("started")
	trigger_tick()


## 停止：置 _running 为假并发 stopped，随后归零。
## 之后 _process 直接 return，不会再 tick。
func stop() -> void:
	_running = false
	emit_signal("stopped")
	reset()


## 运行中则停止，否则开始
func toggle() -> void:
	if _running:
		stop()
	else:
		start()


## 是否正在走
func is_running() -> bool:
	return _running


# ===== 参数设置 =====

## 设置 BPM，夹到 20..300。运行中改 BPM 平滑生效：
## 不重置 current_beat / bar_count / _accum（_accum 已累计的时间保留）。
func set_bpm(v: float) -> void:
	bpm = clampf(v, MIN_BPM, MAX_BPM)


## 设置每小节拍数，夹到 1..12；current_beat 越界时夹回合法范围
func set_beats_per_bar(v: int) -> void:
	beats_per_bar = clampi(v, MIN_BEATS_PER_BAR, MAX_BEATS_PER_BAR)
	if current_beat >= beats_per_bar:
		current_beat = clampi(current_beat, 0, beats_per_bar - 1)


# ===== 拍点 =====

## 手动触发一次 tick（供测试与"点一下"用）。
## 顺序：先 emit（监听者拿到的是"本次"拍号），再自增，最后放点击音。
func trigger_tick() -> void:
	var is_accent := accent_first_beat and current_beat == 0

	emit_signal("tick", current_beat, is_accent)

	current_beat += 1
	if current_beat >= beats_per_bar:
		current_beat = 0
		bar_count += 1

	if click_enabled:
		_play_click(is_accent)


## 距下一次 tick 还有多少毫秒（供 UI 画节拍指示），至少 0
func msec_to_next_tick() -> int:
	return maxi(0, int(_period_msec() - _accum))


## 立即归零（停止时调用）
func reset() -> void:
	current_beat = 0
	bar_count = 0
	_accum = 0.0


# ===== 内部实现 =====

## 一拍的毫秒数
func _period_msec() -> float:
	# bpm 被 set_bpm 夹在 20..300，永不为 0
	return 60000.0 / bpm


## 播放一次点击音。各自独立 player，重音不会打断弱拍、弱拍不会打断重音。
func _play_click(is_accent: bool) -> void:
	var player := _accent_player if is_accent else _weak_player
	if player == null:
		return
	# 每次播放前刷新音量，这样 HUD 直接改 click_volume 也能立刻生效
	player.volume_db = _volume_db()
	# headless（Dummy 驱动）下 play() 可安全调用，不假设有真实设备
	player.play()


## click_volume(0..1) -> 分贝；0 用 -80（不调用 linear_to_db(0) 以免得到 -inf）
func _volume_db() -> float:
	if click_volume <= 0.0:
		return SILENT_DB
	return linear_to_db(clampf(click_volume, 0.0, 1.0))


func _apply_click_volume() -> void:
	var db := _volume_db()
	if _accent_player != null:
		_accent_player.volume_db = db
	if _weak_player != null:
		_weak_player.volume_db = db


## 代码生成一段点击音 PCM：44.1kHz / 16bit / 单声道 / 约 40ms / 正弦 + 指数衰减。
## 不引入任何外部音频文件，也不使用 AudioStreamGenerator。
func _make_click_stream(freq: float) -> AudioStreamWAV:
	var frame_count := int(CLICK_MIX_RATE * CLICK_DURATION)  # 1764 帧
	var data := PackedByteArray()
	data.resize(frame_count * 2)                             # 16bit 单声道 = 2 字节/帧

	for i in frame_count:
		var t := float(i) / float(CLICK_MIX_RATE)
		var amp := exp(-t * CLICK_DECAY) * _fade_envelope(i, frame_count)
		var sample := sin(TAU * freq * t) * amp * CLICK_PEAK
		var value := int(clampf(sample * 32767.0, -32768.0, 32767.0))
		data.encode_s16(i * 2, value)

	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = CLICK_MIX_RATE
	stream.stereo = false
	stream.data = data
	return stream


## 首尾淡入淡出包络（0..1），避免起止处爆音
func _fade_envelope(i: int, frame_count: int) -> float:
	var fade_in := int(CLICK_MIX_RATE * CLICK_FADE_IN_SEC)
	var fade_out := int(CLICK_MIX_RATE * CLICK_FADE_OUT_SEC)

	if fade_in > 0 and i < fade_in:
		return float(i) / float(fade_in)

	var remaining := frame_count - 1 - i
	if fade_out > 0 and remaining < fade_out:
		return maxf(0.0, float(remaining) / float(fade_out))

	return 1.0
