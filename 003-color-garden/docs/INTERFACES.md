# 003-color-garden 接口契约（所有子 Agent 必须严格遵守）

> 本文件是**唯一事实来源**。任何实现都不得修改这里的公开签名、信号名、节点路径、文件命名。
> 需要变更必须先提出，由主 Agent 统一修改本文件。

引擎：**Godot 4.7.2**（`C:\Hub\program\godot-4\Godot_v4.7.2-stable_win64_console.exe`）
素材生成：**Blender 4.5.14 LTS**（`C:\Hub\program\blender 4.5\blender.exe`，bpy / Python 3.11.15，已实测 headless 可用、启动约 0.5s）
工程根：`C:\Hub\workspace\godot-game-practice\003-color-garden\`
缩进：**Tab**。注释：**中文**。

---

## 0. 这是什么，以及三个 demo 重点

一个**涂色游戏**：7 个图案（小花/小草/蝴蝶/小狗/蜜蜂/小猫/小猪），右侧色板选色，
点画布上的区域给它上色，作品可保存/载入/导出 PNG。

**三个 demo 重点（必须真正实现，不能敷衍）：**

| # | 重点 | 硬性要求 |
|---|---|---|
| 1 | **PhysicsPointQuery 点击检测** | 点击必须通过 `PhysicsDirectSpaceState2D.intersect_point(PhysicsPointQueryParameters2D)` 命中区域。每个区域是一个 `Area2D` + `CollisionPolygon2D`。**不许**用"遍历多边形 + `point_in_polygon`"代替。该 API 一次会返回**所有**重叠命中，必须把命中列表完整暴露出来（UI 显示"本次命中 N 个区域"） |
| 2 | **Tween 动画** | 见 §6。填色脉冲、色板选中脉冲、切换图案的错峰入场，都必须是 `create_tween()` 实现的，且可被重复触发而不堆叠 |
| 3 | **加色混合逻辑** | 涂色是**逐通道相加**（`PaletteDef.add_color`），不是覆盖。暗底 + 光绘：红+绿=黄，红+蓝=品红，绿+蓝=青，三色加满=白。命中多个区域时**每个都加一遍**（`PaletteDef.add_many`） |

### 为什么用暗底（不是白纸）

加色是**光**的混合方式，必须有暗底才成立——从白底出发任何颜色加上去都立刻饱和。
颜料/印刷走的是减色混合，那才需要白底。这不是偷懒，是本 demo 要讲清楚的核心概念。

---

## 1. 目录结构（固定）

```
003-color-garden/
├── project.godot
├── README.md
├── LICENSES.md                  # 无第三方素材（图案由脚本生成），说明这一点
├── docs/
│   ├── INTERFACES.md            # 本文件
│   ├── .gdignore                # 让 Godot 跳过本目录
│   └── screenshot.png           # 界面截图（主 Agent 收尾时放）
├── assets/patterns/             # 7 个区域数据：flower.json grass.json ... pig.json
├── tools/
│   └── generate_patterns.py     # Blender bpy 脚本（生成上面 7 个 JSON）
├── scenes/
│   └── main.tscn                # 唯一场景，根节点 Main(Control) 挂 scripts/main.gd
├── scripts/
│   ├── palette_def.gd           # class_name PaletteDef（主 Agent 已写，勿改）
│   ├── pattern_schema.gd        # class_name PatternSchema（主 Agent 已写，勿改）
│   ├── main.gd                  # 装配层
│   ├── pattern_data.gd          # class_name PatternData：读 JSON + 校验
│   ├── color_region.gd          # class_name ColorRegion（extends Area2D）：一个可涂区域
│   ├── canvas_view.gd           # class_name CanvasView（extends Node2D）：区域容器 + 点查询
│   ├── palette_panel.gd         # class_name PalettePanel（extends Control）：色板 UI
│   ├── hud.gd                   # class_name ColorHud（extends Control）：顶栏
│   ├── fx.gd                    # class_name Fx：Tween 工具
│   ├── artwork_export.gd        # class_name ArtworkExport：扫描线光栅化 + 导出 PNG
│   └── autoload/
│       └── paint_state.gd       # autoload 名：PaintState
└── tests/
    ├── test_scene.tscn          # 测试入口场景，挂 tests/test_runner.gd
    └── test_runner.gd           # headless 断言驱动
