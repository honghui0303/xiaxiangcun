extends Node

## 修仙小院 · 模拟层
##
## 只放数据与规则：没有任何 draw / tween / 动画 / 节点位置代码。
## 线上：_process 里累加 delta，满 1 秒跑一次 tick（推进作物生长）。
## 小人的动作由 task_board.gd 派发，动作演完回调 apply_intent() 结算结果。
## 离线：simulate_offline() 复用同一套 pick_intent() 优先级，把缺失的时间补算掉。
##
## 唯一权威数据源：本节点。HUD / Pawn / Yard 全部只读这里。

signal stats_changed

# ---------------- 路径与常量 ----------------

const DATA_PATH := "res://data/balance.json"
const SAVE_PATH := "user://save.json"
const SAVE_VERSION := 3              # v2 → v3：新增 crafted（炼丹次数表），日志侧靠它识别"第一次炼出某味丹"
const SAVE_INTERVAL_SEC := 60.0      # 自动存档间隔
const TICK_SEC := 1.0                # 模拟步长：1 秒 1 tick
const OFFLINE_CAP_SEC := 28800.0     # 离线最多补算 8 小时，超出截断（本轮 spec 钉死）
const MEDITATE_CHUNK_SEC := 15.0     # 一次打坐的时长（线上与离线步长一致）
const MAX_FRAME_DELTA := 1.0         # 单帧最多推进 1 秒，防止休眠/卡顿后暴冲
const MAX_OFFLINE_STEPS := 20000     # 离线补算循环上限，纯保险丝
const MAX_PLOT_SLOTS := 8            # 田块数量上限（yard 目前画 3 块）
const MAX_WAIT_SEC := 600.0          # 囤料等待上限：连续 600 秒毫无进展就降级防死锁

# 任务种类（task_board / pawn 通过 SimScript.KIND_* 引用，避免字符串漂移）
const KIND_HARVEST := "harvest"
const KIND_CRAFT := "craft"
const KIND_PLANT := "plant"
const KIND_MEDITATE := "meditate"
const KIND_GATHER := "gather"

## 采集动作兜底参数（design 侧正式值到了只换这里，别散进逻辑）。
## 一次动作的时长为 sec，产出 yield 份；crop 在表里没写就用 _default。
const GATHER_FALLBACK := {
	"zhuye": {"sec": 5.0, "yield": 2},      # 竹林采叶：5 秒得 2 份
	"jingshui": {"sec": 4.0, "yield": 2},   # 井边打水：4 秒得 2 份
	"_default": {"sec": 5.0, "yield": 2},
}

## 在线涓流降速倍率：**仅在 AMBIENT_ONLINE_TRICKLE = true 时生效**（A 路径备用）。
## 保留它的原因是：万一在线完全不涨被证明太苦，旋钮的一行改法就在这里。
const AMBIENT_ONLINE_RATE_MULT := 3.0

## 在线涓流开关（M2 定案 = false，即 B 路径）。
## false：在线时井水/竹叶**完全不自动增长**，每一份都必须由小人走到井边 / 竹丛取回。
##        这样"井和竹丛是死物"这笔债（设计侧 R-07）才算真还清——水缸里的水是他挑回来的。
## true ：退回 A 路径（在线 1/3 速涓流 + 采集补充）。实测两档产能差 0.02%，
##        差别只在"看不看得见"，所以选 false。实测数据见 docs/m2-accept.md。
## 离线补算**不受这个开关影响**，永远全速涓流：挂机 8 小时回来缺料 = 惩罚挂机。
const AMBIENT_ONLINE_TRICKLE := false

## 采集阈值：库存 < 单炉最大需求 × 这个倍率就去采。
## 为什么是 2：料刚好够一炉的时候开炉，等于把下一炉的料提前吃掉，下一次就得干等田；
## 留两炉余量，"采 → 炼"才叠得起来。
const GATHER_TRIGGER_MULT := 2

## balance.json 缺失或字段不全时的兜底（保持任务契约里的最小结构）。
## 设计侧的真数据缺哪个字段，就单点退回这里的哪个值，不会整块失效。
const FALLBACK := {
	"config": {
		"meditate_qi_per_sec": 1.0,
		"offline_eff": 1.0,
		"handling_overhead": 1.0,
		"start_items": {},
		"start_stones": 0,
		"plot_capacity": 3,
		"plant_plan": [],
		# 采集物涓流兜底：每 20 秒 1 份、封顶 16 份。
		# 上限 16 而不是 6：紫金丹单炉要 8 份竹叶 + 8 份井水，cap < 8 会让它永远凑不齐一炉，
		# 而且不报错，症状和丹方饿死一模一样。留一倍余量取 16。
		"ambient_rate_sec": 20.0,
		"ambient_cap": 16,
	},
	"crops": [
		{"id": "lingcao", "name": "灵草", "grow_sec": 90.0, "yield": 3, "source": "plot"},
	],
	"recipes": [
		{"id": "huiling_dan", "name": "回灵丹", "inputs": {"lingcao": 2}, "qi": 30.0, "sec": 20.0,
			"stones": 0, "unlock_realm": 0, "tier": 1},
	],
	"realms": [
		{"name": "练气", "exp": 0.0, "plots": 1},
		{"name": "筑基", "exp": 300.0, "plots": 2},
		{"name": "金丹", "exp": 1200.0, "plots": 3},
	],
}

# ---------------- 静态配置（来自 balance.json 或兜底） ----------------

var _crops: Array = []               # [{id, name, grow_sec, yield, source}]
var _crop_by_id: Dictionary = {}
var _recipes: Array = []             # [{id, name, inputs, qi, sec, stones, unlock_realm}]
var _recipe_by_id: Dictionary = {}
var _realms: Array = []              # [{name, exp, plots}] 按 exp 升序
var _plant_plan: Array = []          # [[作物id, ...], ...] 按境界索引

var _plot_slots: int = 3             # 田块几何数量（与 yard 画的块数一致）
var _meditate_qi_per_sec: float = 1.0
var _offline_eff: float = 1.0        # 离线效率折扣
var _handling: float = 1.0           # 动作处理效率（1.0 = 无损耗）
var _start_items: Dictionary = {}
var _start_stones: int = 0
var _plant_sec: float = 4.0
var _harvest_sec: float = 3.5
var _ambient_rate_sec: float = 20.0  # 采集物涓流间隔（秒/份），作物自带字段优先
var _ambient_cap: int = 16           # 采集物库存上限，作物自带字段优先

# ---------------- 运行时状态（会被存档） ----------------

var tick_count: int = 0
var exp_total: float = 0.0
var stones: int = 0
var herb_counts: Dictionary = {}     # crop_id -> int
var crafted: Dictionary = {}         # recipe_id -> 累计出炉次数（只增不减，存档；日志侧用它判断"第一次"）
var realm_index: int = 0
var plots: Array = []                # [{crop: String, elapsed: float, ready: bool}]

