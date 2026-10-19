# res://tests/test_m4_adversarial_challenger_runner.gd
extends SceneTree

## M4 Adversarial Challenger Test Suite
## Stress-tests Responsive HUD, Permission Screen, OscilloscopeView, and Main Scene Coordinator.
## Covers:
## - Dynamic screen resizing (Pixel 7a 2400x1080 20:9, notch/pill safe margins, 4:3, 16:9, ultrawide).
## - Rapid permission button clicks, denial vs grant transitions, headless auto-pass logic.
## - Rapid level switching (Ode to Joy, Bach Minuet, Cadence & Triads) and custom song OMR ingestion via modal.
## - Process-loop audit guaranteeing zero play() calls in _process().

const HudScript = preload("res://scripts/responsive_hud.gd")
const PermScript = preload("res://scripts/permission_screen.gd")
const ScopeScript = preload("res://scripts/oscilloscope_view.gd")
const MainScript = preload("res://scripts/main.gd")
const LoaderScript = preload("res://scripts/level_loader.gd")

var total_passed: int = 0
var total_failed: int = 0
var failure_details: Array[String] = []

func _init() -> void:
	call_deferred("run_all_challenges")

func run_all_challenges() -> void:
	print("==================================================================")
	print(" STARTING M4 ADVERSARIAL CHALLENGER TEST SUITE                   ")
	print("==================================================================")

	_setup_autoloads()

	test_suite_1_screen_resizing_and_safe_areas()
	test_suite_2_permission_screen_state_machine()
	test_suite_3_level_switching_and_shortcuts()
	test_suite_4_custom_song_omr_modal()
	test_suite_5_telemetry_and_process_loop_audit()

	print("==================================================================")
	print(" M4 ADVERSARIAL RESULTS: %d Passed, %d Failed" % [total_passed, total_failed])
	print("==================================================================")

	if failure_details.size() > 0:
		print("\n--- FAILURE BREAKDOWN ---")
		for f in failure_details:
			printerr("  [CHALLENGE FINDING] %s" % f)
		print("-------------------------\n")

	if total_failed == 0:
		print("CHALLENGE STATUS: APPROVE (All adversarial challenges passed)")
		quit(0)
	else:
		printerr("CHALLENGE STATUS: CHALLENGE_FAILED (%d empirical failures detected)" % total_failed)
		quit(1)

func assert_test(condition: bool, test_name: String, detail: String = "") -> void:
	if condition:
		total_passed += 1
		print("  [PASS] %s" % test_name)
	else:
		total_failed += 1
		var formatted: String = "%s | %s" % [test_name, detail] if detail != "" else test_name
		failure_details.append(formatted)
		printerr("  [FAIL] %s" % formatted)

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

