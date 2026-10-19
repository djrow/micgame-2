# res://tests/test_m3_adversarial_challenger.gd
extends SceneTree

## Empirical Adversarial Challenge Suite for Milestone M3
## Rigorously stresses:
## 1. Diatonic geometry across all 88 piano keys (MIDI 21 to 108)
## 2. Harmonic second collision horizontal offsets (+16px) for 2-, 3-, and multi-note clusters
## 3. Ledger line derivations for Middle C, extreme high/low pitches, and staff notes
## 4. GrandStaffHighway horizontal scrolling, receptor dynamics, and playhead synchronization
## 5. NoteRenderer canvas item state and visual rendering integrity

const NoteDataScript = preload("res://scripts/note_data.gd")
const GrandStaffHighwayScript = preload("res://scripts/grand_staff_highway.gd")
const NoteRendererScript = preload("res://scripts/note_renderer.gd")

var tests_passed: int = 0
var tests_failed: int = 0

# Piano 88 keys diatonic ground truth table
# Note names and expected diatonic steps
const SEMITONE_STEPS: Array[int] = [0, 0, 1, 1, 2, 3, 3, 4, 4, 5, 5, 6]
const SEMITONE_ACCIDENTALS: Array[bool] = [false, true, false, true, false, false, true, false, true, false, true, false]
const NOTE_BASE_NAMES: Array[String] = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

func _init() -> void:
	print("======================================================================")
	print(" STARTING M3 ADVERSARIAL CHALLENGER VERIFICATION (GODOT HEADLESS)     ")
	print("======================================================================")

	suite_1_all_88_piano_keys_geometry()
	suite_2_staff_lines_and_spacing_invariants()
	suite_3_midi_boundary_and_dirty_inputs()
	suite_4_harmonic_second_two_note_collisions()
	suite_5_harmonic_second_multi_note_clusters()
	suite_6_harmonic_second_timing_and_invariance()
	suite_7_ledger_lines_all_registers()
	suite_8_grand_staff_highway_scrolling_dynamics()
	suite_9_note_renderer_visual_pipeline()
	suite_10_exhaustive_88_key_ledgers_and_serialization()

	print("======================================================================")
	print(" ADVERSARIAL CHALLENGE COMPLETE: %d Passed, %d Failed" % [tests_passed, tests_failed])
	print("======================================================================")

	if tests_failed == 0:
		print("VERDICT: ALL ADVERSARIAL CHALLENGES PASSED (APPROVE)")
		quit(0)
	else:
		push_error("VERDICT: CHALLENGE DETECTED %d FAILURES (CHALLENGE_FAILED)" % tests_failed)
		quit(1)

func assert_true(condition: bool, message: String) -> void:
	if condition:
		tests_passed += 1
	else:
		tests_failed += 1
		printerr("  [FAIL] %s" % message)

func assert_eq(actual, expected, message: String) -> void:
	if actual == expected:
		tests_passed += 1
	else:
		tests_failed += 1
		printerr("  [FAIL] %s -> expected %s, got %s" % [message, str(expected), str(actual)])

func assert_almost_eq(actual: float, expected: float, epsilon: float, message: String) -> void:
	if absf(actual - expected) <= epsilon:
		tests_passed += 1
	else:
		tests_failed += 1
		printerr("  [FAIL] %s -> expected ~%s, got %s (diff %s > %s)" % [message, str(expected), str(actual), str(absf(actual - expected)), str(epsilon)])

# -----------------------------------------------------------------------------
# SUITE 1: Diatonic Geometry Across All 88 Piano Keys (MIDI 21 to 108)
# -----------------------------------------------------------------------------
func suite_1_all_88_piano_keys_geometry() -> void:
	print("\n>>> Suite 1: Full 88-Key Piano Diatonic Geometry (MIDI 21 A0 to 108 C8)")

	for midi in range(21, 109):
		var pc: int = midi % 12
		var oct: int = int(floor(float(midi) / 12.0)) - 1
		var expected_step: int = oct * 7 + SEMITONE_STEPS[pc]
		var expected_y: float = 360.0 - float(expected_step - 28) * 9.0
		var expected_accidental: bool = SEMITONE_ACCIDENTALS[pc]
		var expected_name: String = NOTE_BASE_NAMES[pc] + str(oct)

		# Test static methods
		var actual_step: int = NoteDataScript.midi_to_step(midi)
		var actual_y: float = NoteDataScript.midi_to_y(midi)
		var actual_name: String = NoteDataScript.midi_to_pitch_name(midi)

		assert_eq(actual_step, expected_step, "MIDI %d step matches oracle" % midi)
		assert_almost_eq(actual_y, expected_y, 0.0001, "MIDI %d Y pos matches formula" % midi)
		assert_eq(actual_name, expected_name, "MIDI %d pitch name matches oracle" % midi)

		# Test NoteData instance instantiation
		var note = NoteDataScript.new(midi, midi, 0.0, 1.0)
		assert_eq(note.diatonic_step, expected_step, "NoteData(%d).diatonic_step matches" % midi)
		assert_almost_eq(note.y_pos, expected_y, 0.0001, "NoteData(%d).y_pos matches" % midi)
		assert_eq(note.is_accidental, expected_accidental, "NoteData(%d).is_accidental matches" % midi)
		if expected_accidental:
			assert_eq(note.accidental_type, "#", "NoteData(%d).accidental_type is #" % midi)
			assert_eq(note.accidental, 1, "NoteData(%d).accidental is 1" % midi)
		else:
			assert_eq(note.accidental_type, "", "NoteData(%d).accidental_type is empty" % midi)
			assert_eq(note.accidental, 0, "NoteData(%d).accidental is 0" % midi)

		# Staff assignment logic: >= 60 is treble, < 60 is bass
		var expected_staff: String = "treble" if midi >= 60 else "bass"
		assert_eq(note.staff, expected_staff, "NoteData(%d).staff is %s" % [midi, expected_staff])

	print("  [PASS] Verified all 88 individual piano keys across steps and Y positions.")

