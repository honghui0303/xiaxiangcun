extends Node2D

## 小院日志的显示层：画面上方浮一行字，自己淡入、停留、淡出。
##
## 它只做三件事：排队、计时、画字。文案与"哪天该播"全在 logbook.gd，这里一概不管。
## 排版原则来自设计侧：**不打扰**。所以没有面板、没有边框、没有图标、没有提示音，
## 一行字出现八秒然后消失，玩家抬头看见就看见了，没看见也不损失什么。

const FADE_IN := 0.9
const HOLD := 8.0
const FADE_OUT := 2.2
const GAP := 1.4              # 两条之间留的空白，别让字接字
const MAX_QUEUE := 3          # 积压超过三条就丢最旧的，宁可少播也别排队播到天亮
const FONT_SIZE := 18
const TOP_Y := 34.0
const PAD_X := 44.0
const PILL_PAD_X := 12.0
const PILL_H := 26.0

const C_TEXT := Color(0.95, 0.97, 0.92)
const C_PILL := Color(0.03, 0.06, 0.05, 0.34)   # 贴字的暗底衬：只裹住文字本身，不是整条横幅
const C_SHADOW := Color(0.02, 0.05, 0.04, 0.55)

var _queue: Array = []        # 待播文案
var _cur := ""
var _t := 0.0                 # 当前条已播时长
var _gap := 0.0               # 上一条淡出后还要等多久
var _font: SystemFont

func _ready() -> void:
	_font = SystemFont.new()
	_font.font_names = PackedStringArray([
		"Microsoft YaHei", "Microsoft YaHei UI", "SimHei", "Noto Sans CJK SC", "sans-serif"
	])
	z_index = 5

## 接日志引擎：只连一个信号，别的一概不问
func bind_logbook(book) -> void:
	if book != null and not book.line_ready.is_connected(push_line):
		book.line_ready.connect(push_line)

## 新来一条：正在播就排队，空着就直接上
func push_line(text: String) -> void:
	var t := String(text).strip_edges()
	if t == "":
		return
	if _cur == "" and _gap <= 0.0:
		_start(t)
		return
	_queue.append(t)
	if _queue.size() > MAX_QUEUE:
		_queue.pop_front()

func _start(t: String) -> void:
	_cur = t
	_t = 0.0
	queue_redraw()

func _process(delta: float) -> void:
	if _cur == "":
		if _gap > 0.0:
			_gap -= delta
			if _gap <= 0.0 and not _queue.is_empty():
				_start(String(_queue.pop_front()))
		return
	_t += delta
	if _t >= FADE_IN + HOLD + FADE_OUT:
		_cur = ""
		_t = 0.0
		_gap = GAP
		queue_redraw()
		return
	queue_redraw()

## 透明度：淡入用 smoothstep，淡出用二次曲线，都是"轻轻出现、慢慢散掉"，没有弹跳
func _alpha() -> float:
	if _t < FADE_IN:
		var k := _t / FADE_IN
		return k * k * (3.0 - 2.0 * k)
	var tail := FADE_IN + HOLD
	if _t <= tail:
		return 1.0
	var k2 := clampf((_t - tail) / FADE_OUT, 0.0, 1.0)
	return (1.0 - k2) * (1.0 - k2)

func _draw() -> void:
	if _cur == "":
		return
	var w := get_viewport_rect().size.x
	# headless 下视口只有 64x64，画了也是白画（还会算出负宽度去居中）
	if w < 300.0:
		return
	var a := _alpha()
	if a <= 0.01:
		return

	var text_w: float = _font.get_string_size(_cur, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x
	var x := clampf((w - text_w) * 0.5, PAD_X, w - PAD_X - text_w)
	var pos := Vector2(x, TOP_Y)

	# 底衬：只裹住文字，边角收得很轻。小院上方是"浅色雾带 + 深色远山"的交界处，
	# 光靠描边在浅色那一段会糊掉，加一层 0.34 的暗底最省事，也不像 UI 面板。
	var pill := Rect2(x - PILL_PAD_X, TOP_Y - PILL_H + 8.0, text_w + PILL_PAD_X * 2.0, PILL_H)
	draw_rect(pill, Color(C_PILL.r, C_PILL.g, C_PILL.b, C_PILL.a * a))

	# 再描一层深色底影，让字在任何底色上都有硬边
	draw_string(_font, pos + Vector2(0.0, 1.0), _cur, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE,
		Color(C_SHADOW.r, C_SHADOW.g, C_SHADOW.b, C_SHADOW.a * a))
	draw_string(_font, pos, _cur, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE,
		Color(C_TEXT.r, C_TEXT.g, C_TEXT.b, C_TEXT.a * a))
