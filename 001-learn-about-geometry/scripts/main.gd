extends Node
## ============================================================
## 开始页脚本（挂在 start_screen.tscn 的根节点上）
## 职责只有一个：等用户点按钮，然后切换到别的场景。
## ============================================================

# 用常量存场景路径：将来改文件名只改这里，而且拼写错误在编译期就能发现
const LOADING_SCREEN_SCENE := "res://scenes/loading_screen.tscn"
const LEADERBOARD_SCENE := "res://scenes/leaderboard.tscn"

# @onready = 等节点都进场景树、_ready() 之后再取值。
# 新手最容易踩的坑：在变量声明处直接 $按钮 会拿到 null，因为场景还没加载完。
@onready var button_start_game: Button = $Button_Start_Game
@onready var button_ranking: Button = $Button_Ranking

# 类似构造函数的入口：节点第一次出现在场景里时自动调用一次
func _ready() -> void:
	# 信号连接：把按钮的 pressed（按下）信号连到下面的处理函数。
	# connect() 之后，每次按钮被按下，Godot 就会自动调用 _on_button_start_game_pressed()。
	# 也可以不写代码，在编辑器 Node 面板的 Signals 标签里双击连接（效果一样）。
	button_start_game.pressed.connect(_on_button_start_game_pressed)
	button_ranking.pressed.connect(_on_button_ranking_pressed)


func _on_button_start_game_pressed() -> void:
	# 切换场景：整个加载新场景、卸载旧场景。
	# 注意 start_screen 上的所有数据都会消失 —— 跨场景的数据要放 GameState 单例（见 autoload）。
	get_tree().change_scene_to_file(LOADING_SCREEN_SCENE)


func _on_button_ranking_pressed() -> void:
	get_tree().change_scene_to_file(LEADERBOARD_SCENE)
