extends Node

## 小院日志：按"游戏日"解锁的院子独白。
##
## 设计来源：`design/narrative/yard-log.md`（文案与规则），`data/logs.json`（数据）。
## 这个系统的全部职责只有一句：**在合适的日子，让一句话自己出现，然后再消失。**
##
## 三条实现取舍，都有理由：
##  1. **不存档。** 哪一条播过、循环播到第几年，全部由 `sim.tick_count`（累计在线秒数）
##     推导得出。存一份"已播列表"会多一个能和进度失步的状态源，而这里的代价只是
##     "读档回退时可能重播一条"——可接受，且不会污染进度。
##  2. **不打扰。** 它不发通知、不改数值、不挡视线，只在画面上方浮一行字。
##  3. **一天一条。** 同一天绝不播两条，跨天时优先播"最新"的那条（离线/低帧跳天时不刷屏）。

signal line_ready(text: String)

const DATA_PATH := "res://data/logs.json"
const DAY_SEC_DEFAULT := 378.0     # 1 游戏日 ≈ 6.3 分钟（全通 32 小时 ≈ 第 304 天）
const MAX_LINES_PER_TICK := 2      # 一次跨很多天时，最多补播两条
const COLLISION_DAYS := 3          # 循环事件要避开一次性条目 ±3 天
const MAX_SHIFT_DAYS := 10         # 允许滑动 ±10 天（设计侧 3.3 第 4 条）
const SEEN_PATH := "user://logbook.json"   # 只存"哪些事件日志播过"，不含任何进度
const NIGHT_SEC := 21600.0         # "整夜没添柴"的门槛：离线 ≥ 6 小时

var _entries: Array = []           # [{day:int, text:String, id:String}] 按 day 升序
var _loops: Array = []             # [{id, name, first_day, period_days, variants:Array, days:Array}]
var _events: Array = []            # [{id, text, when:String, armed:bool}] 事件触发型（不按天数）
var _day_sec := DAY_SEC_DEFAULT
var _seen: Dictionary = {}         # event_id -> true（只用于事件日志，天数日志靠 tick_count 推导）
var _hits: Dictionary = {}         # when -> true（外部系统喊过的事：狗趴门槛、下雨、燕子走）

var _sim = null
var _day := -1                     # 当前游戏日
var _cursor := 0                   # 一次性条目游标：指向第一条"还没到"的
var _loop_fired: Dictionary = {}   # loop_id -> 已经播到第几次（内部用，按天推导后缓存在这里）
var _offline_real_sec := 0.0       # 本次启动的离线秒数（只有启动那一刻有意义）
var _data_from_file := false

func _ready() -> void:
	_load_data()
	_load_seen()

func _process(_delta: float) -> void:
	if _sim == null:
		return
	_check_events()
	var today := day_of(int(_sim.tick_count))
	if today <= _day:
		return
	_day = today
	_fire_due(today)

## 接上 Sim 之后再来一次"对齐"：读档进来的进度不该把历史日志重播一遍。
## 注意这里**不补播**，只把游标推到当前位置——历史是历史，玩家不在场就不是他的日子。
func bind_sim(sim_ref) -> void:
	_sim = sim_ref
	_day = day_of(int(_sim.tick_count))
	_cursor = 0
	while _cursor < _entries.size() and int(_entries[_cursor]["day"]) <= _day:
		_cursor += 1
	_loop_fired.clear()
	# 事件类：读档时把"已经发生过的事"记进 _seen，避免一进游戏就蹦出一句"第一次炼出紫金丹"
	_prime_events()

## 读档时对齐事件类的已知状态：
##  · 已经炼过的丹 → 那句"第一次"属于历史，不再播；
##  · 离线很久这件事是**这一次启动**发生的，所以要在启动时判一次（不是 prime 掉）。
func _prime_events() -> void:
	for ev in _events:
		if not bool(ev["armed"]):
			continue
		var when := String(ev["when"])
		if when.begins_with("craft:") and _sim != null:
			var rid := when.split(":")[1]
			if int(_sim.crafted_count(rid)) > 0:
				_seen[String(ev["id"])] = true
	_check_offline_event()

