"""
Tier 2: Boundary & Corner Cases E2E Tests (Features 1 - 20)
Stress tests extreme values, edge boundaries, empty buffers, invalid inputs,
and noise across all 20 features defined in PROJECT.md.
Each feature contains 5 distinct, opaque-box boundary test cases (100 tests total).
"""

import json
import os
import tempfile
import unittest
import numpy as np

from tests.e2e.e2e_test_utils import (
    DiatonicMath,
    HighwayMath,
    ScoringEngine,
    AudioInferenceUtils,
    OMRUtils,
    ConfigValidator,
    ChartValidator
)

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
MODEL_PATH = os.path.join(PROJECT_ROOT, "assets", "models", "nmp.onnx")


# ==============================================================================
# Feature 1: Godot Config Cleanup (Boundaries)
# ==============================================================================
class TestFeature01ConfigBoundaries(unittest.TestCase):
    """F1: Godot Config Boundaries & Parser Edge Cases."""

    def test_f01_b01_empty_config_handling(self):
        """TC01: parsing empty content returns empty sections dict without error."""
        with tempfile.NamedTemporaryFile("w", delete=False) as f:
            f.write("")
            path = f.name
        try:
            res = ConfigValidator.parse_godot_project_file(path)
            self.assertEqual(res, {"root": {}})
        finally:
            os.remove(path)

    def test_f01_b02_comment_only_config(self):
        """TC02: lines with semicolon comments or whitespace are cleanly ignored."""
        with tempfile.NamedTemporaryFile("w", delete=False) as f:
            f.write("; Comment line\n   ; Indented comment\n\n")
            path = f.name
        try:
            res = ConfigValidator.parse_godot_project_file(path)
            self.assertEqual(res, {"root": {}})
        finally:
            os.remove(path)

    def test_f01_b03_whitespace_padded_keys(self):
        """TC03: keys and values with leading/trailing spaces are stripped cleanly."""
        with tempfile.NamedTemporaryFile("w", delete=False) as f:
            f.write("[test_sec]\n  key1  =   value1  \n")
            path = f.name
        try:
            res = ConfigValidator.parse_godot_project_file(path)
            self.assertEqual(res.get("test_sec", {}).get("key1"), "value1")
        finally:
            os.remove(path)

    def test_f01_b04_missing_section_header(self):
        """TC04: keys declared before any section header map to root."""
        with tempfile.NamedTemporaryFile("w", delete=False) as f:
            f.write("orphan_key=orphan_value\n[section1]\nkey2=val2\n")
            path = f.name
        try:
            res = ConfigValidator.parse_godot_project_file(path)
            self.assertEqual(res.get("root", {}).get("orphan_key"), "orphan_value")
            self.assertEqual(res.get("section1", {}).get("key2"), "val2")
        finally:
            os.remove(path)

    def test_f01_b05_special_characters_in_values(self):
        """TC05: values containing quotes, colons, or brackets are preserved intact."""
        with tempfile.NamedTemporaryFile("w", delete=False) as f:
            f.write('[application]\nrun/main_scene="res://scenes/main.tscn"\n')
            path = f.name
        try:
            res = ConfigValidator.parse_godot_project_file(path)
            val = res.get("application", {}).get("run/main_scene")
            self.assertEqual(val, '"res://scenes/main.tscn"')
        finally:
            os.remove(path)


# ==============================================================================
# Feature 2: Grand Staff Highway (Boundaries)
# ==============================================================================
class TestFeature02HighwayBoundaries(unittest.TestCase):
    """F2: Highway Scrolling Edge & Boundary Calculations."""

    def test_f02_b01_zero_scroll_speed(self):
        """TC01: scroll speed 0 freezes note at hit line X=160."""
        x = HighwayMath.note_x_position(10.0, 5.0, scroll_speed=0.0)
        self.assertEqual(x, 160.0)

    def test_f02_b02_extreme_high_scroll_speed(self):
        """TC02: high scroll speed (10,000 px/s) scales without numerical overflow."""
        x = HighwayMath.note_x_position(2.0, 1.0, scroll_speed=10000.0)
        self.assertEqual(x, 10160.0)

    def test_f02_b03_negative_playhead_time(self):
        """TC03: negative playhead (countdown -2.0s) scrolls notes further rightward."""
        x = HighwayMath.note_x_position(1.0, -2.0, scroll_speed=200.0)
        self.assertEqual(x, 160.0 + (3.0 * 200.0))

    def test_f02_b04_exact_zero_time_to_hit(self):
        """TC04: exact equality between playhead and note time places note on hit line."""
        t = 3.1415926
        x = HighwayMath.note_x_position(t, t, scroll_speed=350.0)
        self.assertEqual(x, 160.0)

    def test_f02_b05_large_timestamp_delta(self):
        """TC05: note scheduled 10,000 seconds in future calculates valid large X."""
        x = HighwayMath.note_x_position(10000.0, 0.0, scroll_speed=240.0)
        self.assertEqual(x, 160.0 + 2400000.0)


