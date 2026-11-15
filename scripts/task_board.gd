extends Node

## 派活板
##
## 唯一职责：把 sim 算出的「当前最该做的事」翻译成小人能执行的一个任务。
## 优先级不在这里判断 —— 全部在 sim.pick_intent() 里，只有一处定义，
## 这样线上派活和离线补算永远不会算出两套结果。
##
## 任意时刻小人最多持有一个任务：request_task() 一次只返回一个，pawn 演完才来要下一个。

const SimScript := preload("res://scripts/sim.gd")

var sim: SimScript = null

## HUD 右上角的一句话提示。键必须与 sim.gd 的 KIND_* 常量字面值一致。
const LABELS := {
	"harvest": "收割",
	"craft": "炼丹",
	"plant": "播种",
	"meditate": "打坐",
	"gather": "采集",
}

func setup(sim_ref: SimScript) -> void:
	sim = sim_ref

## 领一个任务。返回 {kind, plot, recipe, duration, label}
func request_task() -> Dictionary:
	if sim == null:
		return {}
	var intent: Dictionary = sim.pick_intent()
	if intent.is_empty():
		return {}
	var task := {
		"kind": String(intent.get("kind", SimScript.KIND_MEDITATE)),
		"plot": int(intent.get("plot", -1)),
		"recipe": String(intent.get("recipe", "")),
		"crop": String(intent.get("crop", "")),
		"duration": sim.intent_duration(intent),
		"label": label_for(intent),
	}
	return task

## 小人动作演完 → 交给 sim 结算
func complete(task: Dictionary) -> bool:
	if sim == null or task.is_empty():
		return false
	return sim.apply_intent(task, float(task.get("duration", -1.0)))

func label_for(intent: Dictionary) -> String:
	var kind := String(intent.get("kind", ""))
	var base := String(LABELS.get(kind, ""))
	if kind == SimScript.KIND_CRAFT:
		var rname := sim.recipe_name(String(intent.get("recipe", "")))
		return "%s·%s" % [base, rname]
	if kind == SimScript.KIND_HARVEST or kind == SimScript.KIND_PLANT:
		return "%s第%d块田" % [base, int(intent.get("plot", 0)) + 1]
	if kind == SimScript.KIND_GATHER:
		# 采叶 / 打水：动词归 sim 管（它知道作物 id 的含义），这里只取字
		return sim.gather_verb(String(intent.get("crop", "")))
	# 等料提示由 sim 算好塞进 intent.hint（"待灵草 4/8"），这里只拼接，不做二次判断。
	# 纯打坐没有 hint，就是「打坐」两个字，不给玩家暗示哪里不对。
	var hint := String(intent.get("hint", ""))
	if hint != "":
		return "%s · %s" % [base, hint]
	return base
