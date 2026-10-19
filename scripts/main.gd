class_name Main
extends Node2D

## Main Game Coordinator for V2:
## Orchestrates GrandStaffHighway, ResponsiveHUD, PermissionScreen, OscilloscopeView,
## LevelLoader, and wires signals across Autoload Singletons:
## (GameManager, AudioManager, AudioCaptureService, InferenceService, ScoringService).

signal chord_hit_detected(pitch: int, time: float, hit_data: Dictionary)
signal level_switched(piece_id: String)
signal game_flow_started()
signal calibration_changed(new_offset_ms: float)

# Exported Settings
@export var enable_mic_capture: bool = true
@export var auto_loop_playback: bool = true
@export var input_calibration_offset_sec: float = 0.050 # 50ms microphone & DSP buffer latency compensation
@export var semitone_tolerance: int = 0 # 0 = strict pitch match, 1 = +/- 1 semitone tolerance
@export var selected_piece: String = "piece_1_monophonic"
@export var load_via_omr: bool = false
@export var auto_pass_desktop: bool = false # PermissionScreen desktop bypass setting

# UI & Scene Nodes
var highway: GrandStaffHighway = null
var hud: CanvasLayer = null
var permission_screen: CanvasLayer = null
var oscilloscope_view: Control = null
var level_loader: LevelLoader = null
var audio_player: AudioStreamPlayer = null

# Internal State
var _last_detected_pitches: Array[int] = []
var _pitch_refractory_until: Dictionary = {}
var _loop_restart_timer: float = -1.0
var _test_tone_timer: float = 0.0
var _test_tone_pitches: Array = [60, 64, 67]
var _is_permission_resolved: bool = false

func _ready() -> void:
	# 0. Fit and center desktop window within usable screen work area
	_configure_desktop_window()

	# 1. Guarantee Master bus is unmuted at 0 dB
	var master_idx: int = AudioServer.get_bus_index("Master")
	if master_idx != -1:
		AudioServer.set_bus_mute(master_idx, false)
		AudioServer.set_bus_volume_db(master_idx, 0.0)

	# 2. Locate and wire Scene Nodes
	_find_or_create_scene_nodes()

	# 3. Connect Singleton and Node Signals
	_connect_singleton_signals()
	_connect_node_signals()

	# 4. Load initial piece data into highway and audio manager
	load_piece(selected_piece, load_via_omr)

	# 5. Evaluate Permission Gate
	_evaluate_permission_gate()

## Ensures the OS window fits comfortably inside the usable screen rect and is centered on screen
func _configure_desktop_window() -> void:
	var is_headless: bool = (DisplayServer.get_name() == "headless")
	var is_desktop: bool = OS.get_name() in ["Windows", "Linux", "macOS"]
	if is_headless or not is_desktop:
		return

	var screen_idx: int = DisplayServer.window_get_current_screen()
	var usable: Rect2i = DisplayServer.screen_get_usable_rect(screen_idx)
	if usable.size.x <= 0 or usable.size.y <= 0:
		return

	var dpi: int = DisplayServer.screen_get_dpi(screen_idx)
	var cap_w: int = 1152 if dpi >= 110 else 1280
	var cap_h: int = 648 if dpi >= 110 else 720

	# Keep window <= 76% of usable work area with 16:9 aspect ratio so it never overflows the screen
	var max_w: int = mini(cap_w, int(floor(float(usable.size.x) * 0.76)))
	var max_h: int = mini(cap_h, int(floor(float(usable.size.y) * 0.76)))
	var target_w: int = maxi(800, mini(max_w, int(round(float(max_h) * (16.0 / 9.0)))))
	var target_h: int = maxi(450, int(round(float(target_w) * (9.0 / 16.0))))

	DisplayServer.window_set_size(Vector2i(target_w, target_h))
	var deco_size: Vector2i = DisplayServer.window_get_size_with_decorations()
	if deco_size.x <= 0 or deco_size.y <= 0:
		deco_size = Vector2i(target_w + 18, target_h + 47)

	var target_x: int = usable.position.x + maxi(20, (usable.size.x - deco_size.x) / 2)
	var target_y: int = usable.position.y + maxi(32, (usable.size.y - deco_size.y) / 2)
	DisplayServer.window_set_position(Vector2i(target_x, target_y))

