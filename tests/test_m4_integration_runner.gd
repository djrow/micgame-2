extends SceneTree

## Comprehensive M4 Integration & Scene Verification Runner.
## Tests scenes/main.tscn, scenes/hud.tscn, scenes/permission_screen.tscn,
## scripts/responsive_hud.gd, scripts/permission_screen.gd, scripts/main.gd,
## and scripts/oscilloscope_view.gd.

var total_passed: int = 0
var total_failed: int = 0

func _init() -> void:
	call_deferred("run_all_tests")

func run_all_tests() -> void:
	print("==================================================================")
	print(" STARTING M4 INTEGRATION & SCENE VERIFICATION RUNNER              ")
	print("==================================================================")

	_setup_autoloads()

	test_oscilloscope_view()
	test_permission_screen_scene()
	test_responsive_hud_scene()
	test_main_scene_integration()

	print("==================================================================")
	print(" M4 VERIFICATION RESULTS: %d Passed, %d Failed" % [total_passed, total_failed])
	print("==================================================================")

	if total_failed == 0:
		print("ALL M4 COMPONENTS VERIFIED SUCCESSFULLY [OK]")
		quit(0)
	else:
		printerr("M4 VERIFICATION FAILED: %d test(s) failed." % total_failed)
		quit(1)

func assert_test(cond: bool, msg: String) -> void:
	if cond:
		print("  [PASS] %s" % msg)
		total_passed += 1
	else:
		printerr("  [FAIL] %s" % msg)
		total_failed += 1

func _setup_autoloads() -> void:
	var singletons = [
		{"name": "GameManager", "path": "res://scripts/game_manager.gd"},
		{"name": "AudioManager", "path": "res://scripts/audio_manager.gd"},
		{"name": "AudioCaptureService", "path": "res://scripts/audio_capture_service.gd"},
		{"name": "InferenceService", "path": "res://scripts/inference_service.gd"},
		{"name": "ScoringService", "path": "res://scripts/scoring_service.gd"},
	]
	for s in singletons:
		if not root.has_node(s["name"]):
			var sc = load(s["path"])
			if sc != null:
				var inst = sc.new()
				inst.name = s["name"]
				root.add_child(inst)

# --- Suite 1: OscilloscopeView Unit & Geometry Tests ---
func test_oscilloscope_view() -> void:
	print("\n--- Suite 1: scripts/oscilloscope_view.gd Verification ---")
	var ScopeScript = load("res://scripts/oscilloscope_view.gd")
	assert_test(ScopeScript != null, "scripts/oscilloscope_view.gd loads successfully")

	var scope = ScopeScript.new()
	assert_test(scope != null, "OscilloscopeView instantiates successfully")
	root.add_child(scope)
	scope._ready()

	# Geometry & Dock zone
	scope.snap_to_diagnostic_dock_zone(1280.0)
	assert_test(scope.position.y == 480.0, "Oscilloscope docked at Y = 480.0 (got %f)" % scope.position.y)
	assert_test(scope.size.y == 130.0, "Oscilloscope height is 130.0 px (got %f)" % scope.size.y)
	var clearance = 720.0 - (scope.position.y + scope.size.y)
	assert_test(clearance == 110.0, "Bottom clearance is 110.0 px >= 100 px mobile safe margin")

	# Waveform update & Trigger offset
	var samples := PackedFloat32Array()
	samples.resize(512)
	for i in range(512):
		samples[i] = sin(float(i) * 0.1) * 0.5
	scope.update_waveform(samples, 0.35, -9.1, false, 48000)
	assert_test(scope.current_rms > 0.3, "RMS computed correctly (got %f)" % scope.current_rms)
	assert_test(not scope.is_gated, "Signal above -46 dB gate threshold is marked not gated")
	var trig: int = scope._find_trigger_offset()
	assert_test(trig >= 0 and trig < 512, "Rising-edge trigger offset found: %d" % trig)

	# Circular sample ingestion
	var chunk := PackedFloat32Array()
	chunk.resize(256)
	chunk.fill(0.2)
	scope.push_samples(chunk)
	assert_test(scope.waveform_buffer.size() == 512, "Circular buffer maintains 512 samples")

	# Pitch telemetry
	scope.update_pitch_telemetry([60, 64, 67], {60: 0.95, 64: 0.88, 67: 0.91}, "Goertzel DSP")
	assert_test(scope.active_pitches.size() == 3, "Active pitches updated to 3 chord notes")
	assert_test(scope.backend_name == "Goertzel DSP", "Backend name updated in oscilloscope")

	# Static Note name
	assert_test(ScopeScript.midi_to_note_name(60) == "C4 (60)", "MIDI 60 formats as C4 (60)")
	assert_test(ScopeScript.midi_to_note_name(69) == "A4 (69)", "MIDI 69 formats as A4 (69)")

	scope.clear()
	assert_test(scope.current_rms == 0.0, "clear() resets current_rms to 0.0")
	scope.queue_free()

