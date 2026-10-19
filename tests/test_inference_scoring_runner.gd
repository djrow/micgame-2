# res://tests/test_inference_scoring_runner.gd
extends SceneTree

## Comprehensive Headless Verification Runner for V2 Polyphonic Microphone Rhythm Game (micgame-2).
## Validates all 10 core subsystems across AudioCaptureService, InferenceService (4 tiers),
## ScoringService, GrandStaffHighway, NoteData/Diatonic Math, OscilloscopeView, ResponsiveHUD,
## LevelLoader, OMRProcessor, and Cross-Platform Export Configurations.

const AudioCaptureServiceScript = preload("res://scripts/audio_capture_service.gd")
const AudioManagerScript = preload("res://scripts/audio_manager.gd")
const GameManagerScript = preload("res://scripts/game_manager.gd")
const InferenceServiceScript = preload("res://scripts/inference_service.gd")
const ScoringServiceScript = preload("res://scripts/scoring_service.gd")
const GrandStaffHighwayScript = preload("res://scripts/grand_staff_highway.gd")
const NoteDataScript = preload("res://scripts/note_data.gd")
const LevelLoaderScript = preload("res://scripts/level_loader.gd")
const OMRProcessorScript = preload("res://scripts/omr_processor.gd")
const OscilloscopeViewScript = preload("res://scripts/oscilloscope_view.gd")

var tests_passed: int = 0
var tests_failed: int = 0

func assert_true(condition: bool, msg: String) -> void:
	if condition:
		tests_passed += 1
		print("  [PASS] %s" % msg)
	else:
		tests_failed += 1
		printerr("  [FAIL] %s" % msg)

func assert_eq(actual: Variant, expected: Variant, msg: String) -> void:
	if actual == expected:
		tests_passed += 1
		print("  [PASS] %s (expected %s, got %s)" % [msg, str(expected), str(actual)])
	else:
		tests_failed += 1
		printerr("  [FAIL] %s (expected %s, got %s)" % [msg, str(expected), str(actual)])

func _create_mock_driver() -> RefCounted:
	var S = load("res://scripts/inference/mock_driver.gd")
	if S:
		return S.new()
	var Fallback = load("res://scripts/inference/audio_pitch_model.gd")
	return Fallback.new()

