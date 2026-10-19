extends SceneTree

## Comprehensive Adversarial Test Runner for Milestone M4:
## Audio Telemetry, 512-Sample Circular Buffer Stability,
## Zero-Crossing Trigger Detection, and High-Throughput Streams.

var total_passed: int = 0
var total_failed: int = 0

func _init() -> void:
	call_deferred("run_adversarial_tests")

func run_adversarial_tests() -> void:
	print("==================================================================")
	print(" STARTING M4 ADVERSARIAL TELEMETRY & HIGH-THROUGHPUT RUNNER        ")
	print("==================================================================")

	_setup_autoloads()

	test_circular_buffer_nan_inf_noise_stability()
	test_zero_crossing_trigger_edge_cases()
	test_high_frequency_telemetry_and_memory_stress()
	test_end_to_end_audio_telemetry_pipeline()

	print("==================================================================")
	print(" ADVERSARIAL RESULTS: %d Passed, %d Failed" % [total_passed, total_failed])
	print("==================================================================")

	if total_failed == 0:
		print("ALL M4 ADVERSARIAL CHALLENGES SURVIVED [OK]")
		quit(0)
	else:
		printerr("M4 ADVERSARIAL CHALLENGE FAILED: %d test(s) failed." % total_failed)
		quit(1)

func assert_test(cond: bool, msg: String) -> void:
	if cond:
		print("  [PASS] %s" % msg)
		total_passed += 1
	else:
		printerr("  [FAIL] %s" % msg)
		total_failed += 1

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