```

## 2. project.godot（主 Agent 已写，勿改）

```ini
[application]
config/name="Color Garden"
run/main_scene="res://scenes/main.tscn"
config/features=PackedStringArray("4.7", "GL Compatibility")

[autoload]
PaintState="*res://scripts/autoload/paint_state.gd"

[display]
window/size/viewport_width=1280
window/size/viewport_height=800
window/stretch/mode="canvas_items"
window/stretch/aspect="expand"

[layer_names]
2d_physics/layer_2="color_region"
```

**一律用 `res://` 路径，不要手写 `uid://`。**
`PaletteDef` / `PatternSchema` 用 `class_name` 暴露，**不注册 autoload**。

---

## 3. 图案区域数据 schema（`assets/patterns/<name>.json`）

```json
{
  "version": 1,
  "name": "flower",
  "display_name": "小花",
  "width": 512,
  "height": 512,
  "regions": [
    {
      "id": "petal_0",
      "label": "花瓣1",
      "polygon": [[256.0, 96.0], [286.4, 140.2], [256.0, 184.4]],
      "z": 10
    }
  ]
}
```

**硬性约束**（生成端必须自检，`PatternSchema.validate_pattern()` 会逐条校验）：

1. `version` == 1；`name` ∈ `PatternSchema.PATTERNS`；`width`/`height` == **512×512**
2. `regions` 是数组，**每个图案 6 ~ 16 个区域**
3. 每个区域：`id`（**全局唯一**，`[a-z0-9_]`）、`label`（中文，给 UI 显示）、
   `polygon`（**≥3 个 [x, y] 点，闭合多边形，不重复首尾点**）、`z`（整数，绘制顺序，大的在上）
4. **坐标必须全部落在 [0, 512] × [0, 512] 内**
5. **禁止 `holes`** —— `CollisionPolygon2D` 不支持挖洞。需要"洞"就用多个不重叠区域拼出来
6. 多边形必须是**简单多边形**（不自交）。允许凹多边形（`CollisionPolygon2D` 会自动分解）
7. **区域之间尽量不要重叠**（重叠是允许的，但会让"一次点击命中多个"变成常态，影响可玩性）。
   允许**少量**有意重叠，用来演示 `intersect_point` 的多命中 —— 每个图案最多 1 组这种重叠。

### 各图案建议的区域划分

| name | 显示名 | 建议区域 |
|---|---|---|
| `flower` | 小花 | 5 花瓣 + 花心 + 花茎 + 2 叶 = 9 |
| `grass` | 小草 | 5~7 草叶 + 土堆 = 6~8 |
| `butterfly` | 蝴蝶 | 左上/右上/左下/右下 4 翅 + 身体 + 2 触角 = 7 |
| `dog` | 小狗 | 头 + 2 耳 + 2 眼 + 鼻 + 身体 + 4 腿 + 尾 = 11~13 |
| `bee` | 蜜蜂 | 头 + 2 触角 + 身体 + 3 条纹 + 2 翅 + 螫针 = 9~10 |
| `cat` | 小猫 | 头 + 2 耳 + 2 眼 + 鼻 + 身体 + 4 腿 + 尾 = 11~13 |
| `pig` | 小猪 | 头 + 2 耳 + 2 眼 + 猪鼻 + 2 鼻孔 + 身体 + 4 腿 + 尾 = 13~14 |

---

## 4. PatternData（`scripts/pattern_data.gd`，`class_name PatternData`）

```gdscript
class_name PatternData
extends RefCounted

## 读 + 校验；任何失败返回空字典 {} 并 push_warning（绝不崩溃）
static func load_pattern(name: String) -> Dictionary

## 7 个图案名（顺序同 PatternSchema.PATTERNS）
static func list_patterns() -> Array[String]

## 该图案文件是否存在
static func exists(name: String) -> bool

## 统计信息：{ "region_count": int, "total_area": float }
static func summarize(pattern: Dictionary) -> Dictionary
```

