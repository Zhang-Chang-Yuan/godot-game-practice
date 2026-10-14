# 001 · Learn About Geometry（认识几何体）

一个完整的幼儿向「认识几何」小游戏：屏幕中央出一个几何体，下方 4 个选项，选出正确的形状。答 10 题，每题 10 分，满分 100 分，成绩记入排行榜。

本项目同时是一条 **Blender 4.5 → Godot 4.7** 的完整资源管线：模型由 Blender 导出 GLB，游戏在 Godot 里加载。

---

## 一、怎么运行

```powershell
# 方式 1：命令行直接玩
& "C:\Hub\program\godot-4\Godot_v4.7.2-stable_win64.exe" --path .

# 方式 2：用 Godot 项目管理器打开本目录的 project.godot，按 F5
```

游戏启动后自动进入**开始页**，点「开始游戏」即可。

---

## 二、游戏流程

```
开始页(开始/排行榜按钮)
   │  点"开始游戏"
   ▼
加载页(生成10道随机题 + 预载6个模型，进度条走满)
   │
   ▼
答题页(题目大图 + 4个选项，答对+10分，答错染色提示)
   │  答完第10题
   ▼
结算页(显示得分/用时，可再来一局/看排行榜/回主菜单)
   │
   ▼
排行榜页(分数降序、同分比用时，存 user://leaderboard.json，前20名)
```

---

## 三、目录结构

```
001-learn-about-geometry/
├── project.godot            # 工程配置：主场景、autoload、窗口大小、渲染方式
├── models/                  # 6 个 GLB 模型（Blender 导出，共约 30 KB）
│   ├── Cube.glb             # 正方体（12 三角面）
│   ├── Cuboid.glb           # 长方体（12）
│   ├── Sphere.glb           # 球体（224，16×8 段）
│   ├── Cylinder.glb         # 圆柱体（44，12 顶点）
│   ├── Cone.glb             # 圆锥体（22）
│   └── Pyramid.glb          # 四棱锥（6）
├── scenes/                  # 所有界面（场景）
│   ├── start_screen.tscn    # 开始页（2 个按钮）
│   ├── loading_screen.tscn  # 加载页（进度条 + 小提示 + 计时器）
│   ├── quiz.tscn            # 答题页（题目 + 4 选项 + 计分板）
│   ├── result_screen.tscn   # 结算页
│   ├── leaderboard.tscn     # 排行榜页
│   ├── shape_preview.tscn   # 【组件】在 2D 界面里显示 3D 模型
│   └── option_item.tscn     # 【组件】一个答题选项
├── scripts/                 # 所有代码
│   ├── main.gd                  # 开始页逻辑
│   ├── loading_screen.gd        # 加载流程
│   ├── quiz.gd                  # 答题逻辑（核心）
│   ├── result_screen.gd         # 结算页逻辑
│   ├── leaderboard_screen.gd    # 排行榜页逻辑
│   ├── shape_preview.gd         # ShapePreview 组件逻辑
│   ├── option_item.gd           # OptionItem 组件逻辑
│   └── autoload/
│       ├── game_state.gd        # 单例：全局数据（题目/分数/缓存）
│       └── leaderboard.gd       # 单例：排行榜存档
├── tools/
│   └── export_geometry.py   # Blender 导出脚本（重新生成模型用）
└── README.md
```

> **GLB 和 .import 文件**：`models/` 里每个 `.glb` 旁边都有 `.glb.import`，那是 Godot 自动生成的导入配置，别删。`.godot/` 是引擎缓存，删了会重新生成。

---

## 四、每个文件在干什么（新人导读）

### 两个 autoload 单例（整个游戏最重要的概念）

单例 = 全局唯一的节点，任何场景里都能直接用它，切换场景也不会消失。
注册位置：**项目 → 项目设置 → Autoload**。

| 文件 | 里面有什么 |
|---|---|
| `scripts/autoload/game_state.gd` | `questions`（10 道题）、`question_index`、`score`、`quiz_start_msec`、`model_cache`（模型缓存）、`start_new_game()`、`generate_questions()` |
| `scripts/autoload/leaderboard.gd` | `records`（记录数组）、`add_record(得分, 毫秒)`、`clear_records()`；负责读写 JSON 和排序 |

**为什么需要它**：场景一切换，旧场景上的数据全部清空。分数、题目这种"跨场景还要用"的数据只能放单例——就像把菜放进冰箱，厨师（场景）换了一茬还能拿到。

### 两个组件场景（一次搭建，处处复用）

| 文件 | 干什么 |
|---|---|
| `shape_preview.tscn` + `shape_preview.gd` | 用 **SubViewport** 把 3D 世界渲染成一张贴图贴在 2D 界面上。这是"UI 里显示 3D 模型"的标准做法 |
| `option_item.tscn` + `option_item.gd` | 一个答题选项 = 按钮 + 内嵌 ShapePreview，被点击时发出自定义信号 `option_selected(路径)` |

### 五个页面场景