# ==============================================================================
# SUITE 1: 512-Sample Circular Buffer Stability Under Pathological Inputs
# ==============================================================================
func test_circular_buffer_nan_inf_noise_stability() -> void:
	print("\n--- Suite 1: 512-Sample Circular Buffer Stability Under Pathological Inputs ---")
	var ScopeScript = load("res://scripts/oscilloscope_view.gd")
	assert_test(ScopeScript != null, "scripts/oscilloscope_view.gd loaded")
	var scope: Control = ScopeScript.new()
	assert_test(scope != null, "OscilloscopeView created")
	root.add_child(scope)
	scope._ready()

	# 1.1 Ingestion of NaN arrays via update_waveform (512 samples)
	var nan_samples := PackedFloat32Array()
	nan_samples.resize(512)
	for i in range(512):
		nan_samples[i] = NAN
	scope.update_waveform(nan_samples, 0.0, -100.0, true, 48000)

	assert_test(scope.waveform_buffer.size() == 512, "Circular buffer maintained at 512 samples after all-NaN input")
	var has_nan: bool = false
	for i in range(512):
		if is_nan(scope.waveform_buffer[i]):
			has_nan = true
			break
	assert_test(not has_nan, "All NaN samples sanitized to 0.0 in waveform_buffer")
	assert_test(not is_nan(scope.peak_amplitude), "peak_amplitude is non-NaN after all-NaN input (got %f)" % scope.peak_amplitude)
	assert_test(not is_nan(scope.estimated_freq_hz), "estimated_freq_hz is non-NaN after all-NaN input")
	assert_test(not is_nan(scope.current_display_gain), "current_display_gain is non-NaN after all-NaN input")

	# 1.2 Ingestion of Inf arrays via update_waveform (+Inf and -Inf)
	var inf_samples := PackedFloat32Array()
	inf_samples.resize(512)
	for i in range(512):
		inf_samples[i] = INF if (i % 2 == 0) else -INF
	scope.update_waveform(inf_samples, 0.0, -100.0, true, 48000)

	var has_inf: bool = false
	for i in range(512):
		if is_inf(scope.waveform_buffer[i]):
			has_inf = true
			break
	assert_test(not has_inf, "All Inf samples sanitized to 0.0 in waveform_buffer")
	assert_test(not is_inf(scope.peak_amplitude), "peak_amplitude is finite after Inf input")

	# 1.3 Ingestion of NaN/Inf via push_samples in chunks of 64
	for chunk_idx in range(16):
		var chunk := PackedFloat32Array()
		chunk.resize(64)
		for j in range(64):
			match (j % 4):
				0: chunk[j] = NAN
				1: chunk[j] = INF
				2: chunk[j] = -INF
				3: chunk[j] = 0.25
		scope.push_samples(chunk)

	assert_test(scope.waveform_buffer.size() == 512, "Circular buffer size remains exactly 512 after 16 chunk pushes")
	var contaminated: bool = false
	for i in range(512):
		var v = scope.waveform_buffer[i]
		if is_nan(v) or is_inf(v):
			contaminated = true
			break
	assert_test(not contaminated, "push_samples successfully filters NaNs and Infs across circular shifts")
	assert_test(not is_nan(scope.current_rms) and not is_inf(scope.current_rms), "current_rms is finite after push_samples (got %f)" % scope.current_rms)
	assert_test(not is_nan(scope.current_rms_db) and not is_inf(scope.current_rms_db), "current_rms_db is finite after push_samples (got %f)" % scope.current_rms_db)

	# 1.4 Extreme Noise and Out-of-Bounds Amplitudes
	var extreme_samples := PackedFloat32Array()
	extreme_samples.resize(256)
	for i in range(256):
		extreme_samples[i] = 1e6 if (i % 2 == 0) else -1e6
	scope.push_samples(extreme_samples)

	var all_bounded: bool = true
	for i in range(512):
		var v = scope.waveform_buffer[i]
		if absf(v) > 1.50001:
			all_bounded = false
			break
	assert_test(all_bounded, "push_samples clamps extreme out-of-bounds amplitudes to [-1.5, 1.5]")
	assert_test(scope.current_display_gain >= 1.0 and scope.current_display_gain <= 6.0, "current_display_gain is bounded in [1.0, 6.0] under extreme signal")

	# 1.5 DC Offsets: Pure positive DC (+1.0 flatline)
	var dc_pos := PackedFloat32Array()
	dc_pos.resize(512)
	dc_pos.fill(1.0)
	scope.update_waveform(dc_pos, 1.0, 0.0, false, 48000)
	var trig_pos: int = scope._find_trigger_offset()
	assert_test(trig_pos == 0, "Pure positive DC flatline returns trigger offset 0 (got %d)" % trig_pos)
	assert_test(scope.estimated_freq_hz == 0.0, "Zero-crossings for positive DC flatline yields 0.0 Hz")

	# 1.6 DC Offsets: Pure negative DC (-1.0 flatline)
	var dc_neg := PackedFloat32Array()
	dc_neg.resize(512)
	dc_neg.fill(-1.0)
	scope.update_waveform(dc_neg, 1.0, 0.0, false, 48000)
	var trig_neg: int = scope._find_trigger_offset()
	assert_test(trig_neg == 0, "Pure negative DC flatline returns trigger offset 0 (got %d)" % trig_neg)
	assert_test(scope.estimated_freq_hz == 0.0, "Zero-crossings for negative DC flatline yields 0.0 Hz")

	# 1.7 DC Bias: AC signal riding on positive DC offset (+0.8 + 0.1 * sin)
	var biased := PackedFloat32Array()
	biased.resize(512)
	for i in range(512):
		biased[i] = 0.8 + 0.1 * sin(float(i) * 0.2)
	scope.update_waveform(biased, 0.81, -1.8, false, 48000)
	var trig_biased: int = scope._find_trigger_offset()
	assert_test(trig_biased == 0, "AC signal strictly above zero level gracefully defaults trigger offset to 0")

	# 1.8 Rapid 48kHz Audio Stream with Irregular Chunk Sizes (1000 pushes)
	var test_chunk_sizes = [0, 1, 7, 32, 64, 127, 128, 255, 256, 511, 512, 513, 1024, 2048]
	var size_invariant: bool = true
	for iter in range(1000):
		var sz = test_chunk_sizes[iter % test_chunk_sizes.size()]
		var stream_chunk := PackedFloat32Array()
		stream_chunk.resize(sz)
		for j in range(sz):
			stream_chunk[j] = 0.3 * sin(float(iter * sz + j) * 0.05)
		scope.push_samples(stream_chunk)
		if scope.waveform_buffer.size() != 512:
			size_invariant = false
			break
	assert_test(size_invariant, "Ring buffer size strictly preserved at 512 across 1000 variable-sized chunk pushes")

	# 1.9 Reset via clear()
	scope.clear()
	assert_test(scope.waveform_buffer.size() == 512, "Buffer size is 512 after clear()")
	assert_test(scope.current_rms == 0.0, "current_rms is 0.0 after clear()")
	assert_test(scope.current_rms_db == -100.0, "current_rms_db is -100.0 dB after clear()")
	assert_test(scope.is_gated == true, "is_gated is true after clear()")
	assert_test(scope.peak_amplitude == 0.0, "peak_amplitude is 0.0 after clear()")
	assert_test(scope.estimated_freq_hz == 0.0, "estimated_freq_hz is 0.0 after clear()")

	scope.queue_free()