---

## 5. PaintState（autoload `PaintState`，`scripts/autoload/paint_state.gd`）

单一状态源：当前图案、笔刷、每个区域已累积的颜色、存盘/导出。

```gdscript
extends Node

signal pattern_loaded(pattern_name: String)
signal region_painted(region_id: String, new_color: Color, hit_ids: Array)
signal brush_changed(color: Color)
signal strength_changed(strength: float)
signal artwork_saved(path: String)
signal artwork_loaded(path: String)
signal artwork_exported(path: String)
signal state_reset()

const SAVE_PATH := "user://artwork.json"
const EXPORT_PATH := "user://artwork.png"
const SAVE_VERSION := 1

var pattern_name: String = ""        # 当前图案名，未加载时 ""
var pattern: Dictionary = {}         # 当前图案完整字典
var brush_color: Color               # 初始 = PaletteDef.palette_color(0)
var brush_strength: float            # 初始 = PaletteDef.DEFAULT_STRENGTH
var colors: Dictionary = {}          # region_id -> Color（已累积）

func load_pattern(name: String) -> Error         # 失败返回 ERR_DOES_NOT_EXIST / ERR_PARSE_ERROR
func set_brush(color: Color) -> void
func set_brush_strength(v: float) -> void        # 夹到 0.05 ~ 1.0
func region_color(region_id: String) -> Color    # 未记录则返回 PaletteDef.BASE_COLOR
func apply_to_region(region_id: String) -> Color # 加色叠加；返回新颜色
func apply_to_regions(region_ids: Array) -> Color# 多个区域各加一遍；返回第一个的新颜色
func reset_region(region_id: String) -> void
func reset_all() -> void
func painted_count() -> int                      # 非底色的区域数
func region_count() -> int
func to_dict() -> Dictionary
func from_dict(d: Dictionary) -> Error
func save_artwork(path: String = SAVE_PATH) -> Error
func load_artwork(path: String = SAVE_PATH) -> Error
func export_png(path: String = EXPORT_PATH) -> Error
```

**硬性要求**

1. `apply_to_region` **必须**调 `PaletteDef.add_color`，不许自己写加色公式。
2. `apply_to_regions` 对**每个命中区域各自**调一次 `PaletteDef.add_color`（各自基于自己的当前色相加），
   返回第一个命中区域的新颜色。`PaletteDef.add_many` 供调色板的"混色预览"（`mixed_preview()`）使用 ——
   它演示"多个颜色加色求和"的语义（红+绿+蓝 = 白）。
3. `load_pattern` 后 `colors` 重置为**空字典**（未涂色区域用 `BASE_COLOR` 隐式表示），
   并发 `pattern_loaded`。加载失败时**保持原状态不变**。
4. `to_dict()` 返回 `{ "version": 1, "pattern": <name>, "colors": { id: [r,g,b,a] } }`。
5. `from_dict` / `load_artwork` 对脏数据必须**返回错误码且不崩溃**：
   - 文件不存在 → `ERR_FILE_NOT_FOUND`
   - JSON 解析失败 / 顶层非 Dictionary / 缺 `pattern` 或 `colors` → `ERR_PARSE_ERROR`
   - `pattern` 不是 7 个之一 → `ERR_INVALID_DATA`
   - `colors` 里**未知 region_id 或非法颜色值**：跳过该项，其余照常载入（不报错）
6. `export_png` 调 `ArtworkExport.export_png(pattern, colors, PatternSchema.CANVAS_SIZE, path)`。
7. headless 下必须不报错（不能依赖 GPU 截图）。

---

## 6. ColorRegion（`scripts/color_region.gd`，`class_name ColorRegion extends Area2D`）

一个可涂色区域 = `Area2D`（碰撞层 **2**）+ `CollisionPolygon2D` + `Polygon2D`（填充）+ `Line2D`（描边）。

