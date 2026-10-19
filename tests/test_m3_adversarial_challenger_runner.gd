# res://tests/test_m3_adversarial_challenger_runner.gd
extends SceneTree

const ScoringServiceScript = preload("res://scripts/scoring_service.gd")
const LevelLoaderScript = preload("res://scripts/level_loader.gd")
const OMRProcessorScript = preload("res://scripts/omr_processor.gd")
const NoteDataScript = preload("res://scripts/note_data.gd")

var tests_passed: int = 0
var tests_failed: int = 0
var failure_details: Array[String] = []

func _init() -> void:
	print("==================================================================")
	print(" M3 ADVERSARIAL CHALLENGER VERIFICATION SUITE                    ")
	print("==================================================================")

	test_submillisecond_timing_jitter()
	test_high_throughput_1500_notes()
	test_sustain_retrigger_60_frames()
	test_partial_chord_and_expiration()
	test_level_loader_adversarial_inputs()
	test_omr_processor_adversarial_images()

	print("==================================================================")
	print(" M3 ADVERSARIAL CHALLENGER RESULTS: %d Passed, %d Failed" % [tests_passed, tests_failed])
	print("==================================================================")

	if failure_details.size() > 0:
		print("\n--- FAILURE BREAKDOWN ---")
		for f in failure_details:
			print("  [CHALLENGE FINDING] %s" % f)
		print("-------------------------\n")

	if tests_failed == 0:
		print("CHALLENGE STATUS: APPROVE (All adversarial tests passed)")
		quit(0)
	else:
		print("CHALLENGE STATUS: CHALLENGE_FAILED (%d empirical failures detected)" % tests_failed)
		quit(1)

func record_pass(msg: String) -> void:
	tests_passed += 1
	print("  [PASS] %s" % msg)

func record_fail(msg: String, detail: String = "") -> void:
	tests_failed += 1
	var formatted = "%s | %s" % [msg, detail] if detail != "" else msg
	failure_details.append(formatted)
	printerr("  [FAIL] %s" % formatted)

func assert_eq(actual, expected, test_name: String) -> void:
	if actual == expected:
		record_pass("%s (got %s)" % [test_name, str(actual)])
	else:
		record_fail(test_name, "Expected %s, but got %s" % [str(expected), str(actual)])

func assert_true(condition: bool, test_name: String) -> void:
	if condition:
		record_pass(test_name)
	else:
		record_fail(test_name, "Condition was false")

