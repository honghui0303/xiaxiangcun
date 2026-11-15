extends Node2D

## 狗。不是灵宠，是一条狗。
##
## 设计约束（`design/narrative/yard-log.md` 4.1，写死不许改）：
##  · 不许写成灵宠：会挡路、会在炉边睡、会咬坏鞋、会老、会死；
##  · 不许给它名字，不许让它"通人性"——叫"狗"最重；
##  · 时间尺度是反向的刀：他 306 天成仙，狗陪了他 804 天，然后狗死了，他还活着。
##
## 所以这只狗的全部行为只有三件：走、停、趴着（只在炉边和屋墙根两处）。
## 它不参与任何数值，不挡路也不让路，不叫，不摇尾巴讨好人（走路时尾巴有一点惯性摆动，
## 那是身体的动作，不是情绪）。
##
## **出现与消失都挂在日志的"天"上**：第 96 天篱笆底下钻进来一条狗（日志那天会播），
## 第 900 天石板上那块饼没动（那天也会播）。它消失时不解释、不告别、不留东西——
## 跟设计侧那条"死亡一个字都不解释"保持一致。

const BASE_Y := 194.0
const ARRIVE_DAY := 96        # 与日志第 96 天对齐：篱笆底下钻进来一条狗，瘦
const GONE_DAY := 900         # 与日志第 900 天对齐：石板上那块饼没动
const SPEED := 26.0           # 比人慢一截（人 44）
const ARRIVE_EPS := 1.5
const MAX_X_RATIO := 0.93

## 停下来的落脚点：只在这些空草地上停，避开田垄（0.47-0.66）、井（0.735）、
## 竹丛（0.80-0.88）和炉子（0.385）——路过可以，站着不动压在家具上就假了。
const PAUSE_SPOTS := [0.225, 0.25, 0.325, 0.352, 0.672, 0.690, 0.762, 0.905, 0.925]

## 趴着的地方只有两处：炉边、屋墙根。别处不趴——狗认地方。
## 想对应日志 3.3（a）那条"狗第一次趴在门槛上"，但房子是正面平面画的，
## 门在屋子中间，狗站不进去，只能贴着墙根右边趴；再往左就压到墙上了。
const DOOR_SPOT := 0.205
const LIE_SPOTS := [0.335, DOOR_SPOT]

## 第一次在墙根趴下时发一次。日志 3.3（a）那条事件等这个信号，别处不发。
signal lay_at_door

const C_FUR := Color(0.34, 0.27, 0.20)
const C_FUR_HI := Color(0.44, 0.36, 0.27)
const C_FUR_DARK := Color(0.22, 0.17, 0.13)
const C_NOSE := Color(0.10, 0.08, 0.07)

enum State { GONE, WANDER, PAUSE, LIE }

var _logbook = null
var _stage_w := 0.0            # >0 时用它当院子宽度（探针注入用；正式运行每帧读视口）
var _state: State = State.GONE
var _target_x := 0.0
var _facing := 1.0             # +1 朝右，-1 朝左
var _walk_phase := 0.0
var _wait := 0.0
var _rest_cool := 50.0        # 离下次"去趴着"还有多久（每帧递减）
var _going_lie := false
var _door_told := false

func bind_logbook(book, stage_width: float = 0.0) -> void:
	_logbook = book
	_stage_w = stage_width
	z_index = 4                # 压在小院之上、小人之下（小人 10，日志那行字 5）

## 院子宽度。正式运行时永远走视口；探针里 headless 视口只有 64x64，
## 所以留一个注入口，不然 _spawn 会被 w<200 挡掉，什么都测不到。
func _w() -> float:
	return _stage_w if _stage_w > 0.0 else get_viewport_rect().size.x

