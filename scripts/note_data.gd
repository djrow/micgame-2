class_name NoteData
extends Resource

## Represents a single musical note event on the Grand Staff Highway for V2.
## Implements exact diatonic notation properties, vertical coordinate placement,
## ledger line derivation, accidental parsing, and scoring state tracking.

const DIATONIC_OFFSETS: Array[int] = [0, 0, 1, 1, 2, 3, 3, 4, 4, 5, 5, 6]
const IS_ACCIDENTAL_TABLE: Array[bool] = [false, true, false, true, false, false, true, false, true, false, true, false]
const PITCH_NAMES: Array[String] = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

const Y_CENTER: float = 360.0 # Middle C4 ledger line / center receptor
const LINE_SPACING: float = 18.0
const STEP_DY: float = 9.0 # LINE_SPACING / 2.0 (diatonic step Y distance)
const MIDDLE_C_STEP: int = 28 # C4 (MIDI 60)

# Core note event attributes
@export var id: int = 0
@export var pitch_midi: int = 60:
	set(value):
		pitch_midi = clampi(value, 0, 127)
		_compute_notation_properties()

var pitch: int:
	get: return pitch_midi
	set(value): pitch_midi = value

@export var time_sec: float = 0.0:
	set(value): time_sec = maxf(0.0, value)

var start_time: float:
	get: return time_sec
	set(value): time_sec = value

@export var duration_sec: float = 0.0:
	set(value): duration_sec = maxf(0.0, value)

var duration: float:
	get: return duration_sec
	set(value): duration_sec = value

@export var staff: String = "treble" # "treble" or "bass"
@export var chord_id: int = -1

# Precomputed notation & layout properties
var pitch_name: String = "C4"
var diatonic_step: int = 28
var is_accidental: bool = false
var accidental: int = 0 # -1 = flat, 0 = natural, 1 = sharp
var accidental_type: String = "" # "#" or "b"
var y_pos: float = 360.0
var ledger_y_positions: Array[float] = []
var chord_offset_x: float = 0.0

# Gameplay evaluation state
var is_hit: bool = false
var is_missed: bool = false
var is_scored: bool:
	get: return is_hit or is_missed
	set(value): is_hit = value

var hit_time: float = -1.0
var hit_rating: String = "" # "PERFECT", "GOOD", "MISS"
var hit_score: int = 0

var rating: String:
	get: return hit_rating
	set(value): hit_rating = value

var score_awarded: int:
	get: return hit_score
	set(value): hit_score = value

var points: int:
	get: return hit_score
	set(value): hit_score = value

func _init(p_id: int = 0, p_midi: int = 60, p_time: float = 0.0, p_dur: float = 0.0, p_staff: String = "", p_chord_id: int = -1) -> void:
	id = p_id
	pitch_midi = clampi(p_midi, 0, 127)
	time_sec = maxf(0.0, p_time)
	duration_sec = maxf(0.0, p_dur)
	chord_id = p_chord_id
	staff = p_staff if p_staff != "" else ("treble" if pitch_midi >= 60 else "bass")
	_compute_notation_properties()

func _compute_notation_properties() -> void:
	var pc: int = pitch_midi % 12
	var oct: int = int(floor(float(pitch_midi) / 12.0)) - 1
	diatonic_step = oct * 7 + DIATONIC_OFFSETS[pc]
	is_accidental = IS_ACCIDENTAL_TABLE[pc]
	accidental = 1 if is_accidental else 0
	accidental_type = "#" if is_accidental else ""
	pitch_name = PITCH_NAMES[pc] + str(oct)

	# Middle C is Y=360.0. Higher pitches have smaller Y (higher on screen).
	y_pos = Y_CENTER - float(diatonic_step - MIDDLE_C_STEP) * STEP_DY

	ledger_y_positions.clear()
	var steps: Array[int] = get_ledger_steps(diatonic_step)
	for s in steps:
		ledger_y_positions.append(step_to_y(s))

static func midi_to_step(midi: int) -> int:
	var clamped: int = clampi(midi, 0, 127)
	var pc: int = clamped % 12
	var oct: int = int(floor(float(clamped) / 12.0)) - 1
	return oct * 7 + DIATONIC_OFFSETS[pc]

static func step_to_y(step: int) -> float:
	return Y_CENTER - float(step - MIDDLE_C_STEP) * STEP_DY

static func midi_to_y(midi: int) -> float:
	return step_to_y(midi_to_step(midi))

static func midi_to_pitch_name(midi: int) -> String:
	var clamped: int = clampi(midi, 0, 127)
	var pc: int = clamped % 12
	var oct: int = int(floor(float(clamped) / 12.0)) - 1
	return PITCH_NAMES[pc] + str(oct)

## Returns the array of diatonic step indices that require horizontal ledger lines.
## Middle C (step 28) has its own ledger line.
## High notes above Treble staff (step >= 40, i.e. A5 and higher) get ledger lines on even steps.
## Low notes below Bass staff (step <= 16, i.e. E2 and lower) get ledger lines on even steps.
static func get_ledger_steps(step: int) -> Array[int]:
	var ledgers: Array[int] = []
	if step == MIDDLE_C_STEP:
		ledgers.append(MIDDLE_C_STEP)
	elif step >= 40:
		var max_even: int = step if (step % 2 == 0) else (step - 1)
		var s: int = 40
		while s <= max_even:
			ledgers.append(s)
			s += 2
	elif step <= 16:
		var min_even: int = step if (step % 2 == 0) else (step + 1)
		var s: int = 16
		while s >= min_even:
			ledgers.append(s)
			s -= 2
	return ledgers

static func from_dict(dict: Dictionary, note_id: int = 0) -> NoteData:
	var midi_val: int = int(dict.get("pitch_midi", dict.get("pitch", dict.get("midi", 60))))
	var t_val: float = float(dict.get("time_sec", dict.get("start_time", dict.get("time", 0.0))))
	var d_val: float = float(dict.get("duration_sec", dict.get("duration", 0.0)))
	var st: String = str(dict.get("staff", ""))
	var cid: int = int(dict.get("chord_id", -1))
	var note: NoteData = NoteData.new(note_id, midi_val, t_val, d_val, st, cid)
	if dict.has("chord_offset_x"):
		note.chord_offset_x = float(dict["chord_offset_x"])
	return note

func to_dict() -> Dictionary:
	return {
		"id": id,
		"pitch_midi": pitch_midi,
		"pitch": pitch_midi,
		"pitch_name": pitch_name,
		"time_sec": time_sec,
		"start_time": time_sec,
		"duration_sec": duration_sec,
		"duration": duration_sec,
		"staff": staff,
		"chord_id": chord_id,
		"diatonic_step": diatonic_step,
		"is_accidental": is_accidental,
		"accidental": accidental,
		"accidental_type": accidental_type,
		"y_pos": y_pos,
		"chord_offset_x": chord_offset_x,
		"is_hit": is_hit,
		"is_missed": is_missed,
		"is_scored": is_scored,
		"hit_rating": hit_rating,
		"hit_score": hit_score
	}

func duplicate_note() -> NoteData:
	var copy: NoteData = NoteData.new(id, pitch_midi, time_sec, duration_sec, staff, chord_id)
	copy.chord_offset_x = chord_offset_x
	copy.is_hit = is_hit
	copy.is_missed = is_missed
	copy.hit_time = hit_time
	copy.hit_rating = hit_rating
	copy.hit_score = hit_score
	return copy
