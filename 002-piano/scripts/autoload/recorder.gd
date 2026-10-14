extends Node
## Recorder（autoload 名：Recorder）
## 录制 / 回放演奏事件。公开接口与事件格式严格遵循 docs/INTERFACES.md 第 5 节。
##
## 事件字典固定五个键：
## { "t": int,          # 相对录制开始的毫秒
##   "type": String,    # "on" | "off" | "sustain"
##   "midi": int,       # type 为 sustain 时忽略，填 -1
##   "velocity": float, # type 为 on 时有效，其余填 0.0
##   "value": bool }    # type 为 sustain 时有效：true=踩下

## 默认存档路径
const DEFAULT_PATH := "user://recording.json"
## 存档格式版本
const FORMAT_VERSION := 1

## 录制的事件列表
var events: Array[Dictionary] = []

# ---------------- 内部状态 ----------------
var _recording: bool = false        # 是否正在录制
var _playing: bool = false          # 是否正在回放
var _suppress_record: bool = false  # 回放派发期间临时抑制录制写入
var _record_start_msec: int = 0     # 录制起点（Time.get_ticks_msec）
var _play_start_msec: int = 0       # 回放起点（Time.get_ticks_msec）
var _play_cursor: int = 0           # 下一个待派发事件的索引

# ---------------- 信号（与契约逐字一致）----------------
signal recording_started()
signal recording_stopped(event_count: int)
signal event_recorded(ev: Dictionary)
signal playback_started()
signal playback_finished()
signal playback_progress(msec: int)


func _ready() -> void:
	# PianoEngine 是 autoload，运行时一定存在；这里仍做防御式检查，
	# 以便并行开发期（引擎文件尚未落地）不会因为缺信号而报错。
	if PianoEngine.has_signal("note_started"):
		PianoEngine.note_started.connect(_on_piano_note_started)
	if PianoEngine.has_signal("note_stopped"):
		PianoEngine.note_stopped.connect(_on_piano_note_stopped)
	if PianoEngine.has_signal("sustain_changed"):
		PianoEngine.sustain_changed.connect(_on_piano_sustain_changed)
	set_process(true)


# ---------------- PianoEngine 信号回调 ----------------

## 只有"正在录制、且不在回放、且不在回放派发中"才允许写入事件。
func _can_write_event() -> bool:
	return is_recording() and not is_playing() and not _suppress_record


func _on_piano_note_started(midi: int, velocity: float) -> void:
	if not _can_write_event():
		return
	_append_event("on", midi, velocity, false)


func _on_piano_note_stopped(midi: int) -> void:
	if not _can_write_event():
		return
	_append_event("off", midi, 0.0, false)


func _on_piano_sustain_changed(on: bool) -> void:
	if not _can_write_event():
		return
	_append_event("sustain", -1, 0.0, on)


## 构造事件、追加进 events，并广播 event_recorded。
func _append_event(type: String, midi: int, velocity: float, value: bool) -> void:
	var ev := {
		"t": _record_offset_msec(),
		"type": type,
		"midi": midi,
		"velocity": velocity,
		"value": value,
	}
	events.append(ev)
	emit_signal("event_recorded", ev)


## 相对录制起点的毫秒数
func _record_offset_msec() -> int:
	return int(Time.get_ticks_msec() - _record_start_msec)


# ---------------- 录制 ----------------

func start_recording() -> void:
	# 正在回放就先停掉，避免"边放边录"
	if is_playing():
		stop_playback()
	events.clear()
	_suppress_record = false
	_record_start_msec = int(Time.get_ticks_msec())
	_recording = true
	emit_signal("recording_started")


func stop_recording() -> void:
	# 本来就没在录制：安全返回，且不发 recording_stopped（避免虚假信号）。
	if not _recording:
		return
	_recording = false
	emit_signal("recording_stopped", events.size())


func is_recording() -> bool:
	return _recording


# ---------------- 回放 ----------------

func start_playback() -> void:
	# 正在录制就先停止录制（不再继续写入事件）
	if is_recording():
		stop_recording()
	if events.is_empty():
		push_warning("Recorder.start_playback: 没有可回放的事件，忽略本次调用")
		return
	_playing = true
	_suppress_record = false
	_play_start_msec = int(Time.get_ticks_msec())
	_play_cursor = 0
	emit_signal("playback_started")


## 停止回放。注意：本方法**不发** playback_finished，
## 自然结束时的 playback_finished 由 _process() 在调用本方法之后统一发出，
## 从而保证该信号在一次回放中恰好只发一次。
func stop_playback() -> void:
	_playing = false
	_play_cursor = 0
	# all_notes_off() 可能同步触发 PianoEngine 的 note_stopped，
	# 这里同样临时抑制录制写入（保存并还原，保证可重入）。
	var prev_suppress := _suppress_record
	_suppress_record = true
	PianoEngine.all_notes_off()
	_suppress_record = prev_suppress


func is_playing() -> bool:
	return _playing


func _process(_delta: float) -> void:
	if not _playing:
		return

	var elapsed := int(Time.get_ticks_msec() - _play_start_msec)

	# 派发期间抑制录制：PianoEngine 的信号是同步回调的，
	# 若不抑制，回放自己产生的声音会被重新录进 events（自我循环）。
	_suppress_record = true
	while _play_cursor < events.size() and _to_int(events[_play_cursor].get("t", 0), 0) <= elapsed:
		_dispatch_event(events[_play_cursor])
		_play_cursor += 1
	_suppress_record = false

	# 每帧上报进度
	emit_signal("playback_progress", elapsed)

	# 所有事件派发完毕，且真实时间已越过总时长 -> 结束
	if _play_cursor >= events.size() and elapsed >= duration_msec():
		stop_playback()
		emit_signal("playback_finished")


