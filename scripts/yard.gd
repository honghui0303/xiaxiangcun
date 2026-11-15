extends Node2D

## 小院绘制层（占位美术）
## 全部用色块多边形画出来，M4 阶段整体替换成贴图，接口不变。
## 布局按窗口宽度比例计算，任何分辨率都不会散架。
## M1 起额外承担两件事：给 Pawn 提供目标点坐标（只读）、按 Sim 的地块状态画灵草生长。

const SimScript := preload("res://scripts/sim.gd")

const GROUND_TOP := 62.0
const GROUND_BOTTOM := 218.0
const BASE_Y := 194.0          # 所有物件站立的地面基准线

const C_SKY := Color(0.02, 0.045, 0.055)
const C_GRASS_FAR := Color(0.19, 0.28, 0.16)
const C_GRASS_NEAR := Color(0.34, 0.47, 0.26)
const C_WALL := Color(0.27, 0.26, 0.23)
const C_TILE := Color(0.16, 0.28, 0.25)
const C_TILE_DARK := Color(0.10, 0.19, 0.17)
const C_WOOD := Color(0.44, 0.32, 0.21)
const C_WOOD_DARK := Color(0.25, 0.18, 0.12)
const C_STONE := Color(0.47, 0.46, 0.41)
const C_STONE_DARK := Color(0.33, 0.32, 0.28)
const C_SOIL := Color(0.30, 0.22, 0.14)
const C_SOIL_DARK := Color(0.20, 0.15, 0.10)
const C_HERB := Color(0.52, 0.87, 0.51)
const C_BRONZE := Color(0.29, 0.42, 0.38)
const C_BRONZE_HI := Color(0.46, 0.62, 0.56)
const C_WATER := Color(0.18, 0.42, 0.48)
const C_BAMBOO := Color(0.19, 0.30, 0.20)

var _w: float = 1920.0
var _t: float = 0.0
var _last_draw: float = -1.0
var _stars: Array[Vector2] = []
var _herbs: Array = []
var _gravel: Array = []
var _sim: SimScript = null

func _ready() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261115
	for i in 70:
		_stars.append(Vector2(rng.randf(), rng.randf() * 0.75))
	# 灵草：[地块索引, 横向偏移比例, 高度]
	for i in 3:
		for j in 6:
			_herbs.append([i, 0.10 + j * 0.155, rng.randf_range(0.7, 1.15), rng.randf() * TAU])
	# 碎石：[x比例, y比例, 宽, 高, 与草地混色量]
	for i in 170:
		_gravel.append([
			rng.randf(), rng.randf(),
			rng.randf_range(9.0, 21.0), rng.randf_range(2.8, 5.4),
			rng.randf() * 0.4
		])

func _process(delta: float) -> void:
	_t += delta
	# 8~10fps 重绘就够了，像素风不需要 60 帧
	if _t - _last_draw > 0.1:
		_last_draw = _t
		queue_redraw()

func _draw() -> void:
	_w = get_viewport_rect().size.x
	# headless 模式下视口只有 64x64，按比例算出来的多边形会退化自相交，
	# 引擎会刷 triangulation failed。这不是布局问题，直接不画即可。
	if _w < 200.0:
		return
	_draw_sky()
	_draw_far_bamboo()
	_draw_fence()
	_draw_ground()
	_draw_plaza()
	_draw_cushion()
	_draw_path()
	_draw_house()
	_draw_fields()
	_draw_well()
	_draw_bamboo()
	_draw_cauldron()
	_draw_forge()
	_draw_lanterns()

# ---------- 对外接口：Pawn 用的目标点（只读，不改绘制状态） ----------

func set_sim(sim_ref: SimScript) -> void:
	_sim = sim_ref
	queue_redraw()

## 第 i 块田的作业点：站姿落在田块前沿
func get_field_point(i: int) -> Vector2:
	var g := _field_geo()
	return Vector2(
		float(g["fx"]) + float(i) * (float(g["fw"]) + float(g["gap"])) + float(g["fw"]) * 0.5,
		BASE_Y + 2.0
	)