## 事件日志的判定：每种 when 只有一句话的解释，新增条件请在这里加一个分支。
func _check_events() -> void:
	if _sim == null:
		return
	for ev in _events:
		if not bool(ev["armed"]):
			continue
		var eid := String(ev["id"])
		if _seen.has(eid):
			continue
		var when := String(ev["when"])
		var hit := false
		if when.begins_with("craft:"):
			var rid := when.split(":")[1]
			hit = int(_sim.crafted_count(rid)) > 0
		elif when.begins_with("offline_hours:"):
			hit = float(when.split(":")[1]) * 3600.0 <= _offline_real_sec
		else:
			# 日志引擎自己看不见的条件（狗、天气、燕子）：由各自的系统在事情发生那一刻喊一声。
			hit = _hits.has(when)
		if hit:
			_seen[eid] = true
			_save_seen()
			line_ready.emit(String(ev["text"]))

## 外部系统通知"某件事发生了"。
## 天气 / 燕子 / 狗这类条件，日志引擎没有能力自己观测（它只认 tick_count），
## 所以由各自系统在发生时喊一句 mark("dog:door")，判定和去重仍然走 _check_events 那一套。
func mark(when: String) -> void:
	if _hits.has(when):
		return
	_hits[when] = true
	_check_events()

## 离线时长是"这一次启动"的事实，只能判一次，否则每次启动都会重放同一句话。
func _check_offline_event() -> void:
	if _sim == null:
		return
	var rep: Dictionary = _sim.get_offline_report() if _sim.has_method("get_offline_report") else {}
	_offline_real_sec = float(rep.get("real_sec", 0.0))
	_check_events()

func day_of(sec: int) -> int:
	var per := maxf(_day_sec, 1.0)
	return int(float(sec) / per)

## 当前是第几天（给 HUD / 调试用）
func current_day() -> int:
	return _day

# ============================================================
# 触发
# ============================================================

func _fire_due(today: int) -> void:
	var due: Array = []

	# 一次性条目：把游标之前的全部跳过（同一帧跨多天时只留最后两条）
	while _cursor < _entries.size() and int(_entries[_cursor]["day"]) <= today:
		due.append(String(_entries[_cursor]["text"]))
		_cursor += 1

	# 循环事件：按"第几年"取变体，晚到的年份按当前年份补齐
	for loop in _loops:
		var hit := _loop_line(loop, today)
		if hit != "":
			due.append(hit)

	if due.is_empty():
		return
	var from := maxi(due.size() - MAX_LINES_PER_TICK, 0)
	for i in range(from, due.size()):
		line_ready.emit(String(due[i]))

## 循环事件在某一天该不该播、播哪一版。
## 年数从 1 开始；变体下标 = 0（第 1-2 年）/ 1（第 3-5 年）/ 2（第 6 年以后）。
func _loop_line(loop: Dictionary, today: int) -> String:
	var lid := String(loop["id"])
	var days: Array = loop["days"]
	var year := 0
	for i in days.size():
		if today >= int(days[i]):
			year = i + 1
	if year <= 0:
		return ""
	if int(_loop_fired.get(lid, 0)) >= year:
		return ""
	_loop_fired[lid] = year
	var variants: Array = loop["variants"]
	var idx := 0
	if year >= 6:
		idx = 2
	elif year >= 3:
		idx = 1
	idx = clampi(idx, 0, variants.size() - 1)
	return String(variants[idx])

# ============================================================
# 数据
# ============================================================

