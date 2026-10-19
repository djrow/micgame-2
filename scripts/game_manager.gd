extends Node

## Central Game Coordinator & State Machine Singleton for V2.
## Coordinates high-level game state, piece metadata, scoring statistics,
## mobile permissions, and serves as the primary signal hub.

enum GameState {
	IDLE,
	PERMISSION_REQUIRED,
	PLAYING,
	PAUSED,
	RESULTS
}

# Compatibility aliases
const PERMISSION_GATE = GameState.PERMISSION_REQUIRED
const SONG_SELECT = GameState.IDLE
const TITLE = GameState.IDLE

signal state_changed(old_state: GameState, new_state: GameState)
signal piece_selected(piece_id: String)
signal piece_loaded(piece_id: String, metadata: Dictionary)
signal game_started()
signal game_paused()
signal game_resumed()
signal game_restarted()
signal game_over(summary: Dictionary)
signal game_finished(summary: Dictionary)
signal score_updated(score: int, combo: int, multiplier: int)
signal note_judged(note_id: int, rating: String, points: int)
signal permission_status_changed(granted: bool)

const BUNDLED_PIECES: Dictionary = {
	"piece_1_monophonic": {
		"id": "piece_1_monophonic",
		"alias_id": "ode_to_joy",
		"title": "Ode to Joy",
		"composer": "Ludwig van Beethoven",
		"bpm": 120.0,
		"time_signature": [4, 4],
		"audio_path": "res://assets/audio/piece_1_monophonic.wav",
		"chart_path": "res://assets/charts/piece_1_monophonic.json",
		"score_path": "res://assets/scores/piece_1_monophonic.png"
	},
	"piece_2_harmony": {
		"id": "piece_2_harmony",
		"alias_id": "bach_minuet",
		"title": "Bach Minuet / 2-Part Counterpoint",
		"composer": "Johann Sebastian Bach",
		"bpm": 100.0,
		"time_signature": [3, 4],
		"audio_path": "res://assets/audio/piece_2_harmony.wav",
		"chart_path": "res://assets/charts/piece_2_harmony.json",
		"score_path": "res://assets/scores/piece_2_harmony.png"
	},
	"piece_3_polyphonic": {
		"id": "piece_3_polyphonic",
		"alias_id": "cadence_triads",
		"title": "Cadence & Triad Progression",
		"composer": "Traditional / Classical",
		"bpm": 80.0,
		"time_signature": [4, 4],
		"audio_path": "res://assets/audio/piece_3_polyphonic.wav",
		"chart_path": "res://assets/charts/piece_3_polyphonic.json",
		"score_path": "res://assets/scores/piece_3_polyphonic.png"
	}
}

var current_state: GameState = GameState.IDLE
var current_piece_id: String = "piece_1_monophonic"
var current_piece_metadata: Dictionary = {}
var is_permission_granted: bool = false

# Score and Telemetry State
var total_score: int = 0
var current_combo: int = 0
var max_combo: int = 0
var multiplier: int = 1
var count_perfect: int = 0
var count_good: int = 0
var count_miss: int = 0

func _ready() -> void:
	_init_permission()
	if BUNDLED_PIECES.has(current_piece_id):
		current_piece_metadata = BUNDLED_PIECES[current_piece_id].duplicate()

func _init_permission() -> void:
	if OS.get_name() == "Android":
		# On Android, permission is initially unconfirmed until requested/granted
		is_permission_granted = false
	elif OS.get_name() == "iOS":
		# iOS manages mic permissions dynamically upon capture start
		is_permission_granted = true
	else:
		# Desktop environments grant audio permissions by default
		is_permission_granted = true

func change_state(new_state: GameState) -> void:
	if new_state == current_state:
		return
	var old_state: GameState = current_state
	current_state = new_state
	state_changed.emit(old_state, new_state)

	match new_state:
		GameState.PLAYING:
			game_started.emit()
		GameState.PAUSED:
			game_paused.emit()
		GameState.RESULTS:
			var summary: Dictionary = get_score_summary()
			game_finished.emit(summary)
			game_over.emit(summary)
		GameState.IDLE:
			pass
		GameState.PERMISSION_REQUIRED:
			pass

func get_state() -> GameState:
	return current_state

func is_state(state: GameState) -> bool:
	return current_state == state

