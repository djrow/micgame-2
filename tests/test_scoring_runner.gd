# res://tests/test_scoring_runner.gd
extends SceneTree

const ScoringServiceScript = preload("res://scripts/scoring_service.gd")
const NoteDataScript = preload("res://scripts/note_data.gd")
const GrandStaffHighwayScript = preload("res://scripts/grand_staff_highway.gd")
const LevelLoaderScript = preload("res://scripts/level_loader.gd")
const OMRProcessorScript = preload("res://scripts/omr_processor.gd")

var tests_passed: int = 0
var tests_failed: int = 0

func _init() -> void:
	print("==================================================")
	print(" RUNNING M3 FULL ENGINE HEADLESS VERIFICATION     ")
	print("==================================================")

	# Scoring Service Suites
	test_timing_windows()
	test_scoring_formulas_and_multipliers()
	test_float_scaled_multipliers()
	test_combo_streak_reset()
	test_polyphonic_chord_matching()
	test_partial_chords_and_note_expiration()
	test_sustain_retrigger_filtering()
	test_accuracy_calculation()
	test_adversarial_dirty_inputs_and_bounds()

	# Note Data & Diatonic Math Suites
	test_note_data_and_diatonic_math()
	test_harmonic_second_offset_algorithm()

	# Highway & Scene Lifecycle Suites
	test_highway_scene_and_lifecycle()

	# Level Loader & Audio Alignment Suites
	test_level_loader_and_alignment()

	# OMR Processor Suites
	test_omr_processor_integral_image()

	print("==================================================")
	print(" RESULTS: %d Passed, %d Failed" % [tests_passed, tests_failed])
	print("==================================================")

	if tests_failed == 0:
		print("ALL M3 COMPONENTS VERIFIED SUCCESSFULLY [OK]")
		quit(0)
	else:
		push_error("M3 VERIFICATION FAILED with %d errors" % tests_failed)
		quit(1)

func assert_true(condition: bool, message: String) -> void:
	if condition:
		tests_passed += 1
		print("  [PASS] %s" % message)
	else:
		tests_failed += 1
		printerr("  [FAIL] %s" % message)

func assert_eq(actual, expected, message: String) -> void:
	if actual == expected:
		tests_passed += 1
		print("  [PASS] %s (expected %s, got %s)" % [message, str(expected), str(actual)])
	else:
		tests_failed += 1
		printerr("  [FAIL] %s (expected %s, got %s)" % [message, str(expected), str(actual)])

func assert_almost_eq(actual: float, expected: float, epsilon: float, message: String) -> void:
	if absf(actual - expected) <= epsilon:
		tests_passed += 1
		print("  [PASS] %s (expected ~%s, got %s)" % [message, str(expected), str(actual)])
	else:
		tests_failed += 1
		printerr("  [FAIL] %s (expected ~%s, got %s, diff %s > %s)" % [message, str(expected), str(actual), str(absf(actual - expected)), str(epsilon)])

func test_timing_windows() -> void:
	print("\n--- Suite 1: Timing Windows (Perfect <= 50ms, Good <= 100ms, Miss > 100ms) ---")
	var s = ScoringServiceScript.new()

	assert_eq(s.evaluate_timing(0.0), "PERFECT", "0ms diff evaluates to PERFECT")
	assert_eq(s.evaluate_timing(0.025), "PERFECT", "+25ms diff evaluates to PERFECT")
	assert_eq(s.evaluate_timing(-0.045), "PERFECT", "-45ms diff evaluates to PERFECT")
	assert_eq(s.evaluate_timing(0.050), "PERFECT", "Exact +50ms boundary evaluates to PERFECT")
	assert_eq(s.evaluate_timing(-0.050), "PERFECT", "Exact -50ms boundary evaluates to PERFECT")

	assert_eq(s.evaluate_timing(0.051), "GOOD", "+51ms evaluates to GOOD")
	assert_eq(s.evaluate_timing(-0.075), "GOOD", "-75ms evaluates to GOOD")
	assert_eq(s.evaluate_timing(0.100), "GOOD", "Exact +100ms boundary evaluates to GOOD")
	assert_eq(s.evaluate_timing(-0.100), "GOOD", "Exact -100ms boundary evaluates to GOOD")

	assert_eq(s.evaluate_timing(0.101), "MISS", "+101ms evaluates to MISS")
	assert_eq(s.evaluate_timing(-0.150), "MISS", "-150ms evaluates to MISS")
	assert_eq(s.evaluate_timing(0.500), "MISS", "+500ms evaluates to MISS")
	s.free()

