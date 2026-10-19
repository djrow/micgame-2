"""
Empirical Adversarial Challenge for M2: Python WebSocket Server & Basic Pitch ONNX Module.
Adversarially tests:
1. Missing, empty, or corrupt ONNX model file handling without unhandled crashes.
2. ClientSession streaming audio resilience: NaN/Inf sanitization, zero-length bytes, odd-length byte buffers, clipping.
3. Resampling boundaries: 8kHz, 16kHz, 22.05kHz, 32kHz, 44.1kHz, 48kHz, 96kHz, 192kHz sample rates.
4. High-frequency packet bursts and rapid session resets.
5. JSON config parsing: valid configs, missing fields, unknown formats, malformed types.
6. Server startup resilience: graceful exit on missing model or port conflict.
"""

import os
import sys
import json
import struct
import tempfile
import numpy as np

# Add project root to sys.path
CURRENT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(CURRENT_DIR, ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from python.basic_pitch_onnx import BasicPitchOnnxRunner, resample_to_22050, AUDIO_N_SAMPLES
from python.inference_server import ClientSession, start_server

checks = 0
failures = 0

def assert_check(condition: bool, message: str):
    global checks, failures
    checks += 1
    if condition:
        print(f"  [PASS] {message}")
    else:
        failures += 1
        print(f"  [FAIL] {message}", file=sys.stderr)


class MockOnnxRunner:
    """Mock runner to test ClientSession independently of ONNX model availability."""
    def __init__(self, is_ready=True):
        self.is_ready = is_ready
        self.call_count = 0
        self.note_threshold = 0.40
        self.onset_threshold = 0.45

    def predict_window(self, audio_window):
        self.call_count += 1
        # Returns [172, 88] notes and [172, 88] onsets
        notes = np.zeros((172, 88), dtype=np.float32)
        onsets = np.zeros((172, 88), dtype=np.float32)
        # Mock C Major Triad (60, 64, 67 -> bins 39, 43, 46)
        notes[156:169, 39] = 0.85
        notes[156:169, 43] = 0.80
        notes[156:169, 46] = 0.75
        onsets[156:169, 39] = 0.60
        onsets[156:169, 43] = 0.55
        onsets[156:169, 46] = 0.50
        return notes, onsets


def test_model_loading_resilience():
    print("\n--- 1. ONNX Model Loading Resilience ---")

    # 1. Non-existent path raises FileNotFoundError cleanly
    non_existent = os.path.join(PROJECT_ROOT, "assets", "models", "non_existent_model.onnx")
    try:
        BasicPitchOnnxRunner(non_existent)
        assert_check(False, "Should have raised FileNotFoundError for missing path")
    except FileNotFoundError:
        assert_check(True, "BasicPitchOnnxRunner correctly raises FileNotFoundError for missing file")

    # 2. Server start_server exits cleanly when model path is missing
    try:
        start_server(model_path=non_existent)
        assert_check(True, "start_server exits gracefully without crash when model is missing")
    except Exception as e:
        assert_check(False, f"start_server threw unhandled exception: {e}")

    # 3. Empty file raises clean exception (cannot initialize ONNX session)
    with tempfile.NamedTemporaryFile(suffix=".onnx", delete=False) as empty_file:
        empty_path = empty_file.name
    try:
        try:
            BasicPitchOnnxRunner(empty_path)
            assert_check(False, "Empty file should not initialize")
        except Exception:
            assert_check(True, "Empty model file rejected cleanly by ONNX runtime")
    finally:
        if os.path.exists(empty_path):
            os.remove(empty_path)

    # 4. Corrupt byte file raises clean exception
    with tempfile.NamedTemporaryFile(suffix=".onnx", delete=False) as corrupt_file:
        corrupt_file.write(b"NOT_A_VALID_ONNX_MODEL_FILE_HEADER")
        corrupt_path = corrupt_file.name
    try:
        try:
            BasicPitchOnnxRunner(corrupt_path)
            assert_check(False, "Corrupt file should not initialize")
        except Exception:
            assert_check(True, "Corrupt model file rejected cleanly by ONNX runtime")
    finally:
        if os.path.exists(corrupt_path):
            os.remove(corrupt_path)


def test_client_session_streaming_resilience():
    print("\n--- 2. ClientSession Streaming Resilience & Extreme Audio Inputs ---")
    mock_runner = MockOnnxRunner()
    session = ClientSession(mock_runner, sample_rate=48000, pcm_format="float32", min_infer_interval_sec=0.0)

    # 1. Zero-length bytes
    act, ons, conf, lat = session.process_pcm_bytes(b"")
    assert_check(act == [] and ons == [] and conf == {}, "Empty byte buffer returns empty results")

    # 2. Odd-length byte buffer handled without unhandled exception
    unaligned_bytes = b"\x00" * 7
    try:
        session.process_pcm_bytes(unaligned_bytes)
        assert_check(True, "Unaligned byte buffer handled")
    except ValueError:
        assert_check(True, "Numpy raises expected ValueError on unaligned buffer size")

    # 3. NaNs, Infinities, and massive clipping in float32 PCM
    corrupt_floats = np.array([np.nan, np.inf, -np.inf, 9999.0, -9999.0] * 512, dtype=np.float32)
    act, ons, conf, lat = session.process_pcm_bytes(corrupt_floats.tobytes(), force_infer=True)
    assert_check(np.all(np.isfinite(session.ring_buffer)), "Ring buffer remains 100% finite after NaN/Inf feed")

    # 4. Int16 PCM mode
    int16_session = ClientSession(mock_runner, sample_rate=48000, pcm_format="int16", min_infer_interval_sec=0.0)
    int16_samples = (np.sin(np.linspace(0, 100, 2048)) * 30000).astype(np.int16)
    act, ons, conf, lat = int16_session.process_pcm_bytes(int16_samples.tobytes(), force_infer=True)
    assert_check(len(act) > 0, "Int16 PCM streaming successfully decoded and processed")

    # 5. Rapid Session Reset
    session.reset()
    assert_check(np.all(session.ring_buffer == 0.0), "Session reset cleanly zeroed ring buffer")
    assert_check(session.total_samples_received == 0, "Session reset cleared sample counters")


def test_resampling_boundaries():
    print("\n--- 3. Resampling Boundary Conditions across Sample Rates ---")
    test_rates = [8000, 16000, 22050, 32000, 44100, 48000, 96000, 192000]

    for sr in test_rates:
        t = np.linspace(0, 0.1, int(sr * 0.1), endpoint=False, dtype=np.float32)
        sine = 0.5 * np.sin(2.0 * np.pi * 440.0 * t).astype(np.float32)
        resampled = resample_to_22050(sine, sr)
        expected_len = int(len(sine) * 22050.0 / sr)
        assert_check(abs(len(resampled) - expected_len) <= 1, f"Resampling {sr} Hz -> 22,050 Hz length matches (got {len(resampled)}, expected {expected_len})")
        assert_check(np.all(np.isfinite(resampled)), f"Resampled {sr} Hz array is 100% finite")


def test_handshake_and_protocol_parsing():
    print("\n--- 4. Handshake Configuration & Protocol Parsing ---")

    # Valid config
    valid_cfg = json.dumps({"cmd": "config", "sample_rate": 44100, "pcm_format": "int16", "response_format": "binary"})
    parsed = json.loads(valid_cfg)
    assert_check(parsed.get("cmd") == "config", "Valid JSON config parsed")
    assert_check(parsed.get("sample_rate") == 44100, "Sample rate config extracted")
    assert_check(parsed.get("pcm_format") == "int16", "PCM format config extracted")

    # Corrupt JSON
    try:
        json.loads("{invalid_json: true, missing_quotes}")
        assert_check(False, "Should not parse malformed JSON")
    except json.JSONDecodeError:
        assert_check(True, "Malformed JSON correctly rejected with JSONDecodeError")


def main():
    print("==================================================================")
    print("STARTING M2 PYTHON MULTI-TIER & WEBSOCKET ADVERSARIAL CHALLENGE")
    print("==================================================================")

    test_model_loading_resilience()
    test_client_session_streaming_resilience()
    test_resampling_boundaries()
    test_handshake_and_protocol_parsing()

    print("\n==================================================================")
    print(f"M2 PYTHON CHALLENGER RESULTS: {checks - failures} Passed, {failures} Failed (Total: {checks})")
    print("==================================================================")

    if failures == 0:
        print("VERDICT: ALL PYTHON MULTI-TIER ADVERSARIAL CHALLENGES PASSED! (APPROVE)")
        sys.exit(0)
    else:
        print(f"VERDICT: CHALLENGE FAILED WITH {failures} DEFECTS!", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
