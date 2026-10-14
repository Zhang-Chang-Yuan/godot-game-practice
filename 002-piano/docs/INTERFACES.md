# 002-piano 接口契约（所有子 Agent 必须严格遵守）

> 本文件是**唯一事实来源**。任何实现都不得修改这里的公开签名、信号名、节点路径、文件命名。
> 如需变更，必须先提出，由主 Agent 统一修改本文件。

引擎：**Godot 4.7.2 stable**（`C:\Hub\program\godot-4\Godot_v4.7.2-stable_win64.exe`）
工程根：`C:\Hub\workspace\godot-game-practice\002-piano\`
缩进：**Tab**（与 001 工程一致）。注释：**中文**。

---

## 0. 目录结构（固定）

```
002-piano/
├── project.godot
├── README.md
├── LICENSES.md                  # 音频来源与授权
├── audio/piano/                 # 88 个采样：A0.mp3 As0.mp3 B0.mp3 C1.mp3 ... C8.mp3
├── docs/INTERFACES.md           # 本文件
├── scenes/
│   └── main.tscn                # 唯一场景，根节点 Main(Control) 挂 scripts/main.gd
├── scripts/
│   ├── music_theory.gd          # class_name MusicTheory（纯静态，无节点）
│   ├── main.gd                  # 装配 Keyboard + HUD
│   ├── keyboard.gd              # 88 键键盘（Control）
│   ├── piano_key.gd             # 单个琴键（Control）
│   ├── hud.gd                   # 顶栏：节拍器 / 录制 / 延音 / 音量
│   └── autoload/
│       ├── piano_engine.gd      # autoload 名：PianoEngine
│       ├── metronome.gd         # autoload 名：Metronome
│       └── recorder.gd          # autoload 名：Recorder
└── tests/
    ├── test_scene.tscn          # 测试入口场景，挂 tests/test_runner.gd
    └── test_runner.gd           # headless 断言驱动
```

## 1. project.godot 关键配置（不得随意改动）

```ini
[application]
config/name="Piano 88"
run/main_scene="res://scenes/main.tscn"
config/features=PackedStringArray("4.7", "GL Compatibility")

[autoload]
PianoEngine="*res://scripts/autoload/piano_engine.gd"
Metronome="*res://scripts/autoload/metronome.gd"
Recorder="*res://scripts/autoload/recorder.gd"

[display]
window/size/viewport_width=1280
window/size/viewport_height=720
window/stretch/mode="canvas_items"
window/stretch/aspect="expand"

[rendering]
renderer/rendering_method="gl_compatibility"
renderer/rendering_method.mobile="gl_compatibility"
```

**注意**：`run/main_scene` 与 autoload 一律用 `res://` 路径，**不要**写 `uid://`（避免手写 UID 出错）。
`MusicTheory` 用 `class_name` 暴露，**不注册 autoload**。

---

## 2. MusicTheory（`scripts/music_theory.gd`，`class_name MusicTheory`）

纯静态工具，`extends RefCounted`。全部方法为 `static`。

```gdscript
class_name MusicTheory
extends RefCounted

const MIDI_LOWEST  := 21    # A0
const MIDI_HIGHEST := 108   # C8
const KEY_COUNT    := 88    # 108 - 21 + 1

const NOTE_NAMES := ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

## MIDI 号 -> 显示名，例如 21 -> "A0"，22 -> "A#0"，108 -> "C8"
static func midi_to_name(midi: int) -> String

## 显示名 -> MIDI 号，midi_to_name 的逆运算
static func name_to_midi(name: String) -> int

## 是否黑键（升号音）
static func is_black_key(midi: int) -> bool

## 文件名安全的音名：把 '#' 换成 's'，例如 22 -> "As0"
static func midi_to_filename(midi: int) -> String

## 采样资源路径：res://audio/piano/<filename>.mp3
static func sample_path(midi: int) -> String

## 八度号，例如 21 -> 0，60 -> 4，108 -> 8
static func octave_of(midi: int) -> int

## 该音在"白键序列"里的下标；黑键返回 -1
static func white_index_of(midi: int) -> int

## 白键总数（固定 52）
static func white_key_count() -> int

## 该音所在八度内是第几个半音（0..11），C=0
static func pitch_class(midi: int) -> int

## 该音是否在合法范围
static func is_valid_midi(midi: int) -> bool
```

