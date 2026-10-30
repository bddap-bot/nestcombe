extends "res://../tests/support/suite.gd"


func _initialize() -> void:
	_run.call_deferred()


## Every subtree's icon in `tree` draws its items as their own icons draw them, so none shows what its menu lacks.
func _check_icons(tree: Array, people: SessionWheel) -> void:
	for item in tree:
		if item is Array:
			var model := Hand.miniature(item, people.icon)
			check(_shows(model, item, people, 2), "the icon of %s shows what it holds" % [item])
			model.free()
			_check_icons(item, people)


func _shows(model: Node3D, item: Variant, people: SessionWheel, depth: int) -> bool:
	var drawn: Node3D = people.icon(item)
	if drawn == null and item is Array:
		var shown := range(mini(item.size(), 4)).filter(func(j: int) -> bool: return depth > 1 or not item[j] is Array)
		return model.get_child_count() == shown.size() and range(shown.size()).all(func(c: int) -> bool: return _shows(model.get_child(c), item[shown[c]], people, depth - 1))
	if drawn == null:
		drawn = Hand.miniature(item)
	var same := _meshes(model) == _meshes(drawn)
	drawn.free()
	return same


func _meshes(model: Node) -> Array:
	return model.find_children("*", "MeshInstance3D", true, false).map(func(m: MeshInstance3D) -> Array: return [m.mesh.get_class(), m.mesh.get_aabb()])


## Holds the wheel button and sweeps `hand` to the people leaf `leaf`, where its dial opens.
func _open(hand: Hand, button: String, leaf: String) -> void:
	Buttons.injected[button] = true
	await process_frame
	await process_frame
	var tree := hand.inventory()
	for at in ToolWheel.sweep(tree, ToolWheel.paths(tree)[leaf]):
		Hand.injected_reach[hand.tracker] = at
		await process_frame
		await process_frame
	Hand.injected_reach.erase(hand.tracker)


## Twists `hand` about its pointing axis by `steps` of its dial.
func _twist(hand: Hand, steps: int) -> void:
	var from := hand.global_basis
	for f in 6:
		hand.global_basis = Basis(-from.z, deg_to_rad(steps * Dial.step(hand.dial.choices.size()) * (f + 1) / 6.0)) * from
		await process_frame


func _run() -> void:
	boot_main()
	await process_frame
	var hand: Hand = main.rig.right
	var session: Session = main.session
	check(hand.people.choices("friends") == ["home"] and hand.people.start("friends") == 0, "with no one near, the friends dial is your own garden alone, and starts there")
	_check_icons(hand.inventory(), hand.people)
	for i in 12:
		session.nearby["192.0.2.1:%d" % (8000 + i)] = {"address": "192.0.2.1", "port": 8000 + i, "key": i, "avatar": i % 3, "colour": Color.WHITE, "name": "Friend %d" % i, "joins": i != 3, "seen": INF}
	var friends := hand.people.choices("friends")
	check(friends.size() == 13 and friends[0] == "home" and friends.slice(1).all(func(k: String) -> bool: return k.begins_with("join:")), "the friends dial holds your garden and every garden near, on one ring")
	check(Dial.radius(friends.size()) < 0.15, "a full ring of friends stays within a hand's reach: %.2f m" % Dial.radius(friends.size()))
	var avatars := hand.people.choices("avatars")
	check(avatars.slice(0, Avatar.BUILT_IN.size()) == range(Avatar.BUILT_IN.size()).map(func(i: int) -> String: return "avatar:%d" % i), "the avatars dial starts with the built-in figures")
	check(avatars[hand.people.start("avatars")] == "avatar:%d" % session.avatar, "the avatars dial starts on who you are")
	var tree := hand.inventory()
	_check_icons(tree, hand.people)
	var mirror := hand.people.icon("avatars")
	check(mirror.find_children("Glass", "MeshInstance3D", true, false).size() == 1 and mirror.find_children("*", "Avatar", true, false).size() == 1, "the avatars slot is one figure in a hand mirror")
	var gate := hand.people.icon("friends")
	check(gate.find_children("Glass", "MeshInstance3D", true, false).is_empty() and gate.find_children("*", "Avatar", true, false).size() == 3, "the friends slot is a gate with a few nearby players behind it")
	check(mirror.find_children("*", "Label3D", true, false).is_empty() and gate.find_children("*", "Label3D", true, false).is_empty(), "the people slots carry no text")
	mirror.free()
	gate.free()
	var unjoinable := hand.people.figure("join:192.0.2.1:8003")
	var labels := unjoinable.find_children("*", "Label3D", true, false)
	check(labels.size() == 1 and labels[0].text == "Friend 3", "a garden this build cannot join carries its name and no mark")
	for mesh: MeshInstance3D in unjoinable.find_children("*", "MeshInstance3D", true, false):
		check(mesh.material_override is BaseMaterial3D and mesh.material_override.albedo_color.a < 0.5, "a garden this build cannot join is faint")
	unjoinable.free()
	var worn := hand.people.signature("avatars")
	session.avatar = (session.avatar + 1) % Avatar.BUILT_IN.size()
	check(hand.people.signature("avatars") != worn, "the mirror is drawn again when the player changes who they are")
	session.avatar = 0
	var button := "right_hand/" + Controls.input("wheel", "right_hand")
	await _open(hand, button, "avatars")
	check(hand.dial != null and hand.picking and not hand._wheel_root.visible, "reaching the mirror turns the wheel into the avatars dial")
	check(hand.dial.choices.size() == hand.people.choices("avatars").size() and hand.dial.pick == 0, "one dial of every avatar, starting on the one worn")
	var drawn_as_icons := func(n: Node) -> bool:
		return (n.find_children("*", "MeshInstance3D", true, false) + n.find_children("*", "MultiMeshInstance3D", true, false)).all(func(g: GeometryInstance3D) -> bool:
			var mi := g as MeshInstance3D
			var count := mi.mesh.get_surface_count() if mi != null and g.material_override == null else 1
			return range(count).all(func(i: int) -> bool:
				var m: Material = g.material_override if g.material_override != null else mi.get_active_material(i)
				return m is ShaderMaterial and m.shader.code.contains('#include "res://src/icon.gdshaderinc"')))
	check(not hand.dial.find_children("*", "Avatar", true, false).is_empty() and hand.dial.find_children("*", "Avatar", true, false).all(drawn_as_icons), "the dial's figures draw in the icon look")
	check(hand._built.size() > 20 and hand._built.values().all(drawn_as_icons), "every wheel icon draws in the icon look alone, lit by nothing in the garden")
	check(not drawn_as_icons.call(main.rig.body), "world avatars keep the garden's light")
	var dialled: Array = range(Avatar.BUILT_IN.size()).map(func(i: int) -> Node3D: return hand.dial.choices[i])
	await _twist(hand, 2)
	check(hand.dial.pick == 2 and session.avatar == 0, "twisting turns the dial two avatars on, wearing nothing yet")
	check(hand.dial.choices[2].scale.x > hand.dial.choices[0].scale.x, "the avatar at the top stands larger")
	Buttons.injected.erase(button)
	await process_frame
	await process_frame
	check(session.avatar == 2 and hand.dial == null and not hand.picking, "letting go wears the avatar at the top")
	check(hand._wheel_root.get_children().all(func(i: Node3D) -> bool: return not i.visible), "letting go leaves no figure shown")
	var body := main.rig.body
	await _open(hand, button, "avatars")
	check(hand.dial.pick == 2, "the avatars dial opens again on the one now worn")
	check(dialled.all(func(n: Node3D) -> bool: return hand.dial.choices.has(n)), "opening the dial again builds no built-in figure again")
	Buttons.injected.erase(button)
	await process_frame
	await process_frame
	check(session.avatar == 2 and main.rig.body == body, "letting go where it opened changes no one")
	await _open(hand, button, "friends")
	check(hand.dial.choices.size() == 13 and hand.dial.pick == 0, "reaching the gate turns the wheel into the friends dial, starting at home")
	await _twist(hand, -1)
	check(hand.people.choices("friends")[hand.dial.pick] == "join:192.0.2.1:8011", "a twist back reaches the last garden round the ring")
	hand.tool = Hand.Tool.SEEDS
	await process_frame
	check(hand.dial == null and not hand.picking and hand._wheel_root.get_children().all(func(i: Node3D) -> bool: return not i.visible), "a tool switch closes the dial and shows no figure")
	check(session.visiting.is_empty(), "closing the dial by a tool switch joins nothing")
	Buttons.injected.erase(button)
	await process_frame
	session.nearby.clear()
	await _every_file_in_the_folder_is_on_the_wheel(session, hand)
	var cached := -1
	for repeat in 3:
		var preview := hand.people.figure("avatar:0")
		Hand.unlit(preview)
		preview.free()
		if cached >= 0:
			check(Hand._icon_mats.size() == cached, "closing repeated previews does not retain their tint materials")
		cached = Hand._icon_mats.size()
	var vanished := hand.people.figure("join:192.0.2.1:8000")
	vanished.free()
	main.queue_free()
	await process_frame
	finish()


