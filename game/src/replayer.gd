class_name Replayer
extends MultiplayerAPIExtension

## Plays a session record (`Replay.read`, Main's --replay) in place of the headset's runtime and the network, and says
## where the session it plays diverges from the one recorded; see docs/replay.md.
signal finished

## What a check compares, beside the garden: Replay.check's parts.
const PARTS := ["player", "wildlife", "physics"]

var record: Dictionary
var _main: Main
var _frame := 0
var _count := 0
var _next := 0
var _id := 1
var _sender := 0
var _peers := PackedInt32Array()
var _peer: MultiplayerPeer = OfflineMultiplayerPeer.new()
var _head: Transform3D
## The next of the record's checks of the parts to compare, and the record's gardens not yet come to, oldest first: each
## garden numbers its own commands, so only the oldest is looked for.
var _check := 0
var _gardens := []
## The command after which the garden last matched the record's, and whether a whole garden is being restored, whose
## commands come with no sequence number of their own.
var _held_seq := 0
var _restoring := false
## Where each part first diverged from the record (`_diverge`), by part.
var diverged := {}


func _init(on: Main, played: Dictionary) -> void:
	_main = on
	record = played
	_count = record.frames.size() / Replay.FRAME_BYTES
	for c: Dictionary in record.checks:
		if c.has("garden") and (_gardens.is_empty() or _gardens[-1].seq != c.seq or _gardens[-1].garden != c.garden):
			_gardens.append(c)
	RenderingServer.frame_pre_draw.connect(_view)


## Compares the garden with the record's whenever it comes to a command the record kept it after: as that command has
## applied whole (a batch's or a rebuild's own commands carry no sequence number of the garden's), or as a whole garden
## restored at it is in.
func watch(world: World) -> void:
	world.applied.connect(func(cmd: Dictionary) -> void:
		if not _restoring and cmd.get("seq") == world.seq:
			_compare_garden())
	world.restored.connect(func() -> void: _restoring = true)
	world.loaded.connect(func() -> void:
		_restoring = false
		_compare_garden())


## Runs where the tree polls the network, before anything of the frame: the frame's messages, then its input.
func _poll() -> Error:
	if _frame > _count:
		return OK
	var messages: Array = record.messages
	while _next < messages.size() and messages[_next][0] <= _frame:
		_next += 1
		_deliver(messages[_next - 1])
	if _frame == _count:
		_frame += 1
		_let_go()
		_main.world.settle()
		if not _gardens.is_empty():
			_diverge("garden", _gardens[0], "the garden never came to command %d" % _gardens[0].seq)
		if not diverged.is_empty():
			print("replay: " + "; ".join(diverged.values().map(func(d: Dictionary) -> String: return d.said)))
		else:
			print("replay: every one of the record's %d checks held" % record.checks.size() if not record.checks.is_empty() else "replay: the record took no checks")
		finished.emit()
		return OK
	_apply(Replay.unpack(record.frames, _frame, record.inputs))
	_frame += 1
	_pace()
	return OK


## Scales the next frame to its recorded delta, taking this frame's own step, unscaled, as the next one's: exact when the
## run steps by a fixed rate (--fixed-fps), as close as its frame times allow when it runs in real time.
func _pace() -> void:
	var step := _main.get_process_delta_time() / Engine.time_scale if Engine.time_scale > 0.0 else 0.0
	Engine.time_scale = record.frames.decode_double(_frame * Replay.FRAME_BYTES) / step if _frame < _count and step > 0.0 else 1.0


## A headset draws its eyes where its own tracking puts them, whatever the head node says. XROrigin3D sets the play
## space back from the rig as each frame is processed, so the shift lasts only for the draw.
func _view() -> void:
	if _frame == 0 or _frame > _count or not _main.metrics.info.xr:
		return
	XRServer.world_origin = _main.rig.global_transform * _head * XRServer.get_hmd_transform().affine_inverse()


func _apply(f: Dictionary) -> void:
	_head = f.head
	_main.rig.head.transform = f.head
	for i in Replay.HANDS.size():
		var h: Hand = _main.rig.hands[i]
		var got: Dictionary = f.hands[i]
		h.held_still = got.flags.tracked or got.flags.bare
		h.held_reaches = got.flags.reaches
		h.transform = got.pose
		Hand.injected_sticks[h.tracker] = got.stick
		for input: String in got.held:
			if got.held[input]:
				Buttons.injected["%s/%s" % [h.tracker, input]] = true
			else:
				Buttons.injected.erase("%s/%s" % [h.tracker, input])


## Compares what the session has come to with each check of its parts the record took at the frame now under way, at
## the point of the frame it took them (Metrics), where nothing of the frame is left to move them.
func compare() -> void:
	var checks: Array = record.checks
	while _check < checks.size() and checks[_check].frame <= _frame:
		var c: Dictionary = checks[_check]
		_check += 1
		if not c.has(PARTS[0]):
			continue
		var now := Replay.check(_main)
		for part in PARTS:
			if Replay.digest(now[part]) != c[part]:
				_diverge(part, c, "")


