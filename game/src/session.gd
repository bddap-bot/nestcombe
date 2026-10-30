class_name Session
extends Node

## Who shares this garden (docs/multiplayer.md). Every instance hosts its own garden, which alone is
## single player, and announces it on the local network; joining someone swaps in their garden until
## you leave or they go. Each player's head and hands travel to the others as poses, and the VRM they
## wear from their avatar folder travels once to everyone they meet.

const SpringDefinition = preload("res://addons/avatar_workshop/spring_definition.gd")
const PORT := 7480
## A host takes the first free of PORTS ports from its first; beacons may name any in PORT_RANGE from PORT.
const PORTS := 8
const PORT_RANGE := 64
## Beacons go to each of these ports, so several instances on one machine each find the others.
const BEACON_PORT := 7469
const BEACON_PORTS := 4
const BEACON_EVERY := 1.0
const FORGET_AFTER := 4.0
## At most this many beacons are read a frame and this many gardens remembered, whatever the network sends.
const HEAR_PER_FRAME := 16
const MAX_NEARBY := 12
const MAX_PLAYERS := 8
const POSE_EVERY := 1.0 / 30.0
## How fast a remote avatar closes on its latest pose, per second.
const FOLLOW := 18.0
## How often the avatar folder is looked at, in seconds.
const FOLDER_EVERY := 2.0
## Avatar files travel on a channel of their own, so building commands never wait behind one.
const FILE_CHANNEL := 1
## At most this many avatar files are handed out, and fetched for the picker, at once; a transfer stalled this
## many seconds is dropped.
const SHELF_PEERS := 4
const FETCHES := 2
const STALL := 30.0
## How long, in milliseconds, a peer's reliable data may go unacknowledged before it is dropped. ENet's own
## default drops a live peer within seconds when a large file's transfer meets a burst of Wi-Fi loss.
const SILENCE := 30000
## ENet's longest silence in milliseconds, past what its clock can tell apart: a link set to it never times out.
const PATIENT := 0x7fffffff
const CHUNK := 1 << 16
## A file that could not be fetched, or was not the one named, is tried again after this many seconds; one that was
## and did not read is not, while a beacon still names it.
const RETRY := 30.0
## A thrown handful flies slower than this, in metres a second; a player's throws come at most this often, in seconds.
const MAX_THROW := 20.0
const THROW_EVERY := 0.1
## A hand's reach into a spring chain: a sphere about a palm across, round where it grips.
const HAND_RADIUS := 0.04
const COLOURS: Array[Color] = [Color(0.8, 0.45, 0.32), Color(0.45, 0.62, 0.42), Color(0.86, 0.66, 0.3), Color(0.38, 0.5, 0.72), Color(0.62, 0.4, 0.6), Color(0.3, 0.6, 0.6)]

## Peers or nearby gardens came or went.
signal changed

var world: World
var rig: Rig
## Where every player's thrown seeds land, so each sees the same handfuls and what comes to eat them.
var feed: FeedTool:
	set(f):
		feed = f
		feed.threw.connect(func(from: Vector3, velocity: Vector3, seed: int) -> void:
			if not multiplayer.get_peers().is_empty():
				_threw.rpc(from, velocity, seed))
var avatar := 0
var colour := COLOURS[0]
var me: Persona
var port := 0
## 0 for an instance a test or script made without a port: it opens nothing, so runs side by side never meet.
var first_port := PORT
var beacon_port := BEACON_PORT
## Whether beacons reach the network, or only this machine.
var lan := true
## The garden we are visiting, {address, port}, or empty at home.
var visiting := {}
## Gardens announcing themselves nearby, by "address:port": {address, port, key, avatar, colour, wears, name, joins, seen}.
var nearby := {}
## Remote players' avatars by peer id.
var avatars := {}
var _spring_buttons: Array[Buttons] = []
var _spring_hands := [[], []]
var _spring_holds := {}
## Their seed dishes, two to a player, each shown in its hand while held out; `Wildlife` feeds from them. A leaving
## player's are hidden for the next to take up, never freed, so no animal is left holding a freed one.
var dishes: Array[Dish] = []
var _dishes := {}
var held := {}
var painting: EaselTool
var book: Book
var _sent_held: Array = []
## The folder whose .vrm files are this player's own avatars, or "" for none.
var folder := ""
## Every .vrm in that folder by file name: {seen, when, key, bytes, scene}. `seen` is its modified time and size, so a
## file is read again only when it changes; `key` is "" until it has been read, and `scene` null unless it read as an
## avatar within the limits.
var files := {}
## The folder file worn once it reads: the newest of those that last changed.
var _wanted := ""
## The folder file being read: one at a time, newest first, so a full folder never holds every core or its memory.
var _reading := ""
## That file once it has read as an avatar within the limits; sent to every player met.
var worn := PackedByteArray()
## Its hash, which the beacon names so the picker can fetch the file before anyone joins; "" for a built-in avatar.
var worn_key := ""
## Avatars by file hash for the picker: this player's own and those nearby gardens' beacons name.
var previews := {}
## Each remote player's built-in avatar and colour, and the hash of the file they wear ("" for none).
var _looks := {}
var _wearing := {}
## Avatars read from others' files, by hash, while someone here wears one.
var _scenes := {}
## Files being read on worker threads: {task, peer, done, out}, where only the worker writes `out` until the task
## completes; each player's latest file waiting to be.
var _jobs: Array[Dictionary] = []
var _waiting := {}
var _since_folder := INF
var _home := {}
var _key := 0
var _clock := 0.0
var _since_beacon := INF
var _since_pose := 0.0
var _beacon := PacketPeerUDP.new()
var _listen := PacketPeerUDP.new()
## Hands this player's file, after its length, to whoever asks, over TCP on the game's port number:
## {peer, bytes, sent, opened}.
var _shelf := TCPServer.new()
var _shelved := PackedByteArray()
var _handing: Array[Dictionary] = []
## Files being fetched from nearby gardens, by hash: {peer, got, since}, then {} while one is read.
var _fetches := {}
## When each file last failed to fetch, by hash; INF for one that arrived and did not read.
var _failed := {}
var _targets := {}
## When each remote player last threw.
var _thrown := {}
static var _protocol := 0


