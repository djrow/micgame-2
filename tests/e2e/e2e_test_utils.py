"""
E2E Test Utilities for V2 Polyphonic Microphone Rhythm Game (micgame-2).
Authoritative mathematical models, reference schemas, audio synthesis,
headless scoring/OMR/transcription simulation, and configuration verification helpers.
"""

import copy
import json
import math
import os
import re
import struct
import wave
from typing import Any, Dict, List, Optional, Tuple
import numpy as np

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


class DiatonicMath:
    """Mathematical coordinate system for Grand Staff Right-to-Left Highway."""
    
    Y_CENTER = 360.0        # Y coordinate of Middle C (C4, step 28)
    LINE_SPACING = 18.0     # Distance between adjacent staff lines
    STEP_Y = 9.0            # Distance per diatonic step (half line spacing)
    HIT_LINE_X = 160.0      # Receptor target line X coordinate
    
    # Diatonic offsets for pitch classes C=0, D=1, E=2, F=3, G=4, A=5, B=6
    # Accidentals map to the natural note diatonic offset
    SEMITONE_TO_DIATONIC = {
        0: 0,   # C
        1: 0,   # C# / Db
        2: 1,   # D
        3: 1,   # D# / Eb
        4: 2,   # E
        5: 3,   # F
        6: 3,   # F# / Gb
        7: 4,   # G
        8: 4,   # G# / Ab
        9: 5,   # A
        10: 5,  # A# / Bb
        11: 6   # B
    }
    
    SEMITONE_IS_ACCIDENTAL = {
        0: False, 1: True, 2: False, 3: True, 4: False, 5: False,
        6: True, 7: False, 8: True, 9: False, 10: True, 11: False
    }

    @staticmethod
    def midi_to_diatonic_step(midi_pitch: int) -> int:
        """Returns the absolute diatonic step for a MIDI pitch.
        Middle C (C4, MIDI 60) is step 28.
        """
        octave = (midi_pitch // 12) - 1
        semitone = midi_pitch % 12
        diatonic_offset = DiatonicMath.SEMITONE_TO_DIATONIC[semitone]
        return octave * 7 + diatonic_offset

    @staticmethod
    def is_accidental(midi_pitch: int) -> bool:
        """Returns True if the MIDI pitch is sharp/flat in C major."""
        return DiatonicMath.SEMITONE_IS_ACCIDENTAL[midi_pitch % 12]

    @staticmethod
    def midi_to_y(midi_pitch: int) -> float:
        """Returns the Y pixel coordinate for a MIDI pitch centered at Y=360."""
        step = DiatonicMath.midi_to_diatonic_step(midi_pitch)
        # Higher pitch -> smaller Y (upwards on screen)
        return DiatonicMath.Y_CENTER - (step - 28) * DiatonicMath.STEP_Y

    @staticmethod
    def get_ledger_lines(midi_pitch: int) -> list[float]:
        """Calculates Y positions of ledger lines required for a pitch."""
        step = DiatonicMath.midi_to_diatonic_step(midi_pitch)
        lines = []
        if step == 28:
            # Middle C ledger line
            lines.append(DiatonicMath.Y_CENTER)
        elif step >= 40:
            # Notes above Treble staff (top line F5 is step 38, Y=270)
            # First ledger above is A5 (step 40, Y=252)
            for s in range(40, step + 1, 2):
                lines.append(DiatonicMath.Y_CENTER - (s - 28) * DiatonicMath.STEP_Y)
        elif step <= 16:
            # Notes below Bass staff (bottom line G2 is step 18, Y=450)
            # First ledger below is E2 (step 16, Y=468)
            for s in range(16, step - 1, -2):
                lines.append(DiatonicMath.Y_CENTER - (s - 28) * DiatonicMath.STEP_Y)
        return lines


class HighwayMath:
    """Calculations for Right-to-Left note scrolling and timing."""
    
    DEFAULT_SPEED = 240.0   # Pixels per second

    @staticmethod
    def note_x_position(note_time_sec: float, playhead_time_sec: float,
                        scroll_speed: float = DEFAULT_SPEED,
                        hit_line_x: float = DiatonicMath.HIT_LINE_X) -> float:
        """Calculates note X coordinate relative to hit line."""
        time_to_hit = note_time_sec - playhead_time_sec
        return hit_line_x + (time_to_hit * scroll_speed)

    @staticmethod
    def is_in_hit_window(note_time_sec: float, playhead_time_sec: float,
                         window_sec: float = 0.100) -> bool:
        """Determines if the note is within the hit evaluation window."""
        return abs(note_time_sec - playhead_time_sec) <= window_sec


class ScoringEngine:
    """Reference implementation of timing windows, combo, and scoring."""
    
    PERFECT_WINDOW = 0.050   # +/- 50ms
    GOOD_WINDOW = 0.100      # +/- 100ms
    
    PERFECT_SCORE = 1000
    GOOD_SCORE = 500
    MISS_SCORE = 0

    def __init__(self):
        self.score = 0
        self.combo = 0
        self.max_combo = 0
        self.counts = {"Perfect": 0, "Good": 0, "Miss": 0}

    @property
    def multiplier(self) -> int:
        if self.combo >= 30:
            return 4
        elif self.combo >= 20:
            return 3
        elif self.combo >= 10:
            return 2
        return 1

    def evaluate_hit(self, time_delta: float) -> str:
        """Evaluates hit judgment based on signed or unsigned timing delta."""
        abs_delta = abs(time_delta)
        if abs_delta <= self.PERFECT_WINDOW:
            rating = "Perfect"
            pts = self.PERFECT_SCORE * self.multiplier
            self.combo += 1
        elif abs_delta <= self.GOOD_WINDOW:
            rating = "Good"
            pts = self.GOOD_SCORE * self.multiplier
            self.combo += 1
        else:
            rating = "Miss"
            pts = 0
            self.combo = 0
            
        self.score += pts
        self.counts[rating] += 1
        if self.combo > self.max_combo:
            self.max_combo = self.combo
        return rating


class AudioInferenceUtils:
    """Audio signal synthesis, resampling, and polyphonic pitch matching."""

    @staticmethod
    def midi_to_freq(midi_pitch: int) -> float:
        """Standard equal temperament frequency."""
        return 440.0 * (2.0 ** ((midi_pitch - 69.0) / 12.0))

    @staticmethod
    def synthesize_sine(midi_pitches: list[int], duration_sec: float,
                        sample_rate: int = 22050, amplitude: float = 0.5) -> np.ndarray:
        """Synthesizes mono audio for one or more concurrent MIDI pitches."""
        num_samples = int(duration_sec * sample_rate)
        t = np.linspace(0, duration_sec, num_samples, endpoint=False, dtype=np.float32)
        signal = np.zeros(num_samples, dtype=np.float32)
        
        for pitch in midi_pitches:
            freq = AudioInferenceUtils.midi_to_freq(pitch)
            # Add fundamental plus small second harmonic
            harmonic = (np.sin(2.0 * np.pi * freq * t) + 
                        0.25 * np.sin(4.0 * np.pi * freq * t))
            signal += harmonic.astype(np.float32)
            
        if len(midi_pitches) > 0:
            signal = (signal / len(midi_pitches)) * amplitude
        return signal

    @staticmethod
    def resample_audio(audio: np.ndarray, orig_sr: int, target_sr: int) -> np.ndarray:
        """Pure NumPy 1D linear audio resampling."""
        if orig_sr == target_sr or len(audio) == 0:
            return audio.astype(np.float32)
        target_len = int(len(audio) * target_sr / orig_sr)
        orig_indices = np.linspace(0, len(audio) - 1, len(audio))
        target_indices = np.linspace(0, len(audio) - 1, target_len)
        return np.interp(target_indices, orig_indices, audio).astype(np.float32)

    @staticmethod
    def calculate_rms(audio: np.ndarray) -> float:
        """Calculates Root-Mean-Square energy of audio buffer."""
        if len(audio) == 0:
            return 0.0
        return float(np.sqrt(np.mean(np.square(audio))))

    @staticmethod
    def apply_noise_gate(audio: np.ndarray, threshold_rms: float = 0.01) -> np.ndarray:
        """Applies hard noise gate: zeroes signal if RMS < threshold."""
        rms = AudioInferenceUtils.calculate_rms(audio)
        if rms < threshold_rms:
            return np.zeros_like(audio)
        return audio

    @staticmethod
    def match_polyphonic_clusters(detected: set[int], expected: set[int]) -> dict:
        """Computes Precision, Recall, and F1 score for polyphonic pitch sets."""
        if not detected and not expected:
            return {"precision": 1.0, "recall": 1.0, "f1": 1.0, "tp": 0, "fp": 0, "fn": 0}
        
        tp = len(detected.intersection(expected))
        fp = len(detected - expected)
        fn = len(expected - detected)
        
        precision = tp / (tp + fp) if (tp + fp) > 0 else 0.0
        recall = tp / (tp + fn) if (tp + fn) > 0 else 0.0
        f1 = (2 * precision * recall) / (precision + recall) if (precision + recall) > 0 else 0.0
        
        return {
            "precision": precision,
            "recall": recall,
            "f1": f1,
            "tp": tp,
            "fp": fp,
            "fn": fn
        }


class OMRUtils:
    """Projection profiling and sheet music image analysis."""

    @staticmethod
    def horizontal_projection(binary_image: np.ndarray) -> np.ndarray:
        """Sums dark/foreground pixels horizontally across each row."""
        return np.sum(binary_image > 0, axis=1)

    @staticmethod
    def find_staff_lines(projection: np.ndarray, min_threshold_ratio: float = 0.5) -> list[int]:
        """Detects staff line Y coordinates from horizontal projection peaks."""
        max_val = np.max(projection) if len(projection) > 0 else 0
        if max_val == 0:
            return []
        threshold = max_val * min_threshold_ratio
        peaks = []
        for y in range(1, len(projection) - 1):
            if projection[y] >= threshold and projection[y] >= projection[y - 1] and projection[y] >= projection[y + 1]:
                peaks.append(y)
        return peaks


class ConfigValidator:
    """Validators for project configuration files."""

    @staticmethod
    def parse_godot_project_file(path: str) -> dict:
        """Parses Godot project.godot key-values and sections."""
        if not os.path.exists(path):
            raise FileNotFoundError(f"File not found: {path}")
        
        sections = {}
        current_section = "root"
        sections[current_section] = {}
        
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith(";"):
                    continue
                if line.startswith("[") and line.endswith("]"):
                    current_section = line[1:-1]
                    if current_section not in sections:
                        sections[current_section] = {}
                elif "=" in line:
                    key, val = line.split("=", 1)
                    sections[current_section][key.strip()] = val.strip()
                    
        return sections

    @staticmethod
    def parse_export_presets(path: str) -> dict:
        """Parses export_presets.cfg."""
        if not os.path.exists(path):
            raise FileNotFoundError(f"File not found: {path}")
        return ConfigValidator.parse_godot_project_file(path)


class ChartValidator:
    """JSON Chart format schema validator."""
    
    REQUIRED_ROOT_KEYS = ["title", "bpm", "time_signature", "audio_file", "notes"]
    REQUIRED_NOTE_KEYS = ["pitch_name", "pitch_midi", "staff", "time_sec", "duration_sec", "measure", "beat"]

    @staticmethod
    def validate_chart_dict(chart: dict) -> tuple[bool, str]:
        for key in ChartValidator.REQUIRED_ROOT_KEYS:
            if key not in chart:
                return False, f"Missing root key: {key}"
        if not isinstance(chart["notes"], list):
            return False, "chart['notes'] must be a list"
        
        for idx, note in enumerate(chart["notes"]):
            for nkey in ChartValidator.REQUIRED_NOTE_KEYS:
                if nkey not in note:
                    return False, f"Note index {idx} missing key: {nkey}"
            if not (21 <= note["pitch_midi"] <= 108):
                return False, f"Note index {idx} pitch_midi {note['pitch_midi']} out of standard range [21, 108]"
            if note["time_sec"] < 0:
                return False, f"Note index {idx} negative time_sec: {note['time_sec']}"
            if note["duration_sec"] <= 0:
                return False, f"Note index {idx} non-positive duration_sec: {note['duration_sec']}"
                
        return True, "Valid"


# ==============================================================================
# Simulation & Harness Evaluators for Tier 5 Hardening
# ==============================================================================

class HeadlessScoringSimulator:
    """
    Python mirror of res://scripts/scoring_service.gd for deterministic
    chart playthrough and alignment verification without live microphone input.
    """

    WINDOW_PERFECT_SEC = 0.050
    WINDOW_GOOD_SEC = 0.100
    TIMING_EPSILON = 0.000005

    POINTS_PERFECT = 100
    POINTS_GOOD = 50
    POINTS_MISS = 0

    COMBO_2X = 10
    COMBO_3X = 20
    COMBO_4X = 30

    def __init__(self) -> None:
        self.reset()

    def reset(self) -> None:
        self.score: int = 0
        self.combo: int = 0
        self.max_combo: int = 0
        self.count_perfect: int = 0
        self.count_good: int = 0
        self.count_miss: int = 0
        self.total_notes: int = 0

    def get_multiplier(self) -> int:
        if self.combo >= self.COMBO_4X:
            return 4
        elif self.combo >= self.COMBO_3X:
            return 3
        elif self.combo >= self.COMBO_2X:
            return 2
        return 1

    def evaluate_timing(self, time_diff_sec: float) -> str:
        abs_diff = abs(time_diff_sec)
        if abs_diff <= self.WINDOW_PERFECT_SEC + self.TIMING_EPSILON:
            return "PERFECT"
        elif abs_diff <= self.WINDOW_GOOD_SEC + self.TIMING_EPSILON:
            return "GOOD"
        return "MISS"

    def register_hit(self, judgment: str, note_data: Optional[Dict] = None) -> Dict[str, Any]:
        if judgment not in ("PERFECT", "GOOD", "MISS"):
            return {}
        self.total_notes += 1
        base_pts = 0
        if judgment == "PERFECT":
            self.count_perfect += 1
            self.combo += 1
            base_pts = self.POINTS_PERFECT
        elif judgment == "GOOD":
            self.count_good += 1
            self.combo += 1
            base_pts = self.POINTS_GOOD
        elif judgment == "MISS":
            self.count_miss += 1
            self.combo = 0
            base_pts = self.POINTS_MISS

        if self.combo > self.max_combo:
            self.max_combo = self.combo

        mult = self.get_multiplier()
        points_awarded = base_pts * mult
        self.score += points_awarded
        return {
            "judgment": judgment,
            "base_points": base_pts,
            "multiplier": mult,
            "points_awarded": points_awarded,
            "score": self.score,
            "combo": self.combo,
            "max_combo": self.max_combo,
            "note_data": note_data or {},
        }

    def register_miss(self, note_data: Optional[Dict] = None) -> Dict[str, Any]:
        return self.register_hit("MISS", note_data)

    def process_input(
        self,
        input_time: float,
        pitch_midi: int,
        notes: List[Dict[str, Any]],
        semitone_tolerance: int = 0,
    ) -> Dict[str, Any]:
        best_index = -1
        min_abs_diff = 9999.0

        for i, note in enumerate(notes):
            if note.get("is_hit", False) or note.get("is_missed", False):
                continue
            note_pitch = int(note.get("pitch_midi", 0))
            note_time = float(note.get("time_sec", 0.0))

            if abs(note_pitch - pitch_midi) > semitone_tolerance:
                continue

            time_diff = input_time - note_time
            abs_diff = abs(time_diff)
            if abs_diff <= (self.WINDOW_GOOD_SEC + self.TIMING_EPSILON) and abs_diff < min_abs_diff:
                min_abs_diff = abs_diff
                best_index = i

        if best_index != -1:
            target_note = notes[best_index]
            time_diff = input_time - float(target_note.get("time_sec", 0.0))
            judgment = self.evaluate_timing(time_diff)
            target_note["is_hit"] = True
            target_note["hit_time"] = input_time
            target_note["hit_diff"] = time_diff
            target_note["judgment"] = judgment
            res = self.register_hit(judgment, target_note)
            res["matched_note_index"] = best_index
            res["time_diff"] = time_diff
            return res

        return {}

    def check_expired_notes(self, current_time: float, notes: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        expired_events = []
        for i, note in enumerate(notes):
            if note.get("is_hit", False) or note.get("is_missed", False):
                continue
            note_time = float(note.get("time_sec", 0.0))
            if current_time > note_time + self.WINDOW_GOOD_SEC:
                note["is_missed"] = True
                res = self.register_miss(note)
                res["matched_note_index"] = i
                expired_events.append(res)
        return expired_events

    def get_accuracy(self) -> float:
        if self.total_notes == 0:
            return 100.0
        weighted = (float(self.count_perfect) * 1.0) + (float(self.count_good) * 0.5)
        return (weighted / float(self.total_notes)) * 100.0

    def get_summary(self) -> Dict[str, Any]:
        return {
            "score": self.score,
            "combo": self.combo,
            "max_combo": self.max_combo,
            "multiplier": self.get_multiplier(),
            "total_notes": self.total_notes,
            "count_perfect": self.count_perfect,
            "count_good": self.count_good,
            "count_miss": self.count_miss,
            "accuracy_pct": self.get_accuracy(),
        }


def simulate_piece_playthrough(
    chart_path: str,
    timing_offset_sec: float = 0.015,
    semitone_tolerance: int = 0,
) -> Tuple[bool, Dict[str, Any]]:
    """
    Loads a bundled reference chart, validates schema and beat-to-second alignment,
    and simulates a full headless playthrough at the specified timing offset.
    """
    if not os.path.exists(chart_path):
        return False, {"error": f"Chart not found: {chart_path}"}

    with open(chart_path, "r", encoding="utf-8") as f:
        chart = json.load(f)

    valid, msg = ChartValidator.validate_chart_dict(chart)
    if not valid:
        return False, {"error": f"Invalid chart schema: {msg}"}

    bpm = float(chart["bpm"])
    time_sig = chart["time_signature"]
    beats_per_measure = float(time_sig[0])
    sec_per_beat = 60.0 / bpm

    notes = copy.deepcopy(chart["notes"])
    for n in notes:
        n["is_hit"] = False
        n["is_missed"] = False
        expected_onset_beat = (int(n["measure"]) - 1) * beats_per_measure + float(n["beat"])
        expected_time_sec = expected_onset_beat * sec_per_beat
        if abs(float(n["time_sec"]) - expected_time_sec) > 0.02:
            return False, {
                "error": f"Alignment mismatch on note {n}: time_sec={n['time_sec']} vs expected={expected_time_sec}"
            }
        y_coord = DiatonicMath.midi_to_y(int(n["pitch_midi"]))
        x_at_hit = HighwayMath.note_x_position(float(n["time_sec"]), float(n["time_sec"]))
        if abs(x_at_hit - DiatonicMath.HIT_LINE_X) > 1e-4 or not (0.0 < y_coord < 720.0):
            return False, {"error": f"Invalid highway coordinate for note {n}"}

    sim = HeadlessScoringSimulator()
    onset_groups: Dict[float, List[Dict[str, Any]]] = {}
    for n in notes:
        t = round(float(n["time_sec"]), 4)
        onset_groups.setdefault(t, []).append(n)

    for onset_time in sorted(onset_groups.keys()):
        cluster_notes = onset_groups[onset_time]
        pitches = [int(n["pitch_midi"]) for n in cluster_notes]
        playhead_time = onset_time + timing_offset_sec

        cluster_metrics = AudioInferenceUtils.match_polyphonic_clusters(set(pitches), set(pitches))
        if cluster_metrics["f1"] < 1.0:
            return False, {"error": "Polyphonic cluster self-match F1 < 1.0"}

        for p in pitches:
            sim.process_input(playhead_time, p, cluster_notes, semitone_tolerance=semitone_tolerance)

        sim.check_expired_notes(playhead_time, cluster_notes)

    last_time = max(float(n["time_sec"]) + float(n["duration_sec"]) for n in notes) + 1.0
    sim.check_expired_notes(last_time, notes)

    summary = sim.get_summary()
    summary["title"] = chart.get("title", os.path.basename(chart_path))
    summary["bpm"] = bpm
    summary["chart_notes"] = len(notes)
    summary["onset_clusters"] = len(onset_groups)

    expected_judgment = sim.evaluate_timing(timing_offset_sec)
    if expected_judgment == "PERFECT":
        passed = (
            summary["count_perfect"] == len(notes)
            and summary["count_miss"] == 0
            and abs(summary["accuracy_pct"] - 100.0) < 1e-4
        )
    elif expected_judgment == "GOOD":
        passed = (
            summary["count_good"] == len(notes)
            and summary["count_miss"] == 0
            and abs(summary["accuracy_pct"] - 50.0) < 1e-4
        )
    else:
        passed = summary["count_miss"] == len(notes) and summary["combo"] == 0

    return passed, summary


def evaluate_note_metrics(
    detected: List[Dict],
    ground_truth: List[Dict],
    onset_tolerance_sec: float = 0.15,
    pitch_tolerance_semitones: int = 0,
) -> Dict[str, float]:
    """
    Evaluates note-level True Positives, False Positives, False Negatives,
    Precision, Recall, and F1-score against ground truth chart notes.
    """
    gt_matched = [False] * len(ground_truth)
    det_matched = [False] * len(detected)

    for i, d in enumerate(detected):
        for j, g in enumerate(ground_truth):
            if gt_matched[j]:
                continue
            pitch_match = abs(d["pitch"] - g["pitch_midi"]) <= pitch_tolerance_semitones
            onset_match = abs(d["onset_sec"] - g["time_sec"]) <= onset_tolerance_sec
            if pitch_match and onset_match:
                gt_matched[j] = True
                det_matched[i] = True
                break

    tp = sum(det_matched)
    fp = len(detected) - tp
    fn = len(ground_truth) - sum(gt_matched)

    precision = tp / (tp + fp) if (tp + fp) > 0 else 0.0
    recall = tp / (tp + fn) if (tp + fn) > 0 else 0.0
    f1 = 2.0 * precision * recall / (precision + recall) if (precision + recall) > 0 else 0.0

    return {
        "tp": tp,
        "fp": fp,
        "fn": fn,
        "precision": precision,
        "recall": recall,
        "f1": f1,
        "gt_count": len(ground_truth),
        "det_count": len(detected),
    }


def evaluate_omr_metrics(
    detected_notes: List[Dict],
    ground_truth_notes: List[Dict],
    onset_beat_tolerance: float = 0.25,
) -> Dict[str, float]:
    """
    Evaluates True Positives, False Positives, False Negatives,
    Precision, Recall, and Recognition Accuracy between detected and ground truth notes.
    """
    gt_matched = [False] * len(ground_truth_notes)
    det_matched = [False] * len(detected_notes)

    for i, d in enumerate(detected_notes):
        d_pitch = d.get("pitch_midi")
        d_beat = d.get("onset_beat", d.get("beat", 0.0))

        for j, g in enumerate(ground_truth_notes):
            if gt_matched[j]:
                continue
            g_pitch = g.get("pitch_midi")
            g_beat = g.get("onset_beat", g.get("beat", 0.0))

            pitch_match = (d_pitch == g_pitch)
            onset_match = abs(d_beat - g_beat) <= onset_beat_tolerance

            if pitch_match and onset_match:
                gt_matched[j] = True
                det_matched[i] = True
                break

    tp = sum(det_matched)
    fp = len(detected_notes) - tp
    fn = len(ground_truth_notes) - sum(gt_matched)

    total_reference = len(ground_truth_notes)
    total_detected = len(detected_notes)

    precision = tp / total_detected if total_detected > 0 else 0.0
    recall = tp / total_reference if total_reference > 0 else 0.0
    accuracy = tp / max(total_reference, total_detected) if max(total_reference, total_detected) > 0 else 0.0

    return {
        "tp": tp,
        "fp": fp,
        "fn": fn,
        "gt_count": total_reference,
        "det_count": total_detected,
        "precision": precision,
        "recall": recall,
        "accuracy": accuracy,
    }


def validate_project_config() -> Tuple[bool, List[str]]:
    """Validates project.godot autoloads, main scene, audio input, and rendering settings."""
    logs: List[str] = []
    proj_path = os.path.join(PROJECT_ROOT, "project.godot")
    if not os.path.exists(proj_path):
        return False, ["project.godot missing"]

    config = ConfigValidator.parse_godot_project_file(proj_path)
    app = config.get("application", {})
    main_scene = app.get("run/main_scene", "").strip('"')
    if not main_scene.startswith("res://"):
        return False, ["run/main_scene missing or invalid"]

    local_main = os.path.join(PROJECT_ROOT, main_scene.replace("res://", ""))
    if not os.path.exists(local_main):
        return False, [f"Main scene file missing: {local_main}"]

    autoloads = config.get("autoload", {})
    for name, path_val in autoloads.items():
        clean_path = path_val.strip('"*')
        if clean_path.startswith("res://"):
            local_auto = os.path.join(PROJECT_ROOT, clean_path.replace("res://", ""))
            if not os.path.exists(local_auto):
                return False, [f"Orphaned autoload {name}: {local_auto}"]

    logs.append("project.godot verified clean.")
    return True, logs


def validate_export_presets() -> Tuple[bool, List[str]]:
    """Validates export_presets.cfg for Android (ARM64-v8a), Windows (x86_64), and iOS."""
    logs: List[str] = []
    exp_path = os.path.join(PROJECT_ROOT, "export_presets.cfg")
    if not os.path.exists(exp_path):
        return False, ["export_presets.cfg missing"]

    with open(exp_path, "r", encoding="utf-8") as f:
        content = f.read()

    required_tokens = [
        'name="Android"',
        "architectures/arm64-v8a=true",
        "permissions/record_audio=true",
        "permissions/modify_audio_settings=true",
        'name="Windows Desktop"',
        'binary_format/architecture="x86_64"',
        "binary_format/embed_pck=true",
        'name="iOS"',
        'application/app_store_team_id="0000000000"',
    ]
    for token in required_tokens:
        if token not in content:
            return False, [f"Missing required export preset token: {token}"]

    logs.append("export_presets.cfg verified for Android, Windows Desktop, and iOS.")
    return True, logs
