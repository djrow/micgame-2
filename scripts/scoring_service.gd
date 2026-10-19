extends Node

## ScoringService: Autoload Singleton for polyphonic note matching, timing windows,
## combo multipliers, sustain re-trigger filtering, and performance telemetry.
## Fully supports both NoteData instances and Dictionary chart fixtures.

# Timing Windows (seconds)
const WINDOW_PERFECT_SEC: float = 0.050  # +/- 50ms
const WINDOW_GOOD_SEC: float = 0.100     # +/- 100ms
const TIMING_EPSILON: float = 0.0000001  # 0.1 microsecond tolerance for IEEE 754 precision

# Multiplier Combo Thresholds
const COMBO_2X: int = 10
const COMBO_3X: int = 20
const COMBO_4X: int = 30

enum MultiplierMode {
	INTEGER_TIERS,  # 1x, 2x, 3x, 4x
	FLOAT_SCALED    # 1.0x, 1.5x, 2.0x, 4.0x
}

# --- Service Signals (V2 Interface Contract) ---
signal note_scored(note: Variant, rating: String, points: int)
signal score_updated(score: int, combo: int, multiplier: float)
signal combo_broken()
signal chord_matched(chord_id: int, rating: String, accuracy: float)

# Compatibility signals
signal score_changed(new_score: int)
signal combo_changed(new_combo: int, new_multiplier: int)
signal judgment_recorded(judgment: String, points: int, current_score: int, current_combo: int, current_multiplier: int, note_data: Dictionary)

# --- Configurable Parameters ---
@export var points_perfect: int = 100
@export var points_good: int = 50
@export var points_miss: int = 0
@export var multiplier_mode: MultiplierMode = MultiplierMode.INTEGER_TIERS
@export var semitone_tolerance: int = 0
@export var input_calibration_offset_sec: float = 0.0
@export var auto_sync_game_manager: bool = true

# --- State Variables ---
var active_chart_notes: Array = []
var playhead_time: float = 0.0

var total_score: int = 0
var current_combo: int = 0
var max_combo: int = 0
var count_perfect: int = 0
var count_good: int = 0
var count_miss: int = 0
var total_notes: int = 0

# Sustain & Refractory Tracking
var _last_detected_pitches: Array[int] = []
var _pitch_refractory_until: Dictionary = {}

func _init() -> void:
	reset_score()

func reset() -> void:
	reset_score()

func reset_score() -> void:
	total_score = 0
	current_combo = 0
	max_combo = 0
	count_perfect = 0
	count_good = 0
	count_miss = 0
	total_notes = 0
	_last_detected_pitches.clear()
	_pitch_refractory_until.clear()
	score_updated.emit(total_score, current_combo, get_multiplier_float())
	score_changed.emit(total_score)
	combo_changed.emit(current_combo, get_multiplier())

func set_active_chart(notes: Array) -> void:
	active_chart_notes = notes.duplicate()
	reset_score()

func update_playhead(song_time: float) -> void:
	playhead_time = song_time
	if not active_chart_notes.is_empty():
		check_expired_notes(song_time, active_chart_notes)

func get_multiplier() -> int:
	if current_combo >= COMBO_4X:
		return 4
	elif current_combo >= COMBO_3X:
		return 3
	elif current_combo >= COMBO_2X:
		return 2
	else:
		return 1

func get_multiplier_float() -> float:
	if multiplier_mode == MultiplierMode.FLOAT_SCALED:
		if current_combo >= COMBO_4X:
			return 4.0
		elif current_combo >= COMBO_3X:
			return 2.0
		elif current_combo >= COMBO_2X:
			return 1.5
		else:
			return 1.0
	else:
		return float(get_multiplier())

func evaluate_timing(time_diff_sec: float) -> String:
	if is_nan(time_diff_sec) or is_inf(time_diff_sec):
		return "MISS"
	var abs_diff: float = abs(time_diff_sec)
	if abs_diff <= WINDOW_PERFECT_SEC + TIMING_EPSILON:
		return "PERFECT"
	elif abs_diff <= WINDOW_GOOD_SEC + TIMING_EPSILON:
		return "GOOD"
	else:
		return "MISS"

