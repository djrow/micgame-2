extends SceneTree

# =============================================================================
# test_m4_iter2_challenger_deep_probe.gd
# M4 Iteration 2 Challenger Deep Empirical Probe:
# Highway Seek Robustness, Note Rendering, Hit Detection, Combo Tracking & Telemetry
# =============================================================================

var total_passed: int = 0
var total_failed: int = 0
var failure_log: Array[String] = []

func assert_test(condition: bool, test_name: String, details: String = "") -> void:
	if condition:
		total_passed += 1
		print("  [PASS] %s" % test_name)
	else:
		total_failed += 1
		var msg = "  [FAIL] %s" % test_name
		if not details.is_empty():
			msg += " | %s" % details
		print(msg)
		failure_log.append(test_name + (" | " + details if not details.is_empty() else ""))

func _init() -> void:
	call_deferred("start")

func start() -> void:
	print("==================================================================")
	print(" STARTING M4 ITERATION 2 CHALLENGER DEEP EMPIRICAL PROBE")
	print("==================================================================")
	_setup_autoloads()
	run_all_probe_suites()
	print("==================================================================")
	print(" PROBE RESULTS: %d Passed, %d Failed" % [total_passed, total_failed])
	print("==================================================================")

	if total_failed == 0:
		print("CHALLENGE STATUS: APPROVE (All empirical challenger probes passed)")
		quit(0)
	else:
		print("CHALLENGE STATUS: CHALLENGE_FAILED (%d empirical failures detected)" % total_failed)
		for f in failure_log:
			print("  - %s" % f)
		quit(1)

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

func run_all_probe_suites() -> void:
	test_suite_1_seek_edge_cases()
	test_suite_2_note_rendering_active_notes_after_seek()
	test_suite_3_hit_detection_after_seek()
	test_suite_4_combo_and_score_invariants()
	test_suite_5_resume_playback_continuity()
	test_suite_6_telemetry_under_rapid_scrub_storm()
	test_suite_7_audio_player_branch_calibration_offsets()

# --- Suite 1: Seek Edge Cases on GrandStaffHighway ---
func test_suite_1_seek_edge_cases() -> void:
	print("\n--- Suite 1: Seek Edge Cases on GrandStaffHighway ---")
	var highway_scene = load("res://scenes/highway.tscn")
	assert_test(highway_scene != null, "highway.tscn loaded")
	var highway = highway_scene.instantiate()
	root.add_child(highway)

	# Create test notes
	var notes: Array[Dictionary] = [
		{"pitch_midi": 60, "time_sec": 1.0, "duration_sec": 0.5},
		{"pitch_midi": 64, "time_sec": 2.0, "duration_sec": 0.5},
		{"pitch_midi": 67, "time_sec": 3.0, "duration_sec": 0.5},
		{"pitch_midi": 72, "time_sec": 5.0, "duration_sec": 0.5},
	]
	highway.load_chart_dict({"notes": notes})
	highway.start_playback()

	# 1. Negative seek should clamp to 0.0
	highway.seek(-10.0)
	assert_test(highway.current_song_time == 0.0, "Negative seek(-10.0) clamps to 0.0", "Got %f" % highway.current_song_time)
	assert_test(highway.last_playback_pos == 0.0, "last_playback_pos clamped to 0.0 after negative seek")

	highway.seek(-0.0001)
	assert_test(highway.current_song_time == 0.0, "Negative seek(-0.0001) clamps to 0.0")

	# 2. Seek beyond chart end
	highway.seek(999.0)
	assert_test(highway.current_song_time == 999.0, "Seek beyond chart end sets current_song_time to 999.0")
	highway._process(0.0166)
	assert_test(highway.active_notes.is_empty(), "No active notes spawned when seeking far past chart end")

	# 3. Seek to exact note onset
	highway.seek(2.0)
	assert_test(highway.current_song_time == 2.0, "Seek to exact note timestamp sets 2.0s")
	highway._process(0.0166)
	assert_test(not highway.active_notes.is_empty(), "Active notes populated when seeking to note onset")

	# 4. Rapid repeated seek to same timestamp
	for i in range(20):
		highway.seek(1.5)
	assert_test(highway.current_song_time == 1.5, "20 repeated seeks to 1.5s remain at 1.5s")
	highway._process(0.0166)
	assert_test(highway.current_song_time >= 1.5, "Playhead advances normally after repeated seek")

	highway.queue_free()

