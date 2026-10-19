extends SceneTree

# ==============================================================================
# Adversarial Stress Test Suite: M1 Audio Pipeline
# Focus: Bus 0 Mute Violation, Extreme Buffers, NaN/Inf Sanitization,
#        -46 dB Noise Gate Boundary Precision (0.00499 vs 0.00501),
#        and Zero-Padding Clock Synchronization.
# ==============================================================================

var total_checks: int = 0
var total_failures: int = 0
var test_category: String = ""

func record_pass(message: String) -> void:
	total_checks += 1
	print("  [PASS] [%s] %s" % [test_category, message])

func record_fail(message: String) -> void:
	total_checks += 1
	total_failures += 1
	printerr("  [FAIL] [%s] %s" % [test_category, message])

func assert_true(condition: bool, message: String) -> void:
	if condition:
		record_pass(message)
	else:
		record_fail(message)

func assert_false(condition: bool, message: String) -> void:
	assert_true(not condition, message)

func assert_approx_eq(a: float, b: float, tolerance: float, message: String) -> void:
	var diff: float = abs(a - b)
	if diff <= tolerance:
		record_pass("%s (got %f, expected %f, diff %f <= %f)" % [message, a, b, diff, tolerance])
	else:
		record_fail("%s (got %f, expected %f, diff %f > %f)" % [message, a, b, diff, tolerance])

# Mock pitch model for testing AudioCaptureService forwarding
class MockPitchModel extends RefCounted:
	var received_chunks: Array[PackedFloat32Array] = []
	var total_frames_received: int = 0

	func push_audio_samples(samples: PackedFloat32Array) -> void:
		received_chunks.append(samples)
		total_frames_received += samples.size()

