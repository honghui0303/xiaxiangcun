extends SceneTree

## 校验脚本（M3 回归用，保留）：狗
##   A 出现/消失挂在日志的"天"上：第 95 天没有、96 天出现、899 天还在、900 天没了
##   B 状态机：连续模拟 15 分钟，统计走/停/趴三种状态的占比、坐标范围、趴过几次
##   C 边界：任何时刻都不出院子（x 落在 [0.20w, 0.93w]），y 恒等于 BASE_Y
##
## 用法：godot --headless --path . --script res://tools/probe_dog.gd

const DogScript := preload("res://scripts/dog.gd")
const LogBookScript := preload("res://scripts/logbook.gd")

class FakeSim extends Node:
	var tick_count: int = 0
	func crafted_count(_id: String) -> int:
		return 0
	func get_offline_report() -> Dictionary:
		return {}

## 狗只认 current_day()，不需要真的日志引擎
class FakeBook extends Node:
	var day := 0.0
	func current_day() -> float:
		return day

var _done := false
var _book = null

func _initialize() -> void:
	# headless 下 root 窗口默认只有几十像素宽，狗的 _spawn 会因为 w<200 直接放弃。
	# 这里显式撑到和真实窗口一样大。
	root.size = Vector2i(1920, 264)
	_book = FakeBook.new()
	root.add_child(_book)

func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	_run()
	return true

func _new_dog(day: float) -> Node2D:
	_book.day = day
	var d = DogScript.new()
	root.add_child(d)
	d.bind_logbook(_book, 1920.0)
	return d

func _run() -> void:
	print("=== A 出现与消失 ===")
	for day in [1, 95, 96, 500, 899, 900, 1500]:
		var d := _new_dog(float(day))
		d._process(0.0)                    # 第一帧只会 _spawn，不推进
		d._process(0.0)
		var st := int(d._state)
		var label: String = ["GONE", "WANDER", "PAUSE", "LIE"][st]
		print("  第 %4d 天 → %-6s x=%.0f" % [day, label, d.position.x])
		d.queue_free()

	print("=== B 状态机（第 200 天起，模拟 15 分钟）===")
	var dog := _new_dog(200.0)
	dog._process(0.0)
	var w := 1920.0
	var base_y: float = dog.BASE_Y

	var frames := 900 * 60
	var cnt := [0, 0, 0, 0]
	var min_x := 1e9
	var max_x := -1e9
	var bad_y := 0
	var lie_events: Array = []
	var t := 0.0
	var prev_state := int(dog._state)
	var lie_start := 0.0

	for i in frames:
		dog._process(1.0 / 60.0)
		t += 1.0 / 60.0
		var st := int(dog._state)
		cnt[st] += 1
		if st != 0:
			min_x = minf(min_x, dog.position.x)
			max_x = maxf(max_x, dog.position.x)
			if absf(dog.position.y - base_y) > 0.01:
				bad_y += 1
			if st == 3 and prev_state != 3:
				lie_start = t
			if st != 3 and prev_state == 3:
				lie_events.append({"at": lie_start, "dur": t - lie_start, "x": dog.position.x})
		prev_state = st

	var total := float(frames)
	print("  走动 %5.1f%%  停留 %5.1f%%  趴着 %5.1f%%  不在场 %5.1f%%" % [
		cnt[1] / total * 100.0, cnt[2] / total * 100.0,
		cnt[3] / total * 100.0, cnt[0] / total * 100.0])
	print("  x 范围 %.0f ~ %.0f（院子 %.0f ~ %.0f）" % [
		min_x, max_x, w * 0.20, w * 0.93])
	print("  y 偏离基线 %d 帧（期望 0）" % bad_y)
	print("  趴下 %d 次" % lie_events.size())
	var prev_end := -999.0
	var gap_ok := true
	for e in lie_events:
		var gap: float = e["at"] - prev_end
		if prev_end > -900.0 and gap < 45.0:
			gap_ok = false
			print("  !! 两次趴下间隔只有 %.0f 秒（期望 ≥50）" % gap)
		var spot: String = "炉边" if absf(float(e["x"]) - w * 0.335) < 8.0 else ("门槛" if absf(float(e["x"]) - w * 0.205) < 8.0 else "??")
		print("    第 %5.0f 秒在%s趴下（x=%.0f），趴了 %.0f 秒" % [e["at"], spot, e["x"], e["dur"]])
		prev_end = (e["at"] as float) + (e["dur"] as float)
	print("  冷却校验：%s" % ("通过" if gap_ok else "失败"))
	print("  边界校验：%s" % ("通过" if (min_x >= w * 0.20 - 0.6 and max_x <= w * 0.93 + 0.6 and bad_y == 0) else "失败"))


	print("=== C 狗趴墙根 → 日志那条事件 ===")
	var book = LogBookScript.new()
	root.add_child(book)
	var fake_sim = FakeSim.new()
	root.add_child(fake_sim)
	var lines: Array = []
	book.line_ready.connect(func(t): lines.append(String(t)))
	book.bind_sim(fake_sim)
	# 已播状态存在 user://logbook.json 里，上一轮跑过就会把它记上，
	# 那样这段永远测出 0 条。测试从头开始，先清掉。
	book._seen.clear()

	var dog2 := _new_dog(200.0)
	dog2.lay_at_door.connect(func(): book.mark("dog:door"))
	dog2._process(0.0)
	var before := lines.size()
	# 直接把它摆到墙根，并让它决定趴下
	dog2._state = 1
	dog2._going_lie = true
	dog2._target_x = 1920.0 * 0.205
	dog2.position.x = dog2._target_x
	dog2._process(0.01)
	var got: String = "" if lines.size() <= before else String(lines[-1])
	print("  趴下后播 %d 条（期望 1）→ %s" % [lines.size() - before, got])
	var after_first := lines.size()
	dog2._state = 1
	dog2._going_lie = true
	dog2._process(0.01)
	print("  再趴一次：新增 %d 条（期望 0）" % (lines.size() - after_first))
