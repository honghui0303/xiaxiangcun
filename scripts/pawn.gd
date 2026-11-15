extends Node2D

## 小人
##
## 职责只有四步：向 TaskBoard 领任务 → 走到目标点 → 把动作演完 → 回报 Sim 结算。
## 这里不做任何规则判断（不选点、不算产出、不判优先级），
## 派活优先级在 sim.pick_intent()，数值在 sim.gd，坐标在 yard.gd。

const SimScript := preload("res://scripts/sim.gd")
const TaskBoardScript := preload("res://scripts/task_board.gd")
const YardScript := preload("res://scripts/yard.gd")

## HUD 右上角的一句话提示（空串表示待命）
signal action_changed(text: String)

const BASE_Y := 194.0
const SPEED := 44.0
const ARRIVE_EPS := 1.5     # 到这个距离内就算站到位了

const C_ROBE := Color(0.14, 0.22, 0.26)
const C_ROBE_HI := Color(0.22, 0.34, 0.38)
const C_SKIN := Color(0.80, 0.72, 0.60)
const C_HAIR := Color(0.06, 0.08, 0.09)

enum State { IDLE, WALK, ACT }

var board: TaskBoardScript = null
var yard: YardScript = null

var _state: State = State.IDLE
var _task: Dictionary = {}
var _target := Vector2.ZERO
var _act_left := 0.0
var _act_total := 0.0
var _walk_phase := 0.0
var _work_phase := 0.0
var _walk_by_kind: Dictionary = {}   # 仅统计：各动作类型花在路上的秒数

func setup(board_ref: TaskBoardScript, yard_ref: YardScript) -> void:
	board = board_ref
	yard = yard_ref

func _ready() -> void:
	if yard != null:
		position = yard.get_meditate_point()
	else:
		position = Vector2(640, BASE_Y)
	_state = State.IDLE

# ============================================================
# 状态机
# ============================================================

func _process(delta: float) -> void:
	match _state:
		State.IDLE:
			_take_task()
		State.WALK:
			_walk(delta)
		State.ACT:
			_act(delta)
	queue_redraw()

## 领任务：任何时刻只持有一个
func _take_task() -> void:
	if board == null:
		return
	var task := board.request_task()
	if task.is_empty():
		return
	_task = task
	_target = _point_for(task)
	_state = State.WALK
	action_changed.emit(String(task.get("label", "")))

func _walk(delta: float) -> void:
	_walk_phase += delta * 11.0
	var to := _target - position
	var dist := to.length()
	if dist <= ARRIVE_EPS:
		position = _target
		_begin_act()
		return
	var step := minf(SPEED * delta, dist)
	# 仅统计：路上花的时间也要算进产能账里，否则低估动作成本
	var kind := String(_task.get("kind", ""))
	_walk_by_kind[kind] = float(_walk_by_kind.get(kind, 0.0)) + delta
	position += to / dist * step

func _begin_act() -> void:
	_act_total = maxf(float(_task.get("duration", 1.0)), 0.0)
	_act_left = _act_total
	_work_phase = 0.0
	_state = State.ACT
	if _act_left <= 0.0:
		_finish_act()

func _act(delta: float) -> void:
	# 动作节拍：打坐最慢、农活最快、采集单独一档 ——
	# 采集的"一个循环"= 弯腰再起身（abs(sin) 的一个半周期≈2 秒），
	# 采叶 5 秒 → 2.5 次，打水 4 秒 → 2.0 次，正好是设计要的"2~3 个循环"。
	var spin := 5.2
	if _sitting():
		spin = 2.2
	elif _gathering():
		spin = 1.6
	_work_phase += delta * spin
	_act_left -= delta
	if _act_left <= 0.0:
		_finish_act()

## 演完 → 交给 Sim 结算 → 回到 IDLE，下一帧领下一个任务
func _finish_act() -> void:
	if board != null and not _task.is_empty():
		board.complete(_task)
	_task = {}
	_state = State.IDLE
	action_changed.emit("")

func _point_for(task: Dictionary) -> Vector2:
	if yard == null:
		return Vector2(position.x, BASE_Y)
	var kind := String(task.get("kind", ""))
	if kind == SimScript.KIND_HARVEST or kind == SimScript.KIND_PLANT:
		return yard.get_field_point(int(task.get("plot", 0)))
	if kind == SimScript.KIND_CRAFT:
		return yard.get_cauldron_point()
	if kind == SimScript.KIND_GATHER:
		# 竹叶去竹丛，井水去井边；认不出来的作物站井边（不会发生，兜底而已）
		if String(task.get("crop", "")) == "zhuye":
			return yard.get_bamboo_point()
		return yard.get_well_point()
	if kind == SimScript.KIND_MEDITATE:
		return yard.get_meditate_point()
	# 认不出的任务种类：以前这里静默落到蒲团，小人会在垫子上"打水"——不报错、产量还对，
	# 只有盯着屏幕才看得出来。加一行 warning，让它在 headless 里就能被发现。
	push_warning("[pawn] 未知任务种类 kind=%s，退回打坐点" % kind)
	return yard.get_meditate_point()

func _sitting() -> bool:
	return _state == State.ACT and String(_task.get("kind", "")) == SimScript.KIND_MEDITATE

## 采集：弯腰—起身循环（竹林采叶 / 井边打水）
func _gathering() -> bool:
	return _state == State.ACT and String(_task.get("kind", "")) == SimScript.KIND_GATHER