## 丹炉作业点：站在炉子右侧，别把炉身挡住
func get_cauldron_point() -> Vector2:
	return Vector2(get_viewport_rect().size.x * 0.385 + 24.0, BASE_Y + 2.0)

## 蒲团（打坐点）
func get_meditate_point() -> Vector2:
	return Vector2(get_viewport_rect().size.x * 0.295, BASE_Y)

## 竹林采叶点：站在竹丛左侧，别挡住竹子，人能弯腰够到叶
func get_bamboo_point() -> Vector2:
	return Vector2(get_viewport_rect().size.x * 0.80 - 26.0, BASE_Y + 2.0)

## 井边打水点：站在井台左侧，弯腰能碰到桶
func get_well_point() -> Vector2:
	return Vector2(get_viewport_rect().size.x * 0.735 - 34.0, BASE_Y + 2.0)

func _field_geo() -> Dictionary:
	var w := get_viewport_rect().size.x
	return {"fx": w * 0.465, "fw": w * 0.058, "gap": w * 0.009}

# ---------- 基础画笔 ----------

func _rect(x: float, y: float, w: float, h: float, c: Color) -> void:
	draw_rect(Rect2(x, y, w, h), c)

func _poly(pts: Array, c: Color) -> void:
	var arr := PackedVector2Array()
	for p in pts:
		arr.append(Vector2(p[0], p[1]))
	draw_colored_polygon(arr, c)

func _ellipse(center: Vector2, rx: float, ry: float, c: Color) -> void:
	var pts := PackedVector2Array()
	for i in 24:
		var a := TAU * float(i) / 24.0
		pts.append(center + Vector2(cos(a) * rx, sin(a) * ry))
	draw_colored_polygon(pts, c)

# ---------- 场景元素 ----------

func _draw_sky() -> void:
	# 顶部完全透明，往下逐渐压深，让小院自然融进桌面壁纸
	var pts := PackedVector2Array([
		Vector2(0, 0), Vector2(_w, 0), Vector2(_w, GROUND_TOP), Vector2(0, GROUND_TOP)
	])
	var cols := PackedColorArray([
		Color(C_SKY.r, C_SKY.g, C_SKY.b, 0.0),
		Color(C_SKY.r, C_SKY.g, C_SKY.b, 0.0),
		Color(C_SKY.r, C_SKY.g, C_SKY.b, 0.97),
		Color(C_SKY.r, C_SKY.g, C_SKY.b, 0.97),
	])
	draw_polygon(pts, cols)

	for i in _stars.size():
		var s: Vector2 = _stars[i]
		var twinkle: float = 0.35 + 0.35 * sin(_t * 1.6 + i * 0.9)
		var a: float = twinkle * (1.0 - s.y / 0.75) * 1.6
		if a <= 0.02:
			continue
		draw_rect(Rect2(s.x * _w, s.y * 50.0, 1.6, 1.6), Color(0.75, 0.88, 0.80, minf(a, 0.9)))

func _draw_far_bamboo() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7788
	for i in 26:
		var x := rng.randf() * _w
		var h := rng.randf_range(26.0, 52.0)
		var w := rng.randf_range(1.5, 2.6)
		draw_rect(Rect2(x, GROUND_TOP - h, w, h), Color(C_BAMBOO.r, C_BAMBOO.g, C_BAMBOO.b, 0.55))
	for i in 14:
		var x := rng.randf() * _w
		var y := GROUND_TOP - rng.randf_range(20.0, 44.0)
		_poly([[x, y], [x + 9, y - 3], [x + 10, y + 2]], Color(C_BAMBOO.r, C_BAMBOO.g, C_BAMBOO.b, 0.45))

