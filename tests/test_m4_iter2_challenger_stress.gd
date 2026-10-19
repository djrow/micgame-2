extends SceneTree

# =============================================================================
# test_m4_iter2_challenger_stress.gd
# Deep Empirical Adversarial Stress Test for M4 Iteration 2:
# In-Flight Playback Restart Synchronization & Rapid Level Switching
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
	print(" STARTING M4 ITERATION 2 DEEP ADVERSARIAL STRESS RUNNER")
	print("==================================================================")
	_setup_autoloads()
	run_all_stress_tests()
	print("==================================================================")
	print(" STRESS RESULTS: %d Passed, %d Failed" % [total_passed, total_failed])
	print("==================================================================")

	if total_failed == 0:
		print("CHALLENGE STATUS: APPROVE (All in-flight restart stress tests passed)")
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


func run_all_stress_tests() -> void:
	test_stress_in_flight_restart_various_timestamps()
	test_stress_rapid_restart_storm()
	test_stress_level_switching_during_in_flight_playback()
	test_stress_note_rescoring_after_in_flight_restart()
	test_stress_audio_manager_signal_coupling()

func test_stress_in_flight_restart_various_timestamps() -> void:
	print("\n--- Stress 1: In-Flight Restart Across Spectrum of Timestamps ---")
	var main_scene = load("res://scenes/main.tscn")
	assert_test(main_scene != null, "main.tscn loaded")
	var main = main_scene.instantiate()
	root.add_child(main)
	main._ready()

	var am = root.get_node_or_null("AudioManager")
	assert_test(am != null, "AudioManager resolved in root")

	# Test across various timestamps: boundary, sub-second, mid-song, long playback
	var test_timestamps: Array[float] = [0.005, 0.05, 0.25, 0.49, 0.50, 0.51, 1.0, 3.2, 7.85, 25.0, 120.0]

	for target_t in test_timestamps:
		main.load_piece("piece_1_monophonic", false)
		main.start_playback()

		# Simulate audio manager running at target timestamp
		am.is_playing = true
		am.current_song_time = target_t
		am._last_playback_pos = target_t
		main.highway.current_song_time = target_t
		main.highway.last_playback_pos = target_t

		# Execute restart
		main.restart_playback()

		# Process one frame of highway and main
		main.highway._process(0.0166)
		main._process(0.0166)

		# The highway playhead should remain at or very close to start (<= 0.05s)
		assert_test(main.highway.current_song_time <= 0.05,
			"Restart at t=%.3fs resets playhead to start" % target_t,
			"Got highway.current_song_time = %f" % main.highway.current_song_time)
		assert_test(am.current_song_time <= 0.05,
			"Restart at t=%.3fs resets AudioManager to start" % target_t,
			"Got am.current_song_time = %f" % am.current_song_time)

	main.queue_free()

func test_stress_rapid_restart_storm() -> void:
	print("\n--- Stress 2: Rapid Restart Storm (50 consecutive restarts under active audio) ---")
	var main_scene = load("res://scenes/main.tscn")
	var main = main_scene.instantiate()
	root.add_child(main)
	main._ready()
	var am = root.get_node_or_null("AudioManager")

	main.load_piece("piece_2_harmony", false)
	main.start_playback()

	var all_resets_valid: bool = true
	for i in range(50):
		# Jitter audio manager time between 0.1s and 10.0s
		var sim_time: float = 0.1 + (i * 0.19)
		am.is_playing = true
		am.current_song_time = sim_time
		main.restart_playback()
		main.highway._process(0.0166)
		if main.highway.current_song_time > 0.05 or am.current_song_time > 0.05:
			all_resets_valid = false
			break

	assert_test(all_resets_valid, "50 rapid restarts under varying in-flight audio times maintained clock at 0.0s")
	assert_test(main.highway.is_playing == true, "Highway remains in playing state after restart storm")
	main.queue_free()

func test_stress_level_switching_during_in_flight_playback() -> void:
	print("\n--- Stress 3: Level Switching During In-Flight Playback ---")
	var main_scene = load("res://scenes/main.tscn")
	var main = main_scene.instantiate()
	root.add_child(main)
	main._ready()
	var am = root.get_node_or_null("AudioManager")

	var pieces = ["piece_1_monophonic", "piece_2_harmony", "piece_3_polyphonic"]

	for i in range(15):
		var p = pieces[i % pieces.size()]
		am.is_playing = true
		am.current_song_time = 3.5 + (i * 0.5)

		var ok = main.load_piece(p, false)
		assert_test(ok, "Loaded piece %s while playback in-flight at %.1fs" % [p, am.current_song_time])
		main.start_playback()
		main.highway._process(0.0166)

		assert_test(main.highway.current_song_time <= 0.05,
			"Highway playhead at 0.0s after level switch to %s" % p,
			"Got %f" % main.highway.current_song_time)
		assert_test(am.current_song_time <= 0.05,
			"AudioManager playhead at 0.0s after level switch to %s" % p,
			"Got %f" % am.current_song_time)

	main.queue_free()

func test_stress_note_rescoring_after_in_flight_restart() -> void:
	print("\n--- Stress 4: Note Re-scoring and State Cleared After In-Flight Restart ---")
	var main_scene = load("res://scenes/main.tscn")
	var main = main_scene.instantiate()
	root.add_child(main)
	main._ready()
	var am = root.get_node_or_null("AudioManager")
	var ss = root.get_node_or_null("ScoringService")

	main.load_piece("piece_1_monophonic", false)
	main.start_playback()

	# Manually mark first note as hit
	if not main.highway.chart_notes.is_empty():
		var first_note = main.highway.chart_notes[0]
		first_note.is_hit = true
		first_note.hit_rating = "PERFECT"
		first_note.hit_score = 100
		first_note.rating = "PERFECT"
		first_note.score_awarded = 100
		first_note.points = 100

	# Advance time past note
	am.is_playing = true
	am.current_song_time = 2.0
	main.highway.current_song_time = 2.0

	# Now restart
	main.restart_playback()
	main.highway._process(0.0166)

	# Verify notes in chart were reset
	var all_cleared: bool = true
	for note in main.highway.chart_notes:
		if note.is_hit or note.is_missed:
			all_cleared = false
			break
	assert_test(all_cleared, "All chart notes hit/missed flags cleared after in-flight restart")

	main.queue_free()

func test_stress_audio_manager_signal_coupling() -> void:
	print("\n--- Stress 5: AudioManager playhead_seeked Signal Coupling ---")
	var highway_scene = load("res://scenes/highway.tscn")
	assert_test(highway_scene != null, "highway.tscn loaded")
	var highway = highway_scene.instantiate()
	root.add_child(highway)
	highway._ready()

	var am = root.get_node_or_null("AudioManager")
	if am:
		highway.start_playback()
		highway.current_song_time = 5.0

		# Directly emit seek on AudioManager
		am.seek(0.0)
		assert_test(highway.current_song_time == 0.0,
			"GrandStaffHighway playhead rewound to 0.0 upon AudioManager.seek(0.0)")

		# Seek forward
		am.seek(2.5)
		assert_test(highway.current_song_time == 2.5,
			"GrandStaffHighway playhead advanced to 2.5 upon AudioManager.seek(2.5)")

	highway.queue_free()