## Resolves child nodes from tree or creates graceful runtime instances
func _find_or_create_scene_nodes() -> void:
	# Highway
	if has_node("GrandStaffHighway"):
		highway = get_node("GrandStaffHighway") as GrandStaffHighway
	elif has_node("Highway"):
		highway = get_node("Highway") as GrandStaffHighway
	else:
		var HighwayScene = load("res://scenes/highway.tscn")
		if HighwayScene:
			highway = HighwayScene.instantiate()
			highway.name = "GrandStaffHighway"
			add_child(highway)

	# AudioPlayer (if present in Main or Highway)
	if has_node("AudioPlayer"):
		audio_player = get_node("AudioPlayer") as AudioStreamPlayer
	elif highway != null and highway.has_node("AudioPlayer"):
		audio_player = highway.get_node("AudioPlayer") as AudioStreamPlayer

	# LevelLoader
	if has_node("LevelLoader"):
		level_loader = get_node("LevelLoader") as LevelLoader
	else:
		var LoaderScript = load("res://scripts/level_loader.gd")
		if LoaderScript:
			level_loader = LoaderScript.new()
			level_loader.name = "LevelLoader"
			add_child(level_loader)

	# Responsive HUD
	if has_node("ResponsiveHUD"):
		hud = get_node("ResponsiveHUD") as CanvasLayer
	elif has_node("HUD"):
		hud = get_node("HUD") as CanvasLayer
	else:
		var HudScene = load("res://scenes/hud.tscn")
		if HudScene:
			hud = HudScene.instantiate()
			hud.name = "ResponsiveHUD"
			add_child(hud)

	# Oscilloscope View
	if has_node("OscilloscopeView"):
		oscilloscope_view = get_node("OscilloscopeView") as Control
	elif hud != null:
		if hud.find_child("OscilloscopeView", true, false):
			oscilloscope_view = hud.find_child("OscilloscopeView", true, false) as Control
		elif "oscilloscope_view" in hud and hud.oscilloscope_view != null:
			oscilloscope_view = hud.oscilloscope_view as Control
		elif hud.has_method("_setup_oscilloscope"):
			hud._setup_oscilloscope()
			oscilloscope_view = hud.find_child("OscilloscopeView", true, false) as Control

	# Permission Screen
	if has_node("PermissionScreen"):
		permission_screen = get_node("PermissionScreen") as CanvasLayer
	else:
		var PermScene = load("res://scenes/permission_screen.tscn")
		if PermScene:
			permission_screen = PermScene.instantiate()
			permission_screen.name = "PermissionScreen"
			add_child(permission_screen)
		else:
			var PermScript = load("res://scripts/permission_screen.gd")
			if PermScript:
				permission_screen = PermScript.new()
				permission_screen.name = "PermissionScreen"
				add_child(permission_screen)

	if permission_screen != null:
		if "auto_pass_desktop" in permission_screen:
			permission_screen.auto_pass_desktop = auto_pass_desktop