func _draw_fence() -> void:
	var top := 48.0
	var fh := 14.0
	_rect(0, top, _w, fh, C_WALL)
	# 砖缝
	var x := 0.0
	while x < _w:
		draw_line(Vector2(x, top + fh * 0.5), Vector2(minf(x + 18.0, _w), top + fh * 0.5), Color(0.17, 0.16, 0.14, 0.75), 1.0)
		x += 18.0
	# 墙上的一圈青瓦
	_rect(0, top - 6, _w, 6, C_TILE)
	_rect(0, top - 7, _w, 2, C_TILE_DARK)
	# 墙根阴影
	_rect(0, top + fh, _w, 4, Color(0.06, 0.09, 0.06, 0.75))

func _draw_ground() -> void:
	var pts := PackedVector2Array([
		Vector2(0, GROUND_TOP), Vector2(_w, GROUND_TOP),
		Vector2(_w, GROUND_BOTTOM), Vector2(0, GROUND_BOTTOM)
	])
	var cols := PackedColorArray([
		C_GRASS_FAR, C_GRASS_FAR, C_GRASS_NEAR, C_GRASS_NEAR
	])
	draw_polygon(pts, cols)
	# 地面横向明暗带，做出一点纵深
	_rect(0, GROUND_TOP + 6, _w, 2, Color(0.10, 0.16, 0.09, 0.35))

func _draw_plaza() -> void:
	# 不做整块铺装：平视视角下矩形地面必然读成"一堵墙"。
	# 改成散布的碎石，没有硬边界，自然融进草地。
	var px0 := _w * 0.20
	var px1 := _w * 0.56
	var py0 := BASE_Y - 40.0
	var py1 := BASE_Y + 8.0
	for item in _gravel:
		var x: float = px0 + float(item[0]) * (px1 - px0)
		var y: float = py0 + float(item[1]) * (py1 - py0)
		var w: float = item[2]
		var h: float = item[3]
		var mix: float = item[4]
		var c: Color = Color(0.36, 0.35, 0.30).lerp(Color(0.31, 0.43, 0.25), mix)
		_rect(x, y, w, h, c)

func _draw_cushion() -> void:
	# 打坐蒲团：垫在广场空地上，小人有地方盘腿
	var cx := _w * 0.295
	var by := BASE_Y
	_ellipse(Vector2(cx, by - 1.5), 13.0, 4.6, Color(0.13, 0.15, 0.19, 0.55))
	_ellipse(Vector2(cx, by - 3.0), 12.0, 4.2, Color(0.24, 0.27, 0.33))
	_ellipse(Vector2(cx, by - 4.2), 10.4, 3.2, Color(0.31, 0.35, 0.42))
	_ellipse(Vector2(cx, by - 5.0), 7.0, 1.8, Color(0.26, 0.30, 0.37))

func _draw_path() -> void:
	# 广场之外的踏石小径，一路通到田地那头
	var y := BASE_Y - 4.0
	var x := _w * 0.525
	var i := 0
	while x < _w * 0.80:
		var pw := 24.0 + float((i * 7) % 12)
		var ph := 9.0
		var yy := y + float((i % 2) * 9) - 4.0
		_rect(x, yy, pw, ph, Color(0.30, 0.30, 0.26))
		_rect(x + 1.5, yy + 1.5, pw - 3, ph - 3.5, Color(0.40, 0.39, 0.34))
		x += pw + 7.0
		i += 1

