extends SceneTree

## Standalone Verification Runner for Milestone 2:
## Multi-Tier Polyphonic Pitch Inference Engine.
## Validates polymorphic drivers, mock injection, pure GDScript Goertzel DSP,
## OnnxNativeDriver fallback, WebSocketDriver resilience, and InferenceService routing.

var failures: int = 0
var checks: int = 0

func assert_check(condition: bool, message: String) -> void:
	checks += 1
	if condition:
		print("  [PASS] " + message)
	else:
		failures += 1
		printerr("  [FAIL] " + message)

func _init() -> void:
	print("==================================================")
	print("STARTING M2 INFERENCE ENGINE VERIFICATION SUITE")
	print("==================================================")

	test_polymorphic_contract_compliance()
	test_mock_driver_functionality()
	test_native_pitch_detector_dsp()
	test_onnx_native_driver_fallback()
	test_websocket_driver_interface()
	test_inference_service_singleton_and_fallback()
	test_audiocapture_to_inference_pipeline()

	print("\n==================================================")
	print("M2 VERIFICATION RESULTS: %d Passed, %d Failed" % [checks - failures, failures])
	print("==================================================")

	if failures == 0:
		print("ALL M2 INFERENCE SPECIFICATIONS VERIFIED SUCCESSFULLY!")
		quit(0)
	else:
		printerr("M2 VERIFICATION FAILED WITH %d ERRORS" % failures)
		quit(1)

# ------------------------------------------------------------------------------
# Suite 1: Polymorphic Contract Compliance (IAudioPitchModel)
# ------------------------------------------------------------------------------
func test_polymorphic_contract_compliance() -> void:
	print("\n--- 1. Polymorphic Contract Compliance ---")

	var AudioPitchModelScript = load("res://scripts/inference/audio_pitch_model.gd")
	assert_check(AudioPitchModelScript != null, "AudioPitchModel script loads cleanly")
	var base_model = AudioPitchModelScript.new()
	assert_check(base_model is RefCounted, "AudioPitchModel inherits from RefCounted")
	assert_check(base_model.is_model_ready() == false, "Base AudioPitchModel is_model_ready() defaults to false")
	assert_check(base_model.get_detected_pitches().is_empty(), "Base AudioPitchModel get_detected_pitches() returns empty array")
	assert_check(base_model.get_recent_onsets().is_empty(), "Base AudioPitchModel get_recent_onsets() returns empty array")

	var drivers: Array[Dictionary] = [
		{"name": "MockDriver", "path": "res://scripts/inference/mock_driver.gd"},
		{"name": "NativePitchDetector", "path": "res://scripts/inference/native_pitch_detector.gd"},
		{"name": "OnnxNativeDriver", "path": "res://scripts/inference/onnx_native_driver.gd"},
		{"name": "WebSocketDriver", "path": "res://scripts/inference/websocket_driver.gd"}
	]

	var required_methods: Array[String] = [
		"push_audio_samples",
		"get_detected_pitches",
		"get_recent_onsets",
		"pop_recent_onsets",
		"is_model_ready",
		"reset",
		"poll",
		"get_confidence_map",
		"get_last_latency_ms"
	]

	var required_signals: Array[String] = [
		"pitches_detected",
		"onsets_detected",
		"model_ready",
		"model_error"
	]

	for d in drivers:
		var s = load(d["path"])
		assert_check(s != null, "%s script loads successfully" % d["name"])
		var inst = s.new()
		assert_check(inst != null, "%s instantiates successfully" % d["name"])

		for m in required_methods:
			assert_check(inst.has_method(m), "%s implements required method '%s'" % [d["name"], m])

		for sig in required_signals:
			assert_check(inst.has_signal(sig), "%s declares required signal '%s'" % [d["name"], sig])