**必须满足的边界**：`midi_to_name(21) == "A0"`、`midi_to_name(108) == "C8"`、`midi_to_name(60) == "C4"`、
`midi_to_filename(22) == "As0"`、`name_to_midi(midi_to_name(m)) == m` 对 21..108 全部成立。

---

## 3. PianoEngine（autoload `PianoEngine`，`scripts/autoload/piano_engine.gd`）

复音发声引擎 + 延音踏板。`extends Node`。

### 常量
```gdscript
const POLYPHONY := 32              # 同时发声上限
const SAMPLE_FORMAT := "mp3"       # audio/piano/ 下的扩展名
const RELEASE_FADE_SEC := 0.06     # 松键淡出，防爆音
```

### 状态（只读约定）
```gdscript
var master_volume: float = 0.8     # 0.0 ~ 1.0
var sustain_enabled: bool = false  # 延音踏板
var sustain_loop_enabled: bool = false  # 延音时循环采样尾音（增强长延音）
```

### 信号
```gdscript
signal note_started(midi: int, velocity: float)
signal note_stopped(midi: int)
signal sustain_changed(on: bool)
signal voice_stealed(midi: int)     # 复音数用尽被抢占时
```

### 方法
```gdscript
## 发声。velocity 0.0~1.0。重复 note_on 同一音应先停旧声再起新声。
func note_on(midi: int, velocity: float = 0.8) -> void

## 松键。若 sustain_enabled 为真，则不立即停声，进入"待释放"状态。
func note_off(midi: int) -> void

## 切换延音踏板。关闭时立刻释放所有"待释放"的音。
func set_sustain(on: bool) -> void

## 立即停掉所有发声，清空所有状态
func all_notes_off() -> void

## 该音当前是否在发声（含待释放）
func is_note_active(midi: int) -> bool

## 当前活跃声部数
func active_voice_count() -> int

## 当前被延音踏板挂住的音（待释放）
func sustained_note_count() -> int

## 设置总音量 0.0~1.0
func set_master_volume(v: float) -> void

## 加载采样，返回 AudioStream；失败返回 null。内部应缓存。
func get_stream(midi: int) -> AudioStream
```

### 硬性要求
1. **逻辑状态必须独立于 `AudioStreamPlayer.playing`**：引擎自己维护 `_active: Dictionary[int -> VoiceInfo]`，
   `is_note_active()` / `active_voice_count()` 只读这个字典。这样 **headless（Dummy 音频驱动）下断言依然成立**。
2. **必须在 headless 下不报错**：不得假设有真实音频设备。
3. 复音数用满时，抢占**最早触发**的声部，并发出 `voice_stealed`。
4. 采样文件缺失时：`push_warning` 并静默跳过，**不得崩溃**。
5. 停声走 `RELEASE_FADE_SEC` 的 Tween 淡出，再 `stop()` 并回收声部。
6. `note_on` 的合法范围外 midi（<21 或 >108）直接忽略并 `push_warning`。
7. 声部池在 `_ready()` 里预建 `POLYPHONY` 个 `AudioStreamPlayer` 子节点，命名 `Voice0..Voice31`。
8. **电平补偿与总线限制器**（实现中新增，契约同步收录）：
   - 声部增益 `_VOICE_GAIN := 2.0`（+6.02 dB）。原因：FluidR3_GM 采样被母带处理得极保守，
     实测原始峰值仅 **0.0889（−21.0 dBFS）**；若不补偿，用户把总音量拉满也只有 −21 dBFS。
   - `_velocity_to_db(v)` 返回 `linear_to_db(maxf(v * _VOICE_GAIN, 0.0001))`。
     **不得把 `v * _VOICE_GAIN` 夹到 1.0**，否则满力度得不到任何增益
     （`linear_to_db` 接受 >1.0 的输入并返回正分贝）。
   - `_ready()` 里调用 `_install_limiter()`：在 **AudioServer 总线 0（Master）** 上挂
     `AudioEffectHardLimiter`（`ceiling_db = -1.0`），兜住密集和弦的叠加峰值。
     用 `ClassDB.class_exists()` + `get_class()` 字符串比对做版本探测与幂等，缺失时静默降级。
   - **跨模块副作用声明**：这是给全局 Master 总线挂效果，会影响该总线上的一切声音
     （包括 `Metronome` 的点击音）。
   - 实测电平（默认音量 0.8）：单音 **0.177**、三音和弦 **0.348**、八音和弦 **0.614**（天花板 −1 dB = 0.891）。