func _init(garden: World, player: Rig, look: int, from_port := PORT, on_lan := true, from_beacon := BEACON_PORT, who: Persona = null) -> void:
	name = "Session"
	# A system overlay pauses the garden, not the connection to its visitors.
	process_mode = Node.PROCESS_MODE_ALWAYS
	lan = on_lan
	beacon_port = BEACON_PORT if lan else clampi(from_beacon, 1024, 65536 - BEACON_PORTS)
	world = garden
	rig = player
	first_port = clampi(from_port, PORT, PORT + PORT_RANGE - PORTS) if from_port else 0
	var id := hash(OS.get_unique_id())
	avatar = posmod(look if look >= 0 else id, Avatar.BUILT_IN.size())
	colour = COLOURS[posmod(id / 7 + maxi(first_port - PORT, 0), COLOURS.size())]
	_key = randi()
	me = who if who else Persona.new("", 0, "", id)
	for i in Avatar.BUILT_IN.size():
		Avatar.built_in(i)


## A game a player launched, as opposed to one a script or a test runs. Only it beacons on the network.
static func played(args: Dictionary, launched: bool) -> bool:
	return launched and not (args.has("script") or args.has("replay") or args.has("join") or args.has("port") or args.has("beacon-port"))


## Where beacons go: a script's or a test's stay on this machine, so players never see them.
func beacon_to() -> Array:
	return ["255.255.255.255", "127.0.0.1"] if lan else ["127.0.0.1"]


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer)
	multiplayer.peer_disconnected.connect(_on_gone)
	multiplayer.server_disconnected.connect(_dropped, CONNECT_DEFERRED)
	multiplayer.connection_failed.connect(_dropped, CONNECT_DEFERRED)
	multiplayer.connected_to_server.connect(func() -> void: world.hear("connected", [], world.me()))
	_beacon.set_broadcast_enabled(true)
	for p in (BEACON_PORTS if first_port else 0):
		if _listen.bind(beacon_port + p, "*" if lan else "127.0.0.1") == OK:
			break
	me.offer(_key)
	rig.wear(Avatar.open(Avatar.built_in(avatar), colour))
	for hand in rig.hands:
		_spring_buttons.append(Buttons.new(hand).watch(["grab"]))
	host()


## Opens this garden to others; with nobody joining it is single player, on the same code path.
func host() -> void:
	visiting = {}
	var peer := ENetMultiplayerPeer.new()
	for p in (range(first_port, first_port + PORTS) if first_port else []):
		var probe := PacketPeerUDP.new()
		if probe.bind(p) != OK:
			continue
		probe.close()
		if peer.create_server(p, MAX_PLAYERS - 1) == OK:
			port = p
			multiplayer.multiplayer_peer = peer
			_shelf.listen(p, "*" if lan else "127.0.0.1")
			print("session: hosting on port %d" % p)
			return
	port = 0
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()


## Leaves this garden for another's; ours waits in memory until we come back.
func join(address: String, at_port: int) -> bool:
	var peer := ENetMultiplayerPeer.new()
	if peer.create_client(address, at_port) != OK:
		push_error("session: could not open a connection to %s:%d" % [address, at_port])
		return false
	if visiting.is_empty():
		world.flush()
		_home = world.snapshot()
	_shelf.stop()
	_handing.clear()
	multiplayer.multiplayer_peer.close()
	_drop_avatars()
	multiplayer.multiplayer_peer = peer
	visiting = {"address": address, "port": at_port}
	world.hear("join", [address, at_port])
	changed.emit()
	return true


