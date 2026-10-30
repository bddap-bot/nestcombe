class_name PlayLog
extends RefCounted

## Recording is on only where this file is in the player folder (Main.player_path): written by --record-sessions or
## by a dev tool on a device of ours, never by the game unasked. It may name another folder to record into.
## Beside each second's metrics row it keeps every frame's input (Replay), every message the network brought, what the
## session's state came to every Replay.CHECK_EVERY frames and the garden as World keeps it, so the ring holds hours of
## all of them.
const SWITCH := "record-sessions"
## A take's arm, a file a dev tool puts in the player folder beside the switch for one acted session: that session's
## record keeps the microphone too (`take`). The session that finds it removes it as it starts, so it arms one session
## whether or not that session records, and nothing the game writes ever sets it. An arm older than ARM_SECONDS is spent
## unused, so one left by a take that never started cannot record whoever plays next.
const ARM := "capture-performance"
const ARM_SECONDS := 600
## The record's format: the events it holds and how a frame lays out (Replay). A record of another replays on no build.
const SCHEMA := 3
const MAX_BYTES := 4194304
const MAX_FILES := 64
var directory: String
var session_id: String
## The armed session's microphone take, a mono 16-bit WAV beside its chunks and outside the ring; "" for any other.
var take := ""
var metadata: Dictionary
var _file: FileAccess
var _part := 0
var _ended := false
var _task := -1
var _skipped := 0
var _write_us := 0
## Frames recorded since the last write, and how many the session recorded before them.
var _input := PackedByteArray()
var _frames := 0
## Checks taken since the last write (`check`, `kept`), each with the frame it was taken in.
var _checks := []
## Messages heard since the last write, each [frame, from, whose, call, args], and how many the session heard before them.
var _heard := []
var _messages := 0
## Microphone frames heard since the last write, the frame the take began at, and the take's file once opened.
var _audio := PackedVector2Array()
var _audio_frame := -1
var _wav: FileAccess


static func enabled(args: Dictionary) -> bool:
	return args.has("record-sessions") or FileAccess.file_exists(Main.player_path(SWITCH))


static func open_enabled(args: Dictionary) -> PlayLog:
	var armed := FileAccess.file_exists(Main.player_path(ARM))
	if armed:
		armed = Time.get_unix_time_from_system() - FileAccess.get_modified_time(Main.player_path(ARM)) < ARM_SECONDS
		if not armed:
			push_warning("a performance take armed over %d s ago is spent unused" % ARM_SECONDS)
		DirAccess.remove_absolute(Main.player_path(ARM))
	if args.has("forget-sessions"):
		DirAccess.remove_absolute(Main.player_path(SWITCH))
		return null
	if not enabled(args):
		if armed:
			push_warning("a performance take was armed on a device that records no sessions; nothing is captured")
		return null
	var folder := Main.player_path("sessions")
	if FileAccess.file_exists(Main.player_path(SWITCH)):
		var saved := FileAccess.get_file_as_string(Main.player_path(SWITCH)).strip_edges()
		if not saved.is_empty():
			folder = saved
	if args.has("record-sessions"):
		folder = str(args.get("session-directory", folder))
		var consent := FileAccess.open(Main.player_path(SWITCH), FileAccess.WRITE)
		if consent != null:
			consent.store_string(folder)
	return PlayLog.new(folder, armed)


func _init(folder: String, armed := false) -> void:
	directory = folder
	DirAccess.make_dir_recursive_absolute(directory)
	var started := Time.get_unix_time_from_system()
	session_id = "%d-%d-%d" % [started * 1000, OS.get_process_id(), Time.get_ticks_usec()]
	metadata = {"schema": SCHEMA, "session": session_id, "started": started, "revision": Main.revision(),
		"os": OS.get_name(), "device": OS.get_model_name(), "input": Replay.layout()}
	if armed:
		take = directory.path_join(session_id + ".wav")
		metadata.take = {"file": take.get_file(), "rate": int(AudioServer.get_mix_rate())}
	_open()


## What the session replays from: the seeds it drew from and the garden it starts in, as World.snapshot gives it.
## The garden is serialized here, so the edits that follow cannot change it under the writer.
func begin(seeds: Dictionary, garden: Dictionary) -> void:
	_join()
	_task = WorkerThreadPool.add_task(_write_replay.bind(seeds, var_to_bytes(garden)))


