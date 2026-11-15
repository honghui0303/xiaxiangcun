extends Control

## 底部状态条：境界 / 修为 / 灵石 / 灵草 + 右端「正在做什么」。
## 所有数值都来自 Sim，这里一个常量都不留 —— 想改数值去改 data/balance.json。

const SimScript := preload("res://scripts/sim.gd")

const BAR_H := 46.0
const SUMMARY_SEC := 12.0        # 「一觉醒来」小结在状态条上的驻留时长

const C_BAR_BG := Color(0.03, 0.055, 0.055, 0.62)
const C_BAR_EDGE := Color(0.34, 0.56, 0.46, 0.55)
const C_TEXT := Color(0.84, 0.93, 0.88)
const C_LABEL := Color(0.52, 0.66, 0.60)
const C_ACCENT := Color(0.55, 0.86, 0.72)
const C_ACTION := Color(0.55, 0.74, 0.66, 0.92)
const C_DIM := Color(0.40, 0.50, 0.46)          # 未开放 / 次要信息
const C_SUMMARY := Color(0.72, 0.90, 0.66)

var _sim: SimScript = null
var _action_text: String = ""
var _summary_text: String = ""
var _summary_left: float = 0.0
var _font: SystemFont

func _ready() -> void:
	_font = SystemFont.new()
	_font.font_names = PackedStringArray([
		"Microsoft YaHei", "Microsoft YaHei UI", "SimHei", "Noto Sans CJK SC", "sans-serif"
	])
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)

func _process(delta: float) -> void:
	if _summary_left <= 0.0:
		return
	_summary_left -= delta
	if _summary_left <= 0.0:
		_summary_left = 0.0
		_summary_text = ""
	queue_redraw()

## 接上 Sim：数值变化时自动重绘，HUD 不轮询
func bind_sim(sim_ref: SimScript) -> void:
	_sim = sim_ref
	if _sim != null and not _sim.stats_changed.is_connected(_on_stats_changed):
		_sim.stats_changed.connect(_on_stats_changed)
	queue_redraw()

func _on_stats_changed() -> void:
	queue_redraw()

func set_action(text: String) -> void:
	if _action_text == text:
		return
	_action_text = text
	queue_redraw()

## 「一觉醒来」小结：把离线跨的几境收成一句话，而不是让玩家去翻日志。
## 数据来自 sim.simulate_offline() 的 report，这里只负责排版。
func show_offline_summary(rep: Dictionary) -> void:
	if rep.is_empty():
		return
	var real_sec := float(rep.get("real_sec", 0.0))
	if real_sec < 60.0:
		return
	var parts: PackedStringArray = []
	if real_sec >= 3600.0:
		parts.append("离线 %.1f 小时" % (real_sec / 3600.0))
	else:
		parts.append("离线 %d 分钟" % int(real_sec / 60.0))
	var crossed := int(rep.get("realm_crossed", 0))
	if crossed > 0:
		parts.append("越过 %d 境 → %s" % [crossed, String(rep.get("realm_to_name", ""))])
	else:
		parts.append("修为渐长 · %s" % String(rep.get("realm_to_name", "")))
	parts.append("修为 +" + _fmt(float(rep.get("exp", 0.0))))
	parts.append("灵石 +" + str(int(rep.get("stones", 0))))
	_summary_text = "一觉醒来 · " + " · ".join(parts)
	_summary_left = SUMMARY_SEC
	queue_redraw()

func _draw() -> void:
	var vs := get_viewport_rect().size
	# headless / 极端小视口下不画，省得算出一堆负数矩形
	if vs.x < 200.0 or vs.y < BAR_H * 2.0:
		return
	var y0 := vs.y - BAR_H

	draw_rect(Rect2(0, y0, vs.x, BAR_H), C_BAR_BG)
	draw_line(Vector2(0, y0), Vector2(vs.x, y0), C_BAR_EDGE, 1.0)

	# ---- 从 Sim 取真实数值 ----
	var realm := "凡人"
	var exp_cur := 0.0
	var exp_need := 0.0
	var stones_n := 0
	var herb_rows: Array = []
	if _sim != null:
		realm = _sim.get_realm_name()
		exp_cur = _sim.get_exp_in_realm()
		exp_need = _sim.get_exp_realm_need()
		stones_n = _sim.get_stones()
		herb_rows = _sim.get_herb_rows()

	# 修为进度条（已到顶就整条亮着）
	var ratio: float = 1.0 if exp_need <= 0.0 else clampf(exp_cur / exp_need, 0.0, 1.0)
	draw_rect(Rect2(0, y0 - 2, vs.x, 2), Color(0.10, 0.18, 0.16, 0.9))
	draw_rect(Rect2(0, y0 - 2, vs.x * ratio, 2), C_ACCENT)

	var fs := 16
	var base_y := y0 + BAR_H * 0.5 + 6.0
	var x := 36.0

	x = _seg(x, base_y, "境界", realm, fs, 96.0)
	var exp_text := (_fmt(exp_cur) + " / " + _fmt(exp_need)) if exp_need > 0.0 else (_fmt(exp_cur) + " 圆满")
	x = _seg(x, base_y, "修为", exp_text, fs, 300.0)
	# 灵石在 M1 还没有任何消费出口，标一句"待开放"，别让玩家以为自己漏了功能
	x = _seg(x, base_y, "灵石", str(stones_n), fs, 186.0, "待开放")
	for i in herb_rows.size():
		var row: Dictionary = herb_rows[i]
		x = _seg(x, base_y, String(row.get("name", "灵草")), str(int(row.get("count", 0))), fs, 120.0)

	# 右端：优先显示「一觉醒来」小结，其次是小人当前动作
	var right_text := ""
	var right_col := C_ACTION
	if _summary_text != "":
		right_text = _summary_text
		right_col = C_SUMMARY
		right_col.a = clampf(_summary_left / 2.0, 0.0, 1.0)   # 最后 2 秒淡出
	elif _action_text != "":
		right_text = "· 正在" + _action_text
	if right_text != "":
		var tw: float = _font.get_string_size(right_text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var rx := vs.x - 36.0 - tw
		# 挤到左边的数值就干脆不画，宁可少一条信息也别叠字
		if rx > x + 12.0:
			draw_string(_font, Vector2(rx, base_y), right_text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs, right_col)

func _seg(x: float, y: float, label: String, value: String, fs: int, adv: float, hint: String = "") -> float:
	draw_string(_font, Vector2(x, y), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, C_LABEL)
	var lw: float = _font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	draw_string(_font, Vector2(x + lw + 10.0, y), value, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, C_TEXT)
	if hint != "":
		var vw: float = _font.get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(_font, Vector2(x + lw + 10.0 + vw + 7.0, y), hint,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs - 3, C_DIM)
	return x + adv

func _fmt(v: float) -> String:
	return String.num(int(v), 0)
