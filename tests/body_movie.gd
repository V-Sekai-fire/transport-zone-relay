extends SceneTree


const VIEWS := 8
const FPS := 32
const RADIUS := 4.2
const FOCUS_HEIGHT := 0.9
const STRIP := 92
const APART := Vector3(1.6, 0, 0)
const ARM := 0.05
const AXES := [Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN, Vector3.BACK, Vector3.FORWARD]
const AXIS_COLORS := [Color(1, 0.25, 0.25), Color(0.6, 0.1, 0.1), Color(0.3, 1, 0.3), Color(0.1, 0.55, 0.1), Color(0.35, 0.55, 1), Color(0.1, 0.2, 0.7)]
const CLIPS := ["walk", "idle", "walk_back", "run"]

var lib: Object
var args: Array = []
var control := ""
var clip := -1
var frame := 0
var tick := 0
var cam: Camera3D
var sent: Array[MeshInstance3D] = []
var drawn: Array[MeshInstance3D] = []
var sent_star: MultiMesh
var drawn_star: MultiMesh
var worst_star := 0.0
var caption: Label
var stage: SubViewport
var shapes: Array = []
var floors := 0
var floor_geom := -1
var touches: Array[MeshInstance3D] = []
var touching := 0
var deepest_mm := 0.0
var touched_frames := 0
var worst_mm := 0.0


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


func _star() -> MultiMesh:
	var ball := SphereMesh.new()
	ball.radius = 0.008
	ball.height = 0.016
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.no_depth_test = true
	mat.render_priority = 9
	ball.material = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = ball
	mm.instance_count = 21 * 6
	for i in 21 * 6:
		mm.set_instance_color(i, AXIS_COLORS[i % 6])
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	stage.add_child(mi)
	return mm