var _tick_acc: float = 0.0
var _save_acc: float = 0.0
var _wait_sec: float = 0.0          # 连续"囤料等待"累计秒数，用于防死锁降级
var _ambient_acc: Dictionary = {}   # 采集物涓流的小数余额（不存档，不足 1 份的零头）
var _booted: bool = false
var _booting: bool = false          # 启动阶段（读档 / 离线补算）内禁止落盘
var _offline_sim: bool = false      # 正在跑离线补算：涓流全速，否则按在线降速
var _save_blocked: bool = false     # 存档版本高于当前时置位：本次运行一律不落盘
var _save_loaded: bool = false      # 本次启动是否真的读到了存档（只影响日志措辞）
var online_by_kind: Dictionary = {} # 仅统计用：本次运行各动作累计耗时（不存档、不影响规则）
var _data_warned: bool = false
var _offline_report: Dictionary = {}
var _data_from_file: bool = false

# ============================================================
# 启动
# ============================================================

func _ready() -> void:
	_ensure_booted()

func _ensure_booted() -> void:
	if _booted:
		return
	_booted = true
	_booting = true
	_load_data()
	_init_state()
	var offline_sec := _load_save()
	if offline_sec > 1.0:
		_offline_report = simulate_offline(offline_sec)
		print("[sim] 离线 %d 秒 → 折算 %d 秒（效率 %.2f），补算 %d 个动作，修为 +%d，灵石 +%d，境界 %s→%s" % [
			int(offline_sec),
			int(_offline_report.get("simulated_sec", 0.0)),
			_offline_eff,
			int(_offline_report.get("actions", 0)),
			int(_offline_report.get("exp", 0.0)),
			int(_offline_report.get("stones", 0)),
			String(_offline_report.get("realm_from_name", "")),
			String(_offline_report.get("realm_to_name", "")),
		])
	elif offline_sec > 0.0:
		print("[sim] 离线时间不足 1 秒，忽略")
	elif _save_loaded:
		print("[sim] 已读档，本轮没有可补算的离线时间")
	else:
		print("[sim] 无存档或时间戳不可用，按新局开始")
	print("[sim] 数据源=%s 作物=%d 配方=%d 境界=%d 田块=%d/%d" % [
		"balance.json" if _data_from_file else "内置兜底",
		_crops.size(), _recipes.size(), _realms.size(), usable_plot_count(), _plot_slots,
	])
	# 补算完立刻落盘，防止同一段离线时间被重复领取
	_booting = false
	save_now("启动补算")
	stats_changed.emit()

# ============================================================
# 每帧：1 秒 1 tick + 60 秒一存
# ============================================================

func _process(delta: float) -> void:
	_ensure_booted()
	var d: float = minf(delta, MAX_FRAME_DELTA)
	_tick_acc += d
	while _tick_acc >= TICK_SEC:
		_tick_acc -= TICK_SEC
		_tick()

	_save_acc += d
	if _save_acc >= SAVE_INTERVAL_SEC:
		_save_acc = 0.0
		save_now("定时")

func _tick() -> void:
	tick_count += 1
	if _advance_growth(TICK_SEC):
		stats_changed.emit()

## 推进作物生长与采集物涓流；返回是否有数值变化（作物成熟 / 采集物凑够一份）
func _advance_growth(dt: float) -> bool:
	var changed := false
	for i in plots.size():
		var p: Dictionary = plots[i]
		var crop_id := String(p.get("crop", ""))
		if crop_id == "" or bool(p.get("ready", false)):
			continue
		var def: Dictionary = _crop_by_id.get(crop_id, {})
		var need := maxf(float(def.get("grow_sec", 90.0)), 0.1)
		var elapsed := float(p.get("elapsed", 0.0)) + dt
		p["elapsed"] = elapsed
		if elapsed >= need:
			p["ready"] = true
			changed = true
	if _ambient_trickle(dt):
		changed = true
	return changed

## 采集物涓流：井水 / 竹叶这类 source=="ambient" 的料是"顺手材料"，
## 每 ambient_rate_sec 秒自动 +1 份，库存封顶 ambient_cap，**不占小人的时间预算**。
## 设计侧钉死了两条：
##   1 速度与上限都从 balance.json 的作物字段读（现在是每 15 秒 1 份、封顶 60）。
##     上限必须 ≥ 单炉最大需求（紫金丹要 8 份竹叶 + 8 份井水），否则库存永远凑不齐一炉，
##     症状和丹方饿死一模一样而且不报错 —— 加载完数据后有断言兜住这件事。
##   2 一旦让采集动作占用小人的时长，造田时间被挤掉，中后期速率会掉 10~15%，整套推演失效。
## M2 补真实采集动作后，涓流降级为被动补充。
## 累积器 _ambient_acc 记的是"秒"，不是份数，也不存档（丢了几秒的零头无所谓）。
func _ambient_trickle(dt: float) -> bool:
	if dt <= 0.0 or _crops.is_empty():
		return false
	# 在线且 B 路径：一滴都不长（离线才算，见常量注释）。放在循环外，别在循环里 return。
	if not _offline_sim and not AMBIENT_ONLINE_TRICKLE:
		return false
	var changed := false
	for i in _crops.size():
		var c: Dictionary = _crops[i]
		if String(c.get("source", "plot")) != "ambient":
			continue
		var cid := String(c.get("id", ""))
		if cid == "":
			continue
		var rate := _crop_ambient_rate(c)
		if rate <= 0.0:
			continue
		# 在线：B 路径下完全不涨（AMBIENT_ONLINE_TRICKLE=false），所有料都靠小人去取；
		# 离线补算永远全速，不惩罚挂机。
		if not _offline_sim:
			rate *= AMBIENT_ONLINE_RATE_MULT
		var cap := _crop_ambient_cap(c)
		var have := int(herb_counts.get(cid, 0))
		if have >= cap:
			# 满仓就不再攒时间，否则离线一夜会攒出一个"一次性暴发"
			_ambient_acc[cid] = 0.0
			continue
		var acc := float(_ambient_acc.get(cid, 0.0)) + dt
		var periods := int(floor(acc / rate))
		if periods > 0:
			acc -= float(periods) * rate
			var room := maxi(cap - have, 0)
			var add := mini(periods, room)
			if add > 0:
				herb_counts[cid] = have + add
				changed = true
		_ambient_acc[cid] = acc
	return changed

## 涓流间隔：作物自带的 ambient_rate_sec 优先，缺字段才退回 config 的全局兜底
func _crop_ambient_rate(c: Dictionary) -> float:
	var v := float(c.get("ambient_rate_sec", 0.0))
	if v <= 0.0:
		v = _ambient_rate_sec
	return v

## 涓流上限：作物自带的 ambient_cap 优先，缺字段才退回 config 的全局兜底
func _crop_ambient_cap(c: Dictionary) -> int:
	var v := int(c.get("ambient_cap", 0))
	if v <= 0:
		v = _ambient_cap
	return v

# ============================================================
# 派活：优先级唯一的定义处（线上与离线共用）
# ============================================================

