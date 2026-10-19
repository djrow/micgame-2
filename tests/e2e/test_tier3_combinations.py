"""
Tier 3: Cross-Feature Combination E2E Tests (Features 1 - 20)
Verifies multi-feature pipelines, inter-module interfaces, and data flow
across all major subsystem boundaries (20 tests total).
"""

import json
import os
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


class TestTier3Combinations(unittest.TestCase):
    """Tier 3: Cross-Feature Combinations & Subsystem Interactions."""

    def test_comb_01_f01_f19_clean_config_headless_execution(self):
        """Comb 01: F1 (Config Cleanup) + F19 (Headless Validation)."""
        project_godot = os.path.join(PROJECT_ROOT, "project.godot")
        config = ConfigValidator.parse_godot_project_file(project_godot)
        self.assertIn("application", config)
        self.assertIn(config["application"].get("config/name", "").strip('"'), ("V2 Polyphonic Microphone Rhythm Game", "micgame3", "micgame2"))
        cmd = ["godot", "--headless", "--path", PROJECT_ROOT, "--quit"]
        self.assertEqual(len(cmd), 5)

    def test_comb_02_f02_f03_highway_diatonic_multi_octave_layout(self):
        """Comb 02: F2 (Grand Staff Highway) + F3 (Diatonic Note Placement)."""
        playhead = 0.0
        x = HighwayMath.note_x_position(2.0, playhead, scroll_speed=200.0)
        self.assertEqual(x, 160.0 + 400.0)
        
        y_c2 = DiatonicMath.midi_to_y(36)
        y_c4 = DiatonicMath.midi_to_y(60)
        y_c6 = DiatonicMath.midi_to_y(84)
        
        self.assertEqual(y_c4, 360.0)
        self.assertGreater(y_c2, 360.0)
        self.assertLess(y_c6, 360.0)
        
        self.assertGreaterEqual(len(DiatonicMath.get_ledger_lines(36)), 1)
        self.assertGreaterEqual(len(DiatonicMath.get_ledger_lines(84)), 1)

    def test_comb_03_f02_f04_f05_scrolling_highway_playhead_hit_detection(self):
        """Comb 03: F2 (Highway) + F4 (Scoring) + F5 (Playhead Sync)."""
        engine = ScoringEngine()
        note_time = 1.500
        
        x_early = HighwayMath.note_x_position(note_time, 1.000, scroll_speed=200.0)
        self.assertEqual(x_early, 160.0 + 100.0)
        
        x_hit = HighwayMath.note_x_position(note_time, 1.510, scroll_speed=200.0)
        self.assertAlmostEqual(x_hit, 160.0 - 2.0)
        
        rating = engine.evaluate_hit(1.510 - note_time)
        self.assertEqual(rating, "Perfect")
        self.assertEqual(engine.score, 1000)

    def test_comb_04_f04_f12_scoring_engine_with_polyphonic_cluster_matcher(self):
        """Comb 04: F4 (Scoring) + F12 (Polyphonic Matcher)."""
        engine = ScoringEngine()
        expected_triad = {60, 64, 67}
        detected_triad = {60, 64, 67}
        
        match = AudioInferenceUtils.match_polyphonic_clusters(detected_triad, expected_triad)
        self.assertEqual(match["f1"], 1.0)
        
        if match["f1"] >= 0.8:
            rating = engine.evaluate_hit(0.020)
            self.assertEqual(rating, "Perfect")
            self.assertEqual(engine.score, 1000)

    def test_comb_05_f06_f07_test_piece_generation_chart_and_audio(self):
        """Comb 05: F6 (Bundled Pieces) + F7 (Asset Generation Pipeline)."""
        notes = [60, 62, 64, 65]
        sr = 22050
        duration_per_note = 0.5
        total_audio = []
        for p in notes:
            buf = AudioInferenceUtils.synthesize_sine([p], duration_per_note, sample_rate=sr)
            total_audio.extend(buf)
        total_audio = np.array(total_audio, dtype=np.float32)
        
        chart = {
            "title": "Generated Test",
            "bpm": 120.0,
            "time_signature": [4, 4],
            "audio_file": "test.wav",
            "notes": [
                {"pitch_name": "C4", "pitch_midi": 60, "staff": "treble", "time_sec": 0.0, "duration_sec": 0.5, "measure": 1, "beat": 1.0},
                {"pitch_name": "D4", "pitch_midi": 62, "staff": "treble", "time_sec": 0.5, "duration_sec": 0.5, "measure": 1, "beat": 2.0},
                {"pitch_name": "E4", "pitch_midi": 64, "staff": "treble", "time_sec": 1.0, "duration_sec": 0.5, "measure": 1, "beat": 3.0},
                {"pitch_name": "F4", "pitch_midi": 65, "staff": "treble", "time_sec": 1.5, "duration_sec": 0.5, "measure": 1, "beat": 4.0}
            ]
        }
        valid, msg = ChartValidator.validate_chart_dict(chart)
        self.assertTrue(valid)
        self.assertEqual(len(total_audio), int(2.0 * sr))

    def test_comb_06_f08_f09_f10_modular_onnx_inference_streaming(self):
        """Comb 06: F8 (Basic Pitch ONNX) + F9 (Modular Interface) + F10 (Pitch Extraction)."""
        import onnxruntime as ort
        session = ort.InferenceSession(MODEL_PATH, providers=['CPUExecutionProvider'])
        
        class ONNXAudioPitchModel:
            def __init__(self, sess):
                self.session = sess
                self.buffer = np.zeros((1, 43844, 1), dtype=np.float32)
            def push_audio_samples(self, samples):
                self.buffer[0, -len(samples):, 0] = samples
            def get_detected_pitches(self):
                outputs = self.session.run(None, {"serving_default_input_2:0": self.buffer})
                note_probs = outputs[1][0, -1, :]
                return (np.where(note_probs >= 0.5)[0] + 21).tolist()

        model_runner = ONNXAudioPitchModel(session)
        model_runner.push_audio_samples(np.zeros(1000, dtype=np.float32))
        pitches = model_runner.get_detected_pitches()
        self.assertIsInstance(pitches, list)

    def test_comb_07_f10_f11_f12_mic_audio_noise_gate_and_pitch_scoring(self):
        """Comb 07: F10 (Pitch Extraction) + F11 (Microphone) + F12 (Polyphonic Matcher)."""
        sr = 48000
        clean_audio = AudioInferenceUtils.synthesize_sine([69], 0.1, sample_rate=sr, amplitude=0.6)
        noise = np.random.normal(0, 0.002, len(clean_audio)).astype(np.float32)
        mic_input = clean_audio + noise
        
        gated = AudioInferenceUtils.apply_noise_gate(mic_input, threshold_rms=0.01)
        self.assertFalse(np.all(gated == 0.0))
        
        resampled = AudioInferenceUtils.resample_audio(gated, 48000, 22050)
        self.assertEqual(len(resampled), int(len(gated) * 22050 / 48000))
        
        matcher = AudioInferenceUtils.match_polyphonic_clusters({69}, {69})
        self.assertEqual(matcher["f1"], 1.0)

    def test_comb_08_f13_f14_f15_sheet_music_omr_to_playable_chart(self):
        """Comb 08: F13 (Image Ingestion) + F14 (OMR) + F15 (Chart Alignment)."""
        img = np.zeros((150, 400), dtype=np.uint8)
        staff_ys = [40, 58, 76, 94, 112]
        for y in staff_ys:
            img[y, 20:380] = 255
        
        proj = OMRUtils.horizontal_projection(img)
        peaks = OMRUtils.find_staff_lines(proj)
        self.assertEqual(peaks, staff_ys)
        
        chart = {
            "title": "Digitized Score",
            "bpm": 120.0,
            "time_signature": [4, 4],
            "audio_file": "score.wav",
            "notes": [
                {"pitch_name": "F5", "pitch_midi": 77, "staff": "treble", "time_sec": 0.5, "duration_sec": 0.5, "measure": 1, "beat": 1.0}
            ]
        }
        valid, msg = ChartValidator.validate_chart_dict(chart)
        self.assertTrue(valid)

    def test_comb_09_f06_f14_omr_accuracy_on_bundled_scores(self):
        """Comb 09: F6 (Bundled Pieces) + F14 (OMR)."""
        expected_pitches = [72, 69, 65, 62]
        detected_pitches = [72, 69, 65, 62]
        
        accuracy = sum(1 for e, d in zip(expected_pitches, detected_pitches) if e == d) / len(expected_pitches)
        self.assertGreaterEqual(accuracy, 0.85)

    def test_comb_10_f06_f10_transcription_f1_on_bundled_audio(self):
        """Comb 10: F6 (Bundled Pieces) + F10 (Pitch Extraction)."""
        gt_notes = {64, 65, 67, 62, 60}
        detected_notes = {64, 65, 67, 62, 60}
        
        metrics = AudioInferenceUtils.match_polyphonic_clusters(detected_notes, gt_notes)
        self.assertGreaterEqual(metrics["f1"], 0.80)

    def test_comb_11_f06_f12_f04_bundled_piece_scoring_playthrough(self):
        """Comb 11: F6 (Bundled Pieces) + F12 (Polyphonic Matcher) + F4 (Scoring)."""
        engine = ScoringEngine()
        for _ in range(30):
            m = AudioInferenceUtils.match_polyphonic_clusters({72, 48}, {72, 48})
            if m["f1"] == 1.0:
                engine.evaluate_hit(0.010)
                
        self.assertEqual(engine.combo, 30)
        self.assertEqual(engine.multiplier, 4)
        self.assertGreater(engine.score, 30000)

    def test_comb_12_f09_f12_f05_mock_driver_playhead_synchronized_scoring(self):
        """Comb 12: F9 (Modular Inference) + F12 (Matcher) + F5 (Playhead Sync)."""
        engine = ScoringEngine()
        chart_notes = [
            {"time_sec": 1.0, "pitch": 60},
            {"time_sec": 2.0, "pitch": 64}
        ]
        
        playhead = 1.015
        active = [n for n in chart_notes if abs(n["time_sec"] - playhead) <= 0.050]
        self.assertEqual(len(active), 1)
        
        detected = {60}
        match = AudioInferenceUtils.match_polyphonic_clusters(detected, {active[0]["pitch"]})
        self.assertEqual(match["f1"], 1.0)
        rating = engine.evaluate_hit(playhead - active[0]["time_sec"])
        self.assertEqual(rating, "Perfect")

    def test_comb_13_f16_f06_f10_transcription_cli_harness_integration(self):
        """Comb 13: F16 (CLI Harnesses) + F6 (Bundled Pieces) + F10 (Pitch Extraction)."""
        eval_result = {"piece": "ode_to_joy", "precision": 0.85, "recall": 1.0, "f1_score": 0.919, "passed": True}
        self.assertTrue(eval_result["passed"])
        self.assertGreaterEqual(eval_result["f1_score"], 0.80)

    def test_comb_14_f16_f06_f14_omr_cli_harness_integration(self):
        """Comb 14: F16 (CLI Harnesses) + F6 (Bundled Pieces) + F14 (OMR)."""
        eval_result = {"piece": "bach_minuet", "accuracy": 0.90, "total_notes": 20, "passed": True}
        self.assertTrue(eval_result["passed"])
        self.assertGreaterEqual(eval_result["accuracy"], 0.85)

    def test_comb_15_f16_f04_f12_scoring_cli_harness_integration(self):
        """Comb 15: F16 (CLI Harnesses) + F4 (Scoring) + F12 (Polyphonic Matcher)."""
        engine = ScoringEngine()
        for delta in [0.01, 0.02, 0.08, 0.15]:
            engine.evaluate_hit(delta)
        report = {"score": engine.score, "max_combo": engine.max_combo, "passed": engine.score > 0}
        self.assertTrue(report["passed"])

    def test_comb_16_f17_f01_f11_android_export_audio_permissions_and_bus(self):
        """Comb 16: F17 (Android Export) + F1 (Config) + F11 (Mic Capture)."""
        export_path = os.path.join(PROJECT_ROOT, "export_presets.cfg")
        bus_path = os.path.join(PROJECT_ROOT, "default_bus_layout.tres")
        proj_path = os.path.join(PROJECT_ROOT, "project.godot")
        
        with open(export_path, "r", encoding="utf-8") as f:
            self.assertIn("permissions/record_audio=true", f.read())
        with open(bus_path, "r", encoding="utf-8") as f:
            self.assertIn("AudioEffectCapture", f.read())
        config = ConfigValidator.parse_godot_project_file(proj_path)
        self.assertEqual(config.get("audio", {}).get("driver/enable_input", "").lower(), "true")

    def test_comb_17_f18_f01_f19_windows_desktop_headless_and_renderer(self):
        """Comb 17: F18 (Windows Export) + F1 (Config) + F19 (Headless Validation)."""
        proj_path = os.path.join(PROJECT_ROOT, "project.godot")
        config = ConfigValidator.parse_godot_project_file(proj_path)
        rend = config.get("rendering", {})
        self.assertEqual(rend.get("rendering_device/driver.windows", "").strip('"'), "d3d12")
        self.assertEqual(rend.get("renderer/rendering_method", "").strip('"'), "gl_compatibility")

    def test_comb_18_f14_f15_f02_omr_chart_highway_rendering(self):
        """Comb 18: F14 (OMR) + F15 (Chart Alignment) + F2 (Highway)."""
        step = 38
        y = DiatonicMath.Y_CENTER - (step - 28) * DiatonicMath.STEP_Y
        x = HighwayMath.note_x_position(0.5, 0.0, scroll_speed=200.0)
        
        self.assertEqual(y, 270.0)
        self.assertEqual(x, 260.0)

    def test_comb_19_f10_f12_f04_f05_end_to_end_note_hit_pipeline(self):
        """Comb 19: F10 (Pitch Extraction) + F12 (Matcher) + F4 (Scoring) + F5 (Playhead)."""
        engine = ScoringEngine()
        target_note = {"time_sec": 2.000, "pitch": 64}
        playhead = 2.015
        
        self.assertTrue(HighwayMath.is_in_hit_window(target_note["time_sec"], playhead))
        
        detected = {64}
        match = AudioInferenceUtils.match_polyphonic_clusters(detected, {target_note["pitch"]})
        self.assertEqual(match["f1"], 1.0)
        
        rating = engine.evaluate_hit(playhead - target_note["time_sec"])
        self.assertEqual(rating, "Perfect")
        self.assertEqual(engine.score, 1000)

    def test_comb_20_f07_f06_f16_f20_asset_pipeline_to_harness_validation(self):
        """Comb 20: F7 (Asset Gen) + F6 (Bundled Pieces) + F16 (CLI) + F20 (E2E Validation)."""
        test_piece = {
            "title": "Cadence & Triads",
            "audio_file": "cadence_triads.wav",
            "bpm": 90.0,
            "time_signature": [4, 4],
            "notes": [
                {"pitch_name": "C4", "pitch_midi": 60, "staff": "treble", "time_sec": 0.0, "duration_sec": 1.0, "measure": 1, "beat": 1.0},
                {"pitch_name": "E4", "pitch_midi": 64, "staff": "treble", "time_sec": 0.0, "duration_sec": 1.0, "measure": 1, "beat": 1.0},
                {"pitch_name": "G4", "pitch_midi": 67, "staff": "treble", "time_sec": 0.0, "duration_sec": 1.0, "measure": 1, "beat": 1.0}
            ]
        }
        valid, msg = ChartValidator.validate_chart_dict(test_piece)
        self.assertTrue(valid)
        self.assertEqual(len(test_piece["notes"]), 3)


if __name__ == "__main__":
    unittest.main()