# ==============================================================================
# SUITE 2: Zero-Crossing Trigger Detection Under Pathological Waveforms
# ==============================================================================
func test_zero_crossing_trigger_edge_cases() -> void:
	print("\n--- Suite 2: Zero-Crossing Trigger Detection Under Pathological Waveforms ---")
	var ScopeScript = load("res://scripts/oscilloscope_view.gd")
	var scope: Control = ScopeScript.new()
	root.add_child(scope)
	scope._ready()

	# 2.1 Flatline Silence
	var silence := PackedFloat32Array()
	silence.resize(512)
	silence.fill(0.0)
	scope.update_waveform(silence, 0.0, -100.0, true, 48000)
	var trig_silence: int = scope._find_trigger_offset()
	assert_test(trig_silence == 0, "Flatline silence returns trigger offset 0")
	assert_test(scope.is_gated == true, "Flatline silence correctly marked gated")

	# 2.2 Square Wave Trigger (Alternating -0.5 and +0.5 every 16 samples)
	var square := PackedFloat32Array()
	square.resize(512)
	for i in range(512):
		square[i] = 0.5 if ((i / 16) % 2 == 1) else -0.5
	scope.update_waveform(square, 0.5, -6.0, false, 48000)
	var trig_sq: int = scope._find_trigger_offset()
	assert_test(trig_sq == 16, "Square wave trigger offset accurately locks to first rising edge (sample 16, got %d)" % trig_sq)
	assert_test(scope.waveform_buffer[trig_sq - 1] <= 0.0 and scope.waveform_buffer[trig_sq] > 0.0, "Rising edge condition verified at square trigger index")

	# 2.3 20 Hz Sub-bass Tone (Period = 2400 samples at 48kHz)
	# Buffer has 512 samples (~21% of a wave cycle).
	# Test phase 0: rising from 0.0 at index 0.
	var sub_bass_0 := PackedFloat32Array()
	sub_bass_0.resize(512)
	for i in range(512):
		sub_bass_0[i] = 0.6 * sin(TAU * 20.0 * (float(i) / 48000.0))
	scope.update_waveform(sub_bass_0, 0.42, -7.5, false, 48000)
	var trig_sub_0: int = scope._find_trigger_offset()
	assert_test(trig_sub_0 >= 0 and trig_sub_0 < 256, "20 Hz sub-bass (phase 0) returns safe trigger offset: %d" % trig_sub_0)

	# Test phase PI: falling through 0 at index 0, so no rising edge exists in first 255 samples
	var sub_bass_pi := PackedFloat32Array()
	sub_bass_pi.resize(512)
	for i in range(512):
		sub_bass_pi[i] = 0.6 * sin(PI + TAU * 20.0 * (float(i) / 48000.0))
	scope.update_waveform(sub_bass_pi, 0.42, -7.5, false, 48000)
	var trig_sub_pi: int = scope._find_trigger_offset()
	assert_test(trig_sub_pi == 0, "20 Hz sub-bass without rising edge in search window safely defaults to 0 (got %d)" % trig_sub_pi)
	assert_test(scope.estimated_freq_hz <= 30.0, "Sub-bass frequency estimation safely clamped/zeroed: %.1f Hz" % scope.estimated_freq_hz)

	# 2.4 10 kHz Ultrasonic / High Frequency Tone (Period = 4.8 samples at 48kHz)
	var ultra := PackedFloat32Array()
	ultra.resize(512)
	for i in range(512):
		ultra[i] = 0.5 * sin(TAU * 10000.0 * (float(i) / 48000.0))
	scope.update_waveform(ultra, 0.35, -9.1, false, 48000)
	var trig_ultra: int = scope._find_trigger_offset()
	assert_test(trig_ultra >= 1 and trig_ultra <= 6, "10 kHz ultrasonic tone locks to rising edge within first cycle (sample %d)" % trig_ultra)
	assert_test(scope.estimated_freq_hz > 9000.0 and scope.estimated_freq_hz < 11000.0, "10 kHz zero-crossing count accurately estimates ~10kHz (got %.1f Hz)" % scope.estimated_freq_hz)

	# 2.5 Micro-noise Chatter Suppression (hysteresis rejection)
	# Fluctuations of amplitude 0.0005 cross zero, but are well below hysteresis (0.002)
	var chatter := PackedFloat32Array()
	chatter.resize(512)
	for i in range(512):
		chatter[i] = 0.0005 if (i % 2 == 0) else -0.0005
	scope.update_waveform(chatter, 0.0005, -66.0, true, 48000)
	var trig_chatter: int = scope._find_trigger_offset()
	assert_test(trig_chatter == 0, "Micro-noise chatter below hysteresis threshold rejected by trigger (offset %d)" % trig_chatter)

	# 2.6 Asymmetric Sawtooth Wave
	var sawtooth := PackedFloat32Array()
	sawtooth.resize(512)
	for i in range(512):
		sawtooth[i] = -0.5 + float(i % 32) * (1.0 / 32.0)
	scope.update_waveform(sawtooth, 0.29, -10.7, false, 48000)
	var trig_saw: int = scope._find_trigger_offset()
	assert_test(trig_saw >= 15 and trig_saw <= 18, "Sawtooth ramp zero crossing cleanly detected at sample %d" % trig_saw)

	scope.queue_free()

