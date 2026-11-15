extends SceneTree
## The movie of four people, each in a quarter of the picture; see docs/world.md.

const Lib := preload("res://tests/world_lib.gd")
const Avatar := preload("res://tests/avatar.gd")
const Parts := preload("res://tests/parts.gd")
const VIEWS := 8
const FPS := 32
const TICKS := 1728
const RADIUS := 6.6
const ARM := 0.05
const NAMES := ["Aki", "Bo", "Cy", "Dee"]
const COLORS := [Color(1.0, 0.62, 0.3), Color(0.4, 0.75, 1.0), Color(0.55, 0.95, 0.5), Color(1.0, 0.55, 0.8)]
const AXES := [Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN, Vector3.BACK, Vector3.FORWARD]
const AXIS_COLORS := [Color(1, 0.25, 0.25), Color(0.6, 0.1, 0.1), Color(0.3, 1, 0.3), Color(0.1, 0.55, 0.1), Color(0.35, 0.55, 1), Color(0.1, 0.2, 0.7)]

var lib: Object
var control := ""
var tick := -1
var frame := 0
var cams: Array = []
var avatars: Array = []
var stars: Array = []
var tags: Array = []
var shapes: Array = []
var touches: Array = []
var floor_geom := -1
var caption: Label
var spark: Spark
var last_usec := 0


## Milliseconds a frame took to make, newest at the right.
class Spark extends Control:
	var values: Array = []
	var now_ms := 0.0
	var mean_ms := 0.0

	func add(ms: float) -> void:
		values.append(ms)
		if values.size() > 160:
			values.pop_front()
		now_ms = ms
		var sum := 0.0
		for v in values:
			sum += v
		mean_ms = sum / values.size()
		queue_redraw()

	func _draw() -> void:
		var font := ThemeDB.fallback_font
		draw_string(font, Vector2(0, 13), "ms per frame: %.0f now, %.0f mean" % [now_ms, mean_ms], HORIZONTAL_ALIGNMENT_LEFT, -1, 13)
		if values.size() < 2:
			return
		var top: float = maxf(values.max(), 1.0)
		var box := Rect2(0, 20, size.x, size.y - 24)
		draw_rect(box, Color(1, 1, 1, 0.08))
		var pts := PackedVector2Array()
		for i in values.size():
			pts.append(Vector2(box.position.x + box.size.x * i / 159.0, box.end.y - box.size.y * values[i] / top))
		draw_polyline(pts, Color(1.0, 0.85, 0.3), 1.5)
		draw_string(font, Vector2(box.end.x - 46, box.position.y + 12), "%.0f ms" % top, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 1, 1, 0.6))
var worst_mm := 0.0
var touched := 0


func _rad2(i: int) -> float:
	var r := 0.0
	var f := 0.5
	var n := i
	while n > 0:
		r += f * float(n & 1)
		n >>= 1
		f *= 0.5
	return r


func _view_dir(view: int) -> Vector3:
	var pitch := acos(1.0 - 2.0 * float(view) / float(VIEWS)) - PI / 2.0
	var phi := TAU * _rad2(view)
	return Vector3(sin(phi) * cos(pitch), sin(pitch), -cos(phi) * cos(pitch))


func _end(line: String, code: int) -> void:
	print(line)
	quit(code)


func _at(t: PackedFloat64Array, body: int) -> Vector3:
	return Vector3(t[body * 7 + 1], t[body * 7 + 2], t[body * 7])


func _turn(t: PackedFloat64Array, body: int) -> Basis:
	return Basis(Quaternion(t[body * 7 + 5], t[body * 7 + 6], t[body * 7 + 4], t[body * 7 + 3]))


