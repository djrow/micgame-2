extends SceneTree

var total_tests: int = 0
var passed_tests: int = 0
var failed_tests: int = 0
var findings: Array[String] = []

func log_check(condition: bool, description: String, detail: String = "") -> void:
	total_tests += 1
	if condition:
		passed_tests += 1
		print("  [PASS] ", description)
	else:
		failed_tests += 1
		var err_msg = "  [FAIL] %s %s" % [description, ("(" + detail + ")") if detail != "" else ""]
		printerr(err_msg)
		findings.append(err_msg)

func _init() -> void:
	print("======================================================================")
	print("CHALLENGER 2: ADVERSARIAL VERIFICATION OF CONFIGS & LIFECYCLE")
	print("======================================================================")

	test_default_bus_layout_resource()
	test_bus_routing_and_isolation_lifecycle()
	test_audio_capture_adversarial_guard()
	test_export_presets_cfg_comprehensive()
	test_project_godot_and_autoload_integrity()

	print("\n======================================================================")
	print("CHALLENGE RUN COMPLETE: %d Total, %d Passed, %d Failed" % [total_tests, passed_tests, failed_tests])
	print("======================================================================")

	if failed_tests > 0:
		print("\nFINDINGS / FAILURES:")
		for f in findings:
			print(f)
		quit(1)
	else:
		print("\nALL ADVERSARIAL CHECKS PASSED.")
		quit(0)

# ==============================================================================
# 1. default_bus_layout.tres Direct Resource Parsing & Invariants
# ==============================================================================
func test_default_bus_layout_resource() -> void:
	print("\n--- 1. default_bus_layout.tres Direct Resource Parsing ---")

	var res_path: String = "res://default_bus_layout.tres"
	log_check(ResourceLoader.exists(res_path), "default_bus_layout.tres exists via ResourceLoader")

	var layout: AudioBusLayout = ResourceLoader.load(res_path) as AudioBusLayout
	log_check(layout != null, "default_bus_layout.tres loaded successfully as AudioBusLayout")

	if layout == null:
		return

	# AudioBusLayout is applied to AudioServer to inspect its deserialized state
	AudioServer.set_bus_layout(layout)
	var bus_count: int = AudioServer.bus_count
	log_check(bus_count == 2, "AudioBusLayout defines exactly 2 buses", "found: " + str(bus_count))

	# Bus 0: Master Invariants
	var b0_name: String = AudioServer.get_bus_name(0)
	log_check(b0_name == "Master", "Layout Bus 0 is explicitly named 'Master'", "found: " + b0_name)
	log_check(not AudioServer.is_bus_mute(0), "Layout Bus 0 (Master) mute == false")
	log_check(is_equal_approx(AudioServer.get_bus_volume_db(0), 0.0), "Layout Bus 0 (Master) volume_db == 0.0", "found: " + str(AudioServer.get_bus_volume_db(0)))
	log_check(not AudioServer.is_bus_solo(0), "Layout Bus 0 (Master) solo == false")
	log_check(not AudioServer.is_bus_bypassing_effects(0), "Layout Bus 0 (Master) bypass_fx == false")
	log_check(AudioServer.get_bus_send(0) == &"" or AudioServer.get_bus_send(0) == StringName(""), "Layout Bus 0 (Master) send is empty")

	# Bus 1: Record Invariants
	var b1_name: String = AudioServer.get_bus_name(1)
	log_check(b1_name == "Record", "Layout Bus 1 is named 'Record'", "found: " + b1_name)
	log_check(AudioServer.is_bus_mute(1), "Layout Bus 1 (Record) mute == true")
	log_check(is_equal_approx(AudioServer.get_bus_volume_db(1), 0.0), "Layout Bus 1 (Record) volume_db == 0.0", "found: " + str(AudioServer.get_bus_volume_db(1)))
	log_check(AudioServer.get_bus_send(1) == &"" or AudioServer.get_bus_send(1) == StringName(""), "Layout Bus 1 (Record) send is empty (prevents acoustic feedback loop)")

	# Bus 1: AudioEffectCapture
	var b1_fx_count: int = AudioServer.get_bus_effect_count(1)
	log_check(b1_fx_count >= 1, "Layout Bus 1 has at least 1 effect", "count: " + str(b1_fx_count))
	if b1_fx_count >= 1:
		var eff: AudioEffect = AudioServer.get_bus_effect(1, 0)
		log_check(eff is AudioEffectCapture, "Layout Bus 1 effect 0 is AudioEffectCapture", "type: " + str(eff))
		log_check(AudioServer.is_bus_effect_enabled(1, 0), "Layout Bus 1 effect 0 is enabled")
		if eff is AudioEffectCapture:
			var cap: AudioEffectCapture = eff as AudioEffectCapture
			log_check(is_equal_approx(cap.buffer_length, 1.0), "AudioEffectCapture buffer_length == 1.0s", "found: " + str(cap.buffer_length))

	# File raw text inspection to prevent Godot 4 Serializer Bug
	# (Ensure bus/0 is explicitly serialized and not omitted)
	var f = FileAccess.open(res_path, FileAccess.READ)
	if f != null:
		var content: String = f.get_as_text()
		f.close()
		log_check(content.contains('bus/0/name = &"Master"'), "Raw .tres explicitly contains 'bus/0/name = &\"Master\"'")
		log_check(content.contains('bus/0/mute = false'), "Raw .tres explicitly contains 'bus/0/mute = false'")
		log_check(content.contains('bus/0/volume_db = 0.0'), "Raw .tres explicitly contains 'bus/0/volume_db = 0.0'")
		log_check(content.contains('bus/1/name = &"Record"'), "Raw .tres explicitly contains 'bus/1/name = &\"Record\"'")
		log_check(content.contains('bus/1/mute = true'), "Raw .tres explicitly contains 'bus/1/mute = true'")
		log_check(not content.contains('bus/0/name = &"Record"'), "Raw .tres NEVER assigns Record to bus/0")
	else:
		log_check(false, "Could not open default_bus_layout.tres via FileAccess")

