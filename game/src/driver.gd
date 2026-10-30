class_name Driver
extends Node

## Plays a JSON list of steps through the same rig and tool entry points the controllers use.
## A step marked "background" starts and the next one follows at once, as a camera glides while a wall is drawn.
## Each step starts once the garden's builds are laid, so it reads them as built.

signal finished

## The parts of the scene `layer` hides, as demo/meadow-layers.json prices the bare meadow; "all" hides every one.
## "mountains" are the ranges and whatever lies between them and the meadow.
## How long `act` acts.
const ACT_SECONDS := 33.0
const LAYERS := ["terrain", "grass", "flowers", "trees", "mountains", "sky", "stars", "sun_disc", "sun", "shadows", "masonry", "ivy", "moss", "boulders", "camera_previews", "ambient", "fog", "post", "msaa", "water", "hands", "self", "ceilings", "underfoot", "eyes", "flames", "halos", "smoke", "wildlife", "shy", "interior"]

var main: Main
var steps: Array
var _eye := Vector3.ZERO
var _at := Vector3.FORWARD
## A view found nothing to look at: the steps after it would capture the wrong thing under their names, so none run.
var failed := false
var _waiting := {}
## What `layer` hid: each property it turned off, by object and property, and the value it had before.
var _hidden := {}
## The share of their area the builds a `sized` step lays take: walls farther apart, a village over a smaller disc,
## paths shorter.
var _area := 1.0
## Players `figures` stood, posed again every frame as streamed poses pose another player.
var _stood: Array[Avatar] = []
## Whether the figures hold Posture's poses, and the microseconds and frames their poses have taken.
var _posing := false
var _posed_usec := 0
var _posed_frames := 0
## The units the last fill_flora's plants would count as, carried on the next units line.
var _flora_units := {}
## Where a headset's hands stand until a step poses them: as a player holds them while building, the book shut in the
## left hand and the right pointing at the ground. Left to the controllers, an unworn headset's idle ones put the book
## and the beam in view or out of it from run to run, about 2 ms of a Quest 2's GPU time.
const HELD := [{"hand": "left", "at": [-0.06, -0.3, -0.34], "aim": [0.15, -0.55, -1.0]}, {"hand": "right", "at": [0.3, -0.55, -0.15], "aim": [0, -1, -0.3]}]


func _init(owner: Main, script: Array) -> void:
	main = owner
	steps = script


static func read(path: String) -> Array:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	assert(parsed is Array, "script %s is not a JSON array" % path)
	return parsed


func _ready() -> void:
	_run()


func _run() -> void:
	await _drawing()
	if main.get_viewport().use_xr:
		for s in HELD:
			await _hold_pose(s)
	for step in steps:
		if failed:
			print("driver: failed")
			finished.emit()
			return
		await _standing()
		print("driver: ", step)
		if step.get("background", false):
			call("_" + step.op, step)
		else:
			await call("_" + step.op, step)
	await _standing()
	print("driver: done")
	finished.emit()


func _exit_tree() -> void:
	if not _waiting.is_empty():
		push_error("driver: until %s timed out" % _waiting)


## A headset runs the main loop for seconds before its session draws a frame, and its shell keeps drawing its launch
## transition meanwhile: a script's clock starts once the game draws. The frame the session starts in carries the
## whole wait as its delta, which would end the first timer at once.
func _drawing() -> void:
	if not main.get_viewport().use_xr:
		return
	while main.xr.get_session_state() not in [OpenXRInterface.SESSION_STATE_SYNCHRONIZED, OpenXRInterface.SESSION_STATE_VISIBLE, OpenXRInterface.SESSION_STATE_FOCUSED]:
		await get_tree().process_frame
	await get_tree().process_frame
	while get_process_delta_time() > 0.25:
		await get_tree().process_frame


func _standing() -> void:
	while main.world.stairs.laying() or main.tool.walls.any(func(w: Wall) -> bool: return w.laying()):
		await get_tree().process_frame


func _wait(s: Dictionary) -> void:
	await get_tree().create_timer(s.seconds, true, false, true).timeout


## Holds a control of `device` (default the Frame; see Controls.DEVICES) for `seconds`, as the controller
## would feed it.
func _press(s: Dictionary) -> void:
	var control: String = s.button
	var device: String = s.get("device", "frame")
	hold(device, control, true)
	await get_tree().create_timer(s.get("seconds", 0.1)).timeout
	hold(device, control, false)
	await get_tree().process_frame
	await get_tree().process_frame


## Holds or lets go of a device's control: a stick direction moves the stick that way.
static func hold(device: String, control: String, on: bool) -> void:
	var to: Array = Controls.DEVICES[device][control]
	if Hand.FLICKS.has(to[1]):
		if on:
			Hand.injected_sticks[to[0]] = Hand.FLICKS[to[1]]
		else:
			Hand.injected_sticks.erase(to[0])
	elif on:
		Buttons.injected["%s/%s" % to] = true
	else:
		Buttons.injected.erase("%s/%s" % to)


## Takes a tool from a hand's wheel as a player does: hold the wheel button, sweep the hand through each
## level of the tool's path, let go; "none" lets go at the centre, emptying the hand. An untracked hand is moved itself; a tracked one sweeps by injected
## reach. An "action", a person's key (SessionWheel.choices), sweeps to its people leaf and twists the dial that opens
## there round to it, the shorter way. "capture" saves a view at the opening and at each level reached, as
## "<capture>-<level>", the dial turned as "<capture>-dial", "popping" one the frame after the pick. "bare" picks with a bare hand before the head: thumb to middle, the palm swept.
func _pick(s: Dictionary) -> void:
	if s.get("bare", false):
		await _pick_bare(s)
		return
	var hand: Hand = _hand(s)
	var key := "%s/%s" % [hand.tracker, Controls.input("wheel", hand.tracker)]
	var tree := hand.inventory()
	var leaf: Variant = Hand.Tool.get(str(s.get("tool", "none")).to_upper(), Hand.Tool.NONE)
	if s.has("action"):
		leaf = SessionWheel.LEAVES.filter(func(l: String) -> bool: return hand.people.choices(l).has(s.action)).front()
	var path: Array[int] = ToolWheel.paths(tree).get(leaf, [] as Array[int])
	var start := hand.global_position
	var reach := func(p: Vector2) -> void:
		Hand.injected_reach[hand.tracker] = p
	# Setting the player down closes the wheel, and a change of avatar refits them where they stand after a fade.
	while main.rig._pending != null or absf(main.rig.fit() / main.rig.world_scale - 1.0) > Rig.REFIT:
		await get_tree().process_frame
	Buttons.injected[key] = true
	await _frames(3)
	if s.has("capture"):
		await _frames(6)
		await main.capture("%s-0" % s.capture)
	var from := Vector2.ZERO
	var level := 0
	for to in ToolWheel.sweep(tree, path):
		level += 1
		for f in 6:
			reach.call(from.lerp(to, (f + 1) / 6.0))
			await _frames(1)
		from = to
		if s.has("capture"):
			await _frames(6)
			await main.capture("%s-%d" % [s.capture, level])
	if s.has("action"):
		await _twist_dial(hand, hand.people.choices(leaf).find(s.action))
		if s.has("capture"):
			await _frames(6)
			await main.capture("%s-dial" % s.capture)
	if s.get("seconds", 0.0) > 0.0:
		await get_tree().create_timer(s.seconds).timeout
	Buttons.injected.erase(key)
	await _frames(1)
	if s.has("popping"):
		await main.capture(s.popping)
	await _frames(1)
	Hand.injected_reach.erase(hand.tracker)
	if not hand.get_has_tracking_data():
		hand.global_position = start
	await _frames(2)


## Twists `hand`, holding its dial, about its pointing axis until choice `to` stands at the top.
func _twist_dial(hand: Hand, to: int) -> void:
	var n := hand.dial.choices.size()
	var steps := posmod(to - hand.dial.start, n)
	if steps > n / 2:
		steps -= n
	var from := hand.global_basis
	for f in 12:
		hand.global_basis = Basis(-from.z, deg_to_rad(steps * Dial.step(n) * (f + 1) / 12.0)) * from
		await _frames(1)
	await _frames(2)


func _pick_bare(s: Dictionary) -> void:
	var hand: Hand = _hand(s)
	var left: bool = hand == main.rig.left
	var head: Transform3D = main.rig.head.global_transform
	var palm := head * Lessons.frame({"at": Vector3(-0.2 if left else 0.2, -0.3, -0.4), "aim": Vector3(0, -0.35, -1), "roll": 0.0})
	var leaf: Variant = Hand.Tool.get(str(s.get("tool", "none")).to_upper(), Hand.Tool.NONE)
	var path: Array[int] = ToolWheel.paths(hand.inventory()).get(leaf, [] as Array[int])
	Hand.injected_joints[hand.tracker] = HandShape.make(palm, left, "")
	await _frames(2)
	Hand.injected_joints[hand.tracker] = HandShape.make(palm, left, "middle")
	await _frames(3)
	var wheel := hand.wheel_frame()
	var from := Vector2.ZERO
	for to in ToolWheel.sweep(hand.inventory(), path):
		for f in 6:
			var p := from.lerp(to, (f + 1) / 6.0)
			Hand.injected_joints[hand.tracker] = HandShape.make(Transform3D(palm.basis, wheel * Vector3(p.x, p.y, 0)), left, "middle")
			await _frames(1)
		from = to
	Hand.injected_joints[hand.tracker] = HandShape.make(Transform3D(palm.basis, wheel * Vector3(from.x, from.y, 0)), left, "")
	await _frames(2)
	Hand.injected_joints.erase(hand.tracker)
	await _frames(2)


## Holds both controllers in front of the head, `left` and `right` in head space, tops tipped toward the eye,
## then turned `turn` degrees about the vertical (180 points them back at the head) and rolled `roll` degrees.
func _hands(s: Dictionary) -> void:
	var head: Transform3D = main.rig.head.global_transform
	for side in ["left", "right"]:
		if not s.has(side):
			continue
		var hand: Hand = main.rig.left if side == "left" else main.rig.right
		var at: Vector3 = head * Vector3(s[side][0], s[side][1], s[side][2])
		var fwd := -head.basis.z
		var b := Basis.looking_at(fwd, Vector3.UP).rotated(head.basis.x, deg_to_rad(s.get("tip", 35.0)))
		b = Basis(Vector3.UP, deg_to_rad(s.get("turn", 0.0))) * b
		hand.global_transform = Transform3D(b * Basis(Vector3.BACK, deg_to_rad(s.get("roll", 0.0))), at)
		hand.held_still = true
	await get_tree().process_frame


## Acts out with the head and hands, in real seconds, what a player without full-body tracking does: stands, sways,
## leans over to look down, crouches, turns round and back, then walks `walk` metres ahead, turns, walks back and turns
## again, standing at `at` [x, z] facing `yaw` degrees, the eyes the worn avatar's height over the ground under them.
func _act(s: Dictionary) -> void:
	var start := Vector3(s.at[0], 0.0, s.at[1])
	var facing := deg_to_rad(s.get("yaw", 0.0))
	var walk: float = s.get("walk", 2.4)
	var up := func(t: float, a: float, b: float, c: float, d: float) -> float: return smoothstep(a, b, t) * (1.0 - smoothstep(c, d, t))
	var t := 0.0
	while t < ACT_SECONDS:
		await get_tree().process_frame
		t += get_process_delta_time()
		var side: float = 0.07 * sin(TAU * (t - 2.0) / 2.0) * up.call(t, 2.0, 2.5, 7.5, 8.0)
		var lean: float = up.call(t, 8.0, 9.0, 10.5, 11.5)
		var crouch: float = up.call(t, 12.0, 13.5, 15.0, 16.5)
		var turn: float = deg_to_rad(120.0) * up.call(t, 17.0, 19.0, 20.0, 22.0)
		var ahead := walk * (smoothstep(23.0, 26.0, t) - smoothstep(27.5, 30.5, t))
		turn += PI * (smoothstep(26.0, 27.5, t) - smoothstep(30.5, 32.0, t))
		var body := Basis(Vector3.UP, facing)
		var p := start + body * Vector3(side, 0.0, -ahead - 0.25 * lean)
		var yaw := Basis(Vector3.UP, facing + turn)
		var eye := Vector3(p.x, main.world.terrain.height_at(p.x, p.z) + main.rig.body.eye_height * (1.0 - 0.45 * crouch), p.z)
		var head := Transform3D(yaw * Basis(Vector3.RIGHT, -deg_to_rad(40.0) * lean), eye)
		main.view(eye, eye + head.basis * Vector3.FORWARD, false)
		var level := Transform3D(yaw, eye)
		for i in 2:
			var hand: Hand = [main.rig.left, main.rig.right][i]
			hand.global_transform = level * Avatar.AT_SIDES[i]
			hand.held_still = true


## Plays both hands through a script in the picture book's form (Lessons.PAGES: `keys` posing each hand in head space
## as the head stands when it begins, `press` holding actions, over `length` seconds), as a player's controllers would,
## then lets go of everything it held. A hand's key may point it `toward` a spot in place of an `aim`: [right, up, ahead]
## metres from the ground under the head, as "relative" builds are placed, so it meets them however high the head is.
## "capture" saves the view at each of the `shots` seconds given; `tools` hands each hand that tool first. With
## "reach" the keys pose the controllers, and each hand reaches from its own as a player's would (`Reach`). "bare"
## plays it with bare hands (`Lessons.bare`).
func _gesture(s: Dictionary) -> void:
	for side in s.get("tools", {}):
		(main.rig.left if side == "left" else main.rig.right).tool = Lessons.tool(s.tools[side])
	var head: Transform3D = main.rig.head.global_transform
	var fwd := -head.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
	var ground := main.world.terrain.ground(head.origin.x, head.origin.z)
	var body := Transform3D(Basis(fwd.cross(Vector3.UP), Vector3.UP, -fwd), ground)
	s = s.duplicate(true)
	for k: Dictionary in s.keys:
		for side in ["left", "right"]:
			if k.has(side) and k[side].has("toward"):
				var at: Vector3 = head * Lessons._v(k[side].at)
				var aim: Vector3 = head.basis.inverse() * (body * Lessons._v(k[side].toward) - at)
				k[side].aim = [aim.x, aim.y, aim.z]
	var shots: Array = s.get("shots", [])
	var t := 0.0
	var bare: bool = s.get("bare", false)
	while t <= s.length:
		for side in Lessons.hands(s):
			var hand: Hand = main.rig.left if side == "left" else main.rig.right
			if bare:
				Hand.injected_joints[hand.tracker] = Lessons.bare(s, side, head, t)
				continue
			hand.held_still = true
			hand.held_reaches = s.get("reach", false)
			hand.global_transform = head * Lessons.frame(Lessons.pose(s, side, t))
		for p in (s.press if not bare else []):
			var key := "%s_hand/%s" % [p.hand, Controls.input(p.action, p.hand + "_hand")]
			if Lessons.held(s, p.hand, p.action, t):
				Buttons.injected[key] = true
			else:
				Buttons.injected.erase(key)
		await get_tree().process_frame
		if s.has("capture") and not shots.is_empty() and t >= shots[0]:
			await main.capture("%s-%d" % [s.capture, s.shots.size() - shots.size()])
			shots = shots.slice(1)
		t += get_process_delta_time()
	for p in s.press:
		Buttons.injected.erase("%s_hand/%s" % [p.hand, Controls.input(p.action, p.hand + "_hand")])
	for h in main.rig.hands:
		h.held_reaches = false
	if bare:
		for side in Lessons.hands(s):
			var tracker := side + "_hand"
			Hand.injected_joints[tracker] = HandShape.make(Hand.injected_joints[tracker][HandShape.PALM], side == "left", "")
		await _frames(1)
		Hand.injected_joints.clear()
	await _frames(2)


## Tips the rig about the head so the head looks level, as an unworn headset lying tilted would not: a scripted view
## then sees what a standing player would, looking level and upright. It reads the head as tracked now, so a
## script waits for tracking to start before it.
func _level(_s: Dictionary) -> void:
	var head: Transform3D = main.rig.head.global_transform
	var ahead := -head.basis.z
	var flat := Vector3(ahead.x, 0.0, ahead.z)
	if flat.length() < 0.01:
		flat = head.basis.y if ahead.y < 0.0 else -head.basis.y
		flat.y = 0.0
	var turn := Basis.looking_at(flat.normalized(), Vector3.UP) * head.basis.orthonormalized().inverse()
	main.rig.global_transform = Transform3D(turn, head.origin - turn * head.origin) * main.rig.global_transform
	await _frames(2)


## Holds `hand` beside the head, or at `from` in head space, holding `tool`, pointing at `at` in the garden.
func _point(s: Dictionary) -> void:
	var hand := _holding(s, Hand.Tool[s.tool.to_upper()])
	var head: Transform3D = main.rig.head.global_transform
	var beside := Vector3(0.18 if s.get("hand", "right") == "right" else -0.18, -0.25, -0.3)
	var from := head * (Lessons._v(s.from) if s.has("from") else beside)
	var at := Vector3(s.at[0], s.at[1], s.at[2])
	hand.global_transform = Transform3D(Basis.looking_at(at - from, Vector3.UP), from)
	hand.held_still = true
	await _frames(2)


func _frames(n: int) -> void:
	for f in n:
		await get_tree().process_frame


## Calls `step` after each frame of `seconds` (the step's own, else `default`) with the share of them done, 1/frames
## to 1; seconds × 60 frames, as tests count them under --fixed-fps 60.
func _over(s: Dictionary, default: float, step: Callable) -> void:
	var frames := maxi(1, ceili(s.get("seconds", default) * 60.0))
	for f in frames:
		await get_tree().process_frame
		step.call(float(f + 1) / frames)


func _hand(s: Dictionary) -> Hand:
	return main.rig.left if s.get("hand", "right") == "left" else main.rig.right


## The step's hand, handed `tool` first, as a player picks it before using it.
func _holding(s: Dictionary, tool: Hand.Tool) -> Hand:
	var hand := _hand(s)
	hand.tool = tool
	return hand


func _place(s: Dictionary) -> void:
	main.rig.place(_spot(s, s.x, s.z), s.get("lift", 0.0))


func _teleport(s: Dictionary) -> void:
	main.rig.teleport(_spot(s, s.x, s.z), s.get("lift", 0.0))
	await get_tree().create_timer(s.get("seconds", 2.0)).timeout


## Shows or hides the gaze marker and logs the gaze pose for `seconds`.
func _gaze(s: Dictionary) -> void:
	var gaze: Gaze = main.rig.gaze
	gaze.show_marker(s.get("on", true))
	var t := 0.0
	while t < s.get("seconds", 0.0):
		print("gaze: tracked ", gaze.get_has_tracking_data(), " ", gaze.global_transform)
		await get_tree().create_timer(0.5).timeout
		t += 0.5