## Connects Autoload Singleton signals
func _connect_singleton_signals() -> void:
	# AudioCaptureService
	if has_node("/root/AudioCaptureService"):
		var cap = get_node("/root/AudioCaptureService")
		if cap.has_signal("raw_waveform_updated") and not cap.raw_waveform_updated.is_connected(_on_audio_raw_waveform_updated):
			cap.raw_waveform_updated.connect(_on_audio_raw_waveform_updated)
		if cap.has_signal("input_device_changed") and not cap.input_device_changed.is_connected(_on_audio_input_device_changed):
			cap.input_device_changed.connect(_on_audio_input_device_changed)

	# InferenceService
	if has_node("/root/InferenceService"):
		var inf = get_node("/root/InferenceService")
		if inf.has_signal("pitch_detected") and not inf.pitch_detected.is_connected(_on_inference_pitch_detected):
			inf.pitch_detected.connect(_on_inference_pitch_detected)
		if inf.has_signal("onset_detected") and not inf.onset_detected.is_connected(_on_inference_onset_detected):
			inf.onset_detected.connect(_on_inference_onset_detected)

	# ScoringService
	if has_node("/root/ScoringService"):
		var ss = get_node("/root/ScoringService")
		if ss.has_signal("note_scored") and not ss.note_scored.is_connected(_on_scoring_note_scored):
			ss.note_scored.connect(_on_scoring_note_scored)
		if ss.has_signal("score_updated") and not ss.score_updated.is_connected(_on_scoring_score_updated):
			ss.score_updated.connect(_on_scoring_score_updated)
		if ss.has_signal("combo_broken") and not ss.combo_broken.is_connected(_on_scoring_combo_broken):
			ss.combo_broken.connect(_on_scoring_combo_broken)

	# GameManager
	if has_node("/root/GameManager"):
		var gm = get_node("/root/GameManager")
		if gm.has_signal("state_changed") and not gm.state_changed.is_connected(_on_gm_state_changed):
			gm.state_changed.connect(_on_gm_state_changed)
		if gm.has_signal("game_restarted") and not gm.game_restarted.is_connected(_on_gm_game_restarted):
			gm.game_restarted.connect(_on_gm_game_restarted)

## Connects signals from local child nodes
func _connect_node_signals() -> void:
	# Highway
	if highway != null:
		if highway.has_signal("note_missed") and not highway.note_missed.is_connected(_on_highway_note_missed):
			highway.note_missed.connect(_on_highway_note_missed)
		if highway.has_signal("playback_finished") and not highway.playback_finished.is_connected(_on_highway_playback_finished):
			highway.playback_finished.connect(_on_highway_playback_finished)

	# HUD
	if hud != null:
		if hud.has_signal("mic_device_selected") and not hud.mic_device_selected.is_connected(_on_hud_mic_device_selected):
			hud.mic_device_selected.connect(_on_hud_mic_device_selected)
		if hud.has_signal("refresh_mics_requested") and not hud.refresh_mics_requested.is_connected(_on_hud_refresh_mics_requested):
			hud.refresh_mics_requested.connect(_on_hud_refresh_mics_requested)
		if hud.has_signal("test_signal_requested") and not hud.test_signal_requested.is_connected(_on_hud_test_signal_requested):
			hud.test_signal_requested.connect(_on_hud_test_signal_requested)
		if hud.has_signal("piece_selected") and not hud.piece_selected.is_connected(_on_hud_piece_selected):
			hud.piece_selected.connect(_on_hud_piece_selected)
		if hud.has_signal("custom_song_requested") and not hud.custom_song_requested.is_connected(_on_hud_custom_song_requested):
			hud.custom_song_requested.connect(_on_hud_custom_song_requested)

		_refresh_hud_microphones()

	# Permission Screen
	if permission_screen != null:
		if permission_screen.has_signal("permission_granted") and not permission_screen.permission_granted.is_connected(_on_permission_granted):
			permission_screen.permission_granted.connect(_on_permission_granted)
		if permission_screen.has_signal("permission_denied") and not permission_screen.permission_denied.is_connected(_on_permission_denied):
			permission_screen.permission_denied.connect(_on_permission_denied)
		if permission_screen.has_signal("flow_completed") and not permission_screen.flow_completed.is_connected(_on_permission_flow_completed):
			permission_screen.flow_completed.connect(_on_permission_flow_completed)
		if permission_screen.has_signal("skip_requested") and not permission_screen.skip_requested.is_connected(_on_permission_skip_requested):
			permission_screen.skip_requested.connect(_on_permission_skip_requested)