func test_scoring_formulas_and_multipliers() -> void:
	print("\n--- Suite 2: Standard Integer Multiplier Progression (1x, 2x, 3x, 4x) ---")
	var s = ScoringServiceScript.new()
	s.multiplier_mode = s.MultiplierMode.INTEGER_TIERS

	# Hits 1 through 9: Multiplier 1x (9 * 100 = 900)
	for i in range(9):
		var res = s.register_hit("PERFECT")
		assert_eq(res["multiplier"], 1, "Hit %d multiplier is 1x" % (i + 1))
	assert_eq(s.total_score, 900, "Score after 9 Perfects is 900")
	assert_eq(s.current_combo, 9, "Combo is 9")

	# 10th Hit: Multiplier triggers 2x (100 * 2 = 200 pts)
	var res10 = s.register_hit("PERFECT")
	assert_eq(res10["multiplier"], 2, "10th hit triggers 2x multiplier")
	assert_eq(res10["points_awarded"], 200, "10th hit awards 200 pts")
	assert_eq(s.total_score, 1100, "Total score after 10th hit is 1100")

	# Hits 11 through 19: Combo 11..19 at 2x
	for i in range(11, 20):
		s.register_hit("PERFECT")
	assert_eq(s.total_score, 2900, "Total score after 19 hits is 2900")

	# 20th Hit: Multiplier triggers 3x (100 * 3 = 300 pts)
	var res20 = s.register_hit("PERFECT")
	assert_eq(res20["multiplier"], 3, "20th hit triggers 3x multiplier")
	assert_eq(s.total_score, 3200, "Total score after 20th hit is 3200")

	# Hits 21 through 29: Combo 21..29 at 3x
	for i in range(21, 30):
		s.register_hit("PERFECT")
	assert_eq(s.total_score, 5900, "Total score after 29 hits is 5900")

	# 30th Hit: Multiplier triggers 4x (100 * 4 = 400 pts)
	var res30 = s.register_hit("PERFECT")
	assert_eq(res30["multiplier"], 4, "30th hit triggers 4x multiplier")
	assert_eq(s.total_score, 6300, "Total score after 30th hit is 6300")

	# 31st Hit with GOOD (50 * 4 = 200 pts)
	var res31 = s.register_hit("GOOD")
	assert_eq(res31["multiplier"], 4, "31st hit multiplier remains 4x")
	assert_eq(res31["points_awarded"], 200, "Good hit at 4x awards 200 pts")
	assert_eq(s.total_score, 6500, "Total score after 31st hit is 6500")
	s.free()

func test_float_scaled_multipliers() -> void:
	print("\n--- Suite 3: Float-Scaled Multipliers (1.0x, 1.5x, 2.0x, 4.0x) ---")
	var s = ScoringServiceScript.new()
	s.multiplier_mode = s.MultiplierMode.FLOAT_SCALED

	for i in range(9):
		s.register_hit("PERFECT")
	assert_eq(s.get_multiplier_float(), 1.0, "Combo 9 multiplier is 1.0x")

	s.register_hit("PERFECT") # 10th
	assert_eq(s.get_multiplier_float(), 1.5, "Combo 10 multiplier is 1.5x")

	for i in range(9):
		s.register_hit("PERFECT")
	s.register_hit("PERFECT") # 20th
	assert_eq(s.get_multiplier_float(), 2.0, "Combo 20 multiplier is 2.0x")

	for i in range(9):
		s.register_hit("PERFECT")
	s.register_hit("PERFECT") # 30th
	assert_eq(s.get_multiplier_float(), 4.0, "Combo 30 multiplier is 4.0x")
	s.free()

