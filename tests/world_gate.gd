extends SceneTree


const TICK_USEC := 15625.0
const ARM := 0.05
const AXES := [Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN, Vector3.BACK, Vector3.FORWARD]
const Lib := preload("res://tests/world_lib.gd")


func _end(line: String, code: int) -> void:
	print(line)
	quit(code)


func _quat(t: PackedFloat64Array, o: int) -> Quaternion:
	return Quaternion(t[o + 4], t[o + 5], t[o + 6], t[o + 3])


func _initialize() -> void:
	var control := ""
	var plain: Array = []
	for x in OS.get_cmdline_user_args():
		if x.begins_with("--control="):
			control = x.trim_prefix("--control=")
		else:
			plain.append(x)
	if plain.size() != 2 or (control != "" and not Lib.CONTROLS.has(control)):
		_end("RESULT: ERROR give the physics guest and the clips directory, and a control that exists", 2)
		return
	var lib := Lib.new()
	if not lib.build(ProjectSettings.globalize_path("res://"), plain[0], plain[1], control):
		_end("RESULT: ERROR " + lib.error, 2)
		return
	var worst := 0.0
	var worst_star := 0.0
	var sum: Array = []
	var count: Array = []
	for v in 4:
		sum.append([0.0, 0.0, 0.0])
		count.append([0, 0, 0])
	for t in lib.ticks:
		lib.step(t)
		if not lib.live:
			continue
		for v in 4:
			for o in 3:
				if lib.has[v][o] < 2:
					continue
				var s: int = o + 1 if o >= v else o
				var was: PackedFloat64Array = lib.then(s)
				var seen: PackedFloat64Array = lib.seen[v][o]
				for p in 21:
					var b: int = lib.ids[p] * 7
					var d := Vector3(seen[b] - was[b], seen[b + 1] - was[b + 1], seen[b + 2] - was[b + 2])
					worst = maxf(worst, d.length() * 1000.0)
					sum[v][o] += d.length() * 1000.0
					count[v][o] += 1
					var bs := Basis(_quat(seen, b))
					var bt := Basis(_quat(was, b))
					for axis in AXES:
						worst_star = maxf(worst_star, (d + (bs * axis - bt * axis) * ARM).length() * 1000.0)
	var pairs := 0
	var total := 0.0
	var n := 0
	for v in 4:
		for o in 3:
			total += sum[v][o]
			n += count[v][o]
			if count[v][o] > 0 and sum[v][o] / count[v][o] < 5.0:
				pairs += 1
	var keys: Array = lib.tally.keys()
	keys.sort()
	for key in keys:
		print("NAMED %s: %d sends" % [key, lib.tally[key]])
	var named: String = lib.named()
	print("WORLD control=%s tier=%s ticks=%d sends=%d judged=%d valid=%d" % [control if control != "" else "none", lib.tier(), lib.ticks, lib.sends, lib.judged, lib.valid])
	print("LEDGER pairs_seeing=%d err_max_mm=%.3f err_mean_mm=%.3f star_max_mm=%.3f named=%s wire_share_of_tick_a_world=%.3f physics_share_a_world=%.3f" % [pairs, worst, total / maxi(n, 1), worst_star, named, lib.usec / float(lib.ticks) / 4.0 / TICK_USEC, lib.physics_usec / float(lib.ticks) / 4.0 / TICK_USEC])
	if control == "":
		if pairs != 12 or named != "nobody" or lib.valid != lib.judged:
			_end("RESULT: FAIL %d of 12 pairs see each other, named=%s, %d of %d verdicts valid" % [pairs, named, lib.valid, lib.judged], 1)
		else:
			_end("RESULT: PASS", 0)
		return
	if named == Lib.CONTROLS[control]:
		_end("RESULT: FAIL named=%s, the planted party" % named, 1)
	else:
		_end("RESULT: ERROR the control %s named %s and %s was planted" % [control, named, Lib.CONTROLS[control]], 2)
