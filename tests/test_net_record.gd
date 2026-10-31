extends "res://../tests/support/suite.gd"

## A recorded session holds every message the network brought, each with its frame, sender and the player it is
## about, its arguments as they arrived, and a file it carries only as its hash; and every networked method records.


func _initialize() -> void:
	boot_main()
	await process_frame
	var folder := "user://net-%d" % OS.get_process_id()
	main.record(PlayLog.new(folder))
	var log := main.metrics.play_log
	var eyes := Transform3D(Basis(Vector3.UP, 0.4), Vector3(1.25, 1.6, -2.5))
	var springs := PackedVector3Array([Vector3(1, 2, 3), Vector3(0.1, 0.2, 0.3)])
	var avatar := PackedByteArray([7, 7, 7])
	var cmd := {"op": "plant", "kind": "tree", "seed": 1, "at": main.world.terrain.ground(2, 2), "id": 5, "seq": 1, "by": 9}
	await frames(3)
	var first := log._frames + log._input.size() / Replay.FRAME_BYTES
	main.session._pose(eyes, eyes, eyes, Vector3.FORWARD, springs, {})
	main.world.hear("_commit", [cmd], 9)
	await frames(2)
	main.session._wear(avatar, 2)
	main.session._wear(PackedByteArray(), 0)
	cmd.seed = 2
	await until(func() -> bool: return log._messages == 5, "a second's messages taken for writing")
	log._join()
	main.session._threw(Vector3.ONE, Vector3.UP, 3)
	log.finish()
	main.metrics.play_log = null
	main.world.play_log = null

	var nets := []
	for name in DirAccess.get_files_at(folder):
		if name.ends_with(".jsonl"):
			for line in FileAccess.get_file_as_string(folder.path_join(name)).strip_edges().split("\n"):
				var e: Dictionary = JSON.parse_string(line)
				if e.event == "net":
					nets.append(e)
	nets.sort_custom(func(a, b) -> bool: return a.first < b.first)
	check(nets.size() >= 2, "messages are written as the session goes, and at its end")
	var heard := []
	for e in nets:
		check(int(e.first) == heard.size(), "net events follow on from each other")
		heard.append_array(Replay.messages(e))
	check(heard[0][3] == "look" and heard[0][0] == 0, "the record begins with the look the session began in: %s" % [heard[0].slice(0, 4)])
	heard = heard.slice(1)
	var calls := heard.map(func(m: Array) -> String: return m[3])
	check(calls == ["_pose", "_commit", "_wear", "_wear", "_threw"], "every message is kept, in the order heard: %s" % [calls])
	check(heard[0][0] == first and heard[1][0] == first and heard[2][0] == first + 2, "each with the frame it came in before: %s" % [heard.map(func(m): return m[0])])
	check(heard[0][4] == [eyes, eyes, eyes, Vector3.FORWARD, springs, {}], "a pose as it arrived")
	check(heard[1][2] == 9 and heard[1][4][0].seed == 1 and heard[1][4][0].at == cmd.at, "a build command as it arrived, about the player who made it, untouched by what came after")
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(avatar)
	check(heard[2][4] == [{"sha256": h.finish().hex_encode(), "bytes": avatar.size()}, 2], "an avatar file kept as its hash and length")
	check(heard[3][4] == [PackedByteArray(), 0], "and no file as none")
	var out := []
	var code := OS.execute("python3", [ProjectSettings.globalize_path("res://../scripts/sessions.py"), ProjectSettings.globalize_path(folder), "--json"], out, true)
	var read: Variant = JSON.parse_string(out[0]) if code == 0 else null
	check(read is Array and read.size() == 1 and int(read[0].net.messages) == 6 and int(read[0].net.missing) == 0 and read[0].net.commands == {"9": 1.0},
		"scripts/sessions.py counts the messages and each player's build commands: %s" % [out])

	for name in DirAccess.get_files_at(folder):
		DirAccess.remove_absolute(folder.path_join(name))
	DirAccess.remove_absolute(folder)
	for path in ["res://src/world.gd", "res://src/session.gd"]:
		var lines := FileAccess.get_file_as_string(path).split("\n")
		for i in lines.size():
			if lines[i].begins_with("@rpc"):
				check(lines[i + 2].strip_edges().begins_with("hear(") or lines[i + 2].strip_edges().begins_with("world.hear("),
					"%s records what it hears first: %s" % [path, lines[i + 1]])
	main.queue_free()
	await process_frame
	finish()