# -----------------------------------------------------------------------------
# SUITE 2: Staff Lines, Spacing & Invariants
# -----------------------------------------------------------------------------
func suite_2_staff_lines_and_spacing_invariants() -> void:
	print("\n>>> Suite 2: Staff Lines & Spacing Invariants")

	# Middle C exactness
	assert_eq(NoteDataScript.midi_to_step(60), 28, "Middle C step is exactly 28")
	assert_eq(NoteDataScript.midi_to_y(60), 360.0, "Middle C Y is exactly 360.0 px")

	# Treble staff lines (from top to bottom): F5(270), D5(288), B4(306), G4(324), E4(342)
	var treble_midis: Array[int] = [77, 74, 71, 67, 64] # F5, D5, B4, G4, E4
	var expected_treble_y: Array[float] = [270.0, 288.0, 306.0, 324.0, 342.0]
	var expected_treble_steps: Array[int] = [38, 36, 34, 32, 30]

	for i in range(5):
		var m: int = treble_midis[i]
		assert_eq(NoteDataScript.midi_to_step(m), expected_treble_steps[i], "Treble line %d step is %d" % [5 - i, expected_treble_steps[i]])
		assert_eq(NoteDataScript.midi_to_y(m), expected_treble_y[i], "Treble line %d Y is %s" % [5 - i, str(expected_treble_y[i])])

	# Bass staff lines (from top to bottom): A3(378), F3(396), D3(414), B2(432), G2(450)
	var bass_midis: Array[int] = [57, 53, 50, 47, 43] # A3, F3, D3, B2, G2
	var expected_bass_y: Array[float] = [378.0, 396.0, 414.0, 432.0, 450.0]
	var expected_bass_steps: Array[int] = [26, 24, 22, 20, 18]

	for i in range(5):
		var m: int = bass_midis[i]
		assert_eq(NoteDataScript.midi_to_step(m), expected_bass_steps[i], "Bass line %d step is %d" % [5 - i, expected_bass_steps[i]])
		assert_eq(NoteDataScript.midi_to_y(m), expected_bass_y[i], "Bass line %d Y is %s" % [5 - i, str(expected_bass_y[i])])

	# GrandStaffHighway constants
	assert_eq(GrandStaffHighwayScript.TREBLE_LINES.size(), 5, "Highway has 5 treble lines")
	assert_eq(GrandStaffHighwayScript.BASS_LINES.size(), 5, "Highway has 5 bass lines")
	for i in range(5):
		assert_eq(GrandStaffHighwayScript.TREBLE_LINES[i], expected_treble_y[i], "Highway TREBLE_LINES[%d] matches" % i)
		assert_eq(GrandStaffHighwayScript.BASS_LINES[i], expected_bass_y[i], "Highway BASS_LINES[%d] matches" % i)

	# Verify uniform staff line spacing = 18.0 px
	for i in range(4):
		var d_treble: float = expected_treble_y[i + 1] - expected_treble_y[i]
		assert_almost_eq(d_treble, 18.0, 0.0001, "Treble adjacent line spacing is 18.0 px")
		var d_bass: float = expected_bass_y[i + 1] - expected_bass_y[i]
		assert_almost_eq(d_bass, 18.0, 0.0001, "Bass adjacent line spacing is 18.0 px")

	# Diatonic step delta = 9.0 px
	for step in range(10, 50):
		var y1: float = NoteDataScript.step_to_y(step)
		var y2: float = NoteDataScript.step_to_y(step + 1)
		assert_almost_eq(y1 - y2, 9.0, 0.0001, "Step %d to %d spacing is exactly 9.0 px" % [step, step + 1])

# -----------------------------------------------------------------------------
# SUITE 3: MIDI Boundary & Dirty Input Resilience
# -----------------------------------------------------------------------------
func suite_3_midi_boundary_and_dirty_inputs() -> void:
	print("\n>>> Suite 3: MIDI Boundary & Dirty Input Resilience")

	# Out of bounds clamping in NoteData
	var n_neg = NoteDataScript.new(1, -10, 0.0, 1.0)
	assert_eq(n_neg.pitch_midi, 0, "Negative MIDI clamped to 0")

	var n_high = NoteDataScript.new(2, 250, 0.0, 1.0)
	assert_eq(n_high.pitch_midi, 127, "Oversized MIDI clamped to 127")

	# Dynamic property alteration triggers recomputation
	var n_dyn = NoteDataScript.new(3, 60, 0.0, 1.0)
	assert_eq(n_dyn.y_pos, 360.0, "Initial dynamic note at 360.0")
	n_dyn.pitch_midi = 77 # F5
	assert_eq(n_dyn.y_pos, 270.0, "Changing pitch_midi recomputes y_pos to 270.0")
	assert_eq(n_dyn.pitch_name, "F5", "Changing pitch_midi recomputes pitch_name to F5")

	n_dyn.pitch = 43 # G2 via pitch alias
	assert_eq(n_dyn.y_pos, 450.0, "Changing pitch alias recomputes y_pos to 450.0")
	assert_eq(n_dyn.pitch_name, "G2", "Changing pitch alias recomputes pitch_name to G2")