# -----------------------------------------------------------------------------
# Suite 1: Sub-Millisecond Timing Jitter & Boundary Stress
# -----------------------------------------------------------------------------
func test_submillisecond_timing_jitter() -> void:
	print("\n--- Suite 1: Sub-Millisecond Timing Window Boundary & Jitter Stress ---")
	var s = ScoringServiceScript.new()

	# Exact boundaries and sub-millisecond offsets
	# 49.999ms = 0.049999s <= 50.0ms -> PERFECT
	assert_eq(s.evaluate_timing(0.049999), "PERFECT", "49.999ms (+0.049999s) must evaluate to PERFECT")
	# 50.000ms = 0.050000s <= 50.0ms -> PERFECT
	assert_eq(s.evaluate_timing(0.050000), "PERFECT", "50.000ms (+0.050000s) must evaluate to PERFECT")
	# 50.001ms = 0.050001s > 50.0ms -> GOOD
	assert_eq(s.evaluate_timing(0.050001), "GOOD", "50.001ms (+0.050001s) must evaluate to GOOD")

	# 99.999ms = 0.099999s <= 100.0ms -> GOOD
	assert_eq(s.evaluate_timing(0.099999), "GOOD", "99.999ms (+0.099999s) must evaluate to GOOD")
	# 100.000ms = 0.100000s <= 100.0ms -> GOOD
	assert_eq(s.evaluate_timing(0.100000), "GOOD", "100.000ms (+0.100000s) must evaluate to GOOD")
	# 100.001ms = 0.100001s > 100.0ms -> MISS
	assert_eq(s.evaluate_timing(0.100001), "MISS", "100.001ms (+0.100001s) must evaluate to MISS")

	# Negative boundaries (early hits)
	# -49.999ms = -0.049999s -> PERFECT
	assert_eq(s.evaluate_timing(-0.049999), "PERFECT", "-49.999ms (-0.049999s) must evaluate to PERFECT")
	# -50.000ms = -0.050000s -> PERFECT
	assert_eq(s.evaluate_timing(-0.050000), "PERFECT", "-50.000ms (-0.050000s) must evaluate to PERFECT")
	# -50.001ms = -0.050001s -> GOOD
	assert_eq(s.evaluate_timing(-0.050001), "GOOD", "-50.001ms (-0.050001s) must evaluate to GOOD")

	# -99.999ms = -0.099999s -> GOOD
	assert_eq(s.evaluate_timing(-0.099999), "GOOD", "-99.999ms (-0.099999s) must evaluate to GOOD")
	# -100.000ms = -0.100000s -> GOOD
	assert_eq(s.evaluate_timing(-0.100000), "GOOD", "-100.000ms (-0.100000s) must evaluate to GOOD")
	# -100.001ms = -0.100001s -> MISS
	assert_eq(s.evaluate_timing(-0.100001), "MISS", "-100.001ms (-0.100001s) must evaluate to MISS")

	# Non-finite floating point numbers
	assert_eq(s.evaluate_timing(NAN), "MISS", "NAN timing diff must safely evaluate to MISS")
	assert_eq(s.evaluate_timing(INF), "MISS", "+INF timing diff must safely evaluate to MISS")
	assert_eq(s.evaluate_timing(-INF), "MISS", "-INF timing diff must safely evaluate to MISS")

	# Test check_expired_notes consistency with evaluate_timing
	# A note at time_sec = 1.0. At current_time = 1.100001s:
	var exp_notes = [
		{"pitch_midi": 60, "time_sec": 1.0, "is_hit": false, "is_missed": false}
	]
	var expired = s.check_expired_notes(1.100001, exp_notes)
	assert_eq(expired.size(), 1, "Note at 1.0s must expire as MISS when playhead reaches 1.100001s")

	# If the note expired at 1.100001s, process_input at 1.100001s must NOT award a hit
	var late_hit = s.process_input(1.100001, 60, exp_notes)
	assert_true(late_hit.is_empty(), "Expired note must reject process_input at 1.100001s")

	s.free()

# -----------------------------------------------------------------------------
# Suite 2: High-Throughput 1500-Note Stream Stress
# -----------------------------------------------------------------------------
func test_high_throughput_1500_notes() -> void:
	print("\n--- Suite 2: High-Throughput 1500-Note Stream & Score Accumulation ---")
	var s = ScoringServiceScript.new()
	s.multiplier_mode = s.MultiplierMode.INTEGER_TIERS

	var total_notes_count: int = 1500
	var test_chart: Array = []
	for i in range(total_notes_count):
		test_chart.append({
			"id": i + 1,
			"pitch_midi": 60 + (i % 12),
			"time_sec": float(i) * 0.1,
			"duration_sec": 0.08,
			"is_hit": false,
			"is_missed": false
		})

	s.set_active_chart(test_chart)

	var start_mem: int = OS.get_static_memory_usage()
	var start_ticks: int = Time.get_ticks_msec()

	# Process 1500 notes sequentially with PERFECT timing
	for i in range(total_notes_count):
		var note_time: float = float(i) * 0.1
		var pitch: int = 60 + (i % 12)
		var res: Dictionary = s.process_input(note_time, pitch, test_chart)
		if res.is_empty():
			record_fail("1500 Note Throughput", "Note %d failed to match at t=%.2f" % [i, note_time])
			break

	var elapsed_ms: int = Time.get_ticks_msec() - start_ticks
	var end_mem: int = OS.get_static_memory_usage()
	var mem_delta_kb: float = float(end_mem - start_mem) / 1024.0

	print("  Throughput: 1500 notes processed in %d ms (%.2f notes/sec)" % [elapsed_ms, float(total_notes_count) / maxf(0.001, float(elapsed_ms) / 1000.0)])
	print("  Static memory delta: %.2f KB" % mem_delta_kb)

	assert_eq(s.current_combo, 1500, "1500 consecutive hits must yield combo of 1500")
	assert_eq(s.max_combo, 1500, "1500 consecutive hits must yield max_combo of 1500")
	assert_eq(s.count_perfect, 1500, "count_perfect must equal 1500")
	assert_eq(s.count_miss, 0, "count_miss must equal 0")

	# Mathematical score derivation for 1500 hits with integer multiplier:
	# 1..9 (9 notes) @ 1x = 9 * 100 = 900
	# 10..19 (10 notes) @ 2x = 10 * 200 = 2000
	# 20..29 (10 notes) @ 3x = 10 * 300 = 3000
	# 30..1500 (1471 notes) @ 4x = 1471 * 400 = 588,400
	# Total = 900 + 2000 + 3000 + 588400 = 594,300
	var expected_score: int = 594300
	assert_eq(s.total_score, expected_score, "Score accumulation across 1500 notes must equal exactly 594,300")
	assert_eq(s.get_accuracy(), 100.0, "Accuracy across 1500 Perfects must be exactly 100.0%")
	assert_true(elapsed_ms < 2000, "1500 notes must be processed in under 2000ms (took %d ms)" % elapsed_ms)

	s.free()