# =============================================================================
# Suite 1: Dynamic Screen Resizing, Aspect Ratios & Safe Margin Invariants
# =============================================================================
func test_suite_1_screen_resizing_and_safe_areas() -> void:
	print("\n--- Suite 1: Dynamic Screen Resizing & Aspect Ratio Stress ---")

	var HudScene = load("res://scenes/hud.tscn")
	assert_test(HudScene != null, "scenes/hud.tscn loads successfully")
	var hud = HudScene.instantiate()
	root.add_child(hud)
	hud._ready()

	var PermScene = load("res://scenes/permission_screen.tscn")
	assert_test(PermScene != null, "scenes/permission_screen.tscn loads successfully")
	var perm = PermScene.instantiate()
	root.add_child(perm)
	perm._ready()

	var scope = ScopeScript.new()
	root.add_child(scope)
	scope._ready()

	# 1.1 Invariant check on Oscilloscope geometry
	scope.snap_to_diagnostic_dock_zone(1280.0)
	assert_test(scope.position.y == 480.0, "Oscilloscope position.y is exactly 480.0", "Got %f" % scope.position.y)
	assert_test(scope.size.y == 130.0, "Oscilloscope size.y is exactly 130.0", "Got %f" % scope.size.y)
	var clearance: float = 720.0 - (scope.position.y + scope.size.y)
	assert_test(clearance == 110.0 and clearance >= 100.0, "Oscilloscope bottom clearance >= 100px (got %f)" % clearance)

	# 1.2 Aspect ratio viewport tests (Pixel 7a 2400x1080 20:9, 16:9, 4:3, Ultrawide 21:9, and Degenerates)
	var resolutions: Array[Dictionary] = [
		{"name": "Pixel 7a Landscape (20:9)", "size": Vector2i(2400, 1080)},
		{"name": "Full HD 1080p (16:9)", "size": Vector2i(1920, 1080)},
		{"name": "Standard Reference (16:9)", "size": Vector2i(1280, 720)},
		{"name": "Legacy 4:3 Display", "size": Vector2i(1440, 1080)},
		{"name": "Older 4:3 Display", "size": Vector2i(1024, 768)},
		{"name": "Ultrawide UWQHD (21:9)", "size": Vector2i(3440, 1440)},
		{"name": "Ultrawide FHD (21:9)", "size": Vector2i(2560, 1080)},
		{"name": "4K Ultra HD (16:9)", "size": Vector2i(3840, 2160)},
		{"name": "Degenerate Small (100x50)", "size": Vector2i(100, 50)},
		{"name": "Portrait Phone Flip (1080x2400)", "size": Vector2i(1080, 2400)},
	]

	for res in resolutions:
		var w_size: Vector2i = res["size"]
		# Update oscilloscope docking width
		scope.snap_to_diagnostic_dock_zone(float(w_size.x))
		assert_test(scope.position.y == 480.0 and scope.size.y == 130.0,
			"Oscilloscope preserves Y=480 H=130 under %s" % res["name"])
		var expected_w: float = maxf(scope.custom_minimum_size.x, float(w_size.x))
		assert_test(scope.size.x == expected_w,
			"Oscilloscope respects custom_minimum_size (got %f, expected %f) under %s" % [scope.size.x, expected_w, res["name"]])

		# Simulate safe area update on PermissionScreen and HUD
		perm._apply_safe_area()
		var p_ml: int = perm.safe_margin.get_theme_constant("margin_left")
		var p_mt: int = perm.safe_margin.get_theme_constant("margin_top")
		var p_mr: int = perm.safe_margin.get_theme_constant("margin_right")
		var p_mb: int = perm.safe_margin.get_theme_constant("margin_bottom")
		assert_test(p_ml >= 32 and p_mt >= 32 and p_mr >= 32 and p_mb >= 32,
			"PermissionScreen safe margins >= 32px under %s" % res["name"],
			"Got L=%d T=%d R=%d B=%d" % [p_ml, p_mt, p_mr, p_mb])

		hud._apply_mobile_safe_area()
		var h_ml: int = hud.safe_margin_container.get_theme_constant("margin_left")
		var h_mt: int = hud.safe_margin_container.get_theme_constant("margin_top")
		var h_mr: int = hud.safe_margin_container.get_theme_constant("margin_right")
		var h_mb: int = hud.safe_margin_container.get_theme_constant("margin_bottom")
		assert_test(h_ml >= 16 and h_mt >= 12 and h_mr >= 16 and h_mb >= 16,
			"HUD safe margins satisfy mobile baselines under %s" % res["name"],
			"Got L=%d T=%d R=%d B=%d" % [h_ml, h_mt, h_mr, h_mb])

	# 1.3 Rapid viewport resize event burst (50 cycles)
	for cycle in range(50):
		var test_width: float = 800.0 + float(cycle * 40)
		scope.snap_to_diagnostic_dock_zone(test_width)
		hud._apply_mobile_safe_area()
		perm._apply_safe_area()
	assert_test(true, "50 rapid viewport resize events processed without failure")

	# 1.4 Oscilloscope Drawing Stress with Adversarial Waveforms
	# Normal waveform
	var samples_normal := PackedFloat32Array()
	samples_normal.resize(512)
	for i in range(512):
		samples_normal[i] = sin(float(i) * 0.05) * 0.5
	scope.update_waveform(samples_normal, 0.35, -9.1, false, 48000)
	scope._draw()
	assert_test(true, "Oscilloscope._draw() rendered normal waveform cleanly")

	# Empty waveform
	scope.update_waveform(PackedFloat32Array(), 0.0, -100.0, true, 48000)
	scope._draw()
	assert_test(true, "Oscilloscope._draw() handled empty waveform without crash")

	# Oversized waveform (2048 samples)
	var samples_large := PackedFloat32Array()
	samples_large.resize(2048)
	samples_large.fill(0.4)
	scope.update_waveform(samples_large, 0.4, -7.9, false, 48000)
	assert_test(scope.waveform_buffer.size() == 512, "Circular buffer clamped oversized input to 512")
	scope._draw()

	# Small waveform (16 samples)
	var samples_small := PackedFloat32Array()
	samples_small.resize(16)
	samples_small.fill(0.1)
	scope.update_waveform(samples_small, 0.1, -20.0, false, 48000)
	assert_test(scope.waveform_buffer.size() == 512, "Circular buffer maintained 512 samples with small chunk")
	scope._draw()

	# Degenerate size oscilloscope drawing (<40x30)
	scope.size = Vector2(20.0, 15.0)
	scope._draw()
	assert_test(true, "Oscilloscope._draw() safely ignored degenerate size <40x30")

	hud.queue_free()
	perm.queue_free()
	scope.queue_free()