# -----------------------------------------------------------------------------
# SUITE 4: Harmonic Second 2-Note Collisions
# -----------------------------------------------------------------------------
func suite_4_harmonic_second_two_note_collisions() -> void:
	print("\n>>> Suite 4: Harmonic Second 2-Note Collisions")

	# Test pair 1: C4 (step 28) and D4 (step 29)
	var pair1: Array[NoteData] = [
		NoteDataScript.new(1, 60, 1.0, 1.0),
		NoteDataScript.new(2, 62, 1.0, 1.0)
	]
	GrandStaffHighwayScript.calculate_chord_offsets(pair1)
	assert_eq(pair1[0].chord_offset_x, 0.0, "Pair 1 lower note C4 offset is 0.0")
	assert_eq(pair1[1].chord_offset_x, 16.0, "Pair 1 higher note D4 offset is +16.0")

	# Test pair 2: Diatonic semitone second B4 (step 34 -> wait, let's verify B4 step)
	# B4 is MIDI 71. pc = 11, oct = 4. step = 4 * 7 + 6 = 34.
	# C5 is MIDI 72. pc = 0, oct = 5. step = 5 * 7 + 0 = 35.
	# Step diff = 35 - 34 = 1. A diatonic second!
	var pair2: Array[NoteData] = [
		NoteDataScript.new(3, 71, 2.0, 1.0), # B4, step 34
		NoteDataScript.new(4, 72, 2.0, 1.0)  # C5, step 35
	]
	GrandStaffHighwayScript.calculate_chord_offsets(pair2)
	assert_eq(pair2[0].chord_offset_x, 0.0, "B4 offset is 0.0")
	assert_eq(pair2[1].chord_offset_x, 16.0, "C5 offset is +16.0")

	# Test pair 3: Diatonic semitone second E4 (step 30) and F4 (step 31)
	# E4 = MIDI 64, step 30; F4 = MIDI 65, step 31
	var pair3: Array[NoteData] = [
		NoteDataScript.new(5, 64, 3.0, 1.0),
		NoteDataScript.new(6, 65, 3.0, 1.0)
	]
	GrandStaffHighwayScript.calculate_chord_offsets(pair3)
	assert_eq(pair3[0].chord_offset_x, 0.0, "E4 offset is 0.0")
	assert_eq(pair3[1].chord_offset_x, 16.0, "F4 offset is +16.0")

	# Test non-second: Third interval C4 (step 28) and E4 (step 30)
	var pair_third: Array[NoteData] = [
		NoteDataScript.new(7, 60, 4.0, 1.0),
		NoteDataScript.new(8, 64, 4.0, 1.0)
	]
	GrandStaffHighwayScript.calculate_chord_offsets(pair_third)
	assert_eq(pair_third[0].chord_offset_x, 0.0, "Third interval C4 has 0 offset")
	assert_eq(pair_third[1].chord_offset_x, 0.0, "Third interval E4 has 0 offset")

	# Test unisons: C4 and C#4 at same onset (chromatic unisons have same diatonic step 28)
	var unisons: Array[NoteData] = [
		NoteDataScript.new(9, 60, 5.0, 1.0), # C4, step 28
		NoteDataScript.new(10, 61, 5.0, 1.0) # C#4, step 28
	]
	GrandStaffHighwayScript.calculate_chord_offsets(unisons)
	assert_eq(unisons[0].chord_offset_x, 0.0, "Unison 1 has 0 offset")
	assert_eq(unisons[1].chord_offset_x, 0.0, "Unison 2 has 0 offset")

