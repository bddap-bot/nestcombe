class_name Rig
extends XROrigin3D

## The player: head, two hands, and locomotion by teleport — onto the ground or into the air to float.
## The left stick pushed forward aims from the left hand whatever it holds, so no choice of tools leaves the player
## unable to move; how far forward it is pushed sets how far along the aim the target lies. Flicked sideways it
## snap-turns, and flicked back it turns the player round.

## The eyes' near clip, in real metres: at 5 cm a face leaned in to a conure cut it open, and its far side, culled from inside,
## left nothing. Godot's reversed depth keeps far stone and paving apart at this near.
const NEAR := 0.02
## Past the farthest range round the garden (Mountains) and the sun's disc beyond it.
const FAR := 2600.0
## A typical wearer's eye height over the floor standing, in real metres, until `stature` has measured theirs.
const EYE := 1.65
## An empty hand drawn closer than this, in metres, to where the avatar holds it is the avatar's own hand to the eyes.
const APART := 0.05
## Once `fit` strays this fraction from the world's scale, the view fades out and back in at the new one, as a
## teleport does: the world never grows in view.
const REFIT := 0.02
## The fit at its extremes, past which an avatar stands above the floor or sinks into it.
const FITS := Vector2(0.1, 10.0)
const AIR_REACH := 30.0
## A target across the map moves metres for a fraction of a degree of hand tremor. The aim follows the hand at
## STEADY_HZ, plus STEADY_HZ_PER_RAD for each radian it lags, so a held hand stays still and a sweep catches up.
const STEADY_HZ := 0.5
const STEADY_HZ_PER_RAD := 60.0
## Past MARKER_NEAR from the eyes the landing preview grows with distance, so it looks as big as it does there.
const MARKER_NEAR := 15.0
## Stick forward at or past FULL_STICK aims at the ray's full target; easing back to the deadzone brings it
## to NEAREST of the way there.
const FULL_STICK := 0.9
const DEADZONE := 0.3
const NEAREST := 0.1
## A released stick springs through every smaller deflection on its way to centre; the target reaches as far as the
## stick did this long before, so the one shown when it reaches its deadzone is where the release lands.
const RELEASE_LOOKBACK := 0.1
const MAX_LIFT := 40.0
## A surface whose outward normal rises less than this, steeper than 70 degrees or facing down, is a side, as of a
## wall; anything flatter is stood on. A ruin's stones lean a little and stand proud of each other, well inside it.
const STEEP := 0.34
## How far back along a ray that struck a side the player lands or floats.
const STAND_OFF := 0.3
## A side struck at most this far over the floor in front of it lands the player on that floor; higher, they float at
## the height struck.
const CLIMB := 1.5
## A target this far over its floor floats.
const LIFTED := 0.15
const SNAP := deg_to_rad(30.0)
## Each turning flick as the angle it turns the player.
const TURNS := {"turn_left": SNAP, "turn_right": -SNAP, "turn_round": PI}
const FADE := 0.09
## While the eyes are inside something solid, a wall or the ground, the view dims this far over INSIDE_TIME, and
## clears as fast once they are out: the view is never moved to push them out.
const INSIDE_DIM := 0.9
const INSIDE_TIME := 0.15
## Where on the ground the player starts, as x and z.
const SPAWN := Vector2(0, 4)
## How far from SPAWN a spawn looks for open ground, and how far apart the points it tries stand.
const SPAWN_SEARCH := 20.0
const SPAWN_STEP := 2.0
## How high over a spawn point nothing may stand: above the tallest build.
const SPAWN_CLEAR := 200.0

## The player was set down somewhere else.
signal placed
## The player was moved in one cut, by a teleport or a snap turn, not by any step of their own.
signal jumped

var head: XRCamera3D
var gaze: Gaze
var left: Hand
var right: Hand
var hands: Array[Hand] = []
var body: Avatar
## The body as the eyes see it (`Avatar.headless`), shown while both hands are empty.
var _seen: Array[MeshInstance3D] = []
var stature := Stature.new()

