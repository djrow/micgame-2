class_name LevelLoader
extends Node

## Level Loader & Audio-Chart Alignment Engine for MicGame-2.
## Coordinates loading rhythm levels from either pre-existing chart JSON files
## or on-the-fly sheet music OMR, pairs accompaniment audio (WAV/MP3/OGG),
## validates timing alignments, and passes configured notes to Highway & ScoringService.

signal level_loaded(level_data: Dictionary)
signal level_load_failed(error_message: String)
signal alignment_completed(alignment_info: Dictionary)

const BUNDLED_PIECES: Dictionary = {
	"piece_1_monophonic": {
		"id": "piece_1_monophonic",
		"alias_id": "ode_to_joy",
		"title": "Ode to Joy",
		"composer": "Ludwig van Beethoven",
		"bpm": 120.0,
		"time_signature": [4, 4],
		"score_path": "res://assets/scores/piece_1_monophonic.png",
		"audio_path": "res://assets/audio/piece_1_monophonic.wav",
		"chart_path": "res://assets/charts/piece_1_monophonic.json",
		"alt_score_path": "res://assets/test_pieces/piece_1_monophonic/score.png",
		"alt_audio_path": "res://assets/test_pieces/piece_1_monophonic/audio.wav",
		"alt_chart_path": "res://assets/test_pieces/piece_1_monophonic/ground_truth.json"
	},
	"piece_2_harmony": {
		"id": "piece_2_harmony",
		"alias_id": "bach_minuet",
		"title": "Bach Minuet / 2-Part Counterpoint",
		"composer": "Johann Sebastian Bach",
		"bpm": 100.0,
		"time_signature": [3, 4],
		"score_path": "res://assets/scores/piece_2_harmony.png",
		"audio_path": "res://assets/audio/piece_2_harmony.wav",
		"chart_path": "res://assets/charts/piece_2_harmony.json",
		"alt_score_path": "res://assets/test_pieces/piece_2_harmony/score.png",
		"alt_audio_path": "res://assets/test_pieces/piece_2_harmony/audio.wav",
		"alt_chart_path": "res://assets/test_pieces/piece_2_harmony/ground_truth.json"
	},
	"piece_3_polyphonic": {
		"id": "piece_3_polyphonic",
		"alias_id": "cadence_triads",
		"title": "Cadence & Triad Progression",
		"composer": "Traditional / Classical",
		"bpm": 80.0,
		"time_signature": [4, 4],
		"score_path": "res://assets/scores/piece_3_polyphonic.png",
		"audio_path": "res://assets/audio/piece_3_polyphonic.wav",
		"chart_path": "res://assets/charts/piece_3_polyphonic.json",
		"alt_score_path": "res://assets/test_pieces/piece_3_polyphonic/score.png",
		"alt_audio_path": "res://assets/test_pieces/piece_3_polyphonic/audio.wav",
		"alt_chart_path": "res://assets/test_pieces/piece_3_polyphonic/ground_truth.json"
	}
}

const PITCH_NAMES: Array[String] = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

@export var calibration_offset_ms: float = 0.0 # Latency compensation in milliseconds
@export var auto_align_timestamps: bool = true
@export var duration_tolerance_sec: float = 1.0

var current_level_data: Dictionary = {}

## Sets in-game calibration offset in milliseconds
func set_calibration_offset_ms(offset_ms: float) -> void:
	calibration_offset_ms = offset_ms
	if not current_level_data.is_empty():
		current_level_data["calibration_offset_ms"] = offset_ms
		current_level_data["calibration_offset_sec"] = offset_ms / 1000.0

## Gets current calibration offset in seconds
func get_calibration_offset_sec() -> float:
	return calibration_offset_ms / 1000.0

## Resolves file path checking both primary and alternative paths
func _resolve_piece_path(primary: String, alt: String) -> String:
	if ResourceLoader.exists(primary) or FileAccess.file_exists(primary) or FileAccess.file_exists(ProjectSettings.globalize_path(primary)):
		return primary
	if alt != "" and (ResourceLoader.exists(alt) or FileAccess.file_exists(alt) or FileAccess.file_exists(ProjectSettings.globalize_path(alt))):
		return alt
	return primary

