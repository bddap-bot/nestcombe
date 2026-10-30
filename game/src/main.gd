class_name Main
extends Node3D

## How much of a photo write_bytes hands the flash at a time.
const SYNC_BYTES := 1 << 20

var args := {}
var xr: OpenXRInterface
var rig: Rig
var world: World
var session: Session
var _undo: Buttons
var _redo: Buttons
var tool: WallTool
var stair_tool: StairTool
var flora_tool: FloraTool
var delete_tool: DeleteTool
var fitting_tool: FittingTool
var ground_grab: GroundGrab
var water: Water
var water_tool: WaterTool
var wildlife: Wildlife
## What scripts read of the fish (Driver), which may not reach the animals themselves.
var fish: Fish
var look: Look
var sky_tool: SkyTool
var palette_tool: PaletteTool
var photo_tool: PhotoTool
var mirror_tool: MirrorTool
var feed_tool: FeedTool
var easels: Easels
var easel_tool: EaselTool
var boulders: Boulders
var sound: Soundscape
var metrics: Metrics
var quality: Quality
var hand_stop: HandStop
var flat: Flat
var book: Book
var _editors: Array
## The global random generator's seed, which a session record keeps: drawn once, so a replay can start from it. The
## wildlife grows from it too unless --seed names another.
var rng_seed := randi()
## What drives the session in place of the headset and the network when it replays a record (--replay FILE).
var replayer: Replayer