func _write_replay(seeds: Dictionary, save: PackedByteArray) -> void:
	_store({"event": "replay", "session": session_id, "seeds": seeds, "save_bytes": save.size(),
		"save": Marshalls.raw_to_base64(save.compress(FileAccess.COMPRESSION_DEFLATE))})


## Keeps this frame's input (Replay.frame) for the next write.
func record(frame: PackedByteArray) -> void:
	_input.append_array(frame)


func ended() -> bool:
	return _ended


## Keeps microphone frames (Take) for the next write; a session that is not a take keeps none.
func listen(frames: PackedVector2Array) -> void:
	if take.is_empty() or _ended or frames.is_empty():
		return
	if _audio_frame < 0:
		_audio_frame = frames()
	_audio.append_array(frames)


## Keeps a message for the next write, stamped with the frame it came in before (the count of frames recorded): a
## networked `call` with `args` as it arrived from peer `from`, or 0 for what this machine did itself (a command it
## ordered as host, a join), about player `whose` (the one who made a build command, the one who came or went).
func heard(from: int, whose: int, call: String, args: Array) -> void:
	if not _ended:
		_heard.append([frames(), from, whose, call, args.duplicate(true)])


## The frames recorded so far.
func frames() -> int:
	return _frames + _input.size() / Replay.FRAME_BYTES


## Keeps what the session's state has come to (Replay.check) for the next write, with the frame it was taken in.
func check(parts: Dictionary) -> void:
	if not _ended:
		_checks.append(parts.merged({"frame": frames()}))


## Keeps the garden as World keeps it, its snapshot's bytes once it has run command `seq`, as a check of its own.
func kept(seq: int, garden: PackedByteArray) -> void:
	if not _ended:
		_checks.append({"frame": frames(), "seq": seq, "garden": garden})


func _open() -> void:
	_file = null
	var files := Array(DirAccess.get_files_at(directory)).filter(func(f): return f.ends_with(".jsonl"))
	files.sort()
	while files.size() >= MAX_FILES:
		DirAccess.remove_absolute(directory.path_join(files.pop_front()))
	for wav in Array(DirAccess.get_files_at(directory)).filter(func(f): return f.ends_with(".wav")):
		if not files.any(func(f: String) -> bool: return f.begins_with(wav.get_basename() + "-")):
			DirAccess.remove_absolute(directory.path_join(wav))
	_part += 1
	# Renamed into place holding its start record, so no reader meets a chunk without one.
	var fresh := directory.path_join("chunk.new")
	var start := FileAccess.open(fresh, FileAccess.WRITE)
	if start == null:
		return
	start.store_line(JSON.stringify(metadata.merged({"event": "start", "part": _part})))
	start.close()
	var chunk := directory.path_join("%s-%04d.jsonl" % [session_id, _part - 1])
	if DirAccess.rename_absolute(fresh, chunk) != OK:
		return
	_file = FileAccess.open(chunk, FileAccess.READ_WRITE)
	if _file != null:
		_file.seek_end()


func sample(row: Dictionary) -> void:
	if _task != -1 and not WorkerThreadPool.is_task_completed(_task):
		_skipped += 1
		return
	_join()
	var snapshot := row.duplicate(true)
	snapshot.skipped_log_samples = _skipped
	snapshot.writer_us = _write_us
	_skipped = 0
	_task = WorkerThreadPool.add_task(_write.bind(snapshot, _take_input(), _take_heard(), _take_audio(), _take_checks()))


## The checks kept since the last write.
func _take_checks() -> Array:
	var block := _checks
	_checks = []
	return block


## The microphone frames kept since the last write.
func _take_audio() -> PackedVector2Array:
	var block := _audio
	_audio = PackedVector2Array()
	return block


## The frames kept since the last write, as their "input" event; {} for none.
func _take_input() -> Dictionary:
	if _input.is_empty():
		return {}
	var block := {"first": _frames, "frames": _input.size() / Replay.FRAME_BYTES, "raw": _input}
	_frames += block.frames
	_input = PackedByteArray()
	return block


## The messages heard since the last write, as their "net" event before encoding; {} for none.
func _take_heard() -> Dictionary:
	if _heard.is_empty():
		return {}
	var block := {"first": _messages, "messages": _heard}
	_messages += _heard.size()
	_heard = []
	return block


func _join() -> void:
	if _task != -1:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