func test_combo_streak_reset() -> void:
	print("\n--- Suite 4: Combo Streak Reset on MISS ---")
	var s = ScoringServiceScript.new()

	for i in range(15):
		s.register_hit("PERFECT")
	assert_eq(s.current_combo, 15, "Combo reaches 15")
	assert_eq(s.get_multiplier(), 2, "Multiplier is 2x")
	var prev_score: int = s.total_score

	var miss_res = s.register_miss()
	assert_eq(miss_res["judgment"], "MISS", "Registered judgment is MISS")
	assert_eq(miss_res["points_awarded"], 0, "MISS awards 0 pts")
	assert_eq(s.current_combo, 0, "Combo reset to 0 on MISS")
	assert_eq(s.get_multiplier(), 1, "Multiplier reset to 1x on MISS")
	assert_eq(s.max_combo, 15, "Max combo preserved at 15")
	assert_eq(s.total_score, prev_score, "Score preserved on MISS")
	s.free()

func test_polyphonic_chord_matching() -> void:
	print("\n--- Suite 5: Polyphonic Chord Matching (C Major Triad [60, 64, 67]) ---")
	var s = ScoringServiceScript.new()
	var chord_notes = [
		{"pitch_midi": 60, "time_sec": 1.0, "duration_sec": 1.0, "is_hit": false, "is_missed": false},
		{"pitch_midi": 64, "time_sec": 1.0, "duration_sec": 1.0, "is_hit": false, "is_missed": false},
		{"pitch_midi": 67, "time_sec": 1.0, "duration_sec": 1.0, "is_hit": false, "is_missed": false}
	]

	# All 3 chord tones arrive concurrently at t=1.02s (+20ms -> PERFECT)
	var chord = [60, 64, 67]
	var hits: Array[Dictionary] = []
	for p in chord:
		var hit = s.process_input(1.02, p, chord_notes, 0)
		if not hit.is_empty():
			hits.append(hit)

	assert_eq(hits.size(), 3, "All 3 chord tones scored concurrently")
	assert_true(chord_notes[0]["is_hit"], "C4 is_hit = true")
	assert_true(chord_notes[1]["is_hit"], "E4 is_hit = true")
	assert_true(chord_notes[2]["is_hit"], "G4 is_hit = true")
	assert_eq(s.current_combo, 3, "Combo is 3 after triad hit")
	assert_eq(s.total_score, 300, "Score is 300 (3 x 100 Perfect)")
	assert_eq(s.count_perfect, 3, "3 Perfect counts recorded")
	s.free()

func test_partial_chords_and_note_expiration() -> void:
	print("\n--- Suite 6: Partial Chords & Note Expiration ---")
	var s = ScoringServiceScript.new()
	var chord_notes = [
		{"pitch_midi": 60, "time_sec": 2.0, "duration_sec": 0.5, "is_hit": false, "is_missed": false},
		{"pitch_midi": 64, "time_sec": 2.0, "duration_sec": 0.5, "is_hit": false, "is_missed": false},
		{"pitch_midi": 67, "time_sec": 2.0, "duration_sec": 0.5, "is_hit": false, "is_missed": false}
	]

	# Player only sings C4 and E4, omitting G4
	s.process_input(2.01, 60, chord_notes, 0)
	s.process_input(2.01, 64, chord_notes, 0)

	assert_true(chord_notes[0]["is_hit"], "C4 struck")
	assert_true(chord_notes[1]["is_hit"], "E4 struck")
	assert_true(not chord_notes[2]["is_hit"], "G4 remains unhit")
	assert_eq(s.current_combo, 2, "Combo is 2 from partial hit")

	# Playhead passes beyond +100ms window (t = 2.15s > 2.0 + 0.10s)
	var expired = s.check_expired_notes(2.15, chord_notes)
	assert_eq(expired.size(), 1, "1 note expired (G4)")
	assert_eq(expired[0]["judgment"], "MISS", "G4 judged MISS")
	assert_true(chord_notes[2]["is_missed"], "G4 marked missed")
	assert_eq(s.current_combo, 0, "Combo reset to 0 by omitted chord note")
	s.free()