func _xray(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = color
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.no_depth_test = true
	return mat


func _axis(row: PackedFloat64Array) -> Vector3:
	return Vector3(row[11], row[12], row[10])


## The colliding geoms of the physics model itself: its floor plane and what may touch it.
func _colliders() -> void:
	var table: PackedFloat64Array = lib.sender.physics.vmcall("mjc_geom_table")
	for i in table.size() / 13:
		var row: PackedFloat64Array = table.slice(i * 13, i * 13 + 13)
		if row[2] == 0.0 and row[3] == 0.0:
			continue
		var kind := int(row[1])
		var mi := MeshInstance3D.new()
		if kind == 0:
			var im := ImmediateMesh.new()
			im.surface_begin(Mesh.PRIMITIVE_LINES, _xray(Color(0.6, 0.65, 0.7, 0.35)))
			for k in range(-10, 11):
				im.surface_add_vertex(Vector3(k, 0, -10))
				im.surface_add_vertex(Vector3(k, 0, 10))
				im.surface_add_vertex(Vector3(-10, 0, k))
				im.surface_add_vertex(Vector3(10, 0, k))
			im.surface_end()
			var quad := PlaneMesh.new()
			quad.size = Vector2(20, 20)
			quad.material = _xray(Color(0.5, 0.6, 0.8, 0.07))
			var sheet := MeshInstance3D.new()
			sheet.mesh = quad
			mi.add_child(sheet)
			mi.mesh = im
			floors += 1
			floor_geom = i
		elif kind == 2:
			var ball := SphereMesh.new()
			ball.radius = row[4]
			ball.height = 2.0 * row[4]
			ball.material = _xray(Color(0.3, 1.0, 0.5, 0.28))
			mi.mesh = ball
		elif kind == 3 or kind == 5:
			var cap: PrimitiveMesh = CapsuleMesh.new() if kind == 3 else CylinderMesh.new()
			if kind == 3:
				cap.radius = row[4]
				cap.height = 2.0 * (row[5] + row[4])
			else:
				cap.top_radius = row[4]
				cap.bottom_radius = row[4]
				cap.height = 2.0 * row[5]
			cap.material = _xray(Color(0.3, 1.0, 0.5, 0.28))
			mi.mesh = cap
		elif kind == 6:
			var box := BoxMesh.new()
			box.size = Vector3(2.0 * row[5], 2.0 * row[6], 2.0 * row[4])
			box.material = _xray(Color(0.3, 1.0, 0.5, 0.28))
			mi.mesh = box
		else:
			var mark := SphereMesh.new()
			mark.radius = 0.012
			mark.height = 0.024
			mark.material = _xray(Color(0.3, 1.0, 0.5, 0.8))
			mi.mesh = mark
		stage.add_child(mi)
		shapes.append([i, mi])
	var spot := SphereMesh.new()
	spot.radius = 0.014
	spot.height = 0.028
	spot.material = _xray(Color(1.0, 0.95, 0.2, 1.0))
	for k in 24:
		var t := MeshInstance3D.new()
		t.mesh = spot
		t.visible = false
		stage.add_child(t)
		touches.append(t)
	_place_colliders()


## Where the physics engine itself finds the body touching its floor in this pose.
func _contacts() -> void:
	var c: PackedFloat64Array = lib.sender.physics.vmcall("mjc_contacts")
	touching = 0
	deepest_mm = 0.0
	for i in c.size() / 6:
		if int(c[i * 6]) != floor_geom and int(c[i * 6 + 1]) != floor_geom:
			continue
		if touching < touches.size():
			touches[touching].position = Vector3(c[i * 6 + 3], c[i * 6 + 4], c[i * 6 + 2])
			touches[touching].visible = true
		touching += 1
		deepest_mm = minf(deepest_mm, c[i * 6 + 5] * 1000.0)
	for k in range(mini(touching, touches.size()), touches.size()):
		touches[k].visible = false
	if touching > 0:
		touched_frames += 1


func _place_colliders() -> void:
	var table: PackedFloat64Array = lib.sender.physics.vmcall("mjc_geom_table")
	for s in shapes:
		var row: PackedFloat64Array = table.slice(s[0] * 13, s[0] * 13 + 13)
		var up := _axis(row).normalized()
		var basis: Basis = Basis(Quaternion(Vector3.UP, up)) if absf(up.dot(Vector3.UP)) < 0.999999 else Basis.IDENTITY
		s[1].transform = Transform3D(basis, Vector3(row[8], row[9], row[7]))


func _dots(color: Color) -> Array[MeshInstance3D]:
	var ball := SphereMesh.new()
	ball.radius = 0.018
	ball.height = 0.036
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.no_depth_test = true
	mat.render_priority = 10
	ball.material = mat
	var out: Array[MeshInstance3D] = []
	for p in 21:
		var d := MeshInstance3D.new()
		d.mesh = ball
		stage.add_child(d)
		out.append(d)
	return out


func _initialize() -> void:
	for x in OS.get_cmdline_user_args():
		if x.begins_with("--control="):
			control = x.trim_prefix("--control=")
		else:
			args.append(x)
	if args.size() != 4:
		_end("RESULT: ERROR give the presence directory, the physics guest, the avatar and the clips directory", 2)
		return
	lib = load(String(args[0]).path_join("tests/body_lib.gd")).new()
	if not lib.build(args[0], args[1], args[2], control):
		_end("RESULT: ERROR " + lib.error, 2)
		return
	var size: Vector2i = DisplayServer.window_get_size()
	stage = SubViewport.new()
	stage.own_world_3d = true
	stage.size = Vector2i(size.x, size.y - STRIP)
	stage.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var frame_box := SubViewportContainer.new()
	frame_box.add_child(stage)
	root.add_child(frame_box)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.13, 0.14, 0.16)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 0.3
	var we := WorldEnvironment.new()
	we.environment = env
	stage.add_child(we)
	for l in [[Vector3(-50, 35, 0), 0.7], [Vector3(55, -145, 0), 0.25]]:
		var light := DirectionalLight3D.new()
		light.rotation_degrees = l[0]
		light.light_energy = l[1]
		stage.add_child(light)
	_colliders()
	stage.add_child(lib.sender.scene)
	stage.add_child(lib.viewer.scene)
	lib.viewer.scene.position = APART
	cam = Camera3D.new()
	cam.fov = 40.0
	cam.near = 0.05
	cam.far = 60.0
	stage.add_child(cam)
	cam.make_current()
	sent = _dots(Color(1.0, 0.35, 0.1))
	drawn = _dots(Color(0.2, 0.85, 1.0))
	sent_star = _star()
	drawn_star = _star()
	var layer := CanvasLayer.new()
	caption = Label.new()
	caption.position = Vector2(16, size.y - STRIP + 4)
	caption.size = Vector2(size.x - 32, STRIP - 8)
	caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	caption.clip_text = false
	caption.add_theme_font_size_override("font_size", 13)
	layer.add_child(caption)
	root.add_child(layer)
	await process_frame
	clip = 0
	if not lib.begin(String(args[3]).path_join(CLIPS[0] + ".f64")):
		_end("RESULT: ERROR " + lib.error, 2)