# ------------------------------------------------------------------------------
# Suite 2: MockDriver Deterministic Functionality
# ------------------------------------------------------------------------------
func test_mock_driver_functionality() -> void:
	print("\n--- 2. MockDriver Deterministic Testing Harness ---")

	var MockDriverScript = load("res://scripts/inference/mock_driver.gd")
	var mock = MockDriverScript.new()

	assert_check(mock.is_model_ready() == true, "MockDriver is immediately ready")
	assert_check(mock.get_detected_pitches().is_empty(), "MockDriver initial pitches empty")

	# Test signal emission on pitch injection using container reference
	var mock_state := {
		"pitches": [],
		"onsets": []
	}
	mock.connect("pitches_detected", func(p: Array[int]):
		mock_state["pitches"] = p.duplicate()
	)
	mock.set_detected_pitches([60, 64, 67])

	var p_rec: Array = mock_state["pitches"]
	assert_check(p_rec == [60, 64, 67], "pitches_detected signal received injected C Major Triad [60, 64, 67]")
	assert_check(mock.get_detected_pitches() == [60, 64, 67], "get_detected_pitches() returns injected pitches")

	# Test onsets and atomic popping
	mock.connect("onsets_detected", func(o: Array[int]):
		mock_state["onsets"] = o.duplicate()
	)
	mock.set_recent_onsets([60, 64])

	var o_rec: Array = mock_state["onsets"]
	assert_check(o_rec == [60, 64], "onsets_detected signal received injected onsets [60, 64]")
	assert_check(mock.get_recent_onsets(false) == [60, 64], "get_recent_onsets(false) retains onsets")
	var popped: Array[int] = mock.pop_recent_onsets()
	assert_check(popped == [60, 64], "pop_recent_onsets() consumed onsets atomically")
	assert_check(mock.get_recent_onsets().is_empty(), "Onsets buffer drained after pop")

	# Test inject_chord convenience
	mock.inject_chord([62, 65, 69])
	assert_check(mock.get_detected_pitches() == [62, 65, 69], "inject_chord set active pitches [62, 65, 69]")
	assert_check(mock.get_recent_onsets() == [62, 65, 69], "inject_chord set recent onsets [62, 65, 69]")

	# Test sample tracking throughput
	var dummy := PackedFloat32Array()
	dummy.resize(512)
	dummy.fill(0.0)
	mock.push_audio_samples(dummy)
	assert_check(mock._samples_processed == 512, "MockDriver tracks sample processing throughput (512 samples)")

	# Test chart playback simulation
	mock.reset()
	assert_check(mock.get_detected_pitches().is_empty(), "reset() cleared active pitches")
	assert_check(mock._samples_processed == 0, "reset() reset sample count")

	var chart_notes: Array = [
		{"pitch_midi": 60, "time_sec": 1.0, "duration_sec": 0.5},
		{"pitch_midi": 64, "time_sec": 1.0, "duration_sec": 0.5},
		{"pitch_midi": 67, "time_sec": 1.0, "duration_sec": 0.5}
	]
	mock.load_chart(chart_notes)
	mock.update_playback_time(0.5)
	assert_check(mock.get_detected_pitches().is_empty(), "Chart playback at t=0.5s is inactive")

	mock.update_playback_time(1.0)
	var active_chart: Array[int] = mock.get_detected_pitches()
	assert_check(active_chart.has(60) and active_chart.has(64) and active_chart.has(67),
		"Chart playback at t=1.0s triggered C Major chord notes [60, 64, 67]")

	mock.update_playback_time(1.6)
	assert_check(mock.get_detected_pitches().is_empty(), "Chart playback at t=1.6s note expired")