func get_state_name(state: GameState = current_state) -> String:
	match state:
		GameState.IDLE: return "IDLE"
		GameState.PERMISSION_REQUIRED: return "PERMISSION_REQUIRED"
		GameState.PLAYING: return "PLAYING"
		GameState.PAUSED: return "PAUSED"
		GameState.RESULTS: return "RESULTS"
		_: return "UNKNOWN"

func record_judgment(rating: String, points: int = 0, note_id: int = -1) -> void:
	match rating.to_upper():
		"PERFECT":
			count_perfect += 1
			current_combo += 1
			_update_multiplier()
			var earned: int = 100 * multiplier if points <= 0 else points * multiplier
			total_score += earned
		"GOOD":
			count_good += 1
			current_combo += 1
			_update_multiplier()
			var earned: int = 50 * multiplier if points <= 0 else points * multiplier
			total_score += earned
		"MISS":
			count_miss += 1
			current_combo = 0
			multiplier = 1
		_:
			push_warning("GameManager: Unknown judgment rating: " + rating)

	max_combo = maxi(max_combo, current_combo)
	note_judged.emit(note_id, rating, points)
	score_updated.emit(total_score, current_combo, multiplier)

func _update_multiplier() -> void:
	if current_combo >= 30:
		multiplier = 4
	elif current_combo >= 20:
		multiplier = 3
	elif current_combo >= 10:
		multiplier = 2
	else:
		multiplier = 1

func reset_score() -> void:
	total_score = 0
	current_combo = 0
	max_combo = 0
	multiplier = 1
	count_perfect = 0
	count_good = 0
	count_miss = 0
	score_updated.emit(total_score, current_combo, multiplier)

func get_score_summary() -> Dictionary:
	var total_notes: int = count_perfect + count_good + count_miss
	var accuracy: float = 0.0
	if total_notes > 0:
		accuracy = float(count_perfect + count_good) / float(total_notes) * 100.0
	return {
		"score": total_score,
		"max_combo": max_combo,
		"perfect": count_perfect,
		"good": count_good,
		"miss": count_miss,
		"total_notes": total_notes,
		"accuracy": accuracy,
		"piece_id": current_piece_id
	}

func select_piece(piece_id: String) -> bool:
	return load_piece(piece_id)

func load_piece(piece_id: String, custom_metadata: Dictionary = {}) -> bool:
	if BUNDLED_PIECES.has(piece_id):
		current_piece_id = piece_id
		current_piece_metadata = BUNDLED_PIECES[piece_id].duplicate()
		if not custom_metadata.is_empty():
			current_piece_metadata.merge(custom_metadata, true)
	elif not custom_metadata.is_empty():
		current_piece_id = piece_id
		current_piece_metadata = custom_metadata.duplicate()
	else:
		push_error("GameManager: Piece ID not found: " + piece_id)
		return false

	reset_score()
	piece_selected.emit(current_piece_id)
	piece_loaded.emit(current_piece_id, current_piece_metadata)
	return true

func get_current_piece_id() -> String:
	return current_piece_id

func get_current_piece_metadata() -> Dictionary:
	return current_piece_metadata.duplicate()

func get_bundled_pieces() -> Dictionary:
	return BUNDLED_PIECES.duplicate(true)

func start_game() -> void:
	if not is_permission_granted and OS.get_name() == "Android":
		change_state(GameState.PERMISSION_REQUIRED)
		return
	reset_score()
	change_state(GameState.PLAYING)

func pause_game() -> void:
	if current_state == GameState.PLAYING:
		change_state(GameState.PAUSED)

func resume_game() -> void:
	if current_state == GameState.PAUSED:
		change_state(GameState.PLAYING)

func restart_game() -> void:
	reset_score()
	game_restarted.emit()
	change_state(GameState.PLAYING)

func finish_game() -> void:
	change_state(GameState.RESULTS)

func is_microphone_permission_granted() -> bool:
	return is_permission_granted

func request_microphone_permission() -> void:
	if OS.get_name() == "Android":
		OS.request_permission("android.permission.RECORD_AUDIO")
	else:
		set_permission_granted(true)

func set_permission_granted(granted: bool) -> void:
	is_permission_granted = granted
	permission_status_changed.emit(granted)
	if granted and current_state == GameState.PERMISSION_REQUIRED:
		change_state(GameState.IDLE)
