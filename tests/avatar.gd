extends RefCounted
## One skinned avatar and its follower guest, with no physics of its own; see docs/world.md.

const HIP_BONES := ["upperleg01.L", "upperleg01.R"]
const HIP_BODIES := ["femur_l", "femur_r"]

var error := ""
var scene: Node
var skel: Skeleton3D
var follower: Object
var bones := 0


func _find(n: Node, cls: String) -> Node:
	if n.is_class(cls):
		return n
	for c in n.get_children():
		var r := _find(c, cls)
		if r != null:
			return r
	return null


func _tint(n: Node, mat: Material) -> void:
	if n is MeshInstance3D:
		n.material_override = mat
	for c in n.get_children():
		_tint(c, mat)


func build(follow_dir: String, glb: String, bodies: PackedStringArray, zero: PackedFloat64Array, color: Color) -> bool:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(glb, state) != OK:
		error = "cannot read %s" % glb
		return false
	scene = doc.generate_scene(state)
	skel = _find(scene, "Skeleton3D") as Skeleton3D
	if skel == null:
		error = "no skeleton"
		return false
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	_tint(scene, mat)
	var names := PackedStringArray()
	var parents := PackedInt32Array()
	var rest := PackedFloat64Array()
	bones = skel.get_bone_count()
	for c in bones:
		names.append(skel.get_bone_name(c))
		parents.append(skel.get_bone_parent(c))
		var g := skel.get_bone_global_rest(c)
		var q := g.basis.get_rotation_quaternion()
		rest.append_array([g.origin.x, g.origin.y, g.origin.z, q.x, q.y, q.z, q.w])
	var drive := PackedInt32Array()
	for line in FileAccess.get_file_as_string(follow_dir.path_join("data/drive.tsv")).split("\n", false).slice(1):
		var f := line.split("\t", true)
		var row := [names.find(f[0]), bodies.find(f[1]), -1, -1, -1, -1]
		if f[2] != "":
			row = [row[0], row[1], names.find(f[2]), names.find(f[3]), bodies.find(f[4]), bodies.find(f[5])]
		drive.append_array(row)
	var hips := PackedInt32Array([names.find(HIP_BONES[0]), names.find(HIP_BONES[1]), bodies.find(HIP_BODIES[0]), bodies.find(HIP_BODIES[1])])
	var script: Object = ClassDB.instantiate("SafeGDScript")
	script.set_source_code(FileAccess.get_file_as_string(follow_dir.path_join("follow.sgd")))
	if script.get_compile_error() != "":
		error = script.get_compile_error()
		return false
	follower = ClassDB.instantiate("Sandbox")
	follower.load_buffer(script.get_content())
	var ok = follower.vmcallv("setup", parents, rest, drive, zero, hips)
	if typeof(ok) != TYPE_INT or ok != 0:
		error = "the follower refused its tables: %s" % str(ok)
		return false
	return true


func pose(now: PackedFloat64Array) -> bool:
	var out = follower.vmcallv("pose", now)
	if not (out is PackedFloat64Array) or out.size() != bones * 4 + 3:
		return false
	for c in bones:
		skel.set_bone_pose_rotation(c, Quaternion(out[c * 4], out[c * 4 + 1], out[c * 4 + 2], out[c * 4 + 3]))
	skel.set_bone_pose_position(0, Vector3(out[bones * 4], out[bones * 4 + 1], out[bones * 4 + 2]))
	return true