## 把单个事件派发给 PianoEngine
func _dispatch_event(ev: Dictionary) -> void:
	match _to_str(ev.get("type", "on"), "on"):
		"on":
			PianoEngine.note_on(_to_int(ev.get("midi", -1), -1), _to_float(ev.get("velocity", 0.0), 0.0))
		"off":
			PianoEngine.note_off(_to_int(ev.get("midi", -1), -1))
		"sustain":
			PianoEngine.set_sustain(_to_bool(ev.get("value", false), false))
		_:
			pass  # 非法 type：静默跳过，不崩溃


# ---------------- 查询 / 清理 ----------------

func clear() -> void:
	events.clear()


## 最后一个事件的时间戳；空列表返回 0（契约要求，不留尾巴）。
func duration_msec() -> int:
	if events.is_empty():
		return 0
	return _to_int(events[-1].get("t", 0), 0)


func event_count() -> int:
	return events.size()


# ---------------- 存档 / 读档 ----------------

func to_dict() -> Dictionary:
	return {
		"version": FORMAT_VERSION,
		"duration_msec": duration_msec(),
		"events": events,
	}


func save_to_file(path: String = DEFAULT_PATH) -> Error:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("Recorder.save_to_file: 无法写入 %s" % path)
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(to_dict(), "\t"))
	f.close()
	return OK


func load_from_file(path: String = DEFAULT_PATH) -> Error:
	if not FileAccess.file_exists(path):
		push_warning("Recorder.load_from_file: 文件不存在 %s" % path)
		return ERR_FILE_NOT_FOUND
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("Recorder.load_from_file: 无法读取 %s" % path)
		return FileAccess.get_open_error()
	var text := f.get_as_text()
	f.close()

	var parsed: Variant = JSON.parse_string(text)
	if parsed == null:
		push_warning("Recorder.load_from_file: JSON 解析失败 %s" % path)
		return ERR_PARSE_ERROR
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("Recorder.load_from_file: 顶层不是 Dictionary %s" % path)
		return ERR_PARSE_ERROR
	var data: Dictionary = parsed
	return from_dict(data)


## 从字典导入事件。任何非法输入都返回错误而不是崩溃。
func from_dict(d: Dictionary) -> Error:
	if not d.has("events"):
		push_warning("Recorder.from_dict: 缺少 events 字段")
		return ERR_PARSE_ERROR
	if typeof(d["events"]) != TYPE_ARRAY:
		push_warning("Recorder.from_dict: events 不是数组")
		return ERR_PARSE_ERROR
	if not d.has("version"):
		push_warning("Recorder.from_dict: 缺少 version 字段")
		return ERR_PARSE_ERROR
	var ver_type := typeof(d["version"])
	if ver_type != TYPE_INT and ver_type != TYPE_FLOAT:
		push_warning("Recorder.from_dict: version 类型非法")
		return ERR_PARSE_ERROR
	if int(d["version"]) > FORMAT_VERSION:
		push_warning("Recorder.from_dict: version 高于 FORMAT_VERSION，拒绝读取")
		return ERR_PARSE_ERROR

	var raw_events: Array = d["events"]
	events.clear()
	for raw in raw_events:
		if typeof(raw) != TYPE_DICTIONARY:
			continue  # 非字典元素跳过
		var src: Dictionary = raw
		var type_str := _to_str(src.get("type", "on"), "on")
		if type_str != "on" and type_str != "off" and type_str != "sustain":
			continue  # 非法 type 跳过
		# 规范化成契约里的五个键，缺键给默认值
		events.append({
			"t": _to_int(src.get("t", 0), 0),
			"type": type_str,
			"midi": _to_int(src.get("midi", -1), -1),
			"velocity": _to_float(src.get("velocity", 0.0), 0.0),
			"value": _to_bool(src.get("value", false), false),
		})
	return OK


# ---------------- 类型安全的小工具 ----------------
# 说明：JSON 里的值类型完全不可信，直接 int()/float()/bool() 强转 Dictionary 等类型
# 会触发引擎错误。这里统一做白名单转换，保证 load_from_file 永不崩溃。

static func _to_int(v: Variant, def_value: int) -> int:
	match typeof(v):
		TYPE_INT, TYPE_FLOAT, TYPE_BOOL:
			return int(v)
		TYPE_STRING, TYPE_STRING_NAME:
			var s := String(v)
			if s.is_valid_int():
				return s.to_int()
			if s.is_valid_float():
				return int(s.to_float())
			return def_value
		_:
			return def_value


static func _to_float(v: Variant, def_value: float) -> float:
	match typeof(v):
		TYPE_INT, TYPE_FLOAT, TYPE_BOOL:
			return float(v)
		TYPE_STRING, TYPE_STRING_NAME:
			var s := String(v)
			if s.is_valid_float():
				return s.to_float()
			return def_value
		_:
			return def_value


static func _to_bool(v: Variant, def_value: bool) -> bool:
	match typeof(v):
		TYPE_BOOL:
			return bool(v)
		TYPE_INT, TYPE_FLOAT:
			return float(v) != 0.0
		TYPE_STRING, TYPE_STRING_NAME:
			var s := String(v).strip_edges().to_lower()
			if s == "true" or s == "1" or s == "yes" or s == "on":
				return true
			if s == "false" or s == "0" or s == "no" or s == "off":
				return false
			return def_value
		_:
			return def_value


static func _to_str(v: Variant, def_value: String) -> String:
	match typeof(v):
		TYPE_STRING, TYPE_STRING_NAME:
			return String(v)
		_:
			return def_value
