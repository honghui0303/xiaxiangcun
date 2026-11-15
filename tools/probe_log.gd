extends SceneTree

## 校验脚本（M3 回归用，保留）：日志系统的三个部分
##   A 天数类：快进到第 1400 天，查 57 条是否全触发、有无重播、循环排期
##   B 事件类：模拟"第一次炼出紫金丹""离线 6 小时"，查只播一次
##   C 读档：已炼过的丹不该在进入游戏时补播
## 用法：godot --headless --path . --script res://tools/probe_log.gd

const LogBookScript := preload("res://scripts/logbook.gd")

class FakeSim extends Node:
	var tick_count: int = 0
	var _crafted: Dictionary = {}
	var _report: Dictionary = {}
	func crafted_count(id: String) -> int:
		return int(_crafted.get(id, 0))
	func get_offline_report() -> Dictionary:
		return _report

var _book = null
var _fake = null
var _fired: Array = []
var _done := false

func _initialize() -> void:
	_book = LogBookScript.new()
	root.add_child(_book)
	_fake = FakeSim.new()
	root.add_child(_fake)

func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	_run()
	return true

func _run() -> void:
	_book.line_ready.connect(func(t): _fired.append({"day": _book.current_day(), "text": t}))
	_book.bind_sim(_fake)

	var day_sec := int(_book._day_sec)
	print("=== A 天数类：1 日=%d 秒，模拟到第 1400 天 ===" % day_sec)
	var marks := [88, 260, 400, 452, 456, 480, 613, 660, 845, 1100, 1400]
	for d in range(0, 1401):
		_fake.tick_count = d * day_sec
		_book._process(0.0)
		if d in marks:
			print("  [第 %4d 天] 累计 %d 条" % [d, _fired.size()])

	# 重播检查：只查一次性条目。循环允许同年段文案相同（3 变体覆盖 40 年）。
	var loop_texts := {}
	for loop in _book._loops:
		for v in loop["variants"]:
			loop_texts[String(v)] = true
	var seen := {}
	var dup := 0
	for f in _fired:
		var k := String(f["text"])
		if loop_texts.has(k):
			continue
		if seen.has(k):
			dup += 1
			print("  !! 一次性条目重复: 第 %d 天 %s" % [f["day"], k])
		seen[k] = true
	print("  合计 %d 条 / 一次性 %d（数据 %d）/ 重复 %d" % [
		_fired.size(), seen.size(), _book._entries.size(), dup])
	for loop in _book._loops:
		var cnt := 0
		for f in _fired:
			if loop["variants"].has(String(f["text"])):
				cnt += 1
		print("  循环 %s：播出 %d 次，安排日 %s" % [loop["id"], cnt, str(loop["days"].slice(0, 4))])

	print("=== B 事件类 ===")
	var before := _fired.size()
	_fake._crafted["zijin_dan"] = 1
	_book._process(0.0)
	_book._process(0.0)
	_book._process(0.0)
	var got := ""
	if _fired.size() > before:
		got = String(_fired[-1]["text"])
	print("  首次紫金丹：新增 %d 条（期望 1）→ %s" % [_fired.size() - before, got])
	var after_first := _fired.size()
	_fake._crafted["zijin_dan"] = 2
	for i in 5:
		_book._process(0.0)
	print("  再炼一次：新增 %d 条（期望 0）" % (_fired.size() - after_first))

	print("=== C 读档不补播 ===")
	var book2 = LogBookScript.new()
	root.add_child(book2)
	var fake2 = FakeSim.new()
	fake2.tick_count = 1400 * day_sec
	fake2._crafted["zijin_dan"] = 3        # 老存档里已经炼过
	fake2._report = {"real_sec": 0.0}
	root.add_child(fake2)
	var fired2 := []
	book2.line_ready.connect(func(t): fired2.append(t))
	book2.bind_sim(fake2)
	book2._process(0.0)
	print("  进入游戏时补播 %d 条（期望 0）" % fired2.size())

	print("=== D 离线 6 小时 ===")
	var book3 = LogBookScript.new()
	root.add_child(book3)
	var fake3 = FakeSim.new()
	fake3._report = {"real_sec": 25000.0}
	root.add_child(fake3)
	var fired3 := []
	book3.line_ready.connect(func(t): fired3.append(t))
	book3.bind_sim(fake3)
	var d3 := ""
	if fired3.size() > 0:
		d3 = String(fired3[0])
	print("  启动即播 %d 条（期望 1）→ %s" % [fired3.size(), d3])

	print("--- 最后 6 条 ---")
	for i in range(maxi(_fired.size() - 6, 0), _fired.size()):
		print("  第 %d 天：%s" % [int(_fired[i]["day"]), String(_fired[i]["text"])])