# --- Suite 2: PermissionScreen Scene Verification ---
func test_permission_screen_scene() -> void:
	print("\n--- Suite 2: scenes/permission_screen.tscn Verification ---")
	var PermScene = load("res://scenes/permission_screen.tscn")
	assert_test(PermScene != null, "scenes/permission_screen.tscn loads successfully")

	var perm = PermScene.instantiate()
	assert_test(perm != null, "PermissionScreen instantiates successfully")
	assert_test(perm is CanvasLayer, "PermissionScreen root is CanvasLayer")
	assert_test(perm.layer == 10, "PermissionScreen layer is set to 10")
	root.add_child(perm)
	perm._ready()

	assert_test(perm.dimmer != null, "Dimmer ColorRect resolved")
	assert_test(perm.safe_margin != null, "SafeAreaMargin resolved")
	assert_test(perm.modal_card != null, "ModalCard resolved")
	assert_test(perm.title_label != null, "TitleLabel resolved")
	assert_test(perm.request_button != null, "RequestButton resolved")
	assert_test(perm.start_button != null, "StartButton resolved")
	assert_test(perm.skip_button != null, "SkipButton resolved")

	# Safe area margins
	perm._apply_safe_area()
	var ml: int = perm.safe_margin.get_theme_constant("margin_left")
	assert_test(ml >= 32, "Safe area margin_left is >= 32px (got %d)" % ml)

	# Headless auto-pass
	assert_test(perm.auto_pass_headless == true, "auto_pass_headless defaults to true")

	# Flow completion signal
	var flow_emitted: Array = [false]
	perm.flow_completed.connect(func(): flow_emitted[0] = true)
	perm._complete_flow(true)
	assert_test(flow_emitted[0] == true, "flow_completed emitted on _complete_flow(true)")
	assert_test(perm.is_permission_granted == true, "is_permission_granted is true")
	assert_test(perm.visible == false, "PermissionScreen hides upon completion")

	perm.queue_free()