# ==============================================================================
# 2. AudioServer Bus Routing & Two-Bus Isolation Lifecycle
# ==============================================================================
func test_bus_routing_and_isolation_lifecycle() -> void:
	print("\n--- 2. AudioServer Bus Routing & Two-Bus Isolation Lifecycle ---")

	# Apply the layout to AudioServer
	var layout: AudioBusLayout = ResourceLoader.load("res://default_bus_layout.tres") as AudioBusLayout
	if layout != null:
		AudioServer.set_bus_layout(layout)

	log_check(AudioServer.bus_count == 2, "AudioServer bus_count == 2 after layout applied")
	log_check(AudioServer.get_bus_name(0) == "Master", "AudioServer bus 0 is Master")
	log_check(not AudioServer.is_bus_mute(0), "AudioServer bus 0 is unmuted")
	log_check(is_equal_approx(AudioServer.get_bus_volume_db(0), 0.0), "AudioServer bus 0 volume is 0.0 dB")

	log_check(AudioServer.get_bus_name(1) == "Record", "AudioServer bus 1 is Record")
	log_check(AudioServer.is_bus_mute(1), "AudioServer bus 1 is muted")
	log_check(AudioServer.get_bus_send(1) == &"" or AudioServer.get_bus_send(1) == StringName(""), "AudioServer bus 1 send is empty")

	var effect: AudioEffect = AudioServer.get_bus_effect(1, 0)
	log_check(effect is AudioEffectCapture, "AudioServer bus 1 effect 0 is AudioEffectCapture")
	if effect is AudioEffectCapture:
		log_check(is_equal_approx((effect as AudioEffectCapture).buffer_length, 1.0), "AudioServer AudioEffectCapture buffer_length == 1.0s")

# ==============================================================================
# 3. AudioCaptureService Adversarial Guard Testing
# ==============================================================================
func test_audio_capture_adversarial_guard() -> void:
	print("\n--- 3. AudioCaptureService Adversarial Guard & Stress Testing ---")

	var cap_script = load("res://scripts/audio_capture_service.gd")
	log_check(cap_script != null, "scripts/audio_capture_service.gd loaded")
	if cap_script == null:
		return

	var cap = cap_script.new()
	root.add_child(cap)

	# Verify initialization didn't mute Master
	log_check(cap.record_bus_idx > 0, "AudioCaptureService record_bus_idx > 0", "idx: " + str(cap.record_bus_idx))
	log_check(not AudioServer.is_bus_mute(0), "Master bus (0) is NOT muted after AudioCaptureService init")

	# Adversarial input: NaN / Inf float values to process_stereo_buffer
	var nan_stereo := PackedVector2Array([
		Vector2(NAN, 0.5),
		Vector2(INF, -INF),
		Vector2(-NAN, 0.0)
	])
	var sanitized_out: PackedFloat32Array = cap.process_stereo_buffer(nan_stereo)
	var has_nan_or_inf: bool = false
	for s in sanitized_out:
		if is_nan(s) or is_inf(s):
			has_nan_or_inf = true
			break
	log_check(not has_nan_or_inf, "process_stereo_buffer sanitizes NaN and Inf gracefully")

	# Gating silence test: pure silence
	var silent := PackedVector2Array()
	silent.resize(256)
	silent.fill(Vector2.ZERO)
	var gated_out: PackedFloat32Array = cap.process_stereo_buffer(silent)
	log_check(cap.is_currently_gated, "Zero signal is gated")
	log_check(gated_out.size() == 256, "Zero signal returns 256 zero frames to maintain sample clock")

	# Boundary test: RMS just below 0.005 threshold (0.0049)
	var boundary_low := PackedVector2Array()
	boundary_low.resize(256)
	boundary_low.fill(Vector2(0.0049, 0.0049))
	cap.process_stereo_buffer(boundary_low)
	log_check(cap.is_currently_gated, "Signal at RMS 0.0049 is gated (< 0.005)")

	# Boundary test: RMS just above 0.005 threshold (0.0051)
	var boundary_high := PackedVector2Array()
	boundary_high.resize(256)
	boundary_high.fill(Vector2(0.0051, 0.0051))
	cap.process_stereo_buffer(boundary_high)
	log_check(not cap.is_currently_gated, "Signal at RMS 0.0051 is NOT gated (>= 0.005)")

	# Invalid device selection
	var invalid_dev_result = cap.set_input_device("NonExistentAudioDeviceXYZ12345")
	log_check(not invalid_dev_result, "set_input_device() safely rejects non-existent device")

	# Clean up
	cap.queue_free()