```gdscript
class_name ColorRegion
extends Area2D

const LAYER := 2          # 碰撞层 2（project.godot 里命名为 color_region）

var region_id: String
var label: String
var polygon: PackedVector2Array
var z_order: int

func setup(region_dict: Dictionary) -> void      # 建子节点、设碰撞层、设多边形
func set_fill_color(c: Color) -> void
func fill_color() -> Color
func set_highlight(on: bool) -> void             # 悬停/命中高亮（描边变亮变粗）
func play_fill_flash() -> void                   # Tween：亮度脉冲，见下
func centroid() -> Vector2
func area() -> float
```

**硬性要求**

1. `setup()` 里：`collision_layer = 1 << (LAYER - 1)`、`collision_mask = 0`、
   `monitoring = false`、`monitorable = true`（我们只用 direct space state 查询，不需要 overlap 信号）。
   `CollisionPolygon2D.build_mode` 用默认的 `BUILD_SOLIDS`（凹多边形会自动分解）。
2. 描边 `Line2D` 用**亮色**（如 `Color(0.75, 0.85, 1.0)`）、`width = 2.5`、**闭合**（末点接回首点）。
   这是暗底上让图案"读得出来"的关键。
3. `play_fill_flash()` 用 `Fx.fill_flash(self)`（§7），**必须可重复触发不堆叠**：
   每次调用先 `kill` 掉上一个 tween（把 tween 存在成员变量里）。
4. `set_highlight(on)` 只改描边外观，不改填充色。

---

## 7. Fx（`scripts/fx.gd`，`class_name Fx`）—— demo 重点 2

```gdscript
class_name Fx
extends RefCounted

## 填色脉冲：把节点的 modulate 从亮到正常，0.25s
static func fill_flash(node: CanvasItem, duration := 0.25) -> Tween

## 色板选中脉冲：scale 1.0 -> 1.18 -> 1.0，0.18s
static func swatch_pop(node: Control, duration := 0.18) -> Tween

## 错峰入场：对每个节点做 alpha 0->1 的淡入，第 i 个延迟 i * step
static func stagger_intro(nodes: Array, step := 0.02, duration := 0.3) -> Tween

## 悬停呼吸（可选）：轻微上下浮动
static func float_loop(node: Node2D, amplitude := 6.0, period := 1.6) -> Tween
```

**硬性要求**：全部用 `create_tween()`；`stagger_intro` 用 `set_parallel` + `tween_interval`
或逐个 `tween_property` 并设置 `set_delay`，**总时长必须约等于 `(n-1)*step + duration`**（测试会断言）。
每个函数返回 `Tween`，调用方负责保存并在下次调用前 `kill()`。

---

## 8. CanvasView（`scripts/canvas_view.gd`，`class_name CanvasView extends Node2D`）—— demo 重点 1

```gdscript
class_name CanvasView
extends Node2D

## hits 是**本次点查询命中的全部** region_id（可能多个），顺序 = 查询返回顺序
signal region_hit(hit_ids: Array, painted_id: String)
signal canvas_rebuilt(region_count: int)

const MAX_HITS := 32

func build_from_pattern(d: Dictionary) -> void   # 清空 + 按 z 升序建区域
func clear_regions() -> void
func region_count() -> int
func region_node(region_id: String) -> ColorRegion
func region_ids() -> Array[String]

## demo 重点 1 的核心：PhysicsPointQuery
func pick_region_ids(world_pos: Vector2) -> Array[String]

## 点查询 + 上色：返回被涂的 region_id（"" = 没命中任何区域）
func paint_at(world_pos: Vector2) -> String

## 把屏幕/父节点坐标换算成本 Node2D 的局部坐标
func to_local_pos(global_pos: Vector2) -> Vector2
```

**硬性要求**

1. `pick_region_ids` **必须**这样实现（这是 demo 的展示点，代码要清晰）：
   ```gdscript
   var space := get_world_2d().direct_space_state
   var params := PhysicsPointQueryParameters2D.new()
   params.position = world_pos
   params.collide_with_areas = true
   params.collide_with_bodies = false
   params.collision_mask = 1 << (ColorRegion.LAYER - 1)
   var hits := space.intersect_point(params, MAX_HITS)
   ```
   然后从 `hits[i]["collider"]` 取 `ColorRegion` 并收集 `region_id`。
   **必须用 `intersect_point`**，不许退化成自己遍历多边形做 `point_in_polygon`。