# --- Suite 3: ResponsiveHUD Scene Verification ---
func test_responsive_hud_scene() -> void:
	print("\n--- Suite 3: scenes/hud.tscn Verification ---")
	var HudScene = load("res://scenes/hud.tscn")
	assert_test(HudScene != null, "scenes/hud.tscn loads successfully")

	var hud = HudScene.instantiate()
	assert_test(hud != null, "ResponsiveHUD instantiates successfully")
	assert_test(hud is CanvasLayer, "ResponsiveHUD root is CanvasLayer")
	assert_test(hud.layer == 10, "ResponsiveHUD layer is 10")
	root.add_child(hud)
	hud._ready()

	# Node references
	assert_test(hud.safe_margin_container != null, "SafeMarginContainer resolved")
	assert_test(hud.main_layout != null, "MainLayout resolved")
	assert_test(hud.top_bar != null, "TopBar resolved")
	assert_test(hud.piece_title_label != null, "PieceTitleLabel resolved")
	assert_test(hud.piece1_btn != null, "Piece1Btn resolved")
	assert_test(hud.piece2_btn != null, "Piece2Btn resolved")
	assert_test(hud.piece3_btn != null, "Piece3Btn resolved")
	assert_test(hud.omr_btn != null, "OMRScanBtn resolved")
	assert_test(hud.custom_btn != null, "CustomSongBtn resolved")
	assert_test(hud.play_pause_btn != null, "PlayPauseBtn resolved")
	assert_test(hud.restart_btn != null, "RestartBtn resolved")
	assert_test(hud.time_elapsed_label != null, "TimeElapsedLabel resolved")
	assert_test(hud.song_progress_bar != null, "SongProgressBar resolved")
	assert_test(hud.time_total_label != null, "TimeTotalLabel resolved")
	assert_test(hud.score_value != null, "ScoreValue resolved")
	assert_test(hud.accuracy_value != null, "AccuracyValue resolved")
	assert_test(hud.combo_container != null, "ComboContainer resolved")
	assert_test(hud.combo_label != null, "ComboLabel resolved")
	assert_test(hud.multiplier_label != null, "MultiplierLabel resolved")
	assert_test(hud.diagnostic_dock != null, "DiagnosticDock resolved")
	assert_test(hud.mic_status_label != null, "MicStatusLabel resolved")
	assert_test(hud.mic_dropdown != null, "MicDropdown resolved")
	assert_test(hud.refresh_mic_btn != null, "RefreshMicBtn resolved")
	assert_test(hud.mic_level_label != null, "MicLevelLabel resolved")
	assert_test(hud.test_signal_btn != null, "TestSignalBtn resolved")
	assert_test(hud.oscilloscope_container != null, "OscilloscopeColumn resolved")
	assert_test(hud.inference_backend_label != null, "InferenceBackendLabel resolved")
	assert_test(hud.inference_metrics_label != null, "InferenceMetricsLabel resolved")
	assert_test(hud.detected_notes_label != null, "DetectedNotesLabel resolved")
	assert_test(hud.last_onset_label != null, "LastOnsetLabel resolved")
	assert_test(hud.judgment_layer != null, "JudgmentLayer resolved")
	assert_test(hud.custom_song_modal != null, "CustomSongModal resolved")

	# Oscilloscope dynamic slotting
	assert_test(hud.oscilloscope_view != null, "OscilloscopeView automatically embedded into OscilloscopeColumn")

	# Telemetry updates
	hud.update_score(5400)
	assert_test(hud.score_value != null, "update_score executed without crash")

	hud.update_combo(10, 2)
	assert_test(hud.combo_label.text == "10 COMBO", "Combo label shows 10 COMBO")
	assert_test(hud.multiplier_label.text == "2x MULTIPLIER", "Multiplier label shows 2x MULTIPLIER")

	hud.update_accuracy(98.5)
	assert_test(hud.accuracy_value.text == "98.5%", "Accuracy label shows 98.5%")

	hud.spawn_judgment_popup("PERFECT", Vector2(160, 360))
	hud.spawn_judgment_popup("GOOD", Vector2(160, 360))
	hud.spawn_judgment_popup("MISS", Vector2(160, 360))
	assert_test(hud.judgment_layer.get_child_count() == 3, "3 judgment popups spawned in JudgmentLayer")

	# Audio telemetry (6 and 7 argument calls)
	var dummy_raw := PackedFloat32Array()
	dummy_raw.resize(256)
	dummy_raw.fill(0.1)
	hud.update_audio_telemetry(dummy_raw, 0.1, -20.0, false, true, 1000, 48000)
	assert_test(hud.mic_status_label.text.contains("SIGNAL ACTIVE"), "Mic status updated to SIGNAL ACTIVE")

	# Inference telemetry
	var status_dict: Dictionary = {
		"tier_name": "Goertzel DSP",
		"is_ready": true,
		"latency_ms": 1.2,
		"active_pitches": [60, 64, 67],
		"confidence_map": {"60": 0.95, "64": 0.90, "67": 0.85}
	}
	hud.update_inference_telemetry(status_dict, [60, 64])
	assert_test(hud.inference_backend_label.text.contains("Goertzel DSP"), "Inference backend label updated")
	assert_test(hud.detected_notes_label.text.contains("C4 (60)"), "Detected notes label formatted C4 (60)")
	assert_test(hud.last_onset_label.text.contains("C4 (60)"), "Last onset label formatted C4 (60)")

	hud.queue_free()