## The garden we were visiting is gone, or never answered.
func _dropped() -> void:
	world.hear("dropped", [])
	go_home()


func go_home() -> void:
	if visiting.is_empty() and multiplayer.multiplayer_peer is ENetMultiplayerPeer:
		return
	print("session: home from ", visiting)
	world.hear("home", [])
	multiplayer.multiplayer_peer.close()
	_drop_avatars()
	host()
	if not _home.is_empty():
		world.swap(_home)
	_home = {}
	changed.emit()


func _here() -> Vector3:
	return rig.head.global_position if rig != null else Vector3.ZERO


func players() -> int:
	return multiplayer.get_peers().size() + 1


func _on_peer(id: int) -> void:
	world.hear("peer_connected", [], id)
	# A script's or a test's peer is never dropped for going quiet: on a loaded machine one long frame starves its
	# link however alive it is, and its harness ends a run whose player stops. Leaving still says goodbye.
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if enet != null and (multiplayer.is_server() or id == 1):
		var quiet := SILENCE if lan else PATIENT
		enet.get_peer(id).set_timeout(0, quiet, quiet)
	if multiplayer.is_server():
		world.welcome(id)
	_appear.rpc_id(id, avatar, colour)
	Cues.play(Cues.Act.PLAYER_JOINS, _here())
	if not worn.is_empty():
		_wear.rpc_id(id, worn, avatar)
	changed.emit()


func _on_gone(id: int) -> void:
	world.hear("peer_disconnected", [], id)
	print("session: player %d left" % id)
	Cues.play(Cues.Act.PLAYER_LEAVES, avatars[id].global_position if avatars.has(id) else _here())
	if avatars.has(id):
		avatars[id].queue_free()
		avatars.erase(id)
		_targets.erase(id)
	_drop_dishes(id)
	_looks.erase(id)
	_wearing.erase(id)
	_waiting.erase(id)
	_thrown.erase(id)
	for chain in _spring_holds.keys():
		if _spring_holds[chain][0] == id:
			_spring_holds.erase(chain)
	_prune()
	changed.emit()


func _drop_avatars() -> void:
	_spring_holds.clear()
	_spring_hands = [[], []]
	for a in avatars.values():
		a.queue_free()
	avatars.clear()
	_targets.clear()
	for id in _dishes.keys():
		_drop_dishes(id)
	_looks.clear()
	_wearing.clear()
	_waiting.clear()
	_prune()


func _process(delta: float) -> void:
	if delta > 2.0:
		print("session: a frame took %.1f s" % delta)
	rig.pose_body()
	rig.body.simulate_springs = false
	_spring_input(delta)
	_clock += delta
	_since_beacon += delta
	if _since_beacon >= BEACON_EVERY:
		_since_beacon = 0.0
		_announce()
	_hear()
	_hand_out()
	_fetch()
	_since_folder += delta
	if _since_folder >= FOLDER_EVERY:
		_since_folder = 0.0
		_look_in_folder()
	_finish_jobs()
	var faces: Array[Vector3] = []
	for a: Avatar in avatars.values():
		if a.visible:
			faces.append(a.eyes.origin)
	rig.gaze.follow(rig.head.global_transform, faces, delta)
	_since_pose += delta
	if _since_pose >= POSE_EVERY and not multiplayer.get_peers().is_empty():
		_since_pose = 0.0
		var items := [HeldItem.describe(rig.left, painting, book), HeldItem.describe(rig.right, painting, book), HeldItem.perched(rig, 0), HeldItem.perched(rig, 1)]
		if _sent_held.is_empty() or range(items.size()).any(func(i: int) -> bool: return not HeldItem.same(items[i], _sent_held[i])):
			_held.rpc(items)
			_sent_held = items
		_pose.rpc(rig.head.global_transform, rig.left.held_at(), rig.right.held_at(), rig.gaze.look, rig.body.springs.state() if rig.body.springs != null else PackedVector3Array(), _spring_holds)
	var k := 1.0 - exp(-FOLLOW * delta)
	for id in _targets:
		var a: Avatar = avatars[id]
		var t: Array = _targets[id]
		a.pose(a.eyes.interpolate_with(t[0], k), a.hands[0].interpolate_with(t[1], k), a.hands[1].interpolate_with(t[2], k), Gaze.turned(a.look, t[3], k))
		if a.springs != null and t.size() > 4:
			var state: PackedVector3Array = a.springs.state()
			var wanted: PackedVector3Array = t[4]
			if state.size() == wanted.size():
				for i in state.size():
					state[i] = state[i].lerp(wanted[i], k)
				a.springs.apply_state(state)
		for s in 2:
			var dish: Dish = _dishes[id][s]
			dish.transform = a.hands[s]
			dish.eyes = a.eyes.origin
			var item: HeldItem = held[id][s]
			item.transform = a.hands[s]
			item.visible = a.visible
			if item.replaces_hand():
				a.fold(s)
			dish.visible = a.visible and item.feeds()
		for item: HeldItem in held[id].slice(2):
			item.transform = Torso.frame(a.eyes, a.torso)
			item.visible = a.visible