## The hand whose teleport ray is out, or null.
var aim_hand: Hand
## The conure on each shoulder, left then right, or null.
var shoulders: Array[Conure] = [null, null]
## The torso's turn in this node's space, so a snap turn or a teleport carries it with the player.
var _torso := NAN
var aim_ground: Variant = null
var aim_lift := 0.0
var terrain: Terrain
## What a point stands on: the top surface at or just below it, the ground or anything built on it.
var floor_under := func(p: Vector3) -> float: return terrain.shown_at(p.x, p.z)
## Where a ray first meets something solid short of a reach, the ground aside: a build, a plant or stairs, as
## {point, side}, `side` whether it struck a side; or {}.
var solid_hit := func(_origin: Vector3, _dir: Vector3, _reach: float) -> Dictionary: return {}
## The left stick's flicks and click.
var _stick: Buttons
var _fade_t := -1.0
## The view is held black for a garden swap until `respawn` (`blackout`).
var _covered := false
## Seconds the fade under way takes each way.
var _fade_len := FADE
## Whether the eyes are inside something solid (`HandStop`).
var inside := false
var _dim := 0.0
var _pending: Variant = null
var _aim_clock := 0.0
## [time, the stick's forward deflection] over the last RELEASE_LOOKBACK of aiming, oldest first.
var _aim_trail: Array = []
var _steady_dir := Vector3.ZERO

var _landing := Landing.new()
var _underfoot := Underfoot.new()
## The floor the player was last set down over, which a float is measured from: what is built or shaped under a
## floating player afterwards leaves the ring and shadow where they began.
var _floor_y := 0.0
var _fade: MeshInstance3D
var _fade_mat: StandardMaterial3D


var expression_store := ExpressionStore.new()


func _init(ground: Terrain) -> void:
	add_child(expression_store)
	terrain = ground
	head = XRCamera3D.new()
	head.position = Vector3(0, EYE, 0)
	head.near = NEAR
	head.far = far()
	head.cull_mask = Quality.VIEW_MASK & ~Quality.SELF_LAYER | Quality.EYES_LAYER
	add_child(head)
	gaze = Gaze.new()
	add_child(gaze)
	left = Hand.new("left_hand", Hand.Tool.BOOK)
	right = Hand.new("right_hand", Hand.Tool.WALLS)
	hands = [left, right]
	for h in hands:
		add_child(h)
	_stick = Buttons.new(left).watch(["teleport", "turn_left", "turn_right", "turn_round", "reach"])
	_build_markers()


func _build_markers() -> void:
	add_child(_landing)
	add_child(_underfoot)
	_fade_mat = StandardMaterial3D.new()
	_fade_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_fade_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_fade_mat.no_depth_test = true
	_fade_mat.render_priority = 100
	_fade_mat.albedo_color = Color(0, 0, 0, 0)
	_fade = MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(2, 2)
	_fade.mesh = quad
	_fade.position = Vector3(0, 0, -0.08)
	_fade.material_override = _fade_mat
	_fade.visible = false
	head.add_child(_fade)


## Wears `a` as the player's own avatar, posed from the head and hands by `pose_body`: the cameras and mirrors see
## it whole, and the eyes see it headless while both hands are empty.
func wear(a: Avatar) -> void:
	for hand in hands:
		hand.close_wheel()
	expression_store.wear(a.expressions, a.source)
	if body != null:
		body.queue_free()
	body = a
	a.top_level = true
	a.ground = func(p: Vector3) -> float: return floor_under.call(p)
	a.visible = true
	for v: VisualInstance3D in a.find_children("*", "VisualInstance3D", true, false):
		v.layers = Quality.SELF_LAYER
	for mi in a.swaying():
		mi.layers = Quality.PEOPLE_LAYER | Quality.SELF_LAYER
	_seen = a.headless()
	for mi in _seen:
		mi.layers = Quality.EYES_LAYER
	add_child(a)
	_landing.wear(a)


## Poses the body from the head and hands; a hand holding a tool is drawn as the tool alone, so its fingers never
## reach in front of a camera's lens.
func pose_body() -> void:
	body.torso = torso().basis.get_euler().y
	body.pose(head.global_transform, left.held_at(), right.held_at(), gaze.look)
	for h in hands:
		if h.tool != Hand.Tool.NONE:
			body.fold(hands.find(h))
	for mi in _seen:
		mi.visible = bare()


