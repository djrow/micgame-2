class_name ResponsiveHUD
extends CanvasLayer

## ResponsiveHUD: Mobile-safe Heads-Up Display for V2 Polyphonic Microphone Rhythm Game.
## Follows Blueprint §5.1, §5.2, §7.1 Directive 3:
## - Full-viewport root Control using PRESET_FULL_RECT container hierarchies
##   (MarginContainer, HBoxContainer, VBoxContainer)
## - Dynamic safe-area adaptation via DisplayServer.get_display_safe_area() with desktop fallback
## - Telemetry bindings to ScoringService, AudioManager, AudioCaptureService, and InferenceService
## - Responsive Song Timeline, Combo & Multiplier Badges, and Rating Popups (Toasts)
## - Real-Time Oscilloscope & Diagnostic Dock at Y = 480..610 (>100px bottom clearance)
## - Strictly zero calls to play() inside _process()

signal mic_device_selected(device_name: String)
signal refresh_mics_requested()
signal test_signal_requested()
signal piece_selected(piece_id: String, use_omr: bool)
signal custom_song_requested(sheet_path: String, audio_path: String, bpm: float)
signal play_pause_toggled()
signal restart_requested()
signal seek_requested(time_sec: float)

# Palette
const COLOR_PERFECT: Color = Color(1.0, 0.84, 0.0)      # Gold (#FFD700)
const COLOR_GOOD: Color = Color(0.0, 0.90, 1.0)         # Neon Cyan (#00E5FF)
const COLOR_MISS: Color = Color(1.0, 0.20, 0.40)        # Crimson (#FF3366)

const COLOR_MULT_1X: Color = Color(0.80, 0.80, 0.80)   # Silver
const COLOR_MULT_2X: Color = Color(0.00, 0.90, 1.00)   # Cyan
const COLOR_MULT_3X: Color = Color(1.00, 0.60, 0.00)   # Orange
const COLOR_MULT_4X: Color = Color(1.00, 0.84, 0.00)   # Gold

# Core UI Node References
@onready var safe_margin_container: MarginContainer = $SafeMarginContainer if has_node("SafeMarginContainer") else null
@onready var main_layout: VBoxContainer = $SafeMarginContainer/MainLayout if has_node("SafeMarginContainer/MainLayout") else null

# Top Bar
@onready var top_bar: PanelContainer = $SafeMarginContainer/MainLayout/TopBar if has_node("SafeMarginContainer/MainLayout/TopBar") else null
@onready var piece_title_label: Label = $SafeMarginContainer/MainLayout/TopBar/TopHBox/PieceInfoContainer/PieceTitleLabel if has_node("SafeMarginContainer/MainLayout/TopBar/TopHBox/PieceInfoContainer/PieceTitleLabel") else null
@onready var piece1_btn: Button = $SafeMarginContainer/MainLayout/TopBar/TopHBox/PieceButtons/Piece1Btn if has_node("SafeMarginContainer/MainLayout/TopBar/TopHBox/PieceButtons/Piece1Btn") else null
@onready var piece2_btn: Button = $SafeMarginContainer/MainLayout/TopBar/TopHBox/PieceButtons/Piece2Btn if has_node("SafeMarginContainer/MainLayout/TopBar/TopHBox/PieceButtons/Piece2Btn") else null
@onready var piece3_btn: Button = $SafeMarginContainer/MainLayout/TopBar/TopHBox/PieceButtons/Piece3Btn if has_node("SafeMarginContainer/MainLayout/TopBar/TopHBox/PieceButtons/Piece3Btn") else null
@onready var omr_btn: Button = $SafeMarginContainer/MainLayout/TopBar/TopHBox/PieceButtons/OMRScanBtn if has_node("SafeMarginContainer/MainLayout/TopBar/TopHBox/PieceButtons/OMRScanBtn") else null
@onready var custom_btn: Button = $SafeMarginContainer/MainLayout/TopBar/TopHBox/PieceButtons/CustomSongBtn if has_node("SafeMarginContainer/MainLayout/TopBar/TopHBox/PieceButtons/CustomSongBtn") else null
@onready var play_pause_btn: Button = $SafeMarginContainer/MainLayout/TopBar/TopHBox/PlaybackControls/PlayPauseBtn if has_node("SafeMarginContainer/MainLayout/TopBar/TopHBox/PlaybackControls/PlayPauseBtn") else null
@onready var restart_btn: Button = $SafeMarginContainer/MainLayout/TopBar/TopHBox/PlaybackControls/RestartBtn if has_node("SafeMarginContainer/MainLayout/TopBar/TopHBox/PlaybackControls/RestartBtn") else null

