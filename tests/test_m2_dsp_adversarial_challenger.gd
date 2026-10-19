extends SceneTree

## Adversarial Challenge Runner for Milestone 2:
## Goertzel Polyphonic DSP & Pitch Extraction Engine.
##
## Evaluates:
## Suite 1: Polyphonic Chord Separation (C Maj, A Min, F Maj, D7) at 48kHz and 22.05kHz
## Suite 2: Harmonic Suppression Validation (C3=48, C4=60, A4=69 pure and rich overtones)
## Suite 3: Dynamic Range & Signal Extremes (Whisper, Soft, Clipping, DC Bias, NaNs, Infs)
## Suite 4: Chunk Streaming Continuity (64, 128, 257, 1024 frames)

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

func _init() -> void:
	print("==================================================================")
	print("M2 GOERTZEL DSP ADVERSARIAL STRESS SUITE (EMPIRICAL CHALLENGER)")
	print("==================================================================")

	var detector_script = load("res://scripts/inference/native_pitch_detector.gd")
	if detector_script == null:
		printerr("CRITICAL: Cannot load native_pitch_detector.gd")
		quit(1)
		return

	test_suite_1_polyphonic_chords(detector_script)
	test_suite_2_harmonic_suppression(detector_script)
	test_suite_3_dynamic_range_and_extremes(detector_script)
	test_suite_4_chunk_streaming(detector_script)

	print("\n==================================================================")
	print("M2 CHALLENGER SUMMARY: %d Total Checks | %d Passed | %d Failed" % [checks, passes, failures])
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

# Synthesizes test buffer with fundamental + optional harmonic overtones + optional DC bias
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

# ------------------------------------------------------------------------------
# Suite 1: Polyphonic Chord Separation
# ------------------------------------------------------------------------------
func test_suite_1_polyphonic_chords(detector_script: GDScript) -> void:
	print("\n--- Suite 1: Polyphonic Chord Separation ---")

	# 1.1 Tests at standard 48 kHz (Default AudioServer sample rate)
	print("  [Subsuite 1A: 48 kHz Audio Evaluation]")
	var det_48 = detector_script.new(48000.0)

	# C Major [60, 64, 67]
	det_48.reset()
	var c_maj_48 = _synth_audio([60, 64, 67], 48000.0, 2048, 0.10)
	det_48.push_audio_samples(c_maj_48)
	var res_c_maj_48 = det_48.get_detected_pitches()
	log_assert(res_c_maj_48 == [60, 64, 67], "48kHz C Major Triad [60, 64, 67]", "detected: %s" % str(res_c_maj_48))

	# A Minor [57, 60, 64] (Interval A3-C4 is 41.6 Hz; window duration 42.7 ms has lobe width 93.8 Hz)
	det_48.reset()
	var a_min_48 = _synth_audio([57, 60, 64], 48000.0, 2048, 0.10)
	det_48.push_audio_samples(a_min_48)
	var res_a_min_48 = det_48.get_detected_pitches()
	log_assert(res_a_min_48 == [57, 60, 64], "48kHz A Minor Triad [57, 60, 64]", "detected: %s" % str(res_a_min_48))

	# F Major [53, 57, 60] (Interval F3-A3 is 45.4 Hz, A3-C4 is 41.6 Hz)
	det_48.reset()
	var f_maj_48 = _synth_audio([53, 57, 60], 48000.0, 2048, 0.10)
	det_48.push_audio_samples(f_maj_48)
	var res_f_maj_48 = det_48.get_detected_pitches()
	log_assert(res_f_maj_48 == [53, 57, 60], "48kHz F Major Triad [53, 57, 60]", "detected: %s" % str(res_f_maj_48))

	# D Dominant 7th [62, 66, 69, 72] (4-note polyphony, intervals >= 70 Hz)
	det_48.reset()
	var d7_48 = _synth_audio([62, 66, 69, 72], 48000.0, 2048, 0.08)
	det_48.push_audio_samples(d7_48)
	var res_d7_48 = det_48.get_detected_pitches()
	log_assert(res_d7_48 == [62, 66, 69, 72], "48kHz D Dominant 7th [62, 66, 69, 72]", "detected: %s" % str(res_d7_48))

	# 1.2 Tests at 22,050 Hz (V2 Pipeline Inference Rate: 2048 samples = 92.9 ms, lobe width 43.1 Hz)
	print("  [Subsuite 1B: 22.05 kHz Audio Evaluation]")
	var det_22 = detector_script.new(22050.0)

	det_22.reset()
	var c_maj_22 = _synth_audio([60, 64, 67], 22050.0, 2048, 0.10)
	det_22.push_audio_samples(c_maj_22)
	var res_c_maj_22 = det_22.get_detected_pitches()
	log_assert(res_c_maj_22 == [60, 64, 67], "22.05kHz C Major Triad [60, 64, 67]", "detected: %s" % str(res_c_maj_22))

	det_22.reset()
	var a_min_22 = _synth_audio([57, 60, 64], 22050.0, 2048, 0.10)
	det_22.push_audio_samples(a_min_22)
	var res_a_min_22 = det_22.get_detected_pitches()
	log_assert(res_a_min_22 == [57, 60, 64], "22.05kHz A Minor Triad [57, 60, 64]", "detected: %s" % str(res_a_min_22))

	det_22.reset()
	var f_maj_22 = _synth_audio([53, 57, 60], 22050.0, 2048, 0.10)
	det_22.push_audio_samples(f_maj_22)
	var res_f_maj_22 = det_22.get_detected_pitches()
	log_assert(res_f_maj_22 == [53, 57, 60], "22.05kHz F Major Triad [53, 57, 60]", "detected: %s" % str(res_f_maj_22))

	det_22.reset()
	var d7_22 = _synth_audio([62, 66, 69, 72], 22050.0, 2048, 0.08)
	det_22.push_audio_samples(d7_22)
	var res_d7_22 = det_22.get_detected_pitches()
	log_assert(res_d7_22 == [62, 66, 69, 72], "22.05kHz D Dominant 7th [62, 66, 69, 72]", "detected: %s" % str(res_d7_22))