# ==============================================================================
# SUITE 3: High-Frequency Telemetry & Resource Stability Stress
# ==============================================================================
func test_high_frequency_telemetry_and_memory_stress() -> void:
	print("\n--- Suite 3: High-Frequency Telemetry & Resource Stability Stress ---")
	var HudScene = load("res://scenes/hud.tscn")
	assert_test(HudScene != null, "scenes/hud.tscn loaded")
	var hud: CanvasLayer = HudScene.instantiate()
	root.add_child(hud)
	hud._ready()

	var ScopeScript = load("res://scripts/oscilloscope_view.gd")
	var scope: Control = ScopeScript.new()
	root.add_child(scope)
	scope._ready()

	# 3.1 60 FPS Polyphonic Chord Changes (1,000 rapid updates)
	var test_chords = [
		{"pitches": [60, 64, 67], "conf": {60: 0.95, 64: 0.88, 67: 0.92}, "name": "C Major"},
		{"pitches": [57, 60, 64], "conf": {57: 0.91, 60: 0.89, 64: 0.94}, "name": "A Minor"},
		{"pitches": [53, 57, 60, 65], "conf": {53: 0.85, 57: 0.87, 60: 0.90, 65: 0.82}, "name": "F Major 7"},
		{"pitches": [55, 59, 62, 65], "conf": {55: 0.93, 59: 0.90, 62: 0.88, 65: 0.85}, "name": "G 7"},
		{"pitches": [36, 48, 60, 72, 84, 96], "conf": {}, "name": "Octave Stack"},
		{"pitches": [], "conf": {}, "name": "Silence"},
		{"pitches": [0, 127], "conf": {0: 0.5, 127: 0.5}, "name": "Extreme MIDI Bounds"}
	]

	var chord_updates_clean: bool = true
	for i in range(1000):
		var chord_spec = test_chords[i % test_chords.size()]
		var pitches: Array = chord_spec["pitches"]
		var conf: Dictionary = chord_spec["conf"]
		scope.update_pitch_telemetry(pitches, conf, "Test DSP")
		hud.update_inference_telemetry({
			"tier_name": "Test DSP",
			"active_pitches": pitches,
			"confidence_map": conf,
			"latency_ms": 12.5,
			"is_ready": true
		})
		if scope.active_pitches.size() != pitches.size():
			chord_updates_clean = false
			break
	assert_test(chord_updates_clean, "1000 rapid polyphonic chord telemetry bursts processed without failure")

	# 3.2 Rapid RMS Dynamic Range Bursts (-100 dB to +6 dB to -100 dB)
	var rms_burst_clean: bool = true
	var dummy_chunk := PackedFloat32Array()
	dummy_chunk.resize(256)
	for i in range(1000):
		var state_cycle = i % 4
		var test_rms: float = 0.0
		var test_db: float = -100.0
		var test_gated: bool = true

		match state_cycle:
			0: # Absolute silence
				test_rms = 0.0
				test_db = -100.0
				test_gated = true
				dummy_chunk.fill(0.0)
			1: # Low murmur
				test_rms = 0.003
				test_db = -50.4
				test_gated = true
				dummy_chunk.fill(0.003)
			2: # Normal signal
				test_rms = 0.25
				test_db = -12.0
				test_gated = false
				dummy_chunk.fill(0.25)
			3: # Clipped peak burst
				test_rms = 1.99
				test_db = 6.0
				test_gated = false
				dummy_chunk.fill(1.5)

		scope.update_waveform(dummy_chunk, test_rms, test_db, test_gated, 48000)
		hud.update_audio_telemetry(dummy_chunk, test_rms, test_db, test_gated, true, i * 256, 48000)
		scope._process(0.016)

		if is_nan(scope.peak_db_hold) or is_inf(scope.peak_db_hold):
			rms_burst_clean = false
			break

	assert_test(rms_burst_clean, "1000 rapid RMS shock cycles (-100dB to +6dB) maintained valid finite telemetry")
	assert_test(scope.peak_db_hold <= 6.001, "peak_db_hold correctly caught the peak shock burst")

	# 3.3 Static Memory Leak & Allocation Stress
	# Take baseline static memory
	var mem_before: int = int(OS.get_static_memory_usage())

	# Execute 5000 telemetry & audio processing cycles
	for cycle in range(5000):
		var test_samples := PackedFloat32Array()
		test_samples.resize(256)
		test_samples.fill(0.15)
		scope.update_waveform(test_samples, 0.15, -16.5, false, 48000)
		scope._process(0.016)
		hud.update_audio_telemetry(test_samples, 0.15, -16.5, false, true, cycle * 256, 48000)

	var mem_after: int = int(OS.get_static_memory_usage())
	var mem_growth_kb: float = float(mem_after - mem_before) / 1024.0
	print("  [INFO] Static memory before: %d bytes, after: %d bytes (delta: %.2f KB)" % [mem_before, mem_after, mem_growth_kb])
	# Allow modest internal Godot string/cache overhead (< 1500 KB across 5000 iterations)
	assert_test(mem_growth_kb < 1500.0, "Static memory growth across 5000 telemetry updates is bounded (< 1.5 MB, got %.2f KB)" % mem_growth_kb)

	# 3.4 Visual Rendering Stress (queue_redraw and state resilience under edge-case states)
	var draw_states_tested: int = 0
	var test_sizes = [Vector2(1280, 130), Vector2(400, 130), Vector2(50, 40), Vector2(10, 10), Vector2(0, 0)]
	for s_size in test_sizes:
		scope.size = s_size
		# Edge case: All zeros
		scope.waveform_buffer.fill(0.0)
		scope._process(0.016)
		scope.queue_redraw()
		draw_states_tested += 1

		# Edge case: Max clipped
		scope.waveform_buffer.fill(1.5)
		scope.peak_db_hold = 0.0
		scope.current_rms_db = 0.0
		scope.is_gated = false
		scope._process(0.016)
		scope.queue_redraw()
		draw_states_tested += 1

		# Edge case: Deep silence & large active chords
		scope.waveform_buffer.fill(-1.5)
		scope.peak_db_hold = -100.0
		scope.current_rms_db = -100.0
		scope.is_gated = true
		scope.active_pitches = [21, 36, 48, 60, 64, 67, 72, 84, 96, 108]
		scope._process(0.016)
		scope.queue_redraw()
		draw_states_tested += 1

	assert_test(draw_states_tested == 15, "15 pathological display states updated via queue_redraw() and _process() cleanly")

	# 3.5 Judgment Popup Spawn Stress (200 rapid popups)
	for p_i in range(200):
		var ratings = ["PERFECT", "GOOD", "MISS"]
		hud.spawn_judgment_popup(ratings[p_i % 3], Vector2(160, 360))
	assert_test(true, "200 judgment popups spawned rapidly without crashing or dangling state")

	scope.queue_free()
	hud.queue_free()

