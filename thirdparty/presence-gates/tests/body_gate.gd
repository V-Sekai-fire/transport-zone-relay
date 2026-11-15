extends SceneTree


const TICK_USEC := 15625.0
const ARM := 0.05
const AXES := [Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN, Vector3.BACK, Vector3.FORWARD]


func _end(line: String, code: int) -> void:
	print(line)
	quit(code)


func _quat(t: PackedFloat64Array, o: int) -> Quaternion:
	return Quaternion(t[o + 4], t[o + 5], t[o + 6], t[o + 3])


func _initialize() -> void:
	var control := ""
	var clips := ["walk", "idle"]
	var plain: Array = []
	var beat := -1.0
	for x in OS.get_cmdline_user_args():
		if x.begins_with("--control="):
			control = x.trim_prefix("--control=")
		elif x.begins_with("--line="):
			beat = x.trim_prefix("--line=").to_float()
		elif x.begins_with("--clips="):
			clips = Array(x.trim_prefix("--clips=").split(","))
		else:
			plain.append(x)
	if plain.size() != 4:
		_end("RESULT: ERROR give the presence directory, the physics guest, the avatar and the clips directory", 2)
		return
	var Lib = load(String(plain[0]).path_join("tests/body_lib.gd"))
	if control != "" and not Lib.CONTROLS.has(control):
		_end("RESULT: ERROR no control named %s" % control, 2)
		return
	var lib = Lib.new()
	if not lib.build(plain[0], plain[1], plain[2], control):
		_end("RESULT: ERROR " + lib.error, 2)
		return
	root.add_child(lib.sender.scene)
	root.add_child(lib.viewer.scene)
	await process_frame

	var worst_mm := 0.0
	var sum_mm := 0.0
	var worst_turn := 0.0
	var worst_star := 0.0
	var sum_star := 0.0
	var compared := 0
	var ticks_done := 0
	for clip in clips:
		if not lib.begin(String(plain[3]).path_join(clip + ".f64")):
			_end("RESULT: ERROR " + lib.error, 2)
			return
		for t in lib.ticks:
			ticks_done += 1
			if not lib.step(t):
				continue
			for p in 21:
				var o: int = lib.ids[p] * 7
				var mm: float = Vector3(lib.seen[o] - lib.then[o], lib.seen[o + 1] - lib.then[o + 1], lib.seen[o + 2] - lib.then[o + 2]).length() * 1000.0
				worst_mm = maxf(worst_mm, mm)
				sum_mm += mm
				worst_turn = maxf(worst_turn, _quat(lib.seen, o).angle_to(_quat(lib.then, o)))
				var d := Vector3(lib.seen[o] - lib.then[o], lib.seen[o + 1] - lib.then[o + 1], lib.seen[o + 2] - lib.then[o + 2])
				var bs := Basis(_quat(lib.seen, o))
				var bt := Basis(_quat(lib.then, o))
				for axis in AXES:
					var star: float = (d + (bs * axis - bt * axis) * ARM).length() * 1000.0
					worst_star = maxf(worst_star, star)
					sum_star += star
				compared += 1
	var drawn: int = lib.has.count(true)
	var refused: int = lib.refused
	var share: float = lib.usec / float(maxi(ticks_done, 1)) / TICK_USEC
	print("BODY control=%s clips=%s ticks=%d parts_drawn=%d frames_taken=%d frames_refused=%d" % [control if control != "" else "none", ",".join(clips), ticks_done, drawn, lib.taken, refused])
	print("LEDGER parts_drawn=%d err_max_mm=%.3f err_mean_mm=%.3f turn_max_mrad=%.2f star_max_mm=%.3f star_mean_mm=%.3f honest_refused=%d tick_share=%.3f" % [drawn, worst_mm, sum_mm / maxi(compared, 1), worst_turn * 1000.0, worst_star, sum_star / maxi(compared * 6, 1), refused if control == "" else 0, share])
	if compared == 0 or drawn != 21:
		_end("RESULT: FAIL %d of 21 parts were drawn" % drawn, 1)
		return
	if control == "":
		if refused > 0:
			_end("RESULT: FAIL %d honest frames were refused" % refused, 1)
		else:
			_end("RESULT: PASS", 0)
		return
	if beat <= 0.0:
		_end("RESULT: ERROR a control needs --line=<the largest error of the run without it>", 2)
	elif control == "flip" and refused == 0:
		_end("RESULT: ERROR the flipped frames were taken", 2)
	elif worst_mm > 2.0 * beat:
		_end("RESULT: FAIL the planted %s made the largest error %.1f mm, from %.1f" % [control, worst_mm, beat], 1)
	else:
		_end("RESULT: ERROR the planted %s did not make the line worse" % control, 2)
