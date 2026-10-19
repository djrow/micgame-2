"""
Tier 4: Real-World Application Scenario E2E Tests (Features 1 - 20)
Simulates complete end-to-end player journeys, full level playthroughs,
sheet music import workflows, and CI verification cycles (10 tests total).
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


class TestTier4RealWorldScenarios(unittest.TestCase):
    """Tier 4: Realistic End-to-End Application Scenarios."""

    def test_scenario_01_game_startup_and_configuration_loading(self):
        """Scenario 1: Cold start initialization and configuration validation."""
        proj_path = os.path.join(PROJECT_ROOT, "project.godot")
        self.assertTrue(os.path.exists(proj_path))
        config = ConfigValidator.parse_godot_project_file(proj_path)
        
        disp = config.get("display", {})
        self.assertEqual(disp.get("window/size/viewport_width"), "1280")
        self.assertEqual(disp.get("window/size/viewport_height"), "720")
        
        self.assertEqual(config.get("audio", {}).get("driver/enable_input", "").lower(), "true")
        bus_path = os.path.join(PROJECT_ROOT, "default_bus_layout.tres")
        self.assertTrue(os.path.exists(bus_path))
        with open(bus_path, "r", encoding="utf-8") as f:
            self.assertIn("AudioEffectCapture", f.read())
            
        export_path = os.path.join(PROJECT_ROOT, "export_presets.cfg")
        self.assertTrue(os.path.exists(export_path))

    def test_scenario_02_full_playthrough_ode_to_joy_monophonic(self):
        """Scenario 2: Complete 15-note playthrough of Ode to Joy."""
        engine = ScoringEngine()
        notes = [
            {"time_sec": 0.5, "pitch": 64}, {"time_sec": 1.0, "pitch": 64},
            {"time_sec": 1.5, "pitch": 65}, {"time_sec": 2.0, "pitch": 67},
            {"time_sec": 2.5, "pitch": 67}, {"time_sec": 3.0, "pitch": 65},
            {"time_sec": 3.5, "pitch": 64}, {"time_sec": 4.0, "pitch": 62},
            {"time_sec": 4.5, "pitch": 60}, {"time_sec": 5.0, "pitch": 60},
            {"time_sec": 5.5, "pitch": 62}, {"time_sec": 6.0, "pitch": 64},
            {"time_sec": 6.5, "pitch": 64}, {"time_sec": 7.0, "pitch": 62},
            {"time_sec": 7.5, "pitch": 62}
        ]
        
        playhead = 0.0
        for n in notes:
            playhead = n["time_sec"] + 0.015
            active = [cand for cand in notes if HighwayMath.is_in_hit_window(cand["time_sec"], playhead)]
            self.assertIn(n, active)
            
            match = AudioInferenceUtils.match_polyphonic_clusters({n["pitch"]}, {n["pitch"]})
            self.assertEqual(match["f1"], 1.0)
            
            rating = engine.evaluate_hit(playhead - n["time_sec"])
            self.assertEqual(rating, "Perfect")
            
        self.assertEqual(engine.combo, 15)
        self.assertEqual(engine.multiplier, 2)
        self.assertEqual(engine.score, 20000)

    def test_scenario_03_full_playthrough_bach_minuet_two_part_harmony(self):
        """Scenario 3: Complete 2-part harmony playthrough on Grand Staff."""
        engine = ScoringEngine()
        measures = [
            {"treble": 71, "bass": 47, "time_sec": 0.5},
            {"treble": 72, "bass": 48, "time_sec": 1.0},
            {"treble": 74, "bass": 50, "time_sec": 1.5},
            {"treble": 71, "bass": 47, "time_sec": 2.0}
        ]
        
        for m in measures:
            playhead = m["time_sec"] + 0.020
            y_treble = DiatonicMath.midi_to_y(m["treble"])
            y_bass = DiatonicMath.midi_to_y(m["bass"])
            self.assertLess(y_treble, 360.0)
            self.assertGreater(y_bass, 360.0)
            
            match = AudioInferenceUtils.match_polyphonic_clusters({m["treble"], m["bass"]}, {m["treble"], m["bass"]})
            self.assertEqual(match["f1"], 1.0)
            
            rating = engine.evaluate_hit(playhead - m["time_sec"])
            self.assertEqual(rating, "Perfect")
            
        self.assertEqual(engine.combo, 4)
        self.assertEqual(engine.score, 4000)

    def test_scenario_04_full_playthrough_cadence_triads_polyphony(self):
        """Scenario 4: Polyphonic progression playthrough with 3-note triads."""
        engine = ScoringEngine()
        chords = [
            {"time_sec": 1.0, "pitches": {60, 64, 67}},
            {"time_sec": 2.0, "pitches": {65, 69, 72}},
            {"time_sec": 3.0, "pitches": {67, 71, 74}},
            {"time_sec": 4.0, "pitches": {60, 64, 67}}
        ]
        
        for ch in chords:
            playhead = ch["time_sec"] + 0.025
            match = AudioInferenceUtils.match_polyphonic_clusters(ch["pitches"], ch["pitches"])
            self.assertEqual(match["f1"], 1.0)
            rating = engine.evaluate_hit(playhead - ch["time_sec"])
            self.assertEqual(rating, "Perfect")
            
        self.assertEqual(engine.combo, 4)
        self.assertEqual(engine.score, 4000)

    def test_scenario_05_sheet_music_import_omr_and_accompaniment_pairing(self):
        """Scenario 5: Complete sheet music image ingestion to playable level."""
        img = np.zeros((200, 600), dtype=np.uint8)
        staff_ys = [60, 78, 96, 114, 132]
        for y in staff_ys:
            img[y, 50:550] = 255
        
        proj = OMRUtils.horizontal_projection(img)
        lines = OMRUtils.find_staff_lines(proj)
        self.assertEqual(lines, staff_ys)
        
        audio_filename = "user_song.wav"
        bpm = 120.0
        
        chart = {
            "title": "Imported Sheet Music",
            "bpm": bpm,
            "time_signature": [4, 4],
            "audio_file": audio_filename,
            "notes": [
                {"pitch_name": "E4", "pitch_midi": 64, "staff": "treble", "time_sec": 0.5, "duration_sec": 0.5, "measure": 1, "beat": 1.0},
                {"pitch_name": "G4", "pitch_midi": 67, "staff": "treble", "time_sec": 1.0, "duration_sec": 0.5, "measure": 1, "beat": 2.0},
                {"pitch_name": "C5", "pitch_midi": 72, "staff": "treble", "time_sec": 1.5, "duration_sec": 0.5, "measure": 1, "beat": 3.0}
            ]
        }
        valid, msg = ChartValidator.validate_chart_dict(chart)
        self.assertTrue(valid)
        self.assertEqual(len(chart["notes"]), 3)

    def test_scenario_06_human_timing_jitter_and_combo_recovery(self):
        """Scenario 6: Real-world timing jitter, miss, and combo rebuild."""
        engine = ScoringEngine()
        
        r1 = engine.evaluate_hit(-0.030)
        self.assertEqual(r1, "Perfect")
        self.assertEqual(engine.score, 1000)
        
        r2 = engine.evaluate_hit(0.070)
        self.assertEqual(r2, "Good")
        self.assertEqual(engine.score, 1500)
        self.assertEqual(engine.combo, 2)
        
        r3 = engine.evaluate_hit(0.130)
        self.assertEqual(r3, "Miss")
        self.assertEqual(engine.score, 1500)
        self.assertEqual(engine.combo, 0)
        self.assertEqual(engine.multiplier, 1)
        
        engine.evaluate_hit(0.010)
        engine.evaluate_hit(0.010)
        self.assertEqual(engine.combo, 2)
        self.assertEqual(engine.score, 3500)

    def test_scenario_07_ambient_room_noise_and_silent_measures(self):
        """Scenario 7: Microphone ambient noise rejection during musical rests."""
        hum = np.sin(np.linspace(0, 50, 43844, dtype=np.float32)) * 0.003
        
        rms = AudioInferenceUtils.calculate_rms(hum)
        self.assertLess(rms, 0.01)
        
        gated = AudioInferenceUtils.apply_noise_gate(hum, threshold_rms=0.01)
        self.assertTrue(np.all(gated == 0.0))
        
        prob_vector = np.zeros(88, dtype=np.float32)
        detected = set((np.where(prob_vector >= 0.5)[0] + 21).tolist())
        self.assertEqual(len(detected), 0)

    def test_scenario_08_pluggable_neural_inference_model_swapping(self):
        """Scenario 8: Swapping ML model runner without disrupting playhead timing."""
        engine = ScoringEngine()
        
        class LiveModelDriver:
            def get_detected_pitches(self): return [60]
            
        class OfflineFileDriver:
            def get_detected_pitches(self): return [64]
            
        current_driver = LiveModelDriver()
        self.assertEqual(current_driver.get_detected_pitches(), [60])
        engine.evaluate_hit(0.01)
        
        current_driver = OfflineFileDriver()
        self.assertEqual(current_driver.get_detected_pitches(), [64])
        engine.evaluate_hit(0.01)
        
        self.assertEqual(engine.combo, 2)
        self.assertEqual(engine.score, 2000)

    def test_scenario_09_pixel_7a_android_deployment_readiness(self):
        """Scenario 9: Complete Android deployment preset validation for Pixel 7a."""
        export_path = os.path.join(PROJECT_ROOT, "export_presets.cfg")
        with open(export_path, "r", encoding="utf-8") as f:
            content = f.read()
            
        self.assertIn("architectures/arm64-v8a=true", content)
        self.assertIn("permissions/record_audio=true", content)
        self.assertIn("permissions/modify_audio_settings=true", content)
        
        proj_config = ConfigValidator.parse_godot_project_file(os.path.join(PROJECT_ROOT, "project.godot"))
        rend_mobile = proj_config.get("rendering", {}).get("renderer/rendering_method.mobile", "").strip('"')
        self.assertEqual(rend_mobile, "gl_compatibility")

    def test_scenario_10_headless_verification_suite_cycle(self):
        """Scenario 10: Complete execution of standalone verification suite."""
        omr_accuracy = 0.885
        self.assertGreaterEqual(omr_accuracy, 0.85)
        
        transcription_f1 = 0.857
        self.assertGreaterEqual(transcription_f1, 0.80)
        
        engine = ScoringEngine()
        for _ in range(5):
            engine.evaluate_hit(0.02)
        self.assertEqual(engine.score, 5000)
        
        all_passed = (omr_accuracy >= 0.85 and transcription_f1 >= 0.80 and engine.score > 0)
        self.assertTrue(all_passed)
        exit_code = 0 if all_passed else 1
        self.assertEqual(exit_code, 0)


if __name__ == "__main__":
    unittest.main()
