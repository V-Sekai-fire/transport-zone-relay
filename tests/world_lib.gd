extends RefCounted


const SLOTS := 4
const SEND_TICKS := 6
const PHASE := [0, 1, 3, 4]
const DELAY := 18
const PEOPLE := [7, 9, 12, 30]
const TICK_HZ := 64.0
const PLANT_AT := 300
const GONE_TICKS := 320
const ORIGIN := [4000000000000000000, -8000000000000000000, 6500000000000000000]
const CLIPS := ["walk", "idle", "walk_back", "run"]
const STAND := [Vector2(0, 0), Vector2(0, 1.6), Vector2(0, -1.6), Vector2(0, 3.2)]
const CODES := {0: "valid", 1: "incomplete", 2: "sender", 3: "sender-or-zone", 4: "zone", 5: "me"}
const STALE_OLD := "\tgot_ok[k] = false\n\tgot[k] = frame\n"
const STALE_NEW := "\tgot_ok[k] = false\n\tif k == 0 and got[0].size() == FRAME_BYTES and frame.decode_u32(OFF_HLC) >> 8 >= 300:\n\t\tframe = got[0]\n\tgot[k] = frame\n"
const CONTROLS := {"alter": "forged:1", "halves": "sender:3", "stale": "viewer:2", "silent": "silent:2"}

var error := ""
var here := ""
var parts: Object
var control := ""
var usec := 0
var physics: Object
var engines: Array = []
var poses: Array = [null, null, null, null]
var elf_bytes := PackedByteArray()
var loaded: Array = [false, false, false, false]
var bodies := PackedStringArray()
var zero := PackedFloat64Array()
var ids := PackedInt32Array()
var packets: Object
var router: Object
var curves: Array = []
var observers: Array = []
var origin := PackedInt64Array(ORIGIN)
var blank := PackedByteArray()
var clips: Array = []
var ticks := 960
var history: Array = []
var pending: Array = []
var turns: Array = []
var has: Array = []
var fresh: Array = []
var now: Array = []
var seen: Array = []
var live := false
var tally := {}
var judged := 0
var valid := 0
var sends := 0
var physics_usec := 0


func _guest(file: String, old: String, new: String) -> Object:
	var src: String = parts.source(here, file)
	if old != "":
		if src.count(old) != 1:
			error = "a control was not planted in %s" % file
			return null
		src = src.replace(old, new)
	var script: Object = ClassDB.instantiate("SafeGDScript")
	script.set_source_code(src)
	if script.get_compile_error() != "":
		error = "%s does not compile: %s" % [file, script.get_compile_error()]
		return null
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


func build(presence: String, elf: String, clip_dir: String, with_control: String) -> bool:
	here = presence
	parts = load(here.path_join("tests/parts.gd"))
	control = with_control
	if OS.get_environment("BINTR") != "":
		ProjectSettings.set_setting("sandbox/binary_translation/enabled", true)
		ProjectSettings.set_setting("sandbox/binary_translation/cache_dir", OS.get_environment("BINTR"))
	elf_bytes = FileAccess.get_file_as_bytes(elf)
	for s in SLOTS:
		var e: Object = ClassDB.instantiate("Sandbox")
		e.set_memory_max(1024)
		e.set_allocations_max(1 << 22)
		e.set_unboxed_arguments(true)
		e.set("execution_timeout", 4000000)
		engines.append(e)
	WorkerThreadPool.wait_for_group_task_completion(WorkerThreadPool.add_group_task(_load, SLOTS))
	physics = engines[0]
	if loaded.has(false):
		error = "the model did not build"
		return false
	bodies = physics.vmcall("mjc_names", 1)
	physics.vmcall("mjc_forward")
	zero = physics.vmcall("mjc_bodies")
	var driven := {}
	for line in FileAccess.get_file_as_string(parts.dir(here, "follow").path_join("data/drive.tsv")).split("\n", false).slice(1):
		driven[line.split("\t")[1]] = true
	var names: Array = []
	for line in FileAccess.get_file_as_string(parts.dir(here, "packets").path_join("data/parts.tsv")).split("\n", false).slice(1):
		names.append(line.split("\t")[1])
	if names.size() != 21 or driven.size() != 21:
		error = "the part table is not 21 bodies"
		return false
	for n in names:
		if not driven.has(n) or bodies.find(n) < 0:
			error = "the part %s does not drive the avatar" % n
			return false
		ids.append(bodies.find(n))
	packets = _guest("packets", "", "")
	router = _guest("router", "", "")
	if packets == null or router == null:
		return false
	for s in SLOTS:
		var planted: bool = control == "stale" and s == 2
		var o := _guest("observer", STALE_OLD if planted else "", STALE_NEW if planted else "")
		var c := _guest("curve", "", "")
		var k := _keys(s)
		if o == null or c == null or k.size() != 3:
			error = error if error != "" else "no fixture keys"
			return false
		o.vmcallv("setup", s, PEOPLE[0], PEOPLE[1], PEOPLE[2], PEOPLE[3])
		o.vmcallv("keys", k[0], k[1], k[2])
		c.vmcallv("reset", 63, float(DELAY))
		observers.append(o)
		curves.append(c)
		var q := FileAccess.get_file_as_bytes(clip_dir.path_join(CLIPS[s] + ".f64")).to_float64_array()
		if q.size() < 200 * 86:
			error = "no clip %s" % CLIPS[s]
			return false
		clips.append(q)
		history.append([])
		pending.append([{}, {}, {}])
		turns.append([[], [], []])
		has.append([0, 0, 0])
		fresh.append([0, 0, 0])
		now.append(PackedFloat64Array())
		seen.append([PackedFloat64Array(), PackedFloat64Array(), PackedFloat64Array()])
	router.vmcallv("reset")
	for s in SLOTS:
		router.vmcallv("join", PEOPLE[s])
	blank.resize(300)
	return true