## 派活优先级（唯一实现处，实现的是 balance.json 里的 recipe_pick_rule = "top_tier_hold"）：
##   1 收割
##   2 播种 —— 必须排在炼丹前面，理由见下
##   3 采集（M2）：井水/竹叶库存 < 单炉最大需求 × 2 → 去竹林/井边补
##   4 机会型开炉：比长期目标更高阶、且当下材料就够（这类料通常攒不了，比如采集物）
##   5 长期目标（已解锁 + 等得到的最高 tier）材料齐了 → 开炉
##   6 长期目标的料还在田里长 → 回蒲团打坐囤料，不降级
##   7 降级吃当下吃得下的最高阶 → 8 打坐
##
## 【为什么采集排在开炉之前】料只剩一炉的份还去开炉，等于把下一炉的料提前吃掉，
## 开完就得干等田；先补两炉的余量，"采 → 炼"才叠得起来。
## 【为什么采集排在收割/播种之后】田是瓶颈、炉和井都有富余，瓶颈永远优先。
##
## 【为什么播种要排在炼丹前面】田是小人的产能瓶颈，而炼丹有富余。
## 收割完那块田就是空的，先去开炉会让它空转一炉的时间（20~300 秒）。
## 实测金丹期：先炼丹再补种，每块灵草田每轮有 45/143 秒荒着，
## 灵草产量掉 31%，全局产出从 ~2.9 qi/s 掉到 2.16 qi/s。
## 开炉只是把收入提前几秒，补种却把下一茬收成提前几秒 —— 后者才是复利。
## 打坐依旧是不依赖任何前置条件的兜底，这一点没变。
func pick_intent() -> Dictionary:
	_ensure_booted()

	# 1) 收割：成熟了不收就是白等生长时间，而且收完才能补种
	var ready_plot := first_ready_plot()
	if ready_plot >= 0:
		_wait_sec = 0.0
		return {"kind": KIND_HARVEST, "plot": ready_plot, "recipe": ""}

	# 2) 播种：只要有空田就先种上，绝不让田荒着
	var empty_plot := first_empty_plot()
	if empty_plot >= 0:
		_wait_sec = 0.0
		return {"kind": KIND_PLANT, "plot": empty_plot, "recipe": ""}

	var hold := hold_target_recipe()
	var hold_tier := _recipe_tier(hold)
	var now_rid := craftable_recipe()

	# 3) 采集：井水/竹叶快见底时先去补，别透支下一炉。
	#    阈值判据见 gather_target()：库存 < 单炉最大需求 × 2。
	#    位置讲究：排在收割/播种之后（田里的活永远优先），
	#    排在所有开炉分支之前（料见底时开炉 = 把下一炉的料吃掉）。
	#    离线补算时不派采集：离线涓流是全速的，料本来就自己会满，
	#    再让小人跑去采一遍等于白占时间、白白拉低挂机产出。
	var gather_id := "" if _offline_sim else gather_target()
	if gather_id != "":
		_wait_sec = 0.0
		return {"kind": KIND_GATHER, "plot": -1, "recipe": "", "crop": gather_id}

	# 4) 机会型：比长期目标更高阶又刚好够料，直接炼（多为靠库存撑一次的采集类丹方）
	if now_rid != "" and _recipe_tier(now_rid) > hold_tier:
		_wait_sec = 0.0
		return {"kind": KIND_CRAFT, "plot": -1, "recipe": now_rid}

	# 5) 长期目标材料齐了 → 开炉
	if hold != "" and can_craft(hold):
		_wait_sec = 0.0
		return {"kind": KIND_CRAFT, "plot": -1, "recipe": hold}

	# 6) 囤料等待：目标丹方的料都在田里长 → 打坐等，别降级去把它们吃掉。
	#    关键：等待时长只到"下一株成熟"为止，不要闷头坐满 15 秒。
	#    固定 15 秒会有最多 13 秒的反应延迟，而囤料期占了全局 60% 的时间。
	if hold != "" and _wait_sec < MAX_WAIT_SEC:
		var wait_sec := _wait_chunk()
		_wait_sec += wait_sec
		return {"kind": KIND_MEDITATE, "plot": -1, "recipe": "", "duration": wait_sec,
			"hint": _wait_hint(hold)}
	_wait_sec = 0.0

	# 7) 兜底降级：宁可慢不能停
	if now_rid != "":
		return {"kind": KIND_CRAFT, "plot": -1, "recipe": now_rid}

	# 8) 真的无事可做：打坐。
	return {"kind": KIND_MEDITATE, "plot": -1, "recipe": ""}

## 囤料等待时给 HUD 的一句话："待灵草 4/8"。
## 规则（设计侧定稿）：多料未齐时**只报进度最落后的一味** —— 完成度最低的那项才是真瓶颈，
## 紫金丹报灵草、玄参丹报血参。整数不显示小数；料齐了或没有可等的料就返回空串，
## 纯打坐不加后缀。降级那一路根本不调这个函数，所以死锁时天然不提示。
func _wait_hint(recipe_id: String) -> String:
	var r: Dictionary = _recipe_by_id.get(recipe_id, {})
	if r.is_empty():
		return ""
	var inputs: Dictionary = r.get("inputs", {})
	var worst_id := ""
	var worst_have := 0
	var worst_need := 0
	var worst_ratio := 2.0
	for key in inputs.keys():
		var cid := String(key)
		var need := int(inputs[key])
		if need <= 0:
			continue
		var have := int(herb_counts.get(cid, 0))
		if have >= need:
			continue
		var ratio := float(have) / float(need)
		# 并列时取需求更大的那味：缺口更硬，先补它收益更大
		if ratio < worst_ratio - 0.0001 or (absf(ratio - worst_ratio) <= 0.0001 and need > worst_need):
			worst_ratio = ratio
			worst_id = cid
			worst_have = have
			worst_need = need
	if worst_id == "":
		return ""
	return "待%s %d/%d" % [herb_name(worst_id), worst_have, worst_need]

## 下一次有田能收还要等多久（没有作物在地里就返回 -1）
func _next_mature_sec() -> float:
	var best := -1.0
	var n := mini(usable_plot_count(), plots.size())
	for i in n:
		var p: Dictionary = plots[i]
		var cid := String(p.get("crop", ""))
		if cid == "" or bool(p.get("ready", false)):
			continue
		var def: Dictionary = _crop_by_id.get(cid, {})
		var need := maxf(float(def.get("grow_sec", 90.0)), 0.1)
		var remain := need - float(p.get("elapsed", 0.0))
		if best < 0.0 or remain < best:
			best = remain
	return best

## 囤料等待一个回合的长度：睡到下一株成熟就够，避免反应延迟
func _wait_chunk() -> float:
	var ttm := _next_mature_sec()
	if ttm <= 0.0:
		return MEDITATE_CHUNK_SEC
	return clampf(ttm + 0.05, 1.0, MEDITATE_CHUNK_SEC)

## 一个任务需要占用的表演时长（秒）
func intent_duration(intent: Dictionary) -> float:
	var raw := MEDITATE_CHUNK_SEC
	match String(intent.get("kind", "")):
		KIND_HARVEST:
			raw = _harvest_sec
		KIND_PLANT:
			raw = _plant_sec
		KIND_CRAFT:
			var r: Dictionary = _recipe_by_id.get(String(intent.get("recipe", "")), {})
			raw = maxf(float(r.get("sec", 20.0)), 0.5)
		KIND_GATHER:
			raw = _gather_sec(String(intent.get("crop", "")))
		_:
			raw = MEDITATE_CHUNK_SEC
	if String(intent.get("kind", "")) == KIND_MEDITATE:
		# 打坐可以带 duration 提示（囤料等待只睡到下一株成熟），没有就用默认回合长度
		return maxf(float(intent.get("duration", MEDITATE_CHUNK_SEC)), 1.0)
	# handling_overhead < 1 表示每次动手都有额外损耗，等效于动作变长
	return raw / clampf(_handling, 0.2, 1.0)

