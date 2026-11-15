extends SceneTree
## One person as a program of its own, sending to the relay by UDP; see docs/clients.md.

const Parts := preload("res://tests/parts.gd")
const SEND_TICKS := 6
const PHASE := [0, 1, 3, 4]
const PEOPLE := [7, 9, 12, 30]
const TICK_USEC := 15625.0
const ORIGIN := [4000000000000000000, -8000000000000000000, 6500000000000000000]
const CLIPS := ["walk", "idle", "walk_back", "run"]
const STAND := [Vector2(0, 0), Vector2(0, 1.6), Vector2(0, -1.6), Vector2(0, 3.2)]

var here := ""
var slot := 0
var port := 0
var epoch := 0.0
var skew := 0.0
var relay_host := "127.0.0.1"
var lag := 0
var delay := 18
var physics: Object
var packets: Object
var observer: Object
var curve: Object
var ids := PackedInt32Array()
var clip := PackedFloat64Array()
var origin := PackedInt64Array(ORIGIN)
var udp := PacketPeerUDP.new()
var history: Array = []
var held: Array = []
var pending: Array = [{}, {}, {}]
var has := [0, 0, 0]
var judged := 0
var valid := 0
var late_frames := 0
var strange := 0
var skipped := 0
var tally := {}
var work_usec := 0
var worst_usec := 0


func _end(line: String, code: int) -> void:
	print(line)
	quit(code)


func _guest(file: String) -> Object:
	var script: Object = ClassDB.instantiate("SafeGDScript")
	script.set_source_code(Parts.source(here, file))
	if script.get_compile_error() != "":
		return null
	var sb: Object = ClassDB.instantiate("Sandbox")
	sb.load_buffer(script.get_content())
	return sb


func _tick() -> int:
	return int(floor((Time.get_unix_time_from_system() * 1e6 - epoch) * (1.0 + skew) / TICK_USEC))


func _qpos(t: float) -> PackedFloat64Array:
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
	out[0] += STAND[slot].x
	out[1] += STAND[slot].y
	return out


func _other(sender: int) -> int:
	return sender - 1 if sender > slot else sender


func _receive(closing: int) -> void:
	while udp.get_available_packet_count() > 0:
		var f: PackedByteArray = udp.get_packet()
		var half: int = udp.get_packet_port() - port
		if f.size() != 1200 or half < 0 or half > 1:
			strange += 1
			continue
		var person: int = (f.decode_u32(0) - 2000000 - half * 12) / 21
		var sender: int = PEOPLE.find(person)
		if sender < 0 or sender == slot:
			strange += 1
			continue
		var n: int = (f.decode_u32(40) >> 8) / SEND_TICKS
		if n < closing:
			late_frames += 1
		else:
			held.append([n, _other(sender), half, f])


func _take(closing: int) -> void:
	var rest: Array = []
	for h in held:
		if h[0] != closing:
			rest.append(h)
			continue
		if observer.vmcallv("take", h[1] * 2 + h[2], h[3]) != true:
			continue
		var points: Array = pending[h[1]].get(closing, [])
		for i in (12 if h[2] == 0 else 9):
			points.append(packets.vmcallv("placed", h[3].slice(i * 100, i * 100 + 100), origin))
		pending[h[1]][closing] = points
	held = rest


func _close(closing: int) -> void:
	var verdicts: PackedInt32Array = observer.vmcallv("close", closing)
	for o in 3:
		var sender: int = o + 1 if o >= slot else o
		judged += 1
		if verdicts[o] == 0:
			valid += 1
		else:
			var key := "%d about %d" % [verdicts[o], sender]
			tally[key] = tally.get(key, 0) + 1
		var book: Dictionary = pending[o]
		if (verdicts[o] == 0 or verdicts[o] >= 10) and book.has(closing - 1) and book[closing - 1].size() == 21:
			for pt in book[closing - 1]:
				var p: int = int(pt[0]) - 2000000 - PEOPLE[sender] * 21
				curve.vmcallv("put", o * 21 + p, pt[1], pt[2], pt[3], pt[4], pt[9], pt[10], pt[11])
			has[o] += 1
		for key in book.keys():
			if key < closing:
				book.erase(key)