func _announce() -> void:
	if port == 0 or not visiting.is_empty():
		return
	var msg := beacon()
	for dest in beacon_to():
		for p in BEACON_PORTS:
			_beacon.set_dest_address(dest, beacon_port + p)
			_beacon.put_packet(msg)


## Every second, to anyone on the network: nothing identifying, unless the player picked a name to show.
func beacon() -> PackedByteArray:
	var msg := {"cairnfold": protocol(), "key": _key, "port": port, "avatar": avatar, "colour": colour.to_html(false), "players": players()}
	if me.shared and not me.steam():
		msg.name = me.name
	if worn_key != "" and _shelf.is_listening():
		msg.wears = worn_key
	return JSON.stringify(msg).to_utf8_buffer()


## Godot numbers a node's RPCs by name, so two builds whose networked methods differ call the wrong methods
## on each other and every edit a visitor makes is lost: a garden is joined only by builds with the same ones.
static func protocol() -> int:
	if _protocol == 0:
		_protocol = fingerprint([World, Session])
	return _protocol


static func fingerprint(scripts: Array[Script]) -> int:
	var parts := PackedStringArray()
	for s in scripts:
		var rpcs: Dictionary = s.get_rpc_config()
		for m in s.get_script_method_list():
			if rpcs.has(m.name):
				parts.append("%s.%s/%d %s" % [s.get_global_name(), m.name, m.args.size(), rpcs[m.name]])
	parts.sort()
	return hash(parts)


## A beacon's garden, or empty when the packet is not one; `joins` is false for a build with other networked methods.
static func read_beacon(raw: PackedByteArray) -> Dictionary:
	var json := JSON.new()
	if json.parse(raw.slice(0, 512).get_string_from_utf8()) != OK:
		return {}
	var msg: Variant = json.data
	if not (msg is Dictionary and msg.get("cairnfold") is float and msg.get("key") is float and msg.get("port") is float and msg.get("avatar") is float):
		return {}
	var at := int(msg.port)
	if at < PORT or at >= PORT + PORT_RANGE:
		return {}
	var wears := str(msg.get("wears", ""))
	if not (wears.length() == 64 and wears.is_valid_hex_number()):
		wears = ""
	return {"key": int(msg.key), "port": at, "avatar": posmod(int(msg.avatar), Avatar.BUILT_IN.size()), "wears": wears, "colour": Color.from_string(str(msg.get("colour", "")), COLOURS[0]).clamp(), "name": Persona.clean(str(msg.get("name", ""))), "joins": msg.cairnfold == float(protocol())}


func _hear() -> void:
	var before := nearby.keys()
	for n in HEAR_PER_FRAME:
		if _listen.get_available_packet_count() <= 0:
			break
		var garden := read_beacon(_listen.get_packet())
		var ip := _listen.get_packet_ip()
		if garden.is_empty() or garden.key == _key:
			continue
		var where := "%s:%d" % [ip, garden.port]
		if not (nearby.has(where) or nearby.size() < MAX_NEARBY):
			continue
		garden.address = ip
		garden.seen = _clock
		nearby[where] = garden
	for key in nearby.keys():
		if _clock - nearby[key].seen > FORGET_AFTER:
			nearby.erase(key)
	if nearby.keys() != before:
		changed.emit()
	_prune_previews()
	for garden in nearby.values():
		var wears: String = garden.get("wears", "")
		if wears != "" and not previews.has(wears) and not _fetches.has(wears) and _fetches.size() < FETCHES and _clock - _failed.get(wears, -INF) > RETRY:
			var peer := StreamPeerTCP.new()
			if peer.connect_to_host(garden.address, garden.port) == OK:
				_fetches[wears] = {"peer": peer, "got": PackedByteArray(), "since": _clock}
			else:
				_failed[wears] = _clock


## The avatar a figure in the picker shows: the file `wears` names once it has been fetched and read, else the
## built-in one.
func look(wears: String, built_in: int) -> PackedScene:
	var scene: PackedScene = previews.get(wears)
	return scene if scene else Avatar.built_in(built_in)


## Whether the picker has fetches or reads still under way.
func previewing() -> bool:
	return not _fetches.is_empty()


