extends SceneTree

## Independent Forensic Verification for M2
## Tests unexpected and boundary inputs on NativePitchDetector and InferenceService

var checks: int = 0
var failures: int = 0

func assert_check(condition: bool, message: String) -> void:
	checks += 1
	if condition:
		print("  [PASS] " + message)
	else:
		failures += 1
		printerr("  [FAIL] " + message)

func _init() -> void:
	print("==================================================")
	print("STARTING AUDITOR INDEPENDENT EMPIRICAL M2 TESTS")
	print("==================================================")

	var DetScript = load("res://scripts/inference/native_pitch_detector.gd")
	var detector = DetScript.new(22050.0)

	# 1. Pure Silence Test
	detector.reset()
	var silence := PackedFloat32Array()
	silence.resize(2048)
	silence.fill(0.0)
	detector.push_audio_samples(silence)
	var pitches = detector.get_detected_pitches()
	assert_check(pitches.is_empty(), "Pure silence produces empty pitch array: %s" % str(pitches))

	# 2. Pure Sub-Gate Noise (amp = 0.002, RMS < 0.005)
	detector.reset()
	var sub_noise := PackedFloat32Array()
	sub_noise.resize(2048)
	for i in range(2048):
		sub_noise[i] = 0.002 * (float((i * 101) % 1000) / 500.0 - 1.0)
	detector.push_audio_samples(sub_noise)
	pitches = detector.get_detected_pitches()
	assert_check(pitches.is_empty(), "Sub-gate noise is rejected: %s" % str(pitches))

	# 3. Pure A4 = 440 Hz (MIDI 69)
	detector.reset()
	var a4_buf := PackedFloat32Array()
	a4_buf.resize(2048)
	for i in range(2048):
		var t = float(i) / 22050.0
		a4_buf[i] = 0.25 * sin(TAU * 440.0 * t)
	detector.push_audio_samples(a4_buf)
	pitches = detector.get_detected_pitches()
	assert_check(pitches == [69], "Pure A4 (440 Hz) produces strictly [69]: %s" % str(pitches))

	# 4. Pure C4 = 261.63 Hz (MIDI 60)
	detector.reset()
	var c4_buf := PackedFloat32Array()
	c4_buf.resize(2048)
	var freq_c4 = 440.0 * pow(2.0, float(60 - 69) / 12.0)
	for i in range(2048):
		var t = float(i) / 22050.0
		c4_buf[i] = 0.25 * sin(TAU * freq_c4 * t)
	detector.push_audio_samples(c4_buf)
	pitches = detector.get_detected_pitches()
	assert_check(pitches == [60], "Pure C4 (261.63 Hz) produces strictly [60]: %s" % str(pitches))

	# 5. Pure G4 = 392.00 Hz (MIDI 67)
	detector.reset()
	var g4_buf := PackedFloat32Array()
	g4_buf.resize(2048)
	var freq_g4 = 440.0 * pow(2.0, float(67 - 69) / 12.0)
	for i in range(2048):
		var t = float(i) / 22050.0
		g4_buf[i] = 0.25 * sin(TAU * freq_g4 * t)
	detector.push_audio_samples(g4_buf)
	pitches = detector.get_detected_pitches()
	assert_check(pitches == [67], "Pure G4 (392.00 Hz) produces strictly [67]: %s" % str(pitches))

	# 6. Low Boundary Note: C2 = 65.41 Hz (MIDI 36)
	detector.reset()
	var c2_buf := PackedFloat32Array()
	c2_buf.resize(2048)
	var freq_c2 = 440.0 * pow(2.0, float(36 - 69) / 12.0)
	for i in range(2048):
		var t = float(i) / 22050.0
		c2_buf[i] = 0.35 * sin(TAU * freq_c2 * t)
	detector.push_audio_samples(c2_buf)
	pitches = detector.get_detected_pitches()
	assert_check(pitches.has(36), "Low boundary C2 (MIDI 36) detected: %s" % str(pitches))

	# 7. High Boundary Note: C6 = 1046.50 Hz (MIDI 84)
	detector.reset()
	var c6_buf := PackedFloat32Array()
	c6_buf.resize(2048)
	var freq_c6 = 440.0 * pow(2.0, float(84 - 69) / 12.0)
	for i in range(2048):
		var t = float(i) / 22050.0
		c6_buf[i] = 0.25 * sin(TAU * freq_c6 * t)
	detector.push_audio_samples(c6_buf)
	pitches = detector.get_detected_pitches()
	assert_check(pitches.has(84), "High boundary C6 (MIDI 84) detected: %s" % str(pitches))

	# 8. Dyad (Two Notes): C4 + G4 (MIDI 60, 67)
	detector.reset()
	var dyad_buf := PackedFloat32Array()
	dyad_buf.resize(2048)
	for i in range(2048):
		var t = float(i) / 22050.0
		dyad_buf[i] = 0.15 * sin(TAU * freq_c4 * t) + 0.15 * sin(TAU * freq_g4 * t)
	detector.push_audio_samples(dyad_buf)
	pitches = detector.get_detected_pitches()
	assert_check(pitches == [60, 67], "Dyad C4+G4 [60, 67] produces strictly [60, 67]: %s" % str(pitches))

	# 9. Triad: E Major (E4=64, G#4=68, B4=71)
	detector.reset()
	var e_maj_buf := PackedFloat32Array()
	e_maj_buf.resize(2048)
	var f_e4 = 440.0 * pow(2.0, float(64 - 69) / 12.0)
	var f_gs4 = 440.0 * pow(2.0, float(68 - 69) / 12.0)
	var f_b4 = 440.0 * pow(2.0, float(71 - 69) / 12.0)
	for i in range(2048):
		var t = float(i) / 22050.0
		e_maj_buf[i] = 0.10 * sin(TAU * f_e4 * t) + 0.10 * sin(TAU * f_gs4 * t) + 0.10 * sin(TAU * f_b4 * t)
	detector.push_audio_samples(e_maj_buf)
	pitches = detector.get_detected_pitches()
	assert_check(pitches == [64, 68, 71], "E Major Triad [64, 68, 71] produces strictly [64, 68, 71]: %s" % str(pitches))

	# 10. Chord: C Major Triad [60, 64, 67]
	detector.reset()
	var c_maj_buf := PackedFloat32Array()
	c_maj_buf.resize(2048)
	var f_e4_c = 440.0 * pow(2.0, float(64 - 69) / 12.0)
	for i in range(2048):
		var t = float(i) / 22050.0
		c_maj_buf[i] = 0.10 * sin(TAU * freq_c4 * t) + 0.10 * sin(TAU * f_e4_c * t) + 0.10 * sin(TAU * freq_g4 * t)
	detector.push_audio_samples(c_maj_buf)
	pitches = detector.get_detected_pitches()
	assert_check(pitches == [60, 64, 67], "C Major Triad [60, 64, 67] produces strictly [60, 64, 67]: %s" % str(pitches))

	# 11. InferenceService dynamic routing
	var InfScript = load("res://scripts/inference_service.gd")
	var inf = InfScript.new()
	inf.set_tier(inf.ModelTier.GD_DSP)
	var inf_sr: float = float(AudioServer.get_mix_rate())
	if inf_sr <= 0.0:
		inf_sr = 48000.0
	var inf_a4 := PackedFloat32Array()
	inf_a4.resize(2048)
	for i in range(2048):
		var t = float(i) / inf_sr
		inf_a4[i] = 0.25 * sin(TAU * 440.0 * t)
	inf.push_audio_samples(inf_a4)
	var inf_pitches = inf.get_active_pitches()
	assert_check(inf_pitches == [69], "InferenceService dynamically routed A4 to GD_DSP producing [69]: %s" % str(inf_pitches))
	inf.push_audio_samples(silence)
	inf_pitches = inf.get_active_pitches()
	assert_check(inf_pitches.is_empty(), "InferenceService dynamically routed silence producing []: %s" % str(inf_pitches))


	print("\n==================================================")
	print("AUDITOR EMPIRICAL RESULTS: %d Passed, %d Failed" % [checks - failures, failures])
	print("==================================================")

	if failures == 0:
		print("AUDITOR VERIFICATION: 100% CLEAN & VERIFIED!")
		quit(0)
	else:
		printerr("AUDITOR VERIFICATION: %d FAILURES FOUND" % failures)
		quit(1)