func _ready() -> void:
	if get_tree().current_scene == self:
		FastCores.keep_this_thread()
	args.merge(_parse(launch_args()))
	if args.has("replay"):
		var record := Replay.read(args.replay, str(args.get("avatars", Main.player_path("avatars"))))
		if record.has("error"):
			push_error("replay: %s" % record.error)
			Main.quit(get_tree(), 1)
			return
		replayer = Replayer.new(self, record)
		get_tree().set_multiplayer(replayer)
		rng_seed = int(record.seeds.rng)
		args.seed = record.seeds.wildlife
		args.avatar = record.messages.filter(func(m: Array) -> bool: return m[3] == "look")[0][4][1]
	seed(rng_seed)
	Store.check()
	get_viewport().use_occlusion_culling = true
	world = World.new()
	world.terrain.install()
	world.marks.install()
	look = Look.build(self, world.terrain)
	var flora := Flora.new(world.terrain, world.marks)
	add_child(flora)
	add_child(Meadow.new(flora))
	rig = Rig.new(world.terrain)
	add_child(rig)
	book = Book.new()
	book.rig = rig
	add_child(book)
	world.look = look
	add_child(world)
	var builds := Node3D.new()
	builds.name = "Builds"
	add_child(builds)
	var paths := Paths.new()
	paths.terrain = world.terrain
	paths.marks = world.marks
	builds.add_child(paths)
	flora_tool = FloraTool.new(rig, flora, paths, world)
	add_child(flora_tool)
	tool = WallTool.new(rig, world, flora, paths)
	builds.add_child(tool)
	paths.masonry = tool.masonry
	world.stairs = Stairs.new(tool.masonry)
	builds.add_child(world.stairs)
	stair_tool = StairTool.new(rig, tool, world)
	add_child(stair_tool)
	tool.masonry.placed.connect(look.bounce.place)
	boulders = Boulders.new()
	boulders.terrain = world.terrain
	builds.add_child(boulders)
	hand_stop = HandStop.new(world, rig)
	add_child(hand_stop)
	fitting_tool = FittingTool.new(rig, tool, world)
	fitting_tool.lamps.rooms_changed.connect(look.bounce.enclose)
	fitting_tool.lamps.rooms_changed.connect(look.interior.enclose)
	add_child(fitting_tool)
	delete_tool = DeleteTool.new(rig, tool, flora_tool, world)
	add_child(delete_tool)
	easels = Easels.new()
	easels.terrain = world.terrain
	builds.add_child(easels)
	easel_tool = EaselTool.new(rig, easels, world)
	easel_tool.canvas_contact.connect(Cues.canvas_contact)
	add_child(easel_tool)
	tool.painting = easel_tool.claims
	ground_grab = GroundGrab.new(rig, world, _editing)
	ground_grab.reshaped.connect(tool.reground)
	ground_grab.reshaped.connect(paths.reground)
	ground_grab.reshaped.connect(boulders.reseat)
	ground_grab.reshaped.connect(easels.reseat)
	ground_grab.reshaped.connect(flora.reground)
	add_child(ground_grab)
	var hands: Array[Node3D] = []
	hands.assign(rig.hands)
	water = Water.new(world.terrain, hands)
	water.refilled.connect(tool.reground.bind(true))
	water.refilled.connect(paths.reground.bind(true))
	add_child(water)
	water_tool = WaterTool.new(rig, world)
	add_child(water_tool)
	mirror_tool = MirrorTool.new(rig, world.terrain)
	add_child(mirror_tool)
	world.attach(tool, flora, paths, ground_grab, water, easels, boulders)
	world.holders.append_array([world.stairs, mirror_tool])
	for h in rig.hands:
		h.world = world
		h.body.add_child(BudgetBar.new(world, h))
	palette_tool = PaletteTool.new(rig, tool, world)
	add_child(palette_tool)
	_editors = [tool, stair_tool, flora_tool, delete_tool, easel_tool, ground_grab, palette_tool]
	sky_tool = SkyTool.new(rig, look, world, _editing)
	add_child(sky_tool)
	photo_tool = PhotoTool.new(rig)
	photo_tool.flora = flora
	photo_tool.easels = easels
	photo_tool.scene = _photo_scene
	if args.has("capture-dir"):
		photo_tool.folder = str(args["capture-dir"]).path_join("photos")
	add_child(photo_tool)
	_undo = Buttons.new(rig.left).watch(["undo"])
	_redo = Buttons.new(rig.right).watch(["redo"])
	var played := Session.played(args, get_tree().current_scene == self)
	var me := Persona.new(str(args.get("name", "")), int(args.get("steam-app", OS.get_environment("SteamAppId"))), "user://name" if played else "", hash(OS.get_unique_id()))
	session = Session.new(world, rig, int(args.get("avatar", -1)), int(args.get("port", Session.PORT if played else 0)), played, int(args.get("beacon-port", Session.BEACON_PORT)), me)
	session.painting = easel_tool
	session.book = book
	session.folder = args.get("avatars", Main.player_path("avatars") if played else "") if replayer == null else ""
	if played:
		DirAccess.make_dir_recursive_absolute(session.folder)
	add_child(session)
	move_child(session, rig.get_index() + 1)
	for hand in rig.hands:
		hand.people = SessionWheel.new(session)
	rig.placed.connect(func() -> void:
		for hand in rig.hands:
			hand.close_wheel())
	if args.has("join"):
		var at: PackedStringArray = str(args.join).split(":")
		session.join.call_deferred(at[0], int(at[1]) if at.size() > 1 else Session.PORT)
	wildlife = Wildlife.new(world.terrain, world.marks, water, flora, tool, world.palette, rig.head, hands, int(args.get("seed", rng_seed)), look)
	add_child(wildlife)
	feed_tool = FeedTool.new(rig, water, world.terrain)
	add_child(feed_tool)
	wildlife.handfuls = feed_tool.handfuls
	wildlife.dishes = session.dishes
	add_child(BirdCarry.new(rig, wildlife.birds, easel_tool))
	fish = wildlife.fish
	session.feed = feed_tool
	sound = Soundscape.new(tool, flora_tool, rig, world.terrain, look, wildlife.rng.seed + 9)
	add_child(Cues.new())
	add_child(Warmup.new([ToolModels.prepare_styles, easels.warm, PondWater.prepare]))
	add_child(sound)
	add_child(Underwater.new(water, look, rig))
	rig.floor_under = func(p: Vector3) -> float: return maxf(maxf(tool.floor_under(p), world.stairs.floor_under(p)), boulders.floor_under(p))
	rig.solid_hit = func(origin: Vector3, dir: Vector3, reach: float) -> Dictionary:
		var hits := world.pick(origin, dir, {World.Kind.BUILDING_PAST_ARCHES: reach, World.Kind.FLOOR: reach, World.Kind.PLANT: reach, World.Kind.STAIRS: reach, World.Kind.BOULDER: reach})
		if hits.is_empty():
			return {}
		var hit: Dictionary = hits.values().back()
		match hits.keys().back():
			World.Kind.BOULDER:
				var b: Boulders.Boulder = hit.boulder
				var inv := b.transform.affine_inverse()
				return {"point": hit.point, "side": Rig.side(inv.basis.transposed() * b.shape.normal(inv * hit.point))}
			World.Kind.STAIRS:
				return {"point": hit.point, "side": hit.side}
		return {"point": origin + dir * hit.along, "side": hit.get("side", false)}
	world.blackout = rig.blackout
	world.loaded.connect(rig.respawn)
	rig.respawn()
	metrics = Metrics.new(args.get("metrics", ""))
	metrics.info = {"xr": _start_xr(), "label": "-", "budget": Budget.info()}
	if replayer != null:
		metrics.info.replayed = replayer.record.session
	metrics.info.flat = Main.flat_wanted(args, metrics.info.xr, played)
	if metrics.info.flat:
		flat = Flat.new(rig)
		add_child(flat)
	quality = Quality.new(xr if metrics.info.xr else null, flora, tool.masonry, look)
	if args.has("quality"):
		quality.pin = int(args.quality)
	quality.covered = rig.covered
	add_child(quality)
	metrics.quality = quality
	easels.quality = quality
	metrics.head = rig.head
	if metrics.info.xr:
		metrics.xr = xr
		metrics.refresh = func() -> float: return xr.display_refresh_rate
	metrics.world = world
	metrics.input = func(delta: float) -> PackedByteArray: return Replay.frame(delta, rig.head, rig.hands)
	metrics.checks = func() -> Dictionary: return Replay.check(self)
	if replayer != null:
		world.replayed = true
		metrics.compare = replayer.compare
		replayer.watch(world)
	metrics.context = func():
		var counts := {}
		for category in ["walls", "paths", "grounds", "groups", "easels", "boulders"]:
			counts[category] = world.state[category].size()
		return {"garden_counts": counts, "masonry_instances": Array(tool.masonry.counts()),
			"tools": [Hand.Tool.keys()[rig.hands[0].tool], Hand.Tool.keys()[rig.hands[1].tool]],
			"visiting": not session.visiting.is_empty(), "players": session.players(),
			"ponds": water.ponds.size(), "ducks": wildlife.ducks().size(), "calls": wildlife.calls.played.duplicate(true)}
	metrics.activity = func() -> Array:
		var tags := []
		if rig.aim_hand != null:
			tags.append("moving")
		if _editing():
			tags.append("building")
		if rig.hands.any(func(h: Hand) -> bool: return h.picking):
			tags.append("wheel")
		if rig.covered():
			tags.append("covered")
		if session.players() > 1:
			tags.append("coop")
		return tags
	add_child(metrics)
	var garden: String = args.get("garden", player_path("garden.save") if played and not args.has("photo") else "")
	if garden != "":
		world.load_from(garden)
	# A session that began on the empty meadow loaded no garden, and its replay loads none either.
	if replayer != null and world.snapshot() != replayer.record.garden:
		world.restore_whole(replayer.record.garden)
	if args.has("photo"):
		open_photo(args.photo)
	if replayer == null and (get_tree().current_scene == self or args.has("record-sessions")):
		var into := PlayLog.open_enabled(args)
		if into != null:
			record(into)
	if replayer != null and get_tree().current_scene == self:
		replayer.finished.connect(finish)
	if args.has("camera"):
		var keys: Variant = CameraPath.read(args.camera) if not metrics.info.xr else "a headset draws from its own eyes"
		if keys is String:
			push_error("camera: %s" % keys)
			Main.quit(get_tree(), 1)
			return
		add_child(CameraPath.new(keys, rig.head))
	if args.has("script"):
		var driver := Driver.new(self, Driver.read(args.script))
		driver.finished.connect(func() -> void: if driver.failed: finish(1))
		add_child(driver)
	if args.has("quit-after"):
		get_tree().create_timer(float(args["quit-after"])).timeout.connect(finish)
	get_tree().auto_accept_quit = false