# ------------------------------------------------------------------------------
# Suite 3: NativePitchDetector (Pure GDScript Goertzel DSP Engine)
# ------------------------------------------------------------------------------
func test_native_pitch_detector_dsp() -> void:
	print("\n--- 3. Pure GDScript Goertzel DSP Polyphonic Pitch Extraction ---")

	var DetectorScript = load("res://scripts/inference/native_pitch_detector.gd")
	var detector = DetectorScript.new(48000.0)

	assert_check(detector.is_model_ready() == true, "NativePitchDetector is ready immediately")
	assert_check(detector._midi_freqs.size() == 49, "Goertzel covers 49 log-spaced bins (MIDI 36..84)")

	# 1. Single Pure Sine Wave Test: A4 = 440 Hz (MIDI 69)
	var single_tone := PackedFloat32Array()
	single_tone.resize(2048)
	var freq_a4: float = 440.0
	for i in range(2048):
		var t: float = float(i) / 48000.0
		single_tone[i] = 0.30 * sin(TAU * freq_a4 * t)

	detector.push_audio_samples(single_tone)
	var detected_single: Array[int] = detector.get_detected_pitches()
	assert_check(detected_single.has(69), "Goertzel successfully detected single tone A4 (MIDI 69) (detected: %s)" % str(detected_single))

	# 2. Synthetic Polyphonic C Major Triad [60, 64, 67] with 80% fundamental + 20% 2nd harmonic
	detector.reset()
	var chord_samples := PackedFloat32Array()
	chord_samples.resize(2048)
	var triad: Array[int] = [60, 64, 67]
	var voice_amp: float = 0.30 / 3.0

	for i in range(2048):
		var t: float = float(i) / 48000.0
		var s: float = 0.0
		for p in triad:
			var f: float = 440.0 * pow(2.0, float(p - 69) / 12.0)
			s += voice_amp * (0.80 * sin(TAU * f * t) + 0.20 * sin(TAU * f * 2.0 * t))
		chord_samples[i] = s

	detector.push_audio_samples(chord_samples)
	var detected_chord: Array[int] = detector.get_detected_pitches()
	assert_check(detected_chord.has(60), "C Major Triad: C4 (MIDI 60) detected")
	assert_check(detected_chord.has(64), "C Major Triad: E4 (MIDI 64) detected")
	assert_check(detected_chord.has(67), "C Major Triad: G4 (MIDI 67) detected")
	assert_check(detected_chord.size() == 3, "Exactly 3 triad notes extracted without ghost notes (detected: %s)" % str(detected_chord))

	# 3. Harmonic Suppression Verification: Octaves 72 (C5), 76 (E5), 79 (G5) are suppressed
	assert_check(not detected_chord.has(72), "Harmonic suppression: 2nd harmonic C5 (72) suppressed")
	assert_check(not detected_chord.has(76), "Harmonic suppression: 2nd harmonic E5 (76) suppressed")
	assert_check(not detected_chord.has(79), "Harmonic suppression: 2nd harmonic G5 (79) suppressed")

	# 4. Confidence Map Verification
	var conf: Dictionary = detector.get_confidence_map()
	assert_check(conf.has("60") and conf.has("64") and conf.has("67"), "Confidence map populated with triad MIDI strings")

	# 5. Silence & Noise Gating Verification
	var silence := PackedFloat32Array()
	silence.resize(2048)
	silence.fill(0.0)
	detector.push_audio_samples(silence)
	assert_check(detector.get_detected_pitches().is_empty(), "Silence pushes clear detected pitches (RMS gate active)")

	# 6. Latency Benchmark
	var lat_ms: float = detector.get_last_latency_ms()
	assert_check(lat_ms >= 0.0 and lat_ms < 15.0, "Goertzel evaluation latency is under 15ms (%0.2f ms)" % lat_ms)

# ------------------------------------------------------------------------------
# Suite 4: OnnxNativeDriver Fallback & Interface Integrity
# ------------------------------------------------------------------------------
func test_onnx_native_driver_fallback() -> void:
	print("\n--- 4. OnnxNativeDriver Fallback & Interface Integrity ---")

	var OnnxScript = load("res://scripts/inference/onnx_native_driver.gd")
	var onnx_drv = OnnxScript.new()

	var native_meta_present: bool = Engine.has_meta("onnx_pitch_native")
	assert_check(onnx_drv.is_available() == native_meta_present, "is_available() reflects Engine.has_meta('onnx_pitch_native') (%s)" % str(native_meta_present))

	if not native_meta_present:
		assert_check(onnx_drv.is_model_ready() == false, "OnnxNativeDriver is_model_ready() is false when binary absent")
		# Verify safe non-crashing behavior when feeding samples
		var test_samples := PackedFloat32Array()
		test_samples.resize(512)
		test_samples.fill(0.1)
		onnx_drv.push_audio_samples(test_samples)
		assert_check(onnx_drv.get_detected_pitches().is_empty(), "push_audio_samples() handled gracefully without crashing")
		var live_res: Dictionary = onnx_drv.transcribe_live_window(test_samples)
		assert_check(live_res.get("ok", true) == false, "transcribe_live_window() returns ok: false gracefully")

	onnx_drv.reset()
	assert_check(onnx_drv.get_detected_pitches().is_empty(), "OnnxNativeDriver reset() completes cleanly")