# Timeline
@onready var time_elapsed_label: Label = $SafeMarginContainer/MainLayout/TopBar/TopHBox/TimelineContainer/TimeElapsedLabel if has_node("SafeMarginContainer/MainLayout/TopBar/TopHBox/TimelineContainer/TimeElapsedLabel") else null
@onready var song_progress_bar: ProgressBar = $SafeMarginContainer/MainLayout/TopBar/TopHBox/TimelineContainer/SongProgressBar if has_node("SafeMarginContainer/MainLayout/TopBar/TopHBox/TimelineContainer/SongProgressBar") else null
@onready var time_total_label: Label = $SafeMarginContainer/MainLayout/TopBar/TopHBox/TimelineContainer/TimeTotalLabel if has_node("SafeMarginContainer/MainLayout/TopBar/TopHBox/TimelineContainer/TimeTotalLabel") else null

# Score & Accuracy
@onready var score_value: Label = $SafeMarginContainer/MainLayout/TopBar/TopHBox/ScorePanel/ScoreContainer/ScoreValue if has_node("SafeMarginContainer/MainLayout/TopBar/TopHBox/ScorePanel/ScoreContainer/ScoreValue") else null
@onready var accuracy_value: Label = $SafeMarginContainer/MainLayout/TopBar/TopHBox/ScorePanel/AccuracyContainer/AccuracyValue if has_node("SafeMarginContainer/MainLayout/TopBar/TopHBox/ScorePanel/AccuracyContainer/AccuracyValue") else null

# Combo & Multiplier
@onready var combo_container: VBoxContainer = $SafeMarginContainer/MainLayout/HighwaySpacer/ComboContainer if has_node("SafeMarginContainer/MainLayout/HighwaySpacer/ComboContainer") else null
@onready var combo_label: Label = $SafeMarginContainer/MainLayout/HighwaySpacer/ComboContainer/ComboLabel if has_node("SafeMarginContainer/MainLayout/HighwaySpacer/ComboContainer/ComboLabel") else null
@onready var multiplier_label: Label = $SafeMarginContainer/MainLayout/HighwaySpacer/ComboContainer/MultiplierLabel if has_node("SafeMarginContainer/MainLayout/HighwaySpacer/ComboContainer/MultiplierLabel") else null

# Judgment Layer
@onready var judgment_layer: Control = $JudgmentLayer if has_node("JudgmentLayer") else null

# Diagnostic Dock
@onready var diagnostic_dock: PanelContainer = $SafeMarginContainer/MainLayout/DiagnosticDock if has_node("SafeMarginContainer/MainLayout/DiagnosticDock") else null
@onready var mic_status_label: Label = $SafeMarginContainer/MainLayout/DiagnosticDock/DockHBox/MicColumn/MicHeaderHBox/MicStatusLabel if has_node("SafeMarginContainer/MainLayout/DiagnosticDock/DockHBox/MicColumn/MicHeaderHBox/MicStatusLabel") else null
@onready var mic_dropdown: OptionButton = $SafeMarginContainer/MainLayout/DiagnosticDock/DockHBox/MicColumn/MicDropdownHBox/MicDropdown if has_node("SafeMarginContainer/MainLayout/DiagnosticDock/DockHBox/MicColumn/MicDropdownHBox/MicDropdown") else null
@onready var refresh_mic_btn: Button = $SafeMarginContainer/MainLayout/DiagnosticDock/DockHBox/MicColumn/MicDropdownHBox/RefreshMicBtn if has_node("SafeMarginContainer/MainLayout/DiagnosticDock/DockHBox/MicColumn/MicDropdownHBox/RefreshMicBtn") else null
@onready var mic_level_label: Label = $SafeMarginContainer/MainLayout/DiagnosticDock/DockHBox/MicColumn/MicLevelLabel if has_node("SafeMarginContainer/MainLayout/DiagnosticDock/DockHBox/MicColumn/MicLevelLabel") else null
@onready var test_signal_btn: Button = $SafeMarginContainer/MainLayout/DiagnosticDock/DockHBox/MicColumn/TestSignalBtn if has_node("SafeMarginContainer/MainLayout/DiagnosticDock/DockHBox/MicColumn/TestSignalBtn") else null
@onready var oscilloscope_container: Control = $SafeMarginContainer/MainLayout/DiagnosticDock/DockHBox/OscilloscopeColumn if has_node("SafeMarginContainer/MainLayout/DiagnosticDock/DockHBox/OscilloscopeColumn") else null
@onready var inference_backend_label: Label = $SafeMarginContainer/MainLayout/DiagnosticDock/DockHBox/InferenceColumn/InferenceBackendLabel if has_node("SafeMarginContainer/MainLayout/DiagnosticDock/DockHBox/InferenceColumn/InferenceBackendLabel") else null
@onready var inference_metrics_label: Label = $SafeMarginContainer/MainLayout/DiagnosticDock/DockHBox/InferenceColumn/InferenceMetricsLabel if has_node("SafeMarginContainer/MainLayout/DiagnosticDock/DockHBox/InferenceColumn/InferenceMetricsLabel") else null
@onready var detected_notes_label: Label = $SafeMarginContainer/MainLayout/DiagnosticDock/DockHBox/InferenceColumn/NotesPanel/NotesVBox/DetectedNotesLabel if has_node("SafeMarginContainer/MainLayout/DiagnosticDock/DockHBox/InferenceColumn/NotesPanel/NotesVBox/DetectedNotesLabel") else null
@onready var last_onset_label: Label = $SafeMarginContainer/MainLayout/DiagnosticDock/DockHBox/InferenceColumn/NotesPanel/NotesVBox/LastOnsetLabel if has_node("SafeMarginContainer/MainLayout/DiagnosticDock/DockHBox/InferenceColumn/NotesPanel/NotesVBox/LastOnsetLabel") else null