## Evaluates whether to gate playback or start immediately (headless / desktop bypass)
func _evaluate_permission_gate() -> void:
	var is_headless: bool = (DisplayServer.get_name() == "headless")
	var is_desktop: bool = OS.get_name() in ["Windows", "Linux", "macOS"]

	if is_headless or (is_desktop and auto_pass_desktop):
		_on_permission_flow_completed()
	else:
		if permission_screen != null and permission_screen.has_method("show_screen"):
			permission_screen.show_screen()
		if has_node("/root/GameManager"):
			var gm = get_node("/root/GameManager")
			if gm.has_method("change_state"):
				gm.change_state(gm.GameState.PERMISSION_REQUIRED)

func _on_permission_granted() -> void:
	_is_permission_resolved = true
	if has_node("/root/AudioCaptureService") and enable_mic_capture:
		var cap = get_node("/root/AudioCaptureService")
		if cap.has_method("start_capture"):
			cap.start_capture()
	_refresh_hud_microphones()

func _on_permission_denied() -> void:
	_is_permission_resolved = false

func _on_permission_skip_requested() -> void:
	_is_permission_resolved = true

func _on_permission_flow_completed() -> void:
	_is_permission_resolved = true
	if permission_screen != null and permission_screen.has_method("hide_screen"):
		permission_screen.hide_screen()

	if has_node("/root/AudioCaptureService") and enable_mic_capture:
		var cap = get_node("/root/AudioCaptureService")
		if cap.has_method("start_capture"):
			cap.start_capture()

	if has_node("/root/GameManager"):
		var gm = get_node("/root/GameManager")
		if gm.has_method("start_game"):
			gm.start_game()

	start_playback()
	game_flow_started.emit()

## Starts or resumes highway and music playback
func start_playback() -> void:
	if highway != null:
		highway.start_playback()
	if has_node("/root/AudioManager"):
		var am = get_node("/root/AudioManager")
		var stream_to_play: AudioStream = null
		if audio_player and audio_player.stream:
			stream_to_play = audio_player.stream
		elif "_current_stream" in am and am._current_stream != null:
			stream_to_play = am._current_stream

		if stream_to_play != null and am.has_method("play_music"):
			am.play_music(stream_to_play, auto_loop_playback, 0.0)
		elif am.has_method("seek"):
			am.seek(0.0)
		elif "current_song_time" in am:
			am.current_song_time = 0.0
			if "_last_playback_pos" in am:
				am._last_playback_pos = 0.0

## Pauses highway and music playback
func pause_playback() -> void:
	if highway != null:
		highway.pause_playback()
	if has_node("/root/AudioManager"):
		var am = get_node("/root/AudioManager")
		if am.has_method("pause_music"):
			am.pause_music()

## Resumes highway and music playback
func resume_playback() -> void:
	if highway != null:
		if highway.has_method("resume_playback"):
			highway.resume_playback()
		else:
			highway.start_playback()
	if has_node("/root/AudioManager"):
		var am = get_node("/root/AudioManager")
		if am.has_method("resume_music"):
			am.resume_music()

## Restarts current level from the beginning
func restart_playback() -> void:
	_loop_restart_timer = -1.0
	if has_node("/root/ScoringService"):
		var ss = get_node("/root/ScoringService")
		if ss.has_method("reset_score"):
			ss.reset_score()
	if has_node("/root/GameManager"):
		var gm = get_node("/root/GameManager")
		if gm.has_method("reset_score"):
			gm.reset_score()

	if has_node("/root/AudioManager"):
		var am = get_node("/root/AudioManager")
		if am.has_method("seek"):
			am.seek(0.0)
		elif "current_song_time" in am:
			am.current_song_time = 0.0
			if "_last_playback_pos" in am:
				am._last_playback_pos = 0.0

	load_piece(selected_piece, load_via_omr)
	start_playback()