## 任务结算：小人动作演完后由 task_board 回调。
## duration 只在打坐时有意义（修为按实际时长折算）。
func apply_intent(intent: Dictionary, duration: float = -1.0) -> bool:
	_ensure_booted()
	var ok := false
	var kind := String(intent.get("kind", ""))
	# 仅统计：记录在线时各动作真正占掉的时间（不含步行，步行由 pawn 自己记）
	if not _offline_sim:
		var spent := duration if duration > 0.0 else intent_duration(intent)
		online_by_kind[kind] = float(online_by_kind.get(kind, 0.0)) + maxf(spent, 0.0)
	match kind:
		KIND_HARVEST:
			ok = harvest(int(intent.get("plot", -1)))
		KIND_PLANT:
			ok = plant(int(intent.get("plot", -1)))
		KIND_CRAFT:
			ok = craft(String(intent.get("recipe", "")))
		KIND_GATHER:
			ok = gather(String(intent.get("crop", "")))
		_:
			var sec := duration if duration > 0.0 else MEDITATE_CHUNK_SEC
			meditate(sec)
			ok = true
	stats_changed.emit()
	return ok

# ============================================================
# 动作规则
# ============================================================

func plant(plot_index: int) -> bool:
	if plot_index < 0 or plot_index >= usable_plot_count():
		return false
	var p := _plot_at(plot_index)
	if p.is_empty():
		return false
	if String(p.get("crop", "")) != "":
		return false
	var cid := plant_crop_for_plot(plot_index)
	if cid == "":
		return false
	p["crop"] = cid
	p["elapsed"] = 0.0
	p["ready"] = false
	return true

func harvest(plot_index: int) -> bool:
	var p := _plot_at(plot_index)
	if p.is_empty():
		return false
	var cid := String(p.get("crop", ""))
	if cid == "" or not bool(p.get("ready", false)):
		return false
	var def: Dictionary = _crop_by_id.get(cid, {})
	var amount := maxi(int(def.get("yield", 1)), 1)
	herb_counts[cid] = int(herb_counts.get(cid, 0)) + amount
	p["crop"] = ""
	p["elapsed"] = 0.0
	p["ready"] = false
	return true

func craft(recipe_id: String) -> bool:
	if not can_craft(recipe_id):
		return false
	var r: Dictionary = _recipe_by_id.get(recipe_id, {})
	if r.is_empty():
		return false
	var inputs: Dictionary = r.get("inputs", {})
	for key in inputs.keys():
		var cid := String(key)
		var need := int(inputs[key])
		var left := int(herb_counts.get(cid, 0)) - need
		if left > 0:
			herb_counts[cid] = left
		else:
			herb_counts.erase(cid)
	_add_exp(float(r.get("qi", 0.0)))
	stones += maxi(int(r.get("stones", 0)), 0)
	crafted[recipe_id] = int(crafted.get(recipe_id, 0)) + 1
	_wait_sec = 0.0
	# 一炉最长 300 秒，出丹立刻落盘：进程被硬杀时不会把整炉丹药赔进去
	save_now("")
	return true

func meditate(seconds: float) -> float:
	var gain := _meditate_qi_per_sec * maxf(seconds, 0.0)
	_add_exp(gain)
	return gain

## 某一味丹累计出炉次数。日志侧的"第一次炼出某味丹"靠它判断，别在别处另记一份。
func crafted_count(recipe_id: String) -> int:
	return int(crafted.get(recipe_id, 0))

func can_craft(recipe_id: String) -> bool:
	var r: Dictionary = _recipe_by_id.get(recipe_id, {})
	if r.is_empty():
		return false
	if int(r.get("unlock_realm", 0)) > realm_index:
		return false
	var inputs: Dictionary = r.get("inputs", {})
	for key in inputs.keys():
		if int(herb_counts.get(String(key), 0)) < int(inputs[key]):
			return false
	return true

## 可炼且已解锁的丹方里，按 (tier 降序, qi/sec 降序) 挑最优 —— 被降级时用
func craftable_recipe() -> String:
	var best_id := ""
	var best_tier := -1
	var best_rate := -1.0
	for i in _recipes.size():
		var r: Dictionary = _recipes[i]
		var rid := String(r.get("id", ""))
		if rid == "" or not can_craft(rid):
			continue
		var tier := int(r.get("tier", 0))
		var rate := float(r.get("qi", 0.0)) / maxf(float(r.get("sec", 20.0)), 0.1)
		if tier > best_tier or (tier == best_tier and rate > best_rate + 0.0001):
			best_tier = tier
			best_rate = rate
			best_id = rid
	return best_id

## 长期目标：已解锁、且"等得到"的最高 tier 丹方（同 tier 取 qi/sec 高的）
## "等得到"= 所有输入都是当前 plant_plan 里会种的田作物，采集物不算（M1 没有采集动作）
func hold_target_recipe() -> String:
	var best_id := ""
	var best_tier := -1
	var best_rate := -1.0
	for i in _recipes.size():
		var r: Dictionary = _recipes[i]
		var rid := String(r.get("id", ""))
		if rid == "":
			continue
		if int(r.get("unlock_realm", 0)) > realm_index:
			continue
		if not _can_wait_for(rid):
			continue
		var tier := int(r.get("tier", 0))
		var rate := float(r.get("qi", 0.0)) / maxf(float(r.get("sec", 20.0)), 0.1)
		if tier > best_tier or (tier == best_tier and rate > best_rate + 0.0001):
			best_tier = tier
			best_rate = rate
			best_id = rid
	return best_id

func _recipe_tier(recipe_id: String) -> int:
	if recipe_id == "":
		return -1
	var r: Dictionary = _recipe_by_id.get(recipe_id, {})
	if r.is_empty():
		return -1
	return int(r.get("tier", 0))

## 这个丹方的料"等得到"吗：每种输入都必须是田里能种出来的作物，
## 而且当前境界的 plant_plan 里确实种它。等不到就别傻等，降级去炼别的。
func _can_wait_for(recipe_id: String) -> bool:
	var r: Dictionary = _recipe_by_id.get(recipe_id, {})
	if r.is_empty():
		return false
	var inputs: Dictionary = r.get("inputs", {})
	if inputs.is_empty():
		return false
	for key in inputs.keys():
		if not _supply_exists(String(key)):
			return false
	return true

## 这一味料"有供给"吗 —— 判据是 supply > 0，不是 supply > 1。
## 允许边收边炼：只要它迟早能到手（田里会种 / 涓流会出），就可以为它囤料，
## 缺口最多一次收割的量，不需要手里同时握着两茬。
## 写成 supply > 1 会把"刚收完、田里还空着"的瞬间判成没供给，一路降级把料吃掉。
func _supply_exists(crop_id: String) -> bool:
	var crop: Dictionary = _crop_by_id.get(crop_id, {})
	if crop.is_empty():
		return false
	if String(crop.get("source", "plot")) == "ambient":
		return true   # 采集物走涓流，永远等得到
	if _plant_plan.is_empty():
		return true   # 没给计划表 → 播种会退回第一种田作物
	var plan := _plan_at_realm()
	if plan.is_empty():
		return true
	return plan.has(crop_id)

# ---------------- 采集（M2） ----------------

