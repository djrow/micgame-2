extends SceneTree

## Deep Adversarial Stress Harness for M2 Iteration 2
## Tests edge conditions: Negative DC, Asymmetric Waves, 44.1 kHz Triads,
## Dynamic Sample Rate switching, Low Boundaries, and Latency Spikes.

var checks: int = 0
var passes: int = 0
var failures: int = 0
var defect_log: Array[String] = []

func log_assert(condition: bool, test_name: String, details: String = "") -> void:
	checks += 1
	if condition:
		passes += 1
		print("  [PASS] %s%s" % [test_name, " (" + details + ")" if details != "" else ""])
	else:
		failures += 1
		var msg: String = "FAIL: %s%s" % [test_name, " -> " + details if details != "" else ""]
		defect_log.append(msg)
		printerr("  [FAIL] %s%s" % [test_name, " (" + details + ")" if details != "" else ""])

func _synth_audio(pitches: Array[int], sample_rate: float, num_samples: int, amp_per_voice: float, rich_overtones: bool = false, dc_offset: float = 0.0) -> PackedFloat32Array:
	var buf := PackedFloat32Array()
	buf.resize(num_samples)
	for i in range(num_samples):
		var t: float = float(i) / sample_rate
		var s: float = dc_offset
		for p in pitches:
			var f0: float = 440.0 * pow(2.0, float(p - 69) / 12.0)
			if rich_overtones:
				s += amp_per_voice * (0.70 * sin(TAU * f0 * t) + 0.20 * sin(TAU * f0 * 2.0 * t) + 0.10 * sin(TAU * f0 * 3.0 * t))
			else:
				s += amp_per_voice * sin(TAU * f0 * t)
		buf[i] = s
	return buf

func _init() -> void:
	print("==================================================================")
	print("M2 ITERATION 2 DEEP ADVERSARIAL STRESS PROBE")
	print("==================================================================")

	var detector_script = load("res://scripts/inference/native_pitch_detector.gd")
	if detector_script == null:
		printerr("CRITICAL: Cannot load native_pitch_detector.gd")
		quit(1)
		return

	test_suite_negative_and_extreme_dc(detector_script)
	test_suite_sample_rate_variations(detector_script)
	test_suite_boundary_tones(detector_script)
	test_suite_asymmetric_waveforms(detector_script)
	test_suite_performance_and_jitter(detector_script)

	print("\n==================================================================")
	print("DEEP CHALLENGER SUMMARY: %d Total Checks | %d Passed | %d Failed" % [checks, passes, failures])
	print("==================================================================")

	if failures > 0:
		print("\nCONFIRMED DEFECTS (%d):" % failures)
		for d in defect_log:
			printerr("  - " + d)
		print("\nFINAL VERDICT: CHALLENGE_FAILED")
		quit(1)
	else:
		print("\nFINAL VERDICT: APPROVE")
		quit(0)