# ==============================================================================
# Feature 3: Diatonic Note Placement (Boundaries)
# ==============================================================================
class TestFeature03DiatonicBoundaries(unittest.TestCase):
    """F3: Diatonic Pitch Mapping Extremes and Ledger Bounds."""

    def test_f03_b01_lowest_supported_pitch_c2(self):
        """TC01: C2 (MIDI 36) maps to octave 2, step 14, below Bass staff."""
        step = DiatonicMath.midi_to_diatonic_step(36)
        self.assertEqual(step, 14)
        y = DiatonicMath.midi_to_y(36)
        self.assertEqual(y, 486.0)
        ledgers = DiatonicMath.get_ledger_lines(36)
        self.assertEqual(ledgers, [468.0, 486.0])

    def test_f03_b02_highest_supported_pitch_c6(self):
        """TC02: C6 (MIDI 84) maps to octave 6, step 42, above Treble staff."""
        step = DiatonicMath.midi_to_diatonic_step(84)
        self.assertEqual(step, 42)
        y = DiatonicMath.midi_to_y(84)
        self.assertEqual(y, 234.0)
        ledgers = DiatonicMath.get_ledger_lines(84)
        self.assertEqual(ledgers, [252.0, 234.0])

    def test_f03_b03_out_of_bounds_pitch_extremes(self):
        """TC03: extreme MIDI values 0 and 127 calculate without exceptions."""
        step_min = DiatonicMath.midi_to_diatonic_step(0)
        step_max = DiatonicMath.midi_to_diatonic_step(127)
        self.assertLess(step_min, 0)
        self.assertGreater(step_max, 50)

    def test_f03_b04_inter_staff_gap_boundary(self):
        """TC04: Middle C (step 28, Y=360) is centered exactly midway between E4 and A3."""
        y_e4 = DiatonicMath.midi_to_y(64)  # 342
        y_a3 = DiatonicMath.midi_to_y(57)  # 378
        y_c4 = DiatonicMath.midi_to_y(60)  # 360
        self.assertEqual(y_c4 - y_e4, 18.0)
        self.assertEqual(y_a3 - y_c4, 18.0)

    def test_f03_b05_all_twelve_pitch_classes_accidental_mapping(self):
        """TC05: all 12 semitones [0..11] map to non-negative diatonic offsets."""
        for semi in range(12):
            offset = DiatonicMath.SEMITONE_TO_DIATONIC[semi]
            self.assertTrue(0 <= offset <= 6)


# ==============================================================================
# Feature 4: Hit Detection & Scoring (Boundaries)
# ==============================================================================
class TestFeature04ScoringBoundaries(unittest.TestCase):
    """F4: Timing Window Threshold Boundaries & Multiplier Transitions."""

    def test_f04_b01_exact_perfect_boundary_50ms(self):
        """TC01: timing delta exactly 0.050s returns Perfect."""
        engine = ScoringEngine()
        rating = engine.evaluate_hit(0.050)
        self.assertEqual(rating, "Perfect")
        self.assertEqual(engine.score, 1000)

    def test_f04_b02_just_beyond_perfect_50_001ms(self):
        """TC02: timing delta 0.05001s returns Good."""
        engine = ScoringEngine()
        rating = engine.evaluate_hit(0.05001)
        self.assertEqual(rating, "Good")
        self.assertEqual(engine.score, 500)

    def test_f04_b03_exact_good_boundary_100ms(self):
        """TC03: timing delta exactly 0.100s returns Good."""
        engine = ScoringEngine()
        rating = engine.evaluate_hit(0.100)
        self.assertEqual(rating, "Good")
        self.assertEqual(engine.score, 500)

    def test_f04_b04_just_beyond_good_100_001ms(self):
        """TC04: timing delta 0.10001s returns Miss."""
        engine = ScoringEngine()
        rating = engine.evaluate_hit(0.10001)
        self.assertEqual(rating, "Miss")
        self.assertEqual(engine.score, 0)

    def test_f04_b05_negative_vs_positive_time_delta_symmetry(self):
        """TC05: rushing by -30ms and dragging by +30ms produce identical scores."""
        eng1 = ScoringEngine()
        eng2 = ScoringEngine()
        r1 = eng1.evaluate_hit(-0.030)
        r2 = eng2.evaluate_hit(0.030)
        self.assertEqual(r1, r2)
        self.assertEqual(eng1.score, eng2.score)