## Keeps only what a nearby garden's beacon names now, so a host changing avatars leaves nothing behind.
func _prune_previews() -> void:
	var named := {worn_key: true}
	for g in nearby.values():
		named[g.get("wears", "")] = true
	for key in previews.keys():
		if not named.has(key):
			previews.erase(key)
	for key in _failed.keys():
		if not named.has(key):
			_failed.erase(key)
	for key in _fetches.keys():
		if not named.has(key) and not _fetches[key].is_empty():
			_fetches[key].peer.disconnect_from_host()
			_fetches.erase(key)


## Sends this player's file, after its length, to each who connects: it is what any player who joins gets anyway.
func _hand_out() -> void:
	while _shelf.is_connection_available():
		var peer := _shelf.take_connection()
		if _handing.size() < SHELF_PEERS and worn_key != "":
			_handing.append({"peer": peer, "bytes": _shelved, "sent": 0, "opened": _clock})
		else:
			peer.disconnect_from_host()
	for i in range(_handing.size() - 1, -1, -1):
		var h := _handing[i]
		var peer: StreamPeerTCP = h.peer
		var bytes: PackedByteArray = h.bytes
		peer.poll()
		var status := peer.get_status()
		while status == StreamPeerTCP.STATUS_CONNECTED and h.sent < bytes.size():
			var put := peer.put_partial_data(bytes.slice(h.sent, h.sent + CHUNK))
			if put[0] != OK or put[1] == 0:
				break
			h.sent += put[1]
		if status == StreamPeerTCP.STATUS_ERROR or status == StreamPeerTCP.STATUS_NONE or _clock - h.opened > STALL:
			peer.disconnect_from_host()
			_handing.remove_at(i)


## Reads what nearby gardens' files have sent; a whole one is read on a worker thread and kept if its hash is the
## one its beacon named.
func _fetch() -> void:
	for key in _fetches.keys():
		var f: Dictionary = _fetches[key]
		if f.is_empty():
			continue
		var peer: StreamPeerTCP = f.peer
		peer.poll()
		var status := peer.get_status()
		# Taken out of the dictionary while it grows, so appending never copies what has already arrived.
		var got: PackedByteArray = f.got
		f.got = PackedByteArray()
		if status == StreamPeerTCP.STATUS_CONNECTED and peer.get_available_bytes() > 0:
			var part := peer.get_partial_data(peer.get_available_bytes())
			if part[0] == OK:
				got.append_array(part[1])
		f.got = got
		var want: int = got.decode_u32(0) + 4 if got.size() >= 4 else -1
		var whole := got.size() == want
		var failed: bool = status == StreamPeerTCP.STATUS_ERROR or (status == StreamPeerTCP.STATUS_NONE and not whole) or want > Avatar.MAX_BYTES + 4 or (want >= 0 and got.size() > want) or _clock - f.since > STALL
		if failed:
			_failed[key] = _clock
		if failed or whole:
			peer.disconnect_from_host()
			_fetches.erase(key)
		if whole and not failed:
			_fetches[key] = {}
			_read(got.slice(4), "", _previewed.bind(key))


func _previewed(key: String, _bytes: PackedByteArray, scene: PackedScene, wanted: String) -> void:
	_fetches.erase(wanted)
	if not nearby.values().any(func(g: Dictionary) -> bool: return g.get("wears") == wanted):
		return
	if key == wanted and scene:
		previews[wanted] = scene
		changed.emit()
	else:
		_failed[wanted] = INF if key == wanted else _clock
	print("session: a nearby garden's host wears %s%s" % [wanted, "" if previews.has(wanted) else ", which did not match or read"])


## A player's avatar and colour, sent once to each player they meet.
@rpc("any_peer", "reliable")
func _appear(look: int, tint: Color) -> void:
	world.hear("_appear", [look, tint])
	var id := multiplayer.get_remote_sender_id()
	if avatars.has(id):
		return
	_looks[id] = [posmod(look, Avatar.BUILT_IN.size()), tint.clamp()]
	_dress(id, Avatar.built_in(look), "")
	var taken: Array = _dishes.values().reduce(func(all: Array, pair: Array) -> Array: return all + pair, [])
	var pair: Array[Dish] = []
	for dish in dishes:
		if pair.size() < 2 and not taken.has(dish):
			pair.append(dish)
	while pair.size() < 2:
		var dish := Dish.new(false)
		add_child(dish)
		dishes.append(dish)
		pair.append(dish)
	_dishes[id] = pair
	var models: Array[HeldItem] = []
	for side in 4:
		var item := HeldItem.new()
		item.add_to_group(HeldItem.GROUP)
		item.easels = painting.easels if painting != null else null
		item.terrain = world.terrain
		add_child(item)
		models.append(item)
	held[id] = models
	_sent_held.clear()


