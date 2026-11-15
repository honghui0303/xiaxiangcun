extends SceneTree

## 临时探针（验收用，验收完删除）：按境界段测在线派活的种类分布。
## 只驱动 sim 层（pick_intent + apply_intent + 世界推进），不建窗口、不建 pawn。
## 用法：godot --headless --path . --script res://tools/probe_gather.gd

const SimScript := preload("res://scripts/sim.gd")
const SEG_SEC := 3600.0   # 每段测 1 小时模拟时长，次数即"次/小时"
const INIT_AMBIENT := 8   # 采集物起始库存：贴近 B 路径下的稳态（而不是满仓 60）

var _sim = null
var _done := false

func _initialize() -> void:
	_sim = SimScript.new()
	root.add_child(_sim)

## add_child 触发的 _ready 会推迟到第一帧，所以测量必须放在 _process 里，
## 不能在 _initialize 里抢跑（否则读到的还是 FALLBACK 的默认参数）。
func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	_run()
	return true

func _run() -> void:
	var sim = _sim
	# 启动补算会落盘，之后立刻禁止写盘，避免污染试玩存档
	sim._save_blocked = true

	var realms: Array = sim._realms
	print("=== 探针启动：在线涓流开关=%s（倍率=%s），ambient_rate_sec=%s，cap=%s ===" % [
		SimScript.AMBIENT_ONLINE_TRICKLE, SimScript.AMBIENT_ONLINE_RATE_MULT,
		sim._ambient_rate_sec, sim._ambient_cap])

	var full := false
	for arg in OS.get_cmdline_user_args():
		if arg == "--full":
			full = true
	if full:
		_full_run(sim)
		print("=== 探针结束 ===")
		return

	for r in realms.size():
		_measure(sim, r, String(realms[r].get("name", "?")))

	print("=== 探针结束 ===")

## 从新档一路跑到飞升，测全通时长与各动作时间占比（对应设计侧"全通 31.94 小时"）。
func _full_run(sim) -> void:
	sim.exp_total = 0.0
	sim.realm_index = 0
	sim._recompute_realm()
	sim.herb_counts.clear()
	sim.plots.clear()
	for i in 3:
		sim.plots.append({"crop": "", "elapsed": 0.0, "ready": false})
	sim._wait_sec = 0.0
	sim._ambient_acc.clear()
	# 新档的起始物品照 balance.json 的 start_items 给
	var items: Dictionary = sim._start_items
	for k in items:
		sim.herb_counts[String(k)] = int(items[k])

	var time_by_kind: Dictionary = {}
	var count_by_kind: Dictionary = {}
	var elapsed := 0.0
	var steps := 0
	var limit := 80.0 * 3600.0
	while elapsed < limit and sim.realm_index < 8 and steps < 400000:
		steps += 1
		var intent: Dictionary = sim.pick_intent()
		var kind := String(intent.get("kind", ""))
		var cost: float = maxf(sim.intent_duration(intent), 0.1)
		sim._advance_growth(cost)
		elapsed += cost
		time_by_kind[kind] = float(time_by_kind.get(kind, 0.0)) + cost
		count_by_kind[kind] = int(count_by_kind.get(kind, 0)) + 1
		sim.apply_intent(intent, cost)

	print("[全通] %.2f 小时 到 %s · 采集 %d 次（%.1f 次/小时）· 灵石 %d" % [
		elapsed / 3600.0, sim.get_realm_name(), int(count_by_kind.get("gather", 0)),
		float(count_by_kind.get("gather", 0)) / maxf(elapsed / 3600.0, 0.001), sim.stones])
	print("        时间分布 %s" % _kind_pct(time_by_kind, elapsed))

func _measure(sim, realm_index: int, realm_name: String) -> void:
	var realms: Array = sim._realms
	# 站到本境界起点：修为给一点点余量，避免_ready里的重算把它踩回去
	sim.exp_total = float(realms[realm_index].get("exp", 0.0)) + 1.0
	sim.realm_index = realm_index
	sim._recompute_realm()
	# 库存摆在"稳态"：采集物顶到上限，田里作物给中等余量
	for c in sim._crops:
		var is_amb := String(c.get("source", "plot")) == "ambient"
		sim.herb_counts[String(c.get("id", ""))] = INIT_AMBIENT if is_amb else 60
	sim._wait_sec = 0.0
	sim._ambient_acc.clear()

	var time_by_kind: Dictionary = {}
	var count_by_kind: Dictionary = {}
	var left := SEG_SEC
	var steps := 0
	while left > 0.05 and steps < 40000:
		steps += 1
		var intent: Dictionary = sim.pick_intent()
		var kind := String(intent.get("kind", ""))
		var cost: float = maxf(sim.intent_duration(intent), 0.1)
		if cost > left:
			cost = left
		sim._advance_growth(cost)
		left -= cost
		time_by_kind[kind] = float(time_by_kind.get(kind, 0.0)) + cost
		count_by_kind[kind] = int(count_by_kind.get(kind, 0)) + 1
		if left > 0.05:
			sim.apply_intent(intent, cost)
		# 把境界钉在段首：否则一小时的窗口会一路升到化神，"练气"这一行其实是"练气→化神"
		sim.exp_total = float(realms[realm_index].get("exp", 0.0)) + 1.0
		sim.realm_index = realm_index

	var gather_n := int(count_by_kind.get("gather", 0))
	var gather_sec := float(time_by_kind.get("gather", 0.0))
	var total := 0.0
	for k in time_by_kind:
		total += float(time_by_kind[k])
	print("[%s] 采集 %d 次/小时 · 占小人时间 %.2f%% · 其余分布 %s" % [
		realm_name, gather_n,
		(gather_sec / maxf(total, 0.001)) * 100.0,
		_kind_pct(time_by_kind, total)])
	print("        期末库存 jingshui=%d zhuye=%d · 修为 %.0f→%.0f · 境界=%s" % [
		int(sim.herb_counts.get("jingshui", 0)), int(sim.herb_counts.get("zhuye", 0)),
		float(realms[realm_index].get("exp", 0.0)), sim.exp_total, sim.get_realm_name()])

func _kind_pct(t: Dictionary, total: float) -> String:
	var parts: Array = []
	for k in t:
		parts.append("%s %.1f%%" % [k, float(t[k]) / maxf(total, 0.001) * 100.0])
	return ", ".join(parts)
