class_name MockDriver
extends "res://scripts/inference/audio_pitch_model.gd"

## Offline / Mock pitch model runner for deterministic test harnesses, CI automation,
## and chart playback simulation without microphone input.

var _active_pitches: Array[int] = []
var _recent_onsets: Array[int] = []
var _confidence_map: Dictionary = {}
var _samples_processed: int = 0
var _chart_notes: Array = []
var _is_chart_mode: bool = false
var _onset_window_sec: float = 0.050

func _init(initial_pitches: Array = []) -> void:
	if not initial_pitches.is_empty():
		set_detected_pitches(initial_pitches)

## Programmatically feeds active sustained pitches.
func set_detected_pitches(pitches: Array) -> void:
	_active_pitches.clear()
	_confidence_map.clear()
	for p in pitches:
		var midi_val: int = int(p)
		_active_pitches.append(midi_val)
		_confidence_map[str(midi_val)] = 1.0
	pitches_detected.emit(_active_pitches)

## Programmatically feeds recent note onsets.
func set_recent_onsets(onsets: Array) -> void:
	_recent_onsets.clear()
	for o in onsets:
		_recent_onsets.append(int(o))
	onsets_detected.emit(_recent_onsets)

## Convenience method to inject chord pitches as both active and onset pitches.
func inject_chord(pitches: Array) -> void:
	set_detected_pitches(pitches)
	set_recent_onsets(pitches)

## Loads chart notes to simulate player input synchronized to playhead time.
func load_chart(notes: Array) -> void:
	_chart_notes = notes.duplicate(true)
	_is_chart_mode = true

## Loads chart notes directly from a JSON file path.
func load_chart_from_file(file_path: String) -> Error:
	if not FileAccess.file_exists(file_path):
		model_error.emit("Chart file not found: %s" % file_path)
		return ERR_FILE_NOT_FOUND
	var file: FileAccess = FileAccess.open(file_path, FileAccess.READ)
	var content: String = file.get_as_text()
	var json: JSON = JSON.new()
	var err: Error = json.parse(content)
	if err != OK:
		model_error.emit("Failed to parse chart JSON: %d" % err)
		return err
	var data: Variant = json.data
	if data is Dictionary and data.has("notes"):
		load_chart(data["notes"])
		return OK
	return ERR_INVALID_DATA

## Updates chart playback mode based on current song time.
## Populates _active_pitches with currently sustained notes and
## _recent_onsets with notes whose onset is within _onset_window_sec.
func update_playback_time(current_time: float) -> void:
	if not _is_chart_mode:
		return

	var active_set: Array[int] = []
	var onset_set: Array[int] = []

	for n in _chart_notes:
		var pitch: int = 0
		var time_sec: float = 0.0
		var dur: float = 0.2

		if n is Dictionary:
			pitch = int(n.get("pitch_midi", 0))
			time_sec = float(n.get("time_sec", 0.0))
			dur = float(n.get("duration_sec", 0.2))
		elif n is RefCounted and "pitch_midi" in n and "time_sec" in n:
			pitch = n.pitch_midi
			time_sec = n.time_sec
			dur = n.duration_sec if "duration_sec" in n else 0.2

		# Sustained note duration check
		if current_time >= time_sec and current_time <= (time_sec + dur):
			if not active_set.has(pitch):
				active_set.append(pitch)

		# Attack / onset window check
		if absf(current_time - time_sec) <= _onset_window_sec:
			if not onset_set.has(pitch):
				onset_set.append(pitch)

	_active_pitches = active_set
	_recent_onsets = onset_set

	if not _active_pitches.is_empty():
		pitches_detected.emit(_active_pitches)
	if not _recent_onsets.is_empty():
		onsets_detected.emit(_recent_onsets)

## Accepts audio samples and tracks throughput.
func push_audio_samples(samples: PackedFloat32Array) -> void:
	_samples_processed += samples.size()

func get_detected_pitches() -> Array[int]:
	return _active_pitches

func get_recent_onsets(clear: bool = false) -> Array[int]:
	var copy: Array[int] = _recent_onsets.duplicate()
	if clear:
		_recent_onsets.clear()
	return copy

func pop_recent_onsets() -> Array[int]:
	return get_recent_onsets(true)

func is_model_ready() -> bool:
	return true

func reset() -> void:
	_active_pitches.clear()
	_recent_onsets.clear()
	_confidence_map.clear()
	_samples_processed = 0
	_chart_notes.clear()
	_is_chart_mode = false

func poll(_delta: float = 0.0) -> void:
	pass

func get_confidence_map() -> Dictionary:
	return _confidence_map

func get_last_latency_ms() -> float:
	return 0.1