static func aim_pose(head: Transform3D, dir: Array) -> Transform3D:
	var along: Vector3 = head.basis * Vector3(dir[0], dir[1], dir[2])
	return Transform3D(Basis.looking_at(along, Vector3.UP), head * Vector3(-0.2, -0.35, -0.25))


## Teleports as a player does with any tool: the left hand points beside the head along `dir` (relative
## to the head's facing) with its stick pushed `stick` forward for `seconds`, optionally captures the aimed view, from
## the `watch` pose (a `view` step's keys) if given, then lets go.
func _aim(s: Dictionary) -> void:
	var rig: Rig = main.rig
	rig.left.global_transform = aim_pose(rig.head.global_transform, s.dir)
	Hand.injected_sticks[rig.left.tracker] = Vector2(0, 1)
	while rig.aim_hand == null:
		await get_tree().process_frame
	Hand.injected_sticks[rig.left.tracker] = Vector2(0, s.get("stick", 1.0))
	await get_tree().create_timer(s.get("seconds", 1.0)).timeout
	if s.has("watch"):
		await _view(s.watch)
	if s.has("capture"):
		await main.capture(s.capture)
	Hand.injected_sticks.erase(rig.left.tracker)
	await get_tree().create_timer(s.get("settle", 2.0)).timeout


func _wall(s: Dictionary) -> void:
	_lay_materials(s)
	await _stroke(s, Hand.Tool.WALLS)


func _lay_materials(s: Dictionary) -> void:
	var finish := WallLayout.Finish[String(s.get("finish", "bare")).to_upper()] as WallLayout.Finish
	main.tool.finish = finish
	main.tool.wear = s.get("wear", 0.0)
	main.tool.fence_finish = finish if WallLayout.suits(finish, true) else WallLayout.Finish.BARE
	main.tool.planks = s.get("planks", false)
	main.tool.foundation = WallLayout.Foundation[String(s.get("foundation", "pillars")).to_upper()]


func _fence(s: Dictionary) -> void:
	_lay_materials(s)
	await _stroke(s, Hand.Tool.FENCE)


## With `capture`, saves the view `capture_at` of the way through the stroke, the wall half drawn.
func _stroke(s: Dictionary, held: Hand.Tool) -> void:
	var tool: WallTool = main.tool
	var m := tool.mason(_holding(s, held))
	var path := _path(s)
	var first := _target(s, path[0])
	tool.begin_stroke(m, first.point, first.on)
	var frames := maxi(1, ceili(s.get("seconds", 2.0) * 60.0))
	var shot := ceili(frames * s.get("capture_at", 0.6)) if s.has("capture") else -1
	for f in frames:
		await get_tree().process_frame
		tool.extend_stroke(m, _along(path, float(f + 1) / frames))
		if f == shot:
			await main.capture(s.capture)
	tool.end_stroke(m)


## The house tool's trigger: a square house put up at `at`, `size` [along, across], its front turned `turn` degrees
## from the x axis (the head's right with "relative"), raised `rise` metres on its plinth; with "round", the tower
## tool's, a round tower `size` [across, across]. Put up at `from` (default `at`) turned `turn_from` (default `turn`), a
## grip then carries it there over `seconds`, raising it as it goes; else "seconds" waits that long after. With "capture",
## `shots` views named after it are saved at even steps of the carry, the last just before letting go. With `windows`,
## a square house opens windows of that family in WallLayout.WINDOW_FAMILIES all round it (`_open_windows`). With `seed`,
## its stones and roof are laid from that seed, so runs before and after a change lay the same house.
func _house(s: Dictionary) -> void:
	var tool: WallTool = main.tool
	var round: bool = s.get("round", false)
	_holding(s, Hand.Tool.TOWER if round else Hand.Tool.HOUSE)
	_lay_materials(s)
	var x: float = s.at[0]
	var z: float = s.at[1]
	var at := WallTool.stance(_spot(s, x, z), _turn(s, x, z, s.get("turn", 0.0)), round)
	if s.has("size"):
		at.size = Vector2(s.size[0], s.size[1])
		at.pitch = WallTool.pitch_for(at)
	at.rise = snappedf(s.get("rise", 0.0), WallLayout.COURSE)
	var carried := s.has("from") or s.has("turn_from") or s.has("capture")
	var put := at.duplicate()
	if carried:
		var from: Array = s.get("from", s.at)
		put.center = _spot(s, from[0], from[1])
		put.yaw = _turn(s, from[0], from[1], s.get("turn_from", s.get("turn", 0.0)))
		put.rise = 0.0
	var on: int = _target(s, put.center).on
	_lay_gables(s)
	var count := tool.walls.size()
	var house := tool.new_house(put, PackedInt32Array([on]) if on >= 0 else PackedInt32Array())
	if s.has("seed"):
		house.layout.seed = int(s.seed)
		house.roof.seed = int(s.seed)
	if s.has("windows") and not round:
		_open_windows(house, int(s.windows), on < 0)
	tool.build([house])
	if not carried:
		await get_tree().create_timer(s.get("seconds", 0.0)).timeout
		return
	for f in 600:
		if tool.walls.size() > count:
			break
		await get_tree().process_frame
	if tool.walls.size() == count:
		push_error("driver: the house put up at %s never stood" % put.center)
		return
	tool.take_build(tool.walls[-1])
	var start: Dictionary = tool.held_at.duplicate()
	var frames := maxi(1, ceili(s.get("seconds", 2.0) * 60.0))
	var shots: int = s.get("shots", 3) if s.has("capture") else 0
	var taken := 0
	for f in frames:
		await get_tree().process_frame
		var k := float(f + 1) / frames
		var to := start.duplicate()
		to.center = start.center.lerp(at.center, k)
		to.yaw = lerp_angle(start.yaw, at.yaw, k)
		to.rise = snappedf(at.rise * k, WallLayout.COURSE)
		tool.stand_build(to)
		if taken < shots and f + 1 >= frames * (taken + 1) / shots:
			taken += 1
			await get_tree().create_timer(0.4).timeout
			await main.capture("%s-%d" % [s.capture, taken])
	if tool.held != null:
		tool.end_build()


## Holds the built house `index` (or under `at`) as hands would and over `seconds` moves it by `move` [x, z] metres,
## turns it `turn` degrees, sizes it to `size` [along its ridge, across it] (a tower to `size[0]` across), raises it
## `rise` metres onto its plinth, its walls to `height` and its roof to `pitch`, `curve` and `overhang`; then lets go.
func _resize(s: Dictionary) -> void:
	var tool: WallTool = main.tool
	tool.take_build(_wall_of(s))
	var start: Dictionary = tool.held_at.duplicate()
	var end := start.duplicate()
	var move: Array = s.get("move", [0, 0])
	end.center = start.center + Vector3(move[0], 0.0, move[1])
	end.yaw = start.yaw + deg_to_rad(s.get("turn", 0.0))
	if s.has("size"):
		end.size = Vector2(s.size[0], s.size[0] if start.round else s.size[1])
	var keys := ["rise", "height", "pitch", "curve", "overhang"].filter(func(k: String) -> bool: return start.has(k))
	for k: String in keys:
		end[k] = s.get(k, start[k])
	await _over(s, 1.0, func(k: float) -> void:
		var to := start.duplicate()
		to.center = start.center.lerp(end.center, k)
		to.yaw = lerp_angle(start.yaw, end.yaw, k)
		if start.has("size"):
			to.size = start.size.lerp(end.size, k)
		for key: String in keys:
			to[key] = lerpf(start[key], end[key], k)
		tool.stand_build(to))
	if tool.held != null:
		tool.end_build()


func _turn(s: Dictionary, x: float, z: float, degrees: float) -> float:
	var t := deg_to_rad(degrees)
	return WallTool.angle(_spot(s, x + cos(t), z + sin(t)) - _spot(s, x, z))


## Shapes the roof of build `index`: its `pitch` and `curve` as a grip pulls them, its eaves `overhang` metres past the
## walls, its `deck` ("stone" or "wood"), its `dormers` and its `hatches`, each [metres along the ridge, across it].
func _roof(s: Dictionary) -> void:
	var w: Wall = main.tool.walls[s.index]
	var r := w.roof
	r.pitch = RoofLayout.snap_pitch(s.get("pitch", r.pitch), WallTool.ROOF_STEP)
	r.curve = clampf(s.get("curve", r.curve), -RoofLayout.CURVE, RoofLayout.CURVE)
	r.overhang = clampf(snappedf(s.get("overhang", r.overhang), WallTool.ROOF_STEP), 0.0, r.reach())
	var roof := {"pitch": r.pitch, "curve": r.curve, "overhang": r.overhang}
	if s.has("deck"):
		roof["deck"] = int(RoofLayout.Deck[s.deck.to_upper()])
	for key in ["dormers", "hatches"]:
		if s.has(key):
			roof[key] = PackedVector2Array(s[key].map(func(d: Array) -> Vector2: return Vector2(d[0], d[1])))
	main.world.submit({"op": "reshape", "of": "walls", "id": w.id, "data": {"roof": roof}})


## Thatches every roof standing, as the roof style pick does, so a phase measures thatch against the same houses tiled.
func _thatch(_s: Dictionary) -> void:
	for id: int in main.world.state.walls:
		if main.world.state.walls[id].has("roof"):
			main.world.submit({"op": "reshape", "of": "walls", "id": id, "data": {"roof": {"thatch": true}}})


func _top(s: Dictionary) -> void:
	var w: Wall = main.tool.walls[s.index]
	if w.roof == null or w.roof.flat():
		main.world.submit({"op": "reshape", "of": "walls", "id": w.id, "data": {"top": int(WallLayout.Top[s.style.to_upper()])}})


## Turns the gable ends of the house `index` (or under `at`) to `style`: wall, boards or steps.
func _gable(s: Dictionary) -> void:
	main.world.submit({"op": "reshape", "of": "walls", "id": _wall_of(s).id, "data": {"gable_end": int(WallLayout.GableEnd[s.style.to_upper()])}})


## With `gable` (wall, boards or steps), houses laid after take that style of gable end.
func _lay_gables(s: Dictionary) -> void:
	if s.has("gable"):
		main.tool.gable_end = WallLayout.GableEnd[s.gable.to_upper()]


func _lift_wall(s: Dictionary) -> void:
	var w := _wall_of(s)
	main.world.submit({"op": "reshape", "of": "walls", "id": w.id, "data": {"height": float(s.height)}})


## Holds wall `index` (or the one under `at`), a house too, as two hands would, and draws them `metres` apart upright
## then back `times` times, `seconds` a pull: its height, or with "roof" a house's ridge.
func _grip(s: Dictionary) -> void:
	var tool: WallTool = main.tool
	var w := _wall_of(s)
	for n in int(s.get("times", 1)):
		var metres: float = s.get("metres", 1.0) * (1.0 if n % 2 == 0 else -1.0)
		tool.take_build(w)
		var start: Dictionary = tool.held_at.duplicate()
		await _over(s, 1.0, func(k: float) -> void:
			var up := metres * smoothstep(0.0, 1.0, k)
			var to := start.duplicate()
			if s.get("roof", false):
				to.pitch = RoofLayout.snap_pitch(start.pitch + up, WallTool.ROOF_STEP)
			else:
				to.height = maxf(start.height + snappedf(up, WallLayout.COURSE), WallLayout.MIN_HEIGHT)
			tool.stand_build(to))
		if tool.held != null:
			tool.end_build()
		await _standing()


## Grips the meadow's tree `tree`, or with `x`, `z` the tree standing nearest there, near its top with both hands 2 m
## apart, as two hands do, and spreads them `metres` farther over `seconds` (negative closes them), sizing it by their
## span; "capture" saves the view at the end of the pull.
func _grow(s: Dictionary) -> void:
	var tool: WallTool = main.tool
	var flora: Flora = main.flora_tool.flora
	var trunk := _trunk(s)
	var at := trunk.foot() + Vector3.UP * flora.top_of(trunk) * 0.8
	var mid: Vector3 = at + Vector3.BACK * 2.0
	var right := tool.mason(main.rig.right)
	var left := tool.mason(main.rig.left)
	for m: WallTool.Mason in [right, left]:
		m.hand.global_position = mid + Vector3.RIGHT * (1.0 if m == right else -1.0)
		tool.begin_grow(m, trunk, m.hand.global_transform, at)
	await _over(s, 1.0, func(k: float) -> void:
		var half: float = 1.0 + s.metres * 0.5 * smoothstep(0.0, 1.0, k)
		tool.drag_pair(left, mid + Vector3.RIGHT * half, mid + Vector3.LEFT * half))
	if s.has("capture"):
		await main.capture(s.capture)
	tool.end_grow(left)
	tool.end_grow(right)


## The meadow's tree `tree`, or with `x`, `z` the tree standing nearest there.
func _trunk(s: Dictionary) -> Flora.Plant:
	var flora: Flora = main.flora_tool.flora
	if s.has("tree"):
		return flora.groups[0][flora.meadow_trees()[s.tree]]
	var trunk: Flora.Plant
	var spot := Vector3(s.x, 0.0, s.z)
	for parts in flora.solids():
		var p: Flora.Plant = parts[0]
		if p.pool == flora.trunks and (trunk == null or Vector3(p.anchor.x, 0, p.anchor.z).distance_to(spot) < Vector3(trunk.anchor.x, 0, trunk.anchor.z).distance_to(spot)):
			trunk = p
	return trunk


## Grips the boulder placed `boulder` before the last (0 the last) from `reach` metres off (1.5 without), or with
## "tree" or `x`, `z` a tree's trunk as `grow` finds it, as a hand does, and over `seconds` moves the hand by `move`
## [x, y, z] metres while turning it by `turn` [x, y, z] degrees, then lets go; "capture" saves the view before letting go.
func _carry(s: Dictionary) -> void:
	var tool: WallTool = main.tool
	var m := tool.mason(_hand(s))
	var from: Transform3D
	if s.has("tree") or s.has("x"):
		var trunk := _trunk(s)
		var at := trunk.foot() + Vector3.UP * 1.2
		from = Transform3D(Basis(), at + Vector3.BACK * s.get("reach", 1.5))
		tool.begin_grow(m, trunk, from, at)
	else:
		var ids: Array = main.world.state.boulders.keys()
		var b: Boulders.Boulder = main.boulders.find(ids[ids.size() - 1 - int(s.get("boulder", 0))])
		from = Transform3D(Basis(), b.position + Vector3.BACK * (b.shape.reach() * b.size + s.get("reach", 1.5)))
		var rock: Dictionary = main.boulders.pick(from.origin, -from.basis.z)
		tool.begin_grow(m, b, from, rock.get("point", b.position))
	var move: Array = s.get("move", [0, 0, 0])
	var turn: Array = s.get("turn", [0, 0, 0])
	await _over(s, 1.0, func(done: float) -> void:
		var k := smoothstep(0.0, 1.0, done)
		var basis := Basis.from_euler(Vector3(deg_to_rad(turn[0]), deg_to_rad(turn[1]), deg_to_rad(turn[2])) * k)
		m.sizing.follow.call(m, Transform3D(basis, from.origin + Vector3(move[0], move[1], move[2]) * k)))
	if s.has("capture"):
		await main.capture(s.capture)
	tool.end_grow(m)


## Takes hold of a piece of clutter as a hand within reach of it does: piece `piece` (or the first of `style`) of wall
## `wall` (an index into the walls, -1 the last), or of path `path` (likewise into the paths). Over `seconds` the hand
## moves by `move` [x, y, z] metres while turning by `turn` degrees about the vertical, then lets go; with `copy` the
## other hand grips it too and carries a copy off instead; with `take` a press of the decorations tool takes it away.
## "capture" saves the view before letting go.
func _clutter(s: Dictionary) -> void:
	var target := _clutter_target(s)
	if target.is_empty():
		print("clutter: no piece %s" % s)
		failed = true
		return
	var tool: WallTool = main.tool
	var at: Vector3 = target.bounds.get_center()
	target.point = at
	if s.get("take", false):
		main.fitting_tool.fit(target)
		return
	var from := Transform3D(Basis(), at + Vector3(0.0, 0.3, 0.3))
	var first := tool.mason(main.rig.right)
	tool.begin_grow(first, tool._fitting_grip(target), from, at)
	var m := first
	if s.get("copy", false):
		m = tool.mason(main.rig.left)
		tool.begin_grow(m, tool._fitting_grip(target), from, at)
	var move: Array = s.get("move", [0, 0, 0])
	var turn := deg_to_rad(float(s.get("turn", 0.0)))
	await _over(s, 1.0, func(done: float) -> void:
		var k := smoothstep(0.0, 1.0, done)
		m.sizing.follow.call(m, Transform3D(Basis(Vector3.UP, turn * k), from.origin + Vector3(move[0], move[1], move[2]) * k)))
	if s.has("capture"):
		await main.capture(s.capture)
	tool.end_grow(m)
	if m != first:
		tool.end_grow(first)


## The pick a hand would make on the piece of clutter `_clutter` names, laid as the build stands now; {} for none.
func _clutter_target(s: Dictionary) -> Dictionary:
	var targets: Array[Dictionary] = []
	if s.has("path"):
		var paths: Paths = main.tool.paths
		paths.lay_now()
		var id: int = paths.ids[paths.layouts[s.path]]
		targets.assign(FittingTool.path_targets(paths, main.world.terrain.height_at).filter(func(t: Dictionary) -> bool: return t.path == id))
	else:
		var w: Wall = main.tool.walls[s.get("wall", -1)]
		w.lay_now()
		targets.assign(FittingTool.targets(w).filter(func(t: Dictionary) -> bool: return t.what == "clutter"))
	if s.has("style"):
		targets.assign(targets.filter(func(t: Dictionary) -> bool: return int(t.value.w) == DecorationLayout.named(s.style)))
	var k: int = s.get("piece", 0)
	return targets[k] if k < targets.size() else {}


## Has every house and wall standing gather more of its own, as if hands copied pieces round it: one of each clutter
## style in turn each `every` metres along its foot, `out` from it, until it holds ClutterLayout.MOST or the budget is
## full.
func _cluttered(s: Dictionary) -> void:
	var styles := ["Bench", "Rain barrel", "Crates", "Flower box", "Carved pumpkin", "Anvil", "Market stall"].map(DecorationLayout.named)
	var tally := {"pieces": 0, "full": false}
	var k := 0
	for w: Wall in main.tool.walls:
		var d: Dictionary = main.world.state.walls.get(w.id, {})
		if d.is_empty() or d.fence or not d.on.is_empty():
			continue
		w.lay_now()
		var outward := 1.0 if w.layout.inner_side() <= 0.0 else -1.0
		var list := PackedVector4Array(d.clutter)
		var at: float = s.every * 0.5
		while at < w.layout.length() and list.size() < ClutterLayout.MOST:
			var v := Vector4(at, outward * float(s.out), 0.0, styles[k % styles.size()])
			if w.layout.clutter_frame(v, main.world.terrain.height_at) != null:
				list.append(v)
				k += 1
			at += s.every
		var added: int = list.size() - d.clutter.size()
		if added > 0 and _lit({"op": "reshape", "of": "walls", "id": w.id, "data": {"clutter": list}}, tally):
			tally.pieces += added
	print("stress: %d pieces of clutter more, fill %.3f%s" % [tally.pieces, main.world.fill(), ", the budget full" if tally.full else ""])