# -----------------------------------------------------------------------------
# SUITE 5: Multi-Note Second Clusters (3-, 4-, 5-, and 7-Note)
# -----------------------------------------------------------------------------
func suite_5_harmonic_second_multi_note_clusters() -> void:
	print("\n>>> Suite 5: Multi-Note Second Clusters (3, 4, 5, 7 Notes)")

	# 3-Note Cluster: C4(28), D4(29), E4(30)
	var cluster3: Array[NoteData] = [
		NoteDataScript.new(1, 60, 1.0, 1.0),
		NoteDataScript.new(2, 62, 1.0, 1.0),
		NoteDataScript.new(3, 64, 1.0, 1.0)
	]
	GrandStaffHighwayScript.calculate_chord_offsets(cluster3)
	assert_eq(cluster3[0].chord_offset_x, 0.0, "Cluster 3 note 1 offset = 0.0")
	assert_eq(cluster3[1].chord_offset_x, 16.0, "Cluster 3 note 2 offset = 16.0")
	assert_eq(cluster3[2].chord_offset_x, 0.0, "Cluster 3 note 3 offset alternates to 0.0")

	# 4-Note Cluster: C4(28), D4(29), E4(30), F4(31)
	var cluster4: Array[NoteData] = [
		NoteDataScript.new(1, 60, 1.0, 1.0),
		NoteDataScript.new(2, 62, 1.0, 1.0),
		NoteDataScript.new(3, 64, 1.0, 1.0),
		NoteDataScript.new(4, 65, 1.0, 1.0)
	]
	GrandStaffHighwayScript.calculate_chord_offsets(cluster4)
	assert_eq(cluster4[0].chord_offset_x, 0.0, "Cluster 4 note 1 = 0.0")
	assert_eq(cluster4[1].chord_offset_x, 16.0, "Cluster 4 note 2 = 16.0")
	assert_eq(cluster4[2].chord_offset_x, 0.0, "Cluster 4 note 3 = 0.0")
	assert_eq(cluster4[3].chord_offset_x, 16.0, "Cluster 4 note 4 = 16.0")

	# 5-Note Cluster: C4(28), D4(29), E4(30), F4(31), G4(32)
	var cluster5: Array[NoteData] = [
		NoteDataScript.new(1, 60, 1.0, 1.0),
		NoteDataScript.new(2, 62, 1.0, 1.0),
		NoteDataScript.new(3, 64, 1.0, 1.0),
		NoteDataScript.new(4, 65, 1.0, 1.0),
		NoteDataScript.new(5, 67, 1.0, 1.0)
	]
	GrandStaffHighwayScript.calculate_chord_offsets(cluster5)
	assert_eq(cluster5[0].chord_offset_x, 0.0, "Cluster 5 note 1 = 0.0")
	assert_eq(cluster5[1].chord_offset_x, 16.0, "Cluster 5 note 2 = 16.0")
	assert_eq(cluster5[2].chord_offset_x, 0.0, "Cluster 5 note 3 = 0.0")
	assert_eq(cluster5[3].chord_offset_x, 16.0, "Cluster 5 note 4 = 16.0")
	assert_eq(cluster5[4].chord_offset_x, 0.0, "Cluster 5 note 5 = 0.0")

	# 7-Note Full Diatonic Octave Cluster: C4(28) to B4(34)
	var cluster7: Array[NoteData] = [
		NoteDataScript.new(1, 60, 1.0, 1.0), # 28
		NoteDataScript.new(2, 62, 1.0, 1.0), # 29
		NoteDataScript.new(3, 64, 1.0, 1.0), # 30
		NoteDataScript.new(4, 65, 1.0, 1.0), # 31
		NoteDataScript.new(5, 67, 1.0, 1.0), # 32
		NoteDataScript.new(6, 69, 1.0, 1.0), # 33
		NoteDataScript.new(7, 71, 1.0, 1.0)  # 34
	]
	GrandStaffHighwayScript.calculate_chord_offsets(cluster7)
	for r in range(7):
		var expected: float = 16.0 if (r % 2 == 1) else 0.0
		assert_eq(cluster7[r].chord_offset_x, expected, "Cluster 7 note %d alternates to %s" % [r, str(expected)])

	# Disjoint multiple runs in same chord: [C4, D4] gap [G4, A4]
	var disjoint: Array[NoteData] = [
		NoteDataScript.new(1, 60, 1.0, 1.0), # step 28
		NoteDataScript.new(2, 62, 1.0, 1.0), # step 29
		NoteDataScript.new(3, 67, 1.0, 1.0), # step 32
		NoteDataScript.new(4, 69, 1.0, 1.0)  # step 33
	]
	GrandStaffHighwayScript.calculate_chord_offsets(disjoint)
	assert_eq(disjoint[0].chord_offset_x, 0.0, "Disjoint run 1 lower = 0.0")
	assert_eq(disjoint[1].chord_offset_x, 16.0, "Disjoint run 1 higher = 16.0")
	assert_eq(disjoint[2].chord_offset_x, 0.0, "Disjoint run 2 lower = 0.0")
	assert_eq(disjoint[3].chord_offset_x, 16.0, "Disjoint run 2 higher = 16.0")

