extends RefCounted


const SEND_TICKS := 6
const DELAY := 12
const PERSON := 7
const VIEWER := 9
const TICK_HZ := 64.0
const PLANT_AT := 300
const ORIGIN := [4000000000000000000, -8000000000000000000, 6500000000000000000]
const AXES_OLD := "\t\torigin[0] + int(round(-place[1] * UM)), origin[1] + int(round(place[2] * UM)), origin[2] + int(round(-place[0] * UM)),\n"
const AXES_NEW := "\t\torigin[0] + int(round(place[0] * UM)), origin[1] + int(round(place[2] * UM)), origin[2] + int(round(-place[1] * UM)),\n"
const CONTROLS := ["swap", "axes", "flip"]

var error := ""
var here := ""
var parts: Object
var control := ""
var usec := 0
var sender: Object
var viewer: Object
var ids := PackedInt32Array()
var seen_ids := PackedInt32Array()
var packets: Object
var reader: Object
var router: Object
var curve: Object
var obs_s: Object
var obs_v: Object
var origin := PackedInt64Array(ORIGIN)
var blank := PackedByteArray()
var clip := PackedFloat64Array()
var frames := 0
var ticks := 0
var history: Array = []
var turns: Array = []
var has: Array = []
var now := PackedFloat64Array()
var seen := PackedFloat64Array()
var then := PackedFloat64Array()
var refused := 0
var taken := 0


func _guest(file: String) -> Object:
	var src: String = parts.source(here, file)
	var script: Object = ClassDB.instantiate("SafeGDScript")
	script.set_source_code(src)
	if script.get_compile_error() != "":
		error = "%s does not compile: %s" % [file, script.get_compile_error()]
		return null
	var sb: Object = ClassDB.instantiate("Sandbox")
	sb.load_buffer(script.get_content())
	return sb


func _planted_packets() -> Object:
	var src: String = parts.source(here, "packets")
	if src.count(AXES_OLD) != 1:
		error = "the axes control was not planted"
		return null
	var script: Object = ClassDB.instantiate("SafeGDScript")
	script.set_source_code(src.replace(AXES_OLD, AXES_NEW))
	var sb: Object = ClassDB.instantiate("Sandbox")
	sb.load_buffer(script.get_content())
	return sb


func _call(sb: Object, args: Array) -> Variant:
	var t0 := Time.get_ticks_usec()
	var out = sb.callv("vmcallv", args)
	usec += Time.get_ticks_usec() - t0
	return out


func _keys(slot: int) -> Array:
	var table := FileAccess.get_file_as_bytes(here.path_join("testdata/zone-fixture/keys.%d.table" % slot))
	var out: Array = []
	if table.size() == 100 and table[0] == 3:
		for i in 3:
			out.append(table.slice(2 + i * 33, 34 + i * 33))
	return out


func build(presence: String, elf: String, glb: String, with_control: String) -> bool:
	here = presence
	parts = load(here.path_join("tests/parts.gd"))
	control = with_control
	var Rig = load("res://tests/follow_rig.gd")
	sender = Rig.new()
	viewer = Rig.new()
	if not sender.build(elf, glb, "") or not viewer.build(elf, glb, ""):
		error = sender.error + viewer.error
		return false
	var names: Array = []
	for line in FileAccess.get_file_as_string(parts.dir(here, "packets").path_join("data/parts.tsv")).split("\n", false).slice(1):
		names.append(line.split("\t")[1])
	var sorted_names := names.duplicate()
	sorted_names.sort()
	var driven := Array(sender.parts)
	driven.sort()
	if names.size() != 21 or sorted_names != driven:
		error = "the part table is not the 21 bodies that drive the avatar"
		return false
	for n in names:
		ids.append(sender.bodies.find(n))
	seen_ids = ids.duplicate()
	if control == "swap":
		seen_ids[1] = ids[2]
		seen_ids[2] = ids[1]
	packets = _planted_packets() if control == "axes" else _guest("packets")
	reader = _guest("packets")
	router = _guest("router")
	curve = _guest("curve")
	obs_s = _guest("observer")
	obs_v = _guest("observer")
	if packets == null or reader == null or router == null or curve == null or obs_s == null or obs_v == null:
		return false
	var ks := _keys(0)
	var kv := _keys(1)
	if ks.size() != 3 or kv.size() != 3:
		error = "no fixture keys"
		return false
	obs_s.vmcallv("setup", 0, PERSON, VIEWER, 12, 30)
	obs_v.vmcallv("setup", 1, PERSON, VIEWER, 12, 30)
	obs_s.vmcallv("keys", ks[0], ks[1], ks[2])
	obs_v.vmcallv("keys", kv[0], kv[1], kv[2])
	blank.resize(300)
	return true