## Takes every build's clutter away, as hands would piece by piece: what a garden costs without it.
func _uncluttered(_s: Dictionary) -> void:
	for of in ["walls", "paths"]:
		for id: int in main.world.state[of]:
			if not main.world.state[of][id].clutter.is_empty():
				main.world.submit({"op": "reshape", "of": of, "id": id, "data": {"clutter": PackedVector4Array()}})


## Every wall standing now again, shifted by `offset` [x, z], one each `every` seconds, applied as the host's commands
## reach a visitor: checked, then played.
func _arrive(s: Dictionary) -> void:
	var world: World = main.world
	var walls: Array = world.state.walls.values()
	var shift := Vector3(s.offset[0], 0.0, s.offset[1])
	var id: int = world.state.walls.keys().max() + 1
	for d: Dictionary in walls:
		var w := d.duplicate(true)
		var points := PackedVector3Array()
		for p in w.points:
			points.append(p + shift)
		w.points = points
		w.on = PackedInt32Array()
		if w.has("roof"):
			w.roof.center += shift
		var cmd := Commands.clean({"op": "wall", "ids": PackedInt32Array([id]), "walls": [w], "seq": world.seq + 1, "by": 0}, world.state, true, world.terrain)
		assert(not cmd.is_empty(), "arrive: the shifted wall is not a command a visitor would apply")
		world.seq = cmd.seq
		world._timed(cmd)
		id += 1
		await get_tree().create_timer(s.get("every", 0.5)).timeout


## The house or tower on the ground of the largest footprint `tool` has built, or null for none.
static func largest(tool: WallTool) -> Wall:
	var best: Wall
	var area := 0.0
	for w: Wall in tool.walls:
		var at := WallTool.house_of(tool.world.state.walls[w.id])
		var a: float = 0.0 if at.is_empty() or not w.on.is_empty() else at.size.x * at.size.y
		if a > area:
			best = w
			area = a
	return best


## The wall a step names: by `index` in build order, the one under the ground point `at` [x, z], or with "largest" the
## house or tower on the ground of the largest footprint.
func _wall_of(s: Dictionary) -> Wall:
	if s.get("largest", false):
		return largest(main.tool)
	if s.has("at"):
		return main.tool.pick_building(_spot(s, s.at[0], s.at[1]) + Vector3.UP * 2.0, Vector3.DOWN).wall
	return main.tool.walls[s.index]


## A press of the windows or decorations tool on wall `index` (-1 the last drawn), as `FittingTool.aim`
## would find it: `what` is opening, lantern, flag, chimney, dormer or tower_flag; `s` and `y` place it on the wall,
## `style` and `size` shape an opening, `side` picks a lantern's face, `at` a chimney's or dormer's spot along and across the ridge.
## A decoration with `from` is aimed as the hand would from there toward `at`, turned `turn` degrees if given: furniture
## on a floor or a flat roof; its `style` is DecorationLayout's index or name. `glow`, a Palette.Element.LANTERN swatch,
## is a decoration's flames' or, after the press, its wall's lanterns'.
func _fit(s: Dictionary) -> void:
	if s.what == "decoration":
		var w: Wall = main.tool.walls[s.index] if s.has("index") else null
		var at := w.layout.point_at(float(s.get("s", 0.0))) if w != null else Vector3(float(s.get("x", 0.0)), 0, float(s.get("z", 0.0)))
		var target := {"what": "decoration", "wall": w, "point": at, "s": float(s.get("s", 0.0)), "side": float(s.get("side", 1.0)), "turn": float(s.get("turn", 0.0))}
		if s.has("from"):
			var eye := Vector3(s.from[0], s.from[1], s.from[2])
			target = main.fitting_tool.aim(Hand.Tool.DECORATIONS, eye, (Vector3(s.at[0], s.at[1], s.at[2]) - eye).normalized())
			if s.has("turn"):
				target.turn = deg_to_rad(s.turn)
		if s.has("style"):
			target.style = DecorationLayout.named(s.style) if s.style is String else int(s.style)
		target.lantern = int(s.get("lantern", 0))
		main.fitting_tool.fit(target)
		return
	var target := {"what": s.what, "wall": main.tool.walls[s.index], "s": s.get("s", 0.0), "y": s.get("y", 0.0), "style": s.get("style", WallLayout.Family.COTTAGE), "size": s.get("size", 1.0), "side": s.get("side", 1.0)}
	if s.has("at"):
		target.at = Vector2(s.at[0], s.at[1])
	main.fitting_tool.fit(target)
	if s.has("lantern"):
		main.world.submit({"op": "reshape", "of": "walls", "id": target.wall.id, "data": {"paint": {Palette.Element.LANTERN: int(s.lantern)}}})


## Hangs a string of `style` (a DecorationLayout style name, "Lantern string" without one), its lanterns burning in
## Palette.Element.LANTERN swatch `glow`, from `a` to `b`, each [x, z] on a pole on the ground or [x, y, z] tied there,
## as a stroke of the decorations tool between them would.
func _string(s: Dictionary) -> void:
	var ends: Array[Dictionary] = []
	for end: Array in [s.a, s.b]:
		ends.append({"point": Vector3(end[0], end[1], end[2])} if end.size() == 3 else {"what": "decoration", "mount": "ground", "point": main.world.terrain.ground(end[0], end[1])})
	var cmd := main.fitting_tool.string_command(ends[0], ends[1], int(s.get("seed", 1)), DecorationLayout.named(s.get("style", "Lantern string")), int(s.get("lantern", 0)))
	if cmd.is_empty():
		print("string: none hangs from %s to %s" % [s.a, s.b])
		return
	main.world.submit(cmd)


## A stroke of `tool` along `points`; stone in `style` (StoneStyles' index) when given, as if the style wheel last let go there.
func _paint(s: Dictionary) -> void:
	if s.has("style"):
		Ground.style = s.style
	var flora_tool: FloraTool = main.flora_tool
	var b := flora_tool.brush(main.rig.left if s.get("hand", "left") == "left" else main.rig.right)
	b.hand.tool = Hand.Tool[s.tool.to_upper()]
	if s.has("tree") and b.hand.tool == Hand.Tool.MOSS:
		var flora := flora_tool.flora
		var trees := flora.placed("tree")
		flora_tool.coat_tree(trees[int(s.tree)][0], b.hand)
		return
	var path := _path(s)
	b.meadow = FloraTool.paints_meadow(b.hand.tool, _along(path, 0.0), main.world.marks)
	var t := 0.0
	var seconds: float = s.get("seconds", 2.0)
	while t < seconds:
		await get_tree().process_frame
		var dt := get_process_delta_time()
		t += dt
		flora_tool.paint(b, _along(path, minf(t / seconds, 1.0)), s.radius, dt)
	flora_tool.end_stroke(b)


## A stroke of the path tool from `hand` (left by default) in `surface` (dirt by default); `radius` is half the path's width.
func _pave(s: Dictionary) -> void:
	var flora_tool: FloraTool = main.flora_tool
	var b := flora_tool.brush(main.rig.left if s.get("hand", "left") == "left" else main.rig.right)
	b.hand.tool = Hand.Tool.PATH
	flora_tool.paths.surface = PathLayout.Surface[String(s.get("surface", "dirt")).to_upper()]
	var path := _path(s)
	var mid := path[0].lerp(path[-1], 0.5)
	for i in path.size():
		path[i] = main.world.terrain.ground(lerpf(mid.x, path[i].x, _area), lerpf(mid.z, path[i].z, _area))
	flora_tool.begin_path(b, path[0], s.radius)
	var frames := maxi(1, ceili(s.get("seconds", 2.0) * 60.0))
	for f in frames:
		await get_tree().process_frame
		flora_tool.extend_path(_along(path, float(f + 1) / frames), s.radius)
		if s.has("capture") and f == int(frames * s.get("capture_at", 0.5)):
			await get_tree().create_timer(0.2).timeout
			await main.capture(s.capture)
	flora_tool.end_path(b)


## Grabs the ground at x, z and pulls it `lift` metres over `seconds` (negative digs), as a grip on the ground does.
func _sculpt(s: Dictionary) -> void:
	var tool: GroundGrab = main.ground_grab
	var hand := _hand(s)
	tool.begin(hand, _spot(s, s.x, s.z), s.get("radius", GroundGrab.MIN_RADIUS))
	var t := 0.0
	var seconds: float = s.get("seconds", 1.0)
	while t < seconds:
		await get_tree().process_frame
		var dt := get_process_delta_time()
		t += dt
		tool.pull(hand, s.lift * smoothstep(0.0, 1.0, minf(t / seconds, 1.0)))
		tool.follow(hand, dt)
	tool.end_stroke(hand)


## Desktop only, where no hand is tracked: holds a hand `at` [x, height above the ground, z] for `seconds`, optionally capturing the view.
func _touch(s: Dictionary) -> void:
	main.flora_tool.stand_in = _spot(s, s.at[0], s.at[2]) + Vector3.UP * s.at[1]
	await get_tree().create_timer(s.get("seconds", 1.0)).timeout
	if s.has("capture"):
		await main.capture(s.capture)
	main.flora_tool.stand_in = Flora.NO_HAND


## Digs a hollow at x, z, deeper the more `seconds` (as a grip pressing the ground), and fills it to its brim
## (`Water.brim`), so the pond stays in it.
func _dig(s: Dictionary) -> void:
	var depth := GroundGrab.dig_depth(s.get("seconds", 1.5))
	var radius := GroundGrab.reach(2.8, depth)
	await _sculpt({"x": s.x, "z": s.z, "lift": -depth, "radius": 2.8, "seconds": 0.3, "relative": s.get("relative", false), "hand": s.get("hand", "right")})
	await get_tree().process_frame
	await _pond({"x": s.x, "z": s.z, "brim": radius, "relative": s.get("relative", false), "hand": s.get("hand", "right")})


## Pulls the trigger of the pond tool pointed at the ground at x, z: the hollow beside it fills to that height. With
## `brim`, a hollow pressed at x, z out to that radius fills to its brim (`Water.brim`). Returns once the fill is sent
## to the garden, so `World.idle` then means its water is in.
func _pond(s: Dictionary) -> void:
	var at := _spot(s, s.x, s.z)
	if s.has("brim"):
		at.y = Water.brim(main.world.terrain, at.x, at.z, s.brim)
	var hand := _hand(s)
	var was := hand.tool
	main.water_tool.fill(_holding(s, Hand.Tool.POND), at)
	await get_tree().process_frame
	await get_tree().process_frame
	while main.water_tool.pouring():
		await get_tree().process_frame
	hand.tool = was


## Sweeps the right hand along `points` at `y` metres above the pond at the first point, as if trailing it through.
func _wade(s: Dictionary) -> void:
	var path := _path(s)
	var pond: PondWater = main.water.pond_at(path[0].x, path[0].z)
	assert(pond != null, "wade: no pond at %s" % path[0])
	var y: float = pond.surface_y() + s.get("y", 0.0)
	var t := 0.0
	var seconds: float = s.get("seconds", 2.0)
	while t < seconds:
		var p := _along(path, minf(t / seconds, 1.0))
		main.rig.right.global_position = Vector3(p.x, y, p.z)
		await get_tree().process_frame
		t += get_process_delta_time()
	main.rig.right.position = Vector3.ZERO


func _tree(s: Dictionary) -> void:
	main.flora_tool.place("tree", _spot(s, s.x, s.z), null, s.get("seed", randi()))


func _bush(s: Dictionary) -> void:
	main.flora_tool.place("bush", _spot(s, s.x, s.z), null, s.get("seed", randi()))


## Sets a boulder down at `x`, `z`, of shape `seed` (a new one without) and `scale` (1 without); in `style`
## (StoneStyles' index) when given, as if the style wheel last let go there.
func _boulder(s: Dictionary) -> void:
	if s.has("style"):
		Ground.style = s.style
	main.flora_tool.place_boulder(_spot(s, s.x, s.z), null, int(s.get("seed", randi())), float(s.get("scale", 1.0)))


## Points the delete tool straight down at a ground spot from `height` metres up and presses once: a tap.
func _delete(s: Dictionary) -> void:
	var tool: DeleteTool = main.delete_tool
	tool.press(self, _spot(s, s.x, s.z) + Vector3.UP * s.get("height", 2.0), Vector3.DOWN)
	tool.let_go(self)
	await get_tree().process_frame


## Holds the delete tool's trigger pointed along `dir` (relative to the head's facing; up at the sky by default) for
## `seconds`, saving the view as `capture` at `capture_at` seconds; let go short of DeleteTool.WIPE_HOLD, nothing wipes.
func _wipe(s: Dictionary) -> void:
	var tool: DeleteTool = main.delete_tool
	var d: Array = s.get("dir", [0, 2, -1])
	var t := 0.0
	var shot := not s.has("capture")
	while t < s.seconds:
		var head: Transform3D = main.rig.head.global_transform
		if not tool.charge(self, head * Vector3(0.2, -0.3, -0.3), head.basis * Vector3(d[0], d[1], d[2]), get_process_delta_time()):
			break
		if not shot and t >= s.get("capture_at", 0.0):
			shot = true
			await main.capture(s.capture)
		await get_tree().process_frame
		t += get_process_delta_time()
	tool.cancel(self)
	await get_tree().process_frame


## Holds the delete tool's trigger, pointing straight down from `height` metres over each point of `points` in turn
## across `seconds`, then lets go: along a wall it erases, over the ground it mows. With `index` instead, it sweeps
## that wall in build order from fraction `from` of its length to `to`, wherever the head stands.
func _erase(s: Dictionary) -> void:
	var tool: DeleteTool = main.delete_tool
	var path := _path(s) if s.has("points") else _stretch(main.tool.walls[s.index].layout, s.from, s.to)
	var up: Vector3 = Vector3.UP * float(s.get("height", 6.0))
	tool.press(self, path[0] + up, Vector3.DOWN)
	var length := 0.0
	for i in path.size() - 1:
		length += path[i].distance_to(path[i + 1])
	var secs: float = s.get("seconds", 0.5)
	var t := 0.0
	for i in path.size() - 1:
		var duration := secs * path[i].distance_to(path[i + 1]) / maxf(length, 0.001)
		while t < duration:
			var point := path[i].lerp(path[i + 1], t / duration)
			point.y = main.world.terrain.height_at(point.x, point.z)
			tool.hold(self, point + up, Vector3.DOWN)
			await get_tree().process_frame
			t += get_process_delta_time()
		# A late frame must not skip a turn in the scripted gesture.
		tool.hold(self, path[i + 1] + up, Vector3.DOWN)
		t -= duration
	tool.let_go(self)
	await get_tree().process_frame


static func _stretch(layout: WallLayout, from: float, to: float) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for i in 9:
		out.append(layout.frame_at(layout.length() * lerpf(from, to, i / 8.0)).point)
	return out


## Fills a disc of `radius` at once with parallel walls `spacing` apart of one height, their ivy fully grown, each a stroke
## of ground points every couple of metres. The rows straddle the centre line, so a viewer at the centre stands between
## two of them.
func _stress(s: Dictionary) -> void:
	var tool: WallTool = main.tool
	var m := tool.mason(_holding(s, Hand.Tool.FENCE if s.get("fence", false) else Hand.Tool.WALLS))
	_lay_materials(s)
	var radius: float = s.radius
	var spacing: float = s.spacing / sqrt(_area)
	var rows: Array[PackedVector2Array] = []
	var length := 0.0
	var z := -(floorf(radius / spacing - 0.5) + 0.5) * spacing
	while z < radius:
		var half := sqrt(radius * radius - z * z)
		if half >= 1.0:
			var row := PackedVector2Array()
			var n := maxi(1, ceili(half))
			for i in n + 1:
				row.append(Vector2(lerpf(-half, half, float(i) / n), z))
			rows.append(row)
			length += row[0].distance_to(row[-1])
		z += spacing
	var start := Time.get_ticks_usec()
	for row in rows:
		tool.begin_stroke(m, main.world.terrain.ground(row[0].x, row[0].y))
		for i in range(1, row.size()):
			tool.extend_stroke(m, main.world.terrain.ground(row[i].x, row[i].y))
		var before := tool.walls.size()
		tool.end_stroke(m)
		for w in tool.walls.slice(before):
			main.world.submit({"op": "reshape", "of": "walls", "id": w.id, "data": {"height": float(s.height)}})
			w.ivy_age = INF
	var ms := (Time.get_ticks_usec() - start) / 1000.0
	var stones := 0
	for w in tool.walls:
		stones += w.layout.stones.size()
	print("stress: %d walls, %.0f m, %d stones, laid in %.0f ms" % [tool.walls.size(), length, stones, ms])


## Hangs a lantern every `every` metres along each wall within `radius` of the centre, alternating faces.
func _lanterns(s: Dictionary) -> void:
	var hung := 0
	for w: Wall in main.tool.walls:
		var layout := w.layout
		var after := PackedVector3Array(layout.lanterns)
		var t := 0.5
		while t < layout.length() and after.size() < Commands.MAX_FITTINGS:
			var p := layout.point_at(t)
			if Vector2(p.x, p.z).length() < s.radius and layout.lantern_fits(t, 2.0):
				after.append(Vector3(t, 2.0, 1.0 if hung % 2 == 0 else -1.0))
				hung += 1
			t += s.every
		if after.size() > layout.lanterns.size():
			main.world.submit({"op": "reshape", "of": "walls", "id": w.id, "data": {"lanterns": after}})
	print("stress: %d lanterns" % hung)