func register_hit(judgment: String, note_data: Variant = null) -> Dictionary:
	if judgment != "PERFECT" and judgment != "GOOD" and judgment != "MISS":
		push_warning("ScoringService: Unknown judgment: " + judgment)
		return {}

	total_notes += 1
	var base_pts: int = 0

	if judgment == "PERFECT":
		count_perfect += 1
		current_combo += 1
		base_pts = points_perfect
	elif judgment == "GOOD":
		count_good += 1
		current_combo += 1
		base_pts = points_good
	elif judgment == "MISS":
		count_miss += 1
		current_combo = 0
		base_pts = points_miss
		combo_broken.emit()

	max_combo = maxi(max_combo, current_combo)

	var mult_float: float = get_multiplier_float()
	var mult_int: int = get_multiplier()
	var points_awarded: int = int(round(float(base_pts) * mult_float))
	total_score += points_awarded

	var note_dict: Dictionary = {}
	if note_data is Dictionary:
		note_dict = note_data
	elif note_data is RefCounted and note_data.has_method("to_dict"):
		note_dict = note_data.to_dict()

	var result: Dictionary = {
		"judgment": judgment,
		"base_points": base_pts,
		"multiplier": mult_int,
		"multiplier_float": mult_float,
		"points_awarded": points_awarded,
		"score": total_score,
		"combo": current_combo,
		"max_combo": max_combo,
		"note_data": note_dict
	}

	note_scored.emit(note_data if note_data != null else note_dict, judgment, points_awarded)
	score_updated.emit(total_score, current_combo, mult_float)
	score_changed.emit(total_score)
	combo_changed.emit(current_combo, mult_int)
	judgment_recorded.emit(judgment, points_awarded, total_score, current_combo, mult_int, note_dict)

	if auto_sync_game_manager and is_inside_tree() and has_node("/root/GameManager"):
		var gm = get_node("/root/GameManager")
		if gm.has_method("record_judgment"):
			var note_id: int = int(note_dict.get("id", -1))
			gm.record_judgment(judgment, points_awarded, note_id)

	return result

func register_miss(note_data: Variant = null) -> Dictionary:
	return register_hit("MISS", note_data)

## Matches incoming pitch and timestamp against target notes array.
## Fully supports NoteData instances and Dictionary fixtures.
func process_input(input_time: float, pitch_midi: int, notes: Array, p_tolerance: int = 0) -> Dictionary:
	var best_index: int = -1
	var min_abs_diff: float = 9999.0

	for i in range(notes.size()):
		var note = notes[i]
		var is_hit: bool = false
		var is_missed: bool = false
		var note_pitch: int = 0
		var note_time: float = 0.0

		if note is Dictionary:
			is_hit = bool(note.get("is_hit", false))
			is_missed = bool(note.get("is_missed", false))
			if not note.has("time_sec") or not note.has("pitch_midi"):
				continue
			note_pitch = int(note.get("pitch_midi", 0))
			note_time = float(note.get("time_sec", 0.0))
		elif note is RefCounted and "pitch_midi" in note and "time_sec" in note:
			is_hit = note.is_hit if "is_hit" in note else false
			is_missed = note.is_missed if "is_missed" in note else false
			note_pitch = note.pitch_midi
			note_time = note.time_sec
		else:
			continue

		# Prevent hitting already hit or already expired notes
		if is_hit or is_missed:
			continue

		if abs(note_pitch - pitch_midi) > p_tolerance:
			continue

		var time_diff: float = input_time - note_time
		var abs_diff: float = abs(time_diff)

		# Must be within hit window (+/- 100ms)
		if abs_diff <= (WINDOW_GOOD_SEC + TIMING_EPSILON) and abs_diff < min_abs_diff:
			min_abs_diff = abs_diff
			best_index = i

	if best_index != -1:
		var target_note = notes[best_index]
		var time_diff: float = 0.0
		var note_dict: Dictionary = {}

		if target_note is Dictionary:
			time_diff = input_time - float(target_note.get("time_sec", 0.0))
			var judgment: String = evaluate_timing(time_diff)
			target_note["is_hit"] = true
			target_note["hit_time"] = input_time
			target_note["hit_diff"] = time_diff
			target_note["hit_rating"] = judgment
			target_note["judgment"] = judgment
			note_dict = target_note
			var result: Dictionary = register_hit(judgment, target_note)
			result["matched_note_index"] = best_index
			result["time_diff"] = time_diff
			target_note["hit_score"] = result.get("points_awarded", 0)
			return result
		elif target_note is RefCounted and "time_sec" in target_note:
			time_diff = input_time - target_note.time_sec
			var judgment: String = evaluate_timing(time_diff)
			target_note.is_hit = true
			if "hit_time" in target_note: target_note.hit_time = input_time
			if "hit_diff" in target_note: target_note.hit_diff = time_diff
			if "hit_rating" in target_note: target_note.hit_rating = judgment
			if "judgment" in target_note: target_note.judgment = judgment
			if target_note.has_method("to_dict"):
				note_dict = target_note.to_dict()
			var result: Dictionary = register_hit(judgment, target_note)
			result["matched_note_index"] = best_index
			result["time_diff"] = time_diff
			if "hit_score" in target_note: target_note.hit_score = result.get("points_awarded", 0)
			return result

	return {}