# -----------------------------------------------------------------------------
# Suite 3: Continuous Tone Sustain Retrigger Lockout Across 60 Frames
# -----------------------------------------------------------------------------
func test_sustain_retrigger_60_frames() -> void:
	print("\n--- Suite 3: Continuous Tone Sustain Retrigger Lockout (60 Frames) ---")
	var s = ScoringServiceScript.new()

	var test_notes = [
		{"id": 1, "pitch_midi": 60, "time_sec": 1.0, "duration_sec": 1.5, "is_hit": false, "is_missed": false},
		{"id": 2, "pitch_midi": 60, "time_sec": 3.0, "duration_sec": 1.0, "is_hit": false, "is_missed": false}
	]
	s.set_active_chart(test_notes)

	# Frame 1: Singer attacks pitch 60 at t=1.0s (onset detected)
	var f1_hits = s.process_detected_pitches([60], [60], 1.0)
	assert_eq(f1_hits.size(), 1, "Frame 1 (Attack): Exactly 1 hit awarded on onset")
	assert_true(test_notes[0]["is_hit"], "Frame 1: Note 1 marked is_hit")
	assert_eq(s.current_combo, 1, "Combo is 1 after initial attack")

	# Frames 2..60: Singer holds continuous pitch 60 for 59 more frames (~1.0s of sustain at 60 FPS)
	# No onsets are emitted by InferenceService during sustain
	var duplicate_hits_count: int = 0
	for f in range(2, 61):
		var frame_time: float = 1.0 + float(f - 1) * 0.016667
		var hits = s.process_detected_pitches([60], [], frame_time)
		if hits.size() > 0:
			duplicate_hits_count += hits.size()

	assert_eq(duplicate_hits_count, 0, "Continuous sustain across 59 subsequent frames must award 0 duplicate hits")
	assert_eq(s.current_combo, 1, "Combo must remain 1 throughout continuous sustain")
	assert_eq(s.total_score, 100, "Score must remain 100 (no score inflation during sustain)")
	assert_true(not test_notes[1]["is_hit"], "Note 2 at 3.0s must remain unhit during Note 1 sustain")

	# Now at t=3.0s, singer articulates new onset for Note 2
	var f_note2_hits = s.process_detected_pitches([60], [60], 3.0)
	assert_eq(f_note2_hits.size(), 1, "New onset at 3.0s successfully hits Note 2")
	assert_true(test_notes[1]["is_hit"], "Note 2 marked is_hit")
	assert_eq(s.current_combo, 2, "Combo reaches 2 on second note onset")
	assert_eq(s.total_score, 200, "Score reaches 200 after second note")

	s.free()