# ==============================================================================
# 4. export_presets.cfg Comprehensive Configuration Testing
# ==============================================================================
func test_export_presets_cfg_comprehensive() -> void:
	print("\n--- 4. export_presets.cfg Comprehensive Validation ---")

	var cf := ConfigFile.new()
	var err = cf.load("res://export_presets.cfg")
	log_check(err == OK, "export_presets.cfg parses cleanly via Godot ConfigFile", "err: " + str(err))
	if err != OK:
		return

	# Preset sections check
	log_check(cf.has_section("preset.0"), "export_presets.cfg defines [preset.0] (Android)")
	log_check(cf.has_section("preset.0.options"), "export_presets.cfg defines [preset.0.options]")
	log_check(cf.has_section("preset.1"), "export_presets.cfg defines [preset.1] (Windows)")
	log_check(cf.has_section("preset.1.options"), "export_presets.cfg defines [preset.1.options]")
	log_check(cf.has_section("preset.2"), "export_presets.cfg defines [preset.2] (iOS)")
	log_check(cf.has_section("preset.2.options"), "export_presets.cfg defines [preset.2.options]")

	# --- Android (preset.0) ---
	var a_platform = cf.get_value("preset.0", "platform", "")
	log_check(a_platform == "Android", "Preset 0 platform is 'Android'", "found: " + a_platform)

	var arm64 = cf.get_value("preset.0.options", "architectures/arm64-v8a", false)
	log_check(arm64 == true, "Android architectures/arm64-v8a == true")

	var armv7 = cf.get_value("preset.0.options", "architectures/armeabi-v7a", true)
	log_check(armv7 == false, "Android architectures/armeabi-v7a == false (Pixel 7a 64-bit pure)")

	var rec_audio = cf.get_value("preset.0.options", "permissions/record_audio", false)
	log_check(rec_audio == true, "Android permissions/record_audio == true")

	var mod_audio = cf.get_value("preset.0.options", "permissions/modify_audio_settings", false)
	log_check(mod_audio == true, "Android permissions/modify_audio_settings == true")

	# Check renderer configuration
	# Note: In Godot 4, renderer is set in project.godot (rendering/renderer/rendering_method.mobile).
	# We also check whether export_presets.cfg has any renderer setting or if project.godot governs it.
	var project_mobile_renderer: String = ProjectSettings.get_setting("rendering/renderer/rendering_method.mobile", "")
	var project_main_renderer: String = ProjectSettings.get_setting("rendering/renderer/rendering_method", "")
	log_check(project_mobile_renderer == "gl_compatibility" or project_main_renderer == "gl_compatibility",
		"Renderer for mobile / Android is gl_compatibility in ProjectSettings",
		"main: " + project_main_renderer + ", mobile: " + project_mobile_renderer)

	# --- Windows Desktop (preset.1) ---
	var w_platform = cf.get_value("preset.1", "platform", "")
	log_check(w_platform == "Windows Desktop", "Preset 1 platform is 'Windows Desktop'", "found: " + w_platform)

	var w_arch = cf.get_value("preset.1.options", "binary_format/architecture", "")
	log_check(w_arch == "x86_64", "Windows binary_format/architecture == 'x86_64'", "found: " + w_arch)

	var w_embed = cf.get_value("preset.1.options", "binary_format/embed_pck", false)
	log_check(w_embed == true, "Windows binary_format/embed_pck == true")

	# --- iOS (preset.2) ---
	var ios_platform = cf.get_value("preset.2", "platform", "")
	log_check(ios_platform == "iOS", "Preset 2 platform is 'iOS'", "found: " + ios_platform)

	var ios_team = cf.get_value("preset.2.options", "application/app_store_team_id", "")
	log_check(ios_team == "0000000000", "iOS application/app_store_team_id == '0000000000'", "found: " + ios_team)

	var ios_export_proj = cf.get_value("preset.2.options", "application/export_project_only", false)
	log_check(ios_export_proj == true, "iOS application/export_project_only == true")

	var ios_files_app = cf.get_value("preset.2.options", "user_data/accessible_from_files_app", false)
	log_check(ios_files_app == true, "iOS user_data/accessible_from_files_app == true")

	var ios_itunes = cf.get_value("preset.2.options", "user_data/accessible_from_itunes_sharing", false)
	log_check(ios_itunes == true, "iOS user_data/accessible_from_itunes_sharing == true")