## Lights the houses, until the frame budget is full, bounded or not: a chimney every `every` metres along each
## gable's ridge, as many as a roof takes; a lantern every `every` metres round each, at 2 m on either face in turn; a string between each and every neighbour within `within` metres, tied to the nearest corners
## of their eaves; then rows of strings `span` long on poles, `rows` apart, across the disc of `radius` about the
## centre, from its middle row outward, clear of the houses. Strings are of lanterns and of flags in turn, and each house's lanterns and strings, and each row, burn in
## the next colour and brightness. Its chimneys smoke as they stand.
func _lights(s: Dictionary) -> void:
	var houses: Array = main.tool.walls.filter(func(w: Wall) -> bool: return w.roof != null and w.layout.closed)
	var looks := Palette.count(Palette.Element.LANTERN)
	var tally := {"strings": 0, "lanterns": 0, "chimneys": 0, "full": false}
	for w: Wall in houses:
		w.lay_now()
		if w.roof.kind != RoofLayout.Kind.GABLE:
			continue
		var stacks := PackedVector2Array(w.roof.chimneys)
		var x: float = -w.roof.ridge_length() * 0.5 + s.every * 0.5
		while x < w.roof.ridge_length() * 0.5 and stacks.size() < Commands.MAX_CHIMNEYS:
			var spot := w.roof.chimney_spot(Vector2(x, 0.0))
			if w.roof.clear_of_dormers(spot) and Array(stacks).all(func(c: Vector2) -> bool: return c.distance_to(spot) > RoofLayout.STACK_WIDTH + 0.3):
				stacks.append(spot)
			x += s.every
		var hung := stacks.size() - w.roof.chimneys.size()
		if hung > 0 and _lit({"op": "reshape", "of": "walls", "id": w.id, "data": FittingGrip.data("chimneys", FittingGrip.packed("chimneys", Array(stacks)), true)}, tally):
			tally.chimneys += hung
	for i in houses.size():
		var w: Wall = houses[i]
		var layout := w.layout
		var after := PackedVector3Array(layout.lanterns)
		var t := 0.5
		while t < layout.length() and after.size() < Commands.MAX_FITTINGS:
			if layout.lantern_fits(t, 2.0):
				after.append(Vector3(t, 2.0, 1.0 if after.size() % 2 == 0 else -1.0))
			t += s.every
		var hung := after.size() - layout.lanterns.size()
		if _lit({"op": "reshape", "of": "walls", "id": w.id, "data": {"lanterns": after, "paint": {Palette.Element.LANTERN: (i * 7) % looks}}}, tally):
			tally.lanterns += hung
	var corners := houses.map(func(w: Wall) -> PackedVector3Array:
		var out := PackedVector3Array()
		for p in w.layout.points:
			out.append(w.transform * (p + Vector3.UP * w.layout.height))
		return out)
	for i in houses.size():
		for j in range(i + 1, houses.size()):
			var a := _middle(corners[i])
			var b := _middle(corners[j])
			if Vector2(a.x - b.x, a.z - b.z).length() <= s.within:
				_hang({"point": _nearest(corners[i], b)}, {"point": _nearest(corners[j], a)}, (i * 7) % looks, tally)
	var r: float = s.radius
	var row := 0
	while (row + 1) / 2 * s.rows <= r and not tally.full:
		var z: float = (row + 1) / 2 * s.rows * (1 if row % 2 else -1)
		var x := -sqrt(maxf(r * r - z * z, 0.0))
		while x + s.span <= sqrt(maxf(r * r - z * z, 0.0)) and not tally.full:
			var a := main.world.terrain.ground(x, z)
			var b := main.world.terrain.ground(x + s.span, z)
			var clear := func(c: PackedVector3Array) -> bool:
				var mid := _middle(c)
				var at := Vector2(mid.x, mid.z)
				return Geometry2D.get_closest_point_to_segment(at, Vector2(x, z), Vector2(x + s.span, z)).distance_to(at) > Vector2(c[0].x, c[0].z).distance_to(at) + 0.5
			if corners.all(clear):
				_hang({"what": "decoration", "mount": "ground", "point": a}, {"what": "decoration", "mount": "ground", "point": b}, (row * 5) % looks, tally)
			x += s.span
		row += 1
	print("stress: %d smoking chimneys, %d lanterns, %d strings on %d houses, fill %.3f%s" % [tally.chimneys, tally.lanterns, tally.strings, houses.size(), main.world.fill(), ", the budget full" if tally.full else ""])


## Hangs a string between aims `from` and `to` for `_lights`, of lanterns burning in `look` or of flags as `tally`'s
## count has it in turn.
func _hang(from: Dictionary, to: Dictionary, look: int, tally: Dictionary) -> void:
	var cmd := main.fitting_tool.string_command(from, to, tally.strings + 1, DecorationLayout.named("Flag string" if tally.strings % 2 else "Lantern string"), look)
	if not cmd.is_empty() and _lit(cmd, tally):
		tally.strings += 1


## Submits `cmd` for `_lights` where the frame budget has room for it, or notes in `tally` that it is full.
func _lit(cmd: Dictionary, tally: Dictionary) -> bool:
	if tally.full or not Budget.fits(main.world.units, main.world.change_of(cmd)):
		tally.full = true
		return false
	main.world.submit(cmd)
	return true


static func _middle(points: PackedVector3Array) -> Vector3:
	var sum := Vector3.ZERO
	for p in points:
		sum += p
	return sum / points.size()


static func _nearest(points: PackedVector3Array, to: Vector3) -> Vector3:
	var best := points[0]
	for p in points:
		if p.distance_to(to) < best.distance_to(to):
			best = p
	return best


## Fills every painted and placed flora pool to capacity, or with `count` of each, within `radius` of `at` (x, z; the centre by default), or only
## those `pools` names (grass, flowers, trees, bushes), the trees taking each species in turn at `scale` (1 without). They are not build commands,
## so the frame budget does not count them; the next units line carries the units they would count as, for scripts/costs.py.
func _fill_flora(s: Dictionary) -> void:
	var flora: Flora = main.flora_tool.flora
	var pools: Array = s.get("pools", ["grass", "flowers", "trees", "bushes", "moss"])
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var at: Array = s.get("at", [0, 0])
	var centre := Vector3(at[0], 0, at[1])
	for i in mini(s.get("count", Flora.PAINTED_GRASS), Flora.PAINTED_GRASS) if "grass" in pools else 0:
		flora.add_grass(_scatter(rng, s.radius, centre), rng)
	for i in mini(s.get("count", Flora.PAINTED_FLOWERS), Flora.PAINTED_FLOWERS) if "flowers" in pools else 0:
		flora.add_flower(_scatter(rng, s.radius, centre), rng)
	for i in mini(s.get("count", Flora.PAINTED_MOSS), Flora.PAINTED_MOSS) if "moss" in pools else 0:
		flora.add_moss(_scatter(rng, s.radius, centre), rng)
	for i in mini(s.get("count", Flora.PLACED_TREES), Flora.PLACED_TREES) if "trees" in pools else 0:
		var species := i % FloraLayout.Species.size()
		var parts := flora.add_tree(_scatter(rng, s.radius, centre), rng.randi(), species)
		if not parts.is_empty():
			flora.set_look(parts[0], species, clampf(s.get("scale", 1.0), FloraLayout.SCALES.x, FloraLayout.SCALES.y))
	for i in mini(s.get("count", Flora.PLACED_BUSHES), Flora.PLACED_BUSHES) if "bushes" in pools else 0:
		flora.add_bush(_scatter(rng, s.radius, centre), rng)
	_flora_units = {}
	for pool: String in pools:
		var fill: Array = {"grass": ["grass", Flora.PAINTED_GRASS], "flowers": ["flower", Flora.PAINTED_FLOWERS], "moss": ["moss", Flora.PAINTED_MOSS], "trees": ["tree", Flora.PLACED_TREES], "bushes": ["bush", Flora.PLACED_BUSHES]}[pool]
		_flora_units[fill[0]] = mini(s.get("count", fill[1]), fill[1])


## Measures distant flora in the same scene, off or on: the flowers' triangles and the grass the ground paints.
func _flora_far(s: Dictionary) -> void:
	var flora: Flora = main.flora_tool.flora
	var on: bool = s.get("mode", "on") != "off"
	for pool: Flora.Pool in [flora.flowers, flora.ghost_flowers]:
		pool.far_live.visible = on
	flora.ground_mat.set_shader_parameter(&"far_grass", on)

## Hides one of LAYERS, or shows it again, so a scene measures what it costs against the same view without it.
## Grass is every blade, the meadow's and painted; the ground paints its grass either way. Trees count their bushes,
## which share their crowns' material. Self is the player's own body as their eyes see it.
func _layer(s: Dictionary) -> void:
	var on: bool = s.get("mode", "on") != "off"
	for name: String in LAYERS if s.name == "all" else [s.name]:
		for off: Array in _layer_parts(name):
			var key := "%d.%s" % [off[0].get_instance_id(), off[1]]
			if on and _hidden.has(key):
				off[0].set(off[1], _hidden[key])
				_hidden.erase(key)
			elif not on and not _hidden.has(key):
				_hidden[key] = off[0].get(off[1])
				off[0].set(off[1], off[2])


## Each [object, property, value hiding it] that hides `name`.
func _layer_parts(name: String) -> Array[Array]:
	var flora: Flora = main.flora_tool.flora
	var look: Look = main.look
	var out: Array[Array] = []
	var materials: Array[Material] = []
	match name:
		"terrain":
			materials = [flora.ground_mat]
		"grass":
			materials = [flora.grass_mat]
		"flowers":
			materials = [flora.flower_mat, flora.flower_far]
		"trees":
			materials = [flora.trunks.material, flora.foliage.material]
		"mountains":
			for n in look.get_children():
				if n is MeshInstance3D and n != look.disc and n != look.moon_disc:
					out.append([n, "visible", false])
		"stars":
			out.append([look.sky_mat, "shader_parameter/stars", 0.0])
		"sky":
			out.append([look.env, "background_mode", Environment.BG_COLOR])
		"sun_disc":
			out.append([look.disc, "visible", false])
			out.append([look.moon_disc, "visible", false])
		"sun":
			out.append([look.sun, "visible", false])
		"shadows":
			for step: Quality.Step in Quality.ladder:
				out.append([step, "shadows", false])
		"masonry":
			out.append([main.tool.masonry, "visible", false])
		"ivy":
			materials = [Wall.kinds()[Wall.Part.IVY].material]
		"moss":
			materials = [flora.moss.material]
		"boulders":
			out.append([main.boulders, "visible", false])
		"camera_previews":
			out.append([main.photo_tool, "process_mode", Node.PROCESS_MODE_DISABLED])
		"fog":
			out.append([look.env, "fog_enabled", false])
		"ambient":
			out.append([look.env, "ambient_light_source", Environment.AMBIENT_SOURCE_DISABLED])
		"post":
			out.append([look.env, "adjustment_enabled", false])
		"msaa":
			out.append([main.get_viewport(), "msaa_3d", Viewport.MSAA_DISABLED])
		"water":
			out.append([main.water, "visible", false])
		"hands":
			for h: Node3D in main.rig.hands:
				out.append([h, "visible", false])
		"self":
			out.append([main.rig.head, "cull_mask", main.rig.head.cull_mask & ~Quality.EYES_LAYER])
		"underfoot":
			for n: Node3D in main.rig._underfoot.get_children():
				out.append([n, "visible", false])
		"eyes":
			out.append([main.hand_stop, "eyes", false])
		"ceilings":
			for n: Node3D in main.get_tree().get_nodes_in_group(&"roof_ceilings"):
				out.append([n, "visible", false])
		"flames":
			materials = [Fittings._flame]
		"halos":
			materials = [Fittings._halo]
		"smoke":
			materials = [Smoke._material]
		"interior":
			out.append([main.look.interior, "masked", false])
		"wildlife":
			out.append([main.wildlife, "visible", false])
			out.append([main.fish, "visible", false])
		"shy":
			for kind in main.wildlife.shy():
				out.append([kind, "visible", false])
		_ when name.begins_with("part/"):
			var bits := name.split("/")
			var kind: int = Wall.Part[bits[1].to_upper()]
			var near := bits.size() < 3 or bits[2] == "near"
			var far := bits.size() < 3 or bits[2] == "far"
			for m in main.find_children("*", "Node3D", true, false):
				if m is Masonry:
					for n: GeometryInstance3D in (m as Masonry).parts(kind, near, far):
						out.append([n, "visible", false])
		"wall_meshes":
			for w in main.find_children("*", "Node3D", true, false):
				for n in w.get_children() if w is Wall else []:
					if n is MeshInstance3D:
						out.append([n, "visible", false])
		_:
			assert(false, "layer: no layer %s" % name)
	for n in main.find_children("*", "GeometryInstance3D", true, false):
		var g := n as GeometryInstance3D
		if g.material_override == null or g.material_override not in materials:
			continue
		if g is MultiMeshInstance3D:
			out.append([(g as MultiMeshInstance3D).multimesh, "visible_instance_count", 0])
		else:
			out.append([g, "visible", false])
	return out


func _village(s: Dictionary) -> void:
	var tool: WallTool = main.tool
	var start := Time.get_ticks_usec()
	var r: float = s.radius * sqrt(_area)
	var step: float = s.spacing
	_lay_gables(s)
	_lay_materials(s)
	main.tool.thatch = s.get("thatch", false)
	var stood := tool.walls.size()
	var k := 0
	var fronts: Array[Dictionary] = []
	for z in range(-int(r / step), int(r / step) + 1):
		for x in range(-int(r / step), int(r / step) + 1):
			var c := Vector2(x, z) * step
			if c.length() > r - step * 0.5 or c.length() < s.get("inner", 0.0) * sqrt(_area):
				continue
			k += 1
			var yaw := PI * 0.5 * (k % 2)
			var at := main.world.terrain.ground(c.x, c.y)
			var on := PackedInt32Array()
			var entry: Dictionary = s.roofs[k % s.roofs.size()] if s.has("roofs") else {}
			var size := Vector2(0.7, 0.44) * step
			for storey in int(entry.get("storeys", s.get("storeys", 1))):
				var round: bool = entry.get("round", false)
				var stance := WallTool.stance(at, yaw, round)
				stance.size = Vector2.ONE * size.y if round else size
				stance.height = s.get("height", WallTool.HOUSE_HEIGHT)
				stance.curve = s.get("curve", 0.0)
				stance.rise = entry.get("rise", 0.0) if on.is_empty() else 0.0
				stance.pitch = entry.get("pitch", s.get("pitch", WallTool.pitch_for(stance)))
				var house := tool.new_house(stance, on)
				house.layout.foundation = WallLayout.Foundation[String(entry.get("foundation", "pillars")).to_upper()]
				_dress_roof(house, entry, size)
				if s.get("windows", false) and not round:
					_open_windows(house, k + storey, on.is_empty())
				if not main.world.fits({"op": "wall", "walls": [house.data()]}):
					house.free()
					break
				tool.build([house])
				if s.has("doors") and on.is_empty():
					var front := house.layout.points[0].lerp(house.layout.points[1], 0.5)
					fronts.append({"at": front, "out": ((front - at) * Vector3(1, 0, 1)).normalized(), "half": s.doors[k % s.doors.size()]})
				size *= entry.get("upper", 1.0)
				tool.walls[-1].ivy_age = INF
				on = PackedInt32Array([tool.walls[-1].id])
			if s.get("wings", false):
				var wing := at + Vector3.RIGHT.rotated(Vector3.UP, yaw) * step * 0.2
				wing = main.world.terrain.ground(wing.x, wing.z)
				var wing_at := WallTool.stance(wing, yaw)
				wing_at.size = Vector2(0.3, 0.6) * step
				wing_at.curve = s.get("curve", 0.0)
				wing_at.pitch = s.get("pitch", WallTool.pitch_for(wing_at))
				var wing_house := tool.new_house(wing_at)
				if main.world.fits({"op": "wall", "walls": [wing_house.data()]}):
					tool.build([wing_house])
					tool.walls[-1].ivy_age = INF
				else:
					wing_house.free()
	for n in fronts.size():
		var f := fronts[n]
		var path := PathLayout.new()
		path.seed = n + 1
		for i in 9:
			var p: Vector3 = f.at + f.out * lerpf(2.2, -1.0, i / 8.0)
			path.add(main.world.terrain.ground(p.x, p.z), f.half)
		main.world.submit({"op": "path", "path": path.data()})
	print("village: %d buildings in %.0f ms" % [tool.walls.size() - stood, (Time.get_ticks_usec() - start) / 1000.0])


## Opens windows round square house `house` in family `k` of WallLayout.WINDOW_FAMILIES: two on its front side either
## side of a door (cottage or arched in turn) when it stands on the `ground`, a fused pair on its back, one on each end,
## and a corner window between its first end and its back; a flat roof gets a trapdoor in its middle.
func _open_windows(house: Wall, k: int, ground: bool) -> void:
	var p := house.layout.points
	var front := Vector2(p[1].x - p[0].x, p[1].z - p[0].z).length()
	var end := Vector2(p[2].x - p[1].x, p[2].z - p[1].z).length()
	var family := WallLayout.WINDOW_FAMILIES[k % WallLayout.WINDOW_FAMILIES.size()]
	var y := WallLayout.lowest(family) + 0.15
	var openings := PackedVector4Array()
	if ground:
		openings.append(Vector4(front * 0.5, 0.0, WallLayout.Family.COTTAGE if k % 2 == 0 else WallLayout.Family.ARCHED, 1.0))
	for at in [front * 0.2, front * 0.8, front + end * 0.5, front * 1.5 + end - 0.45, front * 1.5 + end + 0.45, front * 2.0 + end * 1.5]:
		openings.append(Vector4(at, y, family, 1.0))
	openings.append(Vector4(front + end, WallLayout.lowest(WallLayout.Family.CORNER) + 0.15, WallLayout.Family.CORNER, 1.0))
	house.layout.openings.assign(Array(openings))
	if house.roof.flat():
		house.roof.hatches.assign([Vector2.ZERO])


## Lays `house`'s roof and top, `size` [along, across], as a village's `roofs` entry has them.
func _dress_roof(house: Wall, entry: Dictionary, size: Vector2) -> void:
	var r := house.roof
	r.deck = RoofLayout.Deck[entry.get("deck", "stone").to_upper()]
	r.overhang = entry.get("overhang", RoofLayout.OVERHANG)
	house.layout.top = WallLayout.Top[entry.get("top", "cap").to_upper()]
	var n := int(entry.get("dormers", 0))
	r.dormers.clear()
	for side in ([-1.0, 1.0] if n > 0 else []):
		for i in n:
			r.dormers.append(Vector2(((i + 0.5) / n - 0.5) * (size.x - 1.2), side * size.y))


func _clear(_s: Dictionary) -> void:
	for w in main.tool.walls.duplicate():
		main.world.submit({"op": "take", "of": "walls", "ids": PackedInt32Array([w.id])})
	await get_tree().process_frame


func _scatter(rng: RandomNumberGenerator, radius: float, centre := Vector3.ZERO) -> Vector3:
	return FloraLayout.brush(centre, radius, 1, rng, main.world.terrain.height_at)[0]


## The port of the garden a script visits: its `port`, else the --host-port launch argument.
func _host_port(s: Dictionary) -> int:
	return int(s.get("port", main.args.get("host-port", Session.PORT)))


## Joins the garden hosted at `address` on the host's port, as picking its figure does, until that garden has arrived.
func _join(s: Dictionary) -> void:
	var arrived := _arrival()
	main.session.join(s.get("address", "127.0.0.1"), _host_port(s))
	await _arrived(arrived)


## Set once the next garden arrives, so a step after a visit works in the garden visited, however late it comes.
func _arrival() -> Array:
	var arrived := [false]
	main.world.loaded.connect(func() -> void:
		if main.session.visiting.is_empty():
			push_error("driver: went home instead of arriving")
		else:
			arrived[0] = true, CONNECT_ONE_SHOT)
	return arrived