---

## 4. Metronome（autoload `Metronome`，`scripts/autoload/metronome.gd`）

`extends Node`。**必须用真实时间**（`Time.get_ticks_msec()` 累加），不得按帧计数——headless 帧率极高。

### 状态
```gdscript
var bpm: float = 120.0
var beats_per_bar: int = 4
var current_beat: int = 0     # 0-based，小节内位置
var bar_count: int = 0        # 已完整走过的小节数
var accent_first_beat: bool = true
var click_enabled: bool = true
var click_volume: float = 0.6
```

### 信号
```gdscript
signal tick(beat_index: int, is_accent: bool)
signal started()
signal stopped()
```

### 方法
```gdscript
func start() -> void
func stop() -> void
func toggle() -> void
func is_running() -> bool
func set_bpm(v: float) -> void          # 夹到 20..300
func set_beats_per_bar(v: int) -> void  # 夹到 1..12
## 手动触发一次 tick（供测试与"点一下"用）
func trigger_tick() -> void
## 距下一次 tick 还有多少毫秒（供 UI 画节拍指示）
func msec_to_next_tick() -> int
## 立即归零（停止时调用）
func reset() -> void
```

### 硬性要求
1. `_process(delta)` 里用 `Time.get_ticks_msec()` 的真实差值累加，累计 ≥ `60000.0/bpm` 就 `trigger_tick()` 并扣除周期（用 `while` 处理追帧）。
2. `set_bpm` 在运行中生效，且**不重置**当前小节位置。
3. `start()` 后**立即**发一次 tick（beat 0），随后按周期发。`stop()` 重置 `current_beat`/`bar_count`。
4. 点击音：用 `AudioStreamGenerator`? **不要**。用一个短促的 `AudioStreamWAV`，在代码里生成正弦/方波 PCM（44.1kHz、单声道、约 40ms、带指数衰减），重音 1600Hz、弱拍 900Hz。生成函数放在 metronome.gd 内。
5. headless 下 `trigger_tick()` 必须照常发信号。

---

## 5. Recorder（autoload `Recorder`，`scripts/autoload/recorder.gd`）

`extends Node`。录制/回放演奏事件。

### 事件格式（固定）
```gdscript
# 每个事件是 Dictionary：
# { "t": int,        # 相对录制开始的毫秒
#   "type": String,  # "on" | "off" | "sustain"
#   "midi": int,     # type 为 sustain 时忽略，填 -1
#   "velocity": float, # type 为 on 时有效，其余填 0.0
#   "value": bool }  # type 为 sustain 时有效：true=踩下
```

### 状态
```gdscript
var events: Array[Dictionary] = []
const DEFAULT_PATH := "user://recording.json"
const FORMAT_VERSION := 1
```

### 信号
```gdscript
signal recording_started()
signal recording_stopped(event_count: int)
signal event_recorded(ev: Dictionary)
signal playback_started()
signal playback_finished()
signal playback_progress(msec: int)
```

### 方法
```gdscript
func start_recording() -> void      # 清空 events，记录起点；若正在回放先 stop_playback()
func stop_recording() -> void
func is_recording() -> bool
func start_playback() -> void       # 从 t=0 重放；若正在录制先 stop_recording()
func stop_playback() -> void
func is_playing() -> bool
func clear() -> void
func duration_msec() -> int
func event_count() -> int
func save_to_file(path: String = DEFAULT_PATH) -> Error
func load_from_file(path: String = DEFAULT_PATH) -> Error
func to_dict() -> Dictionary        # { "version": 1, "duration_msec": int, "events": [...] }
func from_dict(d: Dictionary) -> Error
```

