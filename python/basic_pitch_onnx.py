"""
Basic Pitch ONNX Pure NumPy Runner.
Zero scipy/librosa/resampy dependencies.
Uses ONNX Runtime + NumPy for offline transcription and real-time streaming inference.
"""

import os
import wave
from typing import Dict, List, Optional, Tuple, Union
import numpy as np
import onnxruntime as ort

MIDI_OFFSET = 21  # A0
MAX_SEMITONES = 88  # A0 (21) to C8 (108)
AUDIO_SAMPLE_RATE = 22050
AUDIO_N_SAMPLES = 43844
FFT_HOP = 256
FPS = AUDIO_SAMPLE_RATE / FFT_HOP  # ~86.1328 frames/sec


def read_wav_mono(path: str) -> Tuple[np.ndarray, int]:
    """Reads uncompressed 16-bit or 32-bit float PCM WAV file to mono float32 array in [-1.0, 1.0]."""
    with wave.open(path, "rb") as wf:
        n_channels = wf.getnchannels()
        sampwidth = wf.getsampwidth()
        framerate = wf.getframerate()
        n_frames = wf.getnframes()
        data = wf.readframes(n_frames)

    if sampwidth == 2:
        audio = np.frombuffer(data, dtype=np.int16).astype(np.float32) / 32768.0
    elif sampwidth == 4:
        audio = np.frombuffer(data, dtype=np.float32)
    elif sampwidth == 1:
        audio = (np.frombuffer(data, dtype=np.uint8).astype(np.float32) - 128.0) / 128.0
    else:
        raise ValueError(f"Unsupported WAV sample width: {sampwidth}")

    if n_channels > 1:
        audio = audio.reshape(-1, n_channels).mean(axis=1)

    return audio.astype(np.float32), framerate


def resample_to_22050(audio: np.ndarray, orig_sr: int) -> np.ndarray:
    """Linear interpolation resampling to 22,050 Hz using pure NumPy (np.interp)."""
    if orig_sr == AUDIO_SAMPLE_RATE or len(audio) == 0:
        return audio
    num_target_samples = int(len(audio) * AUDIO_SAMPLE_RATE / orig_sr)
    t_orig = np.arange(len(audio)) / orig_sr
    t_target = np.arange(num_target_samples) / AUDIO_SAMPLE_RATE
    return np.interp(t_target, t_orig, audio).astype(np.float32)


def argrelmax_axis0(mat: np.ndarray) -> np.ndarray:
    """Pure NumPy replacement for scipy.signal.argrelmax(mat, axis=0)."""
    peaks = np.zeros_like(mat, dtype=bool)
    if mat.shape[0] < 2:
        return peaks
    if mat.shape[0] >= 3:
        peaks[1:-1] = (mat[1:-1] > mat[:-2]) & (mat[1:-1] >= mat[2:])
    peaks[0] = mat[0] >= mat[1]
    return peaks


def infer_onsets_numpy(onsets: np.ndarray, frames: np.ndarray, n_diff: int = 2) -> np.ndarray:
    """Infers additional onsets from large changes in frame activations."""
    if frames.size == 0 or onsets.size == 0 or frames.shape[0] == 0:
        return onsets
    diffs = []
    for n in range(1, n_diff + 1):
        appended = np.concatenate([np.zeros((n, frames.shape[1]), dtype=np.float32), frames])
        diffs.append(appended[n:, :] - appended[:-n, :])
    frame_diff = np.min(diffs, axis=0)
    frame_diff[frame_diff < 0] = 0
    frame_diff[:n_diff, :] = 0
    if frame_diff.size == 0:
        return onsets
    max_diff = np.max(frame_diff)
    if max_diff > 0:
        max_onsets = np.max(onsets) if onsets.size > 0 else 0.0
        frame_diff = max_onsets * frame_diff / max_diff
    return np.maximum(onsets, frame_diff)