# Custom Song Modal
@onready var custom_song_modal: PanelContainer = $CustomSongModal if has_node("CustomSongModal") else null
@onready var custom_sheet_input: LineEdit = $CustomSongModal/ModalVBox/SheetRow/CustomSheetInput if has_node("CustomSongModal/ModalVBox/SheetRow/CustomSheetInput") else null
@onready var custom_audio_input: LineEdit = $CustomSongModal/ModalVBox/AudioRow/CustomAudioInput if has_node("CustomSongModal/ModalVBox/AudioRow/CustomAudioInput") else null
@onready var custom_bpm_spin: SpinBox = $CustomSongModal/ModalVBox/BpmRow/CustomBpmSpin if has_node("CustomSongModal/ModalVBox/BpmRow/CustomBpmSpin") else null

# Internal state
var displayed_score: int = 0
var score_tween: Tween = null
var _onset_flash_timer: float = 0.0
var _last_onset_text: String = "Last Onset: —"
var _oscilloscope_instance: Control = null
var oscilloscope_view: Control = null
var _is_user_scrubbing: bool = false

# File dialogs
var sheet_file_dialog: FileDialog = null
var audio_file_dialog: FileDialog = null

func _enter_tree() -> void:
	_ensure_hierarchy()

func _ready() -> void:
	layer = 10
	_ensure_hierarchy()
	_wire_ui_buttons()
	_setup_oscilloscope()
	_apply_mobile_safe_area()

	if get_viewport() != null and not get_viewport().size_changed.is_connected(_apply_mobile_safe_area):
		get_viewport().size_changed.connect(_apply_mobile_safe_area)

	update_score(0)
	update_combo(0, 1)
	update_accuracy(100.0)
	refresh_microphone_dropdown()
	bind_services()

func _process(delta: float) -> void:
	_update_timeline_playhead()
	_process_onset_flash(delta)

## Dynamically adapts margins based on DisplayServer safe areas on mobile,
## with clean uniform margins on desktop and headless environments.
func _apply_mobile_safe_area() -> void:
	var left_inset: float = 16.0
	var top_inset: float = 12.0
	var right_inset: float = 16.0
	var bottom_inset: float = 16.0

	var ds_name: String = DisplayServer.get_name()
	var is_mobile: bool = OS.get_name() in ["Android", "iOS"]

	if is_mobile and ds_name != "headless":
		var safe_rect: Rect2i = DisplayServer.get_display_safe_area()
		var win_size: Vector2i = DisplayServer.window_get_size()
		if win_size.x > 0 and win_size.y > 0 and safe_rect.size.x > 0 and safe_rect.size.y > 0:
			var scale_x: float = 1280.0 / float(win_size.x)
			var scale_y: float = 720.0 / float(win_size.y)

			var raw_left: float = float(safe_rect.position.x) * scale_x
			var raw_top: float = float(safe_rect.position.y) * scale_y
			var raw_right: float = float(win_size.x - (safe_rect.position.x + safe_rect.size.x)) * scale_x
			var raw_bottom: float = float(win_size.y - (safe_rect.position.y + safe_rect.size.y)) * scale_y

			left_inset = maxf(16.0, raw_left + 8.0)
			top_inset = maxf(12.0, raw_top + 6.0)
			right_inset = maxf(16.0, raw_right + 8.0)
			# Minimum 24px bottom clearance for mobile gesture navigation bar (Blueprint §5.1)
			bottom_inset = maxf(24.0, raw_bottom + 12.0)

	if safe_margin_container != null:
		safe_margin_container.add_theme_constant_override("margin_left", int(round(left_inset)))
		safe_margin_container.add_theme_constant_override("margin_top", int(round(top_inset)))
		safe_margin_container.add_theme_constant_override("margin_right", int(round(right_inset)))
		safe_margin_container.add_theme_constant_override("margin_bottom", int(round(bottom_inset)))