## 所有丹方里对某一味作物的单炉最大需求 —— 采集阈值的基准
## 某一味料在所有丹方里的单炉最大需求。
## `unlocked_only = true` 时只统计"当前境界已经能炼的方子"——采集阈值用这一档。
## 为什么要有这个参数：练气期只解锁回灵丹（只要灵草），可紫金丹的单炉需求是 8 份竹叶，
## 用全表算出来的阈值是 16，结果小人从第一秒就跑去打水采叶，连跑十五趟才回来生火，
## 第一炉丹被推到第 90 秒——而设计侧的验收第 1 条是"开局 20 秒内炼出第一炉"。
## **只采你现在用得上的料**，这条既是正确性也是观感。
func max_recipe_need(crop_id: String, unlocked_only: bool = false) -> int:
	var best := 0
	for i in _recipes.size():
		var r: Dictionary = _recipes[i]
		if unlocked_only and int(r.get("unlock_realm", 0)) > realm_index:
			continue
		var inputs: Dictionary = r.get("inputs", {})
		best = maxi(best, int(inputs.get(crop_id, 0)))
	return best

## 该去采哪一味？"" = 不用采（库存都在阈值以上，或者已经满仓）
## 判据：库存 < 单炉最大需求 × GATHER_TRIGGER_MULT，缺口最大的那种优先。
func gather_target() -> String:
	var worst_id := ""
	var worst_deficit := 0
	for i in _crops.size():
		var c: Dictionary = _crops[i]
		if String(c.get("source", "plot")) != "ambient":
			continue
		var cid := String(c.get("id", ""))
		var need := max_recipe_need(cid, true)
		if need <= 0:
			continue
		var cap := _crop_ambient_cap(c)
		var have := int(herb_counts.get(cid, 0))
		if have >= cap:
			continue   # 满仓就别跑了，跑了也装不下
		var trigger := need * GATHER_TRIGGER_MULT
		if have >= trigger:
			continue
		var deficit := trigger - have
		if deficit > worst_deficit:
			worst_deficit = deficit
			worst_id = cid
	return worst_id

## 一次采集的时长（秒）：字段 → 兜底表 → _default
func _gather_sec(crop_id: String) -> float:
	var c: Dictionary = _crop_by_id.get(crop_id, {})
	var v := float(c.get("gather_sec", 0.0))
	if v > 0.0:
		return v
	var row: Dictionary = GATHER_FALLBACK.get(crop_id, GATHER_FALLBACK["_default"])
	return maxf(float(row.get("sec", 5.0)), 0.5)

## 一次采集的产出份数
func _gather_yield(crop_id: String) -> int:
	var c: Dictionary = _crop_by_id.get(crop_id, {})
	var v := int(c.get("gather_yield", 0))
	if v > 0:
		return v
	var row: Dictionary = GATHER_FALLBACK.get(crop_id, GATHER_FALLBACK["_default"])
	return maxi(int(row.get("yield", 2)), 1)

## 采集动作的中文短标签（HUD 用）
func gather_verb(crop_id: String) -> String:
	if crop_id == "zhuye":
		return "采叶"
	if crop_id == "jingshui":
		return "打水"
	return "采集"

## 结算一次采集：加库存，封顶 ambient_cap
func gather(crop_id: String) -> bool:
	var c: Dictionary = _crop_by_id.get(crop_id, {})
	if c.is_empty() or String(c.get("source", "plot")) != "ambient":
		return false
	var cap := _crop_ambient_cap(c)
	var have := int(herb_counts.get(crop_id, 0))
	var add := mini(_gather_yield(crop_id), maxi(cap - have, 0))
	if add <= 0:
		return false
	herb_counts[crop_id] = have + add
	_wait_sec = 0.0
	# 打点：采集是低频动作（阈值触发），一行一条便于验收和后续调阈值
	print("[sim] 采集 %s +%d → %d/%d" % [herb_name(crop_id), add, have + add, cap])
	return true

func _add_exp(v: float) -> void:
	if v <= 0.0:
		return
	exp_total += v
	_recompute_realm()

func _recompute_realm() -> void:
	var idx := 0
	for i in _realms.size():
		var r: Dictionary = _realms[i]
		if exp_total >= float(r.get("exp", 0.0)):
			idx = i
		else:
			break
	var before := realm_index
	realm_index = clampi(idx, 0, maxi(_realms.size() - 1, 0))
	if realm_index != before:
		# 境界突破是里程碑，立刻落盘（同时新境界会解锁田块/配方）
		save_now("")

func _plot_at(i: int) -> Dictionary:
	if i < 0 or i >= plots.size():
		return {}
	return plots[i]

# ============================================================
# 只读查询（HUD / Pawn / Yard 用）
# ============================================================

## 田块几何数量（yard 画出来的块数）
func get_plot_count() -> int:
	_ensure_booted()
	return plots.size()

## 当前境界解锁的可用田块数
func usable_plot_count() -> int:
	_ensure_booted()
	if _realms.is_empty():
		return plots.size()
	var r: Dictionary = _realms[realm_index]
	var n := int(r.get("plots", plots.size()))
	return clampi(n, 1, plots.size())

## 返回地块快照（含 progress，绘制层直接用，不再自己算规则）
func get_plot(i: int) -> Dictionary:
	_ensure_booted()
	if i < 0 or i >= plots.size():
		return {}
	var p: Dictionary = plots[i]
	var cid := String(p.get("crop", ""))
	var out := {
		"index": i,
		"crop": cid,
		"elapsed": float(p.get("elapsed", 0.0)),
		"ready": bool(p.get("ready", false)),
		"grow_sec": 0.0,
		"progress": 0.0,
	}
	if cid == "":
		return out
	var def: Dictionary = _crop_by_id.get(cid, {})
	var need := maxf(float(def.get("grow_sec", 90.0)), 0.1)
	out["grow_sec"] = need
	out["progress"] = clampf(float(out["elapsed"]) / need, 0.0, 1.0)
	return out

func first_ready_plot() -> int:
	var n := usable_plot_count()
	for i in mini(n, plots.size()):
		var p: Dictionary = plots[i]
		if String(p.get("crop", "")) != "" and bool(p.get("ready", false)):
			return i
	return -1

func first_empty_plot() -> int:
	var n := usable_plot_count()
	for i in mini(n, plots.size()):
		if String(plots[i].get("crop", "")) == "":
			return i
	return -1

## 第 i 块田该种什么：优先按 plant_plan（每个境界一张表），否则退回第一种可种作物
func plant_crop_for_plot(i: int) -> String:
	var plan := _plan_at_realm()
	if i >= 0 and i < plan.size():
		var want := String(plan[i])
		if _crop_by_id.has(want):
			var c: Dictionary = _crop_by_id[want]
			if String(c.get("source", "plot")) == "plot":
				return want
	for k in _crops.size():
		var c2: Dictionary = _crops[k]
		if String(c2.get("source", "plot")) == "plot":
			return String(c2.get("id", ""))
	return ""

func _plan_at_realm() -> Array:
	if _plant_plan.is_empty():
		return []
	var idx := clampi(realm_index, 0, _plant_plan.size() - 1)
	var row = _plant_plan[idx]
	if typeof(row) != TYPE_ARRAY:
		return []
	return row

func get_realm_name() -> String:
	_ensure_booted()
	if _realms.is_empty():
		return "凡人"
	var r: Dictionary = _realms[realm_index]
	return String(r.get("name", "凡人"))