func _draw_house() -> void:
	var x0 := _w * 0.035
	var hw := _w * 0.155
	var wall_top := BASE_Y - 68.0

	# 墙体
	_rect(x0, wall_top, hw, 68, C_WOOD)
	var px := x0 + 6.0
	while px < x0 + hw - 4.0:
		draw_line(Vector2(px, wall_top + 2), Vector2(px, BASE_Y - 2), Color(0.31, 0.22, 0.14, 0.5), 1.0)
		px += 9.0
	# 立柱
	_rect(x0, wall_top, 5, 68, C_WOOD_DARK)
	_rect(x0 + hw - 5, wall_top, 5, 68, C_WOOD_DARK)
	# 门槛石
	_rect(x0 - 4, BASE_Y - 3, hw + 8, 3, C_STONE_DARK)
	# 门
	var dw := hw * 0.30
	var dx := x0 + (hw - dw) * 0.5
	_rect(dx - 3, BASE_Y - 50, dw + 6, 50, C_WOOD_DARK)
	_rect(dx, BASE_Y - 47, dw, 47, Color(0.13, 0.09, 0.06))
	draw_line(Vector2(dx + dw * 0.5, BASE_Y - 47), Vector2(dx + dw * 0.5, BASE_Y), Color(0.07, 0.05, 0.03), 1.5)
	draw_circle(Vector2(dx + dw * 0.26, BASE_Y - 26), 1.6, Color(0.58, 0.47, 0.26))
	draw_circle(Vector2(dx + dw * 0.74, BASE_Y - 26), 1.6, Color(0.58, 0.47, 0.26))
	# 窗
	for wx in [x0 + 12.0, x0 + hw - 34.0]:
		_rect(wx, BASE_Y - 56, 22, 17, C_WOOD_DARK)
		_rect(wx + 2, BASE_Y - 54, 18, 13, Color(0.66, 0.50, 0.26, 0.9))
		draw_line(Vector2(wx + 11, BASE_Y - 54), Vector2(wx + 11, BASE_Y - 41), C_WOOD_DARK, 1.0)
		draw_line(Vector2(wx + 2, BASE_Y - 47), Vector2(wx + 20, BASE_Y - 47), C_WOOD_DARK, 1.0)
	# 青瓦屋顶
	_poly([
		[x0 - 18, wall_top + 3], [x0 + hw + 18, wall_top + 3],
		[x0 + hw * 0.88, wall_top - 38], [x0 + hw * 0.12, wall_top - 38]
	], C_TILE)
	# 屋脊
	_poly([
		[x0 + hw * 0.12, wall_top - 38], [x0 + hw * 0.88, wall_top - 38],
		[x0 + hw * 0.80, wall_top - 43], [x0 + hw * 0.20, wall_top - 43]
	], C_TILE_DARK)
	# 瓦垄
	var rx := x0 - 16.0
	while rx < x0 + hw + 16.0:
		draw_line(Vector2(rx, wall_top + 1), Vector2(rx + 3, wall_top - 36), Color(0.08, 0.15, 0.13, 0.45), 1.0)
		rx += 10.0
	# 屋檐挑出 + 投影
	_rect(x0 - 18, wall_top + 3, hw + 36, 3, Color(0.06, 0.10, 0.08, 0.8))
	_rect(x0, wall_top + 6, hw, 6, Color(0.10, 0.07, 0.04, 0.32))