## Loads a bundled piece or custom chart path via LevelLoader
func load_piece(piece_id_or_path: String, use_omr: bool = false) -> bool:
	if level_loader == null:
		_find_or_create_scene_nodes()
	if level_loader == null:
		return false

	var level_data: Dictionary = level_loader.load_level(piece_id_or_path, null, {"use_omr": use_omr})
	if level_data.is_empty():
		return false

	level_loader.apply_to_game(level_data, highway, audio_player)
	selected_piece = piece_id_or_path
	load_via_omr = use_omr
	_loop_restart_timer = -1.0

	var cal_sec: float = float(level_data.get("calibration_offset_sec", 0.0))
	input_calibration_offset_sec = 0.050 + cal_sec

	# Update AudioManager and AudioPlayer with audio stream if present, and rewind playhead
	var stream: AudioStream = level_data.get("audio_stream")
	if audio_player != null:
		audio_player.stream = stream

	if has_node("/root/AudioManager"):
		var am = get_node("/root/AudioManager")
		if stream != null:
			if am.has_method("load_audio_stream"):
				am._current_stream = stream
				if am._music_player:
					am._music_player.stream = stream
		if am.has_method("seek"):
			am.seek(0.0)
		elif "current_song_time" in am:
			am.current_song_time = 0.0
			if "_last_playback_pos" in am:
				am._last_playback_pos = 0.0
		if stream == null and am.has_method("stop_music") and am.is_playing:
			am.stop_music()

	if has_node("/root/ScoringService"):
		var ss = get_node("/root/ScoringService")
		if ss.has_method("reset_score"):
			ss.reset_score()

	if has_node("/root/InferenceService"):
		var inf = get_node("/root/InferenceService")
		if inf.has_method("reset"):
			inf.reset()

	_last_detected_pitches.clear()
	_pitch_refractory_until.clear()

	if hud != null:
		if hud.has_method("update_score"):
			hud.update_score(0)
		if hud.has_method("update_combo"):
			hud.update_combo(0, 1)
		if hud.has_method("update_piece_title"):
			var title: String = level_data.get("title", piece_id_or_path)
			hud.update_piece_title(title, load_via_omr)

	level_switched.emit(selected_piece)
	return true

## Loads custom user-provided sheet music image or chart file
func load_custom_song(sheet_path: String, audio_path: String = "", bpm: float = 120.0) -> bool:
	if level_loader == null:
		_find_or_create_scene_nodes()
	if level_loader == null or sheet_path.is_empty():
		return false

	var ext: String = sheet_path.get_extension().to_lower()
	var is_image: bool = ext in ["png", "jpg", "jpeg"]
	var opts: Dictionary = {
		"use_omr": is_image,
		"bpm": bpm,
		"title": sheet_path.get_file().get_basename()
	}
	var audio_src: Variant = audio_path if not audio_path.is_empty() else null
	var level_data: Dictionary = level_loader.load_level(sheet_path, audio_src, opts)
	if level_data.is_empty():
		return false

	level_loader.apply_to_game(level_data, highway, audio_player)
	selected_piece = sheet_path
	load_via_omr = is_image
	_loop_restart_timer = -1.0

	var cal_sec: float = float(level_data.get("calibration_offset_sec", 0.0))
	input_calibration_offset_sec = 0.050 + cal_sec

	# Update AudioManager and AudioPlayer with audio stream if present, and rewind playhead
	var stream: AudioStream = level_data.get("audio_stream")
	if audio_player != null:
		audio_player.stream = stream

	if has_node("/root/AudioManager"):
		var am = get_node("/root/AudioManager")
		if stream != null:
			if am.has_method("load_audio_stream"):
				am._current_stream = stream
				if am._music_player:
					am._music_player.stream = stream
		if am.has_method("seek"):
			am.seek(0.0)
		elif "current_song_time" in am:
			am.current_song_time = 0.0
			if "_last_playback_pos" in am:
				am._last_playback_pos = 0.0
		if stream == null and am.has_method("stop_music") and am.is_playing:
			am.stop_music()

	if has_node("/root/ScoringService"):
		var ss = get_node("/root/ScoringService")
		if ss.has_method("reset_score"):
			ss.reset_score()

	if has_node("/root/InferenceService"):
		var inf = get_node("/root/InferenceService")
		if inf.has_method("reset"):
			inf.reset()

	_last_detected_pitches.clear()
	_pitch_refractory_until.clear()

	if hud != null:
		if hud.has_method("update_score"):
			hud.update_score(0)
		if hud.has_method("update_combo"):
			hud.update_combo(0, 1)
		if hud.has_method("update_piece_title"):
			hud.update_piece_title(sheet_path.get_file().get_basename(), is_image)

	level_switched.emit(selected_piece)
	start_playback()
	return true