# -----------------------------------------------------------------------------
# Suite 4: Partial Chord Matching & Note Expiration
# -----------------------------------------------------------------------------
func test_partial_chord_and_expiration() -> void:
	print("\n--- Suite 4: Partial Chord Matching (4-Note Chord, 2 Struck, 2 Expired) ---")
	var s = ScoringServiceScript.new()

	# 4-note chord at t=2.0s: C Major 7th [C4 (60), E4 (64), G4 (67), B4 (71)]
	var chord_notes = [
		{"id": 1, "pitch_midi": 60, "time_sec": 2.0, "duration_sec": 1.0, "is_hit": false, "is_missed": false},
		{"id": 2, "pitch_midi": 64, "time_sec": 2.0, "duration_sec": 1.0, "is_hit": false, "is_missed": false},
		{"id": 3, "pitch_midi": 67, "time_sec": 2.0, "duration_sec": 1.0, "is_hit": false, "is_missed": false},
		{"id": 4, "pitch_midi": 71, "time_sec": 2.0, "duration_sec": 1.0, "is_hit": false, "is_missed": false}
	]
	s.set_active_chart(chord_notes)

	var signal_tracker = {"combo_broken_count": 0}
	s.combo_broken.connect(func(): signal_tracker["combo_broken_count"] += 1)

	# Singer only sings C4 (60) and G4 (67) at t=2.01s (both +10ms -> PERFECT)
	var hits = s.process_detected_pitches([60, 67], [60, 67], 2.01)
	assert_eq(hits.size(), 2, "2 notes of 4-note chord struck successfully")
	assert_true(chord_notes[0]["is_hit"], "C4 is_hit = true")
	assert_true(not chord_notes[1]["is_hit"], "E4 remains unhit")
	assert_true(chord_notes[2]["is_hit"], "G4 is_hit = true")
	assert_true(not chord_notes[3]["is_hit"], "B4 remains unhit")
	assert_eq(s.current_combo, 2, "Combo is 2 after partial chord hit")
	assert_eq(s.total_score, 200, "Score is 200 after partial chord hit")
	assert_eq(signal_tracker["combo_broken_count"], 0, "combo_broken not fired yet")

	# Playhead advances to t=2.05s (still within +/-100ms window)
	s.update_playhead(2.05)
	assert_eq(s.current_combo, 2, "Combo remains 2 at t=2.05s")
	assert_eq(s.count_miss, 0, "No misses at t=2.05s")

	# Playhead advances past +100ms window to t=2.15s (2.15 > 2.0 + 0.10)
	s.update_playhead(2.15)
	assert_true(chord_notes[1]["is_missed"], "Omitted E4 marked is_missed at t=2.15s")
	assert_true(chord_notes[3]["is_missed"], "Omitted B4 marked is_missed at t=2.15s")
	assert_eq(s.count_miss, 2, "Exactly 2 misses recorded for omitted chord notes")
	assert_eq(s.current_combo, 0, "Combo reset to 0 after omitted notes expire")
	assert_true(signal_tracker["combo_broken_count"] > 0, "combo_broken signal emitted on chord note expiration")
	assert_eq(s.total_score, 200, "Score remains 200 (no score reduction on miss)")

	s.free()

# -----------------------------------------------------------------------------
# Suite 5: LevelLoader Malformed & Adversarial Inputs
# -----------------------------------------------------------------------------
func test_level_loader_adversarial_inputs() -> void:
	print("\n--- Suite 5: LevelLoader Robustness & Malformed Inputs ---")
	var loader = LevelLoaderScript.new()

	# 1. Null / Empty chart inputs
	var null_level = loader.load_level(null)
	assert_true(null_level.is_empty(), "load_level(null) must return empty Dictionary")

	var empty_dict_level = loader.load_level({})
	assert_true(empty_dict_level.is_empty(), "load_level({}) must return empty Dictionary")

	# 2. Non-existent file path
	var missing_file_level = loader.load_level("res://non_existent_chart_path_9999.json")
	assert_true(missing_file_level.is_empty(), "load_level(non_existent_file) must return empty Dictionary")

	# 3. Malformed JSON structure (missing fields, negative BPM, invalid types)
	var malformed_chart = {
		"bpm": -60.0,
		"time_signature": "not_an_array",
		"notes": "not_an_array_of_notes"
	}
	var aligned_malformed = loader.align_level(malformed_chart)
	assert_eq(aligned_malformed.get("bpm"), 120.0, "Negative BPM must fall back to 120.0")
	assert_eq(aligned_malformed.get("time_signature"), [4, 4], "Malformed time signature must fall back to [4, 4]")
	assert_eq(aligned_malformed.get("notes", []).size(), 0, "Malformed notes must fall back to empty array")

	# 4. Chart notes extending beyond audio length (audio 5.0s, chart 12.0s)
	var wav_5s = AudioStreamWAV.new()
	wav_5s.mix_rate = 44100
	wav_5s.format = AudioStreamWAV.FORMAT_16_BITS
	wav_5s.stereo = false
	var pcm_bytes = PackedByteArray()
	pcm_bytes.resize(44100 * 2 * 5) # 5 seconds of PCM data
	wav_5s.data = pcm_bytes

	var long_chart = {
		"bpm": 120.0,
		"notes": [
			{"pitch_midi": 60, "onset_beat": 0.0, "duration_beats": 4.0}, # 2.0s
			{"pitch_midi": 64, "onset_beat": 20.0, "duration_beats": 4.0} # 12.0s
		]
	}
	var aligned_long = loader.align_level(long_chart, wav_5s)
	assert_true(not aligned_long.get("is_aligned", true), "Chart extending beyond audio length must have is_aligned = false")

	# 5. Audio loading from corrupt bytes
	var corrupt_bytes = PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8])
	var wav_res = loader._load_wav_from_bytes(corrupt_bytes)
	assert_true(wav_res == null, "Loading corrupt WAV (<44 bytes) must return null without crashing")

	var bad_header = PackedByteArray()
	for i in range(50): bad_header.append(0)
	var wav_bad_hdr = loader._load_wav_from_bytes(bad_header)
	assert_true(wav_bad_hdr == null, "Loading WAV with invalid RIFF/WAVE header must return null without crashing")

	loader.free()