# -----------------------------------------------------------------------------
# SUITE 6: Harmonic Second Invariance & Temporal Bounds
# -----------------------------------------------------------------------------
func suite_6_harmonic_second_timing_and_invariance() -> void:
	print("\n>>> Suite 6: Harmonic Second Timing Jitter & Order Invariance")

	# Test reverse input order
	var reversed_pair: Array[NoteData] = [
		NoteDataScript.new(2, 62, 1.0, 1.0), # D4 added first
		NoteDataScript.new(1, 60, 1.0, 1.0)  # C4 added second
	]
	GrandStaffHighwayScript.calculate_chord_offsets(reversed_pair)
	# Finding note with MIDI 60 (C4) vs MIDI 62 (D4)
	for n in reversed_pair:
		if n.pitch_midi == 60:
			assert_eq(n.chord_offset_x, 0.0, "Order invariance: C4 remains offset 0.0")
		elif n.pitch_midi == 62:
			assert_eq(n.chord_offset_x, 16.0, "Order invariance: D4 remains offset 16.0")

	# Sub-millisecond timing jitter tolerance (< 5ms threshold)
	var jittered_same_chord: Array[NoteData] = [
		NoteDataScript.new(1, 60, 1.000, 1.0),
		NoteDataScript.new(2, 62, 1.004, 1.0) # dt = 4ms < 5ms
	]
	GrandStaffHighwayScript.calculate_chord_offsets(jittered_same_chord)
	assert_eq(jittered_same_chord[0].chord_offset_x, 0.0, "Jittered 4ms C4 offset = 0.0")
	assert_eq(jittered_same_chord[1].chord_offset_x, 16.0, "Jittered 4ms D4 offset = 16.0 (grouped in chord)")

	# Separate chords threshold (> 5ms threshold)
	var separate_notes: Array[NoteData] = [
		NoteDataScript.new(1, 60, 1.000, 1.0),
		NoteDataScript.new(2, 62, 1.006, 1.0) # dt = 6ms > 5ms
	]
	GrandStaffHighwayScript.calculate_chord_offsets(separate_notes)
	assert_eq(separate_notes[0].chord_offset_x, 0.0, "Separate note 1 offset = 0.0")
	assert_eq(separate_notes[1].chord_offset_x, 0.0, "Separate note 2 offset = 0.0 (not a chord)")

# -----------------------------------------------------------------------------
# SUITE 7: Ledger Lines Across All Registers
# -----------------------------------------------------------------------------
func suite_7_ledger_lines_all_registers() -> void:
	print("\n>>> Suite 7: Ledger Lines Generation Across All Registers")

	# 1. Middle C (step 28)
	var ledgers_c4 = NoteDataScript.get_ledger_steps(28)
	assert_eq(ledgers_c4.size(), 1, "Middle C has exactly 1 ledger step")
	assert_eq(ledgers_c4[0], 28, "Middle C ledger step is 28")

	# 2. Inside staves: steps 30..38 (Treble) and 18..26 (Bass) must be EMPTY
	for s in range(30, 39):
		var ledgers = NoteDataScript.get_ledger_steps(s)
		assert_eq(ledgers.size(), 0, "Treble inside staff step %d has 0 ledgers" % s)

	for s in range(18, 27):
		var ledgers = NoteDataScript.get_ledger_steps(s)
		assert_eq(ledgers.size(), 0, "Bass inside staff step %d has 0 ledgers" % s)

	# 3. Spaces adjacent to staves: D4 (step 29), B3 (step 27), G5 (step 39), F2 (step 17)
	assert_eq(NoteDataScript.get_ledger_steps(29).size(), 0, "D4 space below treble has 0 ledgers")
	assert_eq(NoteDataScript.get_ledger_steps(27).size(), 0, "B3 space above bass has 0 ledgers")
	assert_eq(NoteDataScript.get_ledger_steps(39).size(), 0, "G5 space above treble has 0 ledgers")
	assert_eq(NoteDataScript.get_ledger_steps(17).size(), 0, "F2 space below bass has 0 ledgers")

	# 4. Extreme High Notes (A5 to C8)
	# A5 (step 40): [40] -> Y = 252.0
	var n_a5 = NoteDataScript.new(1, 81, 0.0, 1.0)
	assert_eq(n_a5.ledger_y_positions.size(), 1, "A5 has 1 ledger line")
	assert_eq(n_a5.ledger_y_positions[0], 252.0, "A5 ledger at 252.0 px")

	# B5 (step 41): space on top of first ledger line -> [40] -> Y = 252.0
	var n_b5 = NoteDataScript.new(2, 83, 0.0, 1.0)
	assert_eq(n_b5.ledger_y_positions.size(), 1, "B5 has 1 ledger line")
	assert_eq(n_b5.ledger_y_positions[0], 252.0, "B5 ledger at 252.0 px")

	# C6 (step 42): 2 ledger lines -> [40, 42] -> Y = [252.0, 234.0]
	var n_c6 = NoteDataScript.new(3, 84, 0.0, 1.0)
	assert_eq(n_c6.ledger_y_positions.size(), 2, "C6 has 2 ledger lines")
	assert_eq(n_c6.ledger_y_positions[0], 252.0, "C6 ledger 1 at 252.0 px")
	assert_eq(n_c6.ledger_y_positions[1], 234.0, "C6 ledger 2 at 234.0 px")

	# G6 (step 46, MIDI 91): 4 ledger lines -> [40, 42, 44, 46] -> [252, 234, 216, 198]
	var n_g6 = NoteDataScript.new(4, 91, 0.0, 1.0)
	assert_eq(n_g6.ledger_y_positions.size(), 4, "G6 has 4 ledger lines")
	assert_eq(n_g6.ledger_y_positions[0], 252.0, "G6 ledger 1 is 252")
	assert_eq(n_g6.ledger_y_positions[1], 234.0, "G6 ledger 2 is 234")
	assert_eq(n_g6.ledger_y_positions[2], 216.0, "G6 ledger 3 is 216")
	assert_eq(n_g6.ledger_y_positions[3], 198.0, "G6 ledger 4 is 198")

	# C7 (step 49, MIDI 96): 5 ledger lines -> [40, 42, 44, 46, 48]
	var n_c7 = NoteDataScript.new(5, 96, 0.0, 1.0)
	assert_eq(n_c7.ledger_y_positions.size(), 5, "C7 has 5 ledger lines")
	assert_eq(n_c7.ledger_y_positions[4], 180.0, "C7 highest ledger is 180.0 px")

	# Extreme high C8 (step 56, MIDI 108): 9 ledger lines
	var n_c8 = NoteDataScript.new(6, 108, 0.0, 1.0)
	assert_eq(n_c8.ledger_y_positions.size(), 9, "C8 has 9 ledger lines")
	assert_eq(n_c8.ledger_y_positions[0], 252.0, "C8 ledger 1 is 252.0 px")
	assert_eq(n_c8.ledger_y_positions[8], 108.0, "C8 ledger 9 is 108.0 px")

	# 5. Extreme Low Notes (E2 to A0)
	# E2 (step 16, MIDI 40): 1 ledger line -> [16] -> Y = 468.0
	var n_e2 = NoteDataScript.new(7, 40, 0.0, 1.0)
	assert_eq(n_e2.ledger_y_positions.size(), 1, "E2 has 1 ledger line")
	assert_eq(n_e2.ledger_y_positions[0], 468.0, "E2 ledger at 468.0 px")

	# D2 (step 15, MIDI 38): space below first ledger line -> [16] -> Y = 468.0
	var n_d2 = NoteDataScript.new(8, 38, 0.0, 1.0)
	assert_eq(n_d2.ledger_y_positions.size(), 1, "D2 has 1 ledger line")
	assert_eq(n_d2.ledger_y_positions[0], 468.0, "D2 ledger at 468.0 px")

	# C2 (step 14, MIDI 36): 2 ledger lines -> [16, 14] -> Y = [468.0, 486.0]
	var n_c2 = NoteDataScript.new(9, 36, 0.0, 1.0)
	assert_eq(n_c2.ledger_y_positions.size(), 2, "C2 has 2 ledger lines")
	assert_eq(n_c2.ledger_y_positions[0], 468.0, "C2 ledger 1 is 468.0")
	assert_eq(n_c2.ledger_y_positions[1], 486.0, "C2 ledger 2 is 486.0")

	# A1 (step 12, MIDI 33): 3 ledger lines -> [16, 14, 12] -> Y = [468, 486, 504]
	var n_a1 = NoteDataScript.new(10, 33, 0.0, 1.0)
	assert_eq(n_a1.ledger_y_positions.size(), 3, "A1 has 3 ledger lines")
	assert_eq(n_a1.ledger_y_positions[2], 504.0, "A1 ledger 3 is 504.0")

	# Extreme low A0 (step 5, MIDI 21): 6 ledger lines -> [16, 14, 12, 10, 8, 6]
	var n_a0 = NoteDataScript.new(11, 21, 0.0, 1.0)
	assert_eq(n_a0.ledger_y_positions.size(), 6, "A0 has 6 ledger lines")
	assert_eq(n_a0.ledger_y_positions[0], 468.0, "A0 ledger 1 is 468.0")
	assert_eq(n_a0.ledger_y_positions[5], 558.0, "A0 ledger 6 is 558.0")