## Evaluates polyphonic detected pitches and onsets from InferenceService.
## Implements edge-triggering and sustain re-trigger filtering.
func process_detected_pitches(pitches: Array[int], onsets: Array[int], current_time: float) -> Array[Dictionary]:
	playhead_time = current_time
	var eval_time: float = maxf(0.0, current_time - input_calibration_offset_sec)
	var hits: Array[Dictionary] = []

	# Edge-triggering: candidate strikes include:
	# 1. Any pitch explicitly triggered as an onset
	# 2. Any newly detected pitch (transitioned from inactive to active)
	var candidate_pitches: Array[int] = []
	for p in onsets:
		if not candidate_pitches.has(p):
			candidate_pitches.append(p)

	for p in pitches:
		if not _last_detected_pitches.has(p) and not candidate_pitches.has(p):
			# Check refractory period
			var refractory_until: float = float(_pitch_refractory_until.get(p, 0.0))
			if eval_time >= refractory_until:
				candidate_pitches.append(p)

	_last_detected_pitches.clear()
	for p in pitches:
		_last_detected_pitches.append(p)

	if candidate_pitches.is_empty():
		return hits

	var target_notes: Array = active_chart_notes
	for pitch in candidate_pitches:
		var res: Dictionary = process_input(eval_time, pitch, target_notes, semitone_tolerance)
		if not res.is_empty():
			hits.append(res)
			# Set refractory period to prevent sustained buzz
			_pitch_refractory_until[pitch] = eval_time + 0.120

	return hits

## Evaluates active notes passing beyond hit window (+100ms) without being hit.
func check_expired_notes(current_time: float, notes: Array) -> Array:
	var expired_events: Array = []
	for i in range(notes.size()):
		var note = notes[i]
		if note is Dictionary:
			if note.get("is_hit", false) or note.get("is_missed", false):
				continue
			var note_time: float = float(note.get("time_sec", 0.0))
			if current_time > note_time + WINDOW_GOOD_SEC:
				note["is_missed"] = true
				note["is_hit"] = false
				note["hit_rating"] = "MISS"
				var result: Dictionary = register_miss(note)
				result["matched_note_index"] = i
				expired_events.append(result)
		elif note is RefCounted and "time_sec" in note:
			var is_hit: bool = note.is_hit if "is_hit" in note else false
			var is_missed: bool = note.is_missed if "is_missed" in note else false
			if is_hit or is_missed:
				continue
			var note_time: float = note.time_sec
			if current_time > note_time + WINDOW_GOOD_SEC:
				if "is_missed" in note: note.is_missed = true
				if "is_hit" in note: note.is_hit = false
				if "hit_rating" in note: note.hit_rating = "MISS"
				var note_dict: Dictionary = note.to_dict() if note.has_method("to_dict") else {}
				var result: Dictionary = register_miss(note)
				result["matched_note_index"] = i
				expired_events.append(result)

	return expired_events

func get_accuracy() -> float:
	if total_notes == 0:
		return 100.0
	var weighted_hits: float = (float(count_perfect) * 1.0) + (float(count_good) * 0.5)
	return (weighted_hits / float(total_notes)) * 100.0

func get_summary() -> Dictionary:
	return {
		"score": total_score,
		"combo": current_combo,
		"max_combo": max_combo,
		"multiplier": get_multiplier(),
		"multiplier_float": get_multiplier_float(),
		"total_notes": total_notes,
		"count_perfect": count_perfect,
		"count_good": count_good,
		"count_miss": count_miss,
		"accuracy_pct": get_accuracy()
	}

# Compatibility getters
func get_score() -> int: return total_score
func get_combo() -> int: return current_combo
func get_max_combo() -> int: return max_combo