func _working() -> bool:
	return _state == State.ACT

## 农活/采集要弯腰，打坐不弯
func _bending() -> bool:
	if not _working():
		return false
	var kind := String(_task.get("kind", ""))
	return kind == SimScript.KIND_PLANT or kind == SimScript.KIND_HARVEST \
		or kind == SimScript.KIND_GATHER

# ============================================================
# 绘制（沿用 M0 造型，只把状态映射换掉）
# ============================================================

func _draw() -> void:
	var sitting := _sitting()
	var bob := 0.0
	if _state == State.WALK:
		bob = -abs(sin(_walk_phase)) * 1.6
	elif _working():
		bob = sin(_work_phase) * 0.9
	if _gathering():
		# 弯腰下探：一个循环压到底再起来，看得出是在够竹叶/够水桶
		bob += absf(sin(_work_phase)) * 3.4
	elif _bending():
		bob += 1.4 + abs(sin(_work_phase * 0.8)) * 1.2

	# 影子
	_ellipse(Vector2(0, 0), 7.0, 2.2, Color(0, 0, 0, 0.28))

	# 打坐光圈
	if sitting:
		var pulse := 0.5 + 0.5 * sin(_work_phase * 2.0)
		_ellipse(Vector2(0, -1), 13.0, 4.0, Color(0.55, 0.85, 0.75, 0.10 + pulse * 0.08))
		_ellipse(Vector2(0, -1), 9.0, 2.6, Color(0.65, 0.95, 0.85, 0.12 + pulse * 0.10))

	var y := bob
	if sitting:
		# 盘坐：腿收成椭圆
		_ellipse(Vector2(0, y - 3), 8.0, 3.2, C_ROBE)
		_ellipse(Vector2(0, y - 3), 6.0, 2.0, C_ROBE_HI)
		# 上身
		_poly([[-4.5, y - 5], [4.5, y - 5], [3.5, y - 15], [-3.5, y - 15]], C_ROBE)
		# 头
		draw_circle(Vector2(0, y - 18.5), 3.4, C_SKIN)
		_poly([[-3.6, y - 19], [3.6, y - 19], [2.6, y - 23.5], [-2.6, y - 23.5]], C_HAIR)
		draw_circle(Vector2(0, y - 24.5), 1.4, C_HAIR)
	else:
		# 双腿
		var stride := 0.0
		if _state == State.WALK:
			stride = sin(_walk_phase) * 2.2
		draw_line(Vector2(-1.6, y - 8), Vector2(-1.6 + stride, y), C_ROBE.darkened(0.25), 2.2)
		draw_line(Vector2(1.6, y - 8), Vector2(1.6 - stride, y), C_ROBE.darkened(0.25), 2.2)
		# 袍身
		_poly([
			[-5.0, y - 20.0], [5.0, y - 20.0], [6.4, y - 6.0], [-6.4, y - 6.0]
		], C_ROBE)
		_poly([[-3.0, y - 19.5], [-0.6, y - 19.5], [0.4, y - 7.0], [-3.2, y - 7.0]], C_ROBE_HI)
		# 腰带
		_rect(-5.6, y - 12.0, 11.2, 1.6, Color(0.42, 0.34, 0.22))
		# 头
		draw_circle(Vector2(0, y - 23.0), 3.4, C_SKIN)
		_poly([[-3.6, y - 23.5], [3.6, y - 23.5], [2.6, y - 28.0], [-2.6, y - 28.0]], C_HAIR)
		draw_circle(Vector2(0, y - 29.0), 1.4, C_HAIR)
		# 干活时手臂小幅动作
		if _working():
			if _gathering():
				# 双臂随弯腰下探，够到竹叶 / 水桶
				var reach := absf(sin(_work_phase))
				draw_line(Vector2(3.5, y - 18), Vector2(7.2, y - 17 + reach * 8.0), C_ROBE_HI, 1.8)
				draw_line(Vector2(-3.5, y - 18), Vector2(-5.8, y - 17 + reach * 6.0), C_ROBE_HI, 1.6)
			else:
				var swing := sin(_work_phase) * 3.0
				draw_line(Vector2(3.5, y - 18), Vector2(8.0 + swing, y - 13 + swing), C_ROBE_HI, 1.8)
				# 农活再补一条左臂，看起来像在摆弄土
				if _bending():
					draw_line(Vector2(-3.5, y - 18), Vector2(-7.4 - swing, y - 14 + swing), C_ROBE_HI, 1.6)

func _ellipse(center: Vector2, rx: float, ry: float, c: Color) -> void:
	var pts := PackedVector2Array()
	for i in 20:
		var a := TAU * float(i) / 20.0
		pts.append(center + Vector2(cos(a) * rx, sin(a) * ry))
	draw_colored_polygon(pts, c)

func _poly(pts: Array, c: Color) -> void:
	var arr := PackedVector2Array()
	for p in pts:
		arr.append(Vector2(p[0], p[1]))
	draw_colored_polygon(arr, c)

func _rect(x: float, y: float, w: float, h: float, c: Color) -> void:
	draw_rect(Rect2(x, y, w, h), c)

## 仅统计用：退出时把各动作的步行耗时打出来（配 sim 的动作耗时看产能账）
func _exit_tree() -> void:
	if not _walk_by_kind.is_empty():
		print("[pawn] 步行耗时分布: %s" % str(_walk_by_kind))