2. `paint_at` 命中后调 `PaintState.apply_to_regions(hit_ids)`，并让**每个**命中区域播 `play_fill_flash()`。
3. `region_hit` 信号必须把**完整命中列表**发出去（UI 要显示"本次命中 N 个区域"）。
4. 区域按 `z` 升序添加子节点（后加的在上）。
5. `build_from_pattern` 后发 `canvas_rebuilt(region_count)`。
6. headless 下必须能用（点查询不依赖渲染）。**测试在查询前必须 `await get_tree().physics_frame`**，
   让形状注册进物理空间。

---

## 9. ArtworkExport（`scripts/artwork_export.gd`，`class_name ArtworkExport`）

**纯逻辑扫描线光栅化**，不依赖 GPU，headless 下可测。

```gdscript
class_name ArtworkExport
extends RefCounted

## 把图案 + 颜色光栅化成 Image。
## 背景 = PaletteDef.BASE_COLOR；按 z 升序把每个区域用 even-odd 扫描线填成它的颜色。
static func rasterize(pattern: Dictionary, colors: Dictionary, size: Vector2i) -> Image

## 光栅化后 save_png(path)；返回 OK / 错误码
static func export_png(pattern: Dictionary, colors: Dictionary, size: Vector2i, path: String) -> Error
```

**硬性要求**

1. `Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)`，先填背景色。
2. 扫描线填充：对每条扫描线 `y + 0.5`，求多边形所有边的交点，按 x 排序，
   **even-odd 规则**成对填充。
3. `colors` 里没有的 region_id 用 `PaletteDef.BASE_COLOR`。
4. 未知/非法颜色值**跳过**，不崩溃。
5. 返回的 `Image` 尺寸必须是 `size`，且**至少有一个像素非背景色**（前提是 colors 非空且坐标合法）。

---

## 10. PalettePanel（`scripts/palette_panel.gd`，`class_name PalettePanel extends Control`）

```gdscript
class_name PalettePanel
extends Control

signal color_selected(color: Color)
signal strength_changed(strength: float)

func build() -> void                       # 全代码创建控件
func set_selected(color: Color) -> void    # 更新选中态 + 播 Fx.swatch_pop
func swatch_count() -> int                 # == PaletteDef.palette_size() == 16
func swatch_at(i: int) -> Control          # 取第 i 个色块（测试用）
func selected_color() -> Color
```

**硬性要求**

1. 16 个色块，**4 列 × 4 行**网格；每个色块是 `Button` 或 `ColorRect`（能接 `pressed`/`gui_input`）。
   色块上显示颜色名（小字）。
2. 前 7 个（`PALETTE[i]["demo"] == true`）要有**明显区分**（例如加一圈金色描边 + 上方分组标题
   "加色三原色与混色"），因为它们是 demo 重点 3 的演示色。
3. 一个"笔刷强度" `HSlider`（0.05 ~ 1.0），初始 `PaletteDef.DEFAULT_STRENGTH`。
4. 一个"当前颜色"预览色块 + 一个"当前区域累积色"预览色块（后者由外部调 `set_region_preview()` 更新）：
   ```gdscript
   func set_region_preview(c: Color) -> void
   ```
5. 选中色块要 `Fx.swatch_pop()`。
6. 全代码创建，不依赖 .tscn 子节点。

---

## 11. ColorHud（`scripts/hud.gd`，`class_name ColorHud extends Control`）

顶栏。全代码创建。必须包含：

- **图案选择**：7 个按钮（或 `OptionButton`），文案用 `PatternSchema.display_name()`
- **操作按钮**：`保存`、`载入`、`导出PNG`、`重置`
- **状态栏**：`当前图案` / `已涂 N/M 区域` / `本次命中 K 个区域` / `笔刷强度`
- **命中演示区**（demo 重点 1 的可视化）：显示最近一次点查询命中的 region_id 列表与个数