func _process(_delta: float) -> bool:
	if clip < 0:
		return false
	var live := false
	for k in 2:
		if tick < lib.ticks:
			live = lib.step(tick)
			tick += 1
	if tick >= lib.ticks:
		clip += 1
		tick = 0
		if clip >= CLIPS.size():
			print("VIDEO control=%s frames=%d fps=%d clips=%s views=%d worst_mm=%.2f worst_star_mm=%.2f refused=%d colliders=%d floor_geom=%d frames_touching_floor=%d" % [control if control != "" else "real", frame, FPS, "+".join(CLIPS), VIEWS, worst_mm, worst_star, lib.refused, shapes.size(), floor_geom, touched_frames])
			print("RESULT: PASS recorded")
			quit(0)
			return true
		if not lib.begin(String(args[3]).path_join(CLIPS[clip] + ".f64")):
			print("RESULT: ERROR " + lib.error)
			quit(2)
			return true
		return false
	_place_colliders()
	_contacts()
	var now_mm := 0.0
	var now_star := 0.0
	for p in 21:
		sent[p].position = _at(lib.now, lib.ids[p])
		drawn[p].position = _at(lib.seen, lib.ids[p]) + APART
		var sb := _turn(lib.now, lib.ids[p])
		var db := _turn(lib.seen, lib.ids[p])
		var tb := _turn(lib.then, lib.ids[p]) if live else db
		for k in 6:
			sent_star.set_instance_transform(p * 6 + k, Transform3D(Basis.IDENTITY, sent[p].position + sb * AXES[k] * ARM))
			drawn_star.set_instance_transform(p * 6 + k, Transform3D(Basis.IDENTITY, drawn[p].position + db * AXES[k] * ARM))
			if live:
				now_star = maxf(now_star, ((_at(lib.seen, lib.ids[p]) + db * AXES[k] * ARM) - (_at(lib.then, lib.ids[p]) + tb * AXES[k] * ARM)).length() * 1000.0)
		if live:
			now_mm = maxf(now_mm, (_at(lib.seen, lib.ids[p]) - _at(lib.then, lib.ids[p])).length() * 1000.0)
	worst_mm = maxf(worst_mm, now_mm)
	worst_star = maxf(worst_star, now_star)
	var view: int = mini(tick * VIEWS / lib.ticks, VIEWS - 1)
	var hip: Vector3 = _at(lib.now, lib.ids[3])
	var focus := Vector3(hip.x, FOCUS_HEIGHT, hip.z) + APART * 0.5
	var dir := _view_dir(view)
	var from := focus + dir * RADIUS
	cam.transform = Transform3D(Basis.looking_at(focus - from, Vector3.UP if absf(dir.y) < 0.9 else Vector3(0, 0, 1)), from)
	caption.text = "%s   %s   view %d of %d      largest distance: origins %.1f mm, star points %.1f mm      frames refused %d\nleft, orange: the sender now.   right, blue: the viewer's copy, 12 ticks behind.   each part is a rotation star: its origin and the ends of its axes 5 cm out (X red, Y green, Z blue).\nthe floor and the green shapes are the physics model's own %d colliding geoms, drawn see-through.\nyellow: where the physics engine finds the body touching that floor now: %d contacts, deepest %.1f mm" % [("planted: " + control) if control != "" else "real", CLIPS[clip], view + 1, VIEWS, now_mm, now_star, lib.refused, shapes.size(), touching, deepest_mm]
	frame += 1
	return false