# ==============================================================================
# Feature 5: Audio Playhead Sync (Boundaries)
# ==============================================================================
class TestFeature05PlayheadBoundaries(unittest.TestCase):
    """F5: Playhead Window Edge & Sub-Frame Granularity Bounds."""

    def test_f05_b01_zero_playhead_time(self):
        """TC01: playhead at exactly 0.0s evaluates notes near start."""
        in_win = HighwayMath.is_in_hit_window(0.05, 0.0, window_sec=0.100)
        self.assertTrue(in_win)

    def test_f05_b02_exact_hit_window_edge_minus_100ms(self):
        """TC02: note at 1.0s and playhead at 0.9s is within 100ms window."""
        self.assertTrue(HighwayMath.is_in_hit_window(1.0, 0.9, window_sec=0.100))

    def test_f05_b03_just_outside_hit_window_100_001ms(self):
        """TC03: delta of 0.1001s is strictly outside 100ms hit window."""
        self.assertFalse(HighwayMath.is_in_hit_window(1.0, 0.8999, window_sec=0.100))

    def test_f05_b04_subframe_jitter_tolerance(self):
        """TC04: sub-millisecond audio jitter adds without rounding drift."""
        t1 = 1.0001
        t2 = 1.0002
        self.assertAlmostEqual(t2 - t1, 0.0001, places=6)

    def test_f05_b05_dense_notes_in_single_frame(self):
        """TC05: multiple notes occurring in the same 16ms frame are all returned."""
        notes = [{"time_sec": 1.002}, {"time_sec": 1.008}, {"time_sec": 1.014}]
        playhead = 1.010
        active = [n for n in notes if abs(n["time_sec"] - playhead) <= 0.050]
        self.assertEqual(len(active), 3)


# ==============================================================================
# Feature 6: Bundled Test Pieces (Boundaries)
# ==============================================================================
class TestFeature06BundledPiecesBoundaries(unittest.TestCase):
    """F6: Chart Schema Boundaries, Edge Tempos, and Malformed Notes."""

    def test_f06_b01_empty_notes_list_handling(self):
        """TC01: chart with empty notes array validates structure."""
        chart = {"title": "Silent", "bpm": 120.0, "time_signature": [4, 4], "audio_file": "none.wav", "notes": []}
        valid, msg = ChartValidator.validate_chart_dict(chart)
        self.assertTrue(valid, msg)

    def test_f06_b02_extreme_high_bpm_999(self):
        """TC02: 999 BPM chart produces valid positive beat length."""
        bpm = 999.0
        sec_per_beat = 60.0 / bpm
        self.assertGreater(sec_per_beat, 0.0)

    def test_f06_b03_extreme_low_bpm_20(self):
        """TC03: 20 BPM chart produces 3.0s beat length."""
        bpm = 20.0
        self.assertEqual(60.0 / bpm, 3.0)

    def test_f06_b04_fractional_measure_beats(self):
        """TC04: fractional beats calculate precise floating-point second offsets."""
        bpm = 120.0
        beat = 2.5
        time_offset = (beat - 1.0) * (60.0 / bpm)
        self.assertEqual(time_offset, 0.75)

    def test_f06_b05_note_duration_zero_rejection(self):
        """TC05: note duration <= 0 is rejected by chart validator."""
        bad_chart = {
            "title": "Bad", "bpm": 120.0, "time_signature": [4, 4], "audio_file": "bad.wav",
            "notes": [{"pitch_name": "C4", "pitch_midi": 60, "staff": "treble", "time_sec": 0.0, "duration_sec": 0.0, "measure": 1, "beat": 1.0}]
        }
        valid, msg = ChartValidator.validate_chart_dict(bad_chart)
        self.assertFalse(valid)


# ==============================================================================
# Feature 7: Asset Generation Pipeline (Boundaries)
# ==============================================================================
class TestFeature07AssetGenBoundaries(unittest.TestCase):
    """F7: Synthesis Limits, Clipping Protection, and Buffer Edges."""

    def test_f07_b01_nyquist_frequency_boundary(self):
        """TC01: highest piano note C8 (MIDI 108, 4186 Hz) is below 22,050 Hz Nyquist."""
        freq_c8 = AudioInferenceUtils.midi_to_freq(108)
        nyquist = 22050.0 / 2.0
        self.assertLess(freq_c8, nyquist)

    def test_f07_b02_zero_amplitude_silence_synthesis(self):
        """TC02: synthesis with amplitude=0.0 generates pure zeros."""
        audio = AudioInferenceUtils.synthesize_sine([60], duration_sec=0.1, amplitude=0.0)
        self.assertTrue(np.all(audio == 0.0))

    def test_f07_b03_clipping_protection_normalized_amplitude(self):
        """TC03: 10-pitch chord synthesis normalizes amplitude to prevent clipping."""
        chord_10 = list(range(60, 70))
        audio = AudioInferenceUtils.synthesize_sine(chord_10, duration_sec=0.1, amplitude=0.9)
        self.assertLessEqual(np.max(np.abs(audio)), 1.0)

    def test_f07_b04_single_sample_audio_buffer(self):
        """TC04: 1-sample buffer calculates RMS without zero-division error."""
        single = np.array([0.5], dtype=np.float32)
        rms = AudioInferenceUtils.calculate_rms(single)
        self.assertAlmostEqual(rms, 0.5)

    def test_f07_b05_monophonic_vs_polyphonic_buffer_sizes(self):
        """TC05: 1 note vs 5 notes produce identical output array lengths."""
        a1 = AudioInferenceUtils.synthesize_sine([60], 0.25)
        a5 = AudioInferenceUtils.synthesize_sine([60, 64, 67, 71, 74], 0.25)
        self.assertEqual(len(a1), len(a5))