# ------------------------------------------------------------------------------
# Suite 5: WebSocketDriver Interface & Offline Resilience
# ------------------------------------------------------------------------------
func test_websocket_driver_interface() -> void:
	print("\n--- 5. WebSocketDriver Interface & Offline Resilience ---")

	var WsScript = load("res://scripts/inference/websocket_driver.gd")
	var ws_drv = WsScript.new("ws://127.0.0.1:8765")

	# Initial state before loop / connect completes
	assert_check(ws_drv.is_model_ready() == false, "WebSocketDriver is not ready prior to socket handshake")

	var test_samples := PackedFloat32Array()
	test_samples.resize(512)
	test_samples.fill(0.05)
	ws_drv.push_audio_samples(test_samples)
	assert_check(ws_drv.samples_sent >= 512, "push_audio_samples() tracked outgoing samples count")

	var summary: Dictionary = ws_drv.get_status_summary()
	assert_check(summary.has("backend") and summary.has("is_ready"), "get_status_summary() returns valid diagnostic dictionary")

	ws_drv.disconnect_from_server()
	assert_check(ws_drv.is_connected == false, "disconnect_from_server() marks is_connected false")

# ------------------------------------------------------------------------------
# Suite 6: InferenceService Multi-Tier Singleton & Graceful Fallback
# ------------------------------------------------------------------------------
func test_inference_service_singleton_and_fallback() -> void:
	print("\n--- 6. InferenceService Singleton & Graceful Fallback ---")

	var root_window: Window = root
	var inf: Node = null

	if root_window.has_node("InferenceService"):
		inf = root_window.get_node("InferenceService")
	else:
		var InfScript = load("res://scripts/inference_service.gd")
		inf = InfScript.new()
		inf.name = "InferenceService"
		root_window.add_child(inf)

	assert_check(inf != null, "InferenceService accessible in scene tree")
	assert_check(inf.is_active == true, "InferenceService is active")

	# 1. Tier 4: Mock Tier Switching
	var tier_state := {"backend_changed": false}
	var b_cb = func(_b: int):
		tier_state["backend_changed"] = true
	inf.connect("backend_changed", b_cb)
	inf.set_tier(inf.ModelTier.MOCK)

	assert_check(tier_state["backend_changed"] == true, "backend_changed signal emitted on tier switch")
	assert_check(inf.get_tier() == inf.ModelTier.MOCK, "get_tier() returns ModelTier.MOCK")
	assert_check(inf.get_tier_name() == "Deterministic Mock Driver", "get_tier_name() returns correct label")
	inf.disconnect("backend_changed", b_cb)

	# Inject pitches via active driver in MOCK tier
	var pitch_state := {"pitches": [], "conf": {}}
	var pitch_cb = func(p: Array[int], c: Dictionary):
		pitch_state["pitches"] = p.duplicate()
		pitch_state["conf"] = c.duplicate()

	inf.connect("pitch_detected", pitch_cb)
	inf.active_driver.set_detected_pitches([60, 64, 67])

	var p_received: Array = pitch_state["pitches"]
	assert_check(p_received == [60, 64, 67], "InferenceService pitch_detected signal fired with [60, 64, 67]")
	assert_check(inf.get_active_pitches() == [60, 64, 67], "InferenceService get_active_pitches() returns [60, 64, 67]")
	assert_check(inf.get_confidence_map().has("60"), "InferenceService confidence map has pitch 60")
	inf.disconnect("pitch_detected", pitch_cb)

	# 2. Tier 3: Pure GDScript DSP Tier Switching & Synthetic Processing
	inf.set_tier(inf.ModelTier.GD_DSP)
	assert_check(inf.get_tier() == inf.ModelTier.GD_DSP, "get_tier() returns ModelTier.GD_DSP")

	# Use matching sample rate from AudioServer for synthesis
	var target_sr: float = float(AudioServer.get_mix_rate())
	if target_sr <= 0.0:
		target_sr = 48000.0

	var chord_samples := PackedFloat32Array()
	chord_samples.resize(2048)
	var triad: Array[int] = [60, 64, 67]
	var voice_amp: float = 0.30 / 3.0
	for i in range(2048):
		var t: float = float(i) / target_sr
		var s: float = 0.0
		for p in triad:
			var f: float = 440.0 * pow(2.0, float(p - 69) / 12.0)
			s += voice_amp * (0.80 * sin(TAU * f * t) + 0.20 * sin(TAU * f * 2.0 * t))
		chord_samples[i] = s

	inf.push_audio_samples(chord_samples)
	var inf_detected: Array[int] = inf.get_active_pitches()
	assert_check(inf_detected.has(60) and inf_detected.has(64) and inf_detected.has(67),
		"InferenceService in GD_DSP tier detected synthetic C Major Triad [60, 64, 67] (detected: %s)" % str(inf_detected))

	# 3. Graceful Fallback from Tier 1 (NATIVE_ONNX)
	var fallback_state := {"fired": false, "from": 0, "to": 0}
	var fallback_cb = func(a: int, f: int, _r: String):
		fallback_state["fired"] = true
		fallback_state["from"] = a
		fallback_state["to"] = f

	inf.connect("fallback_triggered", fallback_cb)
	inf.set_tier(inf.ModelTier.NATIVE_ONNX)

	if not Engine.has_meta("onnx_pitch_native"):
		assert_check(fallback_state["fired"] == true, "fallback_triggered signal fired when switching to unavailable NATIVE_ONNX")
		assert_check(fallback_state["from"] == inf.ModelTier.NATIVE_ONNX, "fallback_triggered attempted_tier is NATIVE_ONNX")
		assert_check(inf.get_tier() == inf.ModelTier.GD_DSP or inf.get_tier() == inf.ModelTier.MOCK,
			"InferenceService gracefully fell back to Tier %d (%s) without crashing" % [inf.get_tier(), inf.get_tier_name()])

	inf.disconnect("fallback_triggered", fallback_cb)

	# 4. Telemetry Status Summary
	var status: Dictionary = inf.get_status_summary()
	assert_check(status.has("tier") and status.has("tier_name") and status.has("latency_ms"),
		"InferenceService get_status_summary() returns comprehensive telemetry")