# --- Suite 2: Note Rendering & Active Notes Integrity After Seek ---
func test_suite_2_note_rendering_active_notes_after_seek() -> void:
	print("\n--- Suite 2: Note Rendering & Active Notes Integrity After Seek ---")
	var highway_scene = load("res://scenes/highway.tscn")
	var highway = highway_scene.instantiate()
	root.add_child(highway)

	# Create a dense sequence of notes including harmonic seconds
	var notes: Array[Dictionary] = [
		{"pitch_midi": 60, "time_sec": 1.0, "duration_sec": 0.5},
		{"pitch_midi": 62, "time_sec": 1.0, "duration_sec": 0.5}, # Harmonic second (C4 + D4)
		{"pitch_midi": 64, "time_sec": 2.0, "duration_sec": 0.5},
		{"pitch_midi": 65, "time_sec": 2.0, "duration_sec": 0.5}, # Harmonic second (E4 + F4)
		{"pitch_midi": 67, "time_sec": 3.0, "duration_sec": 0.5},
		{"pitch_midi": 72, "time_sec": 4.0, "duration_sec": 0.5},
	]
	highway.load_chart_dict({"notes": notes})
	highway.start_playback()

	# Verify chord offsets initialized (+16px for harmonic seconds)
	assert_test(highway.chart_notes[0].chord_offset_x == 0.0, "Chord note 1 offset is 0.0")
	assert_test(highway.chart_notes[1].chord_offset_x == 16.0, "Chord note 2 (harmonic second) offset is 16.0")
	assert_test(highway.chart_notes[2].chord_offset_x == 0.0, "Chord note 3 offset is 0.0")
	assert_test(highway.chart_notes[3].chord_offset_x == 16.0, "Chord note 4 (harmonic second) offset is 16.0")

	# Play past 2.5s
	highway.current_song_time = 2.5
	highway._process(0.0166)

	# Verify notes 1.0s and 2.0s are either hit or passed
	# Seek forward to 3.5s
	highway.seek(3.5)
	highway._process(0.0166)

	# Active notes should now only contain notes around/after 3.5s
	for an in highway.active_notes:
		var tail_time = an.time_sec + an.duration_sec
		assert_test(tail_time >= 3.0, "Active note after seek(3.5) is relevant to playhead", "Got note at %f" % an.time_sec)

	# Seek backward to 0.5s
	highway.seek(0.5)
	highway._process(0.0166)

	# All notes from 1.0s to 4.0s should be spawnable again
	var found_first_note: bool = false
	for an in highway.active_notes:
		if an.time_sec == 1.0 and an.pitch_midi == 60:
			found_first_note = true
			break
	assert_test(found_first_note, "First note re-spawned into active_notes after backward seek to 0.5s")

	# Chord offsets must be intact after seek
	assert_test(highway.chart_notes[1].chord_offset_x == 16.0, "Harmonic second offset preserved after multiple seeks")

	highway.queue_free()