func test_sustain_retrigger_filtering() -> void:
	print("\n--- Suite 7: Sustain vs Onset Edge Retrigger Filtering ---")
	var s = ScoringServiceScript.new()
	var test_notes = [
		{"pitch_midi": 60, "time_sec": 1.0, "duration_sec": 1.0, "is_hit": false, "is_missed": false},
		{"pitch_midi": 60, "time_sec": 2.5, "duration_sec": 1.0, "is_hit": false, "is_missed": false}
	]
	s.set_active_chart(test_notes)

	# Frame 1: Initial note attack
	var f1_hits = s.process_detected_pitches([60], [60], 1.0)
	assert_eq(f1_hits.size(), 1, "Note 1 struck on attack")
	assert_true(test_notes[0]["is_hit"], "Note 1 marked is_hit")
	assert_eq(s.current_combo, 1, "Combo is 1")

	# Frames 2..5: Holding sustain (detected_pitches has 60, onsets empty)
	for f in range(5):
		var fn_hits = s.process_detected_pitches([60], [], 1.1 + float(f) * 0.1)
		assert_eq(fn_hits.size(), 0, "No duplicate strike during sustained pitch")

	assert_eq(s.current_combo, 1, "Combo preserved at 1 during sustain")
	assert_true(not test_notes[1]["is_hit"], "Subsequent Note 2 at 2.5s untouched")

	# Frame 6: Attack Note 2 at 2.5s with new onset
	var f6_hits = s.process_detected_pitches([60], [60], 2.5)
	assert_eq(f6_hits.size(), 1, "Note 2 struck on new onset")
	assert_true(test_notes[1]["is_hit"], "Note 2 marked is_hit")
	assert_eq(s.current_combo, 2, "Combo reached 2")
	assert_eq(s.total_score, 200, "Score reached 200")
	s.free()

func test_accuracy_calculation() -> void:
	print("\n--- Suite 8: Accuracy Calculation ---")
	var s = ScoringServiceScript.new()
	assert_eq(s.get_accuracy(), 100.0, "Initial accuracy with 0 notes is 100.0%")

	# 2 Perfect (100% each) + 2 Good (50% each) = (2 + 1)/4 = 75.0%
	s.register_hit("PERFECT")
	s.register_hit("PERFECT")
	s.register_hit("GOOD")
	s.register_hit("GOOD")
	assert_eq(s.get_accuracy(), 75.0, "Accuracy for 2 Perfect + 2 Good is 75.0%")

	# + 1 Miss = 3.0 / 5.0 = 60.0%
	s.register_miss()
	assert_eq(s.get_accuracy(), 60.0, "Accuracy with 1 added Miss is 60.0%")
	s.free()

func test_adversarial_dirty_inputs_and_bounds() -> void:
	print("\n--- Suite 9: Adversarial Dirty Inputs and Submillisecond Bounds ---")
	var s = ScoringServiceScript.new()

	# Submillisecond bounds
	assert_eq(s.evaluate_timing(0.04999), "PERFECT", "+49.99ms is PERFECT")
	assert_eq(s.evaluate_timing(0.05000), "PERFECT", "+50.00ms is PERFECT")
	assert_eq(s.evaluate_timing(0.05001), "GOOD", "+50.01ms is GOOD")
	assert_eq(s.evaluate_timing(0.09999), "GOOD", "+99.99ms is GOOD")
	assert_eq(s.evaluate_timing(0.10000), "GOOD", "+100.00ms is GOOD")
	assert_eq(s.evaluate_timing(0.10001), "MISS", "+100.01ms is MISS")

	# NaN & INF protection
	assert_eq(s.evaluate_timing(NAN), "MISS", "NAN diff evaluates to MISS without crash")
	assert_eq(s.evaluate_timing(INF), "MISS", "INF diff evaluates to MISS without crash")

	# Dirty array resilience
	var dirty_notes = [
		null,
		"garbage",
		{},
		{"unrelated": 123},
		{"pitch_midi": 60, "is_hit": true}, # missing time_sec
		{"pitch_midi": 60, "time_sec": 1.0, "is_hit": false} # valid note
	]
	var res = s.process_input(1.01, 60, dirty_notes)
	assert_eq(res.get("judgment", ""), "PERFECT", "Survived dirty array and matched valid note")
	s.free()