func _process(delta: float) -> void:
	# 1. Test Tone Injection handling
	if _test_tone_timer > 0.0 and has_node("/root/AudioCaptureService"):
		_test_tone_timer = maxf(0.0, _test_tone_timer - delta)
		var cap = get_node("/root/AudioCaptureService")
		if cap.has_method("inject_test_chord"):
			cap.inject_test_chord(_test_tone_pitches, 512, 0.28)

	# 2. Update HUD Telemetry
	_update_hud_telemetry()

	# 3. Auto-loop restart timer when level finishes
	if _loop_restart_timer > 0.0:
		_loop_restart_timer -= delta
		if _loop_restart_timer <= 0.0:
			_loop_restart_timer = -1.0
			load_piece(selected_piece, load_via_omr)
			start_playback()

## Updates HUD diagnostic readouts and oscilloscope waveform
func _update_hud_telemetry() -> void:
	if hud == null:
		return

	if has_node("/root/AudioCaptureService"):
		var cap = get_node("/root/AudioCaptureService")
		if hud.has_method("update_audio_telemetry"):
			hud.update_audio_telemetry(
				cap.oscilloscope_ring_buffer,
				cap.current_rms,
				cap.current_rms_db,
				cap.is_currently_gated,
				cap.is_capturing,
				cap.total_frames_captured,
				cap.get_sample_rate()
			)

	if has_node("/root/InferenceService"):
		var inf = get_node("/root/InferenceService")
		if hud.has_method("update_inference_telemetry") and inf.has_method("get_status_summary"):
			hud.update_inference_telemetry(inf.get_status_summary())

## Forwards raw audio waveform updates to local OscilloscopeView
func _on_audio_raw_waveform_updated(raw_samples: PackedFloat32Array, rms: float, rms_db: float, is_gated: bool) -> void:
	if oscilloscope_view != null and oscilloscope_view.has_method("update_waveform"):
		var sr: int = 48000
		if has_node("/root/AudioCaptureService"):
			var cap = get_node("/root/AudioCaptureService")
			if cap.has_method("get_sample_rate"):
				sr = cap.get_sample_rate()
		oscilloscope_view.update_waveform(raw_samples, rms, rms_db, is_gated, sr)

func _on_audio_input_device_changed(_device_name: String) -> void:
	_refresh_hud_microphones()

func _refresh_hud_microphones() -> void:
	if hud != null and has_node("/root/AudioCaptureService"):
		var cap = get_node("/root/AudioCaptureService")
		if hud.has_method("refresh_microphone_dropdown") and cap.has_method("get_input_devices"):
			hud.refresh_microphone_dropdown(cap.get_input_devices(), cap.get_current_input_device())

## Receives sustained pitches from InferenceService
func _on_inference_pitch_detected(detected_pitches: Array[int], _confidence_map: Dictionary) -> void:
	if enable_mic_capture and _test_tone_timer <= 0.0 and has_node("/root/AudioCaptureService"):
		var cap = get_node("/root/AudioCaptureService")
		if cap.is_capturing and cap.is_currently_gated:
			_last_detected_pitches.clear()
			if highway != null:
				highway.set_live_pitches([])
			return

	# 1. Update live pitch indicators on Grand Staff receptor line
	if highway != null:
		highway.set_live_pitches(detected_pitches)

	# 2. Evaluate candidate strikes against highway active notes
	_evaluate_pitch_candidates(detected_pitches, [])