func _drop_dishes(id: int) -> void:
	for item: HeldItem in held.get(id, []):
		item.queue_free()
	held.erase(id)
	for dish: Dish in _dishes.get(id, []):
		dish.visible = false
	_dishes.erase(id)


## A player's own VRM, sent to each player they meet and again whenever it changes; empty for their built-in one.
## They keep their built-in avatar until the file has been read, on a worker thread, and passes the limits.
@rpc("any_peer", "reliable", "call_remote", FILE_CHANNEL)
func _wear(bytes: PackedByteArray, look: int) -> void:
	world.hear("_wear", [bytes, look])
	var id := multiplayer.get_remote_sender_id()
	print("session: player %d sent %d bytes of avatar%s" % [id, bytes.size(), "" if _looks.has(id) else " before appearing"])
	if not _looks.has(id) or bytes.size() > Avatar.MAX_BYTES:
		return
	_looks[id][0] = posmod(look, Avatar.BUILT_IN.size())
	_waiting[id] = bytes
	_read_waiting()


## Reads at most one file per player at a time, the latest each sent, so nobody can queue up reads.
func _read_waiting() -> void:
	for id in _waiting.keys():
		if _jobs.any(func(j: Dictionary) -> bool: return j.peer == id):
			continue
		var bytes: PackedByteArray = _waiting[id]
		_waiting.erase(id)
		if bytes.is_empty():
			_wearing[id] = ""
			_dress(id, Avatar.built_in(_looks[id][0]), "")
			_prune()
		else:
			_read(bytes, "", _worn_by_peer.bind(id), id)


func _worn_by_peer(key: String, _bytes: PackedByteArray, scene: PackedScene, id: int) -> void:
	if not _looks.has(id):
		return
	if scene == null:
		print("session: player %d sent a file that is not an avatar within the limits" % id)
		return
	print("session: player %d wears %s" % [id, key])
	_wearing[id] = key
	_scenes.get_or_add(key, scene)
	_dress(id, _scenes[key], key)
	_prune()


## Gives player `id` the avatar in `scene`, in their pose.
func _dress(id: int, scene: PackedScene, key: String) -> void:
	var a := Avatar.open(scene, _looks[id][1], key)
	a.simulate_springs = false
	a.ground = func(p: Vector3) -> float: return rig.floor_under.call(p)
	var old: Avatar = avatars.get(id)
	a.visible = old != null and old.visible
	if old != null:
		a.posture.take(old.posture)
		a.pose(old.eyes, old.hands[0], old.hands[1], old.look)
		old.queue_free()
	add_child(a)
	avatars[id] = a


func _prune() -> void:
	for key in _scenes.keys():
		if not _wearing.values().has(key):
			_scenes.erase(key)


static func sha256(bytes: PackedByteArray) -> String:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(bytes)
	return h.finish().hex_encode()


## Wears built-in avatar `look`.
func choose_avatar(look: int) -> void:
	_wanted = ""
	avatar = posmod(look, Avatar.BUILT_IN.size())
	_set_look("", PackedByteArray(), null)


## Wears folder file `f` if it has read as an avatar.
func wear_file(f: String) -> void:
	var file: Dictionary = files.get(f, {})
	if file.get("scene") != null:
		_wanted = ""
		_set_look(file.key, file.bytes, file.scene)


## Notes which .vrm files in the avatar folder are new, changed or gone. The newest new or changed one is worn once it
## reads; the worn one gone, the built-in avatar is.
func _look_in_folder() -> void:
	if folder == "":
		return
	var found := {}
	for f in DirAccess.get_files_at(folder):
		if f.get_extension().to_lower() == "vrm":
			found[f] = folder.path_join(f)
	var gone := []
	for f in files.keys():
		if not found.has(f):
			gone.append(files[f].key)
			files.erase(f)
	if worn_key != "" and gone.has(worn_key):
		_set_look("", PackedByteArray(), null)
	if not files.has(_wanted):
		_wanted = ""
	var newest := ""
	for f in found:
		var when := FileAccess.get_modified_time(found[f])
		var seen := "%d %d" % [when, FileAccess.get_size(found[f])]
		if files.get(f, {}).get("seen") != seen:
			files[f] = {"seen": seen, "when": when, "key": "", "bytes": PackedByteArray(), "scene": null}
			if newest == "" or when > files[newest].when:
				newest = f
	if newest != "":
		_wanted = newest
	_read_next()


## Starts reading the newest folder file not yet read, unless one is being read.
func _read_next() -> void:
	if _reading != "":
		return
	for f in files:
		if files[f].key == "" and (_reading == "" or files[f].when > files[_reading].when):
			_reading = f
	if _reading != "":
		_read(PackedByteArray(), folder.path_join(_reading), _have_file.bind(_reading, files[_reading].seen))


