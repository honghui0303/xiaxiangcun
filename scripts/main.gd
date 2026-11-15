extends Node2D

## 修仙小院 - 主场景
## 职责只有三件：摆放窗口、组装各层、控制功耗。
## 具体玩法逻辑不写在这里，接线顺序就是依赖顺序：sim → task_board / yard → pawn / hud。

const SimScript := preload("res://scripts/sim.gd")
const TaskBoardScript := preload("res://scripts/task_board.gd")
const YardScript := preload("res://scripts/yard.gd")
const PawnScript := preload("res://scripts/pawn.gd")
const HudScript := preload("res://scripts/hud.gd")
const LogBookScript := preload("res://scripts/logbook.gd")
const LogLineScript := preload("res://scripts/log_line.gd")
const DogScript := preload("res://scripts/dog.gd")

const WIN_H := 264
const WIN_MAX_W := 2400
const SHOT_PATH := "C:/Users/xuhon/Desktop/anbian-xiaoyuan-main/_render.png"

var sim: SimScript
var board: TaskBoardScript
var yard: YardScript
var pawn: PawnScript
var hud: HudScript
var logbook: LogBookScript
var logline: LogLineScript
var dog: DogScript

var _headless := false

func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"
	if not _headless:
		_layout_window()
	_build()
	if _headless:
		print("[main] headless：跳过窗口摆放与截图")
		return
	_report()
	await _capture_after_delay()

## 开发用：`-- --capture=秒数` 延迟指定秒数再截图并退出。
## 桌面被别的全屏程序占住时，屏幕截图只能拍到遮挡物，只能让引擎自己导出画面。
func _capture_after_delay() -> void:
	var sec := 1.5
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--capture="):
			sec = float(arg.split("=")[1])
	await get_tree().create_timer(sec).timeout
	var img := get_viewport().get_texture().get_image()
	img.save_png(SHOT_PATH)
	print("[dbg] saved render ", img.get_size())
	if sec > 2.0:
		get_tree().quit()

func _report() -> void:
	print("[dbg] usable=", DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen()))
	print("[dbg] win_size=", DisplayServer.window_get_size(), " win_pos=", DisplayServer.window_get_position())
	print("[dbg] viewport=", get_viewport().get_visible_rect())
	print("[dbg] screen_max_scale=", DisplayServer.screen_get_max_scale())

func _layout_window() -> void:
	DisplayServer.window_set_title("xianxia-yard")
	var screen_id := DisplayServer.window_get_current_screen()
	var usable: Rect2i = DisplayServer.screen_get_usable_rect(screen_id)

	var w: int = mini(usable.size.x, WIN_MAX_W)
	var x: int = usable.position.x + int((usable.size.x - w) * 0.5)
	var y: int = usable.position.y + usable.size.y - WIN_H

	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	DisplayServer.window_set_size(Vector2i(w, WIN_H))
	DisplayServer.window_set_position(Vector2i(x, y))

	# 挂机游戏的地铁规矩：没人看的时候别烧电
	OS.low_processor_usage_mode = true
	OS.low_processor_usage_mode_sleep_usec = 16000

func _build() -> void:
	# 1) 模拟层：所有数值的唯一权威。_ready 里会读存档 + 补算离线时间。
	sim = SimScript.new()
	sim.name = "Sim"
	add_child(sim)

	# 2) 日志引擎：只读 sim 的累计在线秒数，按"游戏日"决定什么时候该出一句话。
	#    它不参与任何数值，也不写存档——状态全部由 tick_count 推导，见 logbook.gd 顶部注释。
	logbook = LogBookScript.new()
	logbook.name = "LogBook"
	add_child(logbook)
	logbook.bind_sim(sim)

	# 3) 那行字：z_index=5，压在小院之上、小人之下，只负责淡入淡出
	logline = LogLineScript.new()
	logline.name = "LogLine"
	add_child(logline)
	logline.bind_logbook(logbook)

	# 4) 绘制层：需要 sim 才能按地块状态画灵草
	yard = YardScript.new()
	yard.name = "Yard"
	yard.set_sim(sim)
	add_child(yard)

	# 5) 派活板：只依赖 sim
	board = TaskBoardScript.new()
	board.name = "TaskBoard"
	board.setup(sim)
	add_child(board)

	# 6) 狗：不参与任何数值，只在院子里走、停、趴着。
	#    出现与消失都挂在日志的"天"上（第 96 天来，第 900 天走），见 dog.gd 顶部注释。
	dog = DogScript.new()
	dog.name = "Dog"
	add_child(dog)
	dog.bind_logbook(logbook)
	# 狗第一次在墙根趴下 → 日志 3.3（a）那条（"狗趴在门槛上……"）。
	# 日志引擎看不见狗，只能由狗喊一声，见 logbook.mark()。
	dog.lay_at_door.connect(func(): logbook.mark("dog:door"))

	# 7) 小人：依赖 board（领活）+ yard（坐标）
	pawn = PawnScript.new()
	pawn.name = "Pawn"
	pawn.z_index = 10
	pawn.scale = Vector2(1.3, 1.3)
	pawn.setup(board, yard)
	add_child(pawn)

	# 8) HUD：读 sim，并接小人的动作提示
	var layer := CanvasLayer.new()
	layer.name = "HudLayer"
	add_child(layer)

	hud = HudScript.new()
	hud.name = "Hud"
	hud.bind_sim(sim)
	layer.add_child(hud)
	pawn.action_changed.connect(hud.set_action)

	# 9) 离线回来的话，把「一觉醒来」小结交给 HUD（12 秒后自动淡出）
	hud.show_offline_summary(sim.get_offline_report())
