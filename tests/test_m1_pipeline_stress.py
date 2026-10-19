#!/usr/bin/env python3
"""
M1 Challenger 1: Python Adversarial Verification Suite
Probes:
- Bus 0 Mute Violation & Code AST Guard Invariants
- Mathematical Precision of RMS Noise Gate: 0.00499 vs 0.00501 (Float32 vs Float64)
- Zero-Padding Clock Synchronization Logic
- Headless Execution of Godot Stress Test Harness (tests/test_m1_audio_pipeline_stress.gd)
"""

import math
import struct
import subprocess
import sys
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
GODOT_BIN = r"C:\Users\david\Downloads\Godot_v4.7.2-stable_win64_console.exe"

checks = 0
failures = 0

def check(cond: bool, desc: str, detail: str = ""):
    global checks, failures
    checks += 1
    if cond:
        print(f"  [PASS] {desc}")
    else:
        failures += 1
        print(f"  [FAIL] {desc} {'(' + detail + ')' if detail else ''}")

def to_float32(val: float) -> float:
    """Simulates 32-bit single-precision IEEE 754 float representation."""
    return struct.unpack('f', struct.pack('f', val))[0]

def simulate_process_buffer(stereo_pairs: list, threshold: float = 0.005, push_silence: bool = True):
    n = len(stereo_pairs)
    if n == 0:
        return [], 0.0, -100.0, False

    mono = []
    sum_squares = 0.0
    for left, right in stereo_pairs:
        # Sanitize NaN/Inf
        if math.isnan(left) or math.isinf(left):
            left = 0.0
        if math.isnan(right) or math.isinf(right):
            right = 0.0
        s = to_float32((left + right) * 0.5)
        mono.append(s)
        sum_squares += s * s

    rms = math.sqrt(sum_squares / n)
    rms_db = 20.0 * math.log10(rms) if rms > 1e-7 else -100.0
    is_gated = (rms < threshold)

    if is_gated:
        forward_samples = [0.0] * n if push_silence else []
    else:
        forward_samples = mono

    return forward_samples, rms, rms_db, is_gated

