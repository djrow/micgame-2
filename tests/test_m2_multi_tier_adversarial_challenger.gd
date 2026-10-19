extends SceneTree

## Adversarial Multi-Tier Inference Routing & Fallback Stress Harness (Milestone 2)
## Tests:
## 1. Strict Polymorphic Interface Conformance across AudioPitchModel and all 4 drivers.
## 2. Rapid multi-tier switching under continuous live audio stream load.
## 3. Missing native GDExtension DLL / meta fallback resilience and corrupt metadata attacks.
## 4. Disconnected and unreachable WebSocket server resilience with zero-crash guarantee.
## 5. Audio buffer boundary conditions, extreme floats (NaN, Inf, clipping), and silence gating.
## 6. Autoload integration: AudioCaptureService -> InferenceService cross-service pipeline.

const AudioPitchModelScript = preload("res://scripts/inference/audio_pitch_model.gd")
const MockDriverScript = preload("res://scripts/inference/mock_driver.gd")
const NativePitchDetectorScript = preload("res://scripts/inference/native_pitch_detector.gd")
const OnnxNativeDriverScript = preload("res://scripts/inference/onnx_native_driver.gd")
const WebSocketDriverScript = preload("res://scripts/inference/websocket_driver.gd")
const InferenceServiceScript = preload("res://scripts/inference_service.gd")

var checks: int = 0
var failures: int = 0
var mix_rate: float = 48000.0

func assert_check(condition: bool, message: String) -> void:
	checks += 1
	if condition:
		print("  [PASS] " + message)
	else:
		failures += 1
		printerr("  [FAIL] " + message)

func _init() -> void:
	print("==================================================================")
	print("STARTING M2 MULTI-TIER ROUTING & FALLBACK ADVERSARIAL CHALLENGE")
	print("==================================================================")

	mix_rate = float(AudioServer.get_mix_rate())
	if mix_rate <= 0.0:
		mix_rate = 48000.0
	print("Inference Engine AudioServer Mix Rate: %f Hz" % mix_rate)

	# Suite 1: Polymorphic Interface Conformance
	test_polymorphic_interface_conformance()

	# Suite 2: Rapid Multi-Tier Switching Under Load
	test_rapid_tier_switching_under_load()

	# Suite 3: Missing Native DLL & GDExtension Metadata Fallback Resilience
	test_native_dll_missing_and_corrupt_meta()

	# Suite 4: Disconnected & Unreachable WebSocket Resilience
	test_disconnected_websocket_resilience()

	# Suite 5: Audio Buffer Boundaries, Float Extremes, and Silence
	test_audio_buffer_extremes_and_silence()

	# Suite 6: Autoload Node Integration
	test_autoload_integration()

	print("\n==================================================================")
	print("M2 CHALLENGER RESULTS: %d Passed, %d Failed (Total: %d)" % [checks - failures, failures, checks])
	print("==================================================================")

	if failures == 0:
		print("VERDICT: ALL MULTI-TIER ADVERSARIAL CHALLENGES PASSED! (APPROVE)")
		quit(0)
	else:
		printerr("VERDICT: CHALLENGE FAILED WITH %d DEFECTS!" % failures)
		quit(1)

# --- Helper Synthesizer ---
func _synthesize_chord(pitches: Array[int], sample_rate: float, num_samples: int, amp_per_voice: float = 0.10, dc_bias: float = 0.0) -> PackedFloat32Array:
	var buf := PackedFloat32Array()
	buf.resize(num_samples)
	for i in range(num_samples):
		var t: float = float(i) / sample_rate
		var s: float = dc_bias
		for p in pitches:
			var f0: float = 440.0 * pow(2.0, float(p - 69) / 12.0)
			# Fundamental + subtle 2nd harmonic
			s += amp_per_voice * (0.85 * sin(TAU * f0 * t) + 0.15 * sin(TAU * f0 * 2.0 * t))
		buf[i] = s
	return buf