func _arrived(arrived: Array) -> void:
	while not arrived[0]:
		await get_tree().process_frame


## Hears `count` made-up gardens near, from documentation addresses no game answers on, each in a built-in avatar and
## colour under "Visitor <n>", every `unjoinable`th one from another build: the friends dial full without as many games.
func _neighbours(s: Dictionary) -> void:
	for i in int(s.count):
		var unjoinable := int(s.get("unjoinable", 0))
		main.session.nearby["192.0.2.1:%d" % (Session.PORT + i)] = {"address": "192.0.2.1", "port": Session.PORT + i, "key": 9000 + i,
			"avatar": i % Avatar.BUILT_IN.size(), "wears": "", "colour": Session.COLOURS[i % Session.COLOURS.size()],
			"name": "Visitor %d" % (i + 1), "joins": unjoinable == 0 or (i + 1) % unjoinable != 0, "seen": INF}
	main.session.changed.emit()
	await get_tree().process_frame


## Joins through the same wheel sweep and release as a player.
func _visit(s: Dictionary) -> void:
	var home: bool = s.get("home", false)
	var arrived := [true] if home else _arrival()
	var key := "home"
	if not home:
		var keys: Array = main.session.nearby.keys().filter(func(x: String) -> bool: return x.ends_with(":%d" % _host_port(s)))
		assert(not keys.is_empty(), "the requested garden has not been discovered")
		key = "join:" + str(keys[0])
	await _pick({"action": key})
	assert(not home or main.session.visiting.is_empty(), "driver: the wheel's home left this player visiting")
	await _arrived(arrived)


## Flat mode: holds the flat-screen control `action` (see Controls.FLAT) for `seconds`, and at least two frames so a slow
## frame cannot swallow the press, as its key or button would.
func _flat(s: Dictionary) -> void:
	var action: String = "flat_" + s.action
	Input.action_press(action)
	await _frames(2)
	await get_tree().create_timer(s.get("seconds", 0.1)).timeout
	Input.action_release(action)
	await _frames(2)


## Stands a player at each of `spots` [[x, z], ...], looking at the middle of the garden, in the VRM at `file`, a path
## under the player's files where it is relative (a built-in avatar without one), each posed again every frame with its hands swaying, as another player's streamed
## poses pose them; with "posture" each instead holds Posture's recorded poses in turn, a second and a fifth each, over
## what is under it, as another player's avatar reads them; [] takes them away. Prices another player's avatar on one
## headset, with no network in the way, and prints the main thread's microseconds per avatar pose when they go.
func _figures(s: Dictionary) -> void:
	if not _stood.is_empty():
		print("figures: %d %s avatars %s, %.1f us per avatar pose over %d frames" % [_stood.size(), _stood[0].source if _stood[0].source else "built-in", "lying and sitting in turn" if _posing else "standing", float(_posed_usec) / maxi(_posed_frames * _stood.size(), 1), _posed_frames])
	for a in _stood:
		a.queue_free()
	_stood.clear()
	_posing = s.get("posture", false)
	_posed_usec = 0
	_posed_frames = 0
	var path: String = s.get("file", "")
	var scene: PackedScene = Avatar.built_in(0)
	if path:
		var result := {}
		main.session._read(PackedByteArray(), path if path.is_absolute_path() else Main.player_path(path), func(_hash: String, _bytes: PackedByteArray, loaded: PackedScene) -> void: result.scene = loaded)
		while not result.has("scene"):
			await get_tree().process_frame
		scene = result.scene
	assert(scene != null, "driver: %s is not an avatar within the limits" % s.get("file"))
	for at: Array in s.spots:
		var a := Avatar.open(scene, Color.WHITE, path)
		var foot := main.world.terrain.ground(at[0], at[1])
		a.transform = Transform3D(Basis.looking_at(Vector3(-foot.x, 0, -foot.z)), foot)
		if _posing:
			a.ground = func(w: Vector3) -> float: return main.rig.floor_under.call(w)
		main.add_child(a)
		_stood.append(a)


func _process(_delta: float) -> void:
	var t := Time.get_ticks_msec() / 1000.0
	var start := Time.get_ticks_usec()
	for i in _stood.size():
		var eyes := Transform3D(Basis.IDENTITY, Vector3(0, _stood[i].eye_height, 0))
		if _posing:
			var held := Posture.held(1 + (int(t / 1.2) + i) % (Posture.poses.size() - 1), _stood[i].eye_height)
			_stood[i].pose(held[0], held[1], held[2])
		else:
			var sway := 0.1 * sin(t * 2.0 + i)
			_stood[i].pose(eyes, eyes * Avatar.AT_SIDES[0].translated(Vector3(0, sway, -0.3)), eyes * Avatar.AT_SIDES[1].translated(Vector3(0, -sway, -0.3)))
	if not _stood.is_empty():
		_posed_usec += Time.get_ticks_usec() - start
		_posed_frames += 1


## Turns the view to `at`, or to the figure of the host's garden with "figure", or to the eyes of the first other
## player with "player".
func _face(s: Dictionary) -> void:
	var to: Vector3
	if s.get("player", false):
		to = (main.session.avatars.values()[0] as Avatar).eyes.origin
	else:
		to = Vector3(s.at[0], s.at[1], s.at[2])
	main.view(main.rig.head.global_position, to, false)
	await _frames(2)


## Waits until the garden has applied command `seq`, `players` share it, `worn` of them show their own avatar files,
## `previewed` avatar files (this player's own included) stand ready for the picker, folder `files` have loaded,
## `wearing` names the folder file worn locally, `swimming` fish have come, with `fed`
## something eats from a held dish (`Main.fed`: "hand" this player's, "dish" another player's as shown here), the
## `digests` named have been written to the capture directory (by any player), with "frenzy" every fish of a pond some
## landed seeds lie on feeds, or with "heard" the host's beacon is heard, for at most `seconds`. Without `seconds` the
## wait has no limit: how long another player takes to start and catch up is the machine's load, not the script's.
func _until(s: Dictionary) -> void:
	var dir := str(main.args.get("capture-dir", "user://captures"))
	var t := 0.0
	_waiting = s
	while t < s.get("seconds", INF):
		var w: World = main.world
		var worn: int = main.session.avatars.values().filter(func(a: Avatar) -> bool: return a.source != "").size()
		var digested: bool = s.get("digests", []).all(func(n: String) -> bool: return FileAccess.file_exists(dir.path_join(n + ".json")))
		var selected: bool = not s.has("avatar") or (main.session.avatar == s.avatar and worn == 0 and main.session._looks.values().all(func(v: Array) -> bool: return v[0] == int(s.avatar)))
		var files_ready: bool = s.get("files", []).all(func(f: String) -> bool: return main.session.files.get(f, {}).get("scene") != null)
		var wearing: bool = not s.has("wearing") or (main.session.worn_key != "" and main.session.worn_key == main.session.files.get(s.wearing, {}).get("key", ""))
		if files_ready and wearing and selected and w.seq >= s.get("seq", 0) and main.session.players() >= s.get("players", 0) and worn >= s.get("worn", 0) and main.session.previews.values().filter(func(p: PackedScene) -> bool: return p != null).size() >= s.get("previewed", 0) and main.fish.swimming.size() >= s.get("swimming", 0) and (not s.has("fed") or main.fed(s.fed == "dish") > 0) and (not s.get("frenzy", false) or _frenzied()) and digested and (not s.get("heard", false) or main.session.nearby.keys().any(func(k: String) -> bool: return k.ends_with(":%d" % _host_port(s)))):
			_waiting = {}
			return
		await get_tree().process_frame
		t += get_process_delta_time()
	_waiting = {}
	push_error("driver: until %s timed out" % s)


func _frenzied() -> bool:
	var f := main.fish.frenzy()
	return f[1] > 0 and f[0] == f[1]


## Writes `World.digest`, where the sun stands, how many other players' avatars stand here, the hashes of their own files and the poses they show, and how many eat from held dishes, to `name`.json in the capture
## directory, for comparing machines.
func _digest(s: Dictionary) -> void:
	var path: String = main.capture_path(s.name + ".json")
	var out: Dictionary = main.world.digest()
	if s.get("ground", false):
		var h: Vector3 = main.rig.head.global_position
		out.ground = {"feet": main.rig.global_position.y, "terrain": main.world.terrain.height_at(h.x, h.z), "head": h.y, "x": h.x, "z": h.z, "yaw": rad_to_deg(main.rig.global_rotation.y), "held": [Hand.Tool.keys()[main.rig.left.tool], Hand.Tool.keys()[main.rig.right.tool]]}
	out.sun = main.look.time
	out.avatars = main.session.avatars.values().filter(func(a: Avatar) -> bool: return a.visible).size()
	out.avatar_choices = main.session._looks.values().map(func(v: Array) -> int: return v[0])
	out.avatar_choices.append(main.session.avatar)
	out.avatar_choices.sort()
	out.worn = main.session.avatars.values().map(func(a: Avatar) -> String: return a.source).filter(func(k: String) -> bool: return k != "")
	out.postures = main.session.avatars.values().map(func(a: Avatar) -> String: return Posture.poses[a.posture.target].name)
	out.fed = {"hand": main.fed(false), "dish": main.fed(true)}
	out.handfuls = main.feed_tool.handfuls.filter(func(h: Handful) -> bool: return h.landed()).map(func(h: Handful) -> Array: return [h.position.x, h.position.y, h.position.z])
	out.frenzy = main.fish.frenzy()
	FileAccess.open(path, FileAccess.WRITE).store_string(JSON.stringify(out, " ", true))
	print("driver: digest ", path)


## Samples a connected, settled session; ENet counters exclude discovery and IP/UDP headers.
## Frame processing time is Godot's elapsed main-thread time, not whole-process CPU usage.
func _network_sample(s: Dictionary) -> void:
	var peer: ENetMultiplayerPeer = multiplayer.multiplayer_peer
	var connection := peer.host
	connection.pop_statistic(ENetConnection.HOST_TOTAL_SENT_DATA)
	connection.pop_statistic(ENetConnection.HOST_TOTAL_RECEIVED_DATA)
	var start := Time.get_ticks_usec()
	var start_unix := Time.get_unix_time_from_system()
	var frames := 0
	var process_ms := 0.0
	var physics_ms := 0.0
	var players: int = main.session.players()
	while Time.get_ticks_usec() - start < s.get("seconds", 10.0) * 1000000.0:
		await get_tree().process_frame
		assert(main.session.players() == players, "peer left during network sample")
		process_ms += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		physics_ms += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		frames += 1
	var seconds := (Time.get_ticks_usec() - start) / 1000000.0
	var out := {"name": s.name, "players": players, "seconds": seconds, "frames": frames,
		"start_unix": start_unix, "end_unix": Time.get_unix_time_from_system(),
		"tx_bytes_s": connection.pop_statistic(ENetConnection.HOST_TOTAL_SENT_DATA) / seconds,
		"rx_bytes_s": connection.pop_statistic(ENetConnection.HOST_TOTAL_RECEIVED_DATA) / seconds,
		"process_ms_frame": process_ms / frames, "physics_ms_frame": physics_ms / frames}
	var path: String = main.capture_path(s.name + ".json")
	FileAccess.open(path, FileAccess.WRITE).store_string(JSON.stringify(out, " ", true))
	print("driver: network sample ", path)


## Takes a photo with the camera in `hand` (right by default), or with `tool` "selfie" the selfie camera, wherever its lens
## points, as pulling its trigger does, and waits until it is saved. With "view", the same lens's view as the headset draws it is captured
## first under that name, to set beside the photo.
func _photo(s: Dictionary) -> void:
	var hand := _holding(s, Hand.Tool[str(s.get("tool", "camera")).to_upper()])
	if s.has("view"):
		await main.capture(s.view, false, PhotoTool.lens(hand))
	await main.photo_tool.shoot(hand)


## Records a video with the camera in `hand` (right by default) for `seconds`, holding its trigger through the
## same edges the controller feeds, and waits until the file is written.
func _video(s: Dictionary) -> void:
	var hand := _holding(s, Hand.Tool[str(s.get("tool", "camera")).to_upper()])
	var key := "%s/%s" % [hand.tracker, Controls.input("tool", hand.tracker)]
	Buttons.injected[key] = true
	await get_tree().create_timer(s.seconds).timeout
	Buttons.injected.erase(key)
	await main.photo_tool.recorded


## Throws a handful of seeds from the dish in `hand` (right by default), or from `from` ([x, height over the ground, z]),
## at `velocity`, as pulling its trigger while swinging the hand at `velocity` does.
func _toss(s: Dictionary) -> void:
	var a: Array = s.get("velocity", [0, 0, 0])
	var v := Vector3(a[0], a[1], a[2])
	var f: Array = s.get("from", [])
	if f.size() == 3:
		main.feed_tool.throw(Vector3(f[0], f[1] + main.world.terrain.height_at(f[0], f[2]), f[2]), v)
		return
	var hand := _holding(s, Hand.Tool.SEEDS)
	main.feed_tool.throw(main.feed_tool.dish(hand), main.feed_tool.launch(hand, v))


## Turns the sky as a player does, until the sun stands at `time` (0 midnight, 0.5 noon; the short way round) over
## `seconds`: `hand` (right by default) beside the head grips open sky high off the sun's arc and turns its aim about the arc.
func _sun(s: Dictionary) -> void:
	var hand := _hand(s)
	var was := hand.global_transform
	var still := hand.held_still
	var axis := Daylight.RISE.cross(Daylight.ARC_UP)
	var grab := Daylight.toward_sun(0.5).rotated(Daylight.RISE, 0.25)
	var turn := wrapf(Daylight.angle(s.time) - Daylight.angle(main.look.time), -PI, PI)
	var head: Transform3D = main.rig.head.global_transform
	hand.held_still = true
	hand.global_transform = Transform3D(Basis.looking_at(grab), head * Vector3(0.18 if hand == main.rig.right else -0.18, -0.25, -0.3))
	var grip := "%s/%s" % [hand.tracker, Controls.input("grab", hand.tracker)]
	Buttons.injected[grip] = true
	await _frames(2)
	var seconds: float = s.get("seconds", 2.0)
	var t := 0.0
	while t < seconds:
		await get_tree().process_frame
		t += minf(get_process_delta_time(), seconds / 8.0)
		hand.global_basis = Basis.looking_at(grab.rotated(axis, turn * smoothstep(0.0, 1.0, minf(t / seconds, 1.0))))
	await _frames(2)
	Buttons.injected.erase(grip)
	await _frames(2)
	hand.global_transform = was
	hand.held_still = still


## The colour picker aimed from `from` (the head by default) at `at`, each [x, height above the ground, z], which must
## land on `element` (meadow, stone, roof, wood or plaster; the meadow needs no aim): opens its wheel on `hand`, twists
## to `swatch` over `seconds`, optionally captures the view with the wheel open, then lets go.
func _colour(s: Dictionary) -> void:
	var tool: PaletteTool = main.palette_tool
	var element: Palette.Element = Palette.Element[s.element.to_upper()]
	var target := tool.colour_target(element, Vector3.ZERO)
	if s.has("at"):
		target = tool.aim(_dial_from(s), _dial_dir(s))
	if target.get("element") != element:
		push_error("driver: colour aimed at %s, not %s" % [target, s.element])
		return
	await _dial(s, _holding(s, Hand.Tool.COLOUR), target, s.swatch)


## A tap of the colour tool's trigger on `hand`, aimed from `from` at `at` as `colour` aims: on a wall, house, tower or
## fence it takes that build's look, or lays the look taken on it; anywhere else it lets the look go.
func _tap(s: Dictionary) -> void:
	var tool: PaletteTool = main.palette_tool
	var hand := _holding(s, Hand.Tool.COLOUR)
	var target := tool.aim(_dial_from(s), _dial_dir(s))
	if target.is_empty():
		tool.tap(hand, "", -1)
	else:
		tool.open(hand, target)
		tool.close(hand)
	await get_tree().process_frame


## The style tool's trigger held on what it finds from `from` toward `at`, as `PaletteTool.aim_style` does
## (`restyle` names what that must be: a PaletteTool.Restyle, such as gable, roof, top, face or foundation), twisted round to choice `pick` over
## `seconds` and let go, as `colour` does.
## With `tree`, it is aimed instead at the meadow's own tree of that number, across its crown from `side` metres away.
func _style(s: Dictionary) -> void:
	var tool: PaletteTool = main.palette_tool
	var target := tool.aim_style(_dial_from(s), _dial_dir(s)) if not s.has("tree") else {}
	if s.has("tree"):
		var flora: Flora = main.flora_tool.flora
		var trunk: Flora.Plant = flora.groups[0][flora.meadow_trees()[s.tree]]
		var crown := trunk.foot() + Vector3.UP * 2.5
		var from := crown + Vector3(0, 1, s.get("side", 6.0))
		target = tool.aim_style(from, (crown - from).normalized())
	if target.get("restyle") != PaletteTool.Restyle[s.restyle.to_upper()]:
		push_error("driver: style aimed at %s, not %s" % [target, s.restyle])
		return
	await _dial(s, _holding(s, Hand.Tool.STYLE), target, s.pick)


func _dial_from(s: Dictionary) -> Vector3:
	return _spot(s, s.from[0], s.from[2]) + Vector3.UP * s.from[1] if s.has("from") else main.rig.head.global_position


func _dial_dir(s: Dictionary) -> Vector3:
	return (_spot(s, s.at[0], s.at[2]) + Vector3.UP * s.at[1] - _dial_from(s)).normalized()


func _dial(s: Dictionary, hand: Hand, target: Dictionary, to: int) -> void:
	var tool: PaletteTool = main.palette_tool
	tool.open(hand, target)
	var from: int = tool.wheels[hand].dial.start
	var turn := (to - from) * Dial.step(target.count)
	var t := 0.0
	var seconds: float = s.get("seconds", 1.0)
	while t < seconds:
		await get_tree().process_frame
		t += get_process_delta_time()
		tool.twist(hand, turn * minf(t / seconds, 1.0))
	if s.has("capture"):
		await main.capture(s.capture)
	tool.close(hand)
	await get_tree().process_frame


func _music(s: Dictionary) -> void:
	main.sound.play_from(s.section)


func _view(s: Dictionary) -> void:
	var pose := _pose(s)
	if pose.is_empty():
		return
	var origin: Vector3 = main.rig.head.global_position if s.get("relative", false) else Vector3.ZERO
	_eye = pose[0] + origin
	_at = pose[1] + (Vector3.ZERO if s.has("toward") else origin)
	main.view(_eye, _at, false)
	# A view is a cut, as a teleport is: no animal takes it for the player moving suddenly.
	main.rig.jumped.emit()
	await get_tree().process_frame