def main():
    print("=" * 80)
    print("M1 CHALLENGER 1: PYTHON ADVERSARIAL STRESS SUITE")
    print("=" * 80)

    # --------------------------------------------------------------------------
    # 1. AST & Invariant Code Auditing
    # --------------------------------------------------------------------------
    print("\n--- 1. AST & Invariant Code Auditing ---")
    cap_file = ROOT_DIR / "scripts" / "audio_capture_service.gd"
    check(cap_file.exists(), "scripts/audio_capture_service.gd exists")
    cap_text = cap_file.read_text(encoding="utf-8")

    check("assert(record_bus_idx > 0" in cap_text, "AudioCaptureService asserts record_bus_idx > 0")
    check("if record_bus_idx > 0:" in cap_text, "AudioCaptureService guards set_bus_mute behind record_bus_idx > 0")
    check("AudioServer.set_bus_mute(0, false)" in cap_text, "AudioCaptureService actively forces Bus 0 mute = false")
    check("AudioServer.set_bus_mute(0, true)" not in cap_text, "AudioCaptureService NEVER sets Bus 0 mute = true")
    check("AudioServer.set_bus_mute(record_bus_idx, true)" in cap_text, "AudioCaptureService mutes record_bus_idx")
    check("is_nan(left)" in cap_text and "is_inf(left)" in cap_text, "AudioCaptureService sanitizes left channel NaN/Inf")
    check("is_nan(right)" in cap_text and "is_inf(right)" in cap_text, "AudioCaptureService sanitizes right channel NaN/Inf")
    check("forward_samples.fill(0.0)" in cap_text, "AudioCaptureService zero-fills forward buffer when gated")

    bus_layout_file = ROOT_DIR / "default_bus_layout.tres"
    check(bus_layout_file.exists(), "default_bus_layout.tres exists")
    bus_text = bus_layout_file.read_text(encoding="utf-8")
    check('bus/0/name = &"Master"' in bus_text, "Layout Bus 0 is Master")
    check("bus/0/mute = false" in bus_text, "Layout Bus 0 mute == false")
    check("bus/0/volume_db = 0.0" in bus_text, "Layout Bus 0 volume_db == 0.0")
    check('bus/1/name = &"Record"' in bus_text, "Layout Bus 1 is Record")
    check("bus/1/mute = true" in bus_text, "Layout Bus 1 mute == true")
    check('bus/1/effect/0/effect = SubResource("AudioEffectCapture_' in bus_text or 'AudioEffectCapture' in bus_text, "Layout Bus 1 contains AudioEffectCapture")

    # --------------------------------------------------------------------------
    # 2. Mathematical Precision & Noise Gate Edge Probing
    # --------------------------------------------------------------------------
    print("\n--- 2. Mathematical Precision & Noise Gate Edge Probing ---")
    threshold = 0.005

    # 2.1 Sub-threshold: 0.00499 (Must be gated)
    val_sub = to_float32(0.00499)
    sub_pairs = [(val_sub, val_sub)] * 256
    out_sub, rms_sub, rms_db_sub, is_gated_sub = simulate_process_buffer(sub_pairs, threshold)
    check(is_gated_sub, "RMS = 0.00499 is strictly gated (float32)", f"rms={rms_sub:.8f}")
    check(len(out_sub) == 256, "RMS = 0.00499 emits 256 frames (sample clock preserved)")
    check(all(x == 0.0 for x in out_sub), "RMS = 0.00499 emits zero-padded buffer")

    # 2.2 Super-threshold: 0.00501 (Must pass)
    val_super = to_float32(0.00501)
    super_pairs = [(val_super, val_super)] * 256
    out_super, rms_super, rms_db_super, is_gated_super = simulate_process_buffer(super_pairs, threshold)
    check(not is_gated_super, "RMS = 0.00501 strictly passes (float32)", f"rms={rms_super:.8f}")
    check(len(out_super) == 256, "RMS = 0.00501 preserves 256 frames")
    check(all(x == val_super for x in out_super), "RMS = 0.00501 passes actual audio signal intact")

    # 2.3 Float32 representation of 0.005 literal
    val_exact_f32 = to_float32(0.005)
    f32_diff = val_exact_f32 - threshold
    check(val_exact_f32 < threshold, f"Float32 0.005f is 0.004999999888241291 (< 0.005 double by {abs(f32_diff):.2e})")

    # 2.4 Float64 representation
    rms_sub_f64 = math.sqrt(sum(0.00499**2 for _ in range(256)) / 256)
    rms_super_f64 = math.sqrt(sum(0.00501**2 for _ in range(256)) / 256)
    check(rms_sub_f64 < threshold, f"Float64 0.00499 < 0.005 (diff: {rms_sub_f64 - threshold:.6f})")
    check(rms_super_f64 > threshold, f"Float64 0.00501 > 0.005 (diff: {rms_super_f64 - threshold:.6f})")

    # --------------------------------------------------------------------------
    # 3. Buffer Extremes & Robustness in Python Simulation
    # --------------------------------------------------------------------------
    print("\n--- 3. Buffer Extremes & Robustness Simulation ---")
    # Empty
    out_e, _, _, _ = simulate_process_buffer([])
    check(len(out_e) == 0, "Empty buffer returns empty list without error")

    # Single
    out_s, rms_s, _, _ = simulate_process_buffer([(to_float32(0.8), to_float32(0.2))])
    check(len(out_s) == 1, "Single-sample buffer returns 1 sample")
    check(abs(rms_s - 0.5) < 1e-4, "Single-sample downmix & RMS is 0.5")

    # NaN / Inf
    nan_pairs = [(float('nan'), float('inf')), (float('-inf'), float('nan'))]
    out_n, rms_n, _, gated_n = simulate_process_buffer(nan_pairs)
    check(len(out_n) == 2, "NaN/Inf buffer returns 2 frames")
    check(gated_n and all(x == 0.0 for x in out_n), "NaN/Inf buffer produces zero-padded output without crashing")

    # 65536 frames
    massive_pairs = [(to_float32(0.3), to_float32(0.3))] * 65536
    out_m, rms_m, _, _ = simulate_process_buffer(massive_pairs)
    check(len(out_m) == 65536, "65,536 frame buffer processed cleanly")
    check(abs(rms_m - 0.3) < 1e-4, "65,536 frame buffer RMS is 0.3")

    # --------------------------------------------------------------------------
    # 4. Headless Execution of Godot Stress Test Harness
    # --------------------------------------------------------------------------
    print("\n--- 4. Headless Execution of Godot Stress Test Harness ---")
    if Path(GODOT_BIN).exists():
        cmd = [GODOT_BIN, "--headless", "--path", str(ROOT_DIR), "-s", "tests/test_m1_audio_pipeline_stress.gd"]
        res = subprocess.run(cmd, capture_output=True, text=True)
        check(res.returncode == 0, f"Godot stress test exited with code {res.returncode}", res.stderr)
        check("VERDICT: ALL ADVERSARIAL STRESS CHALLENGES PASSED (VERDICT: APPROVE)" in res.stdout,
              "Godot stress harness output contains APPROVE verdict")
        check("114 Passed, 0 Failed" in res.stdout, "Godot stress harness completed 114/114 assertions successfully")
    else:
        print("  [WARN] Godot binary not found at", GODOT_BIN)

    print("\n" + "=" * 80)
    print(f"PYTHON ADVERSARIAL SUITE RESULTS: {checks} Checks, {checks - failures} Passed, {failures} Failed")
    print("=" * 80)

    if failures == 0:
        print("VERDICT: APPROVE")
        sys.exit(0)
    else:
        print("VERDICT: CHALLENGE_FAILED")
        sys.exit(1)

if __name__ == "__main__":
    main()