func test_note_data_and_diatonic_math() -> void:
	print("\n--- Suite 10: NoteData Diatonic Placement & Ledger Line Math ---")

	# 1. Middle C (C4, MIDI 60)
	var n_c4 = NoteDataScript.new(1, 60, 0.0, 1.0)
	assert_eq(n_c4.diatonic_step, 28, "Middle C4 diatonic step is 28")
	assert_eq(n_c4.y_pos, 360.0, "Middle C4 Y coordinate is exactly 360.0 px")
	assert_eq(n_c4.pitch_name, "C4", "Middle C4 pitch name is C4")
	assert_eq(n_c4.ledger_y_positions.size(), 1, "Middle C has exactly 1 ledger line")
	assert_eq(n_c4.ledger_y_positions[0], 360.0, "Middle C ledger line is at Y=360.0 px")

	# 2. All 5 Treble Lines: F5(270), D5(288), B4(306), G4(324), E4(342)
	assert_eq(NoteDataScript.midi_to_y(77), 270.0, "Treble line 5: F5 (MIDI 77) is at Y=270.0 px")
	assert_eq(NoteDataScript.midi_to_y(74), 288.0, "Treble line 4: D5 (MIDI 74) is at Y=288.0 px")
	assert_eq(NoteDataScript.midi_to_y(71), 306.0, "Treble line 3: B4 (MIDI 71) is at Y=306.0 px")
	assert_eq(NoteDataScript.midi_to_y(67), 324.0, "Treble line 2: G4 (MIDI 67) is at Y=324.0 px")
	assert_eq(NoteDataScript.midi_to_y(64), 342.0, "Treble line 1: E4 (MIDI 64) is at Y=342.0 px")

	# 3. All 5 Bass Lines: A3(378), F3(396), D3(414), B2(432), G2(450)
	assert_eq(NoteDataScript.midi_to_y(57), 378.0, "Bass line 5: A3 (MIDI 57) is at Y=378.0 px")
	assert_eq(NoteDataScript.midi_to_y(53), 396.0, "Bass line 4: F3 (MIDI 53) is at Y=396.0 px")
	assert_eq(NoteDataScript.midi_to_y(50), 414.0, "Bass line 3: D3 (MIDI 50) is at Y=414.0 px")
	assert_eq(NoteDataScript.midi_to_y(47), 432.0, "Bass line 2: B2 (MIDI 47) is at Y=432.0 px")
	assert_eq(NoteDataScript.midi_to_y(43), 450.0, "Bass line 1: G2 (MIDI 43) is at Y=450.0 px")

	# 4. Spacing checks
	assert_almost_eq(NoteDataScript.midi_to_y(64) - NoteDataScript.midi_to_y(67), 18.0, 0.001, "Staff line spacing is 18.0 px")
	assert_almost_eq(NoteDataScript.midi_to_y(60) - NoteDataScript.midi_to_y(62), 9.0, 0.001, "Diatonic step delta Y is 9.0 px")

	# 5. Ledger line derivations
	# High note A5 (MIDI 81, step 40) -> 1 ledger line at Y=252.0
	var n_a5 = NoteDataScript.new(2, 81, 0.0, 1.0)
	assert_eq(n_a5.ledger_y_positions.size(), 1, "A5 has 1 ledger line")
	assert_eq(n_a5.ledger_y_positions[0], 252.0, "A5 ledger line is at Y=252.0")

	# High note C6 (MIDI 84, step 42) -> 2 ledger lines at Y=252.0 and Y=234.0
	var n_c6 = NoteDataScript.new(3, 84, 0.0, 1.0)
	assert_eq(n_c6.ledger_y_positions.size(), 2, "C6 has 2 ledger lines")
	assert_eq(n_c6.ledger_y_positions[0], 252.0, "C6 1st ledger is Y=252.0")
	assert_eq(n_c6.ledger_y_positions[1], 234.0, "C6 2nd ledger is Y=234.0")

	# Low note E2 (MIDI 40, step 16) -> 1 ledger line at Y=468.0
	var n_e2 = NoteDataScript.new(4, 40, 0.0, 1.0)
	assert_eq(n_e2.ledger_y_positions.size(), 1, "E2 has 1 ledger line")
	assert_eq(n_e2.ledger_y_positions[0], 468.0, "E2 ledger line is at Y=468.0")

	# 6. Serialization round-trip
	var note_dict = n_c4.to_dict()
	assert_eq(note_dict["pitch_midi"], 60, "Dict pitch_midi is 60")
	assert_eq(note_dict["y_pos"], 360.0, "Dict y_pos is 360.0")
	var reconstructed = NoteDataScript.from_dict(note_dict, 10)
	assert_eq(reconstructed.pitch_midi, 60, "Reconstructed note pitch is 60")
	assert_eq(reconstructed.y_pos, 360.0, "Reconstructed note Y is 360.0")