func _draw_fields() -> void:
	var fx := _w * 0.465
	var fw := _w * 0.058
	var gap := _w * 0.009
	var fh := 24.0
	# 先问 Sim 每块田的状态：0 空田 / 1 生长中 / 2 成熟 / 3 未开垦（境界不够）
	var vis: Array = []
	for i in 3:
		vis.append(_plot_visual(i))
	for i in 3:
		var x := fx + float(i) * (fw + gap)
		var y := BASE_Y - fh
		var st: int = int(vis[i]["state"])
		var soil: Color = C_SOIL if st != 3 else Color(0.21, 0.17, 0.12)
		# 梯形田块：顶边窄、底边宽，才有俯视的纵深
		_poly([
			[x + 5, y], [x + fw - 5, y],
			[x + fw, y + fh], [x, y + fh]
		], soil)
		# 垄
		for k in 3:
			var t := float(k + 1) / 4.0
			var yy := y + fh * t
			var inset := 5.0 * (1.0 - t)
			draw_line(Vector2(x + inset, yy), Vector2(x + fw - inset, yy), C_SOIL_DARK, 1.2)
		# 右侧田埂
		_poly([
			[x + fw - 5, y], [x + fw, y + fh], [x + fw - 2, y + fh], [x + fw - 7, y]
		], Color(0.38, 0.31, 0.21))

	# 灵草：高度与颜色跟着 Sim 的地块状态走（空地 → 幼苗 → 成熟）
	for h in _herbs.size():
		var item: Array = _herbs[h]
		var idx: int = item[0]
		var v: Dictionary = vis[idx]
		if int(v["state"]) == 0 or int(v["state"]) == 3:
			continue  # 空地就让它空着，玩家一眼能看出播种有没有生效
		var grow: float = 0.30 + 0.70 * float(v["progress"])
		var ready: bool = int(v["state"]) == 2
		var px: float = fx + float(idx) * (fw + gap) + fw * float(item[1])
		var hh: float = 7.4 * float(item[2]) * grow
		var sway: float = sin(_t * 1.3 + float(item[3])) * 1.2 * grow
		var by := BASE_Y - 7.0
		var col: Color = C_HERB.lerp(Color(0.78, 0.96, 0.56), 1.0 - grow)
		draw_line(Vector2(px, by), Vector2(px + sway, by - hh), col, 1.6)
		draw_line(Vector2(px, by - hh * 0.55), Vector2(px + sway * 1.4 + 2.2, by - hh * 0.8), col, 1.2)
		if ready:
			# 成熟标记：顶端一点荧绿，远看就知道哪块田可以去收了
			draw_circle(Vector2(px + sway, by - hh - 1.0), 1.15, Color(0.86, 1.0, 0.70, 0.85))

## 地块表现参数。没接 sim 时退化成"全都长满"，绘制层可以独立跑。
func _plot_visual(idx: int) -> Dictionary:
	if _sim == null:
		return {"state": 2, "progress": 1.0}
	if idx >= _sim.get_plot_count():
		return {"state": 3, "progress": 0.0}
	if idx >= _sim.usable_plot_count():
		return {"state": 3, "progress": 0.0}
	var p: Dictionary = _sim.get_plot(idx)
	if p.is_empty():
		return {"state": 2, "progress": 1.0}
	if String(p.get("crop", "")) == "":
		return {"state": 0, "progress": 0.0}
	if bool(p.get("ready", false)):
		return {"state": 2, "progress": 1.0}
	return {"state": 1, "progress": float(p.get("progress", 0.0))}

func _draw_well() -> void:
	var cx := _w * 0.735
	var by := BASE_Y
	# 井台
	_ellipse(Vector2(cx, by - 2), 26, 9, C_STONE_DARK)
	_ellipse(Vector2(cx, by - 4), 24, 8, C_STONE)
	_ellipse(Vector2(cx, by - 5), 17, 5.5, Color(0.07, 0.10, 0.10))
	_ellipse(Vector2(cx, by - 5), 15, 4.5, C_WATER)
	# 水面反光
	draw_line(Vector2(cx - 8, by - 6), Vector2(cx + 4, by - 6), Color(0.55, 0.80, 0.82, 0.6), 1.0)
	# 井架
	_rect(cx - 20, by - 34, 3, 30, C_WOOD_DARK)
	_rect(cx + 17, by - 34, 3, 30, C_WOOD_DARK)
	_poly([[cx - 25, by - 34], [cx + 25, by - 34], [cx + 15, by - 42], [cx - 15, by - 42]], C_TILE)
	# 木桶
	_rect(cx - 4, by - 22, 9, 9, Color(0.36, 0.26, 0.16))
	draw_line(Vector2(cx, by - 34), Vector2(cx, by - 22), Color(0.30, 0.28, 0.22), 1.0)

func _draw_bamboo() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var base_x := _w * 0.80
	for i in 6:
		var x := base_x + i * (_w * 0.016) + rng.randf_range(-4.0, 4.0)
		var h := rng.randf_range(58.0, 86.0)
		var bw := 2.6
		_rect(x, BASE_Y - h, bw, h, C_BAMBOO)
		var seg := BASE_Y - h + 8.0
		while seg < BASE_Y:
			_rect(x, seg, bw, 1.2, Color(0.10, 0.18, 0.11))
			seg += 12.0
		# 竹叶
		for k in 3:
			var ly := BASE_Y - h + 10.0 + float(k) * 14.0
			_poly([[x, ly], [x + 12, ly - 5], [x + 13, ly + 1]], Color(0.24, 0.38, 0.24, 0.9))
			_poly([[x + 2, ly + 4], [x - 10, ly - 1], [x - 11, ly + 5]], Color(0.21, 0.34, 0.21, 0.9))