## Keeps a folder file read as it was when seen, and wears it if it is the one wanted.
func _have_file(key: String, bytes: PackedByteArray, scene: PackedScene, f: String, seen: String) -> void:
	_reading = ""
	if files.get(f, {}).get("seen") == seen:
		if scene == null:
			print("session: %s is not an avatar within the limits" % folder.path_join(f))
		files[f].merge({"key": key, "bytes": bytes if scene != null else PackedByteArray(), "scene": scene}, true)
		if f == _wanted:
			_wanted = ""
			if scene != null:
				_set_look(key, bytes, scene)
	_read_next()


func _set_look(key: String, bytes: PackedByteArray, scene: PackedScene) -> void:
	_spring_holds.clear()
	worn = bytes
	if not world.replayed:
		put_on.call_deferred(scene, key, bytes, avatar, colour)
	previews.erase(worn_key)
	worn_key = key
	_shelved = PackedByteArray([0, 0, 0, 0]) + worn
	_shelved.encode_u32(0, worn.size())
	if key != "":
		previews[key] = scene
	print("session: wearing %s" % (key if key != "" else "a built-in avatar"))
	if not multiplayer.get_peers().is_empty():
		_wear.rpc(worn, avatar)


## Puts on `scene`, file `key` of `bytes`, or with none built-in avatar `look`, in `tint`, and has the record keep it as
## `look` (its file as a hash, PlayLog): a choice is put on between frames, where a replay puts the record's on, so the
## rig refits the player (`Rig.fit`) from the same frame in both.
func put_on(scene: PackedScene, key: String, bytes: PackedByteArray, look: int, tint: Color) -> void:
	world.hear("look", [bytes, look, tint])
	rig.wear(Avatar.open(scene if scene != null else Avatar.built_in(look), tint, key))


## Reads a VRM, from `bytes` or the file at `path`, and hashes it on a worker thread; `done(hash, bytes, scene)`
## follows on this one, with a null scene if it is not an avatar within the limits. `peer` is whose file it is,
## 0 for this player's own or one the picker fetched.
func _read(bytes: PackedByteArray, path: String, done: Callable, peer := 0) -> void:
	var out := {}
	var task := WorkerThreadPool.add_task(func() -> void:
		var b := bytes
		if path != "":
			var f := FileAccess.open(path, FileAccess.READ)
			b = f.get_buffer(f.get_length()) if f != null and f.get_length() <= Avatar.MAX_BYTES else PackedByteArray()
		out.merge({"key": sha256(b), "bytes": b, "scene": Avatar.read(b) if not b.is_empty() else null}))
	_jobs.append({"task": task, "peer": peer, "done": done, "out": out})


func _exit_tree() -> void:
	_shelf.stop()
	for job in _jobs:
		WorkerThreadPool.wait_for_task_completion(job.task)
	_jobs.clear()


func _finish_jobs() -> void:
	for i in range(_jobs.size() - 1, -1, -1):
		var job := _jobs[i]
		if WorkerThreadPool.is_task_completed(job.task):
			WorkerThreadPool.wait_for_task_completion(job.task)
			_jobs.remove_at(i)
			job.done.call(job.out.key, job.out.bytes, job.out.scene)
			_read_waiting()


@rpc("any_peer", "reliable")
func _threw(from: Vector3, velocity: Vector3, seed: int) -> void:
	world.hear("_threw", [from, velocity, seed])
	var id := multiplayer.get_remote_sender_id()
	if feed == null or not avatars.has(id) or _clock - _thrown.get(id, -INF) < THROW_EVERY:
		return
	if not (from.is_finite() and Terrain.ROOM.grow(40.0).has_point(from) and velocity.is_finite() and velocity.length() < MAX_THROW):
		return
	_thrown[id] = _clock
	feed.toss(from, velocity, seed)


## A player's head, hands and where their eyes look, in their head's frame.
@rpc("any_peer", "unreliable_ordered")
func _pose(eyes: Transform3D, left: Transform3D, right: Transform3D, look: Vector3, springs := PackedVector3Array(), holders := {}) -> void:
	world.hear("_pose", [eyes, left, right, look, springs, holders])
	var id := multiplayer.get_remote_sender_id()
	var room := Terrain.ROOM.grow(40.0)
	for t in [eyes, left, right]:
		if not (t.is_finite() and absf(t.basis.determinant()) > 1e-3 and room.has_point(t.origin)):
			return
	if not (avatars.has(id) and look.is_finite() and look.length() > 0.1):
		return
	var avatar: Avatar = avatars[id]
	if avatar.springs == null or springs.size() != avatar.springs.point_count:
		springs = PackedVector3Array()
		holders = {}
	for chain in holders:
		var holder: Variant = holders[chain]
		if not chain is int or chain < 0 or avatar.springs == null or chain >= avatar.springs.chains.size() or not holder is Array or holder.size() != 2 or not holder[0] is int or not holder[1] is int or holder[1] < 0 or holder[1] > 1:
			return
	avatar.spring_holders = holders
	for point in springs:
		if not point.is_finite() or not room.has_point(point):
			return
	var target := [eyes.orthonormalized(), left.orthonormalized(), right.orthonormalized(), look.normalized(), springs]
	var a: Avatar = avatars[id]
	if not a.visible:
		a.visible = true
		a.pose(target[0], target[1], target[2], target[3])
	_targets[id] = target