## Connects to V2 Autoload singletons (ScoringService, AudioManager, AudioCaptureService, InferenceService, GameManager)
func bind_services() -> void:
	if not is_inside_tree():
		return

	# 1. ScoringService
	if has_node("/root/ScoringService"):
		var ss = get_node("/root/ScoringService")
		if ss.has_signal("score_updated"):
			var cb = Callable(self, "_on_service_score_updated")
			if not ss.is_connected("score_updated", cb):
				ss.connect("score_updated", cb)
		if ss.has_signal("note_scored"):
			var cb = Callable(self, "_on_service_note_scored")
			if not ss.is_connected("note_scored", cb):
				ss.connect("note_scored", cb)
		if ss.has_signal("combo_broken"):
			var cb = Callable(self, "_on_service_combo_broken")
			if not ss.is_connected("combo_broken", cb):
				ss.connect("combo_broken", cb)

	# 2. AudioManager
	if has_node("/root/AudioManager"):
		var am = get_node("/root/AudioManager")
		if am.has_signal("song_started"):
			var cb = Callable(self, "_on_audio_song_started")
			if not am.is_connected("song_started", cb):
				am.connect("song_started", cb)
		if am.has_signal("song_paused"):
			var cb = Callable(self, "_on_audio_song_paused")
			if not am.is_connected("song_paused", cb):
				am.connect("song_paused", cb)
		if am.has_signal("song_resumed"):
			var cb = Callable(self, "_on_audio_song_resumed")
			if not am.is_connected("song_resumed", cb):
				am.connect("song_resumed", cb)
		if am.has_signal("song_stopped"):
			var cb = Callable(self, "_on_audio_song_stopped")
			if not am.is_connected("song_stopped", cb):
				am.connect("song_stopped", cb)
		if am.has_signal("song_finished"):
			var cb = Callable(self, "_on_audio_song_finished")
			if not am.is_connected("song_finished", cb):
				am.connect("song_finished", cb)

	# 3. AudioCaptureService
	if has_node("/root/AudioCaptureService"):
		var ac = get_node("/root/AudioCaptureService")
		if ac.has_signal("raw_waveform_updated"):
			var cb = Callable(self, "_on_audio_capture_waveform")
			if not ac.is_connected("raw_waveform_updated", cb):
				ac.connect("raw_waveform_updated", cb)
		if ac.has_signal("capture_started"):
			var cb = Callable(self, "_on_audio_capture_started")
			if not ac.is_connected("capture_started", cb):
				ac.connect("capture_started", cb)
		if ac.has_signal("capture_stopped"):
			var cb = Callable(self, "_on_audio_capture_stopped")
			if not ac.is_connected("capture_stopped", cb):
				ac.connect("capture_stopped", cb)
		if ac.has_method("get_input_devices") and ac.has_method("get_current_input_device"):
			refresh_microphone_dropdown(ac.get_input_devices(), ac.get_current_input_device())

	# 4. InferenceService
	if has_node("/root/InferenceService"):
		var inf = get_node("/root/InferenceService")
		if inf.has_signal("pitch_detected"):
			var cb = Callable(self, "_on_inference_pitch_detected")
			if not inf.is_connected("pitch_detected", cb):
				inf.connect("pitch_detected", cb)
		if inf.has_signal("onset_detected"):
			var cb = Callable(self, "_on_inference_onset_detected")
			if not inf.is_connected("onset_detected", cb):
				inf.connect("onset_detected", cb)
		if inf.has_signal("backend_changed"):
			var cb = Callable(self, "_on_inference_backend_changed")
			if not inf.is_connected("backend_changed", cb):
				inf.connect("backend_changed", cb)
		# Initial status populate
		if inf.has_method("get_status_summary"):
			var status = inf.get_status_summary()
			update_inference_telemetry(status)

	# 5. GameManager
	if has_node("/root/GameManager"):
		var gm = get_node("/root/GameManager")
		if gm.has_signal("piece_loaded"):
			var cb = Callable(self, "_on_gm_piece_loaded")
			if not gm.is_connected("piece_loaded", cb):
				gm.connect("piece_loaded", cb)
		if "current_piece_metadata" in gm and not gm.current_piece_metadata.is_empty():
			var p_title: String = gm.current_piece_metadata.get("title", "Unknown Piece")
			update_piece_title(p_title)

# --- Score & Telemetry Updates ---

func update_score(new_score: int) -> void:
	if score_value == null:
		return
	if score_tween != null:
		score_tween.kill()

	score_tween = create_tween()
	score_tween.tween_method(func(val: int):
		displayed_score = val
		if score_value != null:
			score_value.text = "%06d" % val
	, displayed_score, new_score, 0.25).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

func update_combo(combo: int, multiplier: int) -> void:
	if combo_container == null:
		return

	if combo < 2:
		combo_container.modulate.a = 0.0
	else:
		combo_container.modulate.a = 1.0
		if combo_label != null:
			combo_label.text = "%d COMBO" % combo

		# Scale-bounce punch on combo streak increase
		var t: Tween = create_tween()
		combo_container.scale = Vector2(1.22, 1.22)
		t.tween_property(combo_container, "scale", Vector2.ONE, 0.15).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	if multiplier_label != null:
		multiplier_label.text = "%dx MULTIPLIER" % multiplier
		match multiplier:
			1: multiplier_label.modulate = COLOR_MULT_1X
			2: multiplier_label.modulate = COLOR_MULT_2X
			3: multiplier_label.modulate = COLOR_MULT_3X
			4: multiplier_label.modulate = COLOR_MULT_4X
			_: multiplier_label.modulate = COLOR_MULT_4X

func update_accuracy(accuracy_pct: float) -> void:
	if accuracy_value != null:
		accuracy_value.text = "%.1f%%" % clampf(accuracy_pct, 0.0, 100.0)

