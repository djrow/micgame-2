import os
import sys
import re
from pathlib import Path

def main():
    print("Checking project.godot...")
    with open("project.godot", "r", encoding="utf-8") as f:
        godot_content = f.read()

    assert 'config/name="V2 Polyphonic Microphone Rhythm Game"' in godot_content, "Missing project name"
    assert 'GameManager="*res://scripts/game_manager.gd"' in godot_content, "Missing GameManager autoload"
    assert 'AudioManager="*res://scripts/audio_manager.gd"' in godot_content, "Missing AudioManager autoload"
    assert 'AudioCaptureService="*res://scripts/audio_capture_service.gd"' in godot_content, "Missing AudioCaptureService autoload"
    assert 'InferenceService="*res://scripts/inference_service.gd"' in godot_content, "Missing InferenceService autoload"
    assert 'ScoringService="*res://scripts/scoring_service.gd"' in godot_content, "Missing ScoringService autoload"
    assert 'window/size/viewport_width=1280' in godot_content, "Missing viewport width 1280"
    assert 'window/size/viewport_height=720' in godot_content, "Missing viewport height 720"
    assert 'window/stretch/mode="canvas_items"' in godot_content, "Missing stretch mode canvas_items"
    assert 'window/stretch/aspect="keep"' in godot_content, "Missing stretch aspect keep"
    assert 'window/handheld/orientation="sensor_landscape"' in godot_content, "Missing orientation sensor_landscape"
    assert 'driver/enable_input=true' in godot_content, "Missing audio input driver enable"
    assert 'busses/default_bus_layout="res://default_bus_layout.tres"' in godot_content, "Missing default_bus_layout"
    print("  [PASS] project.godot validated.")

    print("Checking default_bus_layout.tres...")
    with open("default_bus_layout.tres", "r", encoding="utf-8") as f:
        bus_content = f.read()
    assert 'bus/0/name = &"Master"' in bus_content, "Missing Master bus 0"
    assert 'bus/0/mute = false' in bus_content, "Master bus must be unmuted"
    assert 'bus/1/name = &"Record"' in bus_content, "Missing Record bus 1"
    assert 'bus/1/mute = true' in bus_content, "Record bus must be muted"
    assert 'buffer_length = 1.0' in bus_content, "Capture buffer length must be 1.0"
    print("  [PASS] default_bus_layout.tres validated.")

    print("Checking export_presets.cfg...")
    with open("export_presets.cfg", "r", encoding="utf-8") as f:
        preset_content = f.read()

    assert 'architectures/arm64-v8a=true' in preset_content, "Android missing arm64-v8a"
    assert 'architectures/armeabi-v7a=false' in preset_content, "Android armeabi-v7a must be false"
    assert 'permissions/record_audio=true' in preset_content, "Android missing record_audio permission"
    assert 'permissions/modify_audio_settings=true' in preset_content, "Android missing modify_audio_settings permission"
    assert 'binary_format/architecture="x86_64"' in preset_content, "Windows missing x86_64 architecture"
    assert 'binary_format/embed_pck=true' in preset_content, "Windows missing embed_pck"
    assert 'application/app_store_team_id="0000000000"' in preset_content, "iOS missing placeholder app_store_team_id"
    assert 'application/export_project_only=true' in preset_content, "iOS missing export_project_only"
    assert 'user_data/accessible_from_files_app=true' in preset_content, "iOS missing accessible_from_files_app"
    assert 'user_data/accessible_from_itunes_sharing=true' in preset_content, "iOS missing accessible_from_itunes_sharing"
    print("  [PASS] export_presets.cfg validated.")

    print("Checking onnx_pitch.gdextension...")
    with open("onnx_pitch.gdextension", "r", encoding="utf-8") as f:
        gdext_content = f.read()

    assert 'entry_symbol = "onnx_pitch_library_init"' in gdext_content, "Missing entry_symbol"
    assert 'compatibility_minimum = "4.1"' in gdext_content, "Missing compatibility_minimum"
    assert 'windows.debug.x86_64' in gdext_content, "Missing windows library mapping"
    assert 'android.debug.arm64' in gdext_content, "Missing android library mapping"
    print("  [PASS] onnx_pitch.gdextension validated.")

    validate_no_play_in_process()

    print("ALL STATIC CONFIGURATION CHECKS PASSED SUCCESSFULLY!")

def validate_no_play_in_process():
    print("Checking GDScript audio scripts for prohibition of play() in _process() / _physics_process()...")
    scripts = [
        Path("scripts/audio_manager.gd"),
        Path("scripts/audio_capture_service.gd"),
    ]
    total_process_loops = 0
    for script_path in scripts:
        assert script_path.exists(), f"Missing {script_path}"
        code = script_path.read_text(encoding="utf-8")

        # Match _process and _physics_process bodies until next unindented func/class/signal
        matches = list(re.finditer(
            r"func\s+(_(?:physics_)?process)\s*\(.*?\)\s*(?:->\s*void)?:\s*\n((?:\t|[ ]{4}).*?)(?=\nfunc |\nstatic func |\nclass |\nsignal |\Z)",
            code,
            re.DOTALL
        ))
        assert len(matches) > 0, f"Expected process method in {script_path.name}"
        for m in matches:
            total_process_loops += 1
            func_name = m.group(1)
            body = m.group(2)
            for line_no, line in enumerate(body.splitlines(), start=1):
                clean_line = re.sub(r"#.*$", "", line).strip()
                if re.search(r"\bplay\s*\(", clean_line):
                    raise AssertionError(
                        f"PROHIBITED CALL in {script_path.name} {func_name} (line {line_no}): '{clean_line}' violates Blueprint §2.3"
                    )
        print(f"  [PASS] {script_path.name} verified: zero play() calls in process loops.")

    # Also scan any other .gd scripts in scripts/ to ensure no other process loops call play()
    all_gd = list(Path("scripts").glob("*.gd"))
    for gd_file in all_gd:
        if gd_file in scripts:
            continue
        code = gd_file.read_text(encoding="utf-8")
        matches = re.finditer(
            r"func\s+(_(?:physics_)?process)\s*\(.*?\)\s*(?:->\s*void)?:\s*\n((?:\t|[ ]{4}).*?)(?=\nfunc |\nstatic func |\nclass |\nsignal |\Z)",
            code,
            re.DOTALL
        )
        for m in matches:
            total_process_loops += 1
            func_name = m.group(1)
            body = m.group(2)
            for line_no, line in enumerate(body.splitlines(), start=1):
                clean_line = re.sub(r"#.*$", "", line).strip()
                if re.search(r"\bplay\s*\(", clean_line):
                    raise AssertionError(
                        f"PROHIBITED CALL in {gd_file.name} {func_name} (line {line_no}): '{clean_line}' violates Blueprint §2.3"
                    )
        print(f"  [PASS] {gd_file.name} verified: zero play() calls in process loops.")

    print(f"  [PASS] Total process loops audited: {total_process_loops} (all 100% compliant).")

if __name__ == "__main__":
    main()