class BasicPitchOnnxRunner:
    """
    Modular ONNX Runtime runner for Spotify's Basic Pitch neural model.
    Supports both offline file transcription and streaming circular buffer inference.
    """

    def __init__(
        self,
        model_path: str,
        note_threshold: float = 0.40,
        onset_threshold: float = 0.45,
        min_note_len_frames: int = 6,
        energy_tolerance_frames: int = 11,
    ):
        if not os.path.isfile(model_path):
            raise FileNotFoundError(f"Basic Pitch ONNX model not found at {model_path}")

        self.model_path = model_path
        self.session = ort.InferenceSession(model_path, providers=["CPUExecutionProvider"])
        self.input_name = self.session.get_inputs()[0].name

        # Map output tensor names
        self.onset_name = "StatefulPartitionedCall:2"
        self.note_name = "StatefulPartitionedCall:1"
        self.contour_name = "StatefulPartitionedCall:0"

        # Verify output names from model metadata
        available_outputs = [o.name for o in self.session.get_outputs()]
        if self.onset_name not in available_outputs:
            self.onset_name = available_outputs[0]
        if self.note_name not in available_outputs:
            self.note_name = available_outputs[1]
        if self.contour_name not in available_outputs and len(available_outputs) > 2:
            self.contour_name = available_outputs[2]

        self.note_threshold = note_threshold
        self.onset_threshold = onset_threshold
        self.min_note_len_frames = min_note_len_frames
        self.energy_tolerance_frames = energy_tolerance_frames

        # Streaming buffer state
        self.ring_buffer = np.zeros(AUDIO_N_SAMPLES, dtype=np.float32)
        self.accumulated_samples = 0
        self.last_onset_time: Dict[int, float] = {p: -999.0 for p in range(MIDI_OFFSET, MIDI_OFFSET + MAX_SEMITONES)}

    def reset_stream(self) -> None:
        """Resets streaming ring buffer and onset debounce timestamps."""
        self.ring_buffer.fill(0)
        self.accumulated_samples = 0
        self.last_onset_time = {p: -999.0 for p in range(MIDI_OFFSET, MIDI_OFFSET + MAX_SEMITONES)}

    def forward(self, audio_chunk_43844: np.ndarray) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
        """
        Runs forward pass returning notes, onsets, and contours probabilities.
        Returns: (notes_172x88, onsets_172x88, contours_172x264)
        """
        if len(audio_chunk_43844) != AUDIO_N_SAMPLES:
            raise ValueError(f"Expected {AUDIO_N_SAMPLES} samples, got {len(audio_chunk_43844)}")

        inp = audio_chunk_43844.reshape(1, AUDIO_N_SAMPLES, 1).astype(np.float32)
        outs = self.session.run(None, {self.input_name: inp})
        out_dict = {o.name: outs[i] for i, o in enumerate(self.session.get_outputs())}

        onsets = out_dict[self.onset_name][0]  # (172, 88)
        notes = out_dict[self.note_name][0]    # (172, 88)
        contours = out_dict.get(self.contour_name, outs[0])[0]  # (172, 264)
        return notes, onsets, contours

    def predict_window(
        self,
        audio_chunk_43844: np.ndarray,
        return_contours: bool = False,
    ) -> Union[Tuple[np.ndarray, np.ndarray], Tuple[np.ndarray, np.ndarray, np.ndarray]]:
        """
        Runs single forward pass on 43,844 samples mono float32.
        Returns: (notes_172x88, onsets_172x88) or (notes, onsets, contours) if return_contours=True.
        """
        notes, onsets, contours = self.forward(audio_chunk_43844)
        if return_contours:
            return notes, onsets, contours
        return notes, onsets

    def predict_raw(
        self,
        audio_samples: np.ndarray,
        sample_rate: int = AUDIO_SAMPLE_RATE,
    ) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
        """
        Runs model forward pass on raw audio buffer.
        Guards against audio buffers < 256 samples by padding with zeros to at least 256 samples.
        """
        if sample_rate != AUDIO_SAMPLE_RATE and len(audio_samples) > 0:
            audio_samples = resample_to_22050(audio_samples, sample_rate)

        if len(audio_samples) < FFT_HOP:
            if len(audio_samples) == 0:
                audio_samples = np.zeros(FFT_HOP, dtype=np.float32)
            else:
                audio_samples = np.pad(audio_samples, (0, FFT_HOP - len(audio_samples)))

        if len(audio_samples) < AUDIO_N_SAMPLES:
            audio_samples = np.pad(audio_samples, (0, AUDIO_N_SAMPLES - len(audio_samples)))
        elif len(audio_samples) > AUDIO_N_SAMPLES:
            audio_samples = audio_samples[:AUDIO_N_SAMPLES]

        return self.forward(audio_samples)

    def process_streaming_chunk(
        self,
        chunk_pcm: np.ndarray,
        sample_rate: int = AUDIO_SAMPLE_RATE,
        current_time_sec: float = 0.0,
    ) -> Tuple[List[int], List[int], Dict[str, float]]:
        """
        Feeds incoming audio PCM chunk to the sliding ring buffer and performs streaming inference.
        Returns: (active_pitches, recent_onsets, confidence_dict)
        """
        if sample_rate != AUDIO_SAMPLE_RATE:
            chunk_pcm = resample_to_22050(chunk_pcm, sample_rate)

        chunk_len = len(chunk_pcm)
        if chunk_len == 0:
            return [], [], {}

        # Slide ring buffer
        if chunk_len >= AUDIO_N_SAMPLES:
            self.ring_buffer[:] = chunk_pcm[-AUDIO_N_SAMPLES:]
        else:
            self.ring_buffer[:-chunk_len] = self.ring_buffer[chunk_len:]
            self.ring_buffer[-chunk_len:] = chunk_pcm

        self.accumulated_samples += chunk_len

        # Run forward pass
        notes, onsets = self.predict_window(self.ring_buffer)

        # Receptive field analysis:
        # Latest real audio corresponds to frames near window end (frames 155..168).
        # Frames 169..171 have edge padding boundary effects, so we inspect frames 158..167 (~70ms window before boundary).
        rec_notes = notes[158:168]   # (10, 88)
        rec_onsets = onsets[158:168] # (10, 88)

        max_notes = rec_notes.max(axis=0)
        max_onsets = rec_onsets.max(axis=0)

        active_pitches: List[int] = []
        recent_onsets: List[int] = []
        confidences: Dict[str, float] = {}

        for b in range(MAX_SEMITONES):
            pitch = b + MIDI_OFFSET
            prob = float(max_notes[b])
            ons = float(max_onsets[b])

            if prob >= self.note_threshold:
                active_pitches.append(pitch)
                confidences[str(pitch)] = round(prob, 3)

            # Onset trigger with 120ms debounce per pitch
            if ons >= self.onset_threshold:
                if (current_time_sec - self.last_onset_time[pitch]) >= 0.120:
                    recent_onsets.append(pitch)
                    self.last_onset_time[pitch] = current_time_sec

        return active_pitches, recent_onsets, confidences

    def transcribe_file(
        self,
        audio_or_path: Union[str, np.ndarray],
        sample_rate: Optional[int] = None,
    ) -> List[Dict[str, Union[int, float]]]:
        """
        Performs complete offline transcription of an audio file or buffer with overlap-add unwrapping.
        Returns sorted list of note events:
        [{"pitch": int, "onset_sec": float, "duration_sec": float, "confidence": float, "onset_prob": float}]
        """
        if isinstance(audio_or_path, str):
            audio, sr = read_wav_mono(audio_or_path)
        else:
            audio = audio_or_path
            sr = sample_rate or AUDIO_SAMPLE_RATE

        if len(audio) < FFT_HOP:
            return []

        audio = resample_to_22050(audio, sr)
        audio_len = len(audio)
        if audio_len < FFT_HOP:
            return []

        n_overlapping_frames = 30
        overlap_len = n_overlapping_frames * FFT_HOP  # 7680 samples
        hop_size = AUDIO_N_SAMPLES - overlap_len      # 36164 samples
        n_olap = int(0.5 * n_overlapping_frames)      # 15 frames

        # Pre-roll padding ensures onset at t=0 has full acoustic context
        pad_start_samples = n_olap * FFT_HOP
        extra_pad_frames = 30
        extra_pad_samples = extra_pad_frames * FFT_HOP
        total_pad_samples = pad_start_samples + extra_pad_samples

        padded_audio = np.concatenate([
            np.zeros(total_pad_samples, dtype=np.float32),
            audio,
            np.zeros(AUDIO_N_SAMPLES, dtype=np.float32),
        ])

        note_windows = []
        onset_windows = []

        for i in range(0, len(padded_audio) - overlap_len, hop_size):
            chunk = padded_audio[i : i + AUDIO_N_SAMPLES]
            if len(chunk) < AUDIO_N_SAMPLES:
                chunk = np.pad(chunk, (0, AUDIO_N_SAMPLES - len(chunk)))

            notes_win, onsets_win = self.predict_window(chunk)
            note_windows.append(notes_win)
            onset_windows.append(onsets_win)

        onsets_concat = np.stack(onset_windows, axis=0)  # (B, 172, 88)
        notes_concat = np.stack(note_windows, axis=0)    # (B, 172, 88)

        # Unwrap output: remove n_olap (15 frames) from beginning and end of each window
        onsets_trimmed = onsets_concat[:, n_olap:-n_olap, :]
        notes_trimmed = notes_concat[:, n_olap:-n_olap, :]

        B, T_trim, F_bins = onsets_trimmed.shape
        unwrapped_onsets = onsets_trimmed.reshape(B * T_trim, F_bins)
        unwrapped_notes = notes_trimmed.reshape(B * T_trim, F_bins)

        # Shift back by extra_pad_frames
        unwrapped_onsets = unwrapped_onsets[extra_pad_frames:]
        unwrapped_notes = unwrapped_notes[extra_pad_frames:]

        n_output_frames = int(np.floor(audio_len * (FPS / AUDIO_SAMPLE_RATE)))
        unwrapped_onsets = unwrapped_onsets[:n_output_frames, :]
        unwrapped_notes = unwrapped_notes[:n_output_frames, :]

        # Note creation post-processing
        frames = unwrapped_notes
        onsets = infer_onsets_numpy(unwrapped_onsets, frames)

        peaks_mask = argrelmax_axis0(onsets)
        peak_thresh_mat = np.zeros_like(onsets)
        peak_thresh_mat[peaks_mask] = onsets[peaks_mask]

        onset_idx = np.where(peak_thresh_mat >= self.onset_threshold)
        onset_time_idx = onset_idx[0][::-1]
        onset_freq_idx = onset_idx[1][::-1]

        remaining_energy = frames.copy()
        note_events: List[Dict[str, Union[int, float]]] = []
        n_total_frames = frames.shape[0]

        for note_start_idx, freq_idx in zip(onset_time_idx, onset_freq_idx):
            if note_start_idx >= n_total_frames - 1:
                continue

            i = note_start_idx + 1
            k = 0
            while i < n_total_frames - 1 and k < self.energy_tolerance_frames:
                if remaining_energy[i, freq_idx] < self.note_threshold:
                    k += 1
                else:
                    k = 0
                i += 1
            i -= k

            if i - note_start_idx <= self.min_note_len_frames:
                continue

            remaining_energy[note_start_idx:i, freq_idx] = 0
            if freq_idx < MAX_SEMITONES - 1:
                remaining_energy[note_start_idx:i, freq_idx + 1] = 0
            if freq_idx > 0:
                remaining_energy[note_start_idx:i, freq_idx - 1] = 0

            amplitude = float(np.mean(frames[note_start_idx:i, freq_idx]))
            start_sec = note_start_idx / FPS
            end_sec = i / FPS
            dur_sec = end_sec - start_sec
            pitch_midi = freq_idx + MIDI_OFFSET

            note_events.append({
                "pitch": pitch_midi,
                "onset_sec": round(start_sec, 3),
                "duration_sec": round(dur_sec, 3),
                "confidence": round(amplitude, 3),
                "onset_prob": round(float(onsets[note_start_idx, freq_idx]), 3),
            })

        note_events.sort(key=lambda x: x["onset_sec"])
        return note_events