```gdscript
class_name ColorHud
extends Control

func build() -> void
func refresh() -> void
func set_hit_info(hit_ids: Array) -> void      # 更新"本次命中"
func button(name: String) -> Button            # 按节点名取按钮（测试用）
func pattern_button(name: String) -> Button
func status_text() -> String
```

**硬性要求**：按钮名固定为 `SaveButton` / `LoadButton` / `ExportButton` / `ResetButton`；
图案按钮名固定为 `Pattern_<name>`（如 `Pattern_flower`）。

---

## 12. main.gd（`scripts/main.gd`，`extends Control`）

装配根场景。要求：

1. 创建背景、`CanvasView`、`PalettePanel`、`ColorHud`，布局合理：
   顶部 HUD（约 64px）→ 左侧画布区（512×512 居中）→ 右侧色板（约 320px 宽）。
2. 画布放一个 `Node2D` 容器，**位置设为画布区中心**，使图案坐标 (0,0)-(512,512) 落在画布区内。
3. 接线：
   - 点击画布（`_unhandled_input` 或 `CanvasView` 的 `_input`）→ `CanvasView.paint_at(位置)`
   - `CanvasView.region_hit` → `ColorHud.set_hit_info()` + `PalettePanel.set_region_preview()`
   - `PalettePanel.color_selected` → `PaintState.set_brush()`
   - `ColorHud` 的按钮 → `PaintState.save_artwork/load_artwork/export_png/reset_all`
   - `PaintState.pattern_loaded` → `CanvasView.build_from_pattern()` + `Fx.stagger_intro()`
4. 启动时自动加载第一个图案 `flower`。
5. 窗口缩放时重排。

---

## 13. tests（`tests/test_scene.tscn` + `tests/test_runner.gd`）

运行方式（**必须用 console 版**）：
```powershell
& "C:\Hub\program\godot-4\Godot_v4.7.2-stable_win64_console.exe" --headless --path "C:\Hub\workspace\godot-game-practice\003-color-garden" --log-file "$env:TEMP\cg.log" res://tests/test_scene.tscn
```

要求覆盖（断言**行为**，不只是"节点存在"）：

- **Schema / 数据**：7 个图案文件全部存在；`PatternSchema.validate_pattern()` 对每个都返回**空错误数组**；
  每个图案区域数在 6~16；所有 id 唯一；所有坐标在界内；无 `holes`；
  `polygon_area() > 0`；`polygon_centroid()` 落在多边形内。
- **PaletteDef**：`add_color` 逐通道相加并夹到 1.0（红+绿→黄、红+蓝→品红、绿+蓝→青、三色→白，逐通道断言）；
  `add_many` 等价于依次 `add_color`；`is_base(BASE_COLOR)` 为真；`array_to_color` 对脏数据返回 BASE_COLOR 不崩溃。
- **PaintState**：`load_pattern` 后 `region_count()` 与 JSON 一致、`painted_count() == 0`；
  `apply_to_region` 后颜色 = `add_color(底色, 笔刷, 强度)` 且 `painted_count() == 1`；
  **连涂同一区域两次**结果 = 两次相加（不是覆盖）；`reset_region` / `reset_all` 生效；
  `set_brush_strength(5.0)` 夹到 1.0、`(0.0)` 夹到 0.05。
- **存盘往返**：涂 3 个区域 → `save_artwork` 返回 OK → `reset_all` → `load_artwork` 返回 OK →
  三个区域颜色与存盘前**逐通道相等**；`painted_count()` 一致。
- **脏数据**：不存在文件 → `ERR_FILE_NOT_FOUND`；`{not json` → `ERR_PARSE_ERROR`；
  顶层 `[]` → `ERR_PARSE_ERROR`；`pattern` 填 `"nope"` → `ERR_INVALID_DATA`；
  `colors` 里塞未知 id 与非法颜色 → 跳过且不崩溃。**每种都要断言错误码，不是"没崩就行"**。