func test_harmonic_second_offset_algorithm() -> void:
	print("\n--- Suite 11: Harmonic Second Notehead Collision Offset (+16px) ---")

	# Case A: Harmonic second C4 (step 28) and D4 (step 29) at t=1.0s
	var notes: Array[NoteData] = [
		NoteDataScript.new(1, 60, 1.0, 1.0), # C4, step 28
		NoteDataScript.new(2, 62, 1.0, 1.0)  # D4, step 29
	]
	GrandStaffHighwayScript.calculate_chord_offsets(notes)
	assert_eq(notes[0].chord_offset_x, 0.0, "Lowest note C4 offset is 0.0 px")
	assert_eq(notes[1].chord_offset_x, 16.0, "Adjacent second note D4 offset is +16.0 px (>= 15px)")

	# Case B: Harmonic third C4 (step 28) and E4 (step 30) - no second collision
	var thirds: Array[NoteData] = [
		NoteDataScript.new(1, 60, 1.0, 1.0), # C4, step 28
		NoteDataScript.new(2, 64, 1.0, 1.0)  # E4, step 30
	]
	GrandStaffHighwayScript.calculate_chord_offsets(thirds)
	assert_eq(thirds[0].chord_offset_x, 0.0, "C4 in third has 0.0 offset")
	assert_eq(thirds[1].chord_offset_x, 0.0, "E4 in third has 0.0 offset")

	# Case C: 3-note cluster (steps 28, 29, 30)
	var cluster: Array[NoteData] = [
		NoteDataScript.new(1, 60, 1.0, 1.0), # step 28
		NoteDataScript.new(2, 62, 1.0, 1.0), # step 29
		NoteDataScript.new(3, 64, 1.0, 1.0)  # step 30
	]
	GrandStaffHighwayScript.calculate_chord_offsets(cluster)
	assert_eq(cluster[0].chord_offset_x, 0.0, "Cluster note 1 offset is 0.0")
	assert_eq(cluster[1].chord_offset_x, 16.0, "Cluster note 2 offset is 16.0")
	assert_eq(cluster[2].chord_offset_x, 0.0, "Cluster note 3 offset alternates to 0.0")

func test_highway_scene_and_lifecycle() -> void:
	print("\n--- Suite 12: Highway Scene Instantiation & Note Lifecycle ---")

	var highway_scene = load("res://scenes/highway.tscn")
	assert_true(highway_scene != null, "scenes/highway.tscn loads successfully")

	var highway = highway_scene.instantiate()
	assert_true(highway is GrandStaffHighwayScript, "Root is GrandStaffHighway")
	assert_true(highway.has_node("NoteRenderer"), "NoteRenderer child exists")
	assert_true(highway.has_node("AudioPlayer"), "AudioPlayer child exists")

	# Test note loading and scrolling coordinates
	var test_notes = [
		{"pitch_midi": 60, "time_sec": 1.0, "duration_sec": 0.5},
		{"pitch_midi": 64, "time_sec": 2.0, "duration_sec": 0.5}
	]
	highway.load_notes(test_notes)
	assert_eq(highway.chart_notes.size(), 2, "2 chart notes loaded")
	assert_eq(highway.x_hit, 160.0, "Receptor x_hit is 160.0 px")

	# Query active notes
	highway.active_notes = highway.chart_notes.duplicate()
	var queried = highway.get_active_notes_at(1.02, 0.05)
	assert_eq(queried.size(), 1, "get_active_notes_at returns note near 1.0s")
	assert_eq(queried[0].pitch_midi, 60, "Queried note is C4 (MIDI 60)")

	highway.free()