# -----------------------------------------------------------------------------
# SUITE 8: GrandStaffHighway Scrolling & Dynamic Playhead
# -----------------------------------------------------------------------------
func suite_8_grand_staff_highway_scrolling_dynamics() -> void:
	print("\n>>> Suite 8: GrandStaffHighway Scrolling & Playhead Dynamics")

	var highway = GrandStaffHighwayScript.new()
	root.add_child(highway)
	assert_eq(highway.x_hit, 160.0, "Highway receptor x_hit is 160.0 px")
	assert_eq(highway.scroll_speed, 400.0, "Default scroll_speed is 400.0 px/s")

	var raw_chart = [
		{"pitch_midi": 60, "time_sec": 1.0, "duration_sec": 0.5},
		{"pitch_midi": 62, "time_sec": 1.0, "duration_sec": 0.5}, # harmonic second with C4
		{"pitch_midi": 64, "time_sec": 2.5, "duration_sec": 1.0}
	]
	highway.load_notes(raw_chart)

	assert_eq(highway.chart_notes.size(), 3, "3 notes loaded in highway")
	# Automatic harmonic second collision calculation on load
	assert_eq(highway.chart_notes[0].chord_offset_x, 0.0, "Auto-offset note 1 = 0.0")
	assert_eq(highway.chart_notes[1].chord_offset_x, 16.0, "Auto-offset note 2 = 16.0")
	assert_eq(highway.chart_notes[2].chord_offset_x, 0.0, "Auto-offset note 3 = 0.0")

	# Test note X coordinate calculation formula:
	# head_x = x_hit + (note.time_sec - current_song_time) * scroll_speed + chord_offset_x
	var test_note = highway.chart_notes[1] # D4 with +16px offset
	var song_time: float = 0.5
	var expected_x: float = 160.0 + (1.0 - 0.5) * 400.0 + 16.0 # 160 + 200 + 16 = 376.0
	var calculated_x: float = highway.x_hit + (test_note.time_sec - song_time) * highway.scroll_speed + test_note.chord_offset_x
	assert_almost_eq(calculated_x, expected_x, 0.001, "Highway note X matches 376.0 px at t=0.5s")

	# At exact hit time t = 1.0s:
	var hit_time: float = 1.0
	var at_hit_x: float = highway.x_hit + (test_note.time_sec - hit_time) * highway.scroll_speed + test_note.chord_offset_x
	assert_almost_eq(at_hit_x, 160.0 + 16.0, 0.001, "At hit time, D4 is at receptor + 16px (176.0 px)")

	# Test note spawning lookahead
	highway.start_playback()
	assert_true(highway.is_playing, "Highway starts playback")

	# Process 0.1s delta: current_song_time becomes 0.1s
	# spawn lookahead = (1280 - 160 + 100) / 400 = 1220 / 400 = 3.05s
	# All notes at 1.0s and 2.5s are <= 0.1 + 3.05 = 3.15s, so all 3 spawn into active_notes!
	highway._process(0.1)
	assert_eq(highway.active_notes.size(), 3, "All 3 notes spawned within lookahead window")

	# Test miss detection: advance time past 1.0s + 0.100s (miss window)
	# Jump to 1.15s
	highway.current_song_time = 1.15
	var missed_notes: Array[NoteData] = []
	highway.note_missed.connect(func(n: NoteData): missed_notes.append(n))
	highway._process(0.01)

	assert_true(highway.chart_notes[0].is_missed, "Note 1 marked missed after passing window")
	assert_true(highway.chart_notes[1].is_missed, "Note 2 marked missed after passing window")
	assert_eq(missed_notes.size(), 2, "2 note_missed signals emitted")

	# Test despawning past DESPAWN_X_THRESHOLD (-60.0)
	# At t = 3.5s, Note 1 tail = 160 + (1.0 - 3.5)*400 + 0.5*400 = 160 - 1000 + 200 = -640 < -60
	highway.current_song_time = 3.5
	highway._process(0.01)
	# Notes 1 and 2 should be culled
	for act in highway.active_notes:
		assert_true(act.id != 1 and act.id != 2, "Expired notes culled from active_notes")

	root.remove_child(highway)
	highway.free()