| 文件 | 核心逻辑 |
|---|---|
| `start_screen.tscn` + `main.gd` | 两个按钮，点谁切谁 |
| `loading_screen.tscn` + `loading_screen.gd` | 三段式加载（详见脚本注释）：① 生成 10 题 ② 异步预载 6 个模型 ③ 切场景 |
| `quiz.tscn` + `quiz.gd` | **游戏核心**：出题 → 等作答 → 判定 → 停顿反馈 → 下一题 → 结算 |
| `result_screen.tscn` + `result_screen.gd` | 显示得分与用时，三个跳转按钮 |
| `leaderboard.tscn` + `leaderboard_screen.gd` | 按记录数动态生成 Label 行 |

---

## 五、这个项目用到的 Godot 核心概念（配合注释阅读）

1. **信号（Signal）**：`pressed` / `option_selected` / `timeout`。按钮被按、计时器到点都会"发信号"，连接过的函数自动被调用。它是 Godot 的解耦利器——A 只管发，B 只管收。
2. **Autoload 单例**：见上。
3. **场景切换**：`get_tree().change_scene_to_file("res://scenes/xxx.tscn")`，旧场景销毁、新场景加载。
4. **SubViewport**：2D 界面里嵌 3D 画面的唯一正统方法。
5. **`await` 异步流程**：`await 信号` 让函数"等到某事发生再继续"，用来做加载、停顿，界面不卡。
6. **`@onready` 变量**：场景加载完再取节点引用，避免拿到 null。
7. **`res://` 与 `user://`**：`res://` 是工程内只读；`user://` 才是运行时能写的目录（排行榜存档在这里）。
8. **`randomize()`**：不调用的话每次运行随机序列相同（10 题永远一样）。

---

## 六、新手常见坑（本项目踩过的）

1. **锚点（Anchor）与偏移（Offset）是一对**：
   - `anchor_right = 1.0` 表示右边"贴父节点右边"；
   - 此时 `offset_right` 要写**负数**（离右边多少像素），写正数会把控件撑到屏幕外。
   - 本项目的 `option_item.tscn` 根节点是全矩形锚点；在 `quiz.tscn` 里放 4 个实例时必须显式写 `anchor_right = 0.0 / anchor_bottom = 0.0`，偏移才能当绝对坐标用（否则按钮会变成超大号，模型全跑出屏幕——这个 bug 真实踩过）。
2. **轮询循环里必须 `await get_tree().process_frame`**：否则 loading 的 while 循环一口气跑完，进度条不动、UI 假死。
3. **想要切换场景后数据不丢**：数据放 autoload，不要放在场景脚本的变量里。
4. **`for` 循环里的随机**：用 `pick_random()` 之前确保调过 `randomize()`。
5. **防连点**：答题页的 `_answering` 布尔锁，停顿期间禁用所有选项（`disabled = true`）。

---

## 七、想改点什么？从这里下手

| 想做的事 | 改哪里 |
|---|---|
| 换模型颜色/形状 | 改 Blender 脚本 `tools/export_geometry.py` 里的 `SHAPES` 表，重新导出 |
| 加新几何体 | ① 导出 GLB 到 `models/` ② 在 `game_state.gd` 的 `MODEL_PATHS` 里加路径（其余逻辑自动适配） |
| 改题目数量 | `game_state.gd` 的 `QUESTION_COUNT` |
| 改每题分值 | `quiz.gd` 的 `SCORE_PER_QUESTION` |
| 改答题停顿时间 | `quiz.gd` 的 `FEEDBACK_DELAY` |
| 改排行榜条数 | `leaderboard.gd` 的 `MAX_RECORDS` |
| 改加载页最短展示时间 | `loading_screen.gd` 的 `MIN_DISPLAY_SEC` |

---

## 八、重新生成模型

```powershell
& "C:\Hub\program\blender 4.5\blender.exe" -b --factory-startup --python tools\export_geometry.py
```

材质规范：纯色哑光 Principled BSDF，Roughness=0.9、Metallic=0、Specular IOR=0；每个 GLB 单文件、原点居中。

---

## 九、质量验证记录

开发期间做过两层自动化验证（均为一次性脚手架，验证通过后已从项目移除以保持整洁）：

1. **资源层**：Blender 回读 6 个 GLB 渲染确认；Godot 侧确认材质 Roughness=0.9、Metallic=0。
2. **流程层**：headless 驱动模拟玩家走完整流程，14 项断言全部通过（生成 10 题、选项含答案且不重复、全对 100 分、结算、排行榜写入与排序、全错 0 分等）。

如果以后想重新验证，可按 README 第四、五节的概念自己搭一个小驱动：把驱动挂到 `root` 下（`add_child.call_deferred`），切换场景时它不会被销毁，然后模拟点击调用 `quiz._on_option_selected(...)` 即可。注意等待判定停顿时要用**真实时间**（`await get_tree().create_timer(1.3).timeout`），不要数帧（headless 帧率远快于真实时间）。
