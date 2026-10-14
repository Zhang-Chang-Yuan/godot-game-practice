class_name MusicTheory
extends RefCounted
# 纯静态乐理工具：MIDI 号 <-> 音名 <-> 采样文件名
# 全项目唯一的"音高字典"，任何模块都不许自己再写一套换算。

const MIDI_LOWEST := 21    # A0
const MIDI_HIGHEST := 108  # C8
const KEY_COUNT := 88      # 108 - 21 + 1

const NOTE_NAMES := ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

# 白键的半音位置（C D E F G A B）
const WHITE_PITCH_CLASSES := [0, 2, 4, 5, 7, 9, 11]


## MIDI 号 -> 显示名，例如 21 -> "A0"，22 -> "A#0"，60 -> "C4"，108 -> "C8"
static func midi_to_name(midi: int) -> String:
	return NOTE_NAMES[pitch_class(midi)] + str(octave_of(midi))


## 显示名 -> MIDI 号，midi_to_name 的逆运算；无法解析返回 -1
## 兼容 '#' 与 's' 两种升号写法（"A#0" 与 "As0" 都认）
static func name_to_midi(name: String) -> int:
	var text := name.strip_edges()
	if text.length() < 2:
		return -1

	var letter := text.substr(0, 1).to_upper()
	var rest := text.substr(1)

	var is_sharp := false
	if rest.begins_with("#") or rest.begins_with("s") or rest.begins_with("S"):
		is_sharp = true
		rest = rest.substr(1)

	# 在 NOTE_NAMES 里找匹配的音级
	var found := -1
	for i in NOTE_NAMES.size():
		var note_name: String = NOTE_NAMES[i]
		if note_name.substr(0, 1) != letter:
			continue
		var name_is_sharp := note_name.length() > 1
		if name_is_sharp != is_sharp:
			continue
		found = i
		break

	if found == -1 or not rest.is_valid_int():
		return -1

	return (rest.to_int() + 1) * 12 + found


## 是否黑键（升号音）
static func is_black_key(midi: int) -> bool:
	return not WHITE_PITCH_CLASSES.has(pitch_class(midi))


## 文件名安全的音名：把 '#' 换成 's'，例如 22 -> "As0"（'#' 在资源路径里不安全）
static func midi_to_filename(midi: int) -> String:
	return midi_to_name(midi).replace("#", "s")


## 采样资源路径：res://audio/piano/<filename>.mp3
static func sample_path(midi: int) -> String:
	return "res://audio/piano/" + midi_to_filename(midi) + ".mp3"


## 八度号，例如 21 -> 0，60 -> 4，108 -> 8
static func octave_of(midi: int) -> int:
	return midi / 12 - 1


## 该音在"白键序列"里的下标（从 A0 数起，0-based）；黑键返回 -1
static func white_index_of(midi: int) -> int:
	if is_black_key(midi):
		return -1
	var count := 0
	for m in range(MIDI_LOWEST, midi):
		if not is_black_key(m):
			count += 1
	return count


## 白键总数（固定 52）
static func white_key_count() -> int:
	var count := 0
	for m in range(MIDI_LOWEST, MIDI_HIGHEST + 1):
		if not is_black_key(m):
			count += 1
	return count


## 该音所在八度内是第几个半音（0..11），C = 0
static func pitch_class(midi: int) -> int:
	return midi % 12


## 该音是否在 88 键合法范围
static func is_valid_midi(midi: int) -> bool:
	return midi >= MIDI_LOWEST and midi <= MIDI_HIGHEST
