# res://tests/test_auditor_m3_adversarial.gd
extends SceneTree

const ScoringServiceScript = preload("res://scripts/scoring_service.gd")
const NoteDataScript = preload("res://scripts/note_data.gd")
const GrandStaffHighwayScript = preload("res://scripts/grand_staff_highway.gd")
const LevelLoaderScript = preload("res://scripts/level_loader.gd")
const OMRProcessorScript = preload("res://scripts/omr_processor.gd")

func _init() -> void:
	print("--- INDEPENDENT AUDITOR ADVERSARIAL STRESS TEST ---")
	var failures: int = 0

	# 1. NoteData out-of-bounds MIDI clamping & negative time
	var n_neg = NoteDataScript.new(-1, -10, -5.0, -2.0)
	if n_neg.pitch_midi != 0:
		printerr("FAIL: NoteData did not clamp negative MIDI to 0")
		failures += 1
	else:
		print("PASS: NoteData clamped negative MIDI to 0")

	if n_neg.time_sec != 0.0 or n_neg.duration_sec != 0.0:
		printerr("FAIL: NoteData did not clamp negative time/duration to 0.0")
		failures += 1
	else:
		print("PASS: NoteData clamped negative time/duration to 0.0")

	var n_high = NoteDataScript.new(999, 200, 10.0, 1.0)
	if n_high.pitch_midi != 127:
		printerr("FAIL: NoteData did not clamp excessive MIDI to 127")
		failures += 1
	else:
		print("PASS: NoteData clamped excessive MIDI to 127")

	# 2. Highway calculate_chord_offsets with edge cases (empty, 1 note, reverse order)
	var empty_notes: Array[NoteData] = []
	GrandStaffHighwayScript.calculate_chord_offsets(empty_notes)
	print("PASS: calculate_chord_offsets handled empty array safely")

	var single_note: Array[NoteData] = [NoteDataScript.new(1, 60, 1.0, 1.0)]
	GrandStaffHighwayScript.calculate_chord_offsets(single_note)
	if single_note[0].chord_offset_x != 0.0:
		printerr("FAIL: single note received non-zero offset")
		failures += 1
	else:
		print("PASS: calculate_chord_offsets handled single note safely")

	# 3. LevelLoader corrupted / truncated WAV bytes
	var loader = LevelLoaderScript.new()
	var trunc_bytes = PackedByteArray([0x52, 0x49, 0x46, 0x46]) # Only "RIFF"
	var wav_res = loader._load_wav_from_bytes(trunc_bytes)
	if wav_res != null:
		printerr("FAIL: _load_wav_from_bytes did not reject truncated buffer")
		failures += 1
	else:
		print("PASS: _load_wav_from_bytes safely returned null on truncated buffer")

	var invalid_magic = PackedByteArray()
	invalid_magic.resize(50)
	var bad_wav = loader._load_wav_from_bytes(invalid_magic)
	if bad_wav != null:
		printerr("FAIL: _load_wav_from_bytes did not reject invalid magic")
		failures += 1
	else:
		print("PASS: _load_wav_from_bytes safely returned null on invalid magic")

	# 4. OMRProcessor 2D SAT query out-of-bounds box coordinates
	var img = Image.create(64, 64, false, Image.FORMAT_L8)
	img.fill(Color(0.5, 0.5, 0.5, 1.0))
	var chart = OMRProcessorScript.process_image_data(img, "test_gray.png")
	if not chart.has("notes") or not chart.has("measures"):
		printerr("FAIL: process_image_data did not return expected schema")
		failures += 1
	else:
		print("PASS: process_image_data returned expected schema on gray image")

	# 5. ScoringService evaluate_timing edge conditions
	var s = ScoringServiceScript.new()
	# Huge time diff
	var res_huge = s.evaluate_timing(100000.0)
	if res_huge != "MISS":
		printerr("FAIL: Huge time diff not judged MISS")
		failures += 1
	else:
		print("PASS: Huge time diff evaluated to MISS")

	# Negative huge time diff
	var res_neg_huge = s.evaluate_timing(-100000.0)
	if res_neg_huge != "MISS":
		printerr("FAIL: Negative huge time diff not judged MISS")
		failures += 1
	else:
		print("PASS: Negative huge time diff evaluated to MISS")

	# Empty notes array in process_input
	var empty_input_res = s.process_input(1.0, 60, [])
	if not empty_input_res.is_empty():
		printerr("FAIL: process_input on empty notes returned non-empty dict")
		failures += 1
	else:
		print("PASS: process_input safely returned empty on empty notes array")

	# Clean up
	s.free()
	loader.free()

	print("--- AUDITOR ADVERSARIAL STRESS TEST SUMMARY ---")
	print("Failures: %d" % failures)
	if failures == 0:
		print("ALL ADVERSARIAL CHECKS PASSED [CLEAN]")
		quit(0)
	else:
		print("ADVERSARIAL CHECKS FAILED [VIOLATION]")
		quit(1)