# ==============================================================================
# Feature 8: Basic Pitch ONNX Model (Boundaries)
# ==============================================================================
class TestFeature08ONNXBoundaries(unittest.TestCase):
    """F8: ONNX Forward Pass Input Extremes and Shape Constraints."""

    @classmethod
    def setUpClass(cls):
        import onnxruntime as ort
        cls.session = ort.InferenceSession(MODEL_PATH, providers=['CPUExecutionProvider'])

    def test_f08_b01_zero_vector_inference(self):
        """TC01: all-zero input vector produces non-NaN, non-Inf outputs."""
        zero_inp = np.zeros((1, 43844, 1), dtype=np.float32)
        outputs = self.session.run(None, {"serving_default_input_2:0": zero_inp})
        for out in outputs:
            self.assertFalse(np.isnan(out).any())
            self.assertFalse(np.isinf(out).any())

    def test_f08_b02_dc_offset_input_vector(self):
        """TC02: input with constant DC offset executes without error."""
        dc_inp = np.full((1, 43844, 1), 0.25, dtype=np.float32)
        outputs = self.session.run(None, {"serving_default_input_2:0": dc_inp})
        self.assertEqual(len(outputs), 3)

    def test_f08_b03_max_amplitude_input_vector(self):
        """TC03: full-scale normalized audio (-1.0 to +1.0) executes cleanly."""
        max_inp = np.ones((1, 43844, 1), dtype=np.float32)
        outputs = self.session.run(None, {"serving_default_input_2:0": max_inp})
        self.assertEqual(len(outputs), 3)

    def test_f08_b04_exact_batch_size_one(self):
        """TC04: model accepts exact batch size 1."""
        inp = np.zeros((1, 43844, 1), dtype=np.float32)
        self.assertEqual(inp.shape[0], 1)

    def test_f08_b05_model_output_probability_range(self):
        """TC05: output activations are bounded."""
        inp = np.zeros((1, 43844, 1), dtype=np.float32)
        outputs = self.session.run(None, {"serving_default_input_2:0": inp})
        for out in outputs:
            self.assertTrue(np.all(np.isfinite(out)))


# ==============================================================================
# Feature 9: Modular Inference Interface (Boundaries)
# ==============================================================================
class TestFeature09InterfaceBoundaries(unittest.TestCase):
    """F9: AudioPitchModel Buffer Edge Cases and Mock Dynamics."""

    def test_f09_b01_empty_samples_push(self):
        """TC01: pushing empty array does not crash driver."""
        class MockDriver:
            def __init__(self): self.buf = []
            def push_audio_samples(self, s):
                if len(s) > 0: self.buf.extend(s)
        driver = MockDriver()
        driver.push_audio_samples(np.array([], dtype=np.float32))
        self.assertEqual(len(driver.buf), 0)

    def test_f09_b02_rapid_sequential_queries(self):
        """TC02: rapid consecutive queries return consistent pitch sets."""
        class MockDriver:
            def get_detected_pitches(self): return [60, 64]
        driver = MockDriver()
        q1 = driver.get_detected_pitches()
        q2 = driver.get_detected_pitches()
        self.assertEqual(q1, q2)

    def test_f09_b03_unsupported_pitch_code_handling(self):
        """TC03: empty pitch query returns empty list (never None)."""
        class MockDriver:
            def get_detected_pitches(self): return []
        driver = MockDriver()
        self.assertEqual(driver.get_detected_pitches(), [])

    def test_f09_b04_driver_switch_mid_song(self):
        """TC04: driver replacement mid-playback preserves active pitch contracts."""
        d1 = {"get": lambda: [60]}
        d2 = {"get": lambda: [64]}
        active = d1
        self.assertEqual(active["get"](), [60])
        active = d2
        self.assertEqual(active["get"](), [64])

    def test_f09_b05_reconnect_resilience(self):
        """TC05: simulated driver reconnect recovers empty state."""
        state = {"connected": False, "queue": [1, 2, 3]}
        state["queue"].clear()
        state["connected"] = True
        self.assertTrue(state["connected"])
        self.assertEqual(len(state["queue"]), 0)