func begin(path: String) -> bool:
	clip = FileAccess.get_file_as_bytes(path).to_float64_array()
	frames = clip.size() / 86
	if frames < 200:
		error = "no clip at %s" % path
		return false
	ticks = int(frames / 100.0 * TICK_HZ)
	router.vmcallv("reset")
	router.vmcallv("join", PERSON)
	router.vmcallv("join", VIEWER)
	curve.vmcallv("reset", 21, float(DELAY))
	history = []
	turns = []
	has = []
	has.resize(21)
	has.fill(false)
	return true


func _qpos(t: float) -> PackedFloat64Array:
	var f: float = clampf(t * 100.0, 0.0, frames - 1.0)
	var i: int = mini(int(f), frames - 2)
	var w: float = f - i
	var out := PackedFloat64Array()
	out.resize(86)
	for k in 86:
		out[k] = lerpf(clip[i * 86 + k], clip[(i + 1) * 86 + k], w)
	var n := sqrt(out[3] * out[3] + out[4] * out[4] + out[5] * out[5] + out[6] * out[6])
	for k in range(3, 7):
		out[k] /= n
	return out


func _send(t: int) -> void:
	var two := PackedByteArray()
	var was: PackedFloat64Array = history[history.size() - 2]
	var ago: PackedFloat64Array = history[history.size() - 3]
	for p in 21:
		var o: int = ids[p] * 7
		var motion := PackedFloat64Array()
		for k in 3:
			motion.append(now[o + k] - was[o + k])
		for k in 3:
			motion.append(now[o + k] - 2.0 * was[o + k] + ago[o + k])
		two.append_array(_call(packets, ["body", PERSON, p, t, origin, now.slice(o, o + 7), motion]))
	two.append_array(blank)
	var sealed: PackedByteArray = _call(obs_s, ["seal", two.slice(0, 1200), two.slice(1200), t / SEND_TICKS])
	_call(router, ["put", 0, 0, sealed.slice(0, 1200)])
	_call(router, ["put", 0, 1, sealed.slice(1200)])
	var fresh := true
	var turn: Array = []
	turn.resize(21)
	for half in 2:
		var f: PackedByteArray = _call(router, ["frame", 1, half])
		if control == "flip" and t >= PLANT_AT and half == 0:
			f[777] = f[777] ^ 1
		if _call(obs_v, ["take", half, f]) != true:
			refused += 1
			fresh = false
			continue
		taken += 1
		for i in (12 if half == 0 else 9):
			var pt: PackedFloat64Array = _call(reader, ["placed", f.slice(i * 100, i * 100 + 100), origin])
			var p: int = int(pt[0]) - 2000000 - PERSON * 21
			_call(curve, ["put", p, pt[1], pt[2], pt[3], pt[4], pt[9], pt[10], pt[11]])
			turn[p] = Quaternion(pt[6], pt[7], pt[8], pt[5])
			has[p] = true
	if fresh:
		turns.append([t, turn])
		if turns.size() > 4:
			turns.pop_front()


## One tick: the sender's body, a send when one is due, and what the viewer draws. False when
## the viewer has nothing to compare yet.
func step(t: int) -> bool:
	now = sender.bodies_at(_qpos(t / TICK_HZ))
	sender.pose(now)
	history.append(now)
	if history.size() > DELAY + 1:
		history.pop_front()
	if t % SEND_TICKS == 0 and history.size() >= 3:
		_send(t)
	_call(router, ["tick"])
	var view: float = t - DELAY
	_call(curve, ["advance", view])
	seen = PackedFloat64Array()
	seen.resize(sender.bodies.size() * 7)
	var lo: int = 0
	for i in turns.size():
		if turns[i][0] <= view:
			lo = i
	var hi: int = mini(lo + 1, turns.size() - 1)
	for p in 21:
		var d: PackedFloat64Array = _call(curve, ["drawn", p])
		var o: int = seen_ids[p] * 7
		var r := Quaternion.IDENTITY
		if not turns.is_empty():
			var w: float = 0.0
			if hi > lo:
				w = clampf((view - turns[lo][0]) / float(turns[hi][0] - turns[lo][0]), 0.0, 1.0)
			r = turns[lo][1][p].slerp(turns[hi][1][p], w)
		seen[o] = d[0]
		seen[o + 1] = d[1]
		seen[o + 2] = d[2]
		seen[o + 3] = r.w
		seen[o + 4] = r.x
		seen[o + 5] = r.y
		seen[o + 6] = r.z
	var t0 := Time.get_ticks_usec()
	var posed: bool = viewer.pose(seen)
	usec += Time.get_ticks_usec() - t0
	if t < 4 * SEND_TICKS + DELAY or not posed or history.size() <= DELAY:
		return false
	then = history[0]
	return true