# --- Suite 3: Hit Detection & Chord Matching After Seek ---
func test_suite_3_hit_detection_after_seek() -> void:
	print("\n--- Suite 3: Hit Detection & Chord Matching After Seek ---")
	var main_scene = load("res://scenes/main.tscn")
	assert_test(main_scene != null, "main.tscn loaded")
	var main = main_scene.instantiate()
	root.add_child(main)
	main._ready()

	var am = root.get_node_or_null("AudioManager")
	var ss = root.get_node_or_null("ScoringService")
	assert_test(ss != null, "ScoringService resolved in root")

	main.load_piece("piece_1_monophonic", false)
	main.start_playback()

	# Seek to near note 1 (which is at 0.0s or near start)
	main.highway.seek(0.0)
	main.highway._process(0.0166)

	var active_notes = main.highway.active_notes
	assert_test(not active_notes.is_empty(), "Active notes available near start")

	var target_note = active_notes[0]
	var target_pitch = target_note.pitch_midi
	var target_time = target_note.time_sec

	# Simulate hit on target note
	var hit_res = ss.process_input(target_time, target_pitch, main.highway.active_notes, 0)
	assert_test(not hit_res.is_empty(), "Hit successfully scored for target note at %f" % target_time)
	assert_test(target_note.is_hit == true, "target_note.is_hit is true after hit")

	# Advance highway past note
	main.highway.current_song_time = target_time + 1.0
	main.highway._process(0.0166)

	# Now seek backward to 0.0s
	main.highway.seek(0.0)
	main.highway._process(0.0166)

	# Note must have is_hit reset to false
	assert_test(target_note.is_hit == false, "target_note.is_hit reset to false after seek backward")

	# Re-hit the note after seek
	var rehit_res = ss.process_input(target_time, target_pitch, main.highway.active_notes, 0)
	assert_test(not rehit_res.is_empty(), "Target note successfully re-hit after seek backward")
	assert_test(target_note.is_hit == true, "target_note.is_hit is true again after re-hit")

	main.queue_free()

# --- Suite 4: Combo & Score Invariants Across Highway & ScoringService Lifecycle ---
func test_suite_4_combo_and_score_invariants() -> void:
	print("\n--- Suite 4: Combo & Score Invariants Across Highway & ScoringService Lifecycle ---")
	var ss = root.get_node_or_null("ScoringService")
	assert_test(ss != null, "ScoringService available")

	ss.reset_score()
	assert_test(ss.total_score == 0, "Score starts at 0")
	assert_test(ss.current_combo == 0, "Combo starts at 0")

	# Build a mock chart of 10 notes
	var mock_notes: Array[NoteData] = []
	for i in range(10):
		var nd = NoteData.new(60 + (i % 5), 1.0 + (i * 0.5), 0.3, i + 1)
		mock_notes.append(nd)

	# Score 5 consecutive perfect hits
	for i in range(5):
		var res = ss.process_input(mock_notes[i].time_sec, mock_notes[i].pitch_midi, mock_notes, 0)
		assert_test(not res.is_empty(), "Note %d hit scored" % i)

	assert_test(ss.current_combo == 5, "Combo reaches 5 after 5 hits", "Got %d" % ss.current_combo)
	assert_test(ss.total_score == 500, "Score reaches 500 after 5 hits", "Got %d" % ss.total_score)

	# Trigger miss on note 5
	ss.register_miss(mock_notes[5])
	assert_test(ss.current_combo == 0, "Combo resets to 0 upon MISS")
	assert_test(ss.max_combo == 5, "Max combo preserved at 5")
	assert_test(ss.total_score == 500, "Score preserved at 500 after MISS")

	# Restart / Reset
	ss.reset_score()
	assert_test(ss.total_score == 0, "Score reset to 0 after reset_score()")
	assert_test(ss.current_combo == 0, "Combo reset to 0 after reset_score()")
	assert_test(ss.max_combo == 0, "Max combo reset to 0 after reset_score()")