### 硬性要求
1. `_ready()` 里连接 `PianoEngine.note_started` / `note_stopped` / `sustain_changed`，**仅当 `is_recording()` 为真**时把事件追加进 `events` 并 `emit_signal("event_recorded", ev)`。
2. **回放期间绝不录制**（否则自我循环）；`is_playing()` 为真时忽略录制写入。
3. 回放用真实时间驱动（`Time.get_ticks_msec()`），在 `_process` 里把到点的事件派发给 `PianoEngine`，派发时需临时抑制录制（见 2）。
4. `stop_recording()` 时发 `recording_stopped(events.size())`。
5. 回放结束发 `playback_finished()`，并 `PianoEngine.all_notes_off()`。
6. `save_to_file` / `load_from_file` 用 `JSON.stringify` / `JSON.parse_string`，UTF-8，失败返回对应 `Error`。
7. `load_from_file` 必须校验 `version` 与 `events` 存在，损坏文件返回 `ERR_PARSE_ERROR`，不得崩溃。
8. **`t` 是「非递减」，不是「严格递增」**（设计局限，明确接受）：
   `t` 取 `Time.get_ticks_msec()`，毫秒分辨率下同一毫秒内的 `note_on` + `note_off` 会得到**相等**的 `t`
   （实测 20/20 次 `t0 == t1`）。事件因果顺序仍由数组下标保证，回放时同毫秒事件在同一帧内按序派发。
   后果：整段都落在同一毫秒的极短片段，`duration_msec() == 0`。
   **写测试时不要在无等待的情况下断言 `t2 > t1`**；要断言严格递增，必须先用真实时间自旋跨过毫秒边界。

---

## 6. Keyboard（`scripts/keyboard.gd`，`extends Control`）

88 键键盘，**全部在代码里生成**，不使用手写 .tscn 子节点。

### 常量/状态
```gdscript
const WHITE_KEY_WIDTH := 36.0
const WHITE_KEY_HEIGHT := 220.0
const BLACK_KEY_WIDTH_RATIO := 0.62
const BLACK_KEY_HEIGHT_RATIO := 0.62
var white_key_width: float = WHITE_KEY_WIDTH
var fit_to_width: bool = false      # true 时按可用宽度缩放 white_key_width
```

### 信号
```gdscript
signal key_pressed(midi: int)
signal key_released(midi: int)
```

### 方法
```gdscript
## 构建 88 个键（幂等，可重复调用）
func build() -> void
## 拿到某个 midi 对应的琴键节点，无则 null
func get_key(midi: int) -> Control
## 程序化按下/松开：必须转发到 PianoEngine.note_on/note_off
func press_note(midi: int, velocity: float = 0.8) -> void
func release_note(midi: int) -> void
## 高亮某个音（供回放时显示）
func set_note_highlight(midi: int, on: bool) -> void
## 电脑键盘映射开关
var computer_keyboard_enabled: bool = true
```

### 硬性要求
1. `custom_minimum_size.x = 52 * white_key_width`，高度 = `WHITE_KEY_HEIGHT`。
2. 黑键必须**叠在白键交界处**（z_index 高于白键），不能占白键位置。
3. 鼠标：按下发声、松开停声；**按住拖动经过其他键要连奏（glissando）**，同一时刻只允许一个鼠标音。
4. 电脑键盘映射（默认开启）：`Z S X D C V G B H N J M` → C4..B4，`Q 2 W 3 E R 5 T 6 Y 7 U` → C5..B5，`,` `L` `.` `;` `/` → C6..E6。
5. `press_note` / `release_note` 是**测试与回放唯一入口**，必须调用 `PianoEngine` 并 `emit_signal`。
6. 不得吞掉 `Metronome` / `Recorder` 的输入；键盘只管音符。
7. 键帽要显示音名（白键在底部、黑键在键内），字号自适应，`white_key_width < 22` 时隐藏文字。

---

## 7. HUD（`scripts/hud.gd`，`extends Control`）

顶栏控制面板，代码生成控件。必须包含：