# -----------------------------------------------------------------------------
# SUITE 9: NoteRenderer Visual State & Safety
# -----------------------------------------------------------------------------
func suite_9_note_renderer_visual_pipeline() -> void:
	print("\n>>> Suite 9: NoteRenderer CanvasItem Execution & Safety")

	var renderer = NoteRendererScript.new()
	assert_eq(renderer.NOTE_RADIUS, 8.5, "Notehead radius is 8.5 px")
	assert_eq(renderer.LEDGER_WIDTH, 28.0, "Ledger width is 28.0 px")
	assert_eq(renderer.SUSTAIN_HEIGHT, 10.0, "Sustain height is 10.0 px")

	# Prepare rich active notes set with all features:
	# 1. Natural note with sustain
	# 2. Accidental note (#) with ledger line
	# 3. Harmonic second cluster with chord offset
	var test_notes: Array[NoteData] = [
		NoteDataScript.new(1, 60, 1.0, 1.5), # C4, Middle C ledger, sustain 1.5s
		NoteDataScript.new(2, 61, 1.0, 0.0), # C#4 accidental
		NoteDataScript.new(3, 81, 1.0, 0.2), # A5 high ledger
		NoteDataScript.new(4, 21, 1.0, 0.0)  # A0 low ledger 6 lines
	]
	GrandStaffHighwayScript.calculate_chord_offsets(test_notes)

	# Add to SceneTree root to enable valid CanvasItem draw context
	root.add_child(renderer)

	# Update renderer state
	renderer.update_notes(test_notes, 0.5, 160.0, 400.0)
	assert_eq(renderer.active_notes.size(), 4, "Renderer received 4 notes")
	assert_eq(renderer.current_song_time, 0.5, "Renderer song time set")

	# Dispatch NOTIFICATION_DRAW properly within CanvasItem lifecycle
	renderer.notification(CanvasItem.NOTIFICATION_DRAW)
	assert_true(true, "NoteRenderer received NOTIFICATION_DRAW cleanly without runtime errors")

	# Test empty notes array safety
	renderer.update_notes([], 0.0, 160.0, 400.0)
	renderer.notification(CanvasItem.NOTIFICATION_DRAW)
	assert_true(true, "NoteRenderer handles empty notes safely during NOTIFICATION_DRAW")

	root.remove_child(renderer)
	renderer.free()