# --- Suite 5: Resume Playback Continuity & Pause/Play State Machine ---
func test_suite_5_resume_playback_continuity() -> void:
	print("\n--- Suite 5: Resume Playback Continuity & Pause/Play State Machine ---")
	var main_scene = load("res://scenes/main.tscn")
	var main = main_scene.instantiate()
	root.add_child(main)
	main._ready()

	var am = root.get_node_or_null("AudioManager")
	main.load_piece("piece_1_monophonic", false)
	main.start_playback()

	# Let time advance to 3.75s
	am.is_playing = true
	am.current_song_time = 3.75
	main.highway.current_song_time = 3.75

	# Pause
	main.pause_playback()
	assert_test(main.highway.is_playing == false, "Highway paused")
	assert_test(am.is_paused == true, "AudioManager paused")

	# Ensure playhead did not reset during pause
	assert_test(absf(main.highway.current_song_time - 3.75) < 0.001,
		"Highway playhead retained at 3.75s during pause",
		"Got %f" % main.highway.current_song_time)

	# Resume
	main.resume_playback()
	assert_test(main.highway.is_playing == true, "Highway resumed")
	assert_test(am.is_paused == false, "AudioManager unpaused")
	assert_test(main.highway.current_song_time >= 3.75,
		"Highway playhead did not jump to 0.0s upon resume_playback()",
		"Got %f" % main.highway.current_song_time)

	# Simulate several frames of playback after resume
	for k in range(5):
		am.current_song_time += 0.0166
		main.highway._process(0.0166)

	assert_test(main.highway.current_song_time > 3.80,
		"Highway playhead advances smoothly after resume",
		"Got %f" % main.highway.current_song_time)

	main.queue_free()

# --- Suite 6: Telemetry & Oscilloscope Stability During Scrubbing & High-Frequency Seek Storm ---
func test_suite_6_telemetry_under_rapid_scrub_storm() -> void:
	print("\n--- Suite 6: Telemetry & Oscilloscope Stability During Scrubbing & Rapid Seeks ---")
	var hud_scene = load("res://scenes/hud.tscn")
	assert_test(hud_scene != null, "hud.tscn loaded")
	var hud = hud_scene.instantiate()
	root.add_child(hud)
	hud._ready()

	var osc = hud.oscilloscope_view
	assert_test(osc != null, "OscilloscopeView resolved in HUD")

	var am = root.get_node_or_null("AudioManager")

	# Concurrently push 200 seek events and 200 audio waveform updates
	var waveform_chunk = PackedFloat32Array()
	waveform_chunk.resize(512)
	for i in range(512):
		waveform_chunk[i] = sin(float(i) * 0.1) * 0.5

	var all_stable: bool = true
	for i in range(200):
		var scrub_time: float = float(i % 30) * 0.5
		hud._seek_to_mouse_pos(float(i % 100))
		hud._on_audio_capture_waveform(waveform_chunk, 0.35, -9.1, false)
		hud._process(0.0166)

		if is_nan(osc.current_rms) or is_inf(osc.current_rms) or osc.waveform_buffer.size() != 512:
			all_stable = false
			break

	assert_test(all_stable, "OscilloscopeView and HUD remained stable across 200 rapid scrub + telemetry updates")
	assert_test(osc.waveform_buffer.size() == 512, "Circular buffer strictly kept 512 samples")

	hud.queue_free()

# --- Suite 7: Audio Player Standalone Branch vs Calibration Offsets ---
func test_suite_7_audio_player_branch_calibration_offsets() -> void:
	print("\n--- Suite 7: Audio Player Standalone Branch vs Calibration Offsets ---")
	var highway_scene = load("res://scenes/highway.tscn")
	var highway = highway_scene.instantiate()
	root.add_child(highway)

	# Test fallback clock behavior when no audio player or AudioManager playing
	var initial_time = highway.current_song_time
	highway.is_playing = true
	highway._process(0.05)
	assert_test(highway.current_song_time >= initial_time + 0.049,
		"Fallback clock advances cleanly by delta when audio is inactive")

	# Test seek with audio_offset_sec variations on GrandStaffHighway
	var offsets: Array[float] = [-0.100, -0.050, 0.0, 0.025, 0.100, 0.250]
	for off in offsets:
		highway.audio_offset_sec = off
		highway.seek(2.0)
		assert_test(highway.current_song_time == 2.0, "Seek to 2.0s with audio_offset_sec = %.3f works" % off)
		highway._process(0.0166)
		assert_test(highway.current_song_time >= 2.0, "Highway playhead moves forward with audio_offset_sec = %.3f" % off)

	highway.queue_free()