# ------------------------------------------------------------------------------
# Suite 2: Harmonic Suppression Validation
# ------------------------------------------------------------------------------
func test_suite_2_harmonic_suppression(detector_script: GDScript) -> void:
	print("\n--- Suite 2: Harmonic Suppression Validation ---")
	var detector = detector_script.new(22050.0)

	# 2.1 Pure C3 (MIDI 48 = 130.81 Hz): verify octaves (+12=60, +24=72) and fifth (+19=67) suppressed
	detector.reset()
	var c3_pure = _synth_audio([48], 22050.0, 2048, 0.30, false)
	detector.push_audio_samples(c3_pure)
	var res_c3 = detector.get_detected_pitches()
	log_assert(res_c3.has(48), "C3 pure tone fundamental (48) detected")
	log_assert(not res_c3.has(60), "C3 pure tone 2nd harmonic octave C4 (60) suppressed")
	log_assert(not res_c3.has(67), "C3 pure tone 3rd harmonic 5th G4 (67) suppressed")
	log_assert(not res_c3.has(72), "C3 pure tone 4th harmonic octave C5 (72) suppressed")
	log_assert(res_c3.size() == 1, "C3 pure tone exactly 1 note detected", "detected: %s" % str(res_c3))

	# 2.2 Rich C3 with physical acoustic harmonics (70% f0, 20% 2f0, 10% 3f0)
	detector.reset()
	var c3_rich = _synth_audio([48], 22050.0, 2048, 0.30, true)
	detector.push_audio_samples(c3_rich)
	var res_c3_rich = detector.get_detected_pitches()
	log_assert(res_c3_rich.has(48), "C3 rich tone fundamental (48) detected")
	log_assert(not res_c3_rich.has(60), "C3 rich tone 2nd harmonic C4 (60) suppressed")
	log_assert(not res_c3_rich.has(67), "C3 rich tone 3rd harmonic G4 (67) suppressed")
	log_assert(not res_c3_rich.has(72), "C3 rich tone 4th harmonic C5 (72) suppressed")
	log_assert(res_c3_rich.size() == 1, "C3 rich tone exactly 1 note detected", "detected: %s" % str(res_c3_rich))

	# 2.3 Pure C4 (MIDI 60 = 261.63 Hz): verify octaves (+12=72, +24=84) and fifth (+19=79) suppressed
	detector.reset()
	var c4_pure = _synth_audio([60], 22050.0, 2048, 0.30, false)
	detector.push_audio_samples(c4_pure)
	var res_c4 = detector.get_detected_pitches()
	log_assert(res_c4.has(60), "C4 pure tone fundamental (60) detected")
	log_assert(not res_c4.has(72), "C4 pure tone 2nd harmonic C5 (72) suppressed")
	log_assert(not res_c4.has(79), "C4 pure tone 3rd harmonic G5 (79) suppressed")
	log_assert(not res_c4.has(84), "C4 pure tone 4th harmonic C6 (84) suppressed")
	log_assert(res_c4.size() == 1, "C4 pure tone exactly 1 note detected", "detected: %s" % str(res_c4))

	# 2.4 Rich C4 with physical acoustic harmonics
	detector.reset()
	var c4_rich = _synth_audio([60], 22050.0, 2048, 0.30, true)
	detector.push_audio_samples(c4_rich)
	var res_c4_rich = detector.get_detected_pitches()
	log_assert(res_c4_rich.has(60), "C4 rich tone fundamental (60) detected")
	log_assert(not res_c4_rich.has(72), "C4 rich tone 2nd harmonic C5 (72) suppressed")
	log_assert(not res_c4_rich.has(79), "C4 rich tone 3rd harmonic G5 (79) suppressed")
	log_assert(not res_c4_rich.has(84), "C4 rich tone 4th harmonic C6 (84) suppressed")
	log_assert(res_c4_rich.size() == 1, "C4 rich tone exactly 1 note detected", "detected: %s" % str(res_c4_rich))

	# 2.5 Rich A4 (MIDI 69 = 440.0 Hz)
	detector.reset()
	var a4_rich = _synth_audio([69], 22050.0, 2048, 0.30, true)
	detector.push_audio_samples(a4_rich)
	var res_a4_rich = detector.get_detected_pitches()
	log_assert(res_a4_rich.has(69), "A4 rich tone fundamental (69) detected")
	log_assert(not res_a4_rich.has(81), "A4 rich tone 2nd harmonic A5 (81) suppressed")
	log_assert(res_a4_rich.size() == 1, "A4 rich tone exactly 1 note detected", "detected: %s" % str(res_a4_rich))