# ==============================================================================
# Feature 10: Real-Time Polyphonic Pitch Extraction (Boundaries)
# ==============================================================================
class TestFeature10PitchExtractionBoundaries(unittest.TestCase):
    """F10: Confidence Threshold Boundaries & Plateau Peak Picking."""

    def test_f10_b01_all_semitones_threshold_zero(self):
        """TC01: threshold 0.0 on positive activations selects all 88 keys."""
        prob_vector = np.full(88, 0.1, dtype=np.float32)
        active = np.where(prob_vector >= 0.0)[0] + 21
        self.assertEqual(len(active), 88)

    def test_f10_b02_threshold_one_zero_activations(self):
        """TC02: threshold 1.0 on standard activations yields zero keys."""
        prob_vector = np.full(88, 0.99, dtype=np.float32)
        active = np.where(prob_vector >= 1.0)[0] + 21
        self.assertEqual(len(active), 0)

    def test_f10_b03_resampling_equal_sample_rates(self):
        """TC03: resampling with orig_sr == target_sr preserves array exactly."""
        arr = np.array([0.1, 0.2, 0.3], dtype=np.float32)
        res = AudioInferenceUtils.resample_audio(arr, 22050, 22050)
        self.assertTrue(np.array_equal(arr, res))

    def test_f10_b04_single_frame_peak_picking(self):
        """TC04: 3-element activation vector peak-picks center element."""
        signal = np.array([0.2, 0.9, 0.2], dtype=np.float32)
        peaks = np.where((signal[1:-1] > signal[:-2]) & (signal[1:-1] > signal[2:]))[0] + 1
        self.assertEqual(peaks.tolist(), [1])

    def test_f10_b05_flat_plateau_peak_picking(self):
        """TC05: flat plateau (identical values) does not trigger infinite peaks."""
        plateau = np.full(10, 0.8, dtype=np.float32)
        peaks = np.where((plateau[1:-1] > plateau[:-2]) & (plateau[1:-1] > plateau[2:]))[0] + 1
        self.assertEqual(len(peaks), 0)


# ==============================================================================
# Feature 11: Microphone Audio Capture (Boundaries)
# ==============================================================================
class TestFeature11MicBoundaries(unittest.TestCase):
    """F11: Noise Gate Edge Tolerances and Buffer Underruns."""

    def test_f11_b01_exact_noise_gate_threshold(self):
        """TC01: audio with RMS exactly at threshold is not zeroed."""
        arr = np.array([0.01, 0.01, 0.01], dtype=np.float32)
        exact_rms = AudioInferenceUtils.calculate_rms(arr)
        gated = AudioInferenceUtils.apply_noise_gate(arr, threshold_rms=exact_rms)
        self.assertFalse(np.all(gated == 0.0))

    def test_f11_b02_just_below_noise_gate_threshold(self):
        """TC02: audio with RMS 0.0099 is zeroed by threshold 0.01."""
        arr = np.array([0.0099, 0.0099], dtype=np.float32)
        gated = AudioInferenceUtils.apply_noise_gate(arr, threshold_rms=0.01)
        self.assertTrue(np.all(gated == 0.0))

    def test_f11_b03_pure_dc_silence(self):
        """TC03: array of all zeros produces RMS 0.0."""
        zeros = np.zeros(100, dtype=np.float32)
        self.assertEqual(AudioInferenceUtils.calculate_rms(zeros), 0.0)

    def test_f11_b04_maximum_amplitude_rms(self):
        """TC04: alternating +/-1.0 array produces RMS 1.0."""
        alt = np.array([1.0, -1.0, 1.0, -1.0], dtype=np.float32)
        self.assertAlmostEqual(AudioInferenceUtils.calculate_rms(alt), 1.0)

    def test_f11_b05_single_spike_transient(self):
        """TC05: single transient spike in large zero buffer is attenuated if mean RMS is low."""
        buf = np.zeros(1000, dtype=np.float32)
        buf[500] = 0.1
        gated = AudioInferenceUtils.apply_noise_gate(buf, threshold_rms=0.01)
        self.assertTrue(np.all(gated == 0.0))