## Spawns a rating popup toast ("PERFECT!", "GOOD!", "MISS") with scale punch, upward float, and fade out.
func spawn_judgment_popup(judgment: String, pos: Vector2 = Vector2.ZERO) -> void:
	var target_parent: Control = judgment_layer if judgment_layer != null else self
	if target_parent == null:
		return

	var label := Label.new()
	label.text = judgment + "!"
	label.top_level = false

	# Position near receptor line X = 160 or caller position
	var spawn_pos: Vector2 = pos
	if spawn_pos == Vector2.ZERO:
		spawn_pos = Vector2(160.0, 320.0)
	label.position = spawn_pos - Vector2(60, 20)
	label.pivot_offset = Vector2(60, 20)

	match judgment:
		"PERFECT":
			label.modulate = COLOR_PERFECT
			label.add_theme_font_size_override("font_size", 32)
		"GOOD":
			label.modulate = COLOR_GOOD
			label.add_theme_font_size_override("font_size", 26)
		"MISS":
			label.text = "MISS"
			label.modulate = COLOR_MISS
			label.add_theme_font_size_override("font_size", 24)
		_:
			label.modulate = Color.WHITE
			label.add_theme_font_size_override("font_size", 24)

	target_parent.add_child(label)

	var tween: Tween = create_tween().set_parallel(true)
	# Float upward
	tween.tween_property(label, "position:y", label.position.y - 40.0, 0.45).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	# Scale punch
	label.scale = Vector2(1.3, 1.3)
	tween.tween_property(label, "scale", Vector2.ONE, 0.15).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	# Fade out
	var alpha_tween: Tween = create_tween()
	alpha_tween.tween_interval(0.20)
	alpha_tween.tween_property(label, "modulate:a", 0.0, 0.25)
	alpha_tween.tween_callback(label.queue_free)

func update_piece_title(title_text: String, is_omr: bool = false) -> void:
	if piece_title_label != null:
		var txt: String = title_text
		if is_omr and not txt.ends_with("[OMR Scanned]"):
			txt += " [OMR Scanned]"
		piece_title_label.text = "Piece: " + txt

# --- Audio & Timeline Telemetry ---

func _update_timeline_playhead() -> void:
	if not is_inside_tree() or not has_node("/root/AudioManager"):
		return
	var am = get_node("/root/AudioManager")
	var playhead: float = am.get_interpolated_playhead() if am.has_method("get_interpolated_playhead") else 0.0
	var dur: float = float(am.song_duration) if "song_duration" in am else 0.0

	if song_progress_bar != null and dur > 0.0 and not _is_user_scrubbing:
		song_progress_bar.max_value = dur
		song_progress_bar.value = clampf(playhead, 0.0, dur)

	if time_elapsed_label != null:
		time_elapsed_label.text = _format_time_sec(playhead)

	if time_total_label != null:
		time_total_label.text = _format_time_sec(dur)

func _format_time_sec(sec: float) -> String:
	var total: int = int(floor(maxf(0.0, sec)))
	var m: int = total / 60
	var s: int = total % 60
	return "%d:%02d" % [m, s]

func _process_onset_flash(delta: float) -> void:
	if _onset_flash_timer > 0.0:
		_onset_flash_timer = maxf(0.0, _onset_flash_timer - delta)
		if last_onset_label != null:
			var t: float = clampf(_onset_flash_timer / 0.6, 0.0, 1.0)
			last_onset_label.modulate = Color(0.75, 0.82, 0.92).lerp(Color(1.0, 0.92, 0.25), t)

# --- Microphone & Oscilloscope Telemetry ---

func update_audio_telemetry(waveform: PackedFloat32Array, rms: float, rms_db: float, is_gated: bool, is_capturing: bool, total_frames: int = 0, sr: int = 48000) -> void:
	if _oscilloscope_instance != null and _oscilloscope_instance.has_method("update_waveform"):
		_oscilloscope_instance.update_waveform(waveform, rms, rms_db, is_gated, sr)

	if mic_status_label != null:
		if not is_capturing:
			mic_status_label.text = "● STOPPED"
			mic_status_label.modulate = Color(1.0, 0.3, 0.35)
		elif is_gated:
			mic_status_label.text = "● CAPTURING (Gate Closed)"
			mic_status_label.modulate = Color(0.45, 0.85, 1.0)
		else:
			mic_status_label.text = "● SIGNAL ACTIVE (Gate Open)"
			mic_status_label.modulate = Color(0.15, 1.0, 0.50)

	if mic_level_label != null:
		var db_str: String = "%.1f dB" % maxf(-60.0, rms_db) if rms_db > -90.0 else "-INF dB"
		mic_level_label.text = "Level: %s | RMS: %.4f | Frames: %d" % [db_str, rms, total_frames]