## Each person's physics is a guest of its own, so the four step on four threads.
func _load(s: int) -> void:
	engines[s].load_buffer(elf_bytes)
	loaded[s] = engines[s].vmcall("mjc_load_human", -1) == true


func _forward(s: int) -> void:
	engines[s].vmcall("mjc_set_qpos", poses[s])
	engines[s].vmcall("mjc_forward")
	now[s] = engines[s].vmcall("mjc_bodies")


func _qpos(s: int, t: float) -> PackedFloat64Array:
	var clip: PackedFloat64Array = clips[s]
	var frames: int = clip.size() / 86
	var f: float = pingpong(t * 100.0, frames - 1.0)
	var i: int = mini(int(f), frames - 2)
	var w: float = f - i
	var out := PackedFloat64Array()
	out.resize(86)
	for k in 86:
		out[k] = lerpf(clip[i * 86 + k], clip[(i + 1) * 86 + k], w)
	var n := sqrt(out[3] * out[3] + out[4] * out[4] + out[5] * out[5] + out[6] * out[6])
	for k in range(3, 7):
		out[k] /= n
	out[0] += STAND[s].x
	out[1] += STAND[s].y
	return out


func _other(slot: int, viewer: int) -> int:
	return slot - 1 if slot > viewer else slot


func _frames(s: int, t: int) -> PackedByteArray:
	var two := PackedByteArray()
	var h: Array = history[s]
	var at: PackedFloat64Array = h[h.size() - 1]
	var was: PackedFloat64Array = h[h.size() - 2]
	var ago: PackedFloat64Array = h[h.size() - 3]
	for p in 21:
		var o: int = ids[p] * 7
		var motion := PackedFloat64Array()
		for k in 3:
			motion.append(at[o + k] - was[o + k])
		for k in 3:
			motion.append(at[o + k] - 2.0 * was[o + k] + ago[o + k])
		two.append_array(_call(packets, ["body", PEOPLE[s], p, t, origin, at.slice(o, o + 7), motion]))
	two.append_array(blank)
	return two


func _send(s: int, t: int) -> void:
	var n: int = t / SEND_TICKS
	var two := _frames(s, t)
	if control == "halves" and s == 3 and t >= PLANT_AT and history[s].size() > SEND_TICKS + 3:
		var keep: Array = history[s]
		history[s] = keep.slice(0, keep.size() - SEND_TICKS)
		var old := _frames(s, t - SEND_TICKS)
		history[s] = keep
		two = two.slice(0, 1200) + old.slice(1200)
	var sealed: PackedByteArray = _call(observers[s], ["seal", two.slice(0, 1200), two.slice(1200), n])
	_call(router, ["put", s, 0, sealed.slice(0, 1200)])
	_call(router, ["put", s, 1, sealed.slice(1200)])
	for v in SLOTS:
		if v == s:
			continue
		var o: int = _other(s, v)
		var points: Array = []
		for half in 2:
			var f: PackedByteArray = _call(router, ["frame", v, o * 2 + half])
			if control == "alter" and s == 1 and half == 0 and t >= PLANT_AT:
				f[777] = f[777] ^ 1
			if _call(observers[v], ["take", o * 2 + half, f]) != true:
				continue
			for i in (12 if half == 0 else 9):
				points.append(_call(packets, ["placed", f.slice(i * 100, i * 100 + 100), origin]))
		if points.size() == 21:
			pending[v][o][n] = points