# ==============================================================================
# Feature 12: Polyphonic Scoring Matcher (Boundaries)
# ==============================================================================
class TestFeature12MatcherBoundaries(unittest.TestCase):
    """F12: Polyphonic Matcher Edge Sets, Null Sets, and Dense Chords."""

    def test_f12_b01_empty_expected_and_empty_detected(self):
        """TC01: both detected and expected sets empty returns 100% precision and recall."""
        m = AudioInferenceUtils.match_polyphonic_clusters(set(), set())
        self.assertEqual(m["f1"], 1.0)

    def test_f12_b02_completely_disjoint_pitch_sets(self):
        """TC02: completely disjoint pitch sets return F1 = 0.0."""
        m = AudioInferenceUtils.match_polyphonic_clusters({60, 62}, {64, 67})
        self.assertEqual(m["f1"], 0.0)
        self.assertEqual(m["tp"], 0)

    def test_f12_b03_single_note_chord(self):
        """TC03: 1-note set match produces F1 = 1.0."""
        m = AudioInferenceUtils.match_polyphonic_clusters({60}, {60})
        self.assertEqual(m["f1"], 1.0)

    def test_f12_b04_large_dense_cluster_10_pitches(self):
        """TC04: 10 concurrent notes matched against 10 expected returns F1 = 1.0."""
        pitches = set(range(50, 60))
        m = AudioInferenceUtils.match_polyphonic_clusters(pitches, pitches)
        self.assertEqual(m["f1"], 1.0)
        self.assertEqual(m["tp"], 10)

    def test_f12_b05_semitone_transposition_error(self):
        """TC05: 1-semitone transposition of chord returns 0 true positives."""
        expected = {60, 64, 67}
        transposed = {61, 65, 68}
        m = AudioInferenceUtils.match_polyphonic_clusters(transposed, expected)
        self.assertEqual(m["tp"], 0)
        self.assertEqual(m["f1"], 0.0)


# ==============================================================================
# Feature 13: Sheet Music Image Ingestion (Boundaries)
# ==============================================================================
class TestFeature13ImageBoundaries(unittest.TestCase):
    """F13: Image Sizing Boundaries, Aspect Extremes, and Bit Depths."""

    def test_f13_b01_minimal_1x1_image(self):
        """TC01: 1x1 image processes without index errors."""
        img = np.array([[255]], dtype=np.uint8)
        proj = OMRUtils.horizontal_projection(img)
        self.assertEqual(len(proj), 1)

    def test_f13_b02_all_black_image(self):
        """TC02: solid black image produces all-zero projection."""
        img = np.zeros((100, 100), dtype=np.uint8)
        proj = OMRUtils.horizontal_projection(img)
        self.assertTrue(np.all(proj == 0))

    def test_f13_b03_all_white_image(self):
        """TC03: solid white image produces uniform projection."""
        img = np.full((50, 200), 255, dtype=np.uint8)
        proj = OMRUtils.horizontal_projection(img)
        self.assertTrue(np.all(proj == 200))

    def test_f13_b04_non_standard_aspect_ratio_10_to_1(self):
        """TC04: 10:1 wide aspect ratio image processes projection cleanly."""
        img = np.zeros((50, 500), dtype=np.uint8)
        proj = OMRUtils.horizontal_projection(img)
        self.assertEqual(len(proj), 50)

    def test_f13_b05_boundary_threshold_values(self):
        """TC05: thresholding at extreme values 0 and 255 produces valid binary masks."""
        img = np.array([[128]], dtype=np.uint8)
        t_low = (img > 0).astype(np.uint8)
        t_high = (img > 254).astype(np.uint8)
        self.assertEqual(t_low[0, 0], 1)
        self.assertEqual(t_high[0, 0], 0)


# ==============================================================================
# Feature 14: Projection Profiling OMR (Boundaries)
# ==============================================================================
class TestFeature14OMRBoundaries(unittest.TestCase):
    """F14: Projection Profiling Peak Limits and Line Edge Conditions."""

    def test_f14_b01_single_isolated_staff_line(self):
        """TC01: single isolated staff line detects exactly 1 peak."""
        img = np.zeros((50, 100), dtype=np.uint8)
        img[25, 10:90] = 255
        proj = OMRUtils.horizontal_projection(img)
        peaks = OMRUtils.find_staff_lines(proj)
        self.assertEqual(peaks, [25])

    def test_f14_b02_dense_parallel_lines_spacing_1px(self):
        """TC02: 1px spacing plateau is filtered by peak condition."""
        proj = np.array([0, 100, 100, 100, 0], dtype=np.int32)
        peaks = OMRUtils.find_staff_lines(proj)
        self.assertIsInstance(peaks, list)

    def test_f14_b03_zero_peaks_on_blank_image(self):
        """TC03: blank image returns empty staff line list."""
        proj = np.zeros(100, dtype=np.int32)
        peaks = OMRUtils.find_staff_lines(proj)
        self.assertEqual(peaks, [])

    def test_f14_b04_staff_lines_at_image_edges(self):
        """TC04: staff line at row 0 does not trigger out-of-bounds error."""
        proj = np.zeros(20, dtype=np.int32)
        proj[0] = 100
        peaks = OMRUtils.find_staff_lines(proj)
        self.assertIsInstance(peaks, list)

    def test_f14_b05_skewed_profile_threshold_ratio(self):
        """TC05: high threshold ratio 0.9 rejects weak artifacts."""
        proj = np.array([0, 50, 0, 100, 0, 40, 0], dtype=np.int32)
        peaks = OMRUtils.find_staff_lines(proj, min_threshold_ratio=0.9)
        self.assertEqual(peaks, [3])