## Loads level from chart source and audio source
## chart_source can be:
## 1. Dictionary (already parsed chart)
## 2. String ending in .json (pre-computed chart file)
## 3. String ending in .png/.jpg/.jpeg (score image, processed via on-device OMR)
## 4. String piece_id ("piece_1_monophonic", "piece_2_harmony", "piece_3_polyphonic" or aliases)
func load_level(chart_source: Variant, audio_source: Variant = null, options: Dictionary = {}) -> Dictionary:
	var chart_dict: Dictionary = {}
	var audio_path_to_load: String = ""

	# 1. Resolve Chart Source
	if chart_source is Dictionary:
		chart_dict = chart_source
	elif chart_source is String:
		var path_str: String = chart_source
		var resolved_piece_key: String = ""

		if BUNDLED_PIECES.has(path_str):
			resolved_piece_key = path_str
		else:
			for k in BUNDLED_PIECES:
				if BUNDLED_PIECES[k].get("alias_id") == path_str:
					resolved_piece_key = k
					break

		if resolved_piece_key != "":
			var piece_info: Dictionary = BUNDLED_PIECES[resolved_piece_key]
			var use_omr: bool = options.get("use_omr", false)
			var chart_p: String = _resolve_piece_path(piece_info.get("chart_path", ""), piece_info.get("alt_chart_path", ""))
			var score_p: String = _resolve_piece_path(piece_info.get("score_path", ""), piece_info.get("alt_score_path", ""))
			var audio_p: String = _resolve_piece_path(piece_info.get("audio_path", ""), piece_info.get("alt_audio_path", ""))

			if use_omr:
				chart_dict = load_chart_from_omr(score_p, piece_info["bpm"], piece_info["time_signature"])
			else:
				chart_dict = load_chart_from_json(chart_p)
			if audio_source == null:
				audio_path_to_load = audio_p
		elif path_str.ends_with(".json"):
			chart_dict = load_chart_from_json(path_str)
		elif path_str.ends_with(".png") or path_str.ends_with(".jpg") or path_str.ends_with(".jpeg"):
			var bpm: float = float(options.get("bpm", 120.0))
			var ts: Array = options.get("time_signature", [4, 4])
			chart_dict = load_chart_from_omr(path_str, bpm, ts)
		else:
			push_error("LevelLoader: Unknown chart source format: " + path_str)
			level_load_failed.emit("Unknown chart source format: " + path_str)
			return {}

	if chart_dict.is_empty():
		push_error("LevelLoader: Failed to load chart from source.")
		level_load_failed.emit("Failed to load chart.")
		return {}

	# 2. Resolve Audio Stream
	var stream: AudioStream = null
	if audio_source is AudioStream:
		stream = audio_source
	elif audio_source is String and audio_source != "":
		stream = load_audio_stream(audio_source)
	elif audio_path_to_load != "":
		stream = load_audio_stream(audio_path_to_load)
	elif chart_dict.has("audio_file") and str(chart_dict["audio_file"]) != "":
		var relative_audio: String = str(chart_dict["audio_file"])
		if chart_source is String and (chart_source.begins_with("res://") or chart_source.begins_with("user://")):
			var base_dir: String = chart_source.get_base_dir()
			stream = load_audio_stream(base_dir.path_join(relative_audio))
		else:
			stream = load_audio_stream(relative_audio)

	# 3. Align Level Notes and Audio
	var aligned_level: Dictionary = align_level(chart_dict, stream, options)
	current_level_data = aligned_level
	level_loaded.emit(aligned_level)
	return aligned_level

## Loads pre-computed chart JSON file from disk
func load_chart_from_json(json_path: String) -> Dictionary:
	var abs_path: String = ProjectSettings.globalize_path(json_path)
	if not FileAccess.file_exists(abs_path) and not FileAccess.file_exists(json_path):
		push_error("LevelLoader: JSON file does not exist: " + json_path)
		return {}

	var file_text: String = FileAccess.get_file_as_string(json_path)
	if file_text.is_empty():
		file_text = FileAccess.get_file_as_string(abs_path)

	var parsed: Variant = JSON.parse_string(file_text)
	if parsed is Dictionary:
		return parsed
	else:
		push_error("LevelLoader: Failed to parse JSON chart from: " + json_path)
		return {}