## Records the session into `into` from here: the seeds and the garden it starts from, then every frame's input and
## every message the network brings beside the metrics, and in an armed take the microphone.
func record(into: PlayLog) -> void:
	metrics.play_log = into
	world.play_log = into
	if not into.take.is_empty():
		add_child(Take.new(into))
	into.begin({"rng": str(rng_seed), "wildlife": str(wildlife.rng.seed)}, world.snapshot())
	world.hear("look", [session.worn, session.avatar, session.colour])


## The commit this build was exported from (scripts/package.sh), or "development" when run from the source.
static func revision() -> String:
	if ResourceLoader.exists("res://revision.tres"):
		return str(load("res://revision.tres").get_meta("revision", "development"))
	return "development"


## What a photo records of the garden it is taken in (PhotoTool.scene).
func _photo_scene() -> Dictionary:
	var away := not session.visiting.is_empty()
	var host: String = session.nearby.get("%s:%d" % [session.visiting.address, session.visiting.port], {}).get("name", "") if away else session.me.name
	return {"about": {"time_of_day": look.time, "garden": {"host": host, "visiting": away,
		"commands": world.seq, "meadow_seed": Meadow.SEED, "wildlife_seed": str(wildlife.rng.seed)}}, "world": var_to_bytes(world.snapshot())}