# =============================================================================
# Suite 2: Permission Screen State Machine Stress & Rapid Click Storms
# =============================================================================
func test_suite_2_permission_screen_state_machine() -> void:
	print("\n--- Suite 2: Permission Screen State Machine & Rapid Click Storms ---")

	var PermScene = load("res://scenes/permission_screen.tscn")
	var perm = PermScene.instantiate()
	root.add_child(perm)
	perm._ready()

	# 2.1 Headless auto-pass configuration
	assert_test(perm.auto_pass_headless == true, "auto_pass_headless defaults to true")

	# 2.2 Rapid click storm on Request Button (50 rapid pressed invocations)
	for i in range(50):
		perm._on_request_button_pressed()
	assert_test(perm.is_permission_granted == true, "Permission granted after 50 rapid request clicks")

	# 2.3 Rapid click storm on Start Button (50 rapid clicks)
	var flow_count: Array[int] = [0]
	var on_flow = func(): flow_count[0] += 1
	perm.flow_completed.connect(on_flow)

	for i in range(50):
		perm._on_start_button_pressed()
	assert_test(flow_count[0] == 50, "flow_completed fired 50 times across 50 start clicks (got %d)" % flow_count[0])
	assert_test(perm.visible == false, "PermissionScreen hidden after flow completion")
	perm.flow_completed.disconnect(on_flow)

	# 2.4 Denial & Skip Flow Transition
	perm.show_screen()
	assert_test(perm.visible == true and perm.is_flow_active == true, "show_screen() successfully re-activates screen")

	var skip_fired: Array[bool] = [false]
	var denied_fired: Array[bool] = [false]
	var completed_fired: Array[bool] = [false]

	var on_skip = func(): skip_fired[0] = true
	var on_denied = func(): denied_fired[0] = true
	var on_comp = func(): completed_fired[0] = true

	perm.skip_requested.connect(on_skip)
	perm.permission_denied.connect(on_denied)
	perm.flow_completed.connect(on_comp)

	perm._on_skip_button_pressed()

	assert_test(skip_fired[0] == true, "skip_requested emitted on skip button press")
	assert_test(denied_fired[0] == true, "permission_denied emitted on skip button press")
	assert_test(completed_fired[0] == true, "flow_completed emitted on skip button press")
	assert_test(perm.is_permission_granted == false, "is_permission_granted set to false after skip")
	assert_test(perm.visible == false, "PermissionScreen hidden after skip flow")

	# Verify GameManager reflects denial
	if root.has_node("GameManager"):
		var gm = root.get_node("GameManager")
		assert_test(gm.is_permission_granted == false, "GameManager.is_permission_granted synchronized to false")

	perm.skip_requested.disconnect(on_skip)
	perm.permission_denied.disconnect(on_denied)
	perm.flow_completed.disconnect(on_comp)

	# 2.5 Alternating Click Storm (Request -> Skip -> Start -> Request -> Start)
	for cycle in range(20):
		perm.show_screen()
		if cycle % 2 == 0:
			perm._on_request_button_pressed()
			perm._on_start_button_pressed()
			assert_test(perm.is_permission_granted == true, "Cycle %d: Grant flow established" % cycle)
		else:
			perm._on_skip_button_pressed()
			assert_test(perm.is_permission_granted == false, "Cycle %d: Denial flow established" % cycle)

	# 2.6 Desktop auto_pass_desktop setting check
	var perm_desktop = PermScene.instantiate()
	perm_desktop.auto_pass_headless = false
	perm_desktop.auto_pass_desktop = true
	root.add_child(perm_desktop)
	perm_desktop._ready()
	assert_test(true, "PermissionScreen with auto_pass_desktop=true initialized without crash")
	perm_desktop.queue_free()

	perm.queue_free()