# -----------------------------------------------------------------------------
# Suite 6: OMRProcessor Adversarial Images
# -----------------------------------------------------------------------------
func test_omr_processor_adversarial_images() -> void:
	print("\n--- Suite 6: OMRProcessor Adversarial Image Robustness ---")

	# 1. Null image
	var null_chart = OMRProcessorScript.process_image_data(null)
	assert_true(null_chart.get("notes", []).is_empty(), "Null Image must return chart with empty notes array")

	# 2. Tiny image (<32px)
	var tiny_img = Image.create(16, 16, false, Image.FORMAT_L8)
	var tiny_chart = OMRProcessorScript.process_image_data(tiny_img)
	assert_true(tiny_chart.get("notes", []).is_empty(), "Tiny image (16x16) must return chart with empty notes array")

	# 3. Pure black image (1600x900)
	var black_img = Image.create(1600, 900, false, Image.FORMAT_L8)
	black_img.fill(Color(0, 0, 0, 1))
	var black_chart = OMRProcessorScript.process_image_data(black_img)
	assert_true(black_chart.get("notes", []).is_empty(), "All-black image must return empty chart without crash")

	# 4. Pure white image (1600x900)
	var white_img = Image.create(1600, 900, false, Image.FORMAT_L8)
	white_img.fill(Color(1, 1, 1, 1))
	var white_chart = OMRProcessorScript.process_image_data(white_img)
	assert_true(white_chart.get("notes", []).is_empty(), "All-white image must return empty chart without crash")

	# 5. Inverted sheet score polarity handling (test that dark_ratio > 0.50 inverts correctly)
	# Create synthetic image with dark background and white staff lines
	var inv_img = Image.create(1600, 900, false, Image.FORMAT_L8)
	inv_img.fill(Color(0.05, 0.05, 0.05, 1)) # Dark background (black)
	# Draw 10 white horizontal staff lines
	var treble_lines = [320, 340, 360, 380, 400]
	var bass_lines = [440, 460, 480, 500, 520]
	for ly in treble_lines + bass_lines:
		for x in range(100, 1500):
			inv_img.set_pixel(x, ly, Color(1, 1, 1, 1))

	var inv_chart = OMRProcessorScript.process_image_data(inv_img)
	assert_true(inv_chart is Dictionary, "Inverted polarity image must process into valid Dictionary without crash")
	assert_true(inv_chart.has("measures"), "Inverted chart contains measures key")
	assert_true(inv_chart.has("notes"), "Inverted chart contains notes key")

	# 6. Random noise image (checkerboard / hash pattern)
	var noise_img = Image.create(200, 200, false, Image.FORMAT_L8)
	for y in range(200):
		for x in range(200):
			var v = 1.0 if ((x ^ y) & 1 == 0) else 0.0
			noise_img.set_pixel(x, y, Color(v, v, v, 1))
	var noise_chart = OMRProcessorScript.process_image_data(noise_img)
	assert_true(noise_chart is Dictionary, "Noise image must be processed without throwing exception")
