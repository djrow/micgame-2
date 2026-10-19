extends SceneTree

## Deep Adversarial Stress Probe for Milestone 2 Multi-Tier Routing & Fallbacks
## Authored by: m2_iter2_challenger_2 (Empirical Challenger)

const AudioPitchModelScript = preload("res://scripts/inference/audio_pitch_model.gd")
const MockDriverScript = preload("res://scripts/inference/mock_driver.gd")
const NativePitchDetectorScript = preload("res://scripts/inference/native_pitch_detector.gd")
const OnnxNativeDriverScript = preload("res://scripts/inference/onnx_native_driver.gd")
const WebSocketDriverScript = preload("res://scripts/inference/websocket_driver.gd")
const InferenceServiceScript = preload("res://scripts/inference_service.gd")

var total_checks: int = 0
var failure_count: int = 0

func assert_probe(condition: bool, msg: String) -> void:
	total_checks += 1
	if condition:
		print("  [PROBE-PASS] %s" % msg)
	else:
		failure_count += 1
		printerr("  [PROBE-FAIL] %s" % msg)

func _init() -> void:
	print("==================================================================")
	print("DEEP ADVERSARIAL STRESS PROBE: M2 MULTI-TIER ROUTING & FALLBACK")
	print("==================================================================")

	probe_invalid_and_out_of_bounds_tiers()
	probe_stale_signal_isolation_on_tier_switch()
	probe_websocket_corrupted_payloads_and_malformed_urls()
	probe_onnx_driver_corrupt_callables_and_returns()
	probe_extreme_sample_rates_and_denormals()
	probe_huge_buffer_allocations_and_hammering()

	print("\n==================================================================")
	print("PROBE RESULTS: %d Passed, %d Failed (Total: %d)" % [
		total_checks - failure_count, failure_count, total_checks
	])
	print("==================================================================")

	if failure_count == 0:
		print("PROBE VERDICT: ALL DEEP STRESS PROBES PASSED!")
		quit(0)
	else:
		printerr("PROBE VERDICT: DEEP STRESS PROBE FAILED WITH %d DEFECTS!" % failure_count)
		quit(1)

# ==============================================================================
# Probe 1: Invalid and Out-of-Bounds Tiers
# ==============================================================================
func probe_invalid_and_out_of_bounds_tiers() -> void:
	print("\n--- Probe 1: Invalid & Out-of-Bounds Tiers ---")
	var srv: Node = InferenceServiceScript.new()
	srv.auto_connect_audio_capture = false
	srv._ready()

	var invalid_tiers: Array[int] = [-999, -1, 0, 5, 99, 99999]
	for bad_tier in invalid_tiers:
		srv.set_tier(bad_tier)
		assert_probe(srv.active_driver != null, "set_tier(%d) safely defaulted active_driver without crash" % bad_tier)
		assert_probe(srv.get_tier() == bad_tier, "get_tier() returned requested tier %d" % bad_tier)
		var t_name: String = srv.get_tier_name(bad_tier)
		assert_probe(t_name.begins_with("Unknown Tier"), "get_tier_name(%d) returned graceful string: %s" % [bad_tier, t_name])
		assert_probe(srv.is_tier_available(bad_tier) == false, "is_tier_available(%d) returned false" % bad_tier)

		# Push audio into invalid tier
		var test_pcm := PackedFloat32Array([0.0, 0.1, -0.1, 0.0])
		srv.push_audio_samples(test_pcm)
		srv._process(0.016)
		assert_probe(true, "push_audio_samples survived under invalid tier %d" % bad_tier)

	srv.free()

# ==============================================================================
# Probe 2: Stale Signal Isolation Across Tier Switches
# ==============================================================================
func probe_stale_signal_isolation_on_tier_switch() -> void:
	print("\n--- Probe 2: Stale Signal Isolation & Signal Rebinding ---")
	var srv: Node = InferenceServiceScript.new()
	srv.auto_connect_audio_capture = false
	srv._ready()

	# Start on MOCK
	srv.set_tier(srv.ModelTier.MOCK)
	var cached_mock: RefCounted = srv.active_driver
	assert_probe(cached_mock != null, "Active driver is MockDriver")

	var srv_events := {"pitches": 0, "last_pitches": []}
	var pitch_cb = func(p: Array[int], _c: Dictionary) -> void:
		srv_events["pitches"] += 1
		srv_events["last_pitches"] = p.duplicate()
	srv.pitch_detected.connect(pitch_cb)

	# Verify firing while active
	cached_mock.inject_chord([60, 64, 67])
	assert_probe(srv_events["pitches"] == 1, "MockDriver emitted while active (count = 1)")
	assert_probe(srv_events["last_pitches"] == [60, 64, 67], "InferenceService received [60, 64, 67]")

	# Switch to GD_DSP
	srv.set_tier(srv.ModelTier.GD_DSP)
	assert_probe(srv.get_tier() == srv.ModelTier.GD_DSP, "Switched to GD_DSP")

	# Now inject chord on the OLD mock driver directly
	cached_mock.inject_chord([72, 76, 79])
	assert_probe(srv_events["pitches"] == 1, "Stale MockDriver injection did NOT fire InferenceService signal (still count = 1)")

	# Switch back to MOCK
	srv.set_tier(srv.ModelTier.MOCK)
	assert_probe(srv.get_tier() == srv.ModelTier.MOCK, "Switched back to MOCK")

	# Inject chord again on newly reactivated MOCK
	cached_mock.inject_chord([62, 65, 69])
	assert_probe(srv_events["pitches"] == 2, "Reactivated MockDriver emitted cleanly (count = 2)")
	assert_probe(srv_events["last_pitches"] == [62, 65, 69], "InferenceService received [62, 65, 69]")

	srv.pitch_detected.disconnect(pitch_cb)
	srv.free()