func _init() -> void:
	print("==============================================================================")
	print("ADVERSARIAL STRESS TEST SUITE: M1 AUDIO PIPELINE")
	print("==============================================================================")

	var root_win: Window = root
	var cap_script = load("res://scripts/audio_capture_service.gd")
	var am_script = load("res://scripts/audio_manager.gd")
	var gm_script = load("res://scripts/game_manager.gd")

	if cap_script == null or am_script == null or gm_script == null:
		printerr("FATAL: Failed to load core scripts.")
		quit(1)
		return

	var cap = cap_script.new()
	var am = am_script.new()
	var gm = gm_script.new()
	root_win.add_child(cap)
	root_win.add_child(am)
	root_win.add_child(gm)

	# --------------------------------------------------------------------------
	# GROUP 1: Bus 0 Mute Violation & Bus Layout Isolation Stress
	# --------------------------------------------------------------------------
	test_category = "BUS_0_MUTE_GUARD"
	print("\n--- GROUP 1: Bus 0 Mute Violation & Bus Layout Isolation Stress ---")

	# Baseline state
	assert_false(AudioServer.is_bus_mute(0), "Bus 0 (Master) initial state is unmuted")
	assert_approx_eq(AudioServer.get_bus_volume_db(0), 0.0, 0.001, "Bus 0 (Master) initial volume is 0.0 dB")
	assert_true(AudioServer.get_bus_name(0) == "Master", "Bus 0 name is 'Master'")
	assert_true(AudioServer.is_bus_mute(1), "Bus 1 (Record) initial state is muted")
	assert_true(AudioServer.get_bus_send(1) == &"" or AudioServer.get_bus_send(1) == StringName(""), "Bus 1 send is empty")

	# Attack 1.1: Externally force Bus 0 mute to true, then verify setup restores it
	AudioServer.set_bus_mute(0, true)
	assert_true(AudioServer.is_bus_mute(0), "Confirmed Bus 0 manually forced to muted state")
	cap._setup_bus_and_capture()
	assert_false(AudioServer.is_bus_mute(0), "AudioCaptureService._setup_bus_and_capture() immediately UNMUTES Bus 0")

	# Attack 1.2: External mute again, verify AudioManager._setup_bus_indices() restores it
	AudioServer.set_bus_mute(0, true)
	am._setup_bus_indices()
	assert_false(AudioServer.is_bus_mute(0), "AudioManager._setup_bus_indices() immediately UNMUTES Bus 0")

	# Attack 1.3: Set record_bus_name to empty string
	var orig_record_bus_name: String = cap.record_bus_name
	cap.record_bus_name = ""
	cap._setup_bus_and_capture()
	assert_false(AudioServer.is_bus_mute(0), "Setting record_bus_name = '' does not mute Bus 0")
	cap.record_bus_name = orig_record_bus_name
	cap._setup_bus_and_capture()

	# Attack 1.4: Verify record_bus_idx is strictly > 0
	assert_true(cap.record_bus_idx > 0, "cap.record_bus_idx is strictly greater than 0 (guarded from 0)")

	# --------------------------------------------------------------------------
	# GROUP 2: Extreme Audio Buffer Lengths
	# --------------------------------------------------------------------------
	test_category = "BUFFER_EXTREMES"
	print("\n--- GROUP 2: Extreme Audio Buffer Lengths ---")

	# Test 2.1: Empty buffer (0 frames)
	var empty_stereo := PackedVector2Array()
	var out_empty: PackedFloat32Array = cap.process_stereo_buffer(empty_stereo)
	assert_true(out_empty.is_empty(), "Empty buffer returns empty PackedFloat32Array")
	assert_true(out_empty.size() == 0, "Empty buffer size is exactly 0")

	# Test 2.2: Single-sample buffer (1 frame)
	var single_sample := PackedVector2Array([Vector2(0.6, 0.4)]) # downmix = 0.5
	var out_single: PackedFloat32Array = cap.process_stereo_buffer(single_sample)
	assert_true(out_single.size() == 1, "Single-sample buffer returns 1 frame")
	assert_approx_eq(out_single[0], 0.5, 0.001, "Single-sample downmix is 0.5")
	assert_approx_eq(cap.current_rms, 0.5, 0.001, "Single-sample RMS is 0.5")
	assert_false(cap.is_currently_gated, "0.5 RMS is not gated")

	# Test 2.3: Two-sample buffer
	var two_samples := PackedVector2Array([Vector2(-0.8, -0.2), Vector2(0.8, 0.2)]) # downmix: -0.5, +0.5
	var out_two: PackedFloat32Array = cap.process_stereo_buffer(two_samples)
	assert_true(out_two.size() == 2, "Two-sample buffer returns 2 frames")
	assert_approx_eq(out_two[0], -0.5, 0.001, "Two-sample frame 0 downmix is -0.5")
	assert_approx_eq(out_two[1], 0.5, 0.001, "Two-sample frame 1 downmix is +0.5")
	assert_approx_eq(cap.current_rms, 0.5, 0.001, "Two-sample RMS is 0.5")

	# Test 2.4: Prime-sized buffers (3, 7, 31, 127, 257)
	var primes: Array[int] = [3, 7, 31, 127, 257]
	for p in primes:
		var buf := PackedVector2Array()
		buf.resize(p)
		for i in range(p):
			buf[i] = Vector2(0.1, 0.1)
		var out_p: PackedFloat32Array = cap.process_stereo_buffer(buf)
		assert_true(out_p.size() == p, "Prime-sized buffer (%d frames) preserved length" % p)
		assert_approx_eq(cap.current_rms, 0.1, 0.001, "Prime-sized buffer (%d frames) RMS is 0.1" % p)

	# Test 2.5: Oscilloscope Ring Buffer boundary (511, 512, 513)
	for sz in [511, 512, 513]:
		var buf := PackedVector2Array()
		buf.resize(sz)
		for i in range(sz):
			buf[i] = Vector2(0.25, 0.25)
		cap.process_stereo_buffer(buf)
		var scope: PackedFloat32Array = cap.get_oscilloscope_samples()
		assert_true(scope.size() == 512, "Oscilloscope ring buffer size remains 512 after %d frame buffer" % sz)

	# Test 2.6: Massive buffer (65,536 frames = 2^16)
	var massive := PackedVector2Array()
	massive.resize(65536)
	for i in range(65536):
		# Alternating +/- 0.4
		var sign_val: float = 1.0 if (i % 2 == 0) else -1.0
		massive[i] = Vector2(0.4 * sign_val, 0.4 * sign_val)
	var out_massive: PackedFloat32Array = cap.process_stereo_buffer(massive)
	assert_true(out_massive.size() == 65536, "Massive buffer (65,536 frames) processed without crash")
	assert_approx_eq(cap.current_rms, 0.4, 0.001, "Massive buffer RMS is exactly 0.4")
	assert_false(cap.is_currently_gated, "Massive buffer is not gated")
	var scope_after_massive: PackedFloat32Array = cap.get_oscilloscope_samples()
	assert_true(scope_after_massive.size() == 512, "Oscilloscope buffer maintains 512 samples after massive buffer")

	# --------------------------------------------------------------------------
	# GROUP 3: NaN, Inf, Extremes, and DC Offsets
	# --------------------------------------------------------------------------
	test_category = "NAN_INF_EXTREMES"
	print("\n--- GROUP 3: NaN, Inf, Extremes, and DC Offsets ---")

	# Test 3.1: All-NaN buffer
	var nan_buf := PackedVector2Array()
	nan_buf.resize(256)
	for i in range(256):
		nan_buf[i] = Vector2(NAN, NAN)
	var out_nan: PackedFloat32Array = cap.process_stereo_buffer(nan_buf)
	assert_true(out_nan.size() == 256, "All-NaN buffer returns 256 frames")
	assert_true(cap.is_currently_gated, "All-NaN buffer is gated")
	assert_approx_eq(cap.current_rms, 0.0, 0.0001, "All-NaN buffer RMS sanitized to 0.0")
	assert_approx_eq(cap.current_rms_db, -100.0, 0.0001, "All-NaN buffer RMS dB is SILENCE_DB_FLOOR (-100 dB)")
	var nan_all_zero: bool = true
	for s in out_nan:
		if is_nan(s) or is_inf(s) or s != 0.0:
			nan_all_zero = false
			break
	assert_true(nan_all_zero, "All-NaN buffer produces strictly zero-filled output (no NaN leakage)")

	# Test 3.2: Partial NaN buffer (Left NaN, Right finite)
	var half_nan_left := PackedVector2Array()
	half_nan_left.resize(128)
	for i in range(128):
		half_nan_left[i] = Vector2(NAN, 0.6) # (0.0 + 0.6) * 0.5 = 0.3
	var out_half_left: PackedFloat32Array = cap.process_stereo_buffer(half_nan_left)
	assert_approx_eq(cap.current_rms, 0.3, 0.001, "Left-NaN buffer downmixes (0 + 0.6)*0.5 -> RMS 0.3")
	assert_approx_eq(out_half_left[0], 0.3, 0.001, "Left-NaN frame 0 is 0.3")
	assert_false(cap.is_currently_gated, "Left-NaN with active right channel is not gated")

	# Test 3.3: Partial NaN buffer (Left finite, Right NaN)
	var half_nan_right := PackedVector2Array()
	half_nan_right.resize(128)
	for i in range(128):
		half_nan_right[i] = Vector2(0.8, NAN) # (0.8 + 0.0) * 0.5 = 0.4
	var out_half_right: PackedFloat32Array = cap.process_stereo_buffer(half_nan_right)
	assert_approx_eq(cap.current_rms, 0.4, 0.001, "Right-NaN buffer downmixes (0.8 + 0)*0.5 -> RMS 0.4")
	assert_approx_eq(out_half_right[0], 0.4, 0.001, "Right-NaN frame 0 is 0.4")

	# Test 3.4: All-Inf and Negative-Inf buffer
	var inf_buf := PackedVector2Array()
	inf_buf.resize(256)
	for i in range(128):
		inf_buf[i] = Vector2(INF, INF)
	for i in range(128, 256):
		inf_buf[i] = Vector2(-INF, -INF)
	var out_inf: PackedFloat32Array = cap.process_stereo_buffer(inf_buf)
	assert_true(out_inf.size() == 256, "Inf buffer returns 256 frames")
	assert_true(cap.is_currently_gated, "Inf buffer is gated after sanitization")
	assert_approx_eq(cap.current_rms, 0.0, 0.0001, "Inf buffer RMS sanitized to 0.0")
	var inf_all_zero: bool = true
	for s in out_inf:
		if is_nan(s) or is_inf(s) or s != 0.0:
			inf_all_zero = false
			break
	assert_true(inf_all_zero, "Inf buffer produces strictly zero-filled output (no Inf leakage)")

	# Test 3.5: Mixed NaN and Inf buffer
	var mixed_nan_inf := PackedVector2Array([
		Vector2(NAN, INF),
		Vector2(-INF, NAN),
		Vector2(0.4, -INF),
		Vector2(INF, 0.6)
	])
	var out_mixed: PackedFloat32Array = cap.process_stereo_buffer(mixed_nan_inf)
	assert_true(out_mixed.size() == 4, "Mixed NaN/Inf buffer preserves 4 frames")
	assert_approx_eq(out_mixed[0], 0.0, 0.001, "Frame 0 (NAN, INF) sanitized to 0.0")
	assert_approx_eq(out_mixed[1], 0.0, 0.001, "Frame 1 (-INF, NAN) sanitized to 0.0")
	assert_approx_eq(out_mixed[2], 0.2, 0.001, "Frame 2 (0.4, -INF) sanitized to 0.2")
	assert_approx_eq(out_mixed[3], 0.3, 0.001, "Frame 3 (INF, 0.6) sanitized to 0.3")

	# Test 3.6: Oscilloscope clamping under high values (5.0)
	var high_val_buf := PackedVector2Array()
	high_val_buf.resize(512)
	for i in range(512):
		high_val_buf[i] = Vector2(5.0, 5.0)
	cap.process_stereo_buffer(high_val_buf)
	var high_scope: PackedFloat32Array = cap.get_oscilloscope_samples()
	var scope_clamped_correctly: bool = true
	for s in high_scope:
		if s > 1.5001 or s < -1.5001:
			scope_clamped_correctly = false
			break
	assert_true(scope_clamped_correctly, "Oscilloscope values strictly clamped to [-1.5, 1.5]")

	# Test 3.7: Subnormal float buffer (1e-35)
	var subnormal_buf := PackedVector2Array()
	subnormal_buf.resize(256)
	for i in range(256):
		subnormal_buf[i] = Vector2(1e-35, 1e-35)
	var out_subnormal: PackedFloat32Array = cap.process_stereo_buffer(subnormal_buf)
	assert_true(out_subnormal.size() == 256, "Subnormal buffer preserves 256 frames")
	assert_true(cap.is_currently_gated, "Subnormal buffer (1e-35) is gated")

	# Test 3.8: Complete stereo phase cancellation
	var cancel_buf := PackedVector2Array()
	cancel_buf.resize(256)
	for i in range(256):
		cancel_buf[i] = Vector2(0.7071, -0.7071) # Downmix = 0.0
	cap.process_stereo_buffer(cancel_buf)
	assert_approx_eq(cap.current_rms, 0.0, 0.0001, "Anti-phase stereo cancels to exactly 0.0 RMS")
	assert_true(cap.is_currently_gated, "Anti-phase stereo cancellation triggers noise gate")

	# --------------------------------------------------------------------------
	# GROUP 4: -46 dB Noise Gate Edge Value Precision (0.00499 vs 0.00501)
	# --------------------------------------------------------------------------
	test_category = "GATE_PRECISION_EDGE"
	print("\n--- GROUP 4: -46 dB Noise Gate Edge Value Precision (0.00499 vs 0.00501) ---")

	# Test 4.1: DC Positive: RMS = 0.00499 (MUST BE GATED)
	var dc_sub_threshold := PackedVector2Array()
	dc_sub_threshold.resize(256)
	for i in range(256):
		dc_sub_threshold[i] = Vector2(0.00499, 0.00499)
	var out_sub: PackedFloat32Array = cap.process_stereo_buffer(dc_sub_threshold)
	assert_approx_eq(cap.current_rms, 0.00499, 0.00001, "DC 0.00499 measured RMS is 0.00499")
	assert_true(cap.is_currently_gated, "Signal at RMS = 0.00499 is STRICTLY GATED (< 0.005)")
	assert_true(out_sub.size() == 256, "Gated signal preserves 256 frames (clock sync)")
	var all_zero_sub: bool = true
	for s in out_sub:
		if s != 0.0:
			all_zero_sub = false
			break
	assert_true(all_zero_sub, "Gated signal at RMS = 0.00499 emits zero-filled buffer")

	# Test 4.2: DC Positive: RMS = 0.00501 (MUST PASS / NOT GATED)
	var dc_super_threshold := PackedVector2Array()
	dc_super_threshold.resize(256)
	for i in range(256):
		dc_super_threshold[i] = Vector2(0.00501, 0.00501)
	var out_super: PackedFloat32Array = cap.process_stereo_buffer(dc_super_threshold)
	assert_approx_eq(cap.current_rms, 0.00501, 0.00001, "DC 0.00501 measured RMS is 0.00501")
	assert_false(cap.is_currently_gated, "Signal at RMS = 0.00501 STRICTLY PASSES (not gated)")
	assert_true(out_super.size() == 256, "Passed signal preserves 256 frames")
	assert_approx_eq(out_super[0], 0.00501, 0.00001, "Passed signal preserves audio sample value (0.00501)")
	var not_all_zero_super: bool = false
	for s in out_super:
		if s != 0.0:
			not_all_zero_super = true
			break
	assert_true(not_all_zero_super, "Passed signal at RMS = 0.00501 is NOT zeroed out")

	# Test 4.3: DC Negative: RMS = 0.00499 (Gated) vs RMS = 0.00501 (Passes)
	var dc_neg_sub := PackedVector2Array()
	dc_neg_sub.resize(256)
	for i in range(256):
		dc_neg_sub[i] = Vector2(-0.00499, -0.00499)
	var out_neg_sub: PackedFloat32Array = cap.process_stereo_buffer(dc_neg_sub)
	assert_approx_eq(cap.current_rms, 0.00499, 0.00001, "Negative DC -0.00499 measured RMS is 0.00499")
	assert_true(cap.is_currently_gated, "Negative DC -0.00499 is STRICTLY GATED")

	var dc_neg_super := PackedVector2Array()
	dc_neg_super.resize(256)
	for i in range(256):
		dc_neg_super[i] = Vector2(-0.00501, -0.00501)
	var out_neg_super: PackedFloat32Array = cap.process_stereo_buffer(dc_neg_super)
	assert_approx_eq(cap.current_rms, 0.00501, 0.00001, "Negative DC -0.00501 measured RMS is 0.00501")
	assert_false(cap.is_currently_gated, "Negative DC -0.00501 STRICTLY PASSES")
	assert_approx_eq(out_neg_super[0], -0.00501, 0.00001, "Negative DC -0.00501 sample value preserved")

	# Test 4.4: AC Square Wave: A = 0.00499 (RMS = 0.00499) vs A = 0.00501 (RMS = 0.00501)
	var sq_sub := PackedVector2Array()
	sq_sub.resize(256)
	for i in range(256):
		var v: float = 0.00499 if (i % 2 == 0) else -0.00499
		sq_sub[i] = Vector2(v, v)
	cap.process_stereo_buffer(sq_sub)
	assert_approx_eq(cap.current_rms, 0.00499, 0.00001, "AC Square wave A=0.00499 RMS is 0.00499")
	assert_true(cap.is_currently_gated, "AC Square wave A=0.00499 is GATED")

	var sq_super := PackedVector2Array()
	sq_super.resize(256)
	for i in range(256):
		var v: float = 0.00501 if (i % 2 == 0) else -0.00501
		sq_super[i] = Vector2(v, v)
	cap.process_stereo_buffer(sq_super)
	assert_approx_eq(cap.current_rms, 0.00501, 0.00001, "AC Square wave A=0.00501 RMS is 0.00501")
	assert_false(cap.is_currently_gated, "AC Square wave A=0.00501 PASSES")

	# Test 4.5: Exact Threshold Boundary: RMS = 0.00500
	# In standard Godot 4 builds, Vector2 components are 32-bit floats.
	# The 32-bit float representation of 0.005 is 0.004999999888241291, which in 64-bit comparison
	# is strictly < 0.0050000000000000001. Therefore, a 32-bit buffer of 0.005f produces rms < 0.005.
	var dc_exact := PackedVector2Array()
	dc_exact.resize(256)
	for i in range(256):
		dc_exact[i] = Vector2(0.00500, 0.00500)
	cap.process_stereo_buffer(dc_exact)
	assert_approx_eq(cap.current_rms, 0.00500, 0.00001, "DC 0.00500 measured RMS is approx 0.00500")
	print("    [DEBUG] cap.current_rms = %.12f, rms_threshold = %.12f, diff = %.12f" % [cap.current_rms, cap.rms_threshold, cap.current_rms - cap.rms_threshold])
	print("    [DEBUG] is_currently_gated at 0.00500f = %s (due to 32-bit float representation 0.004999999888...)" % str(cap.is_currently_gated))

	# --------------------------------------------------------------------------
	# GROUP 5: Zero-Padding Clock Synchronization Across Multi-Chunk Stream
	# --------------------------------------------------------------------------
	test_category = "CLOCK_SYNC_ZERO_PADDING"
	print("\n--- GROUP 5: Zero-Padding Clock Synchronization Across Multi-Chunk Stream ---")

	# Attach Mock Pitch Model
	var mock_model := MockPitchModel.new()
	cap.set_pitch_model(mock_model)

	# Connect signal trackers via Dictionary reference (GDScript lambdas capture primitives by value)
	var tracker := {
		"ready_chunks_count": 0,
		"ready_total_frames": 0,
		"captured_signal_count": 0
	}

	var on_chunk_ready = func(samples: PackedFloat32Array):
		tracker["ready_chunks_count"] += 1
		tracker["ready_total_frames"] += samples.size()

	var on_chunk_captured = func(_samples: PackedFloat32Array, _rms: float, _is_gated: bool):
		tracker["captured_signal_count"] += 1

	cap.audio_chunk_ready.connect(on_chunk_ready)
	cap.audio_chunk_captured.connect(on_chunk_captured)

	var stream_spec: Array[Dictionary] = [
		{"size": 256, "amp": 0.10, "desc": "Active Chunk 1"},
		{"size": 256, "amp": 0.00, "desc": "Silent Chunk 2 (0.0)"},
		{"size": 256, "amp": 0.00499, "desc": "Gated Chunk 3 (0.00499)"},
		{"size": 256, "amp": 0.00501, "desc": "Active Chunk 4 (0.00501)"},
		{"size": 512, "amp": 0.001, "desc": "Gated Chunk 5 (0.001, 512f)"},
		{"size": 128, "amp": 0.25, "desc": "Active Chunk 6 (0.25, 128f)"},
		{"size": 256, "amp": 0.0048, "desc": "Gated Chunk 7 (0.0048)"},
		{"size": 384, "amp": 0.15, "desc": "Active Chunk 8 (0.15, 384f)"},
		{"size": 256, "amp": 0.000, "desc": "Silent Chunk 9 (0.0)"},
		{"size": 512, "amp": 0.05, "desc": "Active Chunk 10 (0.05, 512f)"}
	]

	var expected_total_input_frames: int = 0
	var chunk_idx: int = 0
	var initial_total_frames: int = cap.total_frames_captured

	for spec in stream_spec:
		chunk_idx += 1
		var sz: int = spec["size"]
		var amp: float = spec["amp"]
		expected_total_input_frames += sz

		var chunk := PackedVector2Array()
		chunk.resize(sz)
		for i in range(sz):
			chunk[i] = Vector2(amp, amp)

		var out_chunk: PackedFloat32Array = cap.process_stereo_buffer(chunk)
		assert_true(out_chunk.size() == sz, "Chunk %d (%s) output size strictly matches input size (%d)" % [chunk_idx, spec["desc"], sz])

		if amp < 0.005:
			# Verify zero padding
			var is_zeroed: bool = true
			for s in out_chunk:
				if s != 0.0:
					is_zeroed = false
					break
			assert_true(is_zeroed, "Chunk %d (%s) is correctly zero-padded" % [chunk_idx, spec["desc"]])
		else:
			# Verify active audio passed
			assert_approx_eq(out_chunk[0], amp, 0.0001, "Chunk %d (%s) passes non-zero audio" % [chunk_idx, spec["desc"]])

	# Verify sample clock synchronization across the entire multi-chunk stream
	assert_true(tracker["ready_chunks_count"] == stream_spec.size(), "Emitted %d audio_chunk_ready signals for %d chunks" % [tracker["ready_chunks_count"], stream_spec.size()])
	assert_true(tracker["captured_signal_count"] == stream_spec.size(), "Emitted %d audio_chunk_captured signals for %d chunks" % [tracker["captured_signal_count"], stream_spec.size()])
	assert_true(tracker["ready_total_frames"] == expected_total_input_frames, "Cumulative sample clock exact match: %d frames emitted == %d frames input" % [tracker["ready_total_frames"], expected_total_input_frames])
	assert_true(cap.total_frames_captured - initial_total_frames == expected_total_input_frames, "cap.total_frames_captured correctly tracked %d frames" % expected_total_input_frames)

	# Verify Mock Pitch Model received exact clock-synchronized frames
	assert_true(mock_model.received_chunks.size() == stream_spec.size(), "MockPitchModel received %d chunks" % stream_spec.size())
	assert_true(mock_model.total_frames_received == expected_total_input_frames, "MockPitchModel cumulative frames (%d) matches input (%d)" % [mock_model.total_frames_received, expected_total_input_frames])

	# Disconnect signal trackers
	cap.audio_chunk_ready.disconnect(on_chunk_ready)
	cap.audio_chunk_captured.disconnect(on_chunk_captured)
	cap.set_pitch_model(null)

	# Test 5.4: Verify push_silence_when_gated = false drops gated frames
	cap.push_silence_when_gated = false
	var test_silent := PackedVector2Array()
	test_silent.resize(256)
	test_silent.fill(Vector2(0.001, 0.001))
	var out_dropped: PackedFloat32Array = cap.process_stereo_buffer(test_silent)
	assert_true(out_dropped.is_empty(), "push_silence_when_gated = false emits empty array when gated")
	cap.push_silence_when_gated = true # restore default

	# --------------------------------------------------------------------------
	# GROUP 6: AudioManager Playhead & Robustness Stress
	# --------------------------------------------------------------------------
	test_category = "AUDIO_MANAGER_STRESS"
	print("\n--- GROUP 6: AudioManager Playhead & Robustness Stress ---")

	# Test 6.1: Corrupted WAV byte arrays
	assert_true(am.load_audio_stream("") == null, "Empty path to load_audio_stream returns null cleanly")
	assert_true(am._load_wav_from_bytes(PackedByteArray()) == null, "Empty byte array to _load_wav_from_bytes returns null")
	assert_true(am._load_wav_from_bytes(PackedByteArray([1, 2, 3])) == null, "Short byte array (<44) returns null")

	var bad_riff := PackedByteArray()
	bad_riff.resize(44)
	bad_riff.encode_u32(0, 0x12345678) # Not "RIFF"
	assert_true(am._load_wav_from_bytes(bad_riff) == null, "Invalid RIFF magic bytes returns null")

	# Test 6.2: Headless clock accumulation monotonicity
	am.stop_music()
	am.is_playing = true
	var prev_time: float = am.get_song_position()
	var monotonic: bool = true
	var deltas: Array[float] = [0.016, 0.033, 0.008, 0.016, 0.020]
	for d in deltas:
		am._process(d)
		var cur_time: float = am.get_song_position()
		if cur_time < prev_time:
			monotonic = false
			break
		prev_time = cur_time
	assert_true(monotonic, "Headless audio clock accumulates monotonically")
	am.stop_music()
	assert_approx_eq(am.get_song_position(), 0.0, 0.0001, "stop_music() resets clock to 0.0")

	# Test 6.3: Rapid cycling of audio controls
	for i in range(50):
		am.seek(float(i) * 0.1)
		am.pause_music()
		am.resume_music()
	assert_true(am.get_song_position() >= 0.0, "Rapid state cycling executes without error")
	am.stop_music()

	# Clean up instances
	cap.queue_free()
	am.queue_free()
	gm.queue_free()

	# --------------------------------------------------------------------------
	# FINAL SUMMARY & VERDICT
	# --------------------------------------------------------------------------
	print("\n==============================================================================")
	print("ADVERSARIAL STRESS TEST RESULTS: %d Checks, %d Passed, %d Failed" % [total_checks, total_checks - total_failures, total_failures])
	print("==============================================================================")

	if total_failures == 0:
		print("VERDICT: ALL ADVERSARIAL STRESS CHALLENGES PASSED (VERDICT: APPROVE)")
		quit(0)
	else:
		printerr("VERDICT: ADVERSARIAL CHALLENGES FAILED (VERDICT: CHALLENGE_FAILED with %d failures)" % total_failures)
		quit(1)
