extends SceneTree
## SimProbe without the game window: builds a test scenario (Scenarios) or the saved site, traces
## its light, runs SimProbe commands in order and prints each answer as one line of JSON.
##   godot --headless --path . -s res://debug/probe_cli.gd -- --site=power_farm --hour=12 \
##       --cmds='[["state", {}], ["objects", {}]]'
## Usually through `python tools/probe.py` (easier quoting). `--site=saved` loads the player's
## site (user://site.json) without changing it.


func _initialize() -> void:
	var opts := {"site": "demo", "hour": "", "cmds": "[[\"state\", {}]]"}
	for arg in OS.get_cmdline_user_args():
		var kv := arg.trim_prefix("--").split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	var materials := MaterialDB.new()
	var objects := ObjectDB.new()
	var err := materials.load_dir()
	if err == "":
		err = objects.load_dir()
	var world: SimWorld
	if err == "":
		world = SimWorld.new(materials, Main.WORLD_WIDTH, Main.WORLD_HEIGHT, 1)
		WorldGen.generate(world)
		err = SiteSave.load_file(world, Main.SAVE_PATH, objects) if opts.site == "saved" \
			else Scenarios.build(world, objects, opts.site)
	if err != "":
		print(JSON.stringify({"error": err}))
		quit(1)
		return
	if opts.hour != "":
		world.enqueue(SetTimeCommand.at_hour(world, float(opts.hour)))
		world.flush_commands()
	var light: LightSystem = world.get_system(&"light")
	light.retrace(world)
	var probe: Node = preload("res://debug/sim_probe.gd").new()
	probe.world = world
	probe.object_db = objects
	probe.headless = true
	var cmds: Variant = JSON.parse_string(opts.cmds)
	if not cmds is Array:
		print(JSON.stringify({"error": "cmds must be a JSON list of [name, {args}]"}))
		quit(1)
		return
	for c: Variant in cmds:
		var name := str(c[0]) if c is Array and not c.is_empty() else str(c)
		var args: Dictionary = c[1] if c is Array and c.size() > 1 and c[1] is Dictionary else {}
		print(JSON.stringify({"cmd": name, "args": args, "result": probe.run(name, args)}))
	probe.free()
	quit()