func _write(row: Dictionary, input: Dictionary, net: Dictionary, audio: PackedVector2Array, checks: Array) -> void:
	var begin := Time.get_ticks_usec()
	if _file == null or _ended:
		return
	_write_input(input)
	_write_net(net)
	_write_checks(checks)
	_write_audio(audio)
	_store(row.merged({"event": "frame", "session": session_id}))
	_flush()
	_write_us = Time.get_ticks_usec() - begin


func _write_input(input: Dictionary) -> void:
	if input.is_empty():
		return
	var raw: PackedByteArray = input.raw
	_store({"event": "input", "session": session_id, "first": input.first, "frames": input.frames, "bytes": raw.size(),
		"data": Marshalls.raw_to_base64(raw.compress(FileAccess.COMPRESSION_DEFLATE))})


## The checks, each part's bytes digested here, off the main thread.
func _write_checks(checks: Array) -> void:
	if checks.is_empty():
		return
	for c: Dictionary in checks:
		for part in c:
			if c[part] is PackedByteArray:
				c[part] = Replay.digest(c[part])
	_store({"event": "checks", "session": session_id, "checks": checks})


## Each message's arguments in Godot's own binary encoding, the bytes the network carries, which `bytes_to_var` reads.
func _write_net(net: Dictionary) -> void:
	if net.is_empty():
		return
	var raw := var_to_bytes(net.messages.map(func(m: Array) -> Array: return _without_files(m[4])))
	var index: Array = net.messages.map(func(m: Array) -> Array: return m.slice(0, 4))
	_store({"event": "net", "session": session_id, "first": net.first, "messages": index, "bytes": raw.size(),
		"data": Marshalls.raw_to_base64(raw.compress(FileAccess.COMPRESSION_DEFLATE))})


## A file a message carries, the only bytes any does (an avatar), is kept as its SHA-256 and length, never the file.
static func _without_files(args: Array) -> Array:
	return args.map(func(a: Variant) -> Variant:
		if a is PackedByteArray and not a.is_empty():
			return {"sha256": Session.sha256(a), "bytes": a.size()}
		return a)


## Appends `audio` to the take as mono 16-bit samples, opening it on the first, when a `take` record notes the input
## frame its first sample came in before. Each write leaves the header whole, so a killed session's take still plays.
func _write_audio(audio: PackedVector2Array) -> void:
	if audio.is_empty():
		return
	if _wav == null:
		_wav = FileAccess.open(take, FileAccess.WRITE)
		if _wav == null:
			return
		var rate: int = metadata.take.rate
		_wav.store_buffer("RIFF".to_ascii_buffer())
		_wav.store_32(36)
		_wav.store_buffer("WAVEfmt ".to_ascii_buffer())
		for v in [16, 1 | 1 << 16, rate, rate * 2, 2 | 16 << 16]:
			_wav.store_32(v)
		_wav.store_buffer("data".to_ascii_buffer())
		_wav.store_32(0)
		_store({"event": "take", "session": session_id, "frame": _audio_frame})
	var pcm := PackedByteArray()
	pcm.resize(audio.size() * 2)
	for i in audio.size():
		pcm.encode_s16(i * 2, int(clampf((audio[i].x + audio[i].y) * 0.5, -1.0, 1.0) * 32767.0))
	_wav.store_buffer(pcm)
	var data := _wav.get_position() - 44
	_wav.seek(4)
	_wav.store_32(36 + data)
	_wav.seek(40)
	_wav.store_32(data)
	_wav.seek_end()


## Appends `record` as a line of the current chunk, opening the next first when it would outgrow MAX_BYTES.
func _store(record: Dictionary) -> void:
	if _file == null:
		return
	var line := JSON.stringify(record)
	if _file.get_position() + line.length() + 1024 > MAX_BYTES:
		_open()
	if _file == null:
		return
	_file.store_line(line)


## Once a write: each flush of a Quest's shared storage costs the writer milliseconds.
func _flush() -> void:
	if _file != null:
		_file.flush()
	if _wav != null:
		_wav.flush()


func finish() -> void:
	_join()
	if _ended:
		return
	_write_input(_take_input())
	_write_net(_take_heard())
	_write_checks(_take_checks())
	_write_audio(_take_audio())
	if _wav != null:
		_wav.close()
		_wav = null
	_ended = true
	if _file != null:
		_file.store_line(JSON.stringify({"event": "end", "session": session_id, "ended": Time.get_unix_time_from_system()}))
		_file.close()
		_file = null