func _xray(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = color
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.no_depth_test = true
	return mat


func _star(stage: Node, color: Color) -> MultiMesh:
	var ball := SphereMesh.new()
	ball.radius = 0.011
	ball.height = 0.022
	ball.material = _xray(Color.WHITE)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = ball
	mm.instance_count = 21 * 7
	for i in 21 * 7:
		mm.set_instance_color(i, color if i % 7 == 0 else AXIS_COLORS[i % 7 - 1])
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	stage.add_child(mi)
	return mm


func _floor_and_shapes(stage: Node, v: int) -> void:
	var table: PackedFloat64Array = lib.engines[v].vmcall("mjc_geom_table")
	var mine: Array = []
	for i in table.size() / 13:
		var row: PackedFloat64Array = table.slice(i * 13, i * 13 + 13)
		if row[2] == 0.0 and row[3] == 0.0:
			continue
		var kind := int(row[1])
		var mi := MeshInstance3D.new()
		if kind == 0:
			floor_geom = i
			var im := ImmediateMesh.new()
			im.surface_begin(Mesh.PRIMITIVE_LINES, _xray(Color(0.6, 0.65, 0.7, 0.35)))
			for k in range(-10, 11):
				im.surface_add_vertex(Vector3(k, 0, -10))
				im.surface_add_vertex(Vector3(k, 0, 10))
				im.surface_add_vertex(Vector3(-10, 0, k))
				im.surface_add_vertex(Vector3(10, 0, k))
			im.surface_end()
			mi.mesh = im
			var quad := PlaneMesh.new()
			quad.size = Vector2(20, 20)
			quad.material = _xray(Color(0.5, 0.6, 0.8, 0.07))
			var sheet := MeshInstance3D.new()
			sheet.mesh = quad
			mi.add_child(sheet)
			mi.position = Vector3(row[8], row[9], row[7])
		elif kind == 3:
			var cap := CapsuleMesh.new()
			cap.radius = row[4]
			cap.height = 2.0 * (row[5] + row[4])
			cap.material = _xray(Color(0.3, 1.0, 0.5, 0.22))
			mi.mesh = cap
			mine.append([i, mi])
		else:
			var mark := SphereMesh.new()
			mark.radius = 0.012
			mark.height = 0.024
			mark.material = _xray(Color(0.3, 1.0, 0.5, 0.7))
			mi.mesh = mark
			mine.append([i, mi])
		stage.add_child(mi)
	shapes.append(mine)
	var spot := SphereMesh.new()
	spot.radius = 0.016
	spot.height = 0.032
	spot.material = _xray(Color(1.0, 0.95, 0.2, 1.0))
	var dots: Array = []
	for k in 16:
		var t := MeshInstance3D.new()
		t.mesh = spot
		t.visible = false
		stage.add_child(t)
		dots.append(t)
	touches.append(dots)


func _initialize() -> void:
	var plain: Array = []
	for x in OS.get_cmdline_user_args():
		if x.begins_with("--control="):
			control = x.trim_prefix("--control=")
		else:
			plain.append(x)
	if plain.size() != 3 or (control != "" and not Lib.CONTROLS.has(control)):
		_end("RESULT: ERROR give the physics guest, the avatar and the clips directory", 2)
		return
	var here := ProjectSettings.globalize_path("res://")
	lib = Lib.new()
	if not lib.build(here, plain[0], plain[2], control):
		_end("RESULT: ERROR " + lib.error, 2)
		return
	lib.ticks = TICKS
	var ui := VBoxContainer.new()
	ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.add_theme_constant_override("separation", 0)
	root.add_child(ui)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 0)
	grid.add_theme_constant_override("v_separation", 0)
	ui.add_child(grid)
	for v in 4:
		var stage := SubViewport.new()
		stage.own_world_3d = true
		stage.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		var box := SubViewportContainer.new()
		box.stretch = true
		box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		box.size_flags_vertical = Control.SIZE_EXPAND_FILL
		box.add_child(stage)
		grid.add_child(box)
		var env := Environment.new()
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0.13, 0.14, 0.16).lerp(COLORS[v], 0.06)
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color(1, 1, 1)
		env.ambient_light_energy = 0.35
		var we := WorldEnvironment.new()
		we.environment = env
		stage.add_child(we)
		for l in [[Vector3(-50, 35, 0), 0.7], [Vector3(55, -145, 0), 0.25]]:
			var light := DirectionalLight3D.new()
			light.rotation_degrees = l[0]
			light.light_energy = l[1]
			stage.add_child(light)
		_floor_and_shapes(stage, v)
		var cam := Camera3D.new()
		cam.fov = 46.0
		cam.near = 0.05
		cam.far = 80.0
		stage.add_child(cam)
		cam.make_current()
		cams.append(cam)
		var row: Array = []
		var star_row: Array = []
		var tag_row: Array = []
		for s in 4:
			var a = Avatar.new()
			if not a.build(Parts.dir(here, "follow"), plain[1], lib.bodies, lib.zero, COLORS[s]):
				_end("RESULT: ERROR " + a.error, 2)
				return
			stage.add_child(a.scene)
			row.append(a)
			star_row.append(_star(stage, COLORS[s].darkened(0.25)))
			var tag := Label3D.new()
			tag.text = NAMES[s] if s != v else NAMES[s] + " (me)"
			tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			tag.no_depth_test = true
			tag.modulate = COLORS[s]
			tag.font_size = 48
			tag.pixel_size = 0.004
			stage.add_child(tag)
			tag_row.append(tag)
		avatars.append(row)
		stars.append(star_row)
		tags.append(tag_row)
	var pad := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		pad.add_theme_constant_override(side, 8)
	ui.add_child(pad)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 16)
	pad.add_child(bar)
	caption = Label.new()
	caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	caption.add_theme_font_size_override("font_size", 13)
	bar.add_child(caption)
	spark = Spark.new()
	spark.custom_minimum_size = Vector2(230, 64)
	bar.add_child(spark)
	await process_frame
	tick = 0