func _process(delta: float) -> void:
	if _logbook == null:
		return
	var day := int(_logbook.current_day())
	if day < ARRIVE_DAY or day >= GONE_DAY:
		if _state != State.GONE:
			_state = State.GONE
			queue_redraw()
		return
	if _state == State.GONE:
		_spawn()
		return

	var w := _w()
	if w < 200.0:
		return

	_rest_cool -= delta
	match _state:
		State.WANDER:
			var dx := _target_x - position.x
			if absf(dx) <= ARRIVE_EPS:
				position.x = _target_x
				if _going_lie:
					_state = State.LIE
					if not _door_told and absf(position.x - w * DOOR_SPOT) < 8.0:
						_door_told = true
						lay_at_door.emit()
					_going_lie = false
					_wait = randf_range(22.0, 46.0)
				else:
					_state = State.PAUSE
					_wait = randf_range(3.5, 8.0)
			else:
				_facing = 1.0 if dx > 0.0 else -1.0
				position.x += signf(dx) * minf(SPEED * delta, absf(dx))
				_walk_phase += delta * 7.0
		State.PAUSE:
			_wait -= delta
			if _wait <= 0.0:
				_decide(w)
		State.LIE:
			_wait -= delta
			if _wait <= 0.0:
				_rest_cool = randf_range(50.0, 90.0)
				_decide(w)
	queue_redraw()

## 出现：从篱笆那侧（画面右）走进来，位置随机——它本来就是自己钻进来的
func _spawn() -> void:
	var w := _w()
	if w < 200.0:
		return
	position = Vector2(w * MAX_X_RATIO, BASE_Y)
	_state = State.WANDER
	_facing = -1.0                                  # 从右往左走进来
	_target_x = w * randf_range(0.34, 0.62)
	_rest_cool = randf_range(50.0, 90.0)
	_going_lie = false
	_door_told = false
	queue_redraw()

## 停够了就决定下一件事：多数时候继续逛，冷却到了就去趴着（炉边或墙根）。
func _decide(w: float) -> void:
	if _rest_cool <= 0.0:
		_going_lie = true
		_target_x = w * float(LIE_SPOTS[randi() % LIE_SPOTS.size()])
	else:
		_going_lie = false
		var spot: float = PAUSE_SPOTS[randi() % PAUSE_SPOTS.size()]
		_target_x = w * spot
	_state = State.WANDER

# ============================================================
# 绘制：和小说人同一套色块画法，只是四条腿、更矮
#
# 所有坐标都按「朝右」写，开头用 draw_set_transform 按 _facing 整体镜像 x。
# 第一版只翻转了头、尾巴硬编码在左边，结果朝左走时头和尾巴挤在同一侧，
# 尾巴被身子盖住——一只没有尾巴的狗。
# ============================================================

func _draw() -> void:
	if _state == State.GONE:
		return

	draw_set_transform(Vector2(0, 0), 0.0, Vector2(_facing, 1.0))

	var walking := _state == State.WANDER
	var bob := -absf(sin(_walk_phase)) * 0.9 if walking else 0.0
	var y := bob

	if _state == State.LIE:
		_draw_lying(y)
	else:
		_draw_standing(y, walking)