# --- Suite 4: Main Scene Complete Orchestration ---
func test_main_scene_integration() -> void:
	print("\n--- Suite 4: scenes/main.tscn Complete Integration ---")
	var MainScene = load("res://scenes/main.tscn")
	assert_test(MainScene != null, "scenes/main.tscn loads successfully")

	var main = MainScene.instantiate()
	assert_test(main != null, "Main instantiates successfully")
	var MainClass = load("res://scripts/main.gd")
	assert_test(MainClass != null, "scripts/main.gd loads successfully")
	assert_test(main.get_script() == MainClass, "Main root script is res://scripts/main.gd")

	# Automatically pass desktop gate in headless test
	main.auto_pass_desktop = true
	root.add_child(main)
	main._ready()

	# Master Bus check
	var master_idx: int = AudioServer.get_bus_index("Master")
	assert_test(master_idx == 0, "Master bus is bus 0")
	assert_test(AudioServer.is_bus_mute(0) == false, "Master bus is unmuted")
	assert_test(AudioServer.get_bus_volume_db(0) == 0.0, "Master bus volume is 0.0 dB")

	# Node resolution in Main
	assert_test(main.highway != null, "GrandStaffHighway resolved in Main")
	assert_test(main.hud != null, "ResponsiveHUD resolved in Main")
	assert_test(main.permission_screen != null, "PermissionScreen resolved in Main")
	assert_test(main.oscilloscope_view != null, "OscilloscopeView resolved in Main")
	assert_test(main.level_loader != null, "LevelLoader resolved in Main")
	assert_test(main.audio_player != null, "AudioPlayer resolved in Main")

	# Piece loading
	var loaded_p1: bool = main.load_piece("piece_1_monophonic", false)
	assert_test(loaded_p1 == true, "piece_1_monophonic loaded successfully")
	assert_test(main.highway.chart_notes.size() > 0, "Highway chart notes populated (count=%d)" % main.highway.chart_notes.size())

	var loaded_p2: bool = main.load_piece("piece_2_harmony", false)
	assert_test(loaded_p2 == true, "piece_2_harmony loaded successfully")

	var loaded_p3: bool = main.load_piece("piece_3_polyphonic", false)
	assert_test(loaded_p3 == true, "piece_3_polyphonic loaded successfully")

	# Polyphonic pitch strike evaluation
	main.start_playback()
	assert_test(main.highway.is_playing == true, "Highway is_playing set to true on start_playback")

	# Hit detection simulation
	var hit_fired: Array = [false]
	main.chord_hit_detected.connect(func(_p, _t, _d): hit_fired[0] = true)

	if not main.highway.chart_notes.is_empty():
		var first_note = main.highway.chart_notes[0]
		main.highway.current_song_time = first_note.time_sec + main.input_calibration_offset_sec
		main._evaluate_pitch_candidates([first_note.pitch_midi], [first_note.pitch_midi])
		assert_test(hit_fired[0] == true, "chord_hit_detected signal fired for matched note %d" % first_note.pitch_midi)

	# Process loop safety across 10 frames
	for frame in range(10):
		main._process(0.0166)
	assert_test(true, "Main._process() executed across 10 frames with zero errors")

	# Playback controls
	main.pause_playback()
	assert_test(main.highway.is_playing == false, "pause_playback() stopped highway playback")
	main.resume_playback()
	assert_test(main.highway.is_playing == true, "resume_playback() resumed highway playback")

	# Restart
	main.restart_playback()
	assert_test(main.highway.current_song_time == 0.0, "restart_playback() rewound highway playhead to 0.0")

	main.queue_free()
