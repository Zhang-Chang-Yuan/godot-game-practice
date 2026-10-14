extends Node2D
## ============================================================
## 加载页脚本（挂在 loading_screen.tscn 根节点上）
## 流程三段式：生成 10 道题 → 异步预加载 6 个模型 → 切到答题页。
## ============================================================

# ============ 节点引用 ============
# @onready：晚于场景加载再取值，保证不是 null（新手常见坑）
@onready var progress_bar: ProgressBar = $ProgressBar
@onready var tip_label: Label = $TipLabel
@onready var loading_timer: Timer = $LoadingTimer

# ============ 常量 ============
const GEN_PROGRESS := 20.0     # 阶段 1（生成题目）占 20% 进度
const MIN_DISPLAY_SEC := 0.6   # 加载页最短展示时间，防止一闪而过
const NEXT_SCENE := "res://scenes/quiz.tscn"

const TIPS := [
	"小提示：圆柱和圆锥长得像哦",
	"小提示：正方体有 6 个面",
	"小提示：球体没有棱角",
	"小提示：棱柱的侧面都是长方形",
]

# ============ 生命周期 ============
func _ready() -> void:
	# 初始化进度条：min/max/value 三个值都要给，不然显示可能不对
	progress_bar.min_value = 0
	progress_bar.max_value = 100
	progress_bar.value = 0
	tip_label.text = TIPS.pick_random()

	# 这一步是异步流程：函数里带 await，执行到那里会"挂起"，
	# 等条件满足后自动继续，不需要自己开线程，UI 也不会卡。
	_run_loading()

# ============ 主流程（三段式）============
## 注意：这不是普通函数，是"协程"——函数里出现 await 后，
## 调用方不需要等它，它自己会按顺序推进。
func _run_loading() -> void:
	# ---------- 阶段 1：生成 10 道题（瞬间完成）----------
	# 题目数据存进 GameState 单例；本场景结束后数据不丢
	GameState.start_new_game()
	progress_bar.value = GEN_PROGRESS
	await get_tree().process_frame   # 给 UI 一帧时间把 20% 画出来

	# ---------- 阶段 2：异步预加载 6 个模型 ----------
	await _preload_models()

	# ---------- 阶段 3：交接 ----------
	progress_bar.value = 100
	loading_timer.start()            # 启动一个 0.6 秒的计时器
	await loading_timer.timeout      # await 信号：等到计时器 timeout 信号发出
	get_tree().change_scene_to_file(NEXT_SCENE)

# ============ 阶段 2 的实现 ============
## 异步预加载：让引擎在后台线程加载资源，主线程每帧只问进度、更新进度条。
## 这样界面不卡；资源大的游戏（几十 MB）必须这样做。
func _preload_models() -> void:
	GameState.model_cache.clear()

	var paths: Array = GameState.MODEL_PATHS
	var total: int = paths.size()

	# 1) 全部丢给后台去加载
	for p in paths:
		ResourceLoader.load_threaded_request(p)

	# 2) 轮询状态，直到全部处理完
	var pending: Array = paths.duplicate()
	while not pending.is_empty():
		var still_pending: Array = []
		for p in pending:
			var status: int = ResourceLoader.load_threaded_get_status(p)
			match status:
				ResourceLoader.THREAD_LOAD_IN_PROGRESS:
					still_pending.append(p)          # 还在加载，下一轮再问
				ResourceLoader.THREAD_LOAD_LOADED:
					var res: Resource = ResourceLoader.load_threaded_get(p)
					GameState.model_cache[p] = res   # 加载好的资源存进缓存字典
				ResourceLoader.THREAD_LOAD_FAILED:
					push_error("模型加载失败：%s" % p)
		pending = still_pending

		# 3) 刷新进度条：已完成数 / 总数，映射到 20%~100% 区间
		var done: int = total - pending.size()
		var ratio: float = float(done) / float(total)
		progress_bar.value = GEN_PROGRESS + ratio * (100.0 - GEN_PROGRESS)

		# 4) 灵魂一行：让出一帧，否则 while 循环会一口气跑完，UI 冻住不动
		await get_tree().process_frame
