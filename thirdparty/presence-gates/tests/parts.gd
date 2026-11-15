extends RefCounted
## Where the sibling parts are; see docs/gates.md.

const NAMES := {
	"packets": "interactor-packets-guest",
	"router": "interactor-zone-router-guest",
	"observer": "interactor-observer-guest",
	"curve": "interactor-curve-guest",
	"replica": "interactor-replica-guest",
	"follow": "interactor-anny-follow-guest",
}


static func dir(here: String, part: String) -> String:
	var base: String = OS.get_environment("PARTS")
	if base == "":
		base = here.path_join("..").simplify_path()
	var full: String = NAMES[part]
	for n in [full, full.trim_prefix("interactor-")]:
		if DirAccess.dir_exists_absolute(base.path_join(n)):
			return base.path_join(n)
	return base.path_join(full)


static func source(here: String, part: String) -> String:
	return FileAccess.get_file_as_string(dir(here, part).path_join(part + ".sgd"))