## Opens a photo this game took as the garden it shows, if it carries one, at its time of day, seen from its lens;
## nothing of it is kept. False if the photo holds no garden this game can read whole.
func open_photo(path: String) -> bool:
	var got := PhotoMeta.read(FileAccess.get_file_as_bytes(path))
	if got.is_empty() or not world.restore_whole(got.world):
		push_error("photo: %s holds no garden this game can open" % path)
		return false
	look.set_time(got.about.get("time_of_day", Daylight.DEFAULT))
	var lens := PhotoTool.lens_of(got.about)
	view(lens.origin, lens.origin - lens.basis.z, false)
	print("photo: opened %s" % path)
	return true


func _process(_delta: float) -> void:
	if not _editing():
		if _undo.pressed("undo"):
			world.undo(rig.left)
		if _redo.pressed("redo"):
			world.redo(rig.right)
	_undo.latch()
	_redo.latch()


## Whether `hand`, or with none any hand, has an edit under way: a grip takes nothing from a hand mid-edit.
func _editing(hand: Hand = null) -> bool:
	return _editors.any(func(e) -> bool: return e.busy(hand))


## `Wildlife.feeding`, for a script to wait on: the driver reaches no animal.
func fed(dish: bool) -> int:
	return wildlife.feeding(dish)


## A game played without a headset comes up on the flat screen; a script or test asks for it by --flat.
static func flat_wanted(launch: Dictionary, in_xr: bool, played: bool) -> bool:
	return not in_xr and (launch.has("flat") or played and not launch.has("desktop"))


func _start_xr() -> bool:
	xr = XRServer.find_interface("OpenXR")
	if args.has("desktop") or xr == null or not xr.is_initialized():
		return false
	get_viewport().use_xr = true
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	xr.session_begun.connect(_note_session)
	_watch_xr()
	xr.instance_exiting.connect(finish)
	print("xr: rates ", xr.get_available_display_refresh_rates())
	return true