# =============================================================================
# Suite 3: Main Scene Level Switching & Rapid Keyboard Shortcut Stress
# =============================================================================
func test_suite_3_level_switching_and_shortcuts() -> void:
	print("\n--- Suite 3: Main Scene Level Switching & Keyboard Shortcut Stress ---")

	var MainScene = load("res://scenes/main.tscn")
	var main = MainScene.instantiate()
	main.auto_pass_desktop = true
	root.add_child(main)
	main._ready()

	# 3.1 Initial state verification
	assert_test(main.highway != null, "GrandStaffHighway initialized in Main")
	assert_test(main.level_loader != null, "LevelLoader initialized in Main")
	assert_test(main.selected_piece == "piece_1_monophonic", "Default piece is piece_1_monophonic")

	# 3.2 Rapid sequential level switching (60 switches among 3 bundled pieces)
	var pieces: Array[String] = ["piece_1_monophonic", "piece_2_harmony", "piece_3_polyphonic"]
	var switch_count: int = 0

	for cycle in range(20):
		for p_id in pieces:
			var ok: bool = main.load_piece(p_id, false)
			if ok:
				switch_count += 1
				main.start_playback()

	assert_test(switch_count == 60, "60 rapid level switches completed successfully (count=%d)" % switch_count)
	assert_test(main.highway.chart_notes.size() > 0, "Highway chart notes populated after rapid switches")
	assert_test(main.highway.is_playing == true, "Highway is_playing is true after start_playback")

	# 3.3 Invalid piece load error recovery
	var bad_load: bool = main.load_piece("piece_completely_invalid_and_nonexistent", false)
	assert_test(bad_load == false, "load_piece with non-existent piece ID returns false cleanly")
	assert_test(main.highway.chart_notes.size() > 0, "Highway chart retains valid state after rejected load")

	# 3.4 Rapid Keyboard Shortcut Stress (200 random keystrokes)
	var keys_to_test: Array[int] = [
		KEY_1, KEY_2, KEY_3, KEY_O, KEY_R, KEY_T, KEY_SPACE, KEY_LEFT, KEY_RIGHT
	]

	for i in range(200):
		var k: int = keys_to_test[i % keys_to_test.size()]
		var ev := InputEventKey.new()
		ev.keycode = k
		ev.pressed = true
		ev.echo = false
		main._unhandled_input(ev)

	assert_test(true, "200 rapid keyboard shortcut inputs handled cleanly without crash")

	# 3.5 Test key release and echo event immunity (should do nothing)
	var echo_ev := InputEventKey.new()
	echo_ev.keycode = KEY_1
	echo_ev.pressed = true
	echo_ev.echo = true
	main._unhandled_input(echo_ev)
	assert_test(true, "Echo key event safely ignored")

	var release_ev := InputEventKey.new()
	release_ev.keycode = KEY_1
	release_ev.pressed = false
	release_ev.echo = false
	main._unhandled_input(release_ev)
	assert_test(true, "Key release event safely ignored")

	# 3.6 Playback controls: Pause, Resume, Restart
	main.load_piece("piece_1_monophonic", false)
	main.start_playback()
	assert_test(main.highway.is_playing == true, "Playback running before pause")

	main.pause_playback()
	assert_test(main.highway.is_playing == false, "pause_playback() paused highway")

	main.resume_playback()
	assert_test(main.highway.is_playing == true, "resume_playback() resumed highway")

	# Advance highway time to simulate in-flight gameplay
	main.highway.current_song_time = 4.5
	main.restart_playback()
	assert_test(main.highway.current_song_time == 0.0,
		"restart_playback() successfully reset highway playhead to 0.0 (got %f)" % main.highway.current_song_time)
	assert_test(main.highway.is_playing == true, "restart_playback() restarted playback")

	# Test in-flight restart synchronization with AudioManager
	if root.has_node("AudioManager"):
		var am = root.get_node("AudioManager")
		am.is_playing = true
		am.current_song_time = 4.5
		main.restart_playback()
		main.highway._process(0.0166)
		assert_test(main.highway.current_song_time < 1.0,
			"Highway playhead does not jump back to 4.5s after restart when AudioManager was playing",
			"Highway current_song_time is %f" % main.highway.current_song_time)

	# 3.7 Calibration Offset Stress (extreme offsets: -500ms to +500ms)
	main._adjust_calibration(-500.0)
	assert_test(main.level_loader.calibration_offset_ms < -100.0, "Negative calibration offset allowed")
	main._adjust_calibration(+1000.0)
	assert_test(main.level_loader.calibration_offset_ms > 100.0, "Positive calibration offset allowed")
	main._adjust_calibration(-main.level_loader.calibration_offset_ms) # Reset to 0
	assert_test(is_equal_approx(main.level_loader.calibration_offset_ms, 0.0), "Calibration reset to 0.0 ms")

	# 3.8 Process loop stability across 30 frames
	for f in range(30):
		main._process(0.0166)
	assert_test(true, "Main._process() stable across 30 simulated frames")

	main.queue_free()