func refresh_microphone_dropdown(devices: PackedStringArray = PackedStringArray(), active_dev: String = "") -> void:
	if mic_dropdown == null:
		return
	mic_dropdown.fit_to_longest_item = false
	mic_dropdown.clip_text = true
	var dev_list: PackedStringArray = devices
	if dev_list.is_empty():
		dev_list = AudioServer.get_input_device_list()
	if dev_list.is_empty():
		dev_list = PackedStringArray(["Default Microphone"])

	var current: String = active_dev if not active_dev.is_empty() else AudioServer.input_device
	if current.is_empty():
		current = dev_list[0]

	mic_dropdown.clear()
	var sel_idx: int = 0
	for i in range(dev_list.size()):
		var d: String = dev_list[i]
		mic_dropdown.add_item(d, i)
		if d == current:
			sel_idx = i

	if mic_dropdown.item_count > 0:
		mic_dropdown.select(sel_idx)

# --- Inference Model Telemetry ---

func update_inference_telemetry(status: Dictionary, recent_onsets: Array = []) -> void:
	var backend_name: String = String(status.get("tier_name", status.get("backend", "Goertzel DSP")))
	var is_ready: bool = bool(status.get("is_ready", true))
	var latency_ms: float = float(status.get("latency_ms", 0.0))
	var pitches: Array = status.get("active_pitches", status.get("pitches", []))
	var conf_map: Dictionary = status.get("confidence_map", status.get("confidence", {}))

	if inference_backend_label != null:
		inference_backend_label.text = "● Engine: %s" % backend_name
		inference_backend_label.modulate = Color(0.2, 1.0, 0.55) if is_ready else Color(1.0, 0.65, 0.2)

	if inference_metrics_label != null:
		inference_metrics_label.text = "Latency: %.1f ms" % latency_ms

	if detected_notes_label != null:
		if pitches.is_empty():
			detected_notes_label.text = "Active Notes: — (Sing or Play)"
			detected_notes_label.modulate = Color(0.55, 0.68, 0.82)
		else:
			var parts: PackedStringArray = PackedStringArray()
			for p in pitches:
				var m: int = int(p)
				var pname: String = _midi_to_name(m)
				var conf: float = float(conf_map.get(str(m), 1.0))
				if conf < 1.0 and conf > 0.0:
					parts.append("%s (%d) [%d%%]" % [pname, m, int(round(conf * 100.0))])
				else:
					parts.append("%s (%d)" % [pname, m])
			detected_notes_label.text = "Active Notes: " + ", ".join(parts)
			detected_notes_label.modulate = Color(0.25, 1.0, 0.6)

	if not recent_onsets.is_empty() and last_onset_label != null:
		var onset_parts: PackedStringArray = PackedStringArray()
		for o in recent_onsets:
			var m: int = int(o)
			onset_parts.append("%s (%d)" % [_midi_to_name(m), m])
		_last_onset_text = "Last Onset: " + ", ".join(onset_parts)
		last_onset_label.text = _last_onset_text
		_onset_flash_timer = 0.6

func _midi_to_name(midi: int) -> String:
	if ResourceLoader.exists("res://scripts/note_data.gd"):
		var NoteDataClass = load("res://scripts/note_data.gd")
		if NoteDataClass.has_method("midi_to_pitch_name"):
			return NoteDataClass.midi_to_pitch_name(midi)
	var names: Array[String] = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
	var pc: int = midi % 12
	var oct: int = (midi / 12) - 1
	return names[pc] + str(oct)

# --- Service Callback Handlers ---

func _on_service_score_updated(score: int, combo: int, mult: float) -> void:
	update_score(score)
	update_combo(combo, int(round(mult)))
	if has_node("/root/ScoringService"):
		var ss = get_node("/root/ScoringService")
		if ss.has_method("get_accuracy"):
			update_accuracy(ss.get_accuracy())

func _on_service_note_scored(note: Variant, rating: String, _points: int) -> void:
	var pos: Vector2 = Vector2.ZERO
	if note is Dictionary and note.has("y_pos"):
		pos = Vector2(160.0, float(note.get("y_pos", 360.0)))
	elif note is RefCounted and "y_pos" in note:
		pos = Vector2(160.0, note.y_pos)
	spawn_judgment_popup(rating, pos)

func _on_service_combo_broken() -> void:
	update_combo(0, 1)

func _on_audio_song_started(_stream: AudioStream) -> void:
	if play_pause_btn != null:
		play_pause_btn.text = "⏸ Pause"

func _on_audio_song_paused() -> void:
	if play_pause_btn != null:
		play_pause_btn.text = "▶ Play"

func _on_audio_song_resumed() -> void:
	if play_pause_btn != null:
		play_pause_btn.text = "⏸ Pause"

func _on_audio_song_stopped() -> void:
	if play_pause_btn != null:
		play_pause_btn.text = "▶ Play"

func _on_audio_song_finished() -> void:
	if play_pause_btn != null:
		play_pause_btn.text = "▶ Play"