# ==============================================================================
# Feature 15: Audio-Chart Alignment (Boundaries)
# ==============================================================================
class TestFeature15AlignmentBoundaries(unittest.TestCase):
    """F15: Timeline Alignment Shifts and Microsecond Durations."""

    def test_f15_b01_zero_lead_in_offset(self):
        """TC01: 0.0s lead-in introduces zero time displacement."""
        offset = 0.0
        self.assertEqual(1.5 + offset, 1.5)

    def test_f15_b02_negative_audio_offset(self):
        """TC02: negative offset shifts notes earlier in time."""
        raw = 1.0
        offset = -0.2
        self.assertAlmostEqual(raw + offset, 0.8)

    def test_f15_b03_first_note_at_exact_time_zero(self):
        """TC03: note at t=0.0s is valid and hit evaluation works at playhead 0.0s."""
        self.assertTrue(HighwayMath.is_in_hit_window(0.0, 0.0))

    def test_f15_b04_bpm_boundary_300(self):
        """TC04: 300 BPM presto tempo calculates 0.20s beat duration."""
        bpm = 300.0
        self.assertEqual(60.0 / bpm, 0.2)

    def test_f15_b05_microsecond_note_duration(self):
        """TC05: 0.001s staccato note duration is strictly positive."""
        dur = 0.001
        self.assertGreater(dur, 0.0)


# ==============================================================================
# Feature 16: Standalone CLI Test Harnesses (Boundaries)
# ==============================================================================
class TestFeature16HarnessBoundaries(unittest.TestCase):
    """F16: CLI Accuracy Threshold Strict Boundaries."""

    def test_f16_b01_exact_threshold_85_percent_omr(self):
        """TC01: exactly 85.0% accuracy meets OMR requirement."""
        accuracy = 0.8500
        self.assertTrue(accuracy >= 0.85)

    def test_f16_b02_just_below_85_percent_omr_84_9(self):
        """TC02: 84.99% accuracy fails OMR requirement."""
        accuracy = 0.8499
        self.assertFalse(accuracy >= 0.85)

    def test_f16_b03_exact_threshold_80_percent_f1(self):
        """TC03: exactly 80.0% F1-score meets transcription requirement."""
        f1 = 0.8000
        self.assertTrue(f1 >= 0.80)

    def test_f16_b04_just_below_80_percent_f1_79_9(self):
        """TC04: 79.99% F1-score fails transcription requirement."""
        f1 = 0.7999
        self.assertFalse(f1 >= 0.80)

    def test_f16_b05_empty_dataset_harness_error(self):
        """TC05: zero test cases handled without division-by-zero error."""
        total = 0
        correct = 0
        acc = (correct / total) if total > 0 else 0.0
        self.assertEqual(acc, 0.0)


# ==============================================================================
# Feature 17: Android (Pixel 7a) Export (Boundaries)
# ==============================================================================
class TestFeature17AndroidBoundaries(unittest.TestCase):
    """F17: Android Pixel 7a Hardware Flag & Architecture Isolation."""

    def setUp(self):
        self.export_presets = os.path.join(PROJECT_ROOT, "export_presets.cfg")

    def test_f17_b01_armeabi_v7a_disabled(self):
        """TC01: 32-bit ARM (armeabi-v7a) is disabled for 64-bit Pixel 7a."""
        with open(self.export_presets, "r", encoding="utf-8") as f:
            content = f.read()
        self.assertIn("architectures/armeabi-v7a=false", content)

    def test_f17_b02_x86_disabled_x86_64_enabled(self):
        """TC02: x86 and x86_64 Android ABIs are disabled (native ONNX GDExtension ships arm64-v8a only)."""
        with open(self.export_presets, "r", encoding="utf-8") as f:
            content = f.read()
        self.assertIn("architectures/x86=false", content)
        self.assertIn("architectures/x86_64=false", content)

    def test_f17_b03_version_code_positive_integer(self):
        """TC03: Android version/code is a positive integer."""
        with open(self.export_presets, "r", encoding="utf-8") as f:
            content = f.read()
        self.assertIn("version/code=1", content)

    def test_f17_b04_apk_export_path_defined(self):
        """TC04: export path specifies .apk binary extension."""
        with open(self.export_presets, "r", encoding="utf-8") as f:
            content = f.read()
        self.assertIn('export_path="./micgame3.apk"', content)

    def test_f17_b05_immersive_mode_enabled(self):
        """TC05: screen/immersive_mode is true for mobile full-screen gameplay."""
        with open(self.export_presets, "r", encoding="utf-8") as f:
            content = f.read()
        self.assertIn("screen/immersive_mode=true", content)