## Whether both hands are empty, so the eyes see the player's own body.
func bare() -> bool:
	return hands.all(func(h: Hand) -> bool: return h.tool == Hand.Tool.NONE)


## Whether the eyes see the avatar's own hand where `h` is drawn, rather than `h` thrown out from it.
func shows_hand(h: Hand) -> bool:
	return body != null and bare() and h.held_at().origin.distance_to(h.body.global_position) < APART


## The torso under the head, in the world's space (`Torso`).
func torso() -> Transform3D:
	_torso = Torso.follow(_torso, head.transform.basis)
	return global_transform * Torso.frame(head.transform, _torso)


## Whether the head is under a pond, where the water's fog takes everything past its end: the eyes clip there, so
## the garden beyond is not drawn.
var under := false


## The eyes' far clip: at least FAR, and the whole ground from anywhere a player can stand or float over it,
## however high or deep it is pulled.
func far() -> float:
	return maxf(FAR, terrain.bounds().size.length() + AIR_REACH + MAX_LIFT)


func _process(delta: float) -> void:
	head.far = Look.WATER_FOG.fog_depth_end if under else far()
	_locomotion_input(delta)
	_switch_reach()
	_stick.latch()
	_fade_step(delta)
	_underfoot.follow(head.global_position, global_position.y, _floor_y)
	_refit(delta)


## How many times their own size the wearer stands, as the world's scale: their avatar's eye height over their own, or
## 1 with none worn. They see from its eyes and reach as far as its arms, and it is drawn at its own size and
## proportions whoever wears it.
func fit() -> float:
	return clampf(body.eye_height / stature.eye(EYE), FITS.x, FITS.y) if body != null else 1.0


## Measures the wearer's eye height, and refits them where they stand once `fit` strays from the world's scale.
func _refit(delta: float) -> void:
	stature.add(head.position.y / world_scale, delta)
	if _fade_t < 0.0 and aim_hand == null and absf(fit() / world_scale - 1.0) > REFIT:
		var h := head.global_position
		_cut(Vector3(h.x, _floor_y, h.z), global_position.y - _floor_y)


## The left stick clicked in while centred cycles every hand's reach (`Reach.mode`): a debug switch for comparing them
## in one session, gone once a playtest keeps one. A thumb pressing hard into a push or a flick clicks it by accident.
func _switch_reach() -> void:
	if _stick.pressed("reach") and aim_hand == null and left.stick().length() < DEADZONE:
		Reach.mode = (Reach.mode + 1) % Reach.Mode.size() as Reach.Mode
		print("reach: %s" % Reach.Mode.keys()[Reach.mode])
		Cues.play_in(Cues.Act.WHEEL_PICK, head.global_position, hands)


func _locomotion_input(delta: float) -> void:
	if _covered:
		return
	if aim_hand == null and _stick.held("teleport"):
		aim_hand = left
	if aim_hand != null and aim_hand.picking:
		end_aim()
	if aim_hand != null:
		var stick := aim_hand.stick()
		if stick.length() < DEADZONE:
			if aim_ground != null:
				teleport(aim_ground, aim_lift)
			end_aim()
			return
		_aim_clock += delta
		_aim_trail.append([_aim_clock, stick.y])
		while _aim_trail.size() > 1 and _aim_trail[1][0] <= _aim_clock - RELEASE_LOOKBACK:
			_aim_trail.pop_front()
		aim(_steadied(aim_hand.at_controller(), delta), reach_scale(_aim_trail[0][1]))
		return
	for turn: String in TURNS:
		if _stick.pressed(turn):
			snap_turn(TURNS[turn], left)


func end_aim() -> void:
	aim_hand = null
	aim_ground = null
	_aim_clock = 0.0
	_aim_trail.clear()
	_steady_dir = Vector3.ZERO
	hide_markers()


## `pose` turned from the hand's own direction to the steadied one.
func _steadied(pose: Transform3D, delta: float) -> Transform3D:
	var dir := -pose.basis.z.normalized()
	if _steady_dir == Vector3.ZERO:
		_steady_dir = dir
		return pose
	var hz := STEADY_HZ + STEADY_HZ_PER_RAD * _steady_dir.angle_to(dir)
	_steady_dir = _steady_dir.slerp(dir, 1.0 - exp(-TAU * hz * delta)).normalized()
	return Transform3D(Basis(Quaternion(dir, _steady_dir)) * pose.basis, pose.origin)