# ------------------------------------------------------------------------------
# 1. Negative & Extreme DC Bias Rejection
# ------------------------------------------------------------------------------
func test_suite_negative_and_extreme_dc(detector_script: GDScript) -> void:
	print("\n--- 1. Negative & Extreme DC Bias Rejection ---")
	var detector = detector_script.new(48000.0)

	# Pure negative DC bias -0.30
	detector.reset()
	var neg_dc := PackedFloat32Array()
	neg_dc.resize(2048)
	neg_dc.fill(-0.30)
	detector.push_audio_samples(neg_dc)
	var res_neg_dc = detector.get_detected_pitches()
	log_assert(res_neg_dc.is_empty(), "Pure negative DC (-0.30) rejected by gate", "detected: %s" % str(res_neg_dc))

	# Pure large negative DC bias -0.85
	detector.reset()
	var large_neg_dc := PackedFloat32Array()
	large_neg_dc.resize(2048)
	large_neg_dc.fill(-0.85)
	detector.push_audio_samples(large_neg_dc)
	var res_large_neg_dc = detector.get_detected_pitches()
	log_assert(res_large_neg_dc.is_empty(), "Large negative DC (-0.85) rejected by gate", "detected: %s" % str(res_large_neg_dc))

	# Extreme DC bias +5.0 (out of nominal range)
	detector.reset()
	var extreme_dc := PackedFloat32Array()
	extreme_dc.resize(2048)
	extreme_dc.fill(5.0)
	detector.push_audio_samples(extreme_dc)
	var res_extreme_dc = detector.get_detected_pitches()
	log_assert(res_extreme_dc.is_empty(), "Extreme DC (+5.0) rejected by gate", "detected: %s" % str(res_extreme_dc))

	# Tone + Large Negative DC Offset: A4 (69) + (-0.50 DC)
	detector.reset()
	var tone_neg_dc = _synth_audio([69], 48000.0, 2048, 0.25, false, -0.50)
	detector.push_audio_samples(tone_neg_dc)
	var res_tone_neg_dc = detector.get_detected_pitches()
	log_assert(res_tone_neg_dc == [69], "A4 (69) detected in presence of -0.50 DC bias", "detected: %s" % str(res_tone_neg_dc))

	# Chord + DC Offset: C Major Triad [60, 64, 67] + (+0.35 DC)
	detector.reset()
	var chord_dc = _synth_audio([60, 64, 67], 48000.0, 2048, 0.10, false, 0.35)
	detector.push_audio_samples(chord_dc)
	var res_chord_dc = detector.get_detected_pitches()
	log_assert(res_chord_dc == [60, 64, 67], "C Major Triad [60, 64, 67] detected in presence of +0.35 DC bias", "detected: %s" % str(res_chord_dc))

# ------------------------------------------------------------------------------
# 2. Sample Rate Variations & 44.1 kHz Triads
# ------------------------------------------------------------------------------
func test_suite_sample_rate_variations(detector_script: GDScript) -> void:
	print("\n--- 2. Sample Rate Variations & 44.1 kHz Evaluation ---")
	
	# Test at 44.1 kHz (Standard CD audio rate)
	var det_44 = detector_script.new(44100.0)
	
	# A Minor [57, 60, 64] at 44.1 kHz
	det_44.reset()
	var a_min_44 = _synth_audio([57, 60, 64], 44100.0, 2048, 0.10)
	det_44.push_audio_samples(a_min_44)
	var res_a_min_44 = det_44.get_detected_pitches()
	log_assert(res_a_min_44 == [57, 60, 64], "44.1kHz A Minor Triad [57, 60, 64]", "detected: %s" % str(res_a_min_44))

	# F Major [53, 57, 60] at 44.1 kHz
	det_44.reset()
	var f_maj_44 = _synth_audio([53, 57, 60], 44100.0, 2048, 0.10)
	det_44.push_audio_samples(f_maj_44)
	var res_f_maj_44 = det_44.get_detected_pitches()
	log_assert(res_f_maj_44 == [53, 57, 60], "44.1kHz F Major Triad [53, 57, 60]", "detected: %s" % str(res_f_maj_44))

	# G Major [55, 59, 62] at 48 kHz
	var det_48 = detector_script.new(48000.0)
	det_48.reset()
	var g_maj_48 = _synth_audio([55, 59, 62], 48000.0, 2048, 0.10)
	det_48.push_audio_samples(g_maj_48)
	var res_g_maj_48 = det_48.get_detected_pitches()
	log_assert(res_g_maj_48 == [55, 59, 62], "48kHz G Major Triad [55, 59, 62]", "detected: %s" % str(res_g_maj_48))

	# Dynamic SR switch via push_audio_samples parameter
	det_48.reset()
	var c_maj_22 = _synth_audio([60, 64, 67], 22050.0, 2048, 0.10)
	det_48.push_audio_samples(c_maj_22, 22050.0)
	var res_switch = det_48.get_detected_pitches()
	log_assert(res_switch == [60, 64, 67], "Dynamic sample rate retargeting to 22.05 kHz detects [60, 64, 67]", "detected: %s" % str(res_switch))
	log_assert(absf(det_48.sample_rate - 22050.0) < 0.1, "Sample rate updated to 22050.0")