## Moves the view from the last `view` or `glide` to this one's `eye` and `at` over `seconds`, easing in and out.
func _glide(s: Dictionary) -> void:
	var pose := _pose(s)
	if pose.is_empty():
		return
	var from: Array[Vector3] = [_eye, _at]
	var seconds: float = s.seconds
	var t := 0.0
	while t < seconds:
		await get_tree().process_frame
		t += get_process_delta_time()
		var k := smoothstep(0.0, 1.0, minf(t / seconds, 1.0))
		_eye = from[0].lerp(pose[0], k)
		_at = from[1].lerp(pose[1], k)
		main.view(_eye, _at, false)


## A step's `eye` and `at`. With "subject", they are in the frame of the first node in that group (or its
## `index`th), as it stands now. With "ground", their heights count from the ground under each. With "toward",
## `at` is offset from the node in that group nearest the eye, so a view can turn to an animal that has moved
## without the eye moving.
func _pose(s: Dictionary) -> Array[Vector3]:
	var eye := Vector3(s.eye[0], s.eye[1], s.eye[2])
	var at := Vector3(s.at[0], s.at[1], s.at[2])
	if s.has("subject"):
		var found := get_tree().get_nodes_in_group(s.subject)
		if found.is_empty():
			push_error("driver: nothing in %s to view" % s.subject)
			failed = true
			return []
		var frame: Transform3D = found[s.get("index", 0)].global_transform
		if s.get("ground", false):
			frame.origin.y = 0.0
		eye = frame * eye
		at = frame * at
	if s.get("ground", false):
		eye.y += main.world.terrain.height_at(eye.x, eye.z)
		at.y += main.world.terrain.height_at(at.x, at.z)
	if s.has("toward"):
		var found := get_tree().get_nodes_in_group(s.toward)
		if found.is_empty():
			push_error("driver: nothing in %s to look toward" % s.toward)
			failed = true
			return []
		var eye_at: Vector3 = eye + (main.rig.head.global_position if s.get("relative", false) else Vector3.ZERO)
		found.sort_custom(func(a: Node3D, b: Node3D) -> bool: return a.global_position.distance_to(eye_at) < b.global_position.distance_to(eye_at))
		at += found[0].global_position
	return [eye, at]


## Moves the eye from `from` to `to` over `seconds`, looking `ahead` metres further along the way at `look` height.
func _walk(s: Dictionary) -> void:
	var from := Vector3(s.from[0], s.from[1], s.from[2])
	var to := Vector3(s.to[0], s.to[1], s.to[2])
	var dir := (to - from).normalized()
	var t := 0.0
	var seconds := float(s.seconds)
	while t < seconds:
		var eye := from.lerp(to, t / seconds)
		var at: Vector3 = eye + dir * float(s.get("ahead", 10.0))
		at.y = float(s.get("look", 0.0)) + main.world.terrain.height_at(at.x, at.z)
		eye.y += main.world.terrain.height_at(eye.x, eye.z)
		main.view(eye, at, false)
		await get_tree().process_frame
		t += get_process_delta_time()


## Sets an easel up at `x`, `z`, facing the head (or the ground point `facing`), as the easel tool's trigger does.
func _easel(s: Dictionary) -> void:
	var at := _spot(s, s.x, s.z)
	var toward: Vector3 = _spot(s, s.facing[0], s.facing[1]) if s.has("facing") else main.rig.head.global_position
	main.easel_tool.place(at, Easels.facing(at, toward), _hand(s))
	await _frames(2)


## Stands the hand mirror at the ground under `x`, `z`, its glass toward the head or the ground under `facing`; with
## "away", puts it away.
func _mirror(s: Dictionary) -> void:
	if s.get("away", false):
		main.mirror_tool.clear()
	else:
		var at := _spot(s, s.x, s.z)
		main.mirror_tool.stand_at(at, _spot(s, s.facing[0], s.facing[1]) if s.has("facing") else main.rig.head.global_position)
	await _frames(2)


## The easel a step works at: its `easel`th by age, the newest by default.
func _easel_of(s: Dictionary) -> Easels.Easel:
	var ids: Array = main.easels.easels.keys()
	ids.sort()
	return main.easels.find(ids[s.get("easel", -1)])


## Holds `hand` so its brush's tip is at `tip`, the brush pointing along `along`, turned `roll` about it, however the
## hand holds that brush (`ToolModels.hold`).
func _tip_at(hand: Hand, tip: Vector3, along: Vector3, up: Vector3, roll := 0.0) -> void:
	var basis := Basis.looking_at(along, up).rotated(along.normalized(), roll)
	hand.global_transform = Transform3D(basis, tip - basis * ToolModels.BRUSH_TIP) * ToolModels.hold(main.easel_tool.painter(hand).brush).affine_inverse()
	hand.held_still = true


## A grip at the easel's tray, as a player's hand closing there: takes a brush from the pot ("small", "big",
## "flat"), a stick of charcoal ("thin_stick", "stick", "thick_stick"), or a palette, the watercolour box ("box") or
## the oil palette ("palette"), which stays in the hand until a `set_down`. With `preview`, approaches the handle without closing the grip.
func _take(s: Dictionary) -> void:
	var hand := _hand(s)
	var e := _easel_of(s)
	var at: Vector3
	match s.what:
		"box":
			at = e.palettes[Brushwork.Medium.WATER].global_position
		"palette":
			at = e.palettes[Brushwork.Medium.OIL].global_position
		_:
			var kind: Brushwork.Brush = Brushwork.Brush[s.what.to_upper()]
			at = e.brushes[kind].global_transform * Easels.grip(kind)
	if s.get("preview", false):
		var offset := e.global_basis * Vector3(0, 0.04, 0.07)
		hand.global_transform = Transform3D(Basis.looking_at(-offset), at + offset)
		hand.held_still = true
		await _frames(2)
		return
	hand.global_transform = Transform3D(e.global_basis * Basis(Vector3.RIGHT, -0.6), at)
	hand.held_still = true
	var key := "%s/grip_click" % hand.tracker
	Buttons.injected[key] = true
	await _frames(2)
	Buttons.injected.erase(key)
	await _frames(2)


## A grip by the hand holding a palette, wherever that hand is, sends the palette back to its rest on the tray; done
## once it rests there.
func _set_down(s: Dictionary) -> void:
	var hand := _hand(s)
	hand.held_still = true
	var key := "%s/grip_click" % hand.tracker
	Buttons.injected[key] = true
	await _frames(2)
	Buttons.injected.erase(key)
	while not main.easel_tool.returning.is_empty():
		await _frames(1)
	await _frames(1)


## Checks that `hand` holds `what` (as EaselTool.holding names it) once its brush has had time to show, and that
## the brush it shows is the one it holds.
func _holds(s: Dictionary) -> void:
	var hand := _hand(s)
	await get_tree().create_timer(Hand.POP * 2.0).timeout
	var p: EaselTool.Painter = main.easel_tool.painter(hand)
	var now := EaselTool.holding(p)
	assert(now == s.what, "driver: %s holds %s, not %s" % [hand.tracker, now, s.what])
	var shown: Array = p.models.keys().filter(func(k: Brushwork.Brush) -> bool: return p.models[k].visible)
	var brush := hand.tool == Hand.Tool.EASEL and p.palette == null
	assert(shown == ([p.brush] if brush else []), "driver: %s holding %s shows brushes %s" % [hand.tracker, now, shown])


## Checks that every palette on the easel rests at its place on the tray, as this machine sees it, once those set
## down have arrived.
func _rests(s: Dictionary) -> void:
	var e := _easel_of(s)
	await _frames(1)
	while not main.easel_tool.returning.is_empty():
		await _frames(1)
	for kit: Brushwork.Medium in e.palettes:
		var node: Node3D = e.palettes[kit]
		var held: bool = main.easel_tool.painters.any(func(p: EaselTool.Painter) -> bool: return p.palette == e and p.kit == kit)
		assert(held or (not node.top_level and node.transform.is_equal_approx(Transform3D(Basis(), Easels.KITS[kit]))), "driver: the %s palette is not at its rest" % Brushwork.Medium.keys()[kit].to_lower())


## Holds the palette-holding hand where a painter holds it: beside the canvas, `at` in the easel's frame.
func _hold(s: Dictionary) -> void:
	var e := _easel_of(s)
	var hand := _hand(s)
	hand.global_transform = Transform3D(e.global_basis, e.global_transform * Vector3(s.at[0], s.at[1], s.at[2]))
	hand.held_still = true
	await _frames(2)


func _rag_wipe(s: Dictionary) -> void:
	var hand := _hand(s)
	var e := _easel_of(s)
	var at := Easels.RAG.get_center()
	var start := at + Vector3(-0.08, 0, 0)
	var end := start if s.get("dab", false) else at + Vector3(0.08, 0, 0)
	var path := [start + Vector3.UP * 0.08, start, end, end + Vector3.UP * 0.08]
	var steps := maxi(2, int(s.get("frames", 12)))
	for i in s.get("times", 1):
		for j in path.size() - 1:
			for k in steps:
				_tip_at(hand, e.tray(path[j].lerp(path[j + 1], float(k) / (steps - 1))), Vector3.DOWN, -e.global_basis.z)
				await _frames(1)


## Dips the brush in `hand` into the jar, or pigment `index` of the watercolour box ("pan") or the oil palette ("oil"),
## wherever that palette is, pushed `depth` metres on through it, and lifts it out.
func _dip(s: Dictionary) -> void:
	var hand := _hand(s)
	var e := _easel_of(s)
	var into: Vector3
	match s.what:
		"jar":
			into = e.tray(Easels.JAR + Vector3(0, Easels.JAR_SIZE.y * 0.4, 0))
		_:
			var kit: Brushwork.Medium = EaselTool.PAINTS.find_key(s.what)
			into = e.palettes[kit].global_transform * (Easels.well(kit, s.index) - Vector3(0, s.get("depth", 0.0), 0))
	_tip_at(hand, into + Vector3.UP * 0.08, (Vector3.DOWN - e.global_basis.z * 0.6).normalized(), -e.global_basis.z)
	await _frames(2)
	_tip_at(hand, into, (Vector3.DOWN - e.global_basis.z * 0.6).normalized(), -e.global_basis.z)
	await _frames(3)
	_tip_at(hand, into + Vector3.UP * 0.08, (Vector3.DOWN - e.global_basis.z * 0.6).normalized(), -e.global_basis.z)
	await _frames(2)


## A brushstroke on the oil palette's open board, wherever the palette is, as `_brush` paints the canvas, through
## `points` [x, z, pressure] (x toward the paint, z across, both -1..1 of the palette's half size).
func _mix(s: Dictionary) -> void:
	await _brushstroke(s, true)


## A brushstroke on the canvas through `points` [u, v, pressure] (u across, v down, both 0..1) over `seconds`.
func _brush(s: Dictionary) -> void:
	await _brushstroke(s, false)


## A brushstroke on the canvas, or with `palette` the oil palette's board, through `points` as `_brush` or `_mix` gives
## them: the tip comes in from off the surface, pushes each point's pressure's share of `Brushwork.PRESS_DEPTH` past its
## face (a stick's tip by its rim), and lifts off at the end, leaning `tilt` degrees and a flat brush turned `roll`.
func _brushstroke(s: Dictionary, palette: bool) -> void:
	var hand := _hand(s)
	hand.tool = Hand.Tool.EASEL
	var e := _easel_of(s)
	var frame := e.frame(palette)
	var roll := deg_to_rad(s.get("roll", 0.0))
	var direction := frame.basis * (Basis(Vector3.UP, deg_to_rad(s.get("tilt", 0.0))) * Vector3.FORWARD)
	var kind := main.easel_tool.painter(hand).brush
	var face: float = Brushwork.STICKS[kind].x if Brushwork.is_stick(kind) else 0.0
	var on := func(p: Array, out: float) -> Vector3:
		var depth: float = face - p[2] * Brushwork.PRESS_DEPTH
		var at := Vector2(p[0], -p[1]) * Easels.PALETTE_SIZE * 0.5 if palette else Vector2(p[0] - 0.5, 0.5 - p[1]) * Brushwork.METRES
		return frame * Vector3(at.x, at.y, depth + out)
	var pts: Array = s.points
	var before := frame.affine_inverse() * hand.global_position
	before.z = 0.6
	hand.global_position = frame * before
	await _frames(2)
	_tip_at(hand, on.call(pts[0], 0.4), direction, frame.basis.y, roll)
	await _frames(2)
	_tip_at(hand, on.call(pts[0], 0.05), direction, frame.basis.y, roll)
	await _frames(2)
	var frames := maxi(1, ceili(s.get("seconds", 1.0) * 60.0))
	for f in frames + 1:
		var k := float(f) / frames * (pts.size() - 1)
		var i := mini(floori(k), pts.size() - 2) if pts.size() > 1 else 0
		var a: Array = pts[i]
		var b: Array = pts[mini(i + 1, pts.size() - 1)]
		var t := k - i
		_tip_at(hand, on.call([lerpf(a[0], b[0], t), lerpf(a[1], b[1], t), lerpf(a[2], b[2], t)], 0.0), direction, frame.basis.y, roll)
		await _frames(1)
	if s.has("capture"):
		var hold := ToolModels.hold(kind)
		print("brush contact: tracked %s, visible %s" % [frame.affine_inverse() * hand.global_transform * hold * ToolModels.BRUSH_TIP, frame.affine_inverse() * hand.body.global_transform * hold * ToolModels.BRUSH_TIP])
		await main.capture(s.capture)
	_tip_at(hand, on.call(pts[-1], 0.05), direction, frame.basis.y, roll)
	await _frames(2)


## Takes the canvas's sheet in `hand` and pulls it `pull` metres off (enough tears it away), then lets go.
func _sheet(s: Dictionary) -> void:
	var hand := _hand(s)
	var e := _easel_of(s)
	var frame := e.canvas_frame()
	var key := "%s/grip_click" % hand.tracker
	hand.global_transform = Transform3D(frame.basis * Basis(Vector3.UP, PI), frame * Vector3(0, -0.3, 0.05))
	hand.held_still = true
	Buttons.injected[key] = true
	await _frames(1)
	var frames := maxi(1, ceili(s.get("seconds", 0.6) * 60.0))
	for f in frames:
		hand.global_transform = Transform3D(frame.basis * Basis(Vector3.UP, PI), frame * Vector3(0, -0.3, 0.05 + s.get("pull", 0.4) * (f + 1) / frames))
		await _frames(1)
	if s.has("capture"):
		await main.capture(s.capture)
	Buttons.injected.erase(key)
	await _frames(2)


## Puts a fresh sheet up on the easel, paints `strokes` strokes of `painting` on it, and with `palette` that many of
## `daubs` on its oil palette's board, and waits until both have replayed them as a kept painting.
func _painting(s: Dictionary) -> void:
	var e := _easel_of(s)
	main.world.submit({"op": "sheet", "easel": e.id, "strokes": []})
	for stroke: Dictionary in painting(int(s.strokes)):
		main.world.submit({"op": "paint", "easel": e.id, "stroke": stroke})
	for stroke: Dictionary in daubs(int(s.get("palette", 0))):
		main.world.submit({"op": "paint", "easel": e.id, "palette": true, "stroke": stroke})
	await _frames(2)
	main.easels.repaint(e.id, main.world.state.easels[e.id].strokes)
	main.easels.repaint(e.id, main.world.state.easels[e.id].palette, true)
	await _caught_up(s)


## Takes back this player's last step, as the undo button does whatever the hands hold.
func _undo(_s: Dictionary) -> void:
	main.world.undo()
	await _frames(1)


func _redo(_s: Dictionary) -> void:
	main.world.redo()
	await _frames(1)


## Waits until the easel's canvas and oil palette have caught up with their paint.
func _caught_up(s: Dictionary) -> void:
	var e := _easel_of(s)
	while e.canvas.catching_up() or e.board.catching_up():
		await _frames(1)