func _send(t: int) -> void:
	var two := PackedByteArray()
	var at: PackedFloat64Array = history[history.size() - 1]
	var was: PackedFloat64Array = history[history.size() - 2]
	var ago: PackedFloat64Array = history[history.size() - 3]
	for p in 21:
		var o: int = ids[p] * 7
		var motion := PackedFloat64Array()
		for k in 3:
			motion.append(at[o + k] - was[o + k])
		for k in 3:
			motion.append(at[o + k] - 2.0 * was[o + k] + ago[o + k])
		two.append_array(packets.vmcallv("body", PEOPLE[slot], p, t, origin, at.slice(o, o + 7), motion))
	two.resize(2400)
	var sealed: PackedByteArray = observer.vmcallv("seal", two.slice(0, 1200), two.slice(1200), t / SEND_TICKS)
	for half in 2:
		udp.set_dest_address(relay_host, port + half)
		udp.put_packet(sealed.slice(half * 1200, half * 1200 + 1200))


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() < 7:
		_end("RESULT: ERROR give slot, port, epoch, seconds, physics guest, clips and output directory", 2)
		return
	here = ProjectSettings.globalize_path("res://")
	slot = a[0].to_int()
	port = a[1].to_int()
	epoch = a[2].to_float()
	var last_tick: int = int(a[3].to_float() * 64.0)
	for x in a.slice(7):
		if x.begins_with("--skew-ppm="):
			skew = x.trim_prefix("--skew-ppm=").to_float() / 1e6
	if OS.get_environment("BINTR") != "":
		ProjectSettings.set_setting("sandbox/binary_translation/enabled", true)
		ProjectSettings.set_setting("sandbox/binary_translation/cache_dir", OS.get_environment("BINTR"))
	lag = OS.get_environment("CLOSE_LAG").to_int()
	delay = 18 + SEND_TICKS * lag
	if OS.get_environment("RELAY_HOST") != "":
		relay_host = OS.get_environment("RELAY_HOST")
	physics = ClassDB.instantiate("Sandbox")
	physics.set_memory_max(1024)
	physics.set_allocations_max(1 << 22)
	physics.set_unboxed_arguments(true)
	physics.set("execution_timeout", 4000000)
	physics.load_buffer(FileAccess.get_file_as_bytes(a[4]))
	if physics.vmcall("mjc_load_human", -1) != true:
		_end("RESULT: ERROR the model did not build", 2)
		return
	var bodies: PackedStringArray = physics.vmcall("mjc_names", 1)
	for line in FileAccess.get_file_as_string(Parts.dir(here, "packets").path_join("data/parts.tsv")).split("\n", false).slice(1):
		ids.append(bodies.find(line.split("\t")[1]))
	clip = FileAccess.get_file_as_bytes(String(a[5]).path_join(CLIPS[slot] + ".f64")).to_float64_array()
	packets = _guest("packets")
	observer = _guest("observer")
	curve = _guest("curve")
	var table := FileAccess.get_file_as_bytes("res://testdata/zone-fixture/keys.%d.table" % slot)
	if packets == null or observer == null or curve == null or ids.has(-1) or clip.size() < 200 * 86 or table.size() != 100:
		_end("RESULT: ERROR a guest, the part table, the clip or the keys are missing", 2)
		return
	observer.vmcallv("setup", slot, PEOPLE[0], PEOPLE[1], PEOPLE[2], PEOPLE[3])
	observer.vmcallv("keys", table.slice(2, 34), table.slice(35, 67), table.slice(68, 100))
	curve.vmcallv("reset", 63, float(delay))
	if udp.bind(48100 + slot, "*") != OK:
		_end("RESULT: ERROR the socket did not bind", 2)
		return

	var sent := StreamPeerBuffer.new()
	var seen: Array = [StreamPeerBuffer.new(), StreamPeerBuffer.new(), StreamPeerBuffer.new()]
	while _tick() < 0:
		OS.delay_usec(1000)
	var t: int = _tick()
	var closing: int = t / SEND_TICKS + 1
	var ticks := 0
	while t < last_tick:
		var t0 := Time.get_ticks_usec()
		_receive(closing)
		_take(closing)
		while t >= (closing + 1 + lag) * SEND_TICKS:
			_close(closing)
			closing += 1
			_take(closing)
		physics.vmcall("mjc_set_qpos", _qpos(t / 64.0))
		physics.vmcall("mjc_forward")
		var now: PackedFloat64Array = physics.vmcall("mjc_bodies")
		history.append(now)
		if history.size() > 3:
			history.pop_front()
		sent.put_double(t)
		for p in 21:
			for k in 3:
				sent.put_double(now[ids[p] * 7 + k])
		if t % SEND_TICKS == PHASE[slot] and history.size() >= 3:
			_send(t)
		curve.vmcallv("advance", float(t - delay))
		for o in 3:
			if has[o] < 2:
				continue
			seen[o].put_double(t - delay)
			for p in 21:
				var d: PackedFloat64Array = curve.vmcallv("drawn", o * 21 + p)
				for k in 3:
					seen[o].put_double(d[k])
		var spent: int = Time.get_ticks_usec() - t0
		work_usec += spent
		worst_usec = maxi(worst_usec, spent)
		ticks += 1
		while _tick() <= t:
			OS.delay_usec(300)
		var next: int = _tick()
		skipped += next - t - 1
		t = next
	var out: String = a[6]
	FileAccess.open(out.path_join("sent.%d.f64" % slot), FileAccess.WRITE).store_buffer(sent.data_array)
	for o in 3:
		FileAccess.open(out.path_join("seen.%d.%d.f64" % [slot, o + 1 if o >= slot else o]), FileAccess.WRITE).store_buffer(seen[o].data_array)
	var forged: PackedInt32Array = observer.vmcallv("forged_counts")
	print("CLIENT slot=%d ticks=%d skipped=%d judged=%d valid=%d refused=%d forged=%d late_frames=%d strange=%d mean_tick_usec=%d worst_tick_usec=%d verdicts=%s" % [slot, ticks, skipped, judged, valid, observer.vmcallv("refused_count"), forged[0] + forged[1] + forged[2], late_frames, strange, work_usec / maxi(ticks, 1), worst_usec, str(tally)])
	_end("RESULT: PASS", 0)