## Receives note onsets from InferenceService
func _on_inference_onset_detected(onsets: Array[int]) -> void:
	if enable_mic_capture and _test_tone_timer <= 0.0 and has_node("/root/AudioCaptureService"):
		var cap = get_node("/root/AudioCaptureService")
		if cap.is_capturing and cap.is_currently_gated:
			return

	# Preserve _last_detected_pitches so onset evaluation never wipes sustain state
	_evaluate_pitch_candidates(_last_detected_pitches.duplicate(), onsets)

## Evaluates polyphonic pitch strikes against active highway notes
func _evaluate_pitch_candidates(pitches: Array, onsets: Array) -> void:
	if highway == null or not highway.is_playing:
		return
	if not has_node("/root/ScoringService"):
		return

	var now: float = highway.current_song_time
	var eval_time: float = maxf(0.0, now - input_calibration_offset_sec)

	var candidate_pitches: Array[int] = []
	for p in onsets:
		var ip: int = int(p)
		var refractory_until: float = float(_pitch_refractory_until.get(ip, -1.0))
		if eval_time >= refractory_until and not candidate_pitches.has(ip):
			candidate_pitches.append(ip)
			if candidate_pitches.size() >= 4:
				break

	if candidate_pitches.size() < 4:
		for p in pitches:
			var ip: int = int(p)
			if not _last_detected_pitches.has(ip) and not candidate_pitches.has(ip):
				var refractory_until: float = float(_pitch_refractory_until.get(ip, -1.0))
				if eval_time >= refractory_until:
					candidate_pitches.append(ip)
					if candidate_pitches.size() >= 4:
						break

	_last_detected_pitches.clear()
	for p in pitches:
		_last_detected_pitches.append(int(p))

	if candidate_pitches.is_empty():
		return

	var ss = get_node("/root/ScoringService")
	var target_notes: Array = highway.active_notes if not highway.active_notes.is_empty() else highway.chart_notes
	for pitch in candidate_pitches:
		# Apply 220ms per-pitch trigger cooldown immediately so rapid noise/jitter cannot spam strikes
		_pitch_refractory_until[pitch] = eval_time + 0.220
		var hit_result: Dictionary = ss.process_input(
			eval_time,
			pitch,
			target_notes,
			semitone_tolerance
		)
		if not hit_result.is_empty():
			chord_hit_detected.emit(pitch, eval_time, hit_result)

## Feedback response when ScoringService scores a note
func _on_scoring_note_scored(note: Variant, rating: String, _points: int) -> void:
	var y_pos: float = 360.0
	if note is NoteData:
		y_pos = note.y_pos
	elif note is Dictionary:
		y_pos = float(note.get("y_pos", 360.0))

	if highway != null:
		highway.trigger_hit_pulse(y_pos, rating)

	if hud != null and hud.has_method("spawn_judgment_popup"):
		hud.spawn_judgment_popup(rating, Vector2(GrandStaffHighway.HIT_X, y_pos))

func _on_scoring_score_updated(score: int, combo: int, multiplier: float) -> void:
	if hud != null:
		if hud.has_method("update_score"):
			hud.update_score(score)
		if hud.has_method("update_combo"):
			hud.update_combo(combo, int(multiplier))

func _on_scoring_combo_broken() -> void:
	if hud != null and hud.has_method("update_combo"):
		hud.update_combo(0, 1)

func _on_highway_note_missed(note: NoteData) -> void:
	if has_node("/root/ScoringService"):
		var ss = get_node("/root/ScoringService")
		if ss.has_method("register_miss"):
			ss.register_miss(note)

func _on_highway_playback_finished() -> void:
	if highway != null:
		highway.is_playing = false

	if has_node("/root/GameManager"):
		var gm = get_node("/root/GameManager")
		if gm.has_method("finish_game"):
			gm.finish_game()

	if auto_loop_playback and _loop_restart_timer < 0.0:
		_loop_restart_timer = 2.0

# HUD Event Handlers
func _on_hud_mic_device_selected(device_name: String) -> void:
	if has_node("/root/AudioCaptureService"):
		var cap = get_node("/root/AudioCaptureService")
		if cap.has_method("set_input_device"):
			cap.set_input_device(device_name)
		elif cap.has_method("change_input_device"):
			cap.change_input_device(device_name)