func _compare_garden() -> void:
	if _gardens.is_empty() or _gardens[0].seq != _main.world.seq:
		return
	var c: Dictionary = _gardens.pop_front()
	if Replay.garden(_main.world) != c.garden:
		_diverge("garden", c, "")
	elif not diverged.has("garden"):
		_held_seq = maxi(_held_seq, int(c.seq))


## Notes where `part` first differs from the record's check `c`: its frame and game second, and for the garden the
## commands it ran since it last matched, among them the one whose result changed.
func _diverge(part: String, c: Dictionary, why: String) -> void:
	if diverged.has(part):
		return
	var second := 0.0
	for i in mini(int(c.frame), _count):
		second += record.frames.decode_double(i * Replay.FRAME_BYTES)
	var at := {"part": part, "frame": int(c.frame), "second": snappedf(second, 0.001)}
	if part == "garden":
		at.commands = record.messages.filter(func(m: Array) -> bool:
			return m[3] in ["ordered", "_commit"] and m[4][0].get("seq", 0) > _held_seq and m[4][0].get("seq", 0) <= c.seq).map(
			func(m: Array) -> String: return "%d %s" % [m[4][0].seq, m[4][0].op])
	at.said = "the %s first differs from the record at frame %d, %.1f s in%s%s" % [part, at.frame, at.second,
		", after commands %s" % ", ".join(at.commands) if at.has("commands") else "", ": " + why if why != "" else ""]
	diverged[part] = at
	push_warning("replay: " + at.said)


func _let_go() -> void:
	for h: Hand in _main.rig.hands:
		h.held_still = false
		h.held_reaches = false
		Hand.injected_sticks.erase(h.tracker)
		for input in Replay.inputs(h.tracker):
			Buttons.injected.erase("%s/%s" % [h.tracker, input])


## A message as the network gave it, and each build command as the host ordered it: the garden is the record's, never
## the tools' (World.replayed), so a proposal is only the order that follows it. What else this machine did itself is
## the input's to do again, but for its peers coming and going and its host dropping it, which the network decided.
func _deliver(m: Array) -> void:
	var whose: int = m[2]
	match m[3]:
		"ordered", "_commit":
			_main.world._commit(m[4][0])
		"_propose":
			pass
		"peer_connected":
			_peers.append(whose)
			peer_connected.emit(whose)
		"peer_disconnected":
			if whose in _peers:
				_peers.remove_at(_peers.find(whose))
			peer_disconnected.emit(whose)
		"look":
			var file: Variant = m[4][0]
			var key: String = file.sha256 if file is Dictionary else ""
			var bytes: PackedByteArray = record.avatars[key] if key != "" else PackedByteArray()
			_main.session.avatar = m[4][1]
			_main.session.colour = m[4][2]
			_main.session.put_on(Avatar.read(bytes) if key != "" else null, key, bytes, m[4][1], m[4][2])
		"paused", "resumed":
			_main.held(m[3] == "paused")
		"connected":
			connected_to_server.emit()
		"dropped":
			server_disconnected.emit()
		_ when m[1] != 0:
			_sender = m[1]
			(_main.world if _main.world.has_method(m[3]) else _main.session).callv(m[3], m[4].map(_unfiled))
			_sender = 0


## A file the record kept only as its hash (PlayLog._without_files) arrives as no file.
static func _unfiled(a: Variant) -> Variant:
	return PackedByteArray() if a is Dictionary and a.has("sha256") and a.size() == 2 else a


## A garden this game sets out to join is never reached: it stands for the player the record says this machine
## became there.
func _set_multiplayer_peer(peer: MultiplayerPeer) -> void:
	_peers.clear()
	_id = 1
	if peer is ENetMultiplayerPeer:
		if peer.get_unique_id() != 1:
			_id = _joined_as(peer.get_unique_id())
		peer.close()
		peer = OfflineMultiplayerPeer.new()
	_peer = peer


## The id the host gave this machine when this join connected, else `otherwise`.
func _joined_as(otherwise: int) -> int:
	for i in range(_next, record.messages.size()):
		match record.messages[i][3]:
			"connected":
				return record.messages[i][2]
			"join", "dropped", "home":
				break
	return otherwise


func _get_multiplayer_peer() -> MultiplayerPeer:
	return _peer


func _get_unique_id() -> int:
	return _id


func _get_peer_ids() -> PackedInt32Array:
	return _peers


func _get_remote_sender_id() -> int:
	return _sender


func _rpc(_peer_id: int, _object: Object, _method: StringName, _args: Array) -> Error:
	return OK


func _object_configuration_add(_object: Object, _configuration: Variant) -> Error:
	return OK


func _object_configuration_remove(_object: Object, _configuration: Variant) -> Error:
	return OK