# ==============================================================================
# Probe 3: WebSocket Corrupted Payloads & Malformed URLs
# ==============================================================================
func probe_websocket_corrupted_payloads_and_malformed_urls() -> void:
	print("\n--- Probe 3: WebSocket Corrupted Payloads & Malformed URLs ---")

	# 3.1 Malformed URLs
	var malformed_urls: Array[String] = [
		"",
		"not_a_url",
		"://missing_scheme",
		"http://127.0.0.1:8765",
		"ws://999.999.999.999:99999",
		"ws://localhost:-1"
	]

	for url in malformed_urls:
		var drv = WebSocketDriverScript.new(url)
		assert_probe(drv.is_connected == false, "Malformed URL '%s' handled without crash (is_connected = false)" % url)
		drv.poll(0.016)
		drv.push_audio_samples(PackedFloat32Array([0.1, 0.2]))
		assert_probe(true, "push_audio_samples and poll survived malformed URL '%s'" % url)
		drv.disconnect_from_server()

	# 3.2 Corrupted JSON response parser testing
	var ws_drv = WebSocketDriverScript.new("ws://127.0.0.1:8765")
	var corrupt_json_payloads: Array[String] = [
		"",
		"{invalid_json",
		"null",
		"12345",
		"\"string_only\"",
		"[]",
		"{\"type\": \"pitches\", \"pitches\": \"not_an_array\"}",
		"{\"type\": \"pitches\", \"pitches\": [\"not_an_int\", null, 60]}",
		"{\"type\": \"pitches\", \"onsets\": \"not_an_array\"}",
		"{\"type\": \"pitches\", \"confidence\": \"not_a_dict\"}",
		"{\"type\": \"unknown_type\", \"data\": {}}"
	]

	for cj in corrupt_json_payloads:
		ws_drv.call("_parse_json_response", cj)
		assert_probe(true, "WebSocketDriver._parse_json_response survived corrupt payload: %s" % cj.substr(0, 30))

	# 3.3 Corrupted Binary response parser testing
	var corrupt_binary_payloads: Array[PackedByteArray] = [
		PackedByteArray([]),
		PackedByteArray([0]),
		PackedByteArray([1]),
		PackedByteArray([255, 60]), # Claims 255 pitches, but only 1 byte follows
		PackedByteArray([2, 60, 64, 255]), # Claims 255 onsets, but 0 bytes follow
		PackedByteArray([1, 60, 1, 60, 99, 99, 99]) # Valid-ish shape with trailing bytes
	]

	for cb in corrupt_binary_payloads:
		ws_drv.call("_parse_binary_response", cb)
		assert_probe(true, "WebSocketDriver._parse_binary_response survived truncated packet size %d" % cb.size())

	ws_drv.disconnect_from_server()