func _on_hud_refresh_mics_requested() -> void:
	_refresh_hud_microphones()

func _on_hud_test_signal_requested() -> void:
	_test_tone_pitches = [60, 64, 67]
	if highway != null and highway.is_playing:
		var active = highway.get_active_notes_at(highway.current_song_time, 0.35) if highway.has_method("get_active_notes_at") else []
		if not active.is_empty():
			var chord: Array = []
			for n in active:
				if not n.is_hit and not n.is_missed and not chord.has(n.pitch_midi):
					chord.append(n.pitch_midi)
			if not chord.is_empty():
				_test_tone_pitches = chord
	_test_tone_timer = 0.45

func _on_hud_piece_selected(piece_id: String, use_omr: bool) -> void:
	if piece_id == "__restart__":
		restart_playback()
		return
	load_piece(piece_id, use_omr)
	start_playback()

func _on_hud_custom_song_requested(sheet_path: String, audio_path: String, bpm: float) -> void:
	load_custom_song(sheet_path, audio_path, bpm)

# GameManager Event Handlers
func _on_gm_state_changed(_old_state, new_state) -> void:
	if has_node("/root/GameManager"):
		var gm = get_node("/root/GameManager")
		match new_state:
			gm.GameState.PLAYING:
				start_playback()
			gm.GameState.PAUSED:
				pause_playback()
			gm.GameState.RESULTS:
				pause_playback()

func _on_gm_game_restarted() -> void:
	restart_playback()

func _unhandled_input(event: InputEvent) -> void:
	# Mobile/Web Audio context unlock on first touch
	if event is InputEventScreenTouch and event.pressed:
		if highway and highway.is_playing and audio_player and audio_player.stream and not audio_player.playing:
			audio_player.play(highway.current_song_time)

	# Keyboard playtesting controls
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ESCAPE:
				get_tree().quit()
			KEY_1:
				load_piece("piece_1_monophonic", false)
				start_playback()
			KEY_2:
				load_piece("piece_2_harmony", false)
				start_playback()
			KEY_3:
				load_piece("piece_3_polyphonic", false)
				start_playback()
			KEY_O:
				load_piece(selected_piece, true)
				start_playback()
			KEY_R:
				restart_playback()
			KEY_T:
				_on_hud_test_signal_requested()
			KEY_SPACE:
				_simulate_keyboard_strum()
			KEY_LEFT:
				_adjust_calibration(-5.0)
			KEY_RIGHT:
				_adjust_calibration(+5.0)

func _adjust_calibration(delta_ms: float) -> void:
	if level_loader != null:
		level_loader.set_calibration_offset_ms(level_loader.calibration_offset_ms + delta_ms)
		var cal_sec: float = level_loader.get_calibration_offset_sec()
		if highway != null:
			highway.audio_offset_sec = cal_sec
		if has_node("/root/AudioManager"):
			var am = get_node("/root/AudioManager")
			if am.has_method("set_audio_offset"):
				am.set_audio_offset(cal_sec)
			elif "audio_offset_sec" in am:
				am.audio_offset_sec = cal_sec
		calibration_changed.emit(level_loader.calibration_offset_ms)
		print("Calibration Offset: %.1f ms" % level_loader.calibration_offset_ms)

func _simulate_keyboard_strum() -> void:
	if highway == null or not highway.is_playing or not has_node("/root/ScoringService"):
		return

	var now: float = highway.current_song_time
	var active = highway.get_active_notes_at(now, 0.100) if highway.has_method("get_active_notes_at") else []
	if active.is_empty():
		return

	var best_note: NoteData = null
	var min_diff: float = 999.0
	for n in active:
		if not n.is_hit and not n.is_missed:
			var diff: float = absf(now - n.time_sec)
			if diff < min_diff:
				min_diff = diff
				best_note = n

	if best_note != null:
		var ss = get_node("/root/ScoringService")
		ss.process_input(now, best_note.pitch_midi, highway.active_notes)