func _show(v: int, s: int, pose: PackedFloat64Array, shown: bool) -> void:
	var a = avatars[v][s]
	a.scene.visible = shown
	stars[v][s].visible_instance_count = 21 * 7 if shown else 0
	tags[v][s].visible = shown
	if not shown:
		return
	a.pose(pose)
	var mm: MultiMesh = stars[v][s]
	for p in 21:
		var o := _at(pose, lib.ids[p])
		var b := _turn(pose, lib.ids[p])
		mm.set_instance_transform(p * 7, Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 1.6), o))
		for k in 6:
			mm.set_instance_transform(p * 7 + 1 + k, Transform3D(Basis.IDENTITY, o + b * AXES[k] * ARM))
	tags[v][s].position = _at(pose, lib.ids[0]) + Vector3(0, 0.32, 0)


func _process(_delta: float) -> bool:
	if tick < 0:
		return false
	if tick >= lib.ticks:
		print("VIDEO control=%s frames=%d fps=%d ticks=%d views=%d judged=%d valid=%d named=%s worst_mm=%.2f frames_touching_floor=%d" % [control if control != "" else "real", frame, FPS, tick, VIEWS, lib.judged, lib.valid, lib.named(), worst_mm, touched])
		print("RESULT: PASS recorded")
		quit(0)
		return true
	var clock := Time.get_ticks_usec()
	if last_usec > 0:
		spark.add((clock - last_usec) / 1000.0)
	last_usec = clock
	for k in 2:
		lib.step(tick)
		tick += 1
	var middle := Vector3.ZERO
	for s in 4:
		middle += _at(lib.now[s], lib.ids[3]) * 0.25
	var view: int = mini(tick * VIEWS / lib.ticks, VIEWS - 1)
	var dir := _view_dir(view)
	var focus := Vector3(middle.x, 0.9, middle.z)
	var spread := 0.0
	for s in 4:
		spread = maxf(spread, (_at(lib.now[s], lib.ids[3]) - middle).length())
	var from := focus + dir * maxf(RADIUS, spread * 2.6 + 2.0)
	var now_mm := 0.0
	var seen_pairs := 0
	var any_touch := false
	for v in 4:
		cams[v].transform = Transform3D(Basis.looking_at(focus - from, Vector3.UP if absf(dir.y) < 0.9 else Vector3(0, 0, 1)), from)
		_show(v, v, lib.now[v], true)
		for o in 3:
			var s: int = o + 1 if o >= v else o
			var shown: bool = lib.present(v, o, tick)
			_show(v, s, lib.seen[v][o], shown)
			if shown:
				seen_pairs += 1
				var was: PackedFloat64Array = lib.then(s)
				if lib.live and was.size() > 0:
					for p in 21:
						now_mm = maxf(now_mm, (_at(lib.seen[v][o], lib.ids[p]) - _at(was, lib.ids[p])).length() * 1000.0)
		var table: PackedFloat64Array = lib.engines[v].vmcall("mjc_geom_table")
		for sh in shapes[v]:
			var row: PackedFloat64Array = table.slice(sh[0] * 13, sh[0] * 13 + 13)
			var up := Vector3(row[11], row[12], row[10]).normalized()
			var basis: Basis = Basis(Quaternion(Vector3.UP, up)) if absf(up.dot(Vector3.UP)) < 0.999999 else Basis.IDENTITY
			sh[1].transform = Transform3D(basis, Vector3(row[8], row[9], row[7]))
		var c: PackedFloat64Array = lib.engines[v].vmcall("mjc_contacts")
		var n := 0
		for i in c.size() / 6:
			if int(c[i * 6]) != floor_geom and int(c[i * 6 + 1]) != floor_geom:
				continue
			if n < 16:
				touches[v][n].position = Vector3(c[i * 6 + 3], c[i * 6 + 4], c[i * 6 + 2])
				touches[v][n].visible = true
			n += 1
		for k in range(mini(n, 16), 16):
			touches[v][k].visible = false
		any_touch = any_touch or n > 0
	if any_touch:
		touched += 1
	worst_mm = maxf(worst_mm, now_mm)
	caption.text = "%s   view %d of %d      verdicts valid %d of %d   party named so far: %s      people drawn in the four worlds: %d of 12   largest distance now %.1f mm\nfour worlds: Aki top left, Bo top right, Cy bottom left, Dee bottom right. each shows its own body now and the others 18 ticks behind, only from sends three parties agreed on; a person not agreed on for 5 seconds is gone.\nparts are rotation stars (origin, and axis ends 5 cm out: X red, Y green, Z blue). floor and green shapes: the physics model's own colliding geoms, see-through. yellow: the engine's contacts with its floor." % [("planted: " + control) if control != "" else "real", view + 1, VIEWS, lib.valid, lib.judged, lib.named(), seen_pairs, now_mm]
	frame += 1
	return false