func get_exp_total() -> float:
	_ensure_booted()
	return exp_total

## 当前境界内已积累的修为
func get_exp_in_realm() -> float:
	_ensure_booted()
	if _realms.is_empty():
		return exp_total
	var r: Dictionary = _realms[realm_index]
	return maxf(exp_total - float(r.get("exp", 0.0)), 0.0)

## 从当前境界升到下一境界需要的修为；0 表示已到顶
func get_exp_realm_need() -> float:
	_ensure_booted()
	if realm_index + 1 >= _realms.size():
		return 0.0
	var cur: Dictionary = _realms[realm_index]
	var nxt: Dictionary = _realms[realm_index + 1]
	return maxf(float(nxt.get("exp", 0.0)) - float(cur.get("exp", 0.0)), 0.0)

func get_stones() -> int:
	_ensure_booted()
	return stones

func get_herb_count(crop_id: String) -> int:
	_ensure_booted()
	return int(herb_counts.get(crop_id, 0))

## HUD 用：按 balance 顺序列出所有作物与库存
func get_herb_rows() -> Array:
	_ensure_booted()
	var rows: Array = []
	for i in _crops.size():
		var c: Dictionary = _crops[i]
		var cid := String(c.get("id", ""))
		rows.append({
			"id": cid,
			"name": String(c.get("name", cid)),
			"count": int(herb_counts.get(cid, 0)),
		})
	return rows

func recipe_name(recipe_id: String) -> String:
	var r: Dictionary = _recipe_by_id.get(recipe_id, {})
	if r.is_empty():
		return recipe_id
	return String(r.get("name", recipe_id))

func herb_name(crop_id: String) -> String:
	var c: Dictionary = _crop_by_id.get(crop_id, {})
	if c.is_empty():
		return crop_id
	return String(c.get("name", crop_id))

func get_offline_report() -> Dictionary:
	return _offline_report.duplicate(true)

# ============================================================
# 离线结算
# ============================================================

## 用与线上完全相同的优先级，把离线空档折算成有效秒数后一次性算完。
## 两个关键点：
##   1) 每个动作要真实消耗它的表演时长，否则离线变成"1 tick 炼一炉"的抽水机；
##   2) config.offline_eff 是设计侧给的离线效率折扣，直接作用在有效时长上。
func simulate_offline(seconds: float) -> Dictionary:
	_ensure_booted()
	var offline_prev := _offline_sim
	_offline_sim = true          # 离线补算期间涓流全速（在线是 1/3 速）
	var capped := minf(seconds, OFFLINE_CAP_SEC)
	var eff := clampf(_offline_eff, 0.0, 1.0)
	var left := capped * eff
	var actions := 0
	var exp_before := exp_total
	var stones_before := stones
	var realm_before := realm_index
	var realm_name_before := get_realm_name()
	var herbs_before := herb_counts.duplicate()
	var time_by_kind: Dictionary = {}
	var steps := 0

	while left > 0.05 and steps < MAX_OFFLINE_STEPS:
		steps += 1
		var intent := pick_intent()
		var kind := String(intent.get("kind", ""))
		var cost: float = maxf(intent_duration(intent), 0.1)
		var partial := cost > left
		if partial:
			cost = left
		# 先推进世界时间（作物照常生长 + 采集物涓流），再结算动作
		_advance_growth(cost)
		left -= cost
		actions += 1
		time_by_kind[kind] = float(time_by_kind.get(kind, 0.0)) + cost
		if partial:
			# 时间只够演一半：只有打坐能按比例给修为，其余动作算没做完
			if kind == KIND_MEDITATE:
				meditate(cost)
			break
		apply_intent(intent, cost)

	var herb_gain: Dictionary = {}
	for i in _crops.size():
		var c: Dictionary = _crops[i]
		var cid := String(c.get("id", ""))
		var delta := int(herb_counts.get(cid, 0)) - int(herbs_before.get(cid, 0))
		if delta != 0:
			herb_gain[cid] = delta

	var report := {
		"simulated_sec": capped * eff,
		"real_sec": seconds,
		"capped": seconds > OFFLINE_CAP_SEC,
		"actions": actions,
		"exp": exp_total - exp_before,
		"stones": stones - stones_before,
		"realm_from": realm_before,
		"realm_to": realm_index,
		"realm_from_name": realm_name_before,
		"realm_to_name": get_realm_name(),
		"realm_crossed": maxi(realm_index - realm_before, 0),
		"herbs": herb_gain,
		"time_by_kind": time_by_kind,
	}
	_offline_sim = offline_prev
	stats_changed.emit()
	return report

# ============================================================
# balance.json 读取（全字段容错）
# ============================================================

func _load_data() -> void:
	var raw = null
	var problem := ""
	if not FileAccess.file_exists(DATA_PATH):
		problem = "文件不存在"
	else:
		var f := FileAccess.open(DATA_PATH, FileAccess.READ)
		if f == null:
			problem = "打开失败 err=%d" % FileAccess.get_open_error()
		else:
			var txt := f.get_as_text()
			f.close()
			raw = JSON.parse_string(txt)
			if raw == null:
				problem = "JSON 解析失败"

	if typeof(raw) != TYPE_DICTIONARY:
		_apply_fallback(problem)
		return

	_data_from_file = true
	var d: Dictionary = raw
	var notes: PackedStringArray = []

	_crops = _sanitize_crops(d.get("crops"))
	if _crops.is_empty():
		_crops = _sanitize_crops(FALLBACK["crops"])
		notes.append("crops")

	_recipes = _sanitize_recipes(d.get("recipes"))
	if _recipes.is_empty():
		_recipes = _sanitize_recipes(FALLBACK["recipes"])
		notes.append("recipes")

	_realms = _sanitize_realms(d.get("realms"))
	if _realms.is_empty():
		_realms = _sanitize_realms(FALLBACK["realms"])
		notes.append("realms")

	_sanitize_config(d.get("config"))

	_crop_by_id.clear()
	for i in _crops.size():
		var c: Dictionary = _crops[i]
		_crop_by_id[String(c["id"])] = c
	_recipe_by_id.clear()
	for i in _recipes.size():
		var r: Dictionary = _recipes[i]
		_recipe_by_id[String(r["id"])] = r

	if not notes.is_empty():
		_warn_once("balance.json 字段不可用，已单点退回兜底: " + ", ".join(notes))
	_assert_ambient_caps()

func _apply_fallback(problem: String) -> void:
	_data_from_file = false
	_crops = _sanitize_crops(FALLBACK["crops"])
	_recipes = _sanitize_recipes(FALLBACK["recipes"])
	_realms = _sanitize_realms(FALLBACK["realms"])
	_sanitize_config(FALLBACK["config"])
	_crop_by_id.clear()
	for i in _crops.size():
		var c: Dictionary = _crops[i]
		_crop_by_id[String(c["id"])] = c
	_recipe_by_id.clear()
	for i in _recipes.size():
		var r: Dictionary = _recipes[i]
		_recipe_by_id[String(r["id"])] = r
	_warn_once("balance.json 不可用（%s），使用内置兜底数值" % problem)
	_assert_ambient_caps()