func _close(t: int) -> void:
	var n: int = t / SEND_TICKS
	sends += 1
	for v in SLOTS:
		var verdicts: PackedInt32Array = _call(observers[v], ["close", n])
		for o in 3:
			var sender: int = o + 1 if o >= v else o
			if sends >= 3:
				judged += 1
				if verdicts[o] == 0:
					valid += 1
				else:
					var key := "%s about %d by %d" % [CODES.get(verdicts[o], ("viewer:%d" % (verdicts[o] - 10)) if verdicts[o] < 20 else ("silent:%d" % (verdicts[o] - 20))), sender, v]
					tally[key] = tally.get(key, 0) + 1
			var held: Dictionary = pending[v][o]
			if (verdicts[o] == 0 or verdicts[o] >= 10) and held.has(n - 1):
				var turn: Array = []
				turn.resize(21)
				var at_tick := 0
				for pt in held[n - 1]:
					var p: int = int(pt[0]) - 2000000 - PEOPLE[sender] * 21
					_call(curves[v], ["put", o * 21 + p, pt[1], pt[2], pt[3], pt[4], pt[9], pt[10], pt[11]])
					turn[p] = Quaternion(pt[6], pt[7], pt[8], pt[5])
					at_tick = int(pt[1])
				turns[v][o].append([at_tick, turn])
				if turns[v][o].size() > 5:
					turns[v][o].pop_front()
				has[v][o] += 1
				fresh[v][o] = at_tick
			for key in held.keys():
				if key < n:
					held.erase(key)


## One tick of all four worlds. `live` is true once every viewer has something to compare.
func step(t: int) -> void:
	var t0 := Time.get_ticks_usec()
	for s in SLOTS:
		poses[s] = _qpos(s, t / TICK_HZ)
	WorkerThreadPool.wait_for_group_task_completion(WorkerThreadPool.add_group_task(_forward, SLOTS))
	for s in SLOTS:
		history[s].append(now[s])
		if history[s].size() > DELAY + SEND_TICKS + 4:
			history[s].pop_front()
	physics_usec += Time.get_ticks_usec() - t0
	for s in SLOTS:
		if control == "silent" and s == 2 and t >= PLANT_AT:
			continue
		if t % SEND_TICKS == PHASE[s] and history[s].size() >= 3:
			_send(s, t)
	_call(router, ["tick"])
	if t % SEND_TICKS == SEND_TICKS - 1:
		_close(t)
	var view: float = t - DELAY
	live = t >= 8 * SEND_TICKS + DELAY
	for v in SLOTS:
		_call(curves[v], ["advance", view])
		for o in 3:
			var out := PackedFloat64Array()
			out.resize(bodies.size() * 7)
			var list: Array = turns[v][o]
			var lo: int = 0
			for i in list.size():
				if list[i][0] <= view:
					lo = i
			var hi: int = mini(lo + 1, list.size() - 1)
			for p in 21:
				var d: PackedFloat64Array = _call(curves[v], ["drawn", o * 21 + p])
				var b: int = ids[p] * 7
				var r := Quaternion.IDENTITY
				if not list.is_empty():
					var w: float = 0.0
					if hi > lo:
						w = clampf((view - list[lo][0]) / float(list[hi][0] - list[lo][0]), 0.0, 1.0)
					r = list[lo][1][p].slerp(list[hi][1][p], w)
				out[b] = d[0]
				out[b + 1] = d[1]
				out[b + 2] = d[2]
				out[b + 3] = r.w
				out[b + 4] = r.x
				out[b + 5] = r.y
				out[b + 6] = r.z
			seen[v][o] = out


func then(s: int) -> PackedFloat64Array:
	var h: Array = history[s]
	return h[h.size() - 1 - DELAY] if h.size() > DELAY else PackedFloat64Array()


func named() -> String:
	var forged := [0, 0, 0, 0]
	var refused := 0
	for v in SLOTS:
		refused += observers[v].vmcallv("refused_count")
		var counts: PackedInt32Array = observers[v].vmcallv("forged_counts")
		for o in 3:
			forged[o + 1 if o >= v else o] += counts[o]
	if refused > 0:
		return "refused"
	if forged.max() > 0:
		return "forged:%d" % forged.find(forged.max())
	var out := "nobody"
	var quiet := {}
	for key in tally:
		if key.begins_with("silent:"):
			quiet[key.split(" ")[0]] = quiet.get(key.split(" ")[0], 0) + 1
	for q in quiet:
		if quiet[q] >= 2:
			return q
	for sender in SLOTS:
		var count := {"sender": 0, "sender-or-zone": 0, "zone": 0}
		var viewers := {}
		for key in tally:
			var w: PackedStringArray = key.split(" ")
			if w[2].to_int() == sender and count.has(w[0]):
				count[w[0]] += 1
			if w[0].begins_with("viewer:"):
				viewers[w[0]] = viewers.get(w[0], 0) + 1
		if count["zone"] >= 3:
			out = "zone:%d" % sender
		elif count["sender-or-zone"] >= 3:
			out = "sender-or-zone:%d" % sender
		elif count["sender"] >= 3:
			out = "sender:%d" % sender
		for v in viewers:
			if viewers[v] >= 2 and out == "nobody":
				out = v
	return out


## False once nothing of that person has been agreed on for 5 seconds.
func present(v: int, o: int, t: int) -> bool:
	return has[v][o] >= 2 and t - DELAY - fresh[v][o] <= GONE_TICKS


func tier() -> String:
	return "translated" if engines[0].is_binary_translated() else "interpreted"