## Digitize score image via on-device OMRProcessor
func load_chart_from_omr(score_image_path: String, bpm: float = 120.0, time_sig: Array = [4, 4]) -> Dictionary:
	var omr_script = null
	if ResourceLoader.exists("res://scripts/omr_processor.gd"):
		omr_script = load("res://scripts/omr_processor.gd")
	elif ResourceLoader.exists("res://.agents/teamwork/m3_explorer_2/proposed_omr_processor.gd"):
		omr_script = load("res://.agents/teamwork/m3_explorer_2/proposed_omr_processor.gd")

	if omr_script:
		if omr_script.has_method("process_image"):
			return omr_script.process_image(score_image_path, {"bpm": bpm, "time_signature": time_sig})
		var processor = omr_script.new()
		if processor.has_method("process_image"):
			return processor.process_image(score_image_path, {"bpm": bpm, "time_signature": time_sig})

	push_error("LevelLoader: OMRProcessor script not found or missing process_image method.")
	return {}

## Loads audio stream from WAV, MP3, or OGG file
func load_audio_stream(audio_path: String) -> AudioStream:
	if audio_path.is_empty():
		return null

	# 1. If imported in editor / packaged in PCK or APK, ResourceLoader.load() resolves remappings
	if ResourceLoader.has_cached(audio_path) or ResourceLoader.exists(audio_path):
		var res: Resource = load(audio_path)
		if res is AudioStream:
			if res is AudioStreamWAV:
				res.loop_mode = AudioStreamWAV.LOOP_FORWARD
			return res

	# 2. Check localized and globalized filesystem paths for loose unimported files
	var abs_path: String = ProjectSettings.globalize_path(audio_path)
	var resolved_path: String = audio_path
	if not FileAccess.file_exists(resolved_path):
		if FileAccess.file_exists(abs_path):
			resolved_path = abs_path
		else:
			push_error("LevelLoader: Audio file not found: " + audio_path)
			return null

	# 3. Read loose file bytes
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(resolved_path)
	if bytes.is_empty():
		push_error("LevelLoader: Audio file empty or could not be read: " + resolved_path)
		return null

	var ext: String = resolved_path.get_extension().to_lower()
	if ext == "wav":
		var wav: AudioStreamWAV = _load_wav_from_bytes(bytes)
		if wav:
			wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		return wav
	elif ext == "ogg":
		var ogg: AudioStreamOggVorbis = AudioStreamOggVorbis.load_from_buffer(bytes)
		if ogg:
			ogg.loop = true
		return ogg
	elif ext == "mp3":
		var mp3: AudioStreamMP3 = AudioStreamMP3.new()
		mp3.data = bytes
		mp3.loop = true
		return mp3
	else:
		push_error("LevelLoader: Unsupported audio format extension: " + ext)
		return null

## Robust pure GDScript RIFF WAV parser for unimported / runtime audio streams
func _load_wav_from_bytes(data: PackedByteArray) -> AudioStreamWAV:
	if data.size() < 44:
		push_error("LevelLoader: WAV byte buffer too small for RIFF header.")
		return null

	# Check RIFF and WAVE magic numbers
	var riff: String = data.slice(0, 4).get_string_from_ascii()
	var wave: String = data.slice(8, 12).get_string_from_ascii()
	if riff != "RIFF" or wave != "WAVE":
		push_error("LevelLoader: Invalid RIFF WAVE header.")
		return null

	var channels: int = 1
	var sample_rate: int = 44100
	var bits_per_sample: int = 16
	var audio_format: int = 1 # 1 = PCM
	var audio_data_start: int = 44
	var audio_data_len: int = data.size() - 44

	# Traverse chunks
	var offset: int = 12
	while offset + 8 <= data.size():
		var chunk_id: String = data.slice(offset, offset + 4).get_string_from_ascii()
		var chunk_size: int = data.decode_u32(offset + 4)
		offset += 8
		if chunk_size < 0:
			break

		var padded_chunk_size: int = (chunk_size + 1) & ~1
		if chunk_id == "fmt ":
			if offset + 16 <= data.size():
				audio_format = data.decode_u16(offset)
				channels = maxi(1, data.decode_u16(offset + 2))
				sample_rate = maxi(8000, data.decode_u32(offset + 4))
				bits_per_sample = data.decode_u16(offset + 14)
			offset += padded_chunk_size
		elif chunk_id == "data":
			audio_data_start = offset
			audio_data_len = chunk_size
			offset += padded_chunk_size
			break
		else:
			offset += padded_chunk_size

	var wav := AudioStreamWAV.new()
	wav.mix_rate = sample_rate
	wav.stereo = (channels >= 2)

	if bits_per_sample == 8:
		wav.format = AudioStreamWAV.FORMAT_8_BITS
	elif bits_per_sample == 16:
		wav.format = AudioStreamWAV.FORMAT_16_BITS
	else:
		wav.format = AudioStreamWAV.FORMAT_16_BITS

	var safe_start: int = clampi(audio_data_start, 0, data.size())
	var safe_end: int = clampi(safe_start + maxi(0, audio_data_len), safe_start, data.size())
	var pcm_data: PackedByteArray = data.slice(safe_start, safe_end)
	wav.data = pcm_data
	return wav