# ------------------------------------------------------------------------------
# Suite 3: Dynamic Range & Signal Extremes
# ------------------------------------------------------------------------------
func test_suite_3_dynamic_range_and_extremes(detector_script: GDScript) -> void:
	print("\n--- Suite 3: Dynamic Range & Signal Extremes ---")
	var detector = detector_script.new(22050.0)

	# 3.1 Sub-threshold whisper: amplitude 0.003
	detector.reset()
	var whisper = _synth_audio([60], 22050.0, 2048, 0.003)
	detector.push_audio_samples(whisper)
	var res_whisper = detector.get_detected_pitches()
	log_assert(res_whisper.is_empty(), "Sub-threshold whisper (amp 0.003) rejected by gate", "detected: %s" % str(res_whisper))

	# 3.2 Soft tone: amplitude 0.015 (above gate)
	detector.reset()
	var soft = _synth_audio([64], 22050.0, 2048, 0.015)
	detector.push_audio_samples(soft)
	var res_soft = detector.get_detected_pitches()
	log_assert(res_soft.has(64), "Soft tone (amp 0.015) successfully detected", "detected: %s" % str(res_soft))

	# 3.3 Clipping signal: amplitude 1.50 (hot microphone)
	detector.reset()
	var hot = _synth_audio([67], 22050.0, 2048, 1.50)
	detector.push_audio_samples(hot)
	var res_hot = detector.get_detected_pitches()
	log_assert(res_hot.has(67), "Hot clipping tone (amp 1.5) fundamental detected", "detected: %s" % str(res_hot))
	log_assert(res_hot.size() == 1, "Hot clipping tone does not produce ghost harmonics", "detected: %s" % str(res_hot))

	# 3.4 Hard-clipped square waveform clamped at [-0.8, 0.8]
	detector.reset()
	var clipped := PackedFloat32Array()
	clipped.resize(2048)
	for i in range(2048):
		var t: float = float(i) / 22050.0
		var raw: float = 2.0 * sin(TAU * 440.0 * t)
		clipped[i] = clampf(raw, -0.8, 0.8)
	detector.push_audio_samples(clipped)
	var res_clipped = detector.get_detected_pitches()
	log_assert(res_clipped.has(69), "Hard-clipped waveform fundamental A4 (69) detected", "detected: %s" % str(res_clipped))

	# 3.5 Tone + DC Bias: C4 (60, amp 0.3) + 0.3 DC offset
	detector.reset()
	var tone_plus_dc = _synth_audio([60], 22050.0, 2048, 0.30, false, 0.30)
	detector.push_audio_samples(tone_plus_dc)
	var res_tone_dc = detector.get_detected_pitches()
	log_assert(res_tone_dc.has(60), "C4 (60) detected in presence of +0.3 DC bias", "detected: %s" % str(res_tone_dc))

	# 3.6 Pure DC Bias (0.3 DC, NO audio signal):
	# Should NOT hallucinate bass notes. Without DC blocking, this detects phantom notes [37, 40] or [36, 39].
	detector.reset()
	var pure_dc := PackedFloat32Array()
	pure_dc.resize(2048)
	pure_dc.fill(0.30)
	detector.push_audio_samples(pure_dc)
	var res_pure_dc = detector.get_detected_pitches()
	log_assert(res_pure_dc.is_empty(), "Pure DC bias (+0.3) rejected without spurious bass notes", "detected: %s" % str(res_pure_dc))

	# 3.7 NaNs in Audio Stream
	detector.reset()
	var nan_buf := PackedFloat32Array()
	nan_buf.resize(2048)
	var nan_val: float = 0.0 / 0.0
	for i in range(2048):
		if i % 8 == 0:
			nan_buf[i] = nan_val
		else:
			nan_buf[i] = 0.25 * sin(TAU * 440.0 * float(i) / 22050.0)
	detector.push_audio_samples(nan_buf)
	var lat_nan: float = detector.get_last_latency_ms()
	log_assert(not is_nan(lat_nan), "Latency is valid float after NaN feed", "%0.2f ms" % lat_nan)
	var conf_nan: Dictionary = detector.get_confidence_map()
	var has_nan_conf: bool = false
	for k in conf_nan.keys():
		if is_nan(float(conf_nan[k])):
			has_nan_conf = true
	log_assert(not has_nan_conf, "Confidence map contains zero NaNs after NaN input")

	# 3.8 Infs in Audio Stream
	detector.reset()
	var inf_buf := PackedFloat32Array()
	inf_buf.resize(2048)
	var inf_val: float = 1.0 / 0.0
	for i in range(2048):
		if i % 16 == 0:
			inf_buf[i] = inf_val
		else:
			inf_buf[i] = 0.25 * sin(TAU * 440.0 * float(i) / 22050.0)
	detector.push_audio_samples(inf_buf)
	var lat_inf: float = detector.get_last_latency_ms()
	log_assert(not is_inf(lat_inf), "Latency is valid float after Inf feed", "%0.2f ms" % lat_inf)
	var conf_inf: Dictionary = detector.get_confidence_map()
	var has_inf_conf: bool = false
	for k in conf_inf.keys():
		if is_inf(float(conf_inf[k])):
			has_inf_conf = true
	log_assert(not has_inf_conf, "Confidence map contains zero Infs after Inf input")

# ------------------------------------------------------------------------------
# Suite 4: Chunk Streaming Continuity
# ------------------------------------------------------------------------------
func test_suite_4_chunk_streaming(detector_script: GDScript) -> void:
	print("\n--- Suite 4: Micro-Chunk and Prime-Sized Feeds ---")
	var detector = detector_script.new(22050.0)

	var chunk_sizes: Array[int] = [64, 128, 257, 1024]
	for c_sz in chunk_sizes:
		detector.reset()
		var total_needed: int = 3072
		var num_chunks: int = int(ceil(float(total_needed) / float(c_sz)))
		var chord: Array[int] = [60, 64, 67]
		var full_audio = _synth_audio(chord, 22050.0, num_chunks * c_sz, 0.10)

		for c_idx in range(num_chunks):
			var chunk := PackedFloat32Array()
			chunk.resize(c_sz)
			for i in range(c_sz):
				chunk[i] = full_audio[c_idx * c_sz + i]
			detector.push_audio_samples(chunk)

		var det = detector.get_detected_pitches()
		log_assert(det == [60, 64, 67], "Chunk size %d streaming extraction" % c_sz, "detected: %s" % str(det))