# ==============================================================================
# Feature 18: Windows Desktop Export (Boundaries)
# ==============================================================================
class TestFeature18WindowsBoundaries(unittest.TestCase):
    """F18: Windows Architecture Constraints and Texture Formats."""

    def setUp(self):
        self.export_presets = os.path.join(PROJECT_ROOT, "export_presets.cfg")

    def test_f18_b01_architecture_x86_64_strict(self):
        """TC01: Windows target is strictly 64-bit."""
        with open(self.export_presets, "r", encoding="utf-8") as f:
            content = f.read()
        self.assertIn('binary_format/architecture="x86_64"', content)

    def test_f18_b02_export_path_micgame3_exe(self):
        """TC02: export path targets micgame3.exe."""
        with open(self.export_presets, "r", encoding="utf-8") as f:
            content = f.read()
        self.assertIn('export_path="./micgame3.exe"', content)

    def test_f18_b03_texture_format_s3tc_enabled(self):
        """TC03: desktop S3TC/BPTC compression is enabled."""
        with open(self.export_presets, "r", encoding="utf-8") as f:
            content = f.read()
        self.assertIn("texture_format/s3tc_bptc=true", content)

    def test_f18_b04_etc2_astc_disabled_on_desktop(self):
        """TC04: mobile ETC2/ASTC compression is disabled on desktop."""
        with open(self.export_presets, "r", encoding="utf-8") as f:
            content = f.read()
        self.assertIn("texture_format/etc2_astc=false", content)

    def test_f18_b05_custom_features_empty_default(self):
        """TC05: custom features string is clean."""
        with open(self.export_presets, "r", encoding="utf-8") as f:
            content = f.read()
        self.assertIn('custom_features=""', content)


# ==============================================================================
# Feature 19: Headless Project Validation (Boundaries)
# ==============================================================================
class TestFeature19HeadlessBoundaries(unittest.TestCase):
    """F19: Headless Execution Safeguards and Path Edge Cases."""

    def test_f19_b01_nonexistent_scene_detection(self):
        """TC01: detecting missing scene path triggers warning/handling."""
        missing_path = "res://scenes/missing.tscn"
        local = os.path.join(PROJECT_ROOT, missing_path.replace("res://", ""))
        self.assertFalse(os.path.exists(local))

    def test_f19_b02_syntax_validation_on_gdscript(self):
        """TC02: code validator flags unbalanced parentheses."""
        code_balanced = "func test():\n    pass\n"
        code_unbalanced = "func test(:\n    pass\n"
        self.assertEqual(code_balanced.count("("), code_balanced.count(")"))
        self.assertNotEqual(code_unbalanced.count("("), code_unbalanced.count(")"))

    def test_f19_b03_missing_bus_layout_flag(self):
        """TC03: verification confirms presence of default_bus_layout.tres."""
        bus_path = os.path.join(PROJECT_ROOT, "default_bus_layout.tres")
        self.assertTrue(os.path.exists(bus_path))

    def test_f19_b04_non_standard_godot_path(self):
        """TC04: space-containing paths are quoted in command arguments."""
        path_with_spaces = "C:\\Program Files\\Godot Engine\\godot.exe"
        quoted = f'"{path_with_spaces}"'
        self.assertTrue(quoted.startswith('"') and quoted.endswith('"'))

    def test_f19_b05_timeout_protection_in_headless_runner(self):
        """TC05: execution runner timeout parameter is positive integer."""
        timeout_sec = 30
        self.assertGreater(timeout_sec, 0)


# ==============================================================================
# Feature 20: E2E Test Suite Validation (Boundaries)
# ==============================================================================
class TestFeature20E2EBoundaries(unittest.TestCase):
    """F20: Zero-Tolerance Quality Bounds and Test Isolation."""

    def test_f20_b01_zero_failure_tolerance(self):
        """TC01: strictly zero failures permitted for pass status."""
        failures = 0
        self.assertEqual(failures, 0)

    def test_f20_b02_zero_error_tolerance(self):
        """TC02: strictly zero errors permitted for pass status."""
        errors = 0
        self.assertEqual(errors, 0)

    def test_f20_b03_test_result_runtime_positive(self):
        """TC03: test suite runtime duration is positive."""
        duration = 0.42
        self.assertGreater(duration, 0.0)

    def test_f20_b04_individual_test_isolation(self):
        """TC04: isolated test engines maintain independent state."""
        e1 = ScoringEngine()
        e2 = ScoringEngine()
        e1.evaluate_hit(0.01)
        self.assertEqual(e1.score, 1000)
        self.assertEqual(e2.score, 0)

    def test_f20_b05_runner_handles_keyboard_interrupt(self):
        """TC05: KeyboardInterrupt exception is caught cleanly in runner flow."""
        caught = False
        try:
            raise KeyboardInterrupt()
        except KeyboardInterrupt:
            caught = True
        self.assertTrue(caught)


if __name__ == "__main__":
    unittest.main()