## 站着 / 走着：前胸略高、腰略收，四条腿细长，尾巴先垂后翘
func _draw_standing(y: float, walking: bool) -> void:
	# 影子
	_ellipse(Vector2(0.0, 0.0), 5.8, 1.0, Color(0, 0, 0, 0.12))

	# 四条腿：两条腿间距必须大于腿宽，否则站住不动时会粘成一条粗腿。
	# 走的时候前后交错（s 让对角的两条同向）。
	var s := sin(_walk_phase) * 1.7 if walking else 0.0
	draw_line(Vector2(-5.4, y - 5.6), Vector2(-5.4 + s, y), C_FUR_DARK, 1.2)
	draw_line(Vector2(-3.4, y - 5.6), Vector2(-3.4 - s, y), C_FUR_DARK, 1.2)
	draw_line(Vector2(3.2, y - 5.6), Vector2(3.2 - s, y), C_FUR_DARK, 1.2)
	draw_line(Vector2(5.2, y - 5.6), Vector2(5.2 + s, y), C_FUR_DARK, 1.2)

	# 身子：前胸高、腰略收——一个椭圆会画成野猪，两个一样高会画成方块
	_ellipse(Vector2(-2.6, y - 7.2), 4.6, 2.7, C_FUR)
	_ellipse(Vector2(2.2, y - 7.5), 4.4, 2.9, C_FUR)
	# 背上的光
	_ellipse(Vector2(-0.6, y - 8.6), 4.8, 0.8, C_FUR_HI)

	# 尾巴：从臀部长出来，先垂下去再往上一翘
	# （走路带一点惯性摆动，是身体的动作，不是讨好）
	var wag := sin(_walk_phase * 0.5) * 1.2 if walking else 0.0
	draw_polyline(PackedVector2Array([
		Vector2(-6.4, y - 6.6),
		Vector2(-8.8, y - 7.4),
		Vector2(-10.6, y - 10.2 + wag),
	]), C_FUR_DARK, 1.6)

	# 头：直接压在胸口上，不画脖子线——那根粗线会在肩上鼓出一个驼峰
	draw_circle(Vector2(7.0, y - 10.2), 3.1, C_FUR)
	# 两只耳朵：立起的三角，前后错开，别叠成一只独角
	# 用毛色不描边：这个尺寸上深色三角会把整个头糊成一团，耳形靠轮廓认
	_poly([[5.6, y - 11.8], [6.1, y - 15.2], [7.5, y - 12.5]], C_FUR)
	_poly([[7.7, y - 12.6], [8.3, y - 15.0], [9.4, y - 11.3]], C_FUR)
	# 吻部 + 鼻
	draw_circle(Vector2(9.6, y - 9.4), 1.6, C_FUR)
	draw_circle(Vector2(10.7, y - 9.2), 0.8, C_NOSE)

## 趴着：蜷成一团（"面包"那样），头颈抬起。
## 两次翻车的教训：① 头跟身子同一高度 → 一根插了钉子的木头；
## ② 身子拉太长 → 一根倒下的木头。压短、加厚、头抬过背线，才认得出是活物。
func _draw_lying(y: float) -> void:
	_ellipse(Vector2(0.0, 0.0), 7.4, 1.2, Color(0, 0, 0, 0.12))

	# 身子：短的圆团，不是长条
	_ellipse(Vector2(-0.8, y - 3.6), 6.2, 3.2, C_FUR)
	_ellipse(Vector2(-0.8, y - 4.4), 4.4, 1.5, C_FUR_HI)
	# 前爪：伸出去摊在身前（用毛色，不然是一块黑，像头底下有个洞）
	draw_line(Vector2(3.6, y - 1.1), Vector2(7.6, y - 0.9), C_FUR, 1.8)

	# 头颈抬起：头明显高过背线
	draw_circle(Vector2(5.2, y - 5.8), 3.1, C_FUR)
	# 两只耳朵一后一前向外撇：垂直细长的会读成兔子
	_poly([[3.5, y - 7.8], [3.2, y - 10.6], [5.2, y - 8.3]], C_FUR)
	_poly([[5.8, y - 8.3], [6.6, y - 10.4], [7.2, y - 6.8]], C_FUR)
	draw_circle(Vector2(7.5, y - 4.9), 1.5, C_FUR)
	draw_circle(Vector2(8.5, y - 4.7), 0.7, C_NOSE)

	# 尾巴贴地绕在身后，挨着身子
	draw_polyline(PackedVector2Array([
		Vector2(-6.4, y - 3.0), Vector2(-8.2, y - 1.8), Vector2(-9.4, y - 0.7),
	]), C_FUR_DARK, 1.8)

func _ellipse(center: Vector2, rx: float, ry: float, c: Color) -> void:
	var pts := PackedVector2Array()
	for i in 18:
		var a := TAU * float(i) / 18.0
		pts.append(center + Vector2(cos(a) * rx, sin(a) * ry))
	draw_colored_polygon(pts, c)

func _poly(pts: Array, c: Color) -> void:
	var arr := PackedVector2Array()
	for p in pts:
		arr.append(Vector2(p[0], p[1]))
	draw_colored_polygon(arr, c)
