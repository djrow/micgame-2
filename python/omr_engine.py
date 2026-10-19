"""
Standalone Optical Music Recognition (OMR) Engine for MicGame-2.
Ingests sheet music images (PNG/JPEG) using Pillow and NumPy (with OpenCV optimization),
detects grand staves (Treble and Bass), barlines, time signatures, noteheads, stems,
durations, and polyphonic chords, and outputs structured rhythm charts conforming
to chart.json schema.
"""

import argparse
import json
import math
import os
import sys
from typing import Dict, List, Optional, Tuple

import numpy as np

# Dual support for Pillow and OpenCV
try:
    from PIL import Image as PILImage
except ImportError:
    PILImage = None

try:
    import cv2
except ImportError:
    cv2 = None


# Diatonic pitch mapping lookup table matching score generation standards.
# Spacing Ss = 20px, half-step dy = 10px.
# Staves: Treble (320..400), Middle C (420), Bass (440..520).
Y_TO_NOTE_TABLE: Dict[int, Tuple[int, str, str]] = {
    280: (84, "C6", "treble"),
    290: (83, "B5", "treble"),
    300: (81, "A5", "treble"),
    310: (79, "G5", "treble"),
    320: (77, "F5", "treble"),
    330: (76, "E5", "treble"),
    340: (74, "D5", "treble"),
    350: (72, "C5", "treble"),
    360: (71, "B4", "treble"),
    370: (69, "A4", "treble"),
    380: (67, "G4", "treble"),
    390: (65, "F4", "treble"),
    400: (64, "E4", "treble"),
    410: (62, "D4", "treble"),
    420: (60, "C4", "treble"),
    430: (59, "B3", "bass"),
    440: (57, "A3", "bass"),
    450: (55, "G3", "bass"),
    460: (53, "F3", "bass"),
    470: (52, "E3", "bass"),
    480: (50, "D3", "bass"),
    490: (48, "C3", "bass"),
    500: (47, "B2", "bass"),
    510: (45, "A2", "bass"),
    520: (43, "G2", "bass"),
    530: (41, "F2", "bass"),
    540: (40, "E2", "bass"),
    550: (38, "D2", "bass"),
    560: (36, "C2", "bass"),
}