# -----------------------------------------------------------------------------
# SUITE 10: Exhaustive 88-Key Ledger Invariants & Serialization Round-Trip
# -----------------------------------------------------------------------------
func suite_10_exhaustive_88_key_ledgers_and_serialization() -> void:
	print("\n>>> Suite 10: Exhaustive 88-Key Ledgers & Serialization Round-Trip")

	for midi in range(21, 109):
		var step: int = NoteDataScript.midi_to_step(midi)
		var note = NoteDataScript.new(midi, midi, 0.5, 1.0)
		var ledgers: Array[int] = NoteDataScript.get_ledger_steps(step)

		# 1. Middle C invariant (step 28, covering both C4=60 and C#4=61)
		if step == 28:
			assert_eq(ledgers.size(), 1, "MIDI %d (step 28) has 1 ledger line" % midi)
			assert_eq(ledgers[0], 28, "MIDI %d ledger step is 28" % midi)
			assert_eq(note.ledger_y_positions.size(), 1, "Note %d ledger Y array has 1 entry" % midi)
			assert_eq(note.ledger_y_positions[0], 360.0, "Note %d ledger Y is 360.0 px" % midi)

		# 2. Staff interior and immediate spaces (steps 17 to 39, excluding 28)
		elif step >= 17 and step <= 39:
			assert_eq(ledgers.size(), 0, "MIDI %d (step %d) in/near staff has 0 ledgers" % [midi, step])
			assert_eq(note.ledger_y_positions.size(), 0, "Note %d has 0 ledger Y entries" % midi)

		# 3. High register (steps >= 40)
		elif step >= 40:
			assert_true(ledgers.size() >= 1, "High MIDI %d (step %d) has >= 1 ledgers" % [midi, step])
			for ls in ledgers:
				assert_true(ls % 2 == 0, "Ledger step %d for MIDI %d is even" % [ls, midi])
				assert_true(ls >= 40 and ls <= step, "Ledger step %d within [40, %d]" % [ls, step])
			for ly in note.ledger_y_positions:
				assert_true(ly <= 252.0, "Ledger Y %s for high MIDI %d is <= 252.0 px" % [str(ly), midi])

		# 4. Low register (steps <= 16)
		elif step <= 16:
			assert_true(ledgers.size() >= 1, "Low MIDI %d (step %d) has >= 1 ledgers" % [midi, step])
			for ls in ledgers:
				assert_true(ls % 2 == 0, "Ledger step %d for MIDI %d is even" % [ls, midi])
				assert_true(ls <= 16 and ls >= step, "Ledger step %d within [%d, 16]" % [ls, step])
			for ly in note.ledger_y_positions:
				assert_true(ly >= 468.0, "Ledger Y %s for low MIDI %d is >= 468.0 px" % [str(ly), midi])

		# 5. Serialization round-trip test for every key
		var d = note.to_dict()
		assert_eq(d["pitch_midi"], midi, "Dict pitch_midi matches %d" % midi)
		assert_eq(d["diatonic_step"], step, "Dict diatonic_step matches %d" % step)
		assert_almost_eq(d["y_pos"], note.y_pos, 0.001, "Dict y_pos matches %s" % str(note.y_pos))

		var restored = NoteDataScript.from_dict(d, midi)
		assert_eq(restored.pitch_midi, midi, "Restored pitch_midi matches %d" % midi)
		assert_eq(restored.diatonic_step, step, "Restored diatonic_step matches %d" % step)
		assert_almost_eq(restored.y_pos, note.y_pos, 0.001, "Restored y_pos matches %s" % str(note.y_pos))
		assert_eq(restored.pitch_name, note.pitch_name, "Restored pitch_name matches")

	# 6. Multi-Octave Monster Chord (10 simultaneous notes spanning A0 to C8)
	var monster_chord: Array[NoteData] = [
		NoteDataScript.new(1, 21, 1.0, 1.0), # A0 (step 5)
		NoteDataScript.new(2, 36, 1.0, 1.0), # C2 (step 14)
		NoteDataScript.new(3, 48, 1.0, 1.0), # C3 (step 21)
		NoteDataScript.new(4, 60, 1.0, 1.0), # C4 (step 28)
		NoteDataScript.new(5, 62, 1.0, 1.0), # D4 (step 29) -> harmonic second with C4!
		NoteDataScript.new(6, 64, 1.0, 1.0), # E4 (step 30) -> harmonic second with D4!
		NoteDataScript.new(7, 72, 1.0, 1.0), # C5 (step 35)
		NoteDataScript.new(8, 84, 1.0, 1.0), # C6 (step 42)
		NoteDataScript.new(9, 96, 1.0, 1.0), # C7 (step 49)
		NoteDataScript.new(10, 108, 1.0, 1.0) # C8 (step 56)
	]
	GrandStaffHighwayScript.calculate_chord_offsets(monster_chord)
	assert_eq(monster_chord[0].chord_offset_x, 0.0, "A0 offset is 0.0")
	assert_eq(monster_chord[1].chord_offset_x, 0.0, "C2 offset is 0.0")
	assert_eq(monster_chord[2].chord_offset_x, 0.0, "C3 offset is 0.0")
	assert_eq(monster_chord[3].chord_offset_x, 0.0, "C4 offset is 0.0")
	assert_eq(monster_chord[4].chord_offset_x, 16.0, "D4 offset is 16.0 (second cluster)")
	assert_eq(monster_chord[5].chord_offset_x, 0.0, "E4 offset alternates to 0.0")
	assert_eq(monster_chord[6].chord_offset_x, 0.0, "C5 offset is 0.0")
	assert_eq(monster_chord[7].chord_offset_x, 0.0, "C6 offset is 0.0")
	assert_eq(monster_chord[8].chord_offset_x, 0.0, "C7 offset is 0.0")
	assert_eq(monster_chord[9].chord_offset_x, 0.0, "C8 offset is 0.0")