@rpc("any_peer", "reliable")
func _held(items: Array) -> void:
	world.hear("_held", [items])
	var id := multiplayer.get_remote_sender_id()
	if not held.has(id) or items.size() != 4:
		return
	for item in items:
		if item is not Array or not HeldItem.valid(item):
			return
	for side in 4:
		(held[id][side] as HeldItem).show_state(items[side])


func _spring_input(delta: float) -> void:
	var mine := multiplayer.get_unique_id()
	var active := not get_tree().paused
	for side in _spring_buttons.size():
		var buttons := _spring_buttons[side]
		var hand := buttons.hand
		var selected: Array = _spring_hands[side]
		if not selected.is_empty() and (not active or not buttons.held("grab") or not hand.tracked() or hand.picking or hand.tool != Hand.Tool.NONE):
			_spring_request(selected[0], side, -1)
			_spring_hands[side] = []
			selected = []
		if active and selected.is_empty() and buttons.pressed("grab") and hand.tracked() and not hand.picking and hand.tool == Hand.Tool.NONE and not hand.taken():
			var choices := avatars.duplicate()
			choices[mine] = rig.body
			var nearest := 0.12
			for id: int in choices:
				var avatar: Avatar = choices[id]
				if avatar.springs == null:
					continue
				for chain in avatar.springs.chains.size():
					if (_spring_holds if id == mine else avatar.spring_holders).has(chain) or not avatar.springs.grabs(chain, SpringDefinition.WEARER if id == mine else SpringDefinition.OTHERS):
						continue
					var distance := avatar.springs.tip(chain).distance_to(hand.global_position)
					if distance < nearest:
						nearest = distance
						selected = [id, chain]
			if not selected.is_empty():
				_spring_hands[side] = selected
				_spring_request(selected[0], side, selected[1])
		if not selected.is_empty():
			hand.hold()
		buttons.latch()
	if rig.body.springs == null:
		return
	rig.body.springs.targets.clear()
	rig.body.springs.hands.clear()
	for side in 2:
		if rig.hands[side].tracked():
			rig.body.springs.hands.append([rig.hands[side].global_position, HAND_RADIUS, SpringDefinition.WEARER])
	for avatar: Avatar in avatars.values():
		if avatar.visible:
			for hand: Transform3D in avatar.hands:
				rig.body.springs.hands.append([hand.origin, HAND_RADIUS, SpringDefinition.OTHERS])
	for chain: int in _spring_holds.keys():
		var holder: Array = _spring_holds[chain]
		var hand: Variant = _spring_hand(holder[0], holder[1])
		if hand == null or chain >= rig.body.springs.chains.size():
			_spring_holds.erase(chain)
		else:
			rig.body.springs.targets[chain] = hand
	rig.body.springs.advance(delta)


func _spring_hand(peer: int, side: int) -> Variant:
	if peer == multiplayer.get_unique_id():
		return rig.hands[side].global_position if rig.hands[side].tracked() else null
	return (avatars[peer] as Avatar).hands[side].origin if avatars.has(peer) else null


func _spring_request(owner: int, side: int, chain: int) -> void:
	if owner == multiplayer.get_unique_id():
		_hold_spring(owner, side, chain)
	elif owner in multiplayer.get_peers():
		_grab_spring.rpc_id(owner, side, chain)


@rpc("any_peer", "reliable")
func _grab_spring(side: int, chain: int) -> void:
	world.hear("_grab_spring", [side, chain])
	_hold_spring(multiplayer.get_remote_sender_id(), side, chain)


func _hold_spring(peer: int, side: int, chain: int) -> void:
	if side < 0 or side > 1:
		return
	for held in _spring_holds.keys():
		if _spring_holds[held] == [peer, side]:
			_spring_holds.erase(held)
	if chain < 0 or rig.body.springs == null or chain >= rig.body.springs.chains.size() or _spring_holds.has(chain) or not rig.body.springs.grabs(chain, SpringDefinition.WEARER if peer == multiplayer.get_unique_id() else SpringDefinition.OTHERS):
		return
	var hand: Variant = _spring_hand(peer, side)
	if hand != null and hand.distance_to(rig.body.springs.tip(chain)) < 0.2:
		_spring_holds[chain] = [peer, side]