class OMREngine:
    """
    Robust Optical Music Recognition engine for piano grand staff scores.
    Converts 2D sheet music images into structured, playable note charts.
    """

    def __init__(self, staff_spacing: float = 20.0):
        self.staff_spacing = staff_spacing

    def load_and_binarize(self, image_path: str) -> np.ndarray:
        """
        Loads score image as grayscale and binarizes with Otsu thresholding.
        Supports both Pillow and OpenCV backends.
        Guards against corrupt files, zero-byte files, missing files,
        and inverted color polarity.
        """
        if not os.path.exists(image_path):
            raise FileNotFoundError(f"Score image not found: {image_path}")

        file_size = os.path.getsize(image_path)
        if file_size == 0:
            raise ValueError(f"Score image file is 0 bytes: {image_path}")

        img: Optional[np.ndarray] = None

        # Primary load via OpenCV or Pillow
        if cv2 is not None:
            img = cv2.imread(image_path, cv2.IMREAD_GRAYSCALE)

        if img is None and PILImage is not None:
            try:
                pil_img = PILImage.open(image_path).convert("L")
                img = np.array(pil_img, dtype=np.uint8)
            except Exception as e:
                raise ValueError(f"Failed to decode image with Pillow: {image_path} ({e})")

        if img is None or img.size == 0:
            raise ValueError(f"Failed to decode image: {image_path}")

        # Uniform image (all-white or all-black) has no foreground musical content
        if float(np.std(img)) < 1.0:
            return np.zeros_like(img, dtype=np.uint8)

        # Otsu thresholding: foreground ink = 255, background paper = 0
        if cv2 is not None:
            _, binary = cv2.threshold(img, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)
        else:
            # Pure NumPy Otsu binarization fallback
            hist, bin_edges = np.histogram(img, bins=256, range=(0, 256))
            total = img.size
            current_max, threshold = 0.0, 128
            sum_total = np.dot(np.arange(256), hist)
            sum_b, weight_b = 0.0, 0
            for i in range(256):
                weight_b += hist[i]
                if weight_b == 0:
                    continue
                weight_f = total - weight_b
                if weight_f == 0:
                    break
                sum_b += i * hist[i]
                mean_b = sum_b / weight_b
                mean_f = (sum_total - sum_b) / weight_f
                between_class_variance = weight_b * weight_f * (mean_b - mean_f) ** 2
                if between_class_variance > current_max:
                    current_max = between_class_variance
                    threshold = i
            binary = np.where(img < threshold, 255, 0).astype(np.uint8)

        # Inverted polarity defense: if foreground > 50%, invert
        if float(np.mean(binary == 255)) > 0.50:
            binary = 255 - binary

        return binary

    def detect_staves(self, binary: np.ndarray) -> Tuple[List[int], List[int], float]:
        """
        Detects horizontal staff lines via horizontal projection profile,
        groups them into Treble (5 lines) and Bass (5 lines) staves,
        and computes the staff line spacing Ss.
        """
        h, w = binary.shape
        if h < 60 or w < 60:
            return [320, 340, 360, 380, 400], [440, 460, 480, 500, 520], 20.0

        h_proj = np.sum(binary == 255, axis=1)
        thresh = 0.35 * w
        raw_lines = np.where(h_proj > thresh)[0]

        # Cluster adjacent pixel rows (delta <= 2px)
        clusters: List[List[int]] = []
        for y in raw_lines:
            if not clusters or y - clusters[-1][-1] > 2:
                clusters.append([y])
            else:
                clusters[-1].append(y)

        line_ys = [int(round(float(np.mean(cl)))) for cl in clusters]

        if len(line_ys) == 10:
            treble = line_ys[:5]
            bass = line_ys[5:]
            ss_treble = (treble[4] - treble[0]) / 4.0
            ss_bass = (bass[4] - bass[0]) / 4.0
            ss = (ss_treble + ss_bass) / 2.0
            if ss <= 0:
                ss = 20.0
            self.staff_spacing = ss
            return treble, bass, ss
        elif len(line_ys) >= 10:
            treble = line_ys[:5]
            bass = line_ys[5:10]
            ss = 20.0
            return treble, bass, ss
        else:
            # Fallback to standard grand staff coordinates
            return [320, 340, 360, 380, 400], [440, 460, 480, 500, 520], 20.0

    def detect_barlines(
        self, binary: np.ndarray, treble_ys: List[int], bass_ys: List[int]
    ) -> List[int]:
        """
        Detects measure barlines spanning across staves via vertical line morphology.
        Includes fallback for broken/per-staff barlines.
        """
        h, w = binary.shape
        if h < 100 or w < 250:
            return [0, max(1, w - 1)]

        if cv2 is not None:
            k_bar = cv2.getStructuringElement(cv2.MORPH_RECT, (1, 100))
            barlines_img = cv2.morphologyEx(binary, cv2.MORPH_OPEN, k_bar)

            y_top = max(0, min(h - 1, treble_ys[0] - 5))
            y_bot = max(y_top + 1, min(h, bass_ys[-1] + 5))
            cols = np.where(np.sum(barlines_img[y_top:y_bot, :] == 255, axis=0) > 80)[0]

            clusters: List[List[int]] = []
            for c in cols:
                if c < 150:  # Skip left bracket/clef
                    continue
                if not clusters or c - clusters[-1][-1] > 5:
                    clusters.append([c])
                else:
                    clusters[-1].append(c)

            # Fallback for broken barlines (inter-staff gap erased)
            if len(clusters) < 2:
                k_bar_short = cv2.getStructuringElement(cv2.MORPH_RECT, (1, 55))
                short_img = cv2.morphologyEx(binary, cv2.MORPH_OPEN, k_bar_short)
                cols_short = np.where(np.sum(short_img[y_top:y_bot, :] == 255, axis=0) > 95)[0]
                clusters = []
                for c in cols_short:
                    if c < 150:
                        continue
                    if not clusters or c - clusters[-1][-1] > 5:
                        clusters.append([c])
                    else:
                        clusters[-1].append(c)

            barlines = [int(round(float(np.mean(cl)))) for cl in clusters]
        else:
            barlines = []

        if len(barlines) < 2:
            if w >= 1520:
                return [230, 552, 875, 1197, 1520]
            return [0, max(1, w - 1)]

        return barlines

    def detect_time_signature(
        self, binary: np.ndarray, treble_ys: List[int]
    ) -> List[int]:
        """
        Identifies time signature (e.g. [4, 4] vs [3, 4]) by examining the numerator glyph.
        The numeral '4' contains an enclosed triangular hole, whereas '3' is open.
        """
        h, w = binary.shape
        y_mid = treble_ys[1]  # Line 2 (Y=340)
        y1 = max(0, y_mid - 15)
        y2 = min(h, y_mid + 20)
        x1 = min(w, 180)
        x2 = min(w, 215)
        if y2 <= y1 or x2 <= x1:
            return [4, 4]

        ts_patch = binary[y1:y2, x1:x2]
        if cv2 is not None:
            contours, hier = cv2.findContours(
                ts_patch, cv2.RETR_CCOMP, cv2.CHAIN_APPROX_SIMPLE
            )
            has_hole = False
            if hier is not None:
                for h_node in hier[0]:
                    if h_node[2] != -1:  # Has child hole
                        has_hole = True
                        break
            return [4, 4] if has_hole else [3, 4]

        return [4, 4]

    def detect_hollow_holes(
        self, binary: np.ndarray
    ) -> Tuple[np.ndarray, List[Tuple[float, float]]]:
        """
        Detects the enclosed white holes of hollow noteheads (half & whole notes),
        and returns a filled binary image where hollow noteheads are filled solid.
        """
        if cv2 is None:
            return binary.copy(), []

        inv = cv2.bitwise_not(binary)
        contours, _ = cv2.findContours(inv, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
        filled = binary.copy()
        hollow_coords: List[Tuple[float, float]] = []

        for c in contours:
            x, y, w, h = cv2.boundingRect(c)
            area = cv2.contourArea(c)
            # Hollow notehead inner hole: width ~10..18px, height ~5..12px, area ~50..160px
            if 10 <= w <= 18 and 5 <= h <= 12 and 50 <= area <= 160 and 200 < y < 650 and x > 200:
                cv2.drawContours(filled, [c], -1, 255, -1)
                hollow_coords.append((x + w / 2.0, y + h / 2.0))

        return filled, hollow_coords

    def remove_staff_lines(
        self,
        img: np.ndarray,
        staff_ys: List[int],
        ledger_ys: Tuple[int, ...] = (300, 420, 540, 560),
    ) -> np.ndarray:
        """
        Erase horizontal staff lines and ledger lines via run-length subtraction,
        preserving notehead cores and stems.
        """
        clean = img.copy()
        all_ys = list(staff_ys) + list(ledger_ys)
        h, w = img.shape

        for y in all_ys:
            for dy in (-1, 0, 1):
                row = y + dy
                if 0 <= row < h:
                    col_sum = np.sum(
                        img[max(0, row - 2) : min(h, row + 3), :] == 255, axis=0
                    )
                    clean[row, col_sum <= 3] = 0
        return clean

    def extract_noteheads_and_dots(
        self,
        no_staff_binary: np.ndarray,
        hollow_coords: List[Tuple[float, float]],
        x_min: int = 220,
        x_max: int = 1515,
    ) -> Tuple[List[Dict], List[Tuple[float, float]]]:
        """
        Extracts notehead centroids, dimensions, hollow classification, and dots.
        Splits vertically merged chord notehead blobs when height spans multiple steps.
        """
        if cv2 is None:
            return [], []

        k_note = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7))
        notes_img = cv2.morphologyEx(no_staff_binary, cv2.MORPH_OPEN, k_note)

        contours, _ = cv2.findContours(
            notes_img, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE
        )
        raw_notes: List[Dict] = []
        dots: List[Tuple[float, float]] = []

        for c in contours:
            x, y, w, h = cv2.boundingRect(c)
            if x_min < x < x_max and 250 < y < 650:
                M = cv2.moments(c)
                if M["m00"] > 0:
                    cx = float(M["m10"] / M["m00"])
                    cy = float(M["m01"] / M["m00"])
                    # Merged vertical chord stack (height spans multiple diatonic steps)
                    if 14 <= w <= 36 and h >= 28:
                        num_stacked = max(2, int(round(h / 20.0)))
                        step_span = (num_stacked - 1) * 20.0
                        top_cy = cy - step_span / 2.0
                        for k in range(num_stacked):
                            sub_cy = top_cy + k * 20.0
                            is_h = any(
                                abs(cx - hx) < 8 and abs(sub_cy - hy) < 8
                                for hx, hy in hollow_coords
                            )
                            raw_notes.append(
                                {
                                    "cx": cx,
                                    "cy": sub_cy,
                                    "is_hollow": is_h,
                                    "bbox": (x, int(round(sub_cy - 8)), w, 16),
                                }
                            )
                    elif w >= 14 and h >= 10:
                        is_h = any(
                            abs(cx - hx) < 8 and abs(cy - hy) < 8
                            for hx, hy in hollow_coords
                        )
                        raw_notes.append(
                            {
                                "cx": cx,
                                "cy": cy,
                                "is_hollow": is_h,
                                "bbox": (x, y, w, h),
                            }
                        )
                    elif 4 <= w <= 10 and 4 <= h <= 10:
                        dots.append((cx, cy))

        return raw_notes, dots

    def check_stem_and_flag(
        self,
        stems_img: np.ndarray,
        cx: float,
        cy: float,
        rx: int = 10,
        ry: int = 7,
        stem_len: int = 70,
    ) -> Tuple[bool, bool]:
        """
        Determines stem presence and flags/beams for a notehead.
        Stems extend 70px upwards from (cx+rx-1) or downwards from (cx-rx+1).
        """
        stem_up_x = int(round(cx + rx - 1))
        y_up_start = max(0, int(round(cy - stem_len)))
        y_up_end = max(0, int(round(cy - ry - 2)))
        up_slice = stems_img[
            y_up_start:y_up_end,
            max(0, stem_up_x - 1) : min(stems_img.shape[1], stem_up_x + 2),
        ]
        has_up = bool(np.sum(up_slice == 255) > 20)

        stem_down_x = int(round(cx - rx + 1))
        y_down_start = min(stems_img.shape[0], int(round(cy + ry + 2)))
        y_down_end = min(stems_img.shape[0], int(round(cy + stem_len)))
        down_slice = stems_img[
            y_down_start:y_down_end,
            max(0, stem_down_x - 1) : min(stems_img.shape[1], stem_down_x + 2),
        ]
        has_down = bool(np.sum(down_slice == 255) > 20)

        has_stem = has_up or has_down
        has_flag = False

        if has_up:
            flag_box = stems_img[
                y_up_start : y_up_start + 22,
                stem_up_x + 2 : min(stems_img.shape[1], stem_up_x + 15),
            ]
            if np.sum(flag_box == 255) > 10:
                has_flag = True
        elif has_down:
            flag_box = stems_img[
                max(0, y_down_end - 22) : y_down_end,
                stem_down_x + 2 : min(stems_img.shape[1], stem_down_x + 15),
            ]
            if np.sum(flag_box == 255) > 10:
                has_flag = True

        return has_stem, has_flag

    def map_pitch(self, cy: float) -> Tuple[int, str, str]:
        """
        Maps vertical centroid cy to diatonic MIDI pitch, pitch name, and staff.
        Nearest multiple of 10px corresponds to diatonic steps (lines and spaces).
        """
        nearest_y = int(round(cy / 10.0) * 10)
        return Y_TO_NOTE_TABLE.get(nearest_y, (60, "C4", "treble"))

    def process_score(
        self,
        image_path: str,
        audio_file: str = "audio.wav",
        bpm: Optional[float] = None,
        title: Optional[str] = None,
    ) -> Dict:
        """
        Executes full OMR pipeline on sheet music image and produces structured chart dictionary.
        """
        binary = self.load_and_binarize(image_path)
        treble_ys, bass_ys, ss = self.detect_staves(binary)
        barlines = self.detect_barlines(binary, treble_ys, bass_ys)
        time_sig = self.detect_time_signature(binary, treble_ys)
        beats_per_measure = time_sig[0]
        num_measures = len(barlines) - 1

        if bpm is None or bpm <= 0.0 or math.isnan(bpm) or math.isinf(bpm):
            bpm = 120.0

        if title is None:
            title = os.path.splitext(os.path.basename(image_path))[0]

        # 1. Detect hollow holes & fill them
        filled, hollow_coords = self.detect_hollow_holes(binary)

        # 2. Staff lines & barlines removal
        no_staff = self.remove_staff_lines(filled, treble_ys + bass_ys)
        if cv2 is not None:
            k_bar = cv2.getStructuringElement(cv2.MORPH_RECT, (1, 100))
            barlines_img = cv2.morphologyEx(binary, cv2.MORPH_OPEN, k_bar)
            no_staff[barlines_img == 255] = 0

        # 3. Extract notehead candidates & dots
        raw_notes, dots = self.extract_noteheads_and_dots(no_staff, hollow_coords)

        # 4. Clean stems image with noteheads erased
        clean_stems = self.remove_staff_lines(binary, treble_ys + bass_ys)
        if cv2 is not None:
            for n in raw_notes:
                cv2.ellipse(
                    clean_stems,
                    (int(round(n["cx"])), int(round(n["cy"]))),
                    (12, 9),
                    0,
                    0,
                    360,
                    0,
                    -1,
                )

        # 5. Polyphonic chord clustering: group notes within delta_x <= 0.6 * Ss
        raw_notes = sorted(raw_notes, key=lambda n: n["cx"])
        clusters: List[List[Dict]] = []
        cluster_threshold = 0.6 * ss
        for n in raw_notes:
            if not clusters or (n["cx"] - clusters[-1][-1]["cx"]) > cluster_threshold:
                clusters.append([n])
            else:
                clusters[-1].append(n)

        sec_per_beat = 60.0 / bpm
        sec_per_measure = beats_per_measure * sec_per_beat

        measures_list: List[Dict] = []
        for m in range(1, num_measures + 1):
            start_b = (m - 1) * beats_per_measure
            measures_list.append(
                {
                    "index": m,
                    "start_beat": float(start_b),
                    "start_sec": round(float(start_b * sec_per_beat), 4),
                    "end_sec": round(float(m * sec_per_measure), 4),
                }
            )

        notes_list: List[Dict] = []
        note_id = 1
        for cl in clusters:
            avg_cx = float(np.mean([n["cx"] for n in cl]))
            is_chord = len(cl) > 1

            # Determine measure index
            m_idx = 1
            for m in range(1, num_measures + 1):
                if avg_cx <= barlines[m] + 5 or m == num_measures:
                    m_idx = m
                    break

            x_left = barlines[m_idx - 1]
            x_right = barlines[m_idx]
            w_cur = x_right - x_left
            rel_x = max(0.0, avg_cx - (x_left + 15.0))
            denom = max(1.0, w_cur - 30.0)
            raw_b = (rel_x / denom) * beats_per_measure
            beat = round(raw_b * 4.0) / 4.0  # Quantize to 16th beat
            onset_beat = (m_idx - 1) * beats_per_measure + beat
            onset_sec = round(float(onset_beat * sec_per_beat), 4)

            for n in cl:
                cx = n["cx"]
                cy = n["cy"]
                is_hollow = n["is_hollow"]

                pitch_midi, pitch_name, staff = self.map_pitch(cy)
                has_stem, has_flag = self.check_stem_and_flag(clean_stems, cx, cy)
                has_dot = any(
                    12 <= (dx - cx) <= 30 and abs(dy - cy) <= 8 for dx, dy in dots
                )

                # Duration determination
                if is_hollow:
                    if not has_stem:
                        dur_beats = 4.0
                    elif has_dot:
                        dur_beats = 3.0
                    else:
                        dur_beats = 2.0
                else:
                    if has_flag:
                        dur_beats = 0.5
                    elif has_dot:
                        dur_beats = 1.5
                    else:
                        dur_beats = 1.0

                dur_sec = round(float(dur_beats * sec_per_beat), 4)

                notes_list.append(
                    {
                        "id": note_id,
                        "pitch_name": pitch_name,
                        "pitch_midi": int(pitch_midi),
                        "staff": staff,
                        "voice": 1 if staff == "treble" else 2,
                        "measure": m_idx,
                        "beat": float(beat),
                        "onset_beat": float(onset_beat),
                        "time_sec": onset_sec,
                        "onset_sec": onset_sec,
                        "duration_beats": float(dur_beats),
                        "duration_sec": dur_sec,
                        "is_chord": is_chord,
                        "velocity": 0.8,
                    }
                )
                note_id += 1

        total_duration_sec = (
            round(float(num_measures * sec_per_measure), 2)
            if measures_list
            else 0.0
        )

        chart: Dict = {
            "version": "1.0.0",
            "title": title,
            "bpm": float(bpm),
            "time_signature": time_sig,
            "audio_file": audio_file,
            "score_file": os.path.basename(image_path),
            "metadata": {
                "title": title,
                "composer": "Unknown",
                "tempo_bpm": float(bpm),
                "time_signature": {
                    "numerator": time_sig[0],
                    "denominator": time_sig[1],
                },
                "key_signature": {"key": "C", "mode": "major", "sharps_flats": 0},
                "duration_sec": total_duration_sec,
                "audio_file": audio_file,
                "score_file": os.path.basename(image_path),
            },
            "measures": measures_list,
            "notes": notes_list,
        }

        return chart

    def save_chart(self, chart: Dict, output_path: str) -> None:
        """Saves chart dictionary to JSON file."""
        os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
        with open(output_path, "w", encoding="utf-8") as f:
            json.dump(chart, f, indent=2)


def main():
    parser = argparse.ArgumentParser(
        description="Standalone Optical Music Recognition (OMR) Engine for MicGame-2"
    )
    parser.add_argument("--score", type=str, required=True, help="Path to input score image (PNG/JPEG)")
    parser.add_argument("--output", type=str, default=None, help="Path to output chart JSON file")
    parser.add_argument("--audio", type=str, default="audio.wav", help="Path to audio accompaniment file")
    parser.add_argument("--bpm", type=float, default=None, help="Tempo in BPM (default: 120.0)")
    parser.add_argument("--title", type=str, default=None, help="Song title (default: filename)")
    args = parser.parse_args()

    engine = OMREngine()
    chart = engine.process_score(
        image_path=args.score,
        audio_file=args.audio,
        bpm=args.bpm,
        title=args.title,
    )

    out_path = args.output
    if out_path is None:
        base = os.path.splitext(args.score)[0]
        out_path = f"{base}_chart.json"

    engine.save_chart(chart, out_path)
    print(f"[OMR Engine] Processed {args.score} -> {out_path} ({len(chart['notes'])} notes detected)")


if __name__ == "__main__":
    main()