func _watch_xr() -> void:
	xr.session_begun.connect(_xr_state.bind(OpenXRInterface.SESSION_STATE_READY))
	xr.session_synchronized.connect(_xr_state.bind(OpenXRInterface.SESSION_STATE_SYNCHRONIZED))
	xr.session_visible.connect(_xr_state.bind(OpenXRInterface.SESSION_STATE_VISIBLE))
	xr.session_focussed.connect(_xr_state.bind(OpenXRInterface.SESSION_STATE_FOCUSED))
	xr.session_stopping.connect(_xr_state.bind(OpenXRInterface.SESSION_STATE_STOPPING))
	_xr_state(xr.get_session_state())


func _xr_state(state: int) -> void:
	# An unworn headset never focuses the session, and a script or a replay has no player to pause for.
	var pause := state != OpenXRInterface.SESSION_STATE_FOCUSED and not (args.has("script") or replayer != null)
	if get_tree().paused == pause:
		return
	get_tree().paused = pause
	held(pause)
	print("xr: %s state=%d peers=%s" % ["paused" if pause else "resumed", state, session.multiplayer.get_peers()])


## What a pause does to play beside stopping the tree, which the record keeps (`paused`, `resumed`) and a replay, never
## paused, does where the record has it (Replayer): hands stop following their controllers, since the system menu draws
## its own, and an aim ends; a return takes the controls as they are (`Buttons.resumes`).
func held(pause: bool) -> void:
	world.hear("paused" if pause else "resumed", [])
	rig.left.visible = not pause
	rig.right.visible = not pause
	if pause:
		rig.end_aim()
	else:
		Buttons.resumes += 1


func _note_session() -> void:
	metrics.info.available_hz = Array(xr.get_available_display_refresh_rates())
	metrics.info.render_size = [xr.get_render_target_size().x, xr.get_render_target_size().y] if xr.has_method("get_render_target_size") else []
	metrics.info.render_scale = xr.render_target_size_multiplier
	metrics.info.eye_fov_deg = [_fov(xr.get_projection_for_view(0, 1.0, 0.05, 400.0)), _fov(xr.get_projection_for_view(1, 1.0, 0.05, 400.0))]
	metrics.info.eye_gaze = xr.is_eye_gaze_interaction_supported()
	metrics.info.play_area = {XRInterface.XR_PLAY_AREA_SITTING: "local", XRInterface.XR_PLAY_AREA_ROOMSCALE: "local floor", XRInterface.XR_PLAY_AREA_STAGE: "stage"}.get(xr.xr_play_area_mode, str(xr.xr_play_area_mode))
	print("xr: session at ", xr.display_refresh_rate, " Hz, eye gaze ", metrics.info.eye_gaze)


## Left, right, down and up half-angles of an eye's frustum.
static func _fov(p: Projection) -> Array:
	return Array(Metrics.eye_half_angles(p)).map(func(d: float) -> float: return snappedf(d, 0.1))


## Put the head at `eye` looking at `at`; in a headset the play space moves under the tracked head instead.
func view(eye: Vector3, at: Vector3, relative: bool) -> void:
	if relative:
		eye += rig.head.global_position
		at += rig.head.global_position
	var want := Transform3D(Basis.looking_at(at - eye, Vector3.UP), eye)
	if flat:
		rig.global_position += eye - rig.head.global_position
		flat.face(at)
	elif metrics.info.xr:
		rig.global_transform = want * rig.head.transform.affine_inverse()
	else:
		rig.head.global_transform = want


## With `screen`, saves the camera screen's view from the eyes instead: a headset's tracked hand points wherever
## the controller lies. With `lens`, saves that lens's view as the eyes would see it, to set beside a photo.
func capture(name: String, screen := false, lens: Variant = null) -> void:
	var img: Image
	if screen:
		img = await photo_tool.render_screen(rig.head.global_transform)
	elif lens != null:
		img = await photo_tool.render(lens, PhotoTool.FOV, Quality.VIEW_MASK)
	elif metrics.info.xr:
		img = await photo_tool.render(rig.head.global_transform, 90.0, rig.head.cull_mask)
	else:
		await RenderingServer.frame_post_draw
		img = get_viewport().get_texture().get_image()
	var path := capture_path(name + ".png")
	var saved := await photo_tool.save(img, path)
	if saved != OK:
		push_error("capture: could not write %s: %s" % [path, error_string(saved)])
		return
	print("capture: ", path)