- **节拍器**：开关按钮、BPM 数值显示、`-`/`+`（±5）、Slider(20~300)、拍号选择（2/4 3/4 4/4 6/8）、
  节拍指示灯（每拍闪一下，重音不同色）、Tap Tempo 按钮。
- **延音**：踏板开关按钮（也响应空格键与鼠标右键），开启时按钮高亮，显示"延音 ON/OFF"。
- **录制**：`● 录制` / `■ 停止` / `▶ 回放` / `⏹ 停止回放` / `清空` / `保存` / `载入` 按钮，
  显示事件数与时长。
- **音量**：Slider(0~100) → `PianoEngine.set_master_volume`。
- 状态栏：显示当前活跃声部数 `active_voice_count()`、回放进度。

### 硬性要求
1. 所有控件由代码创建，`hud.gd` 不依赖任何手写 .tscn 子节点。
2. 键盘快捷键：
   - `Space` = 延音踏板开关
   - **`Ctrl+R`** = 录制/停止录制切换
   - **`Ctrl+P`** = 回放/停止回放切换

   **必须带 Ctrl 修饰键**，原因（主 Agent 已实测确认的冲突）：
   第 6 节的音符映射里 **`R` 是 F5（MIDI 77）**（上行 `Q 2 W 3 E R 5 T 6 Y 7 U` = C5..B5）。
   如果 HUD 用裸 `R`，因为 `_input` 早于 `_unhandled_input`，`R` 键将永远弹不出 F5。
   `keyboard.gd` 已经用 `not ke.is_command_or_control_pressed()` 守卫了发声，所以 `Ctrl+R` 不会触发音符，
   两边可以干净共存。判定请用 `key_event.is_command_or_control_pressed()`（跨平台，不要只判 `ctrl_pressed`）。
   （`Space` 与 `P` 与音符映射无冲突，`P` 本就不在映射里，但为一致性 `P` 也统一加 Ctrl。）
3. 不得崩溃：控件引用的 autoload 若不存在要能降级。

---

## 8. main.gd（`scripts/main.gd`，`extends Control`）

装配根场景。要求：
1. 创建背景、标题栏（"Piano 88"）、`Keyboard` 实例、`HUD` 实例，布局合理（键盘在下方，HUD 在上方）。
2. 键盘放进 `ScrollContainer`（水平滚动）以容纳 52 个白键；提供"适应宽度"开关。
3. 连接 **`PianoEngine.note_started` / `note_stopped`** 到 `Keyboard.set_note_highlight`，
   让"正在发声的音"（含被延音挂住的）实时点亮琴键。
   ——**不是**连 `Recorder.playback_*`：连引擎信号才能同时覆盖**实时演奏**与**回放**两条路径；
   且 `Recorder.stop_playback()` 内部会调 `all_notes_off()`，高亮能随之正确熄灭。
4. 窗口缩放时重排（`_notification(NOTIFICATION_RESIZED)` 或 `resized` 信号）。
5. **`Esc` = 全部停音（紧急制动）**：在 `_unhandled_input` 里处理，调用 `PianoEngine.all_notes_off()`。
   **语义边界（对外文案必须一致）**：它只掐掉所有正在发声的音（含被延音挂住的），
   **不会**停止节拍器、也**不会**停止录制或回放。因此不要把它写成"全部停止"。

---

## 9. tests/test_runner.gd（`extends Node`，挂在 `tests/test_scene.tscn`）

运行方式（由测试子 Agent 最终确认）：
```powershell
& "C:\Hub\program\godot-4\Godot_v4.7.2-stable_win64_console.exe" --headless --path "C:\Hub\workspace\godot-game-practice\002-piano" res://tests/test_scene.tscn
```