# ==============================================================================
# Probe 4: OnnxNativeDriver Corrupt Callables and Return Values
# ==============================================================================
func probe_onnx_driver_corrupt_callables_and_returns() -> void:
	print("\n--- Probe 4: OnnxNativeDriver Corrupt Callables & Return Payloads ---")

	# Save original meta if any
	var orig_meta: Variant = null
	if Engine.has_meta("onnx_pitch_native"):
		orig_meta = Engine.get_meta("onnx_pitch_native")

	# 4.1 Non-Callable types in Engine meta
	var bad_metas: Array = [
		123,
		3.14159,
		"STRING_METADATA",
		PackedByteArray([1, 2, 3]),
		Dictionary(),
		Vector2(1.0, 2.0)
	]

	for bm in bad_metas:
		Engine.set_meta("onnx_pitch_native", bm)
		var drv = OnnxNativeDriverScript.new()
		var init_res: bool = drv.initialize()
		assert_probe(init_res == false, "OnnxNativeDriver safely rejected non-Callable metadata type %d" % typeof(bm))

	# 4.2 Callable that returns invalid types (not PackedFloat32Array)
	var bad_callable = func(_cmd: int, _a1 = null, _a2 = null, _a3 = null, _a4 = null) -> Variant:
		return "I AM NOT A PACKED FLOAT ARRAY"

	Engine.set_meta("onnx_pitch_native", bad_callable)
	var drv_corrupt = OnnxNativeDriverScript.new()
	var live_res: Dictionary = drv_corrupt.transcribe_live_window(PackedFloat32Array([0.1, 0.2, 0.3]))
	assert_probe(live_res.get("ok") == false, "transcribe_live_window handled corrupt return type gracefully (ok = false)")

	var full_res: Dictionary = drv_corrupt.transcribe_full_notes(PackedFloat32Array([0.1, 0.2, 0.3]))
	assert_probe(full_res.get("ok") == false, "transcribe_full_notes handled corrupt return type gracefully (ok = false)")

	# 4.3 Callable that returns truncated PackedFloat32Array (< SUMMARY_FLOATS)
	var trunc_callable = func(_cmd: int, _a1 = null, _a2 = null, _a3 = null, _a4 = null) -> Variant:
		return PackedFloat32Array([0.5, 0.5]) # Only 2 floats instead of 352

	Engine.set_meta("onnx_pitch_native", trunc_callable)
	var drv_trunc = OnnxNativeDriverScript.new()
	var trunc_res: Dictionary = drv_trunc.transcribe_live_window(PackedFloat32Array([0.1, 0.2, 0.3]))
	assert_probe(trunc_res.get("ok") == false, "transcribe_live_window handled truncated float array gracefully (ok = false)")

	# Restore original meta
	if orig_meta != null:
		Engine.set_meta("onnx_pitch_native", orig_meta)
	else:
		if Engine.has_meta("onnx_pitch_native"):
			Engine.remove_meta("onnx_pitch_native")

# ==============================================================================
# Probe 5: Extreme Sample Rates & Denormal Floats
# ==============================================================================
func probe_extreme_sample_rates_and_denormals() -> void:
	print("\n--- Probe 5: Extreme Sample Rates & Denormals ---")

	var test_srs: Array[float] = [
		4000.0,   # Very low
		8000.0,   # Standard telephone
		11025.0,  # Quarter CD
		16000.0,  # Speech standard
		22050.0,  # Half CD
		44100.0,  # CD
		48000.0,  # Studio standard
		88200.0,  # High res
		96000.0,  # DVD audio
		192000.0  # Ultra high res
	]

	for sr in test_srs:
		var det = NativePitchDetectorScript.new(sr)
		assert_probe(det.is_model_ready(), "NativePitchDetector ready at %f Hz" % sr)

		# Feed synthetic A4 (440 Hz) at this sample rate
		var buf := PackedFloat32Array()
		buf.resize(2048)
		for i in range(2048):
			var t: float = float(i) / sr
			buf[i] = 0.25 * sin(TAU * 440.0 * t)

		det.push_audio_samples(buf)
		var p: Array[int] = det.get_detected_pitches()
		var lat: float = det.get_last_latency_ms()
		assert_probe(lat >= 0.0 and lat < 50.0, "Latency valid at %f Hz (%f ms)" % [sr, lat])
		assert_probe(not is_nan(lat) and not is_inf(lat), "Latency is finite at %f Hz" % sr)

	# Denormal float feed: 1e-35 to 1e-45
	var det_denorm = NativePitchDetectorScript.new(48000.0)
	var denorm_buf := PackedFloat32Array()
	denorm_buf.resize(2048)
	denorm_buf.fill(1e-38)
	det_denorm.push_audio_samples(denorm_buf)
	assert_probe(det_denorm.get_detected_pitches().is_empty(), "Denormals (1e-38) treated as silence without FP underflow crash")

# ==============================================================================
# Probe 6: Huge Buffer Allocations & Rapid Hammering
# ==============================================================================
func probe_huge_buffer_allocations_and_hammering() -> void:
	print("\n--- Probe 6: Huge Buffer Allocations & Rapid Hammering ---")
	var srv: Node = InferenceServiceScript.new()
	srv.auto_connect_audio_capture = false
	srv._ready()
	srv.set_tier(srv.ModelTier.GD_DSP)

	# 1. 262,144 samples in a single push (~5.46 seconds of 48kHz audio)
	var huge_buf := PackedFloat32Array()
	huge_buf.resize(262144)
	huge_buf.fill(0.02)
	srv.push_audio_samples(huge_buf)
	assert_probe(true, "InferenceService survived 262,144 sample single-shot push without memory error")

	# 2. Rapid rapid tier switching while hammering with prime-sized chunks
	var prime_chunks: Array[int] = [7, 13, 31, 67, 127, 257, 509, 1021]
	for cycle in range(100):
		var chunk_len: int = prime_chunks[cycle % prime_chunks.size()]
		var chunk := PackedFloat32Array()
		chunk.resize(chunk_len)
		chunk.fill(0.05)

		var target_tier: int = (cycle % 4) + 1
		srv.set_tier(target_tier)
		srv.push_audio_samples(chunk)
		srv.pop_recent_onsets()
		srv.get_confidence_map()
		srv._process(0.016)

	assert_probe(srv.is_active, "InferenceService remains active after 100-cycle prime-chunk hammer test")

	srv.free()
