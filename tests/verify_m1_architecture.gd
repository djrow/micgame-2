extends SceneTree

var failures: int = 0
var checks: int = 0

# Spy AudioStreamPlayer to detect any runtime play() calls during process ticks
class SpyAudioStreamPlayer extends AudioStreamPlayer:
	var play_count: int = 0
	var last_from_position: float = 0.0

	@warning_ignore("native_method_override")
	func play(from_position: float = 0.0) -> void:
		play_count += 1
		last_from_position = from_position
		# Do NOT call super.play() in headless mock to keep playing == false,
		# faithfully reproducing mobile asynchronous driver delay.

func assert_check(condition: bool, message: String) -> void:
	checks += 1
	if condition:
		print("  [PASS] " + message)
	else:
		failures += 1
		printerr("  [FAIL] " + message)

func _init() -> void:
	print("==================================================")
	print("STARTING M1 CORE ARCHITECTURE VERIFICATION")
	print("==================================================")

	# ----------------------------------------------------
	# 1. Script Loading & Instantiation Verification
	# ----------------------------------------------------
	print("\n--- 1. Script Loading & Instantiation Verification ---")
	var root_window: Window = root

	var gm_script = load("res://scripts/game_manager.gd")
	assert_check(gm_script != null, "scripts/game_manager.gd loads cleanly")
	var gm = gm_script.new()
	root_window.add_child(gm)
	assert_check(gm != null, "GameManager instantiates cleanly as Node")

	var am_script = load("res://scripts/audio_manager.gd")
	assert_check(am_script != null, "scripts/audio_manager.gd loads cleanly")
	var am = am_script.new()
	root_window.add_child(am)
	am._setup_players()
	assert_check(am != null, "AudioManager instantiates cleanly as Node")

	var cap_script = load("res://scripts/audio_capture_service.gd")
	assert_check(cap_script != null, "scripts/audio_capture_service.gd loads cleanly")
	var cap = cap_script.new()
	root_window.add_child(cap)
	assert_check(cap != null, "AudioCaptureService instantiates cleanly as Node")

	var inf_script = load("res://scripts/inference_service.gd")
	assert_check(inf_script != null, "scripts/inference_service.gd loads cleanly")
	var inf = inf_script.new()
	root_window.add_child(inf)
	assert_check(inf != null, "InferenceService instantiates cleanly as Node")

	var sc_script = load("res://scripts/scoring_service.gd")
	assert_check(sc_script != null, "scripts/scoring_service.gd loads cleanly")
	var sc = sc_script.new()
	root_window.add_child(sc)
	assert_check(sc != null, "ScoringService instantiates cleanly as Node")

	# ----------------------------------------------------
	# 2. AudioBus Layout Verification
	# ----------------------------------------------------
	print("\n--- 2. AudioBus Layout & Two-Bus Isolation Verification ---")
	var bus_count: int = AudioServer.bus_count
	assert_check(bus_count >= 2, "AudioServer has at least 2 buses (count = " + str(bus_count) + ")")

	var bus0_name: String = AudioServer.get_bus_name(0)
	assert_check(bus0_name == "Master", "Bus 0 name is 'Master'")
	assert_check(not AudioServer.is_bus_mute(0), "Bus 0 (Master) is UNMUTED")
	assert_check(is_equal_approx(AudioServer.get_bus_volume_db(0), 0.0), "Bus 0 volume is 0.0 dB")

	var bus1_name: String = AudioServer.get_bus_name(1)
	assert_check(bus1_name == "Record", "Bus 1 name is 'Record'")
	assert_check(AudioServer.is_bus_mute(1), "Bus 1 (Record) is MUTED")
	assert_check(AudioServer.get_bus_send(1) == &"" or AudioServer.get_bus_send(1) == StringName(""), "Bus 1 send is empty (prevents acoustic feedback)")

	var effect_found: bool = false
	var effect_count: int = AudioServer.get_bus_effect_count(1)
	assert_check(effect_count >= 1, "Bus 1 has at least 1 effect (count = " + str(effect_count) + ")")
	for i in range(effect_count):
		var eff: AudioEffect = AudioServer.get_bus_effect(1, i)
		if eff is AudioEffectCapture:
			effect_found = true
			var capture_eff: AudioEffectCapture = eff as AudioEffectCapture
			assert_check(is_equal_approx(capture_eff.buffer_length, 1.0), "AudioEffectCapture buffer length is 1.0s")
			break
	assert_check(effect_found, "Bus 1 effect 0 is AudioEffectCapture")

	# ----------------------------------------------------
	# 3. GameManager Functional Verification
	# ----------------------------------------------------
	print("\n--- 3. GameManager Functional Verification ---")
	if gm:
		assert_check(gm.get_state() == gm.GameState.IDLE, "GameManager initial state is IDLE")
		assert_check(gm.get_state_name() == "IDLE", "GameManager state name is 'IDLE'")

		# State machine transitions
		gm.change_state(gm.GameState.PLAYING)
		assert_check(gm.get_state() == gm.GameState.PLAYING, "Transition to PLAYING succeeds")
		gm.change_state(gm.GameState.PAUSED)
		assert_check(gm.get_state() == gm.GameState.PAUSED, "Transition to PAUSED succeeds")
		gm.change_state(gm.GameState.RESULTS)
		assert_check(gm.get_state() == gm.GameState.RESULTS, "Transition to RESULTS succeeds")
		gm.change_state(gm.GameState.IDLE)
		assert_check(gm.get_state() == gm.GameState.IDLE, "Transition back to IDLE succeeds")

		# Bundled piece catalog
		var pieces: Dictionary = gm.get_bundled_pieces()
		assert_check(pieces.has("piece_1_monophonic"), "Catalog contains piece_1_monophonic")
		assert_check(pieces.has("piece_2_harmony"), "Catalog contains piece_2_harmony")
		assert_check(pieces.has("piece_3_polyphonic"), "Catalog contains piece_3_polyphonic")

		# Piece loading
		var load_ok: bool = gm.load_piece("piece_2_harmony")
		assert_check(load_ok, "load_piece('piece_2_harmony') succeeds")
		assert_check(gm.get_current_piece_id() == "piece_2_harmony", "Current piece id updated")

		# Scoring & multiplier logic
		gm.reset_score()
		assert_check(gm.total_score == 0 and gm.current_combo == 0 and gm.multiplier == 1, "reset_score zeroes score, combo, multiplier")

		for i in range(15):
			gm.record_judgment("PERFECT")
		assert_check(gm.current_combo == 15, "15 PERFECT hits yield combo 15")
		assert_check(gm.multiplier == 2, "Combo 15 yields 2x multiplier")

		for i in range(10):
			gm.record_judgment("GOOD")
		assert_check(gm.current_combo == 25, "10 more hits yield combo 25")
		assert_check(gm.multiplier == 3, "Combo 25 yields 3x multiplier")

		gm.record_judgment("MISS")
		assert_check(gm.current_combo == 0, "MISS resets combo to 0")
		assert_check(gm.multiplier == 1, "MISS resets multiplier to 1")
		assert_check(gm.max_combo == 25, "max_combo preserved at 25")

		var summary: Dictionary = gm.get_score_summary()
		assert_check(summary["perfect"] == 15, "Summary reflects 15 perfects")
		assert_check(summary["good"] == 10, "Summary reflects 10 goods")
		assert_check(summary["miss"] == 1, "Summary reflects 1 miss")
		assert_check(summary["max_combo"] == 25, "Summary max combo is 25")
		assert_check(summary["total_notes"] == 26, "Summary total notes is 26")

	# ----------------------------------------------------
	# 4. AudioManager Functional Verification
	# ----------------------------------------------------
	print("\n--- 4. AudioManager Functional Verification ---")
	if am:
		assert_check(am.master_bus_idx == 0, "AudioManager master_bus_idx is 0")
		assert_check(am.record_bus_idx == 1, "AudioManager record_bus_idx is 1")

		# Sub-frame playhead interpolation & time reporting
		assert_check(is_equal_approx(am.get_song_position(), 0.0), "Initial get_song_position() is 0.0")
		assert_check(is_equal_approx(am.get_interpolated_playhead(), 0.0), "Initial get_interpolated_playhead() is 0.0")

		# Headless clock accumulation simulation
		am.is_playing = true
		am._process(0.016)
		assert_check(am.get_song_position() > 0.015, "Headless clock advances with delta accumulation")
		am.stop_music()
		assert_check(is_equal_approx(am.get_song_position(), 0.0), "stop_music() resets playhead to 0.0")

		# Volume and mute controls
		am.set_master_volume_db(-6.0)
		assert_check(is_equal_approx(am.get_master_volume_db(), -6.0), "set_master_volume_db(-6.0) verified")
		am.set_master_volume_db(0.0)
		assert_check(is_equal_approx(am.get_master_volume_db(), 0.0), "set_master_volume_db(0.0) restored")
		assert_check(not am.is_master_muted(), "Master bus is not muted")

		# AudioStreamWAV loop mode verification
		var test_wav := AudioStreamWAV.new()
		am.play_music(test_wav)
		assert_check(test_wav.loop_mode == AudioStreamWAV.LOOP_FORWARD, "AudioManager configures AudioStreamWAV with LOOP_FORWARD")
		am.stop_music()

	# ----------------------------------------------------
	# 5. AudioCaptureService Functional Verification
	# ----------------------------------------------------
	print("\n--- 5. AudioCaptureService Functional Verification ---")
	if cap:
		# Bus 0 Mute Guard
		assert_check(cap.record_bus_idx > 0, "AudioCaptureService record_bus_idx > 0 (Bus 0 is guarded)")
		assert_check(not AudioServer.is_bus_mute(0), "Bus 0 is definitively not muted after capture service init")

		# Stereo Downmix Test
		var stereo_test := PackedVector2Array([
			Vector2(1.0, 1.0),
			Vector2(-0.8, -0.2),
			Vector2(0.5, -0.5),
			Vector2(0.0, 0.0)
		])
		var downmixed: PackedFloat32Array = cap.process_stereo_buffer(stereo_test)
		assert_check(is_equal_approx(downmixed[0], 1.0), "Stereo downmix (1.0, 1.0) -> 1.0")
		assert_check(is_equal_approx(downmixed[1], -0.5), "Stereo downmix (-0.8, -0.2) -> -0.5")
		assert_check(is_equal_approx(downmixed[2], 0.0), "Stereo downmix (0.5, -0.5) -> 0.0")

		# RMS Silence Gating Test (< 0.005 / -46 dB)
		var silent_stereo := PackedVector2Array()
		silent_stereo.resize(256)
		for i in range(256):
			silent_stereo[i] = Vector2(0.001, 0.001) # RMS = 0.001 < 0.005
		var gated_out: PackedFloat32Array = cap.process_stereo_buffer(silent_stereo)
		assert_check(cap.is_currently_gated, "Signal below 0.005 RMS is marked gated")
		assert_check(cap.current_rms < 0.005, "RMS calculated as < 0.005")
		assert_check(gated_out.size() == 256, "Gated output maintains 256 frames (sample-clock synchronization)")
		var all_zero: bool = true
		for s in gated_out:
			if s != 0.0:
				all_zero = false
				break
		assert_check(all_zero, "Gated output is zero-filled to preserve circular sample clock")

		# Oscilloscope Ring Buffer Test
		var scope_samples: PackedFloat32Array = cap.get_oscilloscope_samples()
		assert_check(scope_samples.size() == 512, "Oscilloscope ring buffer has exactly 512 samples")

		# Input Devices Test
		var devices: PackedStringArray = cap.get_input_devices()
		assert_check(devices.size() >= 1, "get_input_devices() returns at least 1 device")
		var dev_switch_ok: bool = cap.set_input_device(devices[0])
		assert_check(dev_switch_ok, "set_input_device() succeeds with primary device")

		# Test Chord Injection Test
		var injected: PackedFloat32Array = cap.inject_test_chord([60, 64, 67], 512, 0.3)
		assert_check(injected.size() == 512, "inject_test_chord injected 512 frames")
		assert_check(cap.current_rms > 0.05, "inject_test_chord generated active RMS > 0.05")
		assert_check(not cap.is_currently_gated, "Active chord is not gated")

	# ----------------------------------------------------
	# 6. Static Code Audit: Strict Prohibition of play() in _process() / _physics_process()
	# ----------------------------------------------------
	print("\n--- 6. Static Code Audit: Strict Prohibition of play() in _process() ---")
	var audio_scripts: Array[String] = [
		"res://scripts/audio_manager.gd",
		"res://scripts/audio_capture_service.gd"
	]

	for script_path in audio_scripts:
		var f := FileAccess.open(script_path, FileAccess.READ)
		assert_check(f != null, "Audio script is accessible: " + script_path)
		if f == null:
			continue
		var script_content: String = f.get_as_text()
		f.close()

		var lines: PackedStringArray = script_content.split("\n")
		var in_process_body: bool = false
		var process_method_name: String = ""
		var violations: Array[String] = []

		for line_idx in range(lines.size()):
			var raw_line: String = lines[line_idx]
			# Strip inline and full-line comments
			var comment_idx: int = raw_line.find("#")
			var code_only: String = raw_line if comment_idx == -1 else raw_line.substr(0, comment_idx)
			var trimmed: String = code_only.strip_edges()

			# Detect start of _process or _physics_process
			if raw_line.begins_with("func _process") or raw_line.begins_with("func _physics_process"):
				in_process_body = true
				process_method_name = raw_line.strip_edges()
				continue
			# Detect boundary of function exit
			elif in_process_body and (
				raw_line.begins_with("func ") or 
				raw_line.begins_with("static func ") or 
				raw_line.begins_with("signal ") or 
				raw_line.begins_with("class_name ") or 
				raw_line.begins_with("class ")
			):
				in_process_body = false
				process_method_name = ""

			# Evaluate lines inside process function body
			if in_process_body and trimmed != "":
				if ".play(" in trimmed or "play(" in trimmed:
					violations.append("Line %d: %s (in %s)" % [line_idx + 1, trimmed, process_method_name])

		assert_check(violations.is_empty(),
			"%s strictly contains NO play() calls inside _process()/_physics_process()" % script_path.get_file())
		for v in violations:
			printerr("    [CONTRACT VIOLATION] " + v)

	# ----------------------------------------------------
	# 7. Runtime Behavioral Verification: Zero play() Invocations in _process()
	# ----------------------------------------------------
	print("\n--- 7. Runtime Behavioral Verification: Zero play() Invocations in _process() ---")

	# Test 7.1: AudioCaptureService under simulated mobile async startup latency
	var spy_cap_script = load("res://scripts/audio_capture_service.gd")
	var spy_cap = spy_cap_script.new()
	var spy_mic := SpyAudioStreamPlayer.new()
	spy_mic.name = "SpyMicPlayer"
	spy_mic.bus = spy_cap.record_bus_name
	if spy_cap._mic_player:
		spy_cap._mic_player.free()
	spy_cap._mic_player = spy_mic
	spy_cap.is_capturing = true

	# Simulate 60 frames (1 second) of active game ticks where AudioStreamPlayer.playing remains false
	# (faithfully reproducing mobile AAudio / OpenSL ES asynchronous start delay)
	for i in range(60):
		spy_cap._process(0.0166)

	assert_check(spy_mic.play_count == 0,
		"AudioCaptureService._process() across 60 frames generated ZERO play() calls under async delay (count = %d)" % spy_mic.play_count)

	# Verify with capture stopped
	spy_cap.is_capturing = false
	for i in range(60):
		spy_cap._process(0.0166)

	assert_check(spy_mic.play_count == 0,
		"AudioCaptureService._process() when idle generated ZERO play() calls (count = %d)" % spy_mic.play_count)

	spy_mic.free()
	spy_cap.free()

	# Test 7.2: AudioManager under simulated playback with playing == false
	var spy_am_script = load("res://scripts/audio_manager.gd")
	var spy_am = spy_am_script.new()
	var spy_music := SpyAudioStreamPlayer.new()
	spy_music.name = "SpyMusicPlayer"
	if spy_am._music_player:
		spy_am._music_player.free()
	spy_am._music_player = spy_music

	spy_am.is_playing = true
	# Music player is not yet playing (async delay)
	for i in range(60):
		spy_am._process(0.0166)

	assert_check(spy_music.play_count == 0,
		"AudioManager._process() across 60 frames generated ZERO play() calls (count = %d)" % spy_music.play_count)

	spy_am.stop_music()
	spy_music.free()
	spy_am.free()

	# Clean up instances
	gm.queue_free()
	am.queue_free()
	cap.queue_free()
	inf.queue_free()
	sc.queue_free()

	# ----------------------------------------------------
	# Summary
	# ----------------------------------------------------
	print("\n==================================================")
	print("VERIFICATION RESULTS: %d Passed, %d Failed" % [checks - failures, failures])
	print("==================================================")

	if failures == 0:
		print("ALL ARCHITECTURAL SPECIFICATIONS VERIFIED SUCCESSFULLY!")
		quit(0)
	else:
		printerr("VERIFICATION FAILED WITH %d ERRORS" % failures)
		quit(1)