- **PhysicsPointQuery（重点 1）**：`build_from_pattern(flower)` → `await physics_frame` →
  取某个区域的 `centroid()` 作为查询点 → `pick_region_ids()` **非空且包含该 region_id**；
  取一个**远离所有区域**的点（如 (5,5) 若该处无区域，或 (511,511)）→ 返回**空数组**；
  `paint_at(区域形心)` 返回该 id 且 `PaintState.painted_count() == 1`；
  断言 `pick_region_ids` 确实走了 `intersect_point`（例如：临时把某个区域的 `collision_layer` 清 0，
  再查询该区域形心 → 应命中不到。这条能证明检测真的依赖物理形状，而不是几何兜底）。
- **加色混合（重点 3）**：选红 → 涂区域 → 再选绿 → 再涂同一区域 →
  结果 r 与 g 都 > 0 且 b 接近底色（即真的相加，不是覆盖）；连涂到饱和后不再超过 1.0。
- **Tween（重点 2）**：`Fx.fill_flash(node)` 返回 `Tween` 且 `is_valid()`；
  **重复调用不堆叠**（连调 3 次后，节点上活跃的 fill tween 数 == 1 —— 通过 `ColorRegion` 暴露的
  `active_tween_count()` 或 `Fx` 的静态计数来断言，实现方式由 S4 决定但要可测）；
  `Fx.stagger_intro` 对 5 个节点返回的 Tween 总时长 ≈ `4*step + duration`（容差 20%）。
- **导出 PNG**：涂 2 个区域 → `export_png` 返回 OK → 文件存在且 > 0 字节 →
  重新读回 `Image` 尺寸 == 512×512 → **至少一个像素不是背景色**。
- **UI**：`PalettePanel.swatch_count() == 16`；`PalettePanel.swatch_at(i)` 非 null；
  `ColorHud.button("SaveButton")` 等四个按钮非 null；7 个 `Pattern_<name>` 按钮非 null。

### 13.1 必须遵守的测试纪律（都是实测踩过的坑）

1. **`_ready()` 里必须 `await` 每一个测试函数**。漏写 `await` 会让协程永久停在第一个 `await` 处，
   `_ready()` 一返回进程就结束 —— **退出码 0、无 SCRIPT ERROR、无任何报错**，而没跑到的断言不计入总数。
   实测出现过 `TESTS: 76/76 passed + ALL PASS` 但整段断言一条没跑。必须加**看门狗超时**兜底。
2. **Godot 退出码不可靠**：发生 `SCRIPT ERROR` 时仍可能返回 0。必须自己 `get_tree().quit(1)`，
   并同时 grep 输出里的 `SCRIPT ERROR` / `Parse Error`。
3. **等待真实时间要自旋，不要用 `create_timer` 等短间隔**：
   ```gdscript
   var t0 := Time.get_ticks_msec()
   while Time.get_ticks_msec() - t0 < 50:
       await get_tree().process_frame
   ```
   headless 首帧的 `create_timer(0.05)` 只走 0~2ms。
4. **不要写同义反复断言**：边界值用**字面量**，不要拿被测量的常量比自己。
   例如断言色板数量要写 `== 16`，不能写 `== PaletteDef.palette_size()`。
5. `--check-only --script` 对引用 autoload 的脚本会假报 `Identifier not found`，**那是工具限制不是代码错误**。
   验证只能靠完整工程运行。
6. **「计数型」断言必须建立在真实计数上，不能是硬编码常量。**
   实测教训：`active_tween_count()` 最初只保留最后一个 tween 并把返回值写死成 0/1，
   导致「连调 3 次不堆叠」这条断言**永远成立**；变异测试（去掉 kill、故意堆叠）跑出 **236 全绿**，
   完全没抓到。改成逐个检查 `is_running()` 的真实计数后，同一变异立即产生 `expected=1 actual=4`。
   **凡断言"数量/上限/是否重复"，先证明计数器不是常量。**
7. **核对断言总数要用 stdout，不要用 `--log-file`。**
   `--log-file` 会丢行（实测 236 条断言只落盘 213 条 `PASS`）。用 `> out.txt 2>&1` 重定向才完整。