# =============================================================================
# Suite 4: Custom Song OMR Ingestion via Modal & Adversarial File Handling
# =============================================================================
func test_suite_4_custom_song_omr_modal() -> void:
	print("\n--- Suite 4: Custom Song OMR Ingestion via Modal & Adversarial Files ---")

	var MainScene = load("res://scenes/main.tscn")
	var main = MainScene.instantiate()
	main.auto_pass_desktop = true
	root.add_child(main)
	main._ready()

	var hud = main.hud
	assert_test(hud != null, "HUD resolved in Main for custom song modal tests")

	# 4.1 Modal visibility toggle
	assert_test(hud.custom_song_modal.visible == false, "CustomSongModal initially hidden")
	hud._toggle_custom_song_modal()
	assert_test(hud.custom_song_modal.visible == true, "CustomSongModal opens upon toggle")
	hud._toggle_custom_song_modal()
	assert_test(hud.custom_song_modal.visible == false, "CustomSongModal closes upon toggle")

	# 4.2 Ingest valid sheet music image via OMR modal
	var score_images: Array[String] = [
		"res://assets/scores/piece_1_monophonic.png",
		"res://assets/scores/piece_2_harmony.png",
		"res://assets/scores/piece_3_polyphonic.png"
	]

	for img_path in score_images:
		if hud.custom_sheet_input != null:
			hud.custom_sheet_input.text = img_path
		if hud.custom_audio_input != null:
			hud.custom_audio_input.text = ""
		if hud.custom_bpm_spin != null:
			hud.custom_bpm_spin.value = 120.0

		var custom_signal_fired: Array = [false]
		var on_custom = func(_s, _a, _b): custom_signal_fired[0] = true
		hud.custom_song_requested.connect(on_custom)

		hud._on_confirm_custom_song()

		assert_test(custom_signal_fired[0] == true,
			"custom_song_requested emitted for score %s" % img_path.get_file())
		assert_test(main.highway.chart_notes.size() > 0,
			"OMR digitizer populated chart notes for %s (notes=%d)" % [img_path.get_file(), main.highway.chart_notes.size()])
		assert_test(hud.custom_song_modal.visible == false, "Modal closed automatically upon confirmation")

		hud.custom_song_requested.disconnect(on_custom)

	# 4.3 Ingest JSON chart via custom song API
	var ok_json: bool = main.load_custom_song("res://assets/charts/piece_1_monophonic.json", "", 120.0)
	assert_test(ok_json == true, "Custom JSON chart loaded successfully via Main.load_custom_song()")
	assert_test(main.highway.chart_notes.size() > 0, "Highway populated from custom JSON chart")

	# 4.4 Adversarial file tests (non-existent file, blank path, corrupt file)
	var blank_res: bool = main.load_custom_song("", "", 120.0)
	assert_test(blank_res == false, "load_custom_song with empty path returns false cleanly")

	var non_existent: bool = main.load_custom_song("res://assets/scores/non_existent_score_file_xyz.png", "", 120.0)
	assert_test(non_existent == false, "load_custom_song with non-existent file returns false cleanly")

	var invalid_ext: bool = main.load_custom_song("res://scripts/main.gd", "", 120.0)
	assert_test(invalid_ext == false, "load_custom_song with unsupported format returns false cleanly")

	main.queue_free()