## `n` watercolour strokes across the canvas, half a second each, a third of a second apart: a kept painting as
## benches and tests replay it.
static func painting(n: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var out := []
	for k in n:
		var samples := PackedInt32Array()
		var from := Vector2(rng.randf_range(0.05, 0.6), rng.randf_range(0.05, 0.95))
		var to := from + Vector2(rng.randf_range(0.2, 0.35), rng.randf_range(-0.05, 0.05))
		for i in 15:
			samples.append_array(Brushwork.pack(from.lerp(to, i / 14.0), 0.8, 0.0, 0 if i == 0 else 2))
		var c: Color = Brushwork.PIGMENTS[1 + k % (Brushwork.PIGMENTS.size() - 1)]
		out.append({"medium": Brushwork.Medium.WATER, "brush": Brushwork.Brush.BIG, "colour": Brushwork.absorbance(c), "strength": 0.8, "load": 1.0, "gap": 20, "samples": samples})
	return out


## `n` oil strokes round an oil palette's open board, a big brush's fully loaded, each colour in turn: paint as a
## painter leaves a palette, as benches and tests replay it.
static func daubs(n: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var out := []
	for k in n:
		var samples := PackedInt32Array()
		var at := Vector2(rng.randf_range(-0.6, 0.75), rng.randf_range(-0.55, 0.55)) * Easels.PALETTE_SIZE * 0.5
		var heading := rng.randf() * TAU
		for i in 12:
			var point := at + Vector2.from_angle(heading + i * 0.25) * i * 0.004
			samples.append_array(Brushwork.pack(point / Canvas.metres_of(Easels.BOARD) + Vector2(0.5, 0.5), 0.9, 0.0, 0 if i == 0 else 2))
		var c: Color = Brushwork.PIGMENTS[k % Brushwork.PIGMENTS.size()]
		out.append({"medium": Brushwork.Medium.OIL, "brush": Brushwork.Brush.BIG, "colour": Brushwork.absorbance(c), "strength": 1.0, "load": 1.0, "gap": 0, "samples": samples})
	return out


## The player wears built-in avatar `avatar`, or the VRM at `file`, tinted `tint`.
func _wear(s: Dictionary) -> void:
	var bytes := FileAccess.get_file_as_bytes(s.file) if s.has("file") else PackedByteArray()
	var scene := Avatar.read(bytes) if s.has("file") else null
	assert(scene != null or not s.has("file"), "driver: %s is not an avatar within the limits" % s.get("file"))
	main.session.put_on.call_deferred(scene, Session.sha256(bytes) if s.has("file") else "", bytes, int(s.get("avatar", 0)), Color(s.get("tint", "#d9824b")))
	await _frames(2)


## Desktop only: holds the head and both hands where a person in Posture's pose `pose` had theirs, sized to the
## player's own avatar (Posture.held), on the ground at `x`, `z` (or `y` metres up), turned `yaw` degrees; `lift`
## (an adult's metres, sized as the pose is) raises the eyes and `lean` pitches them that many degrees about their own right, with the hands, to try a near
## miss. Over `seconds` it moves there from where the head and hands are, as a player lies down or sits.
func _posture(s: Dictionary) -> void:
	var rig: Rig = main.rig
	var which := Posture.poses.find_custom(func(q: Dictionary) -> bool: return q.name == s.pose)
	var eye_height: float = rig.body.eye_height if rig.body else Rig.EYE
	var points := Posture.held(which, eye_height)
	var eyes := points[0]
	var held: Array[Transform3D] = [points[1], points[2]]
	var lean := Transform3D(Basis(eyes.basis.x, deg_to_rad(s.get("lean", 0.0))), Vector3.ZERO)
	lean = Transform3D(Basis.IDENTITY, eyes.origin) * lean * Transform3D(Basis.IDENTITY, -eyes.origin)
	var x := float(s.get("x", 0.0))
	var z := float(s.get("z", 0.0))
	var frame := Transform3D(Basis(Vector3.UP, deg_to_rad(s.get("yaw", 0.0))), Vector3(x, float(s.get("y", main.world.terrain.height_at(x, z))) + s.get("lift", 0.0) * eye_height / Rig.EYE, z)) * lean
	var to: Array[Transform3D] = [frame * eyes, frame * held[0], frame * held[1]]
	var from: Array[Transform3D] = [rig.head.global_transform, rig.left.global_transform, rig.right.global_transform]
	var seconds := float(s.get("seconds", 0.0))
	var t := 0.0
	while true:
		var k := smoothstep(0.0, 1.0, minf(t / seconds, 1.0)) if seconds > 0.0 else 1.0
		rig.head.global_transform = from[0].interpolate_with(to[0], k)
		for i in 2:
			rig.hands[i].global_transform = from[i + 1].interpolate_with(to[i + 1], k)
			rig.hands[i].held_still = true
		if k >= 1.0:
			break
		await get_tree().process_frame
		t += get_process_delta_time()
	await _frames(2)


## Draws where each other player's head and hands are tracked, as their avatar receives them: a red ball at the eyes
## with a stalk ahead of them, a green ball at the left hand and a blue one at the right, seen through everything.
func _markers(_s: Dictionary) -> void:
	var balls: Array[MeshInstance3D] = []
	for c: Color in [Color.RED, Color.GREEN, Color.BLUE, Color.RED]:
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.no_depth_test = true
		mat.albedo_color = c
		var mi := MeshInstance3D.new()
		if balls.size() < 3:
			var sphere := SphereMesh.new()
			sphere.radius = 0.035
			sphere.height = 0.07
			mi.mesh = sphere
		else:
			var stalk := BoxMesh.new()
			stalk.size = Vector3(0.012, 0.012, 0.2)
			mi.mesh = stalk
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		balls.append(mi)
		add_child(mi)
	while is_inside_tree():
		var shown: Array = main.session.avatars.values().filter(func(a: Avatar) -> bool: return a.visible)
		for mi in balls:
			mi.visible = not shown.is_empty()
		if not shown.is_empty():
			var a: Avatar = shown[0]
			balls[0].global_position = a.eyes.origin
			balls[1].global_position = a.hands[0].origin
			balls[2].global_position = a.hands[1].origin
			balls[3].global_transform = a.eyes * Transform3D(Basis.IDENTITY, Vector3(0, 0, -0.1))
		await get_tree().process_frame


## Holds `hand` at `at`, pointing along `aim`, rolled `roll` degrees, all in head space, as a lesson poses it.
func _hold_pose(s: Dictionary) -> void:
	var hand := _hand(s)
	hand.global_transform = main.rig.head.global_transform * Lessons.frame({"at": Lessons._v(s.at), "aim": Lessons._v(s.aim).normalized(), "roll": s.get("roll", 0.0)})
	hand.held_still = true
	await _frames(2)


## Prints what the held book's live pages cost the GPU over `seconds`, from the renderer's timestamps around each
## viewport: each page's render and their share of a frame, beside the garden's own view.
func _page_cost(s: Dictionary) -> void:
	var b: Book = main.book
	var rd := RenderingServer.get_rendering_device()
	var pages := {}
	for page in b.scenes:
		RenderingServer.viewport_set_measure_render_time(b.scenes[page].get_viewport_rid(), true)
		pages[str(b.scenes[page].get_viewport_rid().get_id())] = page
	var main_id := str(get_viewport().get_viewport_rid().get_id())
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	var renders: Array[float] = []
	var views: Array[float] = []
	var total := 0.0
	var frames := 0
	var t := 0.0
	while t < s.seconds:
		await RenderingServer.frame_post_draw
		frames += 1
		var begin := {}
		for i in rd.get_captured_timestamps_count():
			var n := rd.get_captured_timestamp_name(i)
			var id := n.trim_prefix("vp_begin_").trim_prefix("vp_end_")
			if n.begins_with("vp_begin_"):
				begin[id] = rd.get_captured_timestamp_gpu_time(i)
			elif begin.has(id):
				var ms: float = (rd.get_captured_timestamp_gpu_time(i) - begin[id]) / 1e6
				if pages.has(id):
					renders.append(ms)
					total += ms
				elif id == main_id:
					views.append(ms)
		t += get_process_delta_time()
	renders.sort()
	views.sort()
	print("page_cost: %d frames, %d page renders, %.3f ms GPU a page render (median), %.3f ms a frame for the pages, the garden's view %.3f ms (median)" % [frames, renders.size(),
		renders[renders.size() / 2] if not renders.is_empty() else 0.0, total / maxi(frames, 1), views[views.size() / 2] if not views.is_empty() else 0.0])


## Looks at the held book's middle from `eye`, metres from it along the player's right, up and back.
func _view_book(s: Dictionary) -> void:
	var b: Book = main.book
	var shut := b.at == 0 and b._turn.is_empty()
	var mid := b.global_transform * Vector3(Book.W * 0.5 if shut else 0.0, 0.0, 0.0)
	_eye = mid + main.rig.global_basis * Lessons._v(s.eye)
	_at = mid
	main.view(_eye, _at, false)
	await get_tree().process_frame


## The picture book in the hand holding it: "open" it, "turn" a leaf on or "back", then wait `seconds`.
func _book(s: Dictionary) -> void:
	var b: Book = main.book
	match s.do:
		"open":
			b.open()
		"turn":
			b.turn(1)
		"back":
			b.turn(-1)
	await get_tree().create_timer(s.get("seconds", 1.0)).timeout


func _capture(s: Dictionary) -> void:
	await main.capture(s.name, s.get("screen", false))


func _quit(_s: Dictionary) -> void:
	main.finish()


## With "relative", x is metres to the head's right and z metres ahead of it, so a script works whichever way the headset faces.
func _spot(s: Dictionary, x: float, z: float) -> Vector3:
	if not s.get("relative", false):
		return main.world.terrain.ground(x, z)
	var head: Node3D = main.rig.head
	var fwd := -head.global_basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
	var right := fwd.cross(Vector3.UP)
	var p := head.global_position + right * x + fwd * z
	return main.world.terrain.ground(p.x, p.z)


## What the walls tool builds on at a ground spot: with "on", what a hand pointing straight down from above it
## hits, a build's top or the ground; else the ground.
func _target(s: Dictionary, p: Vector3) -> Dictionary:
	if s.get("on", false):
		var hit: Dictionary = main.tool.aim(p + Vector3.UP * 60.0, Vector3.DOWN)
		if not hit.is_empty():
			return hit
	return {"point": p, "on": -1}


func _path(s: Dictionary) -> Array[Vector3]:
	var path: Array[Vector3] = []
	for p in s.points:
		path.append(_spot(s, p[0], p[1]))
	return path


## The ground point `fraction` of the way along `path`.
func _along(path: Array[Vector3], fraction: float) -> Vector3:
	var d := 0.0
	for i in path.size() - 1:
		d += path[i].distance_to(path[i + 1])
	d *= fraction
	for i in path.size() - 1:
		var seg := path[i].distance_to(path[i + 1])
		if d <= seg:
			var p := path[i].lerp(path[i + 1], d / seg if seg > 0.0 else 0.0)
			p.y = main.world.terrain.height_at(p.x, p.z)
			return p
		d -= seg
	return path[-1]


## Holds the quality ladder at `step`, with "fit" at the fixed table's calibration step (Budget.fit_step), or with
## "held" where the governor stands now; without one, the governor walks it again.
func _quality(s: Dictionary) -> void:
	var step: Variant = s.get("step", -1)
	if step is String:
		main.quality.pin = {"fit": Budget.fit_step(), "held": main.quality.step()}[step]
	else:
		main.quality.pin = int(step)
	print("driver: quality pinned at %d" % main.quality.pin)


## Holds the view's anti-aliasing for measuring: `msaa` samples (0, 2, 4 or 8), `screen` ("none", "fxaa" or "smaa"),
## `foveation` 0 to 3 through the runtime's density map (XR_FB_foveation, which the Mobile renderer reads only with
## the view's VRS mode at XR), `unshaded`, which draws every surface its albedo alone, and `frozen`, which stops the wind
## so two shots of one view differ only by what changed. A key left out is left as is.
func _antialias(s: Dictionary) -> void:
	var vp: Viewport = main.get_viewport()
	if s.has("msaa"):
		vp.msaa_3d = {0: Viewport.MSAA_DISABLED, 2: Viewport.MSAA_2X, 4: Viewport.MSAA_4X, 8: Viewport.MSAA_8X}[int(s.msaa)]
	if s.has("screen"):
		vp.screen_space_aa = {"none": Viewport.SCREEN_SPACE_AA_DISABLED, "fxaa": Viewport.SCREEN_SPACE_AA_FXAA, "smaa": Viewport.SCREEN_SPACE_AA_SMAA}[s.screen]
	if s.has("foveation") and main.xr != null and main.metrics.info.xr:
		vp.vrs_mode = Viewport.VRS_XR if int(s.foveation) > 0 else Viewport.VRS_DISABLED
		main.xr.foveation_level = int(s.foveation)
		print("driver: foveation %d supported %s" % [main.xr.foveation_level, main.xr.is_foveation_supported()])
	if s.has("unshaded"):
		vp.debug_draw = Viewport.DEBUG_DRAW_UNSHADED if s.unshaded else Viewport.DEBUG_DRAW_DISABLED
	if s.has("frozen"):
		Engine.time_scale = 0.0 if s.frozen else 1.0


func _label(s: Dictionary) -> void:
	main.metrics.info.label = s.name


## Lays the `build` steps over the bare meadow as large as this headset holds them: while the dearest of `views` reads
## over the governor's line, the meadow is bared and they are laid again over the share of their area that
## would bring it under, so every phase of demo/costs.json is measured at the refresh rate, on any headset, from one
## script.
func _sized(s: Dictionary) -> void:
	var line := Budget.line_ms() * 0.95
	var base: Array[float] = []
	for v: Dictionary in s.views:
		base.append(await _gpu_ms(v))
	for attempt in 4:
		for b: Dictionary in s.build:
			await call("_" + b.op, b)
		await _standing()
		var share := 1.0
		var read: Array[float] = []
		for i in s.views.size():
			read.append(await _gpu_ms(s.views[i]))
			if read[i] > line:
				share = minf(share, maxf(line - base[i], 0.0) / (read[i] - base[i]))
		print("sized: area %.3f, %s ms over the bare %s" % [_area, read, base])
		if share == 1.0 or attempt == 3:
			break
		_area *= clampf(share * 0.9, 0.1, 0.9)
		await _bare({})
	_area = 1.0


## The viewport's mean GPU time a frame from `view`, once it has settled.
func _gpu_ms(view: Dictionary) -> float:
	await _view(view)
	await get_tree().create_timer(1.5).timeout
	var sum := 0.0
	var n := 0
	var until := Time.get_ticks_msec() + 1000
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame
		if main.quality.fresh:
			sum += main.quality.frame_ms
			n += 1
	return sum / n if n > 0 else 0.0


## Back to the bare meadow, as a long hold of the delete tool leaves it.
func _bare(_s: Dictionary) -> void:
	main.world.submit({"op": "wipe"})
	await _frames(3)


## With `bounded` false the garden takes builds past the frame budget, as the stress scene must; true holds it again,
## to `fill` of its room (all of it without).
func _budget(s: Dictionary) -> void:
	main.world.limit = s.get("fill", 1.0) if s.bounded else INF


func _units(_s: Dictionary) -> void:
	print("budget: %s units %s ms %.3f fill %.3f flora %s" % [main.metrics.info.label, JSON.stringify(main.world.units), Budget.cost_ms(main.world.units), main.world.fill(), JSON.stringify(_flora_units)])
	_flora_units = {}


func _stairs(s: Dictionary) -> void:
	var hand: Hand = main.rig.right
	hand.tool = Hand.Tool.STAIRS
	main.world.stairs.rail = s.get("rail", "stone")
	var a := Vector3(s.a[0], s.a[1], s.a[2])
	var b := Vector3(s.b[0], s.b[1], s.b[2])
	if s.get("ground", false):
		a.y += main.world.terrain.height_at(a.x, a.z)
		b.y += main.world.terrain.height_at(b.x, b.z)
	if s.get("on", false):
		a = _target(s, main.world.terrain.ground(a.x, a.z)).point
		b = _target(s, main.world.terrain.ground(b.x, b.z)).point
	main.stair_tool.begin(hand, a, s.get("width", StairTool.WIDTH))
	var frames := maxi(1, int(s.get("seconds", 1.0) * 30.0))
	for i in frames:
		main.stair_tool.extend(hand, a.lerp(b, float(i + 1) / frames))
		await get_tree().create_timer(1.0 / 30.0).timeout
	main.stair_tool.end(hand)


## Fills the stair allowance without changing whether later scripted builds are bounded.
func _stair_field(_s: Dictionary) -> void:
	main.world.submit({"op": "wipe"})
	await _sculpt({"x": 5.0, "z": -6.0, "lift": 2.0, "seconds": 0.2})
	await _pave({"points": [[5, -2.5], [5, -6]], "radius": 0.8, "seconds": 0.2})
	var placed := 0
	for row in 9:
		for col in 9:
			var a := main.world.terrain.ground((col - 4) * 3.5, (row - 4) * 6.0)
			var d := {"a": a, "b": a + Vector3(0, 2.4, -4), "width": 1.2, "sag": 0.0, "rail": "stone" if col % 2 == 0 else "wood", "seed": row * 9 + col, "paint": Palette.plain(), "on": PackedInt32Array()}
			if col % 3 == 1:
				d.b = a + Vector3(0, 3, -1)
			elif col % 3 == 2:
				d.b = a + Vector3(0, 0, -4)
			if not Budget.fits(main.world.units, main.world.change_of({"op": "stairs", "stairs": d})):
				print("stairs: budget full at %d builds, fill %.3f" % [placed, main.world.fill()])
				return
			main.world.submit({"op": "stairs", "stairs": d})
			placed += 1
			await get_tree().process_frame
	assert(false, "stair field did not fill the budget")


## Four rigged eaters (the largest visiting band), with the same clips on both sides of the CPU measurement.
func _neck_cost(s: Dictionary) -> void:
	var animals: Array[Beast] = []
	var dishes: Array[Dish] = []
	for i in 4:
		var animal := Beast.new(Beast.Kind.FOX if i == 3 else Beast.Kind.DEER, 1.0, i * 0.2)
		add_child(animal)
		animal.set_process(false)
		animal.neck.active = false
		var dish := Dish.new()
		add_child(dish)
		dish.visible = true
		var at := main.world.terrain.ground(12.0 + i * 1.8, 0)
		dish.position = at + Vector3(0, 0.25 if i == 3 else [0.4, 0.8, 1.05][i], 0)
		animal.position = at
		animal.position.z += Hand.TOP.z + animal.neck.stand_off(animal, dish)
		animal.eat(dish.position.y - at.y, 0.0)
		animal.neck.offer = dish
		animal.neck.amount = 1.0
		animals.append(animal)
		dishes.append(dish)
	var elapsed := 0.0
	var samples: Array[float] = []
	var solving: bool = s.get("solve", true)
	while elapsed < s.get("seconds", 10.0):
		await get_tree().process_frame
		elapsed += get_process_delta_time()
		for dish in dishes:
			dish.position.z = sin(elapsed * 0.7) * 0.02
		var start := Time.get_ticks_usec()
		if solving:
			for animal in animals:
				animal.neck._process_modification()
		samples.append((Time.get_ticks_usec() - start) / 1000.0)
	samples.sort()
	print("neck_cost: solve=%s, four animals, %d frames, CPU median %.4f ms, p95 %.4f ms, max %.4f ms" % [solving, samples.size(), samples[samples.size() / 2], samples[int(samples.size() * 0.95)], samples[-1]])
	for animal in animals:
		animal.queue_free()
	for dish in dishes:
		dish.queue_free()


func _held_snapshot(s: Dictionary) -> void:
	await get_tree().create_timer(Hand.POP * 3.0).timeout
	var items := [HeldItem.describe(main.rig.left, main.easel_tool, main.book), HeldItem.describe(main.rig.right, main.easel_tool, main.book), HeldItem.perched(main.rig, 0), HeldItem.perched(main.rig, 1)]
	if s.get("loaded", false):
		assert(items[1].size() == 8 and items[1][0] == HeldItem.Kind.BRUSH and items[1][4] > 0.0, "capture holds a loaded brush")
	var path: String = main.capture_path(s.name)
	FileAccess.open(path + ".held", FileAccess.WRITE).store_var([multiplayer.get_unique_id(), items])
	FileAccess.open(path + ".json", FileAccess.WRITE).store_string(JSON.stringify({"held": items.map(HeldItem.label)}))


func _remote_holds(s: Dictionary) -> void:
	var path: String = main.capture_path(s.name)
	var expected: Array = FileAccess.open(path + ".held", FileAccess.READ).get_var()
	var elapsed := 0.0
	while elapsed < 30.0:
		await get_tree().process_frame
		elapsed += get_process_delta_time()
		if not main.session.held.has(expected[0]):
			continue
		var pair: Array = main.session.held[expected[0]]
		var matches := true
		var avatar: Avatar = main.session.avatars[expected[0]]
		for side in 4:
			var item: HeldItem = pair[side]
			matches = matches and HeldItem.same(item.state, expected[1][side])
			if item.state.is_empty():
				matches = matches and item.model == null
			else:
				matches = matches and item.model != null and item.model.is_visible_in_tree() and item.model.transform.is_equal_approx(item.state[2])
				matches = matches and item.transform.is_equal_approx(avatar.hands[side] if side < 2 else Torso.frame(avatar.eyes, avatar.torso))
				matches = matches and (side >= 2 or avatar.folded(side) == item.replaces_hand())
				if item.state[0] == HeldItem.Kind.BRUSH and not Brushwork.is_stick(item.state[1]):
					var tip := (item.model.get_node("tip") as MeshInstance3D).material_override as ShaderMaterial
					var colour: Color = tip.get_shader_parameter("paint_colour")
					matches = matches and colour.is_equal_approx(item.state[3]) and is_equal_approx(tip.get_shader_parameter("load"), item.state[4])
		if matches:
			print("held: peer sees %s in the other player's hands and on their shoulders" % str(expected[1].map(HeldItem.label)))
			return
	assert(false, "remote held models differ from holder: " + s.name)


static func held_states(birds: bool = false) -> Array:
	var states: Array = []
	for tool in Hand.Tool.values():
		if tool not in Hand.UNMODELLED:
			states.append([HeldItem.Kind.TOOL, tool, Transform3D(Basis(), Hand.TOP), Color.WHITE, 0.0, 0, false, Vector3.ZERO])
	states.append([HeldItem.Kind.PALETTE, Brushwork.Medium.OIL, Transform3D(), Color.WHITE, 0.0, 1, false, Vector3.ZERO])
	states.append([HeldItem.Kind.PALETTE, Brushwork.Medium.WATER, Transform3D(), Color.WHITE, 0.0, 1, false, Vector3.ZERO])
	for brush in Brushwork.Brush.values():
		states.append([HeldItem.Kind.BRUSH, brush, Transform3D(), Color(0.15, 0.3, 0.65), 1.0, 0, false, Vector3.ZERO])
	states.append([HeldItem.Kind.BOOK, 1, Book.local(1.0), Color.WHITE, 0.0, 0, false, Vector3.ZERO])
	if birds:
		states = [[HeldItem.Kind.BIRD, 0, BirdCarry.HOLD, Color.WHITE, 0.0, 0, false, Vector3.ZERO]]
	return states


## The maximum seven peers' fourteen held models, close enough to fill the view, through the live renderer.
## `shown` false keeps them in place hidden, and `label` names the phase, for a pair without them; `capture` saves the view
## before the phase starts.
func _held_cost(s: Dictionary) -> void:
	var items: Array[HeldItem] = []
	var eye: Transform3D = main.rig.head.global_transform
	for i in (Session.MAX_PLAYERS - 1) * 2:
		var item := HeldItem.new()
		item.terrain = main.world.terrain
		add_child(item)
		item.global_transform = eye * Transform3D(Basis(), Vector3((i % 7 - 3) * 0.2, (i / 7 - 0.5) * 0.35, -0.8))
		items.append(item)
	var states := held_states(s.get("birds", false))
	for state in states:
		assert(HeldItem.valid(state), "invalid stress state: " + HeldItem.label(state))
		for item in items:
			item.show_state(state)
			item.visible = s.get("shown", true)
			if s.get("without_cup", false) and item.model is Conure:
				for child in item.model.get_children():
					(child as Node3D).hide()
		# Every item's models are built in one frame, which no player does, and the runtime runs at half rate for a
		# moment after it.
		await get_tree().create_timer(1.0).timeout
		if s.has("capture"):
			await main.capture(s.capture)
		var name := HeldItem.label(state) + ("-without-cup" if s.get("without_cup", false) else "")
		var label := {"op": "label", "name": s.get("label", "held/" + name.replace(" ", "-"))}
		print("driver: ", label)
		await _label(label)
		await get_tree().create_timer(s.get("seconds", 3.0)).timeout
		var end := {"op": "label", "name": "-"}
		print("driver: ", end)
		await _label(end)
	for item in items:
		item.queue_free()


## Offers seeds beside an existing bird, waits for earned trust, then closes the grip.
func _befriend(s: Dictionary) -> void:
	var h := _hand(s)
	var flock: Birds = main.wildlife.birds
	var elapsed := 0.0
	while flock.birds.is_empty() and elapsed < 240.0:
		await get_tree().process_frame
		elapsed += get_process_delta_time()
	assert(not flock.birds.is_empty(), "no conure arrived")
	var available := flock.birds.filter(func(b: Birds.Bird) -> bool: return not b.carried)
	assert(not available.is_empty(), "no free bird")
	var bird: Birds.Bird = available[0]
	while bird.state != Birds.State.PERCH and elapsed < 260.0:
		await get_tree().process_frame
		elapsed += get_process_delta_time()
	assert(bird.state == Birds.State.PERCH, "bird did not land")
	h.tool = Hand.Tool.SEEDS
	h.held_still = true
	h.global_transform = Transform3D(Basis.IDENTITY, bird.node.global_position + Vector3(0.2, -0.15, 0.2))
	elapsed = 0.0
	while elapsed < 90.0:
		await get_tree().process_frame
		elapsed += get_process_delta_time()
		var fed := flock.birds.filter(func(b: Birds.Bird) -> bool: return b.node.hand == h and b.state == Birds.State.FEED and b.affection >= BirdCarry.TRUST)
		if not fed.is_empty():
			bird = fed[0]
			break
	if bird.node.hand != h or bird.affection < BirdCarry.TRUST or bird.state != Birds.State.FEED:
		push_error("bird did not feed and trust hand")
		main.finish()
		return
	Buttons.injected["%s/%s" % [h.tracker, Controls.input("grab", h.tracker)]] = true
	await _frames(30)
	if h.carried != bird.node:
		push_error("grip did not pick up fed bird")
		main.finish()
		return
	print("conure: feeding earned trust, grip carries bird")


## Waits for a conure that trusts this player to come to their shoulder; with `trust`, the first to perch is given the
## trust feeding would earn, and with no conure bound for a perch near enough to follow the player a flock is brought to
## the perch nearest them. With `look`, the head then turns to that shoulder as far as a neck turns and looks down at it.
func _shoulder_bird(s: Dictionary) -> void:
	var flock: Birds = main.wildlife.birds
	var elapsed := 0.0
	var head := main.rig.head.global_position
	while elapsed < 120.0:
		# A conure bound near may perch further off before it comes, out of reach of the player it would follow.
		if not flock.birds.any(func(b: Birds.Bird) -> bool: return b.to.distance_to(head) < Birds.FOLLOW_FROM):
			flock.look()
			var nearest: Birds.Site = null
			var reach := Birds.FOLLOW_FROM
			for site in flock.sites:
				for p in site.points():
					if p.distance_to(head) < reach:
						reach = p.distance_to(head)
						nearest = site
			assert(nearest != null, "no perch near enough for a conure to follow the player")
			flock.arrive(nearest)
		if s.get("trust", false):
			for b in flock.birds:
				if b.state == Birds.State.PERCH:
					b.affection = BirdCarry.TRUST
		var side: int = main.rig.shoulders.find_custom(func(c: Conure) -> bool: return c != null)
		if side >= 0:
			print("conure: rides the player's shoulder")
			if s.get("look", false):
				var yaw: float = main.rig.torso().basis.get_euler().y - main.rig.global_basis.get_euler().y
				main.rig.head.transform.basis = Basis.from_euler(Vector3(-0.6, yaw + Torso.TURN * (1.0 if side == 0 else -1.0), 0))
			return
		var was := elapsed
		await get_tree().process_frame
		elapsed += get_process_delta_time()
		if was < 20.0 and elapsed >= 20.0:
			for b in flock.birds:
				print("conure: %s, affection %.2f, away %.1f s, %.1f m off, asleep %s, head under water %s" % [Birds.State.keys()[b.state], b.affection, b.away, b.node.position.distance_to(main.rig.head.global_position), main.wildlife.asleep(), main.rig.under])
	assert(false, "no conure came to the shoulder")


## Carries the bird to the canvas and sweeps its feathers across it, then lifts away.
func _bird_smear(s: Dictionary) -> void:
	var h := _hand(s)
	assert(h.carried != null, "no held bird")
	var e := _easel_of(s)
	var frame := e.canvas_frame()
	var basis := frame.basis
	var from := h.global_transform
	var target := Transform3D(basis, frame * Vector3(-0.25, 0, 0.09) - basis * (BirdCarry.HOLD.origin + Conure.BODY))
	var approach := 0.0
	while approach < 0.6:
		await get_tree().process_frame
		approach += get_process_delta_time()
		h.global_transform = from.interpolate_with(target, smoothstep(0.0, 0.6, approach))
	await _frames(2)
	var seconds: float = s.get("seconds", 3.0)
	var t := 0.0
	while t < seconds:
		await get_tree().process_frame
		t += get_process_delta_time()
		var along := t / seconds
		h.global_transform = Transform3D(basis, frame * Vector3(lerpf(-0.25, 0.25, along), along * 0.18, 0.018) - basis * (BirdCarry.HOLD.origin + Conure.BODY))
	h.global_position += frame.basis.z * 0.2
	await _frames(30)
	print("conure: wet canvas smear submitted")


## Shows or hides the bird the step's hand carries, cup included, leaving the hand, the carry and any smear running:
## the paired fixture's way of taking the bird alone out of a view.
func _bird_shown(s: Dictionary) -> void:
	var h := _hand(s)
	assert(h.carried != null, "no held bird")
	h.carried.visible = s.shown
	await _frames(2)


func _view_held(s: Dictionary) -> void:
	var h := _hand(s)
	assert(h.carried != null)
	h.global_transform = Transform3D(Basis.IDENTITY, main.world.terrain.ground(1.5, 2.0) + Vector3.UP * 1.4)
	await _frames(30)
	var at := h.carried.global_position + Vector3.UP * 0.07
	var hand_pose := h.global_transform
	main.view(at + Vector3(0.25, 0.13, -0.36), at, false)
	h.global_transform = hand_pose
	await _frames(30)


## Brings every frog, snake, squirrel and owl their habitats draw now, as each kind would in its own time, so the views
## of them do not hang on when they happen to come.
func _shy(_s: Dictionary) -> void:
	main.wildlife.birds.look()
	main.wildlife.squirrels.look()
	for kind in main.wildlife.shy():
		kind.fill()
	await get_tree().process_frame


## Brings a band of deer and the fox to the meadow's rim now where none is there, as Roamers does in its own time, and
## waits until one of each stands in the garden, so the views of them do not hang on when they happen to come.
func _roamers(_s: Dictionary) -> void:
	var roamers: Roamers = main.wildlife.roamers
	for kind: Beast.Kind in Roamers.FIRST:
		while get_tree().get_nodes_in_group(Beast.GROUPS[kind]).is_empty():
			if not roamers.bands.any(func(b: Grazers.Band) -> bool: return (b.animals[0] as Beast).kind == kind):
				roamers.arrive(kind)
			await get_tree().process_frame


func _release_bird(s: Dictionary) -> void:
	var h := _hand(s)
	Buttons.injected.erase("%s/%s" % [h.tracker, Controls.input("grab", h.tracker)])
	await _frames(2)
	assert(h.carried == null, "bird must leave the hand when grip releases")


func _spring_grab(s: Dictionary) -> void:
	var remote: bool = s.get("remote", false)
	var avatar: Avatar = main.session.avatars.values()[0] if remote and not main.session.avatars.is_empty() else main.rig.body
	var chain: int = s.get("chain", 0)
	if avatar.springs == null or chain >= avatar.springs.chains.size():
		push_error("spring: no chain to grab")
		failed = true
		return
	await _pick({"hand": "right", "tool": "none"})
	var hand := main.rig.right
	hand.held_still = true
	hand.global_position = avatar.springs.tip(chain)
	await get_tree().create_timer(0.3).timeout
	var key := "right_hand/" + Controls.input("grab", "right_hand")
	Buttons.injected[key] = true
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		var holders: Dictionary = avatar.spring_holders if remote else main.session._spring_holds
		if holders.get(chain) == [main.session.multiplayer.get_unique_id(), 1]:
			break
		await get_tree().process_frame
	var holders: Dictionary = avatar.spring_holders if remote else main.session._spring_holds
	if holders.get(chain) != [main.session.multiplayer.get_unique_id(), 1]:
		Buttons.injected.erase(key)
		failed = true
		push_error("spring: owner did not accept grip")
		return
	var from := hand.global_position
	var move := Vector3(s.move[0], s.move[1], s.move[2])
	var elapsed := 0.0
	var seconds: float = s.get("seconds", 3.0)
	var travelled := 0.0
	while elapsed < seconds:
		await get_tree().process_frame
		elapsed += get_process_delta_time()
		hand.global_position = from + move * sin(minf(elapsed / seconds, 1.0) * PI * 0.5)
		travelled = maxf(travelled, from.distance_to(avatar.springs.tip(chain)))
	Buttons.injected.erase(key)
	await get_tree().create_timer(1.0).timeout
	if travelled < 0.025:
		failed = true
		push_error("spring: grip did not move the tip")
	print("spring: %s grip travelled %.4f m and released" % ["remote" if remote else "wearer", travelled])


func _spring_watch(s: Dictionary) -> void:
	var seconds: float = s.get("seconds", 60.0)
	var deadline := Time.get_ticks_msec() + int(seconds * 1000)
	var held := false
	var moved := 0.0
	var first := Vector3.ZERO
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		var active := main.session._spring_holds.values().any(func(holder: Array) -> bool: return holder[0] != main.session.multiplayer.get_unique_id())
		if active:
			var tip: Vector3 = main.rig.body.springs.tip(0)
			if not held:
				first = tip
			moved = maxf(moved, tip.distance_to(first))
			held = true
		elif held:
			print("spring: wearer observed remote grab, %.4f m movement, release" % moved)
			if moved < 0.025:
				failed = true
			return
	failed = true
	push_error("spring: wearer never observed a remote grab and release")


func _spring_sway(s: Dictionary) -> void:
	var before: int = main.rig.body.springs.contacts
	var eye := main.rig.head.global_position
	var ahead := -main.rig.head.global_basis.z
	var elapsed := 0.0
	var seconds: float = s.get("seconds", 3.0)
	while elapsed < seconds:
		await get_tree().process_frame
		elapsed += get_process_delta_time()
		var offset := Vector3(sin(elapsed * TAU) * 0.3, 0, 0)
		main.view(eye + offset, eye + offset + ahead, false)
	main.view(eye, eye + ahead, false)
	var contacts: int = main.rig.body.springs.contacts - before
	print("spring: sway resolved %d collider contacts" % contacts)
	if contacts == 0:
		failed = true
		push_error("spring: sway never contacted the declared collider")


func _spring_ready(_s: Dictionary) -> void:
	var deadline := Time.get_ticks_msec() + 90000
	var held := false
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		if main.session.avatars.is_empty():
			continue
		var avatar: Avatar = main.session.avatars.values()[0]
		if not avatar.spring_holders.is_empty():
			held = true
		elif held:
			await get_tree().create_timer(1.0).timeout
			return
	failed = true
	push_error("spring: peer never observed wearer grip and release")


## Looks at chain "chain" (0 if unsaid) of the first other player's avatar from that avatar's left, level with the
## middle of the chain and its head.
func _spring_view(s: Dictionary) -> void:
	await get_tree().create_timer(2.0).timeout
	var avatar: Avatar = main.session.avatars.values()[0]
	var middle := (avatar.eyes.origin + avatar.springs.tip(s.get("chain", 0))) * 0.5
	main.view(middle - avatar.eyes.basis.x * 0.8, middle, false)
	await _frames(2)


## Exercises expressions through the same wheel, wrist and stick input as a player. The fixture is generated here.
func _expression(s: Dictionary) -> void:
	if s.get("fixture", false):
		main.rig.wear(Avatar.open(preload("res://demo/expressions.gd").scene(), Color.WHITE, "expression-demo"))
		main.rig.body.expressions.state.restore({"Hat": 0.0, "Size": 0.5, "Colour": 0.0, "Tone": 0.0, "Decal": 0.0})
		await _frames(2)
		return
	var hand := _hand(s)
	var button := "%s/%s" % [hand.tracker, Controls.input("wheel", hand.tracker)]
	var tree := hand.inventory()
	Hand.injected_reach[hand.tracker] = Vector2.ZERO
	Buttons.injected[button] = true
	await _frames(2)
	for p in ToolWheel.sweep(tree, ToolWheel.paths(tree)[s.get("slot", "expressions")]):
		Hand.injected_reach[hand.tracker] = p
		await _frames(2)
	if s.get("slot", "expressions") == "expressions":
		Hand.injected_reach[hand.tracker] = Vector2.ZERO
	await _frames(2)
	for index: int in s.get("controls", []):
		Hand.injected_reach[hand.tracker] = ToolWheel.ring_dirs()[index] * ToolWheel.RADIUS
		await _frames(1)
		if hand.expressions != null and (hand._wheel == null or hand._wheel.chosen() == null):
			Hand.injected_reach[hand.tracker] = Vector2.ZERO
		await _frames(2)
	var puppet := hand.expressions != null and not hand.expressions.puppet.is_empty()
	if puppet:
		Buttons.injected.erase(button)
		await _frames(2)
	var from := hand.global_basis
	if s.has("twist"):
		for f in 30:
			hand.global_basis = Basis(-from.z, deg_to_rad(float(s.twist) * (f + 1) / 30.0)) * from
			await _frames(1)
	if s.has("stick"):
		Hand.injected_sticks["right_hand"] = Vector2(s.stick[0], s.stick[1])
	if s.has("label"):
		main.metrics.info.label = s.label
	await get_tree().create_timer(s.get("seconds", 1.0)).timeout
	if s.has("capture"):
		await main.capture(s.capture)
	if puppet:
		Buttons.injected[button] = true
		await _frames(2)
	Buttons.injected.erase(button)
	await _frames(2)
	Hand.injected_reach.erase(hand.tracker)
	Hand.injected_sticks.erase("right_hand")
	hand.global_basis = from
	await _frames(2)


## Sweeps the empty right hand back and forth through the middle joint of chain "chain" (0 if unsaid) of the first
## other player's avatar with "remote", else the wearer's own, along that avatar's facing and on its left, where
## spring_view looks from, for "seconds", and fails unless the chain's tip moves.
func _spring_poke(s: Dictionary) -> void:
	var avatar: Avatar = main.session.avatars.values()[0] if s.get("remote", false) else main.rig.body
	var chain: Dictionary = avatar.springs.chains[s.get("chain", 0)]
	await _pick({"hand": "right", "tool": "none"})
	var hand := main.rig.right
	hand.held_still = true
	var through: Vector3 = chain.joints[chain.joints.size() / 2].node.global_position
	var rest := avatar.springs.tip(s.get("chain", 0))
	var seconds: float = s.get("seconds", 4.0)
	var elapsed := 0.0
	var moved := 0.0
	while elapsed < seconds:
		hand.global_position = through - avatar.eyes.basis.x * 0.03 - avatar.eyes.basis.z * 0.15 * cos(elapsed / seconds * 2.0 * TAU)
		await get_tree().process_frame
		elapsed += get_process_delta_time()
		moved = maxf(moved, rest.distance_to(avatar.springs.tip(s.get("chain", 0))))
	hand.global_position = through - avatar.eyes.basis.x * 0.4
	await get_tree().create_timer(1.0).timeout
	print("spring: poke moved the tip %.4f m" % moved)
	if moved < 0.02:
		failed = true
		push_error("spring: poke did not move the tip")