# ------------------------------------------------------------------------------
# Suite 7: AudioCaptureService -> InferenceService Integration Pipeline
# ------------------------------------------------------------------------------
func test_audiocapture_to_inference_pipeline() -> void:
	print("\n--- 7. AudioCaptureService -> InferenceService Pipeline ---")

	var root_window: Window = root
	var cap: Node = null
	if root_window.has_node("AudioCaptureService"):
		cap = root_window.get_node("AudioCaptureService")
	else:
		var CapScript = load("res://scripts/audio_capture_service.gd")
		cap = CapScript.new()
		cap.name = "AudioCaptureService"
		root_window.add_child(cap)

	var inf: Node = root_window.get_node("InferenceService")
	assert_check(cap != null and inf != null, "AudioCaptureService and InferenceService co-exist in tree")

	# Ensure signal connection
	if not cap.is_connected("audio_chunk_ready", Callable(inf, "push_audio_samples")):
		cap.connect("audio_chunk_ready", Callable(inf, "push_audio_samples"))

	# Switch InferenceService to MOCK for deterministic pipeline verification
	inf.set_tier(inf.ModelTier.MOCK)

	var pipe_state := {"chunk_processed": false, "sample_count": 0}
	var chunk_cb = func(count: int):
		pipe_state["chunk_processed"] = true
		pipe_state["sample_count"] = count

	inf.connect("audio_chunk_processed", chunk_cb)

	# Inject mono samples through capture service
	var test_audio := PackedFloat32Array()
	test_audio.resize(256)
	test_audio.fill(0.15)
	cap.inject_mono_samples(test_audio)

	assert_check(pipe_state["chunk_processed"] == true and pipe_state["sample_count"] == 256,
		"AudioCaptureService.inject_mono_samples() routed audio_chunk_ready to InferenceService.audio_chunk_processed (%d frames)" % pipe_state["sample_count"])

	inf.disconnect("audio_chunk_processed", chunk_cb)