要求：
1. 自建断言函数 `_check(cond: bool, label: String)`，统计 pass/fail，**全部打印**到 stdout。
2. 结束时打印 `TESTS: <pass>/<total> passed`，有失败则 `get_tree().quit(1)`，否则 `quit(0)`。
3. 覆盖四大功能的**行为**，而不是只检查节点存在。至少包含：
   - MusicTheory：88 个音名往返、边界值、黑键判定、白键总数 52、文件名无 `#`。
   - 音频资源：88 个 `sample_path()` 文件全部 `ResourceLoader.exists()`；`get_stream()` 非 null。
   - PianoEngine：`note_on` 后 `is_note_active` 为真且 `active_voice_count()==1`；`note_off` 后（无延音）释放；
     开延音后 `note_off` 仍 active 且 `sustained_note_count()>=1`；关延音后立刻释放；
     复音上限：连发 40 个不同音，`active_voice_count() <= POLYPHONY`；重复 `note_on` 同音不叠加计数。
   - Metronome：`set_bpm(600)` 后 **`bpm` 必须等于 300.0**（验证上夹生效）；
     `set_bpm(300)`（周期 200ms）后 `start()`，`start()` 会**立即**发出第 1 拍，
     再等 ~1.1 秒真实时间，`tick` 信号累计次数应 **≥ 5**（理论值 6：t=0/200/400/600/800/1000ms）。
     不要断言 `== 6`，真实计时器有抖动；也不要指望更高拍数——`MAX_BPM` 就是 300。
     `beats_per_bar = 3` 时，第 0、3、6… 拍 `is_accent` 为真，其余为假（可用 `trigger_tick()` 手动连发 6 次来断言，避免等真实时间）。
     `stop()` 后 `is_running()` 为假，且再等 300ms 内不得有新 tick。
   - Recorder：录制期间 `note_on`+`note_off` 产生 2 条事件且 `t` 递增；`duration_msec()>0`；
     `save_to_file` 再 `load_from_file` 后 `event_count()` 一致；损坏 JSON 返回错误不崩溃；
     回放期间不产生新事件。
   - Keyboard：`build()` 后 88 个键节点存在；`press_note(60)` 使 `PianoEngine.is_note_active(60)` 为真。
4. **等待真实时间必须自旋；不要用 `create_timer` 等短间隔，也不要数帧**：
   ```gdscript
   var t0 := Time.get_ticks_msec()
   while Time.get_ticks_msec() - t0 < 50:
       await get_tree().process_frame
   ```
   原因（实测）：headless 下**首帧的 `create_timer(0.05)` 只走了 0~2ms 真实时间**
   （首帧 delta 含引擎启动耗时），用它做"等 50ms 让时间戳递增"这类断言会**随机失败**
   （实测出现过 `0 -> 0`）。等待**较长**时间（1 秒以上）时 `create_timer` 是可用的。
   > 本条原先错误地要求"必须用 `create_timer`"——已按实测修正（见 README 踩坑第 5 条）。
5. 测试结束前调用 `PianoEngine.all_notes_off()`、`Metronome.stop()`、`Recorder.stop_playback()`。

---

### 9.1 重要：`--check-only` 的已知假阴性（主 Agent 已实测确认）

```
godot --headless --path . --check-only --script res://xxx.gd
```

这个命令**不能**用来验证引用了 autoload 裸标识符的脚本。它只加载单个脚本、不实例化 autoload，
因此 `PianoEngine.xxx` / `Metronome.xxx` / `Recorder.xxx` 会被报成
`Compile Error: Identifier not found: PianoEngine`——**这是假阴性，不是代码错误**。

实测证据：`001-learn-about-geometry`（已验收、可正常运行的工程）的 `scripts/quiz.gd` 里
`GameState.questions` 是正确用法，用同样的命令检查却报 `Identifier not found: GameState`。

**结论**：
- `--check-only` 只对**不引用 autoload 的脚本**（如 `music_theory.gd`、`piano_key.gd`）有参考价值。
- 引用 autoload 的脚本（`keyboard.gd`、`hud.gd`、三个 autoload 之间互相引用）**必须**用完整工程运行来验证：
  `godot --headless --path . res://tests/test_scene.tscn`
- 遇到 `Identifier not found: <autoload 名>` 时**不要**改写成 `get_node("/root/...")`，裸标识符是正确惯用写法。

### 9.2 重要：Godot 进程退出码不可靠

Godot 在发生 `SCRIPT ERROR` / `ERROR: Failed to load resource` 时**仍然返回退出码 0**（实测）。
所以：
- 测试驱动必须自己 `get_tree().quit(1)` 才能让退出码为 1；
- 判断"工程是否干净启动"**必须同时**检查 stdout/stderr 里有没有 `SCRIPT ERROR` / `ERROR:`，
  不能只看 `$LASTEXITCODE`。