## The fraction of the way to the ray's full target that a forward stick deflection of `y` reaches.
static func reach_scale(y: float) -> float:
	return lerpf(NEAREST, 1.0, clampf((y - DEADZONE) / (FULL_STICK - DEADZONE), 0.0, 1.0))


## Cast the teleport ray from a pointing pose. Its full target is the first solid thing it hits anywhere on the map,
## the ground, a roof of any pitch, a wall's top, a tree's crown from above, where the player then stands, or a side,
## as of a wall, at whose foot they stand if it was struck within CLIMB of the floor there, else floating where it was
## struck. The mountains round the map are sky to the ray, and its cast ends at the map's side: one that hits nothing
## stands the player on the floor at the side where it leaves, or, aimed above the horizon, floats them in the air
## AIR_REACH along it or at the side if that is nearer. The target lies `fraction` of the way there along the ray, in
## the air above the floor short of a hit.
func aim(from: Transform3D, fraction := 1.0) -> void:
	var origin := from.origin
	var dir := -from.basis.z.normalized()
	var reach := minf(terrain.exit_along(origin, dir), Terrain.side_along(origin, dir))
	var hit: Variant = terrain.raycast(origin, dir, reach)
	var solid: Dictionary = solid_hit.call(origin, dir, reach if hit == null else origin.distance_to(hit))
	if not solid.is_empty():
		hit = solid.point
	if hit == null and dir.y <= 0.0:
		var leaves := origin + dir * reach
		hit = Vector3(leaves.x, floor_under.call(leaves), leaves.z)
	var full: Vector3 = hit if hit != null else origin + dir * minf(AIR_REACH, reach)
	var target := origin.lerp(full, fraction)
	var stand := target
	var g: float = floor_under.call(target)
	if hit != null and fraction >= 1.0:
		stand = full
		g = full.y
		var back := Vector3(dir.x, 0.0, dir.z)
		if solid.get("side", false) and back.length() > 1e-3:
			stand -= back.normalized() * STAND_OFF
			g = floor_under.call(stand)
			if full.y - g <= CLIMB:
				stand.y = g
	aim_ground = Vector3(stand.x, g, stand.z)
	aim_lift = clampf(stand.y - g, 0.0, MAX_LIFT)
	var g3: Vector3 = aim_ground
	var size := maxf(1.0, head.global_position.distance_to(target) / MARKER_NEAR)
	_landing.put(g3 + Vector3.UP * (aim_lift if aim_lift > LIFTED else 0.0), size, self)


## Whether a surface with outward normal `normal` is a side.
static func side(normal: Vector3) -> bool:
	return normal.normalized().y < STEEP


## The outward normal of the face of `box` that the point `p` on its surface lies on.
static func box_normal(box: AABB, p: Vector3) -> Vector3:
	var best := INF
	var n := Vector3.ZERO
	for k in 3:
		for end in [false, true]:
			var d := absf(p[k] - (box.end[k] if end else box.position[k]))
			if d < best:
				best = d
				n = Vector3.ZERO
				n[k] = 1.0 if end else -1.0
	return n


func hide_markers() -> void:
	_landing.hide()


## Move so the head stands over `ground`, `lift` metres up. The rig then stays exactly there: in a headset
## any view motion the player's head did not make is uncomfortable. A far teleport, past MARKER_NEAR from the eyes,
## that stands the player on something, the ground or anything on it, sounds as a landing; one into the air does not.
func teleport(ground: Vector3, lift_m: float) -> void:
	var at := ground + Vector3.UP * (lift_m + head.position.y)
	var landing := lift_m <= LIFTED and head.global_position.distance_to(at) > MARKER_NEAR
	Cues.play(Cues.Act.TELEPORT_ONTO if landing else Cues.Act.TELEPORT, at, left if aim_hand == null else aim_hand)
	_cut(ground, lift_m)


## Fades the view out, sets the player down at `ground`, `lift_m` up, and fades it back in.
func _cut(ground: Vector3, lift_m: float) -> void:
	_pending = [ground, lift_m]
	_fade_len = FADE
	_fade_t = 0.0
	_fade.visible = true