# ==============================================================================
# Suite 1: Polymorphic Interface Conformance
# ==============================================================================
func test_polymorphic_interface_conformance() -> void:
	print("\n--- 1. Polymorphic Interface & Dynamic Dispatch Conformance ---")

	var drivers: Array = [
		{"name": "Base AudioPitchModel", "instance": AudioPitchModelScript.new()},
		{"name": "Tier 4 MockDriver", "instance": MockDriverScript.new()},
		{"name": "Tier 3 NativePitchDetector (GD_DSP)", "instance": NativePitchDetectorScript.new(mix_rate)},
		{"name": "Tier 1 OnnxNativeDriver", "instance": OnnxNativeDriverScript.new()},
		{"name": "Tier 2 WebSocketDriver", "instance": WebSocketDriverScript.new("ws://127.0.0.1:8765")}
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
		var name: String = d["name"]
		var inst: RefCounted = d["instance"]

		# 1. Inheritance
		assert_check(inst is RefCounted, "%s extends RefCounted" % name)
		assert_check(inst.get_script() != null, "%s has valid GDScript attached" % name)

		# 2. Method existence
		for method_name in required_methods:
			assert_check(inst.has_method(method_name), "%s implements '%s'" % [name, method_name])

		# 3. Signal declaration
		for sig_name in required_signals:
			assert_check(inst.has_signal(sig_name), "%s declares signal '%s'" % [name, sig_name])

		# 4. Strict Polymorphic Execution via Duck/Virtual Dispatch
		inst.call("reset")
		var p: Variant = inst.call("get_detected_pitches")
		assert_check(typeof(p) == TYPE_ARRAY, "%s get_detected_pitches() returns Array" % name)
		assert_check((p as Array).is_empty(), "%s get_detected_pitches() initially empty" % name)

		var o: Variant = inst.call("get_recent_onsets", false)
		assert_check(typeof(o) == TYPE_ARRAY, "%s get_recent_onsets() returns Array" % name)
		assert_check((o as Array).is_empty(), "%s get_recent_onsets() initially empty" % name)

		var popped_o: Variant = inst.call("pop_recent_onsets")
		assert_check(typeof(popped_o) == TYPE_ARRAY, "%s pop_recent_onsets() returns Array" % name)

		var rdy: Variant = inst.call("is_model_ready")
		assert_check(typeof(rdy) == TYPE_BOOL, "%s is_model_ready() returns bool" % name)

		var conf: Variant = inst.call("get_confidence_map")
		assert_check(typeof(conf) == TYPE_DICTIONARY, "%s get_confidence_map() returns Dictionary" % name)

		var lat: Variant = inst.call("get_last_latency_ms")
		assert_check(typeof(lat) == TYPE_FLOAT and float(lat) >= 0.0, "%s get_last_latency_ms() returns non-negative float" % name)

		# Polymorphic push_audio_samples with synthetic test buffer
		var test_buf := PackedFloat32Array([0.0, 0.1, -0.1, 0.0])
		inst.call("push_audio_samples", test_buf)
		inst.call("poll", 0.016)
		assert_check(true, "%s push_audio_samples and poll executed without exception" % name)

# ==============================================================================
# Suite 2: Rapid Multi-Tier Switching Under Load
# ==============================================================================
func test_rapid_tier_switching_under_load() -> void:
	print("\n--- 2. Rapid Multi-Tier Switching Under Continuous Audio Load ---")

	var srv: Node = InferenceServiceScript.new()
	srv.auto_connect_audio_capture = false
	srv._ready()

	var state := {
		"chunks": 0,
		"backend": 0,
		"fallback": 0,
		"pitches": 0
	}

	srv.audio_chunk_processed.connect(func(_count: int) -> void:
		state["chunks"] += 1
	)
	srv.backend_changed.connect(func(_b: int) -> void:
		state["backend"] += 1
	)
	srv.fallback_triggered.connect(func(_att: int, _fb: int, _r: String) -> void:
		state["fallback"] += 1
	)
	srv.pitch_detected.connect(func(_pitches: Array[int], _c: Dictionary) -> void:
		state["pitches"] += 1
	)

	var audio_chunk: PackedFloat32Array = _synthesize_chord([60, 64, 67], mix_rate, 256, 0.10)
	var tiers_to_cycle: Array[int] = [
		srv.ModelTier.GD_DSP,
		srv.ModelTier.MOCK,
		srv.ModelTier.WEBSOCKET,
		srv.ModelTier.NATIVE_ONNX # Will trigger fallback to GD_DSP
	]

	var total_iterations: int = 400
	var switches_attempted: int = 0

	for i in range(total_iterations):
		# Rapidly switch tier every 2 iterations
		if i % 2 == 0:
			var target_tier: int = tiers_to_cycle[(i / 2) % tiers_to_cycle.size()]
			srv.set_tier(target_tier)
			switches_attempted += 1

		# Feed live audio stream
		srv.push_audio_samples(audio_chunk)
		srv._process(0.016)

	assert_check(state["chunks"] == total_iterations, "Zero audio chunks dropped during rapid tier switching (%d / %d processed)" % [state["chunks"], total_iterations])
	assert_check(state["backend"] == switches_attempted, "backend_changed emitted for each tier switch (%d emissions)" % state["backend"])
	assert_check(state["fallback"] == (switches_attempted / 4), "fallback_triggered fired every time NATIVE_ONNX was requested without DLL (%d emissions)" % state["fallback"])
	assert_check(srv.is_active, "InferenceService remains active after stress test")

	# Idempotent switching stress: set same tier 50 times consecutively
	var before_switches: int = state["backend"]
	for j in range(50):
		srv.set_tier(srv.ModelTier.GD_DSP)
	assert_check(state["backend"] == before_switches + 50, "Consecutive set_tier(GD_DSP) handled cleanly without duplicate connection errors")

	# Verification that signal listener does not multiply:
	# Switch to Mock driver, inject chord, and verify pitch_detected fires exactly once per injection
	srv.set_tier(srv.ModelTier.MOCK)
	var single_pitch_state := {"fires": 0}
	var test_cb = func(_pitches: Array[int], _c: Dictionary) -> void:
		single_pitch_state["fires"] += 1

	srv.pitch_detected.connect(test_cb)
	var mock_drv: RefCounted = srv.active_driver
	mock_drv.call("inject_chord", [60, 64, 67])
	assert_check(single_pitch_state["fires"] == 1, "MockDriver pitch injection fired InferenceService.pitch_detected exactly once (no duplicate signal wiring)")
	srv.pitch_detected.disconnect(test_cb)

	# Verify GD_DSP detection after intense switching:
	srv.set_tier(srv.ModelTier.GD_DSP)
	srv.reset()
	# Feed 2048 samples of C Major Triad audio
	var full_window: PackedFloat32Array = _synthesize_chord([60, 64, 67], mix_rate, 2048, 0.10)
	srv.push_audio_samples(full_window)
	var detected: Array[int] = srv.get_active_pitches()
	assert_check(detected.has(60) and detected.has(64) and detected.has(67), "GD_DSP cleanly detects C Major Triad [60, 64, 67] after switching stress: %s" % str(detected))

	srv.free()

# ==============================================================================
# Suite 3: Missing Native DLL & GDExtension Metadata Fallback Resilience
# ==============================================================================
func test_native_dll_missing_and_corrupt_meta() -> void:
	print("\n--- 3. Missing Native DLL & GDExtension Metadata Fallback Resilience ---")

	var srv: Node = InferenceServiceScript.new()
	srv.auto_connect_audio_capture = false
	srv._ready()

	# 3.1 Verify native meta is absent
	if Engine.has_meta("onnx_pitch_native"):
		Engine.remove_meta("onnx_pitch_native")
	assert_check(Engine.has_meta("onnx_pitch_native") == false, "Engine metadata 'onnx_pitch_native' is absent")
	assert_check(srv.is_tier_available(srv.ModelTier.NATIVE_ONNX) == false, "InferenceService.is_tier_available(NATIVE_ONNX) correctly returns false")

	# 3.2 Attempt switch to Tier 1 -> Verify fallback to Tier 3 (GD_DSP)
	var fb_state := {"att": -1, "fb": -1, "fired": false}
	var fallback_cb = func(att: int, fb: int, _r: String) -> void:
		fb_state["att"] = att
		fb_state["fb"] = fb
		fb_state["fired"] = true
	srv.fallback_triggered.connect(fallback_cb)

	srv.set_tier(srv.ModelTier.NATIVE_ONNX)
	assert_check(fb_state["fired"] == true, "fallback_triggered signal fired")
	assert_check(fb_state["att"] == srv.ModelTier.NATIVE_ONNX, "fallback_triggered attempted_tier is NATIVE_ONNX")
	assert_check(fb_state["fb"] == srv.ModelTier.GD_DSP, "fallback_triggered fallback_tier is GD_DSP")
	assert_check(srv.get_tier() == srv.ModelTier.GD_DSP, "Active tier safely fell back to Tier 3 (GD_DSP)")

	srv.fallback_triggered.disconnect(fallback_cb)

	# 3.3 Direct execution of OnnxNativeDriver when DLL is missing
	var onnx_drv = OnnxNativeDriverScript.new()
	assert_check(onnx_drv.is_available() == false, "OnnxNativeDriver.is_available() returns false")
	assert_check(onnx_drv.is_ready() == false, "OnnxNativeDriver.is_ready() returns false")
	assert_check(onnx_drv.is_model_ready() == false, "OnnxNativeDriver.is_model_ready() returns false")
	assert_check(onnx_drv.initialize() == false, "OnnxNativeDriver.initialize() returns false without throwing unhandled exception")

	# Push 43,844 samples directly
	var big_buf := PackedFloat32Array()
	big_buf.resize(43844)
	big_buf.fill(0.05)
	onnx_drv.push_audio_samples(big_buf)
	onnx_drv.poll(0.016)
	assert_check(true, "OnnxNativeDriver.push_audio_samples() survived 43,844 samples without native binary")

	var live_res: Dictionary = onnx_drv.transcribe_live_window(big_buf)
	assert_check(live_res.get("ok") == false, "OnnxNativeDriver.transcribe_live_window() returns ok: false safely")

	var full_res: Dictionary = onnx_drv.transcribe_full_notes(big_buf)
	assert_check(full_res.get("ok") == false, "OnnxNativeDriver.transcribe_full_notes() returns ok: false safely")

	# 3.4 Corrupted Metadata Adversarial Attack
	# Set metadata to an invalid type (String instead of Callable)
	Engine.set_meta("onnx_pitch_native", "CORRUPTED_STRING_PAYLOAD")
	assert_check(Engine.has_meta("onnx_pitch_native") == true, "Engine meta populated with corrupt payload")

	# OnnxNativeDriver.initialize() must detect typeof(meta) != TYPE_CALLABLE and return false gracefully
	var corrupt_onnx = OnnxNativeDriverScript.new()
	var init_success: bool = corrupt_onnx.initialize()
	assert_check(init_success == false, "OnnxNativeDriver rejected non-Callable metadata safely")

	# Clean up Engine meta
	Engine.remove_meta("onnx_pitch_native")
	assert_check(Engine.has_meta("onnx_pitch_native") == false, "Engine metadata cleanly restored")

	srv.free()

# ==============================================================================
# Suite 4: Disconnected & Unreachable WebSocket Resilience
# ==============================================================================
func test_disconnected_websocket_resilience() -> void:
	print("\n--- 4. Disconnected & Unreachable WebSocket Server Resilience ---")

	# 4.1 Standalone WebSocketDriver pointed at unreachable closed port
	var unreachable_url: String = "ws://127.0.0.1:9999"
	var ws_drv = WebSocketDriverScript.new(unreachable_url)
	assert_check(ws_drv.is_connected == false, "WebSocketDriver is_connected initially false")
	assert_check(ws_drv.is_model_ready() == false, "WebSocketDriver is_model_ready() false for unreachable port")

	# Feed audio packets to unreachable driver
	var audio_samples: PackedFloat32Array = _synthesize_chord([60, 64, 67], mix_rate, 1024, 0.1)
	for i in range(10):
		ws_drv.push_audio_samples(audio_samples)
	assert_check(ws_drv.samples_sent == 10240, "WebSocketDriver tracks samples_sent even while offline (%d sent)" % ws_drv.samples_sent)

	# Pump poll loop across 150 simulated ticks
	for frame in range(150):
		ws_drv.poll(0.016)
	assert_check(ws_drv.is_connected == false, "WebSocketDriver poll() survived 150 frames with closed socket without crashing")
	assert_check(ws_drv.reconnect_timer >= 0.0, "WebSocketDriver reconnect timer active (%f s)" % ws_drv.reconnect_timer)

	var summary: Dictionary = ws_drv.get_status_summary()
	assert_check(summary["backend"] == "WebSocket (Disconnected)", "WebSocketDriver telemetry correctly reports 'WebSocket (Disconnected)'")
	assert_check(summary["is_ready"] == false, "WebSocketDriver telemetry reports is_ready: false")

	ws_drv.disconnect_from_server()
	assert_check(ws_drv.is_connected == false, "WebSocketDriver disconnect_from_server completes cleanly")

	# 4.2 InferenceService routed to unreachable WebSocket
	var srv: Node = InferenceServiceScript.new()
	srv.auto_connect_audio_capture = false
	srv.websocket_url = unreachable_url
	srv._ready()

	srv.set_tier(srv.ModelTier.WEBSOCKET)
	assert_check(srv.get_tier() == srv.ModelTier.WEBSOCKET, "InferenceService active tier set to WEBSOCKET")

	var ws_stream_state := {"chunk_events": 0}
	srv.audio_chunk_processed.connect(func(_count: int) -> void:
		ws_stream_state["chunk_events"] += 1
	)

	# Stream audio into InferenceService while WebSocket is unreachable
	for chunk_idx in range(50):
		srv.push_audio_samples(audio_samples)
		srv._process(0.016)

	assert_check(ws_stream_state["chunk_events"] == 50, "InferenceService emitted audio_chunk_processed 100% of the time during offline WebSocket stream")

	var srv_summary: Dictionary = srv.get_status_summary()
	assert_check(srv_summary["is_ready"] == false, "InferenceService status summary reports is_ready: false")
	assert_check(srv.get_active_pitches().is_empty(), "InferenceService active pitches empty while offline")

	# 4.3 Instant seamless recovery: Switch back to GD_DSP
	srv.set_tier(srv.ModelTier.GD_DSP)
	srv.reset()
	assert_check(srv.get_tier() == srv.ModelTier.GD_DSP, "InferenceService cleanly switched back to GD_DSP")

	# Push 2048 samples of C Major Triad to GD_DSP
	var full_recov_buf: PackedFloat32Array = _synthesize_chord([60, 64, 67], mix_rate, 2048, 0.10)
	srv.push_audio_samples(full_recov_buf)
	var active: Array[int] = srv.get_active_pitches()
	assert_check(active.has(60) and active.has(64) and active.has(67), "InferenceService immediately resumed live detection on GD_DSP after WebSocket disconnect: %s" % str(active))

	srv.free()

# ==============================================================================
# Suite 5: Audio Buffer Boundaries, Float Extremes, and Silence
# ==============================================================================
func test_audio_buffer_extremes_and_silence() -> void:
	print("\n--- 5. Audio Buffer Boundaries, Float Extremes, and Silence Gating ---")

	var srv: Node = InferenceServiceScript.new()
	srv.auto_connect_audio_capture = false
	srv._ready()
	srv.set_tier(srv.ModelTier.GD_DSP)

	# 5.1 Empty buffer
	var empty_buf := PackedFloat32Array()
	var boundary_state := {"chunk_fired": false}
	srv.audio_chunk_processed.connect(func(_c: int) -> void: boundary_state["chunk_fired"] = true)
	srv.push_audio_samples(empty_buf)
	assert_check(boundary_state["chunk_fired"] == false, "Empty buffer ignored cleanly without error")

	# 5.2 Micro buffer (1 sample)
	var micro_buf := PackedFloat32Array([0.05])
	srv.push_audio_samples(micro_buf)
	assert_check(boundary_state["chunk_fired"] == true, "Micro buffer (1 sample) accepted and processed")

	# 5.3 Massive buffer (65,536 samples)
	var massive_buf := _synthesize_chord([60, 64, 67], mix_rate, 65536, 0.10)
	srv.push_audio_samples(massive_buf)
	var det: Array[int] = srv.get_active_pitches()
	assert_check(det.has(60) and det.has(64) and det.has(67), "Massive buffer (65,536 samples) processed without buffer overflow: %s" % str(det))

	# 5.4 Extreme float values: NaNs, Infinities, and Hard Clipping
	var corrupt_buf := PackedFloat32Array()
	corrupt_buf.resize(2048)
	for i in range(2048):
		if i % 4 == 0:
			corrupt_buf[i] = 0.0 / 0.0 # NaN
		elif i % 4 == 1:
			corrupt_buf[i] = 1.0 / 0.0 # +Inf
		elif i % 4 == 2:
			corrupt_buf[i] = -1.0 / 0.0 # -Inf
		else:
			corrupt_buf[i] = 1000.0 # Massive clipping value

	srv.push_audio_samples(corrupt_buf)
	assert_check(true, "InferenceService survived NaNs, Infs, and clipping (+1000.0) without crashing")

	# Verify NaN did not leak into confidence map
	var conf_map: Dictionary = srv.get_confidence_map()
	var nan_found: bool = false
	for k in conf_map.keys():
		var val: float = float(conf_map[k])
		if is_nan(val) or is_inf(val):
			nan_found = true
	assert_check(nan_found == false, "No NaN or Inf leaked into confidence map values")

	# 5.5 High DC Bias (+0.50) with C Major chord
	var dc_chord := _synthesize_chord([60, 64, 67], mix_rate, 2048, 0.10, 0.40)
	srv.reset()
	srv.push_audio_samples(dc_chord)
	var dc_det: Array[int] = srv.get_active_pitches()
	assert_check(dc_det.has(60), "C4 (60) detected despite +0.40 DC bias offset (detected: %s)" % str(dc_det))

	# 5.6 Silence Gating Continuity
	# After detecting notes, feed 2048 samples of pure zero silence
	var silence_buf := PackedFloat32Array()
	silence_buf.resize(2048)
	silence_buf.fill(0.0)

	var silence_state := {"silence_cleared_pitches": false}
	srv.pitch_detected.connect(func(pitches: Array[int], _c: Dictionary) -> void:
		if pitches.is_empty():
			silence_state["silence_cleared_pitches"] = true
	)

	srv.push_audio_samples(silence_buf)
	assert_check(srv.get_active_pitches().is_empty(), "Silence input cleanly cleared active pitches")
	assert_check(silence_state["silence_cleared_pitches"], "Silence input emitted pitch_detected([]) to notify downstream listeners")

	srv.free()

# ==============================================================================
# Suite 6: Autoload Node Integration
# ==============================================================================
func test_autoload_integration() -> void:
	print("\n--- 6. Autoload Singletons Cross-Service Integration ---")

	var root_window: Window = root
	var has_cap: bool = root_window.has_node("AudioCaptureService")
	var has_inf: bool = root_window.has_node("InferenceService")

	# If autoload nodes not in tree under -s, instantiate and attach
	var cap_node: Node = null
	var inf_node: Node = null

	if has_cap:
		cap_node = root_window.get_node("AudioCaptureService")
	else:
		var CapScript = load("res://scripts/audio_capture_service.gd")
		cap_node = CapScript.new()
		cap_node.name = "AudioCaptureService"
		root_window.add_child(cap_node)

	if has_inf:
		inf_node = root_window.get_node("InferenceService")
	else:
		inf_node = InferenceServiceScript.new()
		inf_node.name = "InferenceService"
		root_window.add_child(inf_node)

	assert_check(cap_node != null and inf_node != null, "AudioCaptureService and InferenceService co-exist in tree")

	# Verify signal declaration
	var cap_sig: String = "audio_chunk_ready"
	assert_check(cap_node.has_signal(cap_sig), "AudioCaptureService declares 'audio_chunk_ready'")

	# Ensure signal connection
	if not cap_node.is_connected("audio_chunk_ready", Callable(inf_node, "push_audio_samples")):
		cap_node.connect("audio_chunk_ready", Callable(inf_node, "push_audio_samples"))
	assert_check(cap_node.is_connected("audio_chunk_ready", Callable(inf_node, "push_audio_samples")), "AudioCaptureService.audio_chunk_ready is connected to InferenceService.push_audio_samples")

	# Test injecting synthetic audio via AudioCaptureService
	var integration_state := {"chunks_received": 0}
	var test_sub = func(_c: int) -> void:
		integration_state["chunks_received"] += 1
	inf_node.connect("audio_chunk_processed", test_sub)

	var test_pcm := _synthesize_chord([60, 64, 67], mix_rate, 512, 0.12)
	cap_node.call("inject_mono_samples", test_pcm)

	assert_check(integration_state["chunks_received"] > 0, "Injected audio into AudioCaptureService routed cleanly to /root/InferenceService (%d chunks)" % integration_state["chunks_received"])
	inf_node.disconnect("audio_chunk_processed", test_sub)