func _draw_cauldron() -> void:
	var cx := _w * 0.385
	var by := BASE_Y
	# 光晕（丹炉常燃）
	_ellipse(Vector2(cx, by - 10), 22, 8, Color(0.85, 0.45, 0.15, 0.10 + 0.04 * sin(_t * 2.0)))
	# 三足
	_rect(cx - 12, by - 8, 3, 8, C_BRONZE)
	_rect(cx + 9, by - 8, 3, 8, C_BRONZE)
	_rect(cx - 2, by - 7, 3, 7, C_BRONZE)
	# 炉身
	_poly([[cx - 16, by - 30], [cx + 16, by - 30], [cx + 11, by - 8], [cx - 11, by - 8]], C_BRONZE)
	# 高光
	_poly([[cx - 13, by - 29], [cx - 7, by - 29], [cx - 5, by - 10], [cx - 9, by - 10]], Color(0.40, 0.56, 0.50, 0.55))
	# 口沿
	_ellipse(Vector2(cx, by - 30), 17, 4.5, C_BRONZE_HI)
	_ellipse(Vector2(cx, by - 30.5), 13, 3.2, Color(0.10, 0.16, 0.14))
	# 炉火
	var fy := by - 32.0 + sin(_t * 6.0) * 0.8
	_poly([[cx - 4, fy], [cx, fy - 7], [cx + 4, fy]], Color(0.95, 0.62, 0.25, 0.85))
	_poly([[cx - 2, fy], [cx, fy - 4], [cx + 2, fy]], Color(1.0, 0.88, 0.55, 0.9))

func _draw_forge() -> void:
	var cx := _w * 0.545
	var by := BASE_Y
	# 石台
	_rect(cx - 26, by - 16, 52, 16, C_STONE_DARK)
	_rect(cx - 26, by - 18, 52, 3, C_STONE)
	# 铁砧
	_poly([[cx - 11, by - 18], [cx + 11, by - 18], [cx + 8, by - 26], [cx - 8, by - 26]], Color(0.30, 0.32, 0.33))
	_rect(cx - 13, by - 24, 26, 3, Color(0.42, 0.45, 0.46))
	# 铁锤
	draw_line(Vector2(cx + 14, by - 16), Vector2(cx + 20, by - 28), C_WOOD_DARK, 2.0)
	_rect(cx + 17, by - 32, 7, 5, Color(0.38, 0.40, 0.41))
	# 火星
	for i in 3:
		var p := fmod(_t * 0.9 + float(i) * 0.33, 1.0)
		var sx := cx + 6.0 + p * 8.0
		var sy := by - 26.0 - p * 14.0
		draw_rect(Rect2(sx, sy, 1.6, 1.6), Color(1.0, 0.72, 0.30, 1.0 - p))

func _draw_lanterns() -> void:
	for fx in [0.255, 0.665]:
		var cx: float = _w * fx
		var by := BASE_Y
		_rect(cx - 2, by - 26, 4, 26, C_STONE_DARK)
		_rect(cx - 6, by - 30, 12, 4, C_STONE)
		_poly([[cx - 7, by - 44], [cx + 7, by - 44], [cx + 4, by - 30], [cx - 4, by - 30]], Color(0.22, 0.24, 0.22))
		var glow := 0.55 + 0.12 * sin(_t * 2.4 + cx)
		_ellipse(Vector2(cx, by - 38), 14, 12, Color(0.95, 0.75, 0.40, 0.10))
		_rect(cx - 3, by - 41, 6, 7, Color(0.98, 0.82, 0.48, glow))