# ------------------------------------------------------------------------------
# 3. Boundary Tones & Lowest/Highest Bins
# ------------------------------------------------------------------------------
func test_suite_boundary_tones(detector_script: GDScript) -> void:
	print("\n--- 3. Boundary Tones & Range Limits ---")
	var detector = detector_script.new(48000.0)

	# Low boundary C2 (MIDI 36 = 65.41 Hz) at 48 kHz with mean subtraction
	detector.reset()
	var c2_buf = _synth_audio([36], 48000.0, 2048, 0.35)
	detector.push_audio_samples(c2_buf)
	var res_c2 = detector.get_detected_pitches()
	log_assert(res_c2.has(36), "Low boundary C2 (MIDI 36) detected at 48 kHz", "detected: %s" % str(res_c2))

	# High boundary C6 (MIDI 84 = 1046.50 Hz) at 48 kHz
	detector.reset()
	var c6_buf = _synth_audio([84], 48000.0, 2048, 0.35)
	detector.push_audio_samples(c6_buf)
	var res_c6 = detector.get_detected_pitches()
	log_assert(res_c6.has(84), "High boundary C6 (MIDI 84) detected at 48 kHz", "detected: %s" % str(res_c6))

# ------------------------------------------------------------------------------
# 4. Asymmetric Waveforms & Distortion
# ------------------------------------------------------------------------------
func test_suite_asymmetric_waveforms(detector_script: GDScript) -> void:
	print("\n--- 4. Asymmetric Waveforms & Distortion ---")
	var detector = detector_script.new(22050.0)

	# Half-wave rectified sine (C4, MIDI 60): s = max(0.0, sin(w*t))
	# Half-wave rectified has substantial DC component and even/odd harmonics
	detector.reset()
	var rectified := PackedFloat32Array()
	rectified.resize(2048)
	var f0 = 440.0 * pow(2.0, float(60 - 69) / 12.0)
	for i in range(2048):
		var t = float(i) / 22050.0
		var raw = 0.50 * sin(TAU * f0 * t)
		rectified[i] = maxf(0.0, raw)
	detector.push_audio_samples(rectified)
	var res_rect = detector.get_detected_pitches()
	log_assert(res_rect.has(60), "Half-wave rectified wave detects fundamental C4 (60)", "detected: %s" % str(res_rect))
	log_assert(not res_rect.has(36) and not res_rect.has(37), "Half-wave rectified DC does not leak phantom bass notes", "detected: %s" % str(res_rect))

# ------------------------------------------------------------------------------
# 5. Performance, Latency, and Jitter
# ------------------------------------------------------------------------------
func test_suite_performance_and_jitter(detector_script: GDScript) -> void:
	print("\n--- 5. Performance, Latency, and Jitter ---")
	var detector = detector_script.new(48000.0)
	var audio = _synth_audio([60, 64, 67], 48000.0, 2048, 0.10)

	var max_lat: float = 0.0
	var sum_lat: float = 0.0
	var iterations: int = 50

	for i in range(iterations):
		detector.push_audio_samples(audio)
		var lat = detector.get_last_latency_ms()
		if lat > max_lat:
			max_lat = lat
		sum_lat += lat

	var avg_lat = sum_lat / float(iterations)
	log_assert(max_lat < 15.0, "Worst-case latency is under 15ms limit", "max: %0.2f ms, avg: %0.2f ms" % [max_lat, avg_lat])
	log_assert(avg_lat < 5.0, "Average latency is under 5ms", "avg: %0.2f ms" % avg_lat)