# ==============================================================================
# 5. project.godot & Autoload Singletons Integrity
# ==============================================================================
func test_project_godot_and_autoload_integrity() -> void:
	print("\n--- 5. project.godot & Autoload Singletons Integrity ---")

	# ProjectSettings verification
	log_check(ProjectSettings.has_setting("application/config/name"), "ProjectSettings has application/config/name")
	var app_name: String = ProjectSettings.get_setting("application/config/name", "")
	log_check(app_name == "V2 Polyphonic Microphone Rhythm Game", "Application name matches V2 title", "found: " + app_name)

	# Audio settings
	var enable_input: bool = ProjectSettings.get_setting("audio/driver/enable_input", false)
	log_check(enable_input == true, "ProjectSettings audio/driver/enable_input == true")

	var bus_layout: String = ProjectSettings.get_setting("audio/busses/default_bus_layout", "")
	log_check(bus_layout == "res://default_bus_layout.tres", "ProjectSettings default_bus_layout == 'res://default_bus_layout.tres'", "found: " + bus_layout)

	# Display settings
	var vp_w: int = ProjectSettings.get_setting("display/window/size/viewport_width", 0)
	var vp_h: int = ProjectSettings.get_setting("display/window/size/viewport_height", 0)
	log_check(vp_w == 1280 and vp_h == 720, "Display viewport is 1280x720", "found: %dx%d" % [vp_w, vp_h])

	var stretch_mode: String = ProjectSettings.get_setting("display/window/stretch/mode", "")
	log_check(stretch_mode == "canvas_items", "Display stretch mode is 'canvas_items'", "found: " + stretch_mode)

	var stretch_aspect: String = ProjectSettings.get_setting("display/window/stretch/aspect", "")
	log_check(stretch_aspect == "keep", "Display stretch aspect is 'keep' (letterbox/pillarbox safe)", "found: " + stretch_aspect)

	var orientation: String = ProjectSettings.get_setting("display/window/handheld/orientation", "")
	log_check(orientation == "sensor_landscape", "Display handheld orientation is 'sensor_landscape'", "found: " + orientation)

	# Autoload Singletons
	var required_autoloads: Dictionary = {
		"GameManager": "res://scripts/game_manager.gd",
		"AudioManager": "res://scripts/audio_manager.gd",
		"AudioCaptureService": "res://scripts/audio_capture_service.gd",
		"InferenceService": "res://scripts/inference_service.gd",
		"ScoringService": "res://scripts/scoring_service.gd"
	}

	var cf := ConfigFile.new()
	cf.load("res://project.godot")
	log_check(cf.has_section("autoload"), "project.godot defines [autoload] section")

	for auto_name in required_autoloads.keys():
		var expected_path: String = required_autoloads[auto_name]
		log_check(cf.has_section_key("autoload", auto_name), "Autoload registered in project.godot: " + auto_name)

		var raw_val: String = cf.get_value("autoload", auto_name, "")
		# In Godot 4 autoloads with singleton enabled start with '*'
		var path_clean: String = raw_val.trim_prefix("*")
		log_check(path_clean == expected_path, "Autoload " + auto_name + " path matches expected", "found: " + raw_val)
		log_check(FileAccess.file_exists(path_clean), "Autoload script exists on filesystem: " + path_clean)

		# Script compilation and load test
		var script = load(path_clean)
		log_check(script != null, "Autoload script compiles cleanly: " + path_clean)
		if script != null:
			var inst = script.new()
			log_check(inst != null, "Autoload script instantiates cleanly as Node: " + auto_name)
			if inst is Node:
				inst.queue_free()

			# Check that script source doesn't declare 'class_name <auto_name>'
			# which triggers Godot 4 singleton shadow warning/error
			var f_src = FileAccess.open(path_clean, FileAccess.READ)
			if f_src != null:
				var src_text: String = f_src.get_as_text()
				f_src.close()
				var class_name_pattern: String = "class_name " + auto_name
				log_check(not src_text.contains(class_name_pattern),
					"Autoload " + auto_name + " does not define conflicting 'class_name " + auto_name + "'")