## 运行时断言（只 warning，不中断）：ambient 作物的上限必须 ≥ 所有丹方里对它的单炉最大需求。
## 不满足就是静默死锁：库存永远凑不齐一炉，丹方永远不会开火，但日志里一个错都没有。
## 症状与"丹方饿死"完全一样，排查成本极高，所以在这里挡一道。
func _assert_ambient_caps() -> void:
	for i in _crops.size():
		var c: Dictionary = _crops[i]
		if String(c.get("source", "plot")) != "ambient":
			continue
		var cid := String(c.get("id", ""))
		if cid == "":
			continue
		var cap := _crop_ambient_cap(c)
		var max_need := 0
		for j in _recipes.size():
			var r: Dictionary = _recipes[j]
			var inputs: Dictionary = r.get("inputs", {})
			max_need = maxi(max_need, int(inputs.get(cid, 0)))
		if max_need > 0 and cap < max_need:
			var msg := "%s 的 ambient_cap=%d 小于单炉需求 %d，相关丹方将永久卡死" % [cid, cap, max_need]
			push_warning("[sim] " + msg)
			print("[sim][warn] " + msg)

func _sanitize_crops(v) -> Array:
	var out: Array = []
	if typeof(v) != TYPE_ARRAY:
		return out
	var arr: Array = v
	for i in arr.size():
		if typeof(arr[i]) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = arr[i]
		var cid := String(d.get("id", ""))
		if cid == "":
			continue
		var grow := float(d.get("grow_sec", 90.0))
		if grow <= 0.0:
			grow = 90.0
		var amount := int(d.get("yield", 1))
		if amount <= 0:
			amount = 1
		out.append({
			"id": cid,
			"name": String(d.get("name", cid)),
			"grow_sec": grow,
			"yield": amount,
			"source": String(d.get("source", "plot")),
			# 涓流参数只有 ambient 作物会带；缺字段留 0，运行时退回 config 的全局兜底
			"ambient_rate_sec": maxf(float(d.get("ambient_rate_sec", 0.0)), 0.0),
			"ambient_cap": maxi(int(d.get("ambient_cap", 0)), 0),
			# 采集参数同理：没写就用 GATHER_FALLBACK
			"gather_sec": maxf(float(d.get("gather_sec", 0.0)), 0.0),
			"gather_yield": maxi(int(d.get("gather_yield", 0)), 0),
		})
	return out

func _sanitize_recipes(v) -> Array:
	var out: Array = []
	if typeof(v) != TYPE_ARRAY:
		return out
	var arr: Array = v
	for i in arr.size():
		if typeof(arr[i]) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = arr[i]
		var rid := String(d.get("id", ""))
		if rid == "":
			continue
		var inputs: Dictionary = {}
		var raw_inputs = d.get("inputs", {})
		if typeof(raw_inputs) == TYPE_DICTIONARY:
			var src: Dictionary = raw_inputs
			for key in src.keys():
				var need := int(src[key])
				if need > 0:
					inputs[String(key)] = need
		var sec := float(d.get("sec", 20.0))
		if sec <= 0.0:
			sec = 20.0
		out.append({
			"id": rid,
			"name": String(d.get("name", rid)),
			"inputs": inputs,
			"qi": maxf(float(d.get("qi", 0.0)), 0.0),
			"sec": sec,
			"stones": maxi(int(d.get("stones", 0)), 0),
			"unlock_realm": maxi(int(d.get("unlock_realm", 0)), 0),
			"tier": maxi(int(d.get("tier", 0)), 0),
		})
	return out

func _sanitize_realms(v) -> Array:
	var out: Array = []
	if typeof(v) != TYPE_ARRAY:
		return out
	var arr: Array = v
	for i in arr.size():
		if typeof(arr[i]) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = arr[i]
		var rname := String(d.get("name", ""))
		if rname == "":
			continue
		out.append({
			"name": rname,
			"exp": maxf(float(d.get("exp", 0.0)), 0.0),
			"plots": maxi(int(d.get("plots", out.size() + 1)), 1),
		})
	if out.is_empty():
		return out
	# 按阈值升序，且保证第一档从 0 开始（否则永远卡在门槛以下）
	out.sort_custom(func(a, b): return float(a["exp"]) < float(b["exp"]))
	var first: Dictionary = out[0]
	first["exp"] = 0.0
	# 每档田块数不允许倒退，也不允许超过几何上限
	var prev := 1
	for i in out.size():
		var r: Dictionary = out[i]
		var n: int = clampi(int(r["plots"]), prev, MAX_PLOT_SLOTS)
		r["plots"] = n
		prev = n
	return out

func _sanitize_config(v) -> void:
	# 先全部退回兜底，再按文件里实际有的字段覆盖
	var cfg_defaults: Dictionary = FALLBACK["config"]
	_plot_slots = clampi(int(cfg_defaults.get("plot_capacity", 3)), 1, MAX_PLOT_SLOTS)
	_meditate_qi_per_sec = float(cfg_defaults.get("meditate_qi_per_sec", 1.0))
	_offline_eff = float(cfg_defaults.get("offline_eff", 1.0))
	_handling = float(cfg_defaults.get("handling_overhead", 1.0))
	_start_items = {}
	_start_stones = 0
	_plant_plan = []
	_plant_sec = 4.0
	_harvest_sec = 3.5
	_ambient_rate_sec = maxf(float(cfg_defaults.get("ambient_rate_sec", 20.0)), 0.0)
	_ambient_cap = maxi(int(cfg_defaults.get("ambient_cap", 16)), 1)

	if typeof(v) != TYPE_DICTIONARY:
		return
	var c: Dictionary = v

	_plot_slots = clampi(int(c.get("plot_capacity", _plot_slots)), 1, MAX_PLOT_SLOTS)
	# 兼容两种写法：meditate_qi_per_sec（设计侧）/ meditate_exp_per_sec（早期契约）
	var med = c.get("meditate_qi_per_sec", c.get("meditate_exp_per_sec", _meditate_qi_per_sec))
	_meditate_qi_per_sec = maxf(float(med), 0.0)
	_offline_eff = clampf(float(c.get("offline_eff", _offline_eff)), 0.0, 1.0)
	_handling = clampf(float(c.get("handling_overhead", _handling)), 0.2, 1.0)

	var raw_items = c.get("start_items", {})
	if typeof(raw_items) == TYPE_DICTIONARY:
		var items: Dictionary = raw_items
		for key in items.keys():
			var amount := int(items[key])
			if amount > 0:
				_start_items[String(key)] = amount
	_start_stones = maxi(int(c.get("start_stones", 0)), 0)

	var raw_plan = c.get("plant_plan", [])
	if typeof(raw_plan) == TYPE_ARRAY:
		var plan: Array = raw_plan
		for row in plan:
			if typeof(row) != TYPE_ARRAY:
				_plant_plan.append([])
				continue
			var line: Array = []
			var src: Array = row
			for item in src:
				line.append(String(item))
			_plant_plan.append(line)

	var raw_actions = c.get("action_sec", {})
	if typeof(raw_actions) == TYPE_DICTIONARY:
		var acts: Dictionary = raw_actions
		_plant_sec = maxf(float(acts.get("plant", _plant_sec)), 0.2)
		_harvest_sec = maxf(float(acts.get("harvest", _harvest_sec)), 0.2)

	# 采集物涓流：config 里是全局兜底，作物自带的 ambient_rate_sec / ambient_cap 会覆盖它
	_ambient_rate_sec = maxf(float(c.get("ambient_rate_sec", _ambient_rate_sec)), 0.0)
	_ambient_cap = maxi(int(c.get("ambient_cap", _ambient_cap)), 1)