func _setup_autoloads() -> void:
	var singletons: Array[Dictionary] = [
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

func _init() -> void:
	call_deferred("_run_all_suites")

func _run_all_suites() -> void:
	print("==================================================")
	print(" RUNNING FULL INFERENCE & SCORING VERIFICATION    ")
	print("==================================================")

	_setup_autoloads()

	test_suite_1_audio_capture_bus_and_lifecycle()
	test_suite_2_stereo_downmix_and_noise_gate()
	test_suite_3_mock_driver_integration()
	test_suite_4_polyphonic_cluster_matching()
	test_suite_5_partial_chords_and_miss_handling()
	test_suite_6_sustain_retrigger_filtering()
	test_suite_7_end_to_end_gameplay_chain()
	test_suite_8_oscilloscope_mic_dropdown_and_live_dsp()
	test_suite_9_native_onnx_driver_pipeline()
	test_suite_10_custom_song_import_and_ios_readiness()
	test_suite_11_latency_calibration_and_instrument_finetuning()

	print("==================================================")
	print(" RESULTS: %d Passed, %d Failed" % [tests_passed, tests_failed])
	print("==================================================")

	await process_frame

	if tests_failed == 0:
		print("ALL INFERENCE & SCORING SUITES PASSED [OK]")
		quit(0)
	else:
		push_error("VERIFICATION FAILED with %d errors" % tests_failed)
		quit(1)

func test_suite_1_audio_capture_bus_and_lifecycle() -> void:
	print("\n--- Test Suite 1: AudioCaptureService Record Bus & Lifecycle ---")
	assert_true(AudioCaptureServiceScript != null, "AudioCaptureService script loads cleanly")

	var cap = AudioCaptureServiceScript.new()
	cap.auto_start = false
	root.add_child(cap)

	assert_eq(cap.is_capturing, false, "Initial capturing state is false")
	assert_true(cap.record_bus_idx > 0, "Record bus index resolved (> 0, Bus 0 Master protected)")
	assert_eq(AudioServer.get_bus_name(0), "Master", "Bus 0 is Master")
	assert_eq(AudioServer.is_bus_mute(0), false, "Bus 0 (Master) is unmuted")
	assert_eq(AudioServer.get_bus_volume_db(0), 0.0, "Bus 0 (Master) volume is 0.0 dB")
	assert_eq(AudioServer.is_bus_mute(cap.record_bus_idx), true, "Record bus is muted to prevent feedback")
	assert_true(cap.capture_effect != null, "AudioEffectCapture attached to Record bus")
	assert_eq(cap.capture_effect.buffer_length, 1.0, "AudioEffectCapture ring buffer length is 1.0s")

	cap.start_capture()
	assert_eq(cap.is_capturing, true, "Capture started successfully")

	cap.stop_capture()
	assert_eq(cap.is_capturing, false, "Capture stopped successfully")

	cap.free()

func test_suite_2_stereo_downmix_and_noise_gate() -> void:
	print("\n--- Test Suite 2: Stereo Downmix & RMS Noise Gating (-46 dB / 0.005 RMS) ---")
	var cap = AudioCaptureServiceScript.new()
	var mock = _create_mock_driver()
	cap.set_pitch_model(mock)

	# 1. Stereo to mono downmix: (L + R) * 0.5
	var stereo_test = PackedVector2Array([
		Vector2(1.0, 1.0),
		Vector2(-0.8, -0.2),
		Vector2(0.5, -0.5)
	])
	var mono = cap.process_stereo_buffer(stereo_test)
	assert_eq(mono[0], 1.0, "Stereo (1.0, 1.0) -> Mono 1.0")
	assert_true(absf(mono[1] - (-0.5)) < 0.0001, "Stereo (-0.8, -0.2) -> Mono -0.5")
	assert_eq(mono[2], 0.0, "Stereo (0.5, -0.5) -> Mono 0.0")

	# 2. Pure silence gating
	mock.reset()
	var silence = PackedVector2Array()
	silence.resize(256)
	silence.fill(Vector2.ZERO)
	var gated_silence = cap.process_stereo_buffer(silence)
	assert_eq(cap.current_rms, 0.0, "Silence RMS is 0.0")
	assert_eq(cap.current_rms_db, -100.0, "Silence dB is -100.0 dB floor")
	assert_true(cap.is_currently_gated, "Silence is gated")
	assert_eq(gated_silence.size(), 256, "Gated silence buffer maintains 256 frames")
	assert_eq(mock._samples_processed, 256, "256 zero samples pushed during silence to preserve clock")

	# 3. Room noise suppression (< 0.005 RMS / -46 dB)
	mock.reset()
	var noise = PackedVector2Array()
	noise.resize(256)
	noise.fill(Vector2(0.003, 0.003)) # 0.003 < 0.005 threshold
	var gated_noise = cap.process_stereo_buffer(noise)
	assert_true(cap.current_rms < 0.005, "Noise RMS < 0.005 threshold")
	assert_true(cap.is_currently_gated, "Room noise suppressed by -46 dB noise gate")
	assert_eq(gated_noise[0], 0.0, "Gated noise sample zeroed out")

	# 4. Musical signal passing (>= 0.005 RMS)
	mock.reset()
	var tone = PackedVector2Array()
	tone.resize(256)
	for i in range(256):
		var v: float = 0.4 * sin(float(i) * 0.1)
		tone[i] = Vector2(v, v)
	cap.process_stereo_buffer(tone)
	assert_true(cap.current_rms > 0.05, "Musical tone RMS > 0.05")
	assert_true(not cap.is_currently_gated, "Musical tone passes noise gate")
	assert_eq(mock._samples_processed, 256, "Active audio samples received by model runner")

	cap.free()

func test_suite_3_mock_driver_integration() -> void:
	print("\n--- Test Suite 3: MockDriver & IAudioPitchModel Polymorphic Protocol ---")
	var mock = _create_mock_driver()

	assert_true(mock.is_model_ready(), "MockDriver is immediately ready")
	assert_eq(mock.get_detected_pitches().size(), 0, "Initial detected pitches is empty")
	assert_eq(mock.get_recent_onsets().size(), 0, "Initial recent onsets is empty")

	# Programmatic pitch and onset injection
	mock.set_detected_pitches([60, 64, 67])
	mock.set_recent_onsets([60])
	assert_eq(mock.get_detected_pitches(), [60, 64, 67], "Detected pitches updated to [60, 64, 67]")
	assert_eq(mock.get_recent_onsets(), [60], "Recent onsets updated to [60]")

	# Test WebSocketDriver structure
	var WsScript = load("res://scripts/inference/websocket_driver.gd")
	assert_true(WsScript != null, "WebSocketDriver script loads cleanly")
	var ws_driver = WsScript.new("ws://127.0.0.1:8765")
	assert_eq(ws_driver.is_model_ready(), false, "WebSocket driver initial readiness is false until connected")
	ws_driver.disconnect_from_server()

func test_suite_4_polyphonic_cluster_matching() -> void:
	print("\n--- Test Suite 4: Polyphonic Chord Matching & Diatonic Geometry ---")
	var scoring = ScoringServiceScript.new()
	scoring.auto_sync_game_manager = false
	var active_notes = [
		{"pitch_midi": 60, "time_sec": 1.0, "duration_sec": 1.0, "is_hit": false, "is_missed": false}, # C4
		{"pitch_midi": 64, "time_sec": 1.0, "duration_sec": 1.0, "is_hit": false, "is_missed": false}, # E4
		{"pitch_midi": 67, "time_sec": 1.0, "duration_sec": 1.0, "is_hit": false, "is_missed": false}  # G4
	]

	# All 3 chord tones arrive concurrently at time 1.02s (+20ms -> PERFECT)
	var chord_cluster = [60, 64, 67]
	var now: float = 1.02
	var hits: Array[Dictionary] = []

	for pitch in chord_cluster:
		var res: Dictionary = scoring.process_input(now, pitch, active_notes, 0)
		if not res.is_empty():
			hits.append(res)

	assert_eq(hits.size(), 3, "All 3 chord tones matched and scored concurrently")
	assert_eq(active_notes[0]["is_hit"], true, "C4 is_hit = true")
	assert_eq(active_notes[1]["is_hit"], true, "E4 is_hit = true")
	assert_eq(active_notes[2]["is_hit"], true, "G4 is_hit = true")
	assert_eq(scoring.current_combo, 3, "Combo incremented to 3 for triad")
	assert_eq(scoring.total_score, 300, "Score awarded 300 points (3 x 100 Perfect)")
	assert_eq(scoring.count_perfect, 3, "3 Perfect counts recorded")

	# Verify Diatonic Y-placement & Harmonic Second Offset (+16.0 px)
	assert_eq(NoteDataScript.midi_to_y(60), 360.0, "Middle C4 maps to Y = 360.0 px")
	assert_eq(NoteDataScript.midi_to_y(64), 342.0, "E4 (Treble line 1) maps to Y = 342.0 px")
	assert_eq(NoteDataScript.midi_to_y(67), 324.0, "G4 (Treble line 2) maps to Y = 324.0 px")
	var second_notes: Array[NoteData] = [
		NoteDataScript.new(1, 60, 1.0, 1.0), # C4
		NoteDataScript.new(2, 62, 1.0, 1.0)  # D4
	]
	GrandStaffHighwayScript.calculate_chord_offsets(second_notes)
	assert_eq(second_notes[1].chord_offset_x, 16.0, "Harmonic second C4-D4 offsets D4 horizontally by +16.0 px")

	scoring.free()

func test_suite_5_partial_chords_and_miss_handling() -> void:
	print("\n--- Test Suite 5: Partial Chord Match & Note Expiration ---")
	var scoring = ScoringServiceScript.new()
	scoring.auto_sync_game_manager = false
	var active_notes = [
		{"pitch_midi": 60, "time_sec": 2.0, "duration_sec": 0.5, "is_hit": false, "is_missed": false},
		{"pitch_midi": 64, "time_sec": 2.0, "duration_sec": 0.5, "is_hit": false, "is_missed": false},
		{"pitch_midi": 67, "time_sec": 2.0, "duration_sec": 0.5, "is_hit": false, "is_missed": false}
	]

	# User only plays C4 and E4, omitting G4
	var partial_cluster = [60, 64]
	var now: float = 2.01
	for p in partial_cluster:
		scoring.process_input(now, p, active_notes, 0)

	assert_eq(active_notes[0]["is_hit"], true, "C4 struck")
	assert_eq(active_notes[1]["is_hit"], true, "E4 struck")
	assert_eq(active_notes[2]["is_hit"], false, "G4 remains unhit")
	assert_eq(scoring.current_combo, 2, "Combo is 2")

	# Playhead passes beyond +100ms miss window (2.15s > 2.0s + 0.10s)
	var expired = scoring.check_expired_notes(2.15, active_notes)
	assert_eq(expired.size(), 1, "1 note expired (G4)")
	assert_eq(expired[0]["judgment"], "MISS", "G4 judged MISS")
	assert_eq(active_notes[2]["is_missed"], true, "G4 marked missed")
	assert_eq(scoring.current_combo, 0, "Combo reset to 0 by missed chord note")

	scoring.free()

func test_suite_6_sustain_retrigger_filtering() -> void:
	print("\n--- Test Suite 6: Sustain vs Onset Edge Retrigger Filtering ---")
	var scoring = ScoringServiceScript.new()
	scoring.auto_sync_game_manager = false
	var active_notes = [
		{"pitch_midi": 60, "time_sec": 1.0, "duration_sec": 1.0, "is_hit": false, "is_missed": false},
		{"pitch_midi": 60, "time_sec": 2.5, "duration_sec": 1.0, "is_hit": false, "is_missed": false}
	]
	scoring.set_active_chart(active_notes)

	# Frame 1: Note 1 attack
	var f1_hits = scoring.process_detected_pitches([60], [60], 1.0)
	assert_eq(f1_hits.size(), 1, "Note 1 hit on initial attack")
	assert_eq(active_notes[0]["is_hit"], true, "Note 1 hit at 1.0s")
	assert_eq(scoring.current_combo, 1, "Combo is 1")

	# Frames 2..6: Holding sustain (detected_pitches has 60, onsets empty)
	for f in range(5):
		var fn_hits = scoring.process_detected_pitches([60], [], 1.1 + float(f) * 0.1)
		assert_eq(fn_hits.size(), 0, "No duplicate strike during sustained note (frame %d)" % (f + 2))

	assert_eq(scoring.current_combo, 1, "Combo preserved at 1 during sustain")
	assert_eq(active_notes[1]["is_hit"], false, "Subsequent note 2 at 2.5s untouched")

	# Frame 7: Release tone and re-attack Note 2 at 2.5s
	var f7_hits = scoring.process_detected_pitches([60], [60], 2.5)
	assert_eq(f7_hits.size(), 1, "Note 2 hit on new onset at 2.5s")
	assert_eq(active_notes[1]["is_hit"], true, "Note 2 marked is_hit")
	assert_eq(scoring.current_combo, 2, "Combo reached 2")
	assert_eq(scoring.total_score, 200, "Score reached 200")

	scoring.free()

func test_suite_7_end_to_end_gameplay_chain() -> void:
	print("\n--- Test Suite 7: Full End-to-End Chain (Capture -> Model -> Matcher -> Scoring) ---")
	var cap = AudioCaptureServiceScript.new()
	var mock = _create_mock_driver()
	cap.set_pitch_model(mock)
	cap.start_capture()

	var scoring = ScoringServiceScript.new()
	scoring.auto_sync_game_manager = false
	var test_chart = [
		{"pitch_midi": 60, "time_sec": 1.0, "duration_sec": 0.4, "is_hit": false, "is_missed": false}, # C4
		{"pitch_midi": 64, "time_sec": 2.0, "duration_sec": 0.4, "is_hit": false, "is_missed": false}, # E4
		{"pitch_midi": 67, "time_sec": 2.0, "duration_sec": 0.4, "is_hit": false, "is_missed": false}  # G4
	]

	# 1. Background room noise is gated
	var noise = PackedVector2Array()
	noise.resize(256)
	noise.fill(Vector2(0.002, 0.002))
	cap.process_stereo_buffer(noise)
	assert_true(cap.is_currently_gated, "Background noise gated")

	# 2. Player sings C4 tone at 1.02s
	var tone = PackedVector2Array()
	tone.resize(256)
	for i in range(256):
		tone[i] = Vector2(0.3, 0.3)
	cap.process_stereo_buffer(tone)
	assert_true(not cap.is_currently_gated, "Musical audio passed noise gate")

	# Model detects C4
	mock.set_detected_pitches([60])
	mock.set_recent_onsets([60])

	# Polyphonic cluster matcher evaluates
	var onsets = mock.get_recent_onsets()
	for p in onsets:
		scoring.process_input(1.02, p, test_chart, 0)

	assert_eq(test_chart[0]["is_hit"], true, "Note C4 scored from audio pipeline")
	assert_eq(scoring.current_combo, 1, "Combo is 1")

	# 3. Player plays chord (E4, G4) at 2.03s
	cap.process_stereo_buffer(tone)
	mock.set_detected_pitches([64, 67])
	mock.set_recent_onsets([64, 67])

	var chord_onsets = mock.get_recent_onsets()
	for p in chord_onsets:
		scoring.process_input(2.03, p, test_chart, 0)

	assert_eq(test_chart[1]["is_hit"], true, "Chord note E4 scored")
	assert_eq(test_chart[2]["is_hit"], true, "Chord note G4 scored")
	assert_eq(scoring.current_combo, 3, "Combo reached 3")

	var summary: Dictionary = scoring.get_summary()
	assert_eq(summary["total_notes"], 3, "3 total notes scored")
	assert_eq(summary["count_perfect"], 3, "All 3 scored PERFECT")
	assert_eq(summary["count_miss"], 0, "0 misses")
	assert_eq(summary["accuracy_pct"], 100.0, "100.0% accuracy")

	scoring.free()
	cap.stop_capture()
	cap.free()

func test_suite_8_oscilloscope_mic_dropdown_and_live_dsp() -> void:
	print("\n--- Test Suite 8: OscilloscopeView, Mic Dropdown & Native Polyphonic DSP ---")
	var DetectorScript = load("res://scripts/inference/native_pitch_detector.gd")
	var HudScene = load("res://scenes/hud.tscn")

	var cap = AudioCaptureServiceScript.new()
	cap.auto_start = false
	var sr: float = float(cap.get_sample_rate())
	if sr <= 0.0:
		sr = 48000.0
	var dsp = DetectorScript.new(sr)
	cap.set_pitch_model(dsp)

	var devices: PackedStringArray = cap.get_input_devices()
	assert_true(devices.size() >= 1, "AudioCaptureService enumerates at least 1 microphone device (%d found)" % devices.size())
	var switched: bool = cap.set_input_device(devices[0])
	assert_true(switched, "AudioCaptureService switches to microphone device '%s'" % devices[0])

	# Inject C Major Triad (60, 64, 67) into AudioCaptureService and verify Oscilloscope buffer + NativePitchDetector
	cap.inject_test_chord([60, 64, 67], 2048, 0.30)
	assert_eq(cap.oscilloscope_ring_buffer.size(), 512, "Oscilloscope ring buffer holds 512 samples")
	assert_true(cap.current_rms > 0.05, "Injected test chord produces positive RMS (%.3f)" % cap.current_rms)

	var detected: Array[int] = dsp.get_detected_pitches()
	assert_true(detected.has(60) and detected.has(64) and detected.has(67), "NativePitchDetector detected C Major Triad [60, 64, 67]: got %s" % str(detected))

	var hud = HudScene.instantiate()
	root.add_child(hud)
	hud.refresh_microphone_dropdown(devices, cap.get_current_input_device())
	assert_true(hud.mic_dropdown != null and hud.mic_dropdown.item_count >= 1, "HUD MicDropdown OptionButton populated with input devices")
	assert_true(hud.oscilloscope_view != null, "HUD OscilloscopeView control instantiated")

	hud.update_audio_telemetry(cap.oscilloscope_ring_buffer, cap.current_rms, cap.current_rms_db, cap.is_currently_gated, true, cap.total_frames_captured, int(sr))
	var status_summary: Dictionary = {
		"tier_name": "Goertzel Polyphonic DSP",
		"is_ready": true,
		"latency_ms": dsp.get_last_latency_ms(),
		"active_pitches": detected,
		"confidence_map": dsp.get_confidence_map()
	}
	hud.update_inference_telemetry(status_summary, dsp.pop_recent_onsets())
	assert_true(hud.detected_notes_label.text.find("C4 (60)") != -1, "HUD DetectedNotesLabel displays live detected note C4 (60): '%s'" % hud.detected_notes_label.text)
	assert_true(hud.oscilloscope_view.current_rms > 0.05, "OscilloscopeView records non-zero waveform RMS")

	hud.free()
	cap.free()

func test_suite_9_native_onnx_driver_pipeline() -> void:
	print("\n--- Test Suite 9: Native ONNX Driver & Multi-Tier Fallback Pipeline ---")
	var OnnxScript = load("res://scripts/inference/onnx_native_driver.gd")
	assert_true(OnnxScript != null, "OnnxNativeDriver script loads cleanly")
	var onnx_drv = OnnxScript.new()

	var inf = root.get_node_or_null("InferenceService")
	assert_true(inf != null, "InferenceService singleton is present in tree")

	# Verify graceful fallback from Tier 1 (NATIVE_ONNX) to Tier 3 (GD_DSP) when binary not present
	inf.set_tier(inf.ModelTier.NATIVE_ONNX)
	if not onnx_drv.is_available():
		assert_eq(inf.get_tier(), inf.ModelTier.GD_DSP, "InferenceService gracefully falls back to GD_DSP when native ONNX binary is absent")
	else:
		assert_eq(inf.get_tier(), inf.ModelTier.NATIVE_ONNX, "InferenceService activates NATIVE_ONNX when binary is present")

	# Feed synthetic C Major Triad through InferenceService active pipeline
	var sr: float = float(AudioServer.get_mix_rate())
	if sr <= 0.0:
		sr = 48000.0
	var chord := PackedFloat32Array()
	chord.resize(2048)
	var voice_amp: float = 0.30 / 3.0
	for i in range(2048):
		var t: float = float(i) / sr
		var s: float = 0.0
		for m in [60, 64, 67]:
			var f: float = 440.0 * pow(2.0, float(m - 69) / 12.0)
			s += voice_amp * (0.80 * sin(TAU * f * t) + 0.20 * sin(TAU * 2.0 * f * t))
		chord[i] = s

	inf.push_audio_samples(chord)
	var det: Array[int] = inf.get_active_pitches()
	assert_true(det.has(60) and det.has(64) and det.has(67), "InferenceService pipeline detected C major triad [60, 64, 67]: %s" % str(det))
	assert_true(inf.get_confidence_map().has("60"), "InferenceService confidence map populated for MIDI 60")

	# Verify that feeding silence immediately clears active pitches and recent onsets (zero phantom notes)
	var silence_buf := PackedFloat32Array()
	silence_buf.resize(2048)
	silence_buf.fill(0.0)
	inf.push_audio_samples(silence_buf)
	assert_eq(inf.get_active_pitches().size(), 0, "InferenceService clears active pitches on silence")
	assert_eq(inf.get_recent_onsets().size(), 0, "InferenceService clears recent onsets on silence")

	# Verify that loud broadband noise (e.g. breath/hiss/percussive noise) triggers ZERO false notes
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	var noise_triggered_notes: int = 0
	for _chunk in range(16):
		var loud_noise := PackedFloat32Array()
		loud_noise.resize(256)
		for i in range(256):
			loud_noise[i] = rng.randf_range(-0.25, 0.25)
		inf.push_audio_samples(loud_noise)
		noise_triggered_notes += inf.get_active_pitches().size() + inf.get_recent_onsets().size()
	assert_eq(noise_triggered_notes, 0, "Broadband noise triggers zero false pitches or onsets")



func test_suite_10_custom_song_import_and_ios_readiness() -> void:
	print("\n--- Test Suite 10: Custom Song OMR Import Dialog & Cross-Platform Readiness ---")
	var main_scene_res = load("res://scenes/main.tscn")
	assert_true(main_scene_res != null, "scenes/main.tscn loads cleanly")

	var main_node = main_scene_res.instantiate()
	main_node.enable_mic_capture = false
	main_node.auto_pass_desktop = true
	root.add_child(main_node)

	var hud = main_node.hud
	var highway = main_node.highway
	var audio_player = main_node.audio_player

	assert_true(hud != null, "ResponsiveHUD node exists in Main scene")
	assert_true(hud.custom_btn != null, "HUD Custom Song button initialized")
	assert_true(hud.custom_song_modal != null, "HUD CustomSongModal initialized")
	assert_true(hud.sheet_file_dialog != null, "HUD SheetFileDialog initialized")
	assert_true(hud.audio_file_dialog != null, "HUD AudioFileDialog initialized")

	# Simulate opening modal and submitting a custom song request via HUD
	hud._toggle_custom_song_modal()
	assert_eq(hud.custom_song_modal.visible, true, "CustomSongModal opens when Custom Song button is pressed")

	hud.sheet_file_dialog.file_selected.emit("res://assets/test_pieces/piece_1_monophonic/score.png")
	hud.audio_file_dialog.file_selected.emit("res://assets/test_pieces/piece_1_monophonic/audio.wav")
	hud.custom_bpm_spin.value = 108.0
	hud._on_confirm_custom_song()

	assert_eq(hud.custom_song_modal.visible, false, "CustomSongModal closes after confirming load")
	assert_true(absf(float(main_node.level_loader.current_level_data.get("bpm", 0.0)) - 108.0) < 0.01, "Main.load_custom_song digitized score.png via OMR with custom BPM (108.0)")
	assert_true(highway.chart_notes.size() > 0, "Main.load_custom_song loaded notes into GrandStaffHighway (%d notes)" % highway.chart_notes.size())
	assert_true(audio_player.stream != null, "Main.load_custom_song paired custom audio.wav into AudioStreamPlayer")

	# Verify iOS & Android export_presets.cfg readiness
	var export_cfg := FileAccess.open("res://export_presets.cfg", FileAccess.READ)
	assert_true(export_cfg != null, "export_presets.cfg exists and is readable")
	var export_text: String = export_cfg.get_as_text() if export_cfg != null else ""
	assert_true(export_text.contains('architectures/arm64-v8a=true'), "Android ARM64-v8a preset enabled")
	assert_true(export_text.contains('application/app_store_team_id="0000000000"'), "iOS placeholder Team ID configured")
	assert_true(export_text.contains('user_data/accessible_from_files_app=true'), "iOS Files App sharing enabled")

	main_node.audio_player.stop()
	main_node.audio_player.stream = null
	if main_node.level_loader != null:
		main_node.level_loader.current_level_data.clear()
	var am = root.get_node_or_null("AudioManager")
	if am != null:
		if am.has_method("stop_song"):
			am.stop_song()
		if am.get("_music_player") != null:
			am._music_player.stop()
			am._music_player.stream = null
		am._current_stream = null
	main_node.free()

func test_suite_11_latency_calibration_and_instrument_finetuning() -> void:
	print("\n--- Test Suite 11: Latency Calibration & Instrument Model Fine-Tuning ---")
	var InstrumentProfileScript = load("res://scripts/inference/instrument_profile.gd")
	assert_true(InstrumentProfileScript != null, "InstrumentProfile script loads cleanly")

	var profile = InstrumentProfileScript.new("balanced")
	assert_eq(profile.preset_id, "balanced", "Default preset is 'balanced'")
	assert_eq(profile.input_latency_offset_ms, 50.0, "Default input latency offset is 50.0 ms")
	assert_eq(profile.per_bin_gain_adapter.size(), 88, "88-bin neural gain adapter initialized")

	# Test preset switching
	profile.apply_preset("plucked_guitar")
	assert_eq(profile.preset_id, "plucked_guitar", "Preset switched to 'plucked_guitar'")
	assert_eq(profile.harmonic_2nd_suppression, 0.62, "Guitar preset harmonic 2nd suppression set to 0.62")
	assert_eq(profile.onnx_sustain_threshold, 0.30, "Guitar preset ONNX sustain threshold set to 0.30")

	profile.apply_preset("bowed_strings")
	assert_eq(profile.preset_id, "bowed_strings", "Preset switched to 'bowed_strings'")
	assert_eq(profile.harmonic_2nd_suppression, 0.65, "Bowed strings harmonic 2nd suppression set to 0.65")
	assert_eq(profile.dsp_attack_crest_min, 3.2, "Bowed strings attack crest minimum set to 3.2")

	# Test learning from synthetic instrument audio (A4 440Hz / MIDI 69 tone with 2nd harmonic)
	var synthetic_instrument := PackedFloat32Array()
	var sr: float = 48000.0
	var dur_samples: int = int(sr * 0.5) # 0.5s tone
	synthetic_instrument.resize(dur_samples)
	for i in range(dur_samples):
		var t: float = float(i) / sr
		var f0: float = sin(TAU * 440.0 * t) * 0.45
		var f1: float = sin(TAU * 880.0 * t) * 0.25 # 2nd harmonic
		synthetic_instrument[i] = f0 + f1

	var learn_res: Dictionary = profile.learn_from_instrument_samples(synthetic_instrument, sr)
	assert_true(bool(learn_res.get("ok", false)), "learn_from_instrument_samples successfully analyzed tone")
	assert_eq(profile.preset_id, "custom_finetuned", "Preset transitioned to 'custom_finetuned'")
	assert_true(profile.per_bin_gain_adapter[69 - 21] >= 1.0, "88-bin neural adapter calibrated for detected fundamental register")

	# Test serialization & dictionary round-trip
	var p_dict: Dictionary = profile.to_dict()
	var restored_profile = InstrumentProfileScript.new()
	restored_profile.from_dict(p_dict)
	assert_eq(restored_profile.preset_id, "custom_finetuned", "Restored profile preset_id matches")
	assert_true(absf(restored_profile.harmonic_2nd_suppression - profile.harmonic_2nd_suppression) < 0.005, "Restored profile harmonic suppression matches within float rounding")

	# Test InferenceService integration
	var inf = root.get_node_or_null("InferenceService")
	if inf != null:
		inf.set_instrument_preset("woodwind_brass", false)
		assert_eq(inf.instrument_profile.preset_id, "woodwind_brass", "InferenceService.set_instrument_preset updated profile")
		var summary: Dictionary = inf.get_status_summary()
		assert_true(summary.has("profile_name"), "InferenceService summary reports profile_name")
		assert_true(summary.has("calibration_ms"), "InferenceService summary reports calibration_ms")

	# Test Main & HUD calibration synchronization
	var main_scene_res = load("res://scenes/main.tscn")
	var main_node = main_scene_res.instantiate()
	main_node.enable_mic_capture = false
	main_node.auto_pass_desktop = true
	root.add_child(main_node)

	var hud = main_node.hud
	assert_true(hud.calibrate_btn != null, "HUD CalibrateBtn initialized")
	assert_true(hud.calibration_modal != null, "HUD CalibrationModal initialized")
	assert_true(hud.latency_slider != null, "HUD LatencySlider initialized")
	assert_true(hud.latency_spin != null, "HUD LatencySpin initialized")
	assert_true(hud.auto_cal_btn != null, "HUD AutoCalBtn initialized")

	# Test opening calibration modal
	hud.toggle_calibration_modal()
	assert_eq(hud.calibration_modal.visible, true, "toggle_calibration_modal opens modal")

	# Test setting latency offset through Main
	main_node.set_input_calibration_offset_ms(75.0)
	assert_eq(main_node.input_calibration_offset_sec, 0.075, "Main.input_calibration_offset_sec updated to 0.075s")
	var ss = root.get_node_or_null("ScoringService")
	if ss != null:
		assert_eq(ss.input_calibration_offset_sec, 0.075, "ScoringService.input_calibration_offset_sec synchronized")
	assert_eq(hud.latency_slider.value, 75.0, "HUD LatencySlider updated to 75.0 ms")
	assert_eq(hud.latency_spin.value, 75.0, "HUD LatencySpin updated to 75.0 ms")

	# Test relative adjustment (KEY_LEFT / KEY_RIGHT simulation)
	main_node._adjust_calibration(+10.0)
	assert_eq(main_node.input_calibration_offset_sec, 0.085, "Main._adjust_calibration(+10ms) updated offset to 85.0 ms")
	assert_eq(hud.latency_slider.value, 85.0, "HUD LatencySlider updated to 85.0 ms after adjustment")

	main_node.audio_player.stop()
	main_node.audio_player.stream = null
	main_node.free()