func _load_data() -> void:
	if not FileAccess.file_exists(DATA_PATH):
		_warn("logs.json 不存在，日志系统静默关闭")
		return
	var f := FileAccess.open(DATA_PATH, FileAccess.READ)
	if f == null:
		_warn("logs.json 打开失败，日志系统静默关闭")
		return
	var raw = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(raw) != TYPE_DICTIONARY:
		_warn("logs.json 解析失败，日志系统静默关闭")
		return
	var d: Dictionary = raw

	_day_sec = maxf(float(d.get("day_length_sec", DAY_SEC_DEFAULT)), 1.0)

	_entries.clear()
	for e in d.get("entries", []):
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var day := int(e.get("day", -1))
		var text := String(e.get("text", ""))
		if day < 0 or text == "":
			continue
		_entries.append({"day": day, "text": text, "id": "d%04d" % day})
	_entries.sort_custom(func(a, b): return int(a["day"]) < int(b["day"]))

	# 循环事件：把"每一年落在第几天"预先算好，连带避开一次性条目的 ±3 天。
	var occupied: Array = []
	for e in _entries:
		occupied.append(int(e["day"]))

	_loops.clear()
	for l in d.get("loops", []):
		if typeof(l) != TYPE_DICTIONARY:
			continue
		var variants: Array = l.get("variants", [])
		if variants.is_empty():
			continue
		var first := int(l.get("first_day", -1))
		var period := maxi(int(l.get("period_days", 365)), 1)
		if first < 0:
			continue
		var days: Array = []
		# 算到第 40 年为止（≈ 第 15000 天）：再往后没有玩家会到，也避免死循环
		for k in 40:
			var day := first + k * period
			# **首年不挪**：第 88 / 260 / 400 / 480 天是设计侧钉死的首触发日（第 88、260、400 天
			# 还是从一次性条目升格过来的），挪了就和设计对不上。只有后续年份才需要避开
			# 一次性条目——那条规则的原文就是"明年本该落在 453，但第 452 天已有，让到 456"。
			if k > 0:
				day = _avoid_collision(day, occupied)
			days.append(day)
		_loops.append({
			"id": String(l.get("id", "loop_%d" % _loops.size())),
			"name": String(l.get("name", "")),
			"days": days,
			"variants": variants,
		})

	_data_from_file = not _entries.is_empty()

	_events.clear()
	for e in d.get("events", []):
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var text := String(e.get("text", ""))
		if text == "":
			continue
		_events.append({
			"id": String(e.get("id", "ev%d" % _events.size())),
			"text": text,
			"when": String(e.get("when", "")),
			"armed": bool(e.get("armed", true)),
		})

	print("[log] 数据源=logs.json 一次性=%d 循环=%d 事件=%d（已武装 %d）1 日=%.0f 秒" % [
		_entries.size(), _loops.size(), _events.size(),
		_events.filter(func(e): return bool(e["armed"])).size(), _day_sec])

## 循环发生日若离某条一次性条目太近，往后挪，最多挪 10 天（设计侧 ±10 天滑动规则）。
func _avoid_collision(day: int, occupied: Array) -> int:
	for shift in MAX_SHIFT_DAYS + 1:
		var cand := day + shift
		var clash := false
		for od in occupied:
			if absi(cand - int(od)) <= COLLISION_DAYS:
				clash = true
				break
		if not clash:
			return cand
	return day

func _warn(msg: String) -> void:
	push_warning("[log] " + msg)
	print("[log][warn] " + msg)

# ------------------------------------------------------------
# 事件日志的"已播"记录：唯一需要落盘的一小块状态，单独一个文件。
# 放进 save.json 会和进度耦合（日志只是叙事，丢了顶多重播一句，不该影响存档结构）；
# 完全不存则每次启动都会重放"第一次炼出紫金丹"。两害相权，选独立小文件。
# ------------------------------------------------------------

func _load_seen() -> void:
	if not FileAccess.file_exists(SEEN_PATH):
		return
	var f := FileAccess.open(SEEN_PATH, FileAccess.READ)
	if f == null:
		return
	var raw = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(raw) != TYPE_DICTIONARY:
		return
	for k in raw.get("seen", []):
		_seen[String(k)] = true

func _save_seen() -> void:
	var f := FileAccess.open(SEEN_PATH, FileAccess.WRITE)
	if f == null:
		_warn("事件日志记录写入失败（不影响进度，最多重播一句）")
		return
	f.store_string(JSON.stringify({"seen": _seen.keys()}, "\t"))
	f.close()