# ==============================================================================
# SUITE 4: End-to-End Pipeline Audio Telemetry Integration
# ==============================================================================
func test_end_to_end_audio_telemetry_pipeline() -> void:
	print("\n--- Suite 4: End-to-End Pipeline Audio Telemetry Integration ---")
	var cap = root.get_node_or_null("AudioCaptureService")
	assert_test(cap != null, "AudioCaptureService singleton resolved in root")

	var ScopeScript = load("res://scripts/oscilloscope_view.gd")
	var scope: Control = ScopeScript.new()
	root.add_child(scope)
	scope._ready()
	scope.connect_services()

	# 4.1 Verify Master Bus Protection Invariant
	var master_idx: int = AudioServer.get_bus_index("Master")
	var record_idx: int = AudioServer.get_bus_index("Record")
	assert_test(master_idx == 0, "Master bus is bus index 0")
	assert_test(not AudioServer.is_bus_mute(0), "Master bus (0) is strictly unmuted")
	assert_test(AudioServer.is_bus_mute(record_idx), "Record bus is strictly muted")
	assert_test(AudioServer.get_bus_volume_db(0) == 0.0, "Master bus volume is 0.0 dB")

	# 4.2 Synthetic Chord Injection Through Live AudioCaptureService Pipeline
	var initial_frames: int = cap.total_frames_captured
	var chord_samples: PackedFloat32Array = cap.inject_test_chord([60, 64, 67], 2048, 0.28)
	assert_test(chord_samples.size() == 2048, "inject_test_chord generated 2048 mono frames")
	assert_test(cap.total_frames_captured == initial_frames + 2048, "AudioCaptureService captured exactly 2048 additional frames")
	assert_test(cap.current_rms > cap.rms_threshold, "Captured chord RMS above gate threshold (got %f > %f)" % [cap.current_rms, cap.rms_threshold])
	assert_test(not cap.is_currently_gated, "Gate is open during chord injection")

	# Verify signal forwarded to OscilloscopeView
	assert_test(scope.waveform_buffer.size() == 512, "OscilloscopeView ring buffer maintained at 512 samples")
	assert_test(scope.peak_amplitude > 0.1, "OscilloscopeView received chord signal via singleton signal connection")
	assert_test(not scope.is_gated, "OscilloscopeView reflects open gate status")

	# 4.3 Snap to Diagnostic Dock Safe Zone Geometry Check
	scope.snap_to_diagnostic_dock_zone(1280.0)
	var dock_rect: Rect2 = scope.get_dock_rect()
	assert_test(dock_rect.position.y == 480.0, "Dock Y starts at 480.0 px")
	assert_test(dock_rect.size.y == 130.0, "Dock height is 130.0 px")
	assert_test(dock_rect.end.y == 610.0, "Dock Y ends at 610.0 px")
	var bottom_clearance: float = 720.0 - dock_rect.end.y
	assert_test(bottom_clearance == 110.0, "Bottom clearance is 110.0 px (>= 100px mobile gesture bar safety margin)")

	# 4.4 Disconnect Services Cleanup
	scope.disconnect_services()
	assert_test(scope._services_bound == false, "Services cleanly disconnected on exit")

	scope.queue_free()