## Each .vrm in the folder that reads is a choice of its own; the newest to arrive is worn, and the worn one removed, the
## built-in avatar is.
func _every_file_in_the_folder_is_on_the_wheel(session: Session, hand: Hand) -> void:
	var source := ProjectSettings.globalize_path("res://").path_join("../tests/avatars")
	var vrms := Array(DirAccess.get_files_at(source)).filter(func(f: String) -> bool: return f.get_extension() == "vrm")
	vrms.sort()
	var folder := ProjectSettings.globalize_path("user://test-wheel-avatars")
	DirAccess.make_dir_recursive_absolute(folder)
	session.folder = folder
	var keys := {}
	for f: String in ["b.vrm", "a.vrm"]:
		var bytes := FileAccess.get_file_as_bytes(source.path_join(vrms[keys.size()]))
		keys[f] = Session.sha256(bytes)
		var out := FileAccess.open(folder.path_join(f), FileAccess.WRITE)
		out.store_buffer(bytes)
		out.close()
		session._look_in_folder()
		while session._reading != "":
			await process_frame
		check(session.worn_key == keys[f] and main.rig.body.source == keys[f], "the newest file to arrive is worn: " + f)
	var slots := hand.people.choices("avatars").filter(func(k: String) -> bool: return k.begins_with("file:"))
	check(slots == ["file:a.vrm", "file:b.vrm"], "two files are two slots, in name order: %s" % [slots])
	session._look_in_folder()
	check(session._reading == "" and session._jobs.is_empty(), "an unchanged file is not read again")
	hand.people.activate("avatar:2")
	check(session.worn.is_empty() and session.avatar == 2, "a built-in choice replaces a worn file")
	for f: String in keys:
		hand.people.activate("file:" + f)
		await process_frame
		check(session.worn_key == keys[f] and main.rig.body.source == keys[f], "choosing a file's slot wears it: " + f)
	DirAccess.remove_absolute(folder.path_join("a.vrm"))
	session._look_in_folder()
	check(session.worn_key == "" and session.worn.is_empty(), "removing the worn file brings the built-in avatar back")
	check(not hand.people.choices("avatars").has("file:a.vrm") and hand.people.choices("avatars").has("file:b.vrm"), "and takes its slot off the dial")
	session.folder = ""
	session.files.clear()