8. **写完测试要用变异测试自证不空洞**：故意改坏被测行为，确认测试**会失败**，然后还原。
   没被任何变异杀死的断言，等于没写。本项目 4 个变异中 M3 曾存活，就是靠这一步发现的。

---

### 13.2 子 Agent 运行约束（实测得出，必须遵守）

本工程的子 Agent 运行在 `step-5-preview-free` 模型上，并发数固定为 **1**（串行）。
主 Agent 实测出的能力边界，**违反会导致任务直接失败（Agent 无任何产物）**：

1. **单轮输出长度有限。**
   - ✅ 极简多步任务（写小文件 + 跑 2 条 pwsh 命令）→ 成功
   - ❌ 要求一次性写出 **≥120 行**的文件 → **失败，零产物**
   - ✅ **改为分 3 块、每块 ≤40 行写入 → 成功**（最终 130 行）
   → **任何超过约 60 行的文件，必须分块写**：
   第一块用 `write` 创建，并在末尾留一行标记 `# --- END PART 1 ---`；
   后续每块用 `edit` 把上一块的标记替换成「新内容 + `# --- END PART n ---`」。**每块 ≤ 40 行。**
2. **不要让子 Agent 去读大文件**（例如本契约 26KB）。任务提示必须**自包含**，
   把需要的规格直接内联进提示里。契约是给人和主 Agent 看的，不是给子 Agent 读的。
3. 任务要**小而聚焦**。不要跑长耗时命令（Blender 启动约 0.5 秒，可接受）；
   单条命令超过 60 秒就停下来报告，不要硬等。

## 14. 分阶段与文件归属（串行执行，一次只有一个 Agent）

> **纪律：只改分配给你的文件。** 不许重排/格式化不属于你的文件（曾发生子 Agent 把
> `INTERFACES.md` 的行首空格改成 Tab 的事故）。不许改 `project.godot`、
> `scripts/palette_def.gd`、`scripts/pattern_schema.gd`、`docs/INTERFACES.md`。

| 阶段 | 负责文件 | 交付 |
|---|---|---|
| **S1 素材** | `tools/generate_patterns.py`、`assets/patterns/*.json` | 7 个 JSON，全部通过 `validate_pattern` |
| **S2 核心** | `scripts/pattern_data.gd`、`scripts/color_region.gd`、`scripts/canvas_view.gd`、`scripts/autoload/paint_state.gd`、`scripts/main.gd`、`scripts/fx.gd` | 点查询 + 加色上色可用（无 UI 也能用程序化调用验证） |
| **S3 UI** | `scripts/palette_panel.gd`、`scripts/hud.gd`、`scripts/main.gd`（加 UI 装配）、`scripts/color_region.gd`（接 Fx） | 完整可交互界面 |
| **S4 持久化** | `scripts/artwork_export.gd`、`scripts/autoload/paint_state.gd`（加存盘/导出）、`scripts/hud.gd`（接按钮） | 保存/载入/导出 PNG |
| **S5 测试** | `tests/*` | headless 套件全绿 |
| **S6 验收** | 只读 + 报告 | 对抗性报告（含变异测试） |

**执行环境提醒**：子 Agent 运行在 `step-5-preview-free` 模型上，**任务要小而聚焦**。
禁止运行长耗时命令（Blender 启动约 0.5s 是可接受的；不要跑全场景渲染、不要开编辑器）。
若某条命令超过 60 秒，停下来报告，不要硬等。

---

## 15. 通用纪律

- GDScript，**缩进用 Tab**，注释用中文。
- 不要手写 `uid://`；`.tscn` 里引用脚本用 `path="res://..."`。
- 不引入任何第三方 Godot 插件或 GDExtension。
- 提交前自检：`godot --headless --path . --quit` 退出码 0 且无 `SCRIPT ERROR` / `Parse Error`。
- **跑 Godot 时优先复制到 `%TEMP%` 再跑**，避免与别的 Agent 争抢 `.godot` 缓存。