func capture_path(name: String) -> String:
	var dir: String = args.get("capture-dir", "user://captures")
	DirAccess.make_dir_recursive_absolute(dir)
	return dir.path_join(name)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		finish()


## The garden and the session log are written before the sounds wind down: a platform that asked us to
## quit may kill the process soon after.
func finish(code := 0) -> void:
	world.flush()
	metrics.close()
	Main.quit(get_tree(), code)


## Where photos go: in user data, except on Android, where an uninstall erases user data and the app's own folders;
## there they go to Pictures/Cairnfold in shared storage, which an uninstall leaves and the device's gallery shows.
static func photos_folder(android := OS.has_feature("android")) -> String:
	return OS.get_system_dir(OS.SYSTEM_DIR_PICTURES, true).path_join("Cairnfold") if android else "user://photos"


## A run's arguments. Godot drops a launch intent's arguments on an exported activity, so on Android they come from
## `launch.args` beside the player's files, one a line, which the run deletes so the next launch starts plain.
static func launch_args() -> PackedStringArray:
	var path := player_path("launch.args")
	if not OS.has_feature("android") or not FileAccess.file_exists(path):
		return OS.get_cmdline_user_args()
	var lines := FileAccess.get_file_as_string(path).strip_edges().split("\n", false)
	DirAccess.remove_absolute(path)
	return lines


## Where the player's `name` (a file or a folder) lives: in user data, except on Android, whose user data only the
## game can read and an uninstall erases with no way to copy it off; there it is in the app's external files folder,
## which a file manager or adb reaches.
static func player_path(name: String) -> String:
	if OS.has_feature("android"):
		var external := OS.get_system_dir(OS.SYSTEM_DIR_DESKTOP, false)
		if external != "":
			return external.path_join(name)
	return "user://" + name


## Writes `bytes` to `path`. On Android Godot's own files reach shared storage only in Download and Documents, so a
## photo is written through java.io, as scoped storage lets an app write its own pictures without a permission. It
## reaches flash SYNC_BYTES at a time: written whole, the kernel flushed a photo's 23 MB in one burst, and the engine's
## code, paged back in on the main thread behind it, held a Quest 2's frame 148 ms.
static func write_bytes(path: String, bytes: PackedByteArray) -> Error:
	if OS.has_feature("android") and path.begins_with(photos_folder()):
		var out: JavaObject = JavaClassWrapper.wrap("java.io.FileOutputStream").FileOutputStream(path)
		if out == null or JavaClassWrapper.get_exception() != null:
			return ERR_FILE_CANT_OPEN
		var fd: JavaObject = out.getFD()
		var failed := false
		for at in range(0, bytes.size(), SYNC_BYTES):
			out.write(bytes.slice(at, at + SYNC_BYTES))
			fd.sync()
			failed = JavaClassWrapper.get_exception() != null
			if failed:
				break
		out.close()
		return ERR_FILE_CANT_WRITE if failed or JavaClassWrapper.get_exception() != null else OK
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	var stored := file.store_buffer(bytes)
	file.close()
	return OK if stored else ERR_FILE_CANT_WRITE


## Data-only tests can finish before the autoloads have entered the tree.
static func quit(tree: SceneTree, code := 0) -> void:
	Wall.quitting = true
	Wall.reap(true)
	if not tree.root.is_inside_tree():
		await tree.process_frame
	await tree.root.get_node("AudioLifetime").finish(code)


static func _parse(raw: PackedStringArray) -> Dictionary:
	var out := {}
	var i := 0
	while i < raw.size():
		var key := raw[i].trim_prefix("--")
		if i + 1 < raw.size() and not raw[i + 1].begins_with("--"):
			out[key] = raw[i + 1]
			i += 2
		else:
			out[key] = true
			i += 1
	return out