## Fades the view to black and holds it there until `respawn` sets the player down in the garden that follows, and
## says whether it is black yet (`World.blackout`).
func blackout() -> bool:
	if not _covered:
		end_aim()
		_pending = null
	return cover()


## Sets the player down on open ground at SPAWN, or the nearest open ground to it, and lifts a cover.
func respawn() -> void:
	_pending = null
	place(spawn(), 0.0)
	uncover()


## Fades the view to black over `fade` seconds and holds it there until `uncover`; says whether it is black yet. Black
## is never brighter than what it covers.
func cover(fade := FADE) -> bool:
	if not _covered:
		_covered = true
		_fade_t = 0.0 if _fade_t < 0.0 else minf(_fade_t, _fade_len * 2.0 - _fade_t) * fade / _fade_len
		_fade_len = fade
		_fade.visible = true
	return _fade_t >= _fade_len


## Fades a cover back to the view.
func uncover() -> void:
	_covered = false


func covered() -> bool:
	return _covered


## The open ground nearest SPAWN, tried ring by ring SPAWN_STEP apart: a point nothing is built, planted or set down
## over, so the player never arrives inside a build. With none within SPAWN_SEARCH, the top of what stands at SPAWN.
func spawn() -> Vector3:
	for ring in int(SPAWN_SEARCH / SPAWN_STEP) + 1:
		var r := ring * SPAWN_STEP
		var n := maxi(1, int(TAU * r / SPAWN_STEP))
		for k in n:
			var at := Vector2(SPAWN.x, SPAWN.y) + Vector2.from_angle(TAU * k / n) * r
			var g := terrain.ground(at.x, at.y)
			if solid_hit.call(g + Vector3.UP * SPAWN_CLEAR, Vector3.DOWN, SPAWN_CLEAR).is_empty():
				return g
	var top := Vector3(SPAWN.x, terrain.shown_at(SPAWN.x, SPAWN.y) + MAX_LIFT, SPAWN.y)
	return Vector3(top.x, floor_under.call(top), top.z)


## Sets the player's head over `ground`, `lift_m` up, at the world's scale that fits them to their avatar (`fit`): over
## it where the head stands once it is next reported at that scale. The head moves with the scale between frames, as a
## headset's runtime reports it, never within one, so a session record keeps each frame's head as it was given and a
## replay places the player from the same pose.
func place(ground: Vector3, lift_m: float) -> void:
	var s := fit()
	var h := global_transform * (head.position * s / world_scale)
	if s != world_scale:
		_rescale_head.call_deferred(s / world_scale)
	world_scale = s
	head.near = NEAR * s
	_floor_y = maxf(ground.y, terrain.shown_at(ground.x, ground.z))
	global_position = Vector3(global_position.x + ground.x - h.x, maxf(ground.y + lift_m, _floor_y), global_position.z + ground.z - h.z)
	placed.emit()


func _rescale_head(by: float) -> void:
	head.position *= by


func snap_turn(angle: float, hand: Hand) -> void:
	var pivot := head.global_position
	var t := Transform3D(Basis(Vector3.UP, angle), Vector3.ZERO)
	global_transform = Transform3D(t.basis * global_transform.basis, pivot + t.basis * (global_position - pivot))
	jumped.emit()
	Cues.play(Cues.Act.TURN, pivot, hand)


func _fade_step(delta: float) -> void:
	_dim = move_toward(_dim, INSIDE_DIM if inside else 0.0, INSIDE_DIM * delta / INSIDE_TIME)
	var a := 0.0
	if _fade_t >= 0.0:
		_fade_t += delta
		if _covered:
			_fade_t = minf(_fade_t, _fade_len)
		a = clampf(1.0 - absf(_fade_t / _fade_len - 1.0), 0.0, 1.0)
		if _pending != null and _fade_t >= _fade_len:
			place(_pending[0], _pending[1])
			_pending = null
			jumped.emit()
		if _fade_t >= _fade_len * 2.0:
			_fade_t = -1.0
			a = 0.0
	a = maxf(a, _dim)
	_fade_mat.albedo_color = Color(0, 0, 0, a)
	_fade.visible = a > 0.0
