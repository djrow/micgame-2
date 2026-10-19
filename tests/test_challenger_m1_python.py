"""
Adversarial Verification Suite for Milestone M1 Configurations, Serialization, and Lifecycle.
Written by m1_challenger_2 (EMPIRICAL CHALLENGER).
"""

import os
import re
import sys

def run_tests():
    checks_passed = 0
    checks_total = 0
    failures = []

    def check(condition, desc, detail=""):
        nonlocal checks_passed, checks_total
        checks_total += 1
        if condition:
            checks_passed += 1
            print(f"  [PASS] {desc}")
        else:
            msg = f"  [FAIL] {desc} ({detail})" if detail else f"  [FAIL] {desc}"
            print(msg)
            failures.append(msg)

    print("=" * 70)
    print("CHALLENGER 2: PYTHON ADVERSARIAL AUDIT")
    print("=" * 70)

    # --------------------------------------------------------------------------
    # 1. default_bus_layout.tres Audit
    # --------------------------------------------------------------------------
    print("\n--- 1. default_bus_layout.tres Static & Semantic Audit ---")
    bus_path = "default_bus_layout.tres"
    check(os.path.exists(bus_path), "default_bus_layout.tres exists on disk")

    with open(bus_path, "r", encoding="utf-8") as f:
        bus_lines = f.readlines()
    bus_content = "".join(bus_lines)

    check('type="AudioBusLayout"' in bus_content, "Resource type is AudioBusLayout")
    check('[resource]' in bus_content, "Resource section exists")

    # Bus 0 Invariants
    check('bus/0/name = &"Master"' in bus_content, "Bus 0 name is explicitly &\"Master\"")
    check('bus/0/mute = false' in bus_content, "Bus 0 mute is explicitly false")
    check('bus/0/volume_db = 0.0' in bus_content, "Bus 0 volume_db is explicitly 0.0")
    check('bus/0/send = &""' in bus_content, "Bus 0 send is explicitly &\"\"")
    check('bus/0/solo = false' in bus_content, "Bus 0 solo is explicitly false")
    check('bus/0/bypass_fx = false' in bus_content, "Bus 0 bypass_fx is explicitly false")

    # Prevent Bus 0 Serializer Bug
    check('bus/0/name = &"Record"' not in bus_content, "Bus 0 is NEVER assigned &\"Record\"")
    check('bus/0/mute = true' not in bus_content, "Bus 0 is NEVER muted")

    # Bus 1 Invariants
    check('bus/1/name = &"Record"' in bus_content, "Bus 1 name is explicitly &\"Record\"")
    check('bus/1/mute = true' in bus_content, "Bus 1 mute is explicitly true")
    check('bus/1/volume_db = 0.0' in bus_content, "Bus 1 volume_db is explicitly 0.0")
    check('bus/1/send = &""' in bus_content, "Bus 1 send is empty (no feedback loop)")
    check('bus/1/effect/0/effect = SubResource("AudioEffectCapture_mic")' in bus_content, "Bus 1 has AudioEffectCapture effect attached")
    check('bus/1/effect/0/enabled = true' in bus_content, "Bus 1 effect 0 is enabled")

    # Sub-resource check
    check('[sub_resource type="AudioEffectCapture" id="AudioEffectCapture_mic"]' in bus_content, "SubResource AudioEffectCapture declared")
    check('buffer_length = 1.0' in bus_content, "AudioEffectCapture buffer_length == 1.0s")

    # No spurious bus 2+
    check('bus/2/name' not in bus_content, "No extraneous bus 2 defined in default_bus_layout.tres")

    # --------------------------------------------------------------------------
    # 2. export_presets.cfg Audit
    # --------------------------------------------------------------------------
    print("\n--- 2. export_presets.cfg Comprehensive Preset Audit ---")
    cfg_path = "export_presets.cfg"
    check(os.path.exists(cfg_path), "export_presets.cfg exists on disk")

    with open(cfg_path, "r", encoding="utf-8") as f:
        cfg_content = f.read()

    # Runnable Presets Section
    check('[runnable_presets]' in cfg_content, "[runnable_presets] section present")
    check('Android="Android"' in cfg_content, "Android runnable preset defined")
    check('"Windows Desktop"="Windows Desktop"' in cfg_content, "Windows Desktop runnable preset defined")

    # Preset 0: Android
    check('[preset.0]' in cfg_content, "[preset.0] exists")
    check('platform="Android"' in cfg_content, "preset.0 platform is Android")
    check('architectures/arm64-v8a=true' in cfg_content, "Android architectures/arm64-v8a=true")
    check('architectures/armeabi-v7a=false' in cfg_content, "Android architectures/armeabi-v7a=false")
    check('permissions/record_audio=true' in cfg_content, "Android permissions/record_audio=true")
    check('permissions/modify_audio_settings=true' in cfg_content, "Android permissions/modify_audio_settings=true")
    check('screen/immersive_mode=true' in cfg_content, "Android screen/immersive_mode=true")

    # Preset 1: Windows Desktop
    check('[preset.1]' in cfg_content, "[preset.1] exists")
    check('platform="Windows Desktop"' in cfg_content, "preset.1 platform is Windows Desktop")
    check('binary_format/architecture="x86_64"' in cfg_content, "Windows binary_format/architecture=\"x86_64\"")
    check('binary_format/embed_pck=true' in cfg_content, "Windows binary_format/embed_pck=true")
    check('texture_format/s3tc_bptc=true' in cfg_content, "Windows texture_format/s3tc_bptc=true")

    # Preset 2: iOS
    check('[preset.2]' in cfg_content, "[preset.2] exists")
    check('platform="iOS"' in cfg_content, "preset.2 platform is iOS")
    check('application/app_store_team_id="0000000000"' in cfg_content, "iOS app_store_team_id=\"0000000000\" (CI placeholder)")
    check('application/export_project_only=true' in cfg_content, "iOS application/export_project_only=true")
    check('user_data/accessible_from_files_app=true' in cfg_content, "iOS user_data/accessible_from_files_app=true")
    check('user_data/accessible_from_itunes_sharing=true' in cfg_content, "iOS user_data/accessible_from_itunes_sharing=true")
    check('privacy/microphone_usage_description=' in cfg_content, "iOS microphone privacy description present")

    # Filter checks (ONNX models bundling)
    check('include_filter="assets/models/*.onnx"' in cfg_content, "ONNX model include filter configured across presets")

    # --------------------------------------------------------------------------
    # 3. project.godot & Autoload Singletons Audit
    # --------------------------------------------------------------------------
    print("\n--- 3. project.godot & Autoload Singletons Audit ---")
    godot_path = "project.godot"
    check(os.path.exists(godot_path), "project.godot exists on disk")

    with open(godot_path, "r", encoding="utf-8") as f:
        godot_content = f.read()

    # Application details
    check('config/name="V2 Polyphonic Microphone Rhythm Game"' in godot_content, "Application title matches V2")
    check('run/main_scene="res://scenes/main.tscn"' in godot_content, "Main scene configured to res://scenes/main.tscn")
    check(os.path.exists("scenes/main.tscn"), "Main scene file scenes/main.tscn exists")

    # Autoloads
    autoloads = [
        ("GameManager", "scripts/game_manager.gd"),
        ("AudioManager", "scripts/audio_manager.gd"),
        ("AudioCaptureService", "scripts/audio_capture_service.gd"),
        ("InferenceService", "scripts/inference_service.gd"),
        ("ScoringService", "scripts/scoring_service.gd"),
    ]

    for name, rel_path in autoloads:
        expected_line = f'{name}="*res://{rel_path}"'
        check(expected_line in godot_content, f"Autoload {name} declared with singleton '*' flag")
        check(os.path.exists(rel_path), f"Autoload script {rel_path} exists on disk")

        # Check for shadow bug: script should NOT declare `class_name <name>`
        with open(rel_path, "r", encoding="utf-8") as sf:
            script_text = sf.read()
        shadow_pattern = f"class_name {name}"
        check(shadow_pattern not in script_text, f"Script {rel_path} does NOT contain '{shadow_pattern}'")

    # Audio Settings
    check('driver/enable_input=true' in godot_content, "Audio driver enable_input=true")
    check('busses/default_bus_layout="res://default_bus_layout.tres"' in godot_content, "Audio default_bus_layout set")

    # Display Settings
    check('window/size/viewport_width=1280' in godot_content, "Viewport width is 1280")
    check('window/size/viewport_height=720' in godot_content, "Viewport height is 720")
    check('window/stretch/mode="canvas_items"' in godot_content, "Stretch mode is canvas_items")
    check('window/stretch/aspect="keep"' in godot_content, "Stretch aspect is keep")
    check('window/handheld/orientation="sensor_landscape"' in godot_content, "Handheld orientation is sensor_landscape")

    # Rendering Settings
    check('renderer/rendering_method="gl_compatibility"' in godot_content, "Default renderer is gl_compatibility")
    check('renderer/rendering_method.mobile="gl_compatibility"' in godot_content, "Mobile renderer is gl_compatibility")

    # --------------------------------------------------------------------------
    # 4. Critical Lifecycle Guard Checks
    # --------------------------------------------------------------------------
    print("\n--- 4. Critical Lifecycle Invariant Checks ---")

    # AudioCaptureService Bus 0 Mute Guard
    with open("scripts/audio_capture_service.gd", "r", encoding="utf-8") as f:
        cap_code = f.read()
    check("assert(record_bus_idx > 0" in cap_code, "AudioCaptureService asserts record_bus_idx > 0")
    check("if record_bus_idx > 0:" in cap_code, "AudioCaptureService guards muting behind record_bus_idx > 0")
    check("AudioServer.set_bus_mute(0, false)" in cap_code, "AudioCaptureService explicitly unmutes Bus 0")
    check("AudioServer.set_bus_volume_db(0, 0.0)" in cap_code, "AudioCaptureService explicitly restores Bus 0 volume to 0.0")

    # AudioManager play in process guard & LOOP_FORWARD
    with open("scripts/audio_manager.gd", "r", encoding="utf-8") as f:
        am_code = f.read()
    check("AudioStreamWAV.LOOP_FORWARD" in am_code, "AudioManager sets LOOP_FORWARD on AudioStreamWAV")
    # Verify _process code (excluding comments) does NOT call _music_player.play()
    process_func = re.search(r"func _process\(delta: float\) -> void:(.*?)(?=\nfunc |\Z)", am_code, re.DOTALL)
    if process_func:
        proc_body = process_func.group(1)
        code_lines = [l.strip() for l in proc_body.splitlines() if not l.strip().startswith("#")]
        code_has_play = any(".play(" in l for l in code_lines)
        check(not code_has_play, "AudioManager._process() code lines NEVER call .play()")
    else:
        check(False, "Could not find _process in AudioManager")

    # --------------------------------------------------------------------------
    # Summary
    # --------------------------------------------------------------------------
    print("\n" + "=" * 70)
    print(f"AUDIT SUMMARY: {checks_total} Checks, {checks_passed} Passed, {len(failures)} Failed")
    print("=" * 70)

    if failures:
        print("\nFAILURES ENCOUNTERED:")
        for f in failures:
            print(f)
        return False
    else:
        print("\nALL PYTHON AUDIT CHECKS PASSED WITH 100% SUCCESS.")
        return True

if __name__ == "__main__":
    success = run_tests()
    sys.exit(0 if success else 1)