func test_level_loader_and_alignment() -> void:
	print("\n--- Suite 13: LevelLoader & Audio-Chart Alignment ---")

	var loader = LevelLoaderScript.new()
	assert_true(loader != null, "LevelLoader instantiates successfully")

	var raw_chart = {
		"title": "Synthetic Test Level",
		"bpm": 120.0,
		"time_signature": [4, 4],
		"notes": [
			{"pitch_midi": 60, "beat": 0.0, "measure": 1, "duration_beats": 1.0},
			{"pitch_midi": 64, "beat": 1.0, "measure": 1, "duration_beats": 1.0},
			{"pitch_midi": 67, "beat": 2.0, "measure": 1, "duration_beats": 2.0}
		]
	}

	var aligned = loader.align_level(raw_chart, null, {"calibration_offset_ms": 25.0})
	assert_eq(aligned["bpm"], 120.0, "Aligned level preserves BPM 120")
	assert_eq(aligned["notes"].size(), 3, "All 3 notes aligned")
	assert_eq(aligned["notes"][0]["time_sec"], 0.0, "Note 1 starts at 0.0s")
	assert_eq(aligned["notes"][1]["time_sec"], 0.5, "Note 2 starts at 0.5s (beat 1 at 120bpm)")
	assert_eq(aligned["notes"][2]["time_sec"], 1.0, "Note 3 starts at 1.0s (beat 2 at 120bpm)")
	assert_eq(aligned["calibration_offset_ms"], 25.0, "Calibration offset ms set to 25.0")
	assert_eq(aligned["calibration_offset_sec"], 0.025, "Calibration offset sec is 0.025s")

	# Test apply_to_game duck typing
	var highway = GrandStaffHighwayScript.new()
	var success = loader.apply_to_game(aligned, highway, null)
	assert_true(success, "apply_to_game succeeds with GrandStaffHighway")
	assert_eq(highway.chart_notes.size(), 3, "Highway received 3 notes")
	assert_eq(highway.audio_offset_sec, 0.025, "Highway audio_offset_sec set to 0.025")
	highway.free()
	loader.free()

func test_omr_processor_integral_image() -> void:
	print("\n--- Suite 14: OMRProcessor Integral Image & Image Handling ---")

	# Test empty image defense
	var empty_chart = OMRProcessorScript.process_image_data(null)
	assert_eq(empty_chart["notes"].size(), 0, "Null image safely produces empty notes list")

	var tiny_img = Image.create(16, 16, false, Image.FORMAT_L8)
	var tiny_chart = OMRProcessorScript.process_image_data(tiny_img)
	assert_eq(tiny_chart["notes"].size(), 0, "Tiny image (<32px) safely produces empty notes list")

	# Test uniform all-white image
	var white_img = Image.create(100, 100, false, Image.FORMAT_L8)
	white_img.fill(Color(1.0, 1.0, 1.0, 1.0))
	var white_chart = OMRProcessorScript.process_image_data(white_img)
	assert_eq(white_chart["notes"].size(), 0, "All-white image produces empty chart without error")

	# Test uniform all-black image
	var black_img = Image.create(100, 100, false, Image.FORMAT_L8)
	black_img.fill(Color(0.0, 0.0, 0.0, 1.0))
	var black_chart = OMRProcessorScript.process_image_data(black_img)
	assert_eq(black_chart["notes"].size(), 0, "All-black image produces empty chart without error")
