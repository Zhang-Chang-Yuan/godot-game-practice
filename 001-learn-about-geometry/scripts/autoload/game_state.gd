extends Node
# 全游戏的"冰箱"：所有跨场景数据都放这里

# ============ 字段清单 ============
var questions: Array = []         # 10 道题，每题 { "answer": 路径, "options": [4 条路径] }
var question_index: int = 0       # 当前第几题（0~9）
var score: int = 0                # 当前得分
var quiz_start_msec: int = 0      # 本局开始时间戳（quiz 里记）
var total_msec: int = 0           # 本局总用时（结算时算，写排行榜用）
var model_cache: Dictionary = {}  # 路径 -> PackedScene / Node3D 资源缓存

# ============ 常量 ============
# 6 个模型路径（替换成你自己的实际路径！）
const MODEL_PATHS := [
	"res://models/Cone.glb",
	"res://models/Cube.glb",
	"res://models/Cuboid.glb",
	"res://models/Cylinder.glb",
	"res://models/Pyramid.glb",
	"res://models/Sphere.glb",
]

const QUESTION_COUNT := 10
const OPTION_COUNT := 4

# ============ 生命周期 ============
func _ready() -> void:
	# 全游戏只调一次；不调的话每次运行随机序列一样，10 题永远相同
	randomize()

# ============ 对外方法 ============

## 重开一局：清计数 + 重新生成题目
func start_new_game() -> void:
	question_index = 0
	score = 0
	quiz_start_msec = 0
	generate_questions()

## 生成 10 道题（阶段 1 的核心逻辑）
func generate_questions() -> void:
	questions.clear()
	for i in QUESTION_COUNT:
		# 1. 从 6 个模型随机抽 1 个当答案
		var answer: String = MODEL_PATHS.pick_random()

		# 2. 从"去掉答案的 5 个"里抽 3 个干扰项（保证选项不重复）
		var pool: Array = MODEL_PATHS.filter(func(p): return p != answer)
		pool.shuffle()
		var distractors: Array = pool.slice(0, OPTION_COUNT - 1)

		# 3. 合并答案 + 干扰项，打乱顺序
		var options: Array = distractors.duplicate()
		options.append(answer)
		options.shuffle()

		# 4. 存进 questions
		questions.append({
			"answer": answer,
			"options": options,
		})

## 便利方法：拿当前题目
func get_current_question() -> Dictionary:
	if question_index < 0 or question_index >= questions.size():
		return {}
	return questions[question_index]

## 便利方法：全部答完了吗
func is_finished() -> bool:
	return question_index >= questions.size()