func _warn_once(msg: String) -> void:
	if _data_warned:
		return
	_data_warned = true
	push_warning("[sim] " + msg)
	print("[sim][warn] " + msg)

# ============================================================
# 存档
# ============================================================

func _init_state() -> void:
	plots.clear()
	for i in _plot_slots:
		plots.append({"crop": "", "elapsed": 0.0, "ready": false})
	herb_counts.clear()
	for key in _start_items.keys():
		herb_counts[String(key)] = int(_start_items[key])
	_ambient_acc.clear()
	crafted.clear()
	_wait_sec = 0.0
	exp_total = 0.0
	stones = _start_stones
	tick_count = 0
	realm_index = 0

func save_now(reason: String = "") -> void:
	if not _booted or _booting or _save_blocked:
		# _save_blocked：读档时发现版本高于当前程序，本次运行一律不落盘，
		# 免得降级运行把玩家的高版本存档写坏（宁可这一局不存）
		return
	var data := {
		"version": SAVE_VERSION,
		"last_save_time": Time.get_unix_time_from_system(),
		"tick_count": tick_count,
		"exp_total": exp_total,
		"stones": stones,
		"realm_index": realm_index,
		"herbs": herb_counts.duplicate(),
		"plots": plots.duplicate(true),
		"crafted": crafted.duplicate(),
	}
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("[sim] 存档写入失败: %s err=%d" % [SAVE_PATH, FileAccess.get_open_error()])
		return
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	if reason != "":
		print("[sim] 存档 → %s（%s）境界=%s 修为=%d 灵石=%d tick=%d" % [
			SAVE_PATH, reason, get_realm_name(), int(exp_total), stones, tick_count,
		])

## 存档版本迁移分派：把低版本存档升到当前结构，返回可直接读的字典。
## 约定：迁移只补字段 / 改字段名 / 换语义，绝不臆造玩家进度；
## 认不出来的东西交给读取侧的全字段容错，不在这里抛错。
func _migrate(save: Dictionary, from_version: int) -> Dictionary:
	var d := save.duplicate(true)
	var v := from_version
	if v < 2:
		d = _migrate_v1_to_v2(d)
		v = 2
	if v < 3:
		d = _migrate_v2_to_v3(d)
		v = 3
	return d

## v1 → v2（M2）：新增的采集状态（阈值判据、采集节流）都是可重建的运行时量，不落盘，
## 所以这一版没有需要搬运的数据，函数体故意留空。
## 将来真要动 plots 的结构（比如 ready:bool → rounds:int），补在这个函数里，
## 并且必须保证"v1 档读进来田不丢、库存不丢、境界不丢"。
func _migrate_v1_to_v2(d: Dictionary) -> Dictionary:
	return d

## v2 → v3（M3 日志）：新增 `crafted`（每味丹的累计出炉次数）。v2 档里没有这个字段，
## 补空字典——**不臆造历史**：老存档的"第一次炼出紫金丹"这条日志会按"将来第一次"处理，
## 也就是玩家可能再见一次那句话。可接受，比编一个假的次数诚实。
func _migrate_v2_to_v3(d: Dictionary) -> Dictionary:
	if typeof(d.get("crafted", null)) != TYPE_DICTIONARY:
		d["crafted"] = {}
	return d

## 返回离线秒数（0 表示新档或时间戳不可用）
func _load_save() -> float:
	if not FileAccess.file_exists(SAVE_PATH):
		return 0.0
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		_warn_once("存档打开失败，按新档处理")
		return 0.0
	var txt := f.get_as_text()
	f.close()
	var raw = JSON.parse_string(txt)
	if typeof(raw) != TYPE_DICTIONARY:
		_warn_once("存档解析失败，按新档处理")
		return 0.0
	var d: Dictionary = raw

	# ---- 版本闸门与迁移（M2 起成为硬约束） ----
	# 1) 比当前程序新的存档：拒绝加载并保留原文件，不覆盖。
	#    否则用户"先玩过新版、又跑了一次旧版"，旧版会把新版存档按自己的结构写回去，
	#    新版再读就静默丢档，而且日志里什么都看不出来。
	var from_version := int(d.get("version", 1))
	if from_version > SAVE_VERSION:
		_save_blocked = true
		var msg := "存档版本 %d 高于当前程序 %d，拒绝加载并保留原文件（本次运行不落盘）" % [
			from_version, SAVE_VERSION]
		push_warning("[sim] " + msg)
		print("[sim][warn] " + msg)
		_init_state()
		return 0.0
	# 2) 低版本存档：走迁移分派补齐结构，再按当前结构读取
	d = _migrate(d, from_version)
	_save_loaded = true
	if from_version != SAVE_VERSION:
		print("[sim] 存档 v%d → v%d 迁移完成" % [from_version, SAVE_VERSION])

	exp_total = maxf(float(d.get("exp_total", 0.0)), 0.0)
	stones = maxi(int(d.get("stones", 0)), 0)
	tick_count = maxi(int(d.get("tick_count", 0)), 0)

	herb_counts.clear()
	var raw_herbs = d.get("herbs", {})
	if typeof(raw_herbs) == TYPE_DICTIONARY:
		var hs: Dictionary = raw_herbs
		for key in hs.keys():
			var amount := int(hs[key])
			if amount > 0:
				herb_counts[String(key)] = amount

	var raw_crafted = d.get("crafted", {})
	if typeof(raw_crafted) == TYPE_DICTIONARY:
		var cs: Dictionary = raw_crafted
		for key in cs.keys():
			var n := int(cs[key])
			if n > 0:
				crafted[String(key)] = n

	var raw_plots = d.get("plots", [])
	if typeof(raw_plots) == TYPE_ARRAY:
		var src: Array = raw_plots
		for i in mini(src.size(), plots.size()):
			if typeof(src[i]) != TYPE_DICTIONARY:
				continue
			var s: Dictionary = src[i]
			var cid := String(s.get("crop", ""))
			if cid != "" and not _crop_by_id.has(cid):
				continue  # 作物被改过，认不出来的直接空掉这一格
			var p: Dictionary = plots[i]
			p["crop"] = cid
			p["elapsed"] = maxf(float(s.get("elapsed", 0.0)), 0.0)
			p["ready"] = bool(s.get("ready", false))

	_recompute_realm()

	var last := float(d.get("last_save_time", 0.0))
	var now := Time.get_unix_time_from_system()
	if last <= 0.0:
		return 0.0
	if last > now:
		# 时钟被往回拨：不补算，只把存档接上
		_warn_once("存档时间戳在未来（时钟回拨？），本轮不做离线补算")
		return 0.0
	return now - last

func _notification(what: int) -> void:
	# 关窗口 / 系统要求退出时兜住最后一次存档
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_WM_GO_BACK_REQUEST:
		save_now("关闭窗口")

func _exit_tree() -> void:
	# 正常退出的最后一道保险（被 TerminateProcess 硬杀时不会走到这里）
	if _booted:
		if not online_by_kind.is_empty():
			print("[sim] 在线动作耗时分布: %s" % str(online_by_kind))
		save_now("退出")