## Aligns note timestamps with tempo, validates duration against audio accompaniment
func align_level(chart: Dictionary, audio_stream: AudioStream = null, options: Dictionary = {}) -> Dictionary:
	var bpm: float = float(chart.get("bpm", 120.0))
	var safe_bpm: float = bpm if (bpm > 0.0 and not is_nan(bpm) and not is_inf(bpm)) else 120.0
	var raw_ts: Variant = chart.get("time_signature", [4, 4])
	var time_sig: Array = [4, 4]
	if raw_ts is Array and raw_ts.size() >= 2 and int(raw_ts[0]) > 0:
		time_sig = raw_ts
	var raw_notes: Array = chart.get("notes", []) if (chart.get("notes", []) is Array) else []
	var sec_per_beat: float = 60.0 / safe_bpm
	var beats_per_measure: int = maxi(1, int(time_sig[0]))

	var cal_ms: float = float(options.get("calibration_offset_ms", calibration_offset_ms))
	var cal_sec: float = cal_ms / 1000.0

	var processed_notes: Array[Dictionary] = []
	var max_note_end_sec: float = 0.0

	for i in range(raw_notes.size()):
		var n: Variant = raw_notes[i]
		var note_dict: Dictionary = {}
		if n is Dictionary:
			note_dict = n.duplicate()
		elif typeof(n) == TYPE_OBJECT and n.has_method("to_dict"):
			note_dict = n.to_dict()

		var pitch_midi: int = int(note_dict.get("pitch_midi", note_dict.get("midi", 60)))
		note_dict["pitch_midi"] = pitch_midi

		# Ensure pitch name
		if not note_dict.has("pitch_name"):
			var safe_midi: int = clampi(pitch_midi, 0, 127)
			var pc: int = safe_midi % 12
			var oct: int = int(floor(float(safe_midi) / 12.0)) - 1
			note_dict["pitch_name"] = PITCH_NAMES[pc] + str(oct)

		# Ensure staff
		if not note_dict.has("staff") or str(note_dict["staff"]) == "":
			note_dict["staff"] = "treble" if pitch_midi >= 60 else "bass"

		# Timestamp alignment
		var onset_sec: float = float(note_dict.get("time_sec", note_dict.get("onset_sec", -1.0)))
		var dur_sec: float = float(note_dict.get("duration_sec", note_dict.get("duration", -1.0)))

		if onset_sec < 0.0 or auto_align_timestamps:
			if note_dict.has("onset_beat"):
				onset_sec = float(note_dict["onset_beat"]) * sec_per_beat
			elif note_dict.has("beat") and note_dict.has("measure"):
				var m: int = int(note_dict["measure"])
				var b: float = float(note_dict["beat"])
				onset_sec = (float(m - 1) * float(beats_per_measure) + b) * sec_per_beat
			elif onset_sec < 0.0:
				onset_sec = 0.0

		if dur_sec <= 0.0:
			if note_dict.has("duration_beats"):
				dur_sec = float(note_dict["duration_beats"]) * sec_per_beat
			else:
				dur_sec = 0.5 * sec_per_beat

		note_dict["time_sec"] = onset_sec
		note_dict["duration_sec"] = dur_sec
		if not note_dict.has("id"):
			note_dict["id"] = i + 1

		var end_sec: float = onset_sec + dur_sec
		if end_sec > max_note_end_sec:
			max_note_end_sec = end_sec

		processed_notes.append(note_dict)

	var audio_dur: float = 0.0
	var is_aligned: bool = true
	var discrepancy_sec: float = 0.0

	if audio_stream != null:
		audio_dur = audio_stream.get_length()
		discrepancy_sec = absf(audio_dur - max_note_end_sec)
		# Duration validation: audio accompaniment should cover chart notes
		if audio_dur > 0.0 and (max_note_end_sec > audio_dur + duration_tolerance_sec):
			push_warning("LevelLoader: Chart notes extend beyond audio length (chart: %.2fs, audio: %.2fs)" % [max_note_end_sec, audio_dur])
			is_aligned = false

	var result: Dictionary = {
		"title": chart.get("title", "Untitled Level"),
		"bpm": safe_bpm,
		"time_signature": time_sig,
		"notes": processed_notes,
		"chart_duration": max_note_end_sec,
		"audio_stream": audio_stream,
		"audio_duration": audio_dur,
		"calibration_offset_ms": cal_ms,
		"calibration_offset_sec": cal_sec,
		"is_aligned": is_aligned,
		"discrepancy_sec": discrepancy_sec
	}

	alignment_completed.emit(result)
	return result