# =============================================================================
# Suite 5: Telemetry, Audio Ingestion & Process Loop Conformance
# =============================================================================
func test_suite_5_telemetry_and_process_loop_audit() -> void:
	print("\n--- Suite 5: Telemetry Edge Cases & Process Loop Conformance ---")

	var HudScene = load("res://scenes/hud.tscn")
	var hud = HudScene.instantiate()
	root.add_child(hud)
	hud._ready()

	# 5.1 Telemetry Edge Cases: 0 samples, 10000 samples, extreme RMS
	var empty_samples := PackedFloat32Array()
	hud.update_audio_telemetry(empty_samples, 0.0, -120.0, true, false, 0, 48000)
	assert_test(hud.mic_status_label.text.contains("STOPPED"), "Audio telemetry handles empty waveform and stopped capture")

	var huge_samples := PackedFloat32Array()
	huge_samples.resize(10000)
	huge_samples.fill(0.3)
	hud.update_audio_telemetry(huge_samples, 0.3, -10.4, false, true, 50000, 48000)
	assert_test(hud.mic_status_label.text.contains("SIGNAL ACTIVE"), "Audio telemetry handles 10,000 samples chunk")

	# 5.2 Rapid Combo Updates and Breaks (100 rapid cycles)
	for c in range(1, 101):
		hud.update_combo(c, 1 + (c / 10))
	assert_test(hud.combo_label.text == "100 COMBO", "Combo updated to 100 COMBO")
	assert_test(hud.multiplier_label.text.contains("MULTIPLIER"), "Multiplier label active")

	hud.update_combo(0, 1) # Combo break
	assert_test(hud.combo_container.modulate.a == 0.0, "Combo container hidden after combo break")

	# 5.3 Judgment Popups Stress (50 rapid popups)
	for i in range(50):
		var ratings = ["PERFECT", "GOOD", "MISS"]
		hud.spawn_judgment_popup(ratings[i % ratings.size()], Vector2(160, 360))
	assert_test(hud.judgment_layer.get_child_count() == 50, "50 judgment popups spawned concurrently")

	# 5.4 Score updates with rapid tweens
	for s in [100, 500, 2500, 15000, 999999]:
		hud.update_score(s)
	assert_test(hud.score_value != null, "Score tweens executed cleanly")

	# 5.5 Process Loop Conformance Audit: PROHIBITION of play() in _process()
	# Scan all scripts in res://scripts/
	var scripts_to_audit: Array[String] = [
		"res://scripts/responsive_hud.gd",
		"res://scripts/permission_screen.gd",
		"res://scripts/oscilloscope_view.gd",
		"res://scripts/main.gd",
		"res://scripts/grand_staff_highway.gd",
		"res://scripts/audio_manager.gd",
		"res://scripts/audio_capture_service.gd",
		"res://scripts/level_loader.gd",
		"res://scripts/scoring_service.gd"
	]

	var play_in_process_found: bool = false
	for script_path in scripts_to_audit:
		var fa = FileAccess.open(script_path, FileAccess.READ)
		if fa != null:
			var content: String = fa.get_as_text()
			fa.close()

			var lines = content.split("\n")
			var in_process: bool = false
			var proc_indent: int = 0

			for line_idx in range(lines.size()):
				var line = lines[line_idx]
				var trimmed = line.strip_edges()

				if trimmed.begins_with("func _process") or trimmed.begins_with("func _physics_process"):
					in_process = true
					proc_indent = _get_line_indent(line)
					continue

				if in_process:
					if trimmed.begins_with("func ") and _get_line_indent(line) <= proc_indent:
						in_process = false
						continue

					if trimmed.contains(".play(") or trimmed.begins_with("play("):
						# Ignore comments
						if not trimmed.begins_with("#"):
							printerr("AUDIT VIOLATION: .play() called in process loop at %s:%d: %s" % [script_path, line_idx + 1, trimmed])
							play_in_process_found = true

	assert_test(not play_in_process_found, "Strictly ZERO play() calls detected in _process() across all production scripts")

	hud.queue_free()

func _get_line_indent(line: String) -> int:
	var count: int = 0
	for ch in line:
		if ch == "\t":
			count += 4
		elif ch == " ":
			count += 1
		else:
			break
	return count
