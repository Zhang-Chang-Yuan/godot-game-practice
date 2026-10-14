# 002 · Piano 88（88 键钢琴）

一个用 **Godot 4.7** 做的可弹奏钢琴：**88 个键全都有独立采样**，配节拍器、延音踏板和演奏录制/回放。
音源复刻自 GitHub 开源项目 [gleitz/midi-js-soundfonts](https://github.com/gleitz/midi-js-soundfonts) 的 FluidR3_GM 音色库。

![Piano 88 界面](docs/screenshot.png)

---

## 一、四大功能

### 1. 节拍器
- BPM **20 ~ 300**，可拖动滑块、按 `-`/`+` 每次 ±5
- 拍号 **2/4、3/4、4/4、6/8**
- **Tap Tempo**：连续点击取平均间隔换算 BPM（间隔 < 2 秒才计入，取最近 4 个间隔平均）
- 节拍指示灯：**重音橙红、弱拍青蓝**，每拍闪一下
- 点击音**代码生成**（重音 1600 Hz / 弱拍 900 Hz，正弦 + 指数衰减 + 首尾淡入淡出防爆音），不依赖任何音频文件

> **时间基准是真实时间**（`Time.get_ticks_msec()`），不是帧数。这点很关键——headless 下帧率可达上千 FPS，按帧计数节拍会飞快。

### 2. 88 个键
- **A0（MIDI 21）到 C8（MIDI 108）**，52 白键 + 36 黑键，一个不缺
- 每个键**一个独立采样**，不做音高移位，音色真实
- 黑键精确**骑在白键交界处**，`z_index` 高于白键
- 三种弹奏方式：**鼠标点击**、**按住拖动连奏（glissando）**、**电脑键盘映射**
- 「适应宽度」开关：开时 52 个白键自动缩放铺满窗口；关时固定 36px 宽，横向滚动查看全部 88 键

### 3. 延音（踏板）
- `空格` 或 **鼠标右键** 切换踏板
- 踩下时松键**不停声**，音符进入「待释放」状态继续发声，直到踏板抬起
- 可选「**延音尾音循环**」：把采样尾部（55% 处起）设为循环点，获得更长延音
- 关闭踏板时，所有挂住的音**立刻**释放

### 4. 录制 / 回放
- 记录每一次 `note_on` / `note_off` / 踏板切换，带**毫秒级时间戳**
- 回放用真实时间驱动，**回放期间绝不录制**（否则会自我循环套娃）
- 保存 / 载入到 `user://recording.json`（JSON，带 `version` 字段与脏数据容错）
- 显示事件数与时长；回放时**琴键会实时点亮**

---

## 二、怎么运行

```powershell
# 方式 1：命令行
& "C:\Hub\program\godot-4\Godot_v4.7.2-stable_win64.exe" --path .

# 方式 2：用 Godot 项目管理器导入本目录的 project.godot，按 F5
```

---

## 三、操作说明

| 操作 | 按键 / 鼠标 |
|---|---|
| 弹奏 | 鼠标左键点击琴键；按住拖动可连奏 |
| 电脑键盘 · 低八度 C4–B4 | `Z S X D C V G B H N J M` |
| 电脑键盘 · 中八度 C5–B5 | `Q 2 W 3 E R 5 T 6 Y 7 U` |
| 电脑键盘 · 高八度 C6–E6 | `, L . ; /` |
| 延音踏板 | `空格` 或 **鼠标右键** |
| 录制 / 停止录制 | **`Ctrl+R`** |
| 回放 / 停止回放 | **`Ctrl+P`** |
| 全部停音（掐掉所有正在发声的音，含被延音挂住的） | `Esc` |

> **为什么录制是 `Ctrl+R` 而不是 `R`？**
> 因为 `R` 是琴键映射里的 **F5**（`Q 2 W 3 E R 5 T 6 Y 7 U` = C5..B5 的完整半音阶）。
> HUD 的输入处理走 `_input`，琴键走 `_unhandled_input`，而 `_input` **一定先执行**。
> 如果 HUD 抢了裸 `R`，`R` 键就永远弹不出 F5。加 `Ctrl` 修饰键后两边干净共存——
> 琴键模块用 `not is_command_or_control_pressed()` 守卫发声，所以 `Ctrl+R` 不会误发音符。

---

## 四、目录结构

```
002-piano/
├── project.godot              # 工程配置：主场景、3 个 autoload、窗口、渲染
├── README.md
├── LICENSES.md                # 音源来源与授权（CC BY 3.0，必须署名）
├── docs/
│   ├── INTERFACES.md          # 接口契约：所有公开签名/信号/常量的唯一事实来源
│   ├── screenshot.png         # 上面的界面截图（.gdignore 让 Godot 不把它当资源导入）
│   └── .gdignore
├── audio/piano/               # 88 个采样：A0.mp3 As0.mp3 B0.mp3 ... C8.mp3
│   └── ATTRIBUTION.md         # 音频署名（CC BY 3.0 强制要求）
├── scenes/
│   └── main.tscn              # 唯一场景，根节点挂 scripts/main.gd
├── scripts/
│   ├── music_theory.gd        # class_name MusicTheory：纯静态乐理换算
│   ├── main.gd                # 装配层：标题栏 + HUD + 键盘
│   ├── keyboard.gd            # 88 键容器：布局 / 鼠标 / 电脑键盘
│   ├── piano_key.gd           # 单个琴键：只负责 _draw()
│   ├── hud.gd                 # 顶栏控制面板（节拍器/延音/录制/音量/状态）
│   └── autoload/
│       ├── piano_engine.gd    # autoload PianoEngine：复音发声 + 延音
│       ├── metronome.gd       # autoload Metronome：节拍器
│       └── recorder.gd        # autoload Recorder：录制 / 回放
└── tests/
    ├── test_scene.tscn        # 测试入口场景
    └── test_runner.gd         # headless 断言驱动
```

---

## 五、架构：3 个单例 + 3 个 UI 组件

```
                    ┌──────────────────────────────┐
   HUD ────────────▶│  Metronome   (autoload)      │  节拍：真实时间驱动
   (控制面板)        │  Recorder    (autoload)      │  录制/回放
                    │  PianoEngine (autoload)      │  发声 + 延音
                    └───────────┬──────────────────┘
                                │ note_on / note_off / set_sustain
   Keyboard ────────────────────┘
   (88 键 UI)                    ▲
                                 │ note_started / note_stopped
                              main.gd ──▶ 点亮 / 熄灭琴键高亮
```

**数据流（弹一个音）**：

```
鼠标/键盘 → keyboard.gd.press_note(midi)
          → PianoEngine.note_on(midi, velocity)
              ├─ MusicTheory.sample_path(midi) → ResourceLoader 加载（带缓存）
              ├─ 从 32 个声部里取一个（满了就抢占最早触发的）
              ├─ _active[midi] = {...}          ← 逻辑状态
              └─ emit note_started(midi, vel)
                   ├─ Recorder   （若在录制：追加事件）
                   └─ main.gd    （点亮琴键）
```

### 最重要的设计决策：**逻辑状态与音频播放器解耦**

`PianoEngine` 自己维护一个 `_active` 字典记录「哪些音在响」，`is_note_active()` / `active_voice_count()`
只读这个字典，**不看 `AudioStreamPlayer.playing`**。

原因：headless 模式下音频驱动是 `Dummy`，`player.playing` 和 `player.finished` 都不可靠。
如果逻辑依赖播放器状态，自动化测试就永远断言不了。解耦之后，测试在任何音频驱动下都能跑。

### 其他关键决策

| 决策 | 原因 |
|---|---|
| 采样文件名用 `As0` 而非 `A#0` | `#` 在 `res://` 路径里有 URL fragment 歧义，不安全 |
| `.tscn` 只有一个根节点 | UI 全部代码生成，避免手写场景文件出错；也让并行开发不打架 |
| 事件字典固定 5 键 `t/type/midi/velocity/value` | 存档格式稳定，加载时能逐键容错 |
| 节拍器点击音代码生成 | 免去又一个小音频文件，且可精确控制包络 |

---

## 六、音源与授权

88 个采样来自 **FluidR3_GM** 音色库的 `acoustic_grand_piano`，经 [gleitz/midi-js-soundfonts](https://github.com/gleitz/midi-js-soundfonts) 打包。

| 实测项 | 数值 |
|---|---|
| 文件数 | **88**（A0 – C8，每键一个独立采样，不做音高移位） |
| Godot 解码 | **88/88 成功**，`AudioStreamMP3`，无失败 |
| 单文件时长 | **3.129 秒**（88 个完全一致） |
| 采样率 / 声道 | 44.1 kHz / **Joint Stereo**（MP3 帧头的声道模式，88/88 一致） |
| 单文件大小 | 14,327 – 25,585 字节（合计约 1.97 MB） |
| `.import` 导入类型 | `importer="mp3"` → `AudioStreamMP3`（88/88 一致） |

> 3.13 秒的自然衰减尾音是「延音」功能的基础：踩下踏板时松键不停声，音符会把这 3.13 秒自然放完；
> 打开「延音尾音循环」后，从采样 55% 处起循环，可获得任意长的延音。

**输出电平（实测）**：采样原始峰值仅 **0.0889（−21.0 dBFS）**——FluidR3_GM 被母带处理得极其保守。
引擎为此给声部补了 **+6 dB**（`_VOICE_GAIN = 2.0`），并在 Master 总线上挂了
`AudioEffectHardLimiter`（天花板 −1 dBFS）兜住密集和弦的叠加峰值。默认音量（滑块 80）下实测：

| 织体 | 峰值 | 电平 |
|---|---|---|
| 单音 | 0.177 | −17.0 dBFS |
| 三音和弦 | 0.348 | −11.1 dBFS |
| 八音和弦 | 0.614 | −6.2 dBFS |

- 采样授权：**CC BY 3.0**（作者 Frank Wen）——**使用时必须署名**
- 打包层授权：**MIT**（© 2012 Benjamin Gleitzman）

完整署名文本、下载地址、以及「降号 → 升号」重命名映射见 [`LICENSES.md`](LICENSES.md)。
**再分发本工程时请勿删除该文件与 `audio/piano/ATTRIBUTION.md`。**

---

## 七、这个项目用到的 Godot 核心概念

1. **Autoload 单例**：跨场景的全局对象。`PianoEngine` / `Metronome` / `Recorder` 都是。
   任何脚本里直接写 `PianoEngine.note_on(60)` 就能用，不需要 `get_node()`。
2. **信号（Signal）**：`note_started` / `tick` / `playback_finished`。发出者只管发，接收者只管收。
   本项目里 `Recorder` 就是靠监听 `PianoEngine` 的信号来录制的——它完全不需要知道键盘的存在。
3. **`_input` vs `_unhandled_input`**：前者先执行，能看到所有事件；后者只拿到没被消费的。
   HUD 用 `_input` 抢快捷键，琴键用 `_unhandled_input`，靠**是否 `set_input_as_handled()`** 决定放行。
4. **`Control.mouse_filter`**：`piano_key.gd` 设成 `IGNORE`，鼠标事件才能穿透到父节点 `keyboard.gd`，
   由它统一按坐标换算命中哪个键。否则每个键各抢各的，连奏逻辑没法写。
5. **`_draw()` 与 `queue_redraw()`**：琴键不用图片，直接画矩形 + 描边 + 文字；状态变了调 `queue_redraw()`。
6. **`Tween`**：松键时的 60ms 淡出、节拍指示灯的闪烁，都用 `create_tween()`。
7. **`AudioStreamWAV` 手写 PCM**：`data` 是 `PackedByteArray`，用 `encode_s16()` 逐帧写 16 位样本。
8. **`Time.get_ticks_msec()`**：所有计时（节拍、录制时间戳、回放）都用它，**不用帧数、不用 `_delta` 累加**。
9. **`user://`**：运行时唯一可写目录。录制存档在 `user://recording.json`。

---

## 八、开发中真实踩到的坑

> 这一节是本次开发**实际发生**的问题，不是教科书条目。

1. **`--check-only` 会对 autoload 报假错。**
   `godot --check-only --script res://xxx.gd` 只编译单个脚本、**不实例化 autoload**，
   所以 `PianoEngine.xxx` 会被报成 `Identifier not found: PianoEngine`。
   实测对照：`001-learn-about-geometry` 里 `GameState.questions` 是正确用法，同样报错。
   **结论**：引用 autoload 的脚本必须用完整工程运行来验证，别被这个假阴性骗去改成 `get_node("/root/...")`。

2. **Godot 的退出码不可靠。**
   发生 `SCRIPT ERROR` / `Failed to load resource` 时，Godot **仍然返回 0**。
   判断「工程是否干净启动」必须同时 grep 输出里的 `SCRIPT ERROR` / `ERROR:`。

3. **`R` 键冲突（`_input` 抢走了琴键）。**
   HUD 原本用裸 `R` 当录制开关，导致 `R` 永远弹不出 F5。修法见第三节的说明。

4. **`all_notes_off()` 改了状态却不发信号。**
   它直接 `_active.clear()` 而不补发 `note_stopped`，结果回放停止后**琴键高亮永久残留**。
   修法：清空前先收集 midi，清空后逐个补发 `note_stopped`。
   **教训**：任何「状态变更」都要走信号通知，哪怕看起来只是清理。

5. **headless 首帧的 `create_timer(0.05)` 只走了 0~2ms 真实时间。**
   首帧 delta 里含引擎启动耗时，所以「等 50ms 让时间戳递增」这类断言会**随机失败**（实测出现 `0 -> 0`）。
   正确写法是自旋等真实时间：
   ```gdscript
   while Time.get_ticks_msec() - t0 < 50:
       await get_tree().process_frame
   ```

6. **黑键坐标不是「白键宽度 × 序号」。**
   黑键必须**骑在两个白键的交界**上：`x_center = (white_index_of(midi - 1) + 1) * white_key_width`。
   恰好 `midi - 1` 对黑键来说**永远是白键**（黑键半音位置是 1/3/6/8/10，减一后是 0/2/5/7/9），
   所以这个公式永远有效。

7. **上游音源用降号记法。**
   `midi-js-soundfonts` 的键名是 `Bb0` / `Db1` / `Ab7`，不是 `A#0`。
   用 `[A-G]#?[0-9]` 去匹配只会拿到 **52 个白键**，黑键全丢。
   正确做法是匹配 `[A-G]b?[0-9]` 再做 `Db→C#` 等映射，最后与 `MusicTheory` 期望的文件名集合做**全等校验**。

8. **契约和测试预期自相矛盾。**
   BPM 被 `clamp` 到 20~300，但测试却用 `set_bpm(600)` 期望 1.1 秒内 ≥9 拍——实际只有 6 拍，必然误判失败。
   **教训**：写测试前先确认被测量对象的**边界行为**。

9. **headless 退出时的 `ObjectDB instances were leaked` 警告。**
   `Dummy` 音频驱动下，只要调用过 `AudioStreamPlayer.play()`，退出时就会有这个警告。
   实测：不调 `play()` 无警告、调过必有、`stop()` 也消不掉。属引擎清理顺序问题，**退出码仍为 0，不是脚本错误**。

10. **「能出声」不等于「音量合适」——采样可能被母带处理得极保守。**
    FluidR3_GM 的采样原始峰值只有 **0.0889（−21.0 dBFS）**。而管线里 velocity=1.0 → 0 dB、
    总音量 0.8 → −1.94 dB，**没有任何环节做增益补偿**，于是用户把音量滑块拉满也只有 −21 dBFS，
    比常规媒体安静约 20 dB。修法：声部补 +6 dB，并在 Master 总线挂限制器兜住密集和弦。

    **教训（方法论）**：不要因为「文件能加载、时长正确」就认为音量没问题。
    正确做法是把 `AudioEffectCapture` 挂到 Master 总线上量 RMS/峰值，**并用一段已知振幅的正弦做增益标定**——
    否则你测到的可能是"总线音量之前"的信号，绝对值不可信（本项目就踩了这个坑：
    改总音量后峰值纹丝不动，才反推出 capture 位于音量节点之前）。

    ```gdscript
    var cap := AudioEffectCapture.new()
    AudioServer.add_bus_effect(0, cap)   # 0 = Master
    # 播放后读 cap.get_buffer(cap.get_frames_available()) 求峰值/RMS
    ```

11. **测试函数不 `await` 会得到「假绿」——本项目最危险的一个坑。**
    在 `_ready()` 里写 `_test_keyboard()`（忘了 `await`），协程会**永久停在那个测试函数里的第一个 `await`**；
    `_ready()` 一返回，进程立刻结束：**退出码 0、无 `SCRIPT ERROR`、无任何报错**。
    而**没跑到的断言根本不计入总数**。

    实测：本工程测试套件的某一版打印了 `TESTS: 76/76 passed` + `ALL PASS` + 退出码 0，
    但整个 Keyboard 段的 **18 条断言一条都没跑**——`x/y` 里的 `y` 自己就是错的。

    **教训**：`132/132 passed` 这种绿色结论，必须配上「**耗时是否合理**」的交叉验证
    （本套件含 2.4s + 0.5s 真实自旋等待，实测 3.17 秒才说明真的跑完了）。
    防御写法：逐个 `await` 测试函数；断言双写日志；**用 `_finished` 标志守卫退出码 0**，
    让"提前退出"变成失败而不是伪装成全绿。

---

## 九、自动化测试

测试有**两个入口场景**，都用 headless 运行（autoload 会正常注册）：

```powershell
$godot = "C:\Hub\program\godot-4\Godot_v4.7.2-stable_win64_console.exe"

# ① 核心逻辑套件：A–F 六个模块（不加载 main.tscn）
& $godot --headless --path . res://tests/test_scene.tscn

# ② UI 套件：HUD 控制面板 + main.gd 装配接线（加载真实主场景）
& $godot --headless --path . res://tests/test_ui.tscn
```

实测结果：

| 套件 | 断言数 | 结果 | 退出码 |
|---|---|---|---|
| `test_scene.tscn`（A–F） | **174** | 全部通过 | 0 |
| `test_ui.tscn`（HUD + main） | **54** | 全部通过 | 0 |
| **合计** | **228** | — | — |

两个套件均无 `SCRIPT ERROR` / `Parse Error`。

> **为什么要分成两个场景**：`test_scene.tscn` 按契约第 9 节的运行方式**不加载 `main.tscn`**，
> 因此 HUD 的按钮接线与 main 的装配逻辑不在它的覆盖范围内。
> `test_ui.tscn` 加载真实主场景，验证「用户实际点的那些按钮」确实接通了底层功能。

> **别被一行 stderr 吓到**：运行时会看到
> `ERROR: Parse JSON failed. Error at line 0: Expected key`。
> 那是**故意的脏数据用例**——测试往 `user://` 写一个内容为 `{not json` 的文件，
> 验证 `Recorder.load_from_file()` 返回 `ERR_PARSE_ERROR` 且不崩溃。
> Godot 的 `JSON.parse_string` 自身会打印这行，代码已正确处理，**不是缺陷**。
> 这也是为什么「判断工程是否干净」不能只看退出码和 stderr——要区分**预期内的**错误日志。

覆盖范围（断言的是**行为**，不只是「节点存在」）：

| 模块 | 断言内容 |
|---|---|
| MusicTheory | 88 个音名往返一致、边界值 A0/C8、黑键判定、白键总数 52、文件名不含 `#` |
| 音频资源 | 88 个 `sample_path()` 文件全部存在且 `get_stream()` 非 null |
| PianoEngine | 发声/停声、延音挂起与释放、**复音上限恰为 32 与 FIFO 抢占**、同音重复不叠加、`all_notes_off` 补发信号计数 |
| Metronome | BPM 上下夹、真实时间节拍数（并证明**不是**按帧计数）、拍号重音位置、停止后不再 tick |
| Recorder | 录制产生事件且时间戳严格递增、存盘往返一致、脏 JSON 不崩溃、**回放期间不录制** |
| Keyboard | 88 个键节点、黑键几何、**29 个电脑键盘映射逐项**、鼠标拖动连奏、黑键优先命中、右键延音、`mouse_exited` 释放 |
| HUD | 节拍器开关/BPM±/滑块/拍号/Tap Tempo、延音与尾音循环、录制·保存·载入·清空·回放、音量滑块、`Space`/`Ctrl+R` 快捷键 |
| main.gd | 适应宽度 24px↔36px 切换、琴键高亮随 `note_started/note_stopped` 点亮熄灭、**Esc 紧急制动清零无残留** |

### 用变异测试证明「测试不是空的」

**全绿不等于测得准。** 本项目用变异测试（故意植入 bug，确认测试会失败）自查，
发现并修掉了一处**同义反复断言**：

| 变异 | 结果 |
|---|---|
| `midi_to_name` 八度 +1 | 10 条失败 ✓ 捕获 |
| `emit_signal("tick", …)` 整行删除 | 6 条失败 ✓ 捕获 |
| `Recorder._can_write_event()` 恒为真 | 2 条失败 ✓ 捕获 |
| **`POLYPHONY` 32→8** | 最初 **全部通过 ✗ 漏网** → 修正断言后 **3 条失败 ✓ 捕获** |

漏网原因：原断言写成 `active_voice_count() <= PianoEngine.POLYPHONY`，
**拿常量比自己**——把常量改小它永远成立，等于「复音上限」这个特性**完全没有测试保护**。
修正为字面量 `32` 并补上 `voice_stealed` 触发次数 `== 8`、首个被抢占的是最早触发的 21 号之后，同一变异立即被捕获。

> **通则**：边界/上限类断言的期望值一律写**字面量**，并额外断言「越界时的可观测行为」，
> 而不只是「没越界」。没被任何变异杀死的断言，等于没写。

---

## 十、想改点什么？从这里下手

| 想做的事 | 改哪里 |
|---|---|
| 改节拍器 BPM 范围 | `metronome.gd` 的 `MIN_BPM` / `MAX_BPM` |
| 改点击音音色 | `metronome.gd` 的 `CLICK_ACCENT_HZ` / `CLICK_WEAK_HZ` / `CLICK_DECAY` |
| 改复音上限 | `piano_engine.gd` 的 `POLYPHONY` |
| 改松键淡出时长 | `piano_engine.gd` 的 `RELEASE_FADE_SEC` |
| 改延音循环起点 | `piano_engine.gd` 的 `_LOOP_OFFSET_RATIO` |
| 改琴键尺寸 / 黑键比例 | `keyboard.gd` 的 `WHITE_KEY_WIDTH` / `BLACK_KEY_WIDTH_RATIO` |
| 改电脑键盘映射 | `keyboard.gd` 的 `_build_physical_map()` |
| 改录制存档的**格式版本** | `recorder.gd` 的 `FORMAT_VERSION`——注意这是**存档格式版本号，不是条数上限**；代码里没有条数上限 |
| 换音源 | 替换 `audio/piano/` 下 88 个文件，保持文件名符合 `MusicTheory.midi_to_filename()`；**并更新 `LICENSES.md`** |