## Applies loaded level data to Highway, AudioPlayer, AudioManager, and ScoringService
func apply_to_game(level_data: Dictionary, highway: Node = null, audio_player: AudioStreamPlayer = null) -> bool:
	if level_data.is_empty() or not level_data.has("notes"):
		push_error("LevelLoader: Cannot apply invalid or empty level data.")
		return false

	var notes: Array = level_data["notes"]
	var cal_sec: float = float(level_data.get("calibration_offset_sec", 0.0))
	var stream: AudioStream = level_data.get("audio_stream")

	# 1. Configure Highway
	if highway != null:
		if highway.has_method("load_notes"):
			highway.load_notes(notes)
		elif highway.has_method("set_notes"):
			highway.set_notes(notes)
		if "audio_offset_sec" in highway:
			highway.audio_offset_sec = cal_sec

	# 2. Configure AudioStreamPlayer
	if audio_player != null and stream != null:
		audio_player.stream = stream
		if highway != null and "audio_player" in highway:
			highway.audio_player = audio_player

	# 3. Configure Autoload Singletons if present in SceneTree
	if Engine.has_singleton("AudioManager") or (is_inside_tree() and has_node("/root/AudioManager")):
		var am = Engine.get_singleton("AudioManager") if Engine.has_singleton("AudioManager") else get_node_or_null("/root/AudioManager")
		if am and am.has_method("set_audio_offset"):
			am.set_audio_offset(cal_sec)
		elif am and "audio_offset_sec" in am:
			am.audio_offset_sec = cal_sec

	if Engine.has_singleton("ScoringService") or (is_inside_tree() and has_node("/root/ScoringService")):
		var ss = Engine.get_singleton("ScoringService") if Engine.has_singleton("ScoringService") else get_node_or_null("/root/ScoringService")
		if ss and ss.has_method("set_active_chart"):
			ss.set_active_chart(notes)

	return true

## Loads a bundled piece by key ("piece_1_monophonic", "piece_2_harmony", "piece_3_polyphonic" or alias)
func load_bundled_piece(piece_key: String, use_omr: bool = false) -> Dictionary:
	var resolved_key: String = piece_key
	if not BUNDLED_PIECES.has(resolved_key):
		for k in BUNDLED_PIECES:
			if BUNDLED_PIECES[k].get("alias_id") == resolved_key:
				resolved_key = k
				break

	if not BUNDLED_PIECES.has(resolved_key):
		push_error("LevelLoader: Bundled piece not found: " + piece_key)
		return {}

	return load_level(resolved_key, null, {"use_omr": use_omr})

## Returns list of available bundled piece definitions
func get_bundled_pieces() -> Array[Dictionary]:
	var list: Array[Dictionary] = []
	for k in BUNDLED_PIECES:
		list.append(BUNDLED_PIECES[k])
	return list