func _on_audio_capture_waveform(raw_samples: PackedFloat32Array, rms: float, rms_db: float, is_gated: bool) -> void:
	var frames: int = 0
	var sr: int = 48000
	if has_node("/root/AudioCaptureService"):
		var ac = get_node("/root/AudioCaptureService")
		frames = ac.total_frames_captured if "total_frames_captured" in ac else 0
		if ac.has_method("get_sample_rate"):
			sr = ac.get_sample_rate()
	update_audio_telemetry(raw_samples, rms, rms_db, is_gated, true, frames, sr)

func _on_audio_capture_started() -> void:
	if mic_status_label != null:
		mic_status_label.text = "● CAPTURING"
		mic_status_label.modulate = Color(0.2, 1.0, 0.5)

func _on_audio_capture_stopped() -> void:
	if mic_status_label != null:
		mic_status_label.text = "● STOPPED"
		mic_status_label.modulate = Color(1.0, 0.3, 0.35)

func _on_inference_pitch_detected(pitches: Array[int], confidence_map: Dictionary) -> void:
	var st: Dictionary = {
		"active_pitches": pitches,
		"confidence_map": confidence_map
	}
	if has_node("/root/InferenceService"):
		var inf = get_node("/root/InferenceService")
		if inf.has_method("get_status_summary"):
			st = inf.get_status_summary()
	update_inference_telemetry(st)

func _on_inference_onset_detected(onsets: Array[int]) -> void:
	update_inference_telemetry({}, onsets)

func _on_inference_backend_changed(_tier: int) -> void:
	if has_node("/root/InferenceService"):
		var inf = get_node("/root/InferenceService")
		if inf.has_method("get_status_summary"):
			update_inference_telemetry(inf.get_status_summary())

func _on_gm_piece_loaded(piece_id: String, metadata: Dictionary) -> void:
	var p_title: String = metadata.get("title", piece_id)
	update_piece_title(p_title)

var _is_ui_wired: bool = false

# --- Internal UI Button & Oscilloscope Setup ---

func _wire_ui_buttons() -> void:
	if _is_ui_wired:
		return
	_is_ui_wired = true
	if piece1_btn != null:
		piece1_btn.pressed.connect(func(): piece_selected.emit("piece_1_monophonic", false))
	if piece2_btn != null:
		piece2_btn.pressed.connect(func(): piece_selected.emit("piece_2_harmony", false))
	if piece3_btn != null:
		piece3_btn.pressed.connect(func(): piece_selected.emit("piece_3_polyphonic", false))
	if omr_btn != null:
		omr_btn.pressed.connect(func(): piece_selected.emit("", true))
	if restart_btn != null:
		restart_btn.pressed.connect(func(): restart_requested.emit())
	if play_pause_btn != null:
		play_pause_btn.pressed.connect(_on_play_pause_pressed)

	if custom_btn != null:
		custom_btn.pressed.connect(_toggle_custom_song_modal)

	if refresh_mic_btn != null:
		refresh_mic_btn.pressed.connect(func():
			refresh_microphone_dropdown()
			refresh_mics_requested.emit()
		)
	if mic_dropdown != null:
		mic_dropdown.item_selected.connect(_on_mic_dropdown_selected)
	if test_signal_btn != null:
		test_signal_btn.pressed.connect(_on_test_signal_pressed)

	# Timeline drag / click seek
	if song_progress_bar != null and song_progress_bar is Range:
		song_progress_bar.gui_input.connect(_on_progress_bar_gui_input)

	_build_custom_song_dialogs()

func _on_play_pause_pressed() -> void:
	play_pause_toggled.emit()
	if has_node("/root/AudioManager"):
		var am = get_node("/root/AudioManager")
		if am.is_paused:
			am.resume_music()
		elif am.is_playing:
			am.pause_music()

func _on_progress_bar_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_is_user_scrubbing = true
			_seek_to_mouse_pos(event.position.x)
		else:
			_is_user_scrubbing = false
	elif event is InputEventMouseMotion and _is_user_scrubbing:
		_seek_to_mouse_pos(event.position.x)

func _seek_to_mouse_pos(pos_x: float) -> void:
	if song_progress_bar == null or song_progress_bar.size.x <= 0.0:
		return
	var fraction: float = clampf(pos_x / song_progress_bar.size.x, 0.0, 1.0)
	var target_time: float = fraction * float(song_progress_bar.max_value)
	song_progress_bar.value = target_time
	seek_requested.emit(target_time)
	if has_node("/root/AudioManager"):
		var am = get_node("/root/AudioManager")
		if am.has_method("seek"):
			am.seek(target_time)

func _on_mic_dropdown_selected(index: int) -> void:
	if mic_dropdown == null or index < 0 or index >= mic_dropdown.item_count:
		return
	var dev_name: String = mic_dropdown.get_item_text(index)
	mic_device_selected.emit(dev_name)
	if mic_device_selected.get_connections().is_empty() and has_node("/root/AudioCaptureService"):
		var ac = get_node("/root/AudioCaptureService")
		if ac.has_method("set_input_device"):
			ac.set_input_device(dev_name)
		elif ac.has_method("change_input_device"):
			ac.change_input_device(dev_name)