### 9.3 致命陷阱：测试函数不 `await` 会得到「假绿」（实测踩过）

在 `_ready()` 里调用测试函数时**必须 `await`**：

```gdscript
func _ready() -> void:
	await _test_music_theory()    # 正确
	await _test_piano_engine()
	await _test_metronome()
	await _test_recorder()
	await _test_keyboard()
	await _test_audio_resources()
	_finish()
```

若写成 `_test_music_theory()`（不 `await`），协程会**永久停在测试函数里的第一个 `await` 处**；
`_ready()` 一旦正常返回，本次运行就立刻结束——**退出码 0、无 `SCRIPT ERROR`、无任何报错**，
而尚未执行的断言**根本不会计入总数**。

实测证据：本工程测试套件的某一版打印了 `TESTS: 76/76 passed` + `ALL PASS` + 退出码 0，
实际上整个 Keyboard 段的 **18 条断言一条都没跑**，Recorder / Metronome 段也只跑了第一行就断。
隔离探针复现：同结构下 5 个 `await` 全部停在第一次让出，进程 0.3 秒退出、退出码 0；
改成逐个 `await` 后全部恢复，总耗时 1.42 秒。

**防御措施（本工程已采用，写测试时必须照做）**：
1. `_ready()` 里逐个 `await` 所有测试函数，让 `_ready()` 全程挂起，main loop 才会推进帧；
2. 驱动把全部断言**双写**到 `user://test_runner.log`，便于事后核对；
3. **只有确实执行到汇总行时才允许退出码为 0**（用 `_finished` 标志守卫）——
   这样"提前退出"会被报成失败，而不是伪装成全绿。

> 推论：`TESTS: x/y passed` 里的 `y` 本身也可能是错的（少算了没跑的部分）。
> 判断测试是否真的跑完，要看**总耗时**是否与套件内的真实等待时间吻合
> （本套件含 2.4s + 0.5s 自旋等待，实测约 3.3s 才合理）。

### 9.4 禁止同义反复断言：边界值必须用**字面量**（实测发现的真实漏洞）

**不要拿被测量的那个常量去和它自己比。**

```gdscript
# ✗ 同义反复：把 POLYPHONY 改成 8，这两条断言照样成立
_check(PianoEngine.active_voice_count() <= PianoEngine.POLYPHONY, "...")
_eq(voice_nodes, PianoEngine.POLYPHONY, "...")

# ✓ 字面量：常量一旦被改就会失败
_eq(PianoEngine.active_voice_count(), 32, "...")
_eq(voice_nodes, 32, "...")
```

**这是变异测试实测发现的漏洞**：把 `POLYPHONY` 从 32 改成 8（变异 M2）后，
上面两条同义反复断言**全部通过**（`TESTS: 132/132 passed`）——
即"复音上限"这个特性**完全没有被测试保护**。改成字面量后，同一个变异立即产生 3 条失败。

**通则**：
1. 任何"边界 / 上限 / 容量"类断言，期望值一律写**字面量**；
2. 额外断言**超出边界时的可观测行为**，而不只是"没超"——
   本项目补了 `voice_stealed` 触发次数 `== 8`、以及首个被抢占的是最早触发的 21 号（验证 FIFO 抢占策略）；
3. **写完测试要用变异测试自证不空洞**：故意改坏被测行为，确认测试**会失败**，然后还原。
   没被任何变异杀死的断言，等于没写。

## 10. 通用纪律

- 只改**分配给你的文件**。不要动别人的文件、不要动 `project.godot`（除非任务明确要求）。
- 不要引入任何第三方 Godot 插件。
- 不要手写 `uid://`；`.tscn` 里引用脚本用 `path="res://..."`。
- 提交前自检：`godot --headless --path . --quit` 必须退出码 0 且无 `SCRIPT ERROR` / `Parse Error`。
- 音频采样文件名**必须**符合 `MusicTheory.midi_to_filename()`（如 `As0.mp3`、`C4.mp3`）。