func _on_test_signal_pressed() -> void:
	test_signal_requested.emit()
	if has_node("/root/AudioCaptureService"):
		var ac = get_node("/root/AudioCaptureService")
		if ac.has_method("inject_test_chord"):
			ac.inject_test_chord([60, 64, 67], 512, 0.28)
		elif ac.has_method("inject_synthetic_chord"):
			ac.inject_synthetic_chord([60, 64, 67], 0.5, 48000, 0.3)

func _setup_oscilloscope() -> void:
	if oscilloscope_container == null:
		oscilloscope_container = find_child("OscilloscopeColumn", true, false) as Control
	if oscilloscope_container == null:
		return

	# If OscilloscopeView is already attached as a child, retain it
	for child in oscilloscope_container.get_children():
		if child.get_class() == "OscilloscopeView" or child.has_method("update_waveform"):
			_oscilloscope_instance = child
			oscilloscope_view = child
			return

	# Otherwise, dynamically load oscilloscope_view.gd if present
	if ResourceLoader.exists("res://scripts/oscilloscope_view.gd"):
		var ScopeClass = load("res://scripts/oscilloscope_view.gd")
		_oscilloscope_instance = ScopeClass.new()
		_oscilloscope_instance.name = "OscilloscopeView"
		_oscilloscope_instance.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_oscilloscope_instance.size_flags_vertical = Control.SIZE_EXPAND_FILL
		oscilloscope_container.add_child(_oscilloscope_instance)
		oscilloscope_view = _oscilloscope_instance

func _toggle_custom_song_modal() -> void:
	if custom_song_modal != null:
		custom_song_modal.visible = not custom_song_modal.visible

func _build_custom_song_dialogs() -> void:
	if custom_song_modal == null:
		return

	# Confirm / Cancel buttons inside modal
	var confirm_btn: Button = custom_song_modal.find_child("ConfirmCustomSongBtn", true, false) as Button
	if confirm_btn != null:
		confirm_btn.pressed.connect(_on_confirm_custom_song)

	var cancel_btn: Button = custom_song_modal.find_child("CancelCustomSongBtn", true, false) as Button
	if cancel_btn != null:
		cancel_btn.pressed.connect(func(): custom_song_modal.visible = false)

	var browse_sheet_btn: Button = custom_song_modal.find_child("BrowseSheetBtn", true, false) as Button
	if browse_sheet_btn != null:
		browse_sheet_btn.pressed.connect(func():
			if sheet_file_dialog != null:
				sheet_file_dialog.popup_centered(Vector2i(720, 480))
		)

	var browse_audio_btn: Button = custom_song_modal.find_child("BrowseAudioBtn", true, false) as Button
	if browse_audio_btn != null:
		browse_audio_btn.pressed.connect(func():
			if audio_file_dialog != null:
				audio_file_dialog.popup_centered(Vector2i(720, 480))
		)

	# FileDialog instances for desktop / Android / iOS
	sheet_file_dialog = FileDialog.new()
	sheet_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	sheet_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	sheet_file_dialog.use_native_dialog = true
	sheet_file_dialog.filters = PackedStringArray(["*.png, *.jpg, *.jpeg ; Sheet Music Images", "*.json ; Note Charts"])
	sheet_file_dialog.file_selected.connect(func(path: String):
		if custom_sheet_input != null:
			custom_sheet_input.text = path
	)
	add_child(sheet_file_dialog)

	audio_file_dialog = FileDialog.new()
	audio_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	audio_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	audio_file_dialog.use_native_dialog = true
	audio_file_dialog.filters = PackedStringArray(["*.wav, *.mp3, *.ogg ; Audio Backing Tracks"])
	audio_file_dialog.file_selected.connect(func(path: String):
		if custom_audio_input != null:
			custom_audio_input.text = path
	)
	add_child(audio_file_dialog)

func _on_confirm_custom_song() -> void:
	var sheet_path: String = custom_sheet_input.text.strip_edges() if custom_sheet_input != null else ""
	var audio_path: String = custom_audio_input.text.strip_edges() if custom_audio_input != null else ""
	var bpm_val: float = float(custom_bpm_spin.value) if custom_bpm_spin != null else 120.0

	if custom_song_modal != null:
		custom_song_modal.visible = false

	if not sheet_path.is_empty():
		custom_song_requested.emit(sheet_path, audio_path, bpm_val)

## Ensures minimal container hierarchy if instantiated dynamically without scene
func _ensure_hierarchy() -> void:
	if safe_margin_container != null or has_node("SafeMarginContainer"):
		return

	# Fallback builder when created via ResponsiveHUD.new()
	safe_margin_container = MarginContainer.new()
	safe_margin_container.name = "SafeMarginContainer"
	safe_margin_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	safe_margin_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(safe_margin_container)

	main_layout = VBoxContainer.new()
	main_layout.name = "MainLayout"
	main_layout.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_layout.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_layout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	main_layout.add_theme_constant_override("separation", 8)
	safe_margin_container.add_child(main_layout)

	judgment_layer = Control.new()
	judgment_layer.name = "JudgmentLayer"
	judgment_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	judgment_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(judgment_layer)
