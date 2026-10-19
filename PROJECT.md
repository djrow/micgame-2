# Project: V2 Polyphonic Microphone Rhythm Game (micgame-2)

## Architecture
The V2 architecture completely decouples audio playback, microphone capture, polyphonic pitch inference, sheet music/audio ingestion, and game scoring into dedicated Autoload Singletons and modular services in Godot 4.7.2:
- **Audio Routing**: Two-bus layout (`Master` bus index 0 unmuted at 0.0 dB; `Record` bus index 1 muted with 1.0s `AudioEffectCapture`).
- **Autoload Singletons**:
  - `GameManager`: Central game coordinator, level/scene state machine, permission flow.
  - `AudioManager`: Audio stream loading (supporting packaged `.sample`), `LOOP_FORWARD`, playhead sync with sub-frame interpolation.
  - `AudioCaptureService`: Microphone capture polling, stereo downmix `(L+R)*0.5`, $-46\text{ dB}$ ($RMS < 0.005$) noise gating with clock sync, bus 0 mute protection.
  - `InferenceService`: Multi-tier polymorphic inference engine (`IAudioPitchModel`), managing Tier 1 (Native ONNX GDExtension), Tier 2 (Python WebSocket), Tier 3 (Pure GDScript Goertzel/DSP), Tier 4 (Mock).
  - `ScoringService`: Polyphonic chord matching, timing windows (Perfect $\le 50$ms, Good $\le 100$ms, Miss $> 100$ms), combo multipliers, sustain re-trigger locking.
- **Visuals & UI**:
  - `GrandStaffHighway`: Two-staff grand staff ($Y=270.0$ to $450.0$, C4=$360.0$, $\Delta Y=9.0\text{ px}$), receptor line at $X=160.0$, harmonic second horizontal offset $\Delta X \ge +15.0\text{ px}$.
  - `ResponsiveHUD`: Container-based layout adapting dynamically to `DisplayServer.get_display_safe_area()`.
  - `PermissionScreen`: Explicit permission gate for mobile before audio initialization.
  - `OscilloscopeView`: Real-time zero-crossing waveform display positioned at $Y=480\dots610$.
- **Ingestion**:
  - `LevelLoader`: Multi-format audio loader (WAV, MP3, OGG) and chart/OMR coordinator.
  - `OMRProcessor`: 2D Summed Area Table (Integral Image) for $O(1)$ staff line and notehead pitch extraction.
- **Verification Harnesses**:
  - Headless Godot runner `tests/test_inference_scoring_runner.gd` with 11 test suites and 95+ assertions.
  - Standalone Python E2E matrix `tests/e2e/run_all_e2e_tests.py` with 250 tests across 5 tiers.

---

## Feature Inventory
| # | Feature | Description | Milestone | Source |
|---|---------|-------------|-----------|--------|
| 1 | F01: Godot Config & Autoloads | `project.godot` with 5 autoloads, 1280x720, sensor_landscape, clean settings | M1 | blueprint §1, §7.1 |
| 2 | F02: Grand Staff Highway | Two-staff highway, scrolling note geometry, receptor line at X=160 | M3 | blueprint §3.1 |
| 3 | F03: Diatonic Note Placement | Exact diatonic Y coordinates (C4=360, dY=9), harmonic second offset (+16px) | M3 | blueprint §3.1, §7.4 |
| 4 | F04: Hit Detection & Scoring Logic | Scoring timing windows (<=50ms Perfect, <=100ms Good, >100ms Miss), combo multipliers | M3 | blueprint §3.3 |
| 5 | F05: Audio Playhead Sync | Sub-frame playhead interpolation, loop safety, no play() in _process | M1 | blueprint §1.2, §7.3 |
| 6 | F06: Bundled Test Pieces | 3 bundled pieces (monophonic, 2-part harmony, polyphonic chordal) | M4 | blueprint §2.3 |
| 7 | F07: Asset Generation Pipeline | Deterministic audio synthesis (additive harmonics, ADSR), chart & score generation | E2E / M4 | blueprint §2.3, §7.2 |
| 8 | F08: Basic Pitch ONNX Model & Fallback | Spotify Basic Pitch model loading, fallback stubbing when binary missing | M2 | blueprint §2.1, §6.1 |
| 9 | F09: Modular Inference Interface | `IAudioPitchModel` polymorphic contract for all 4 inference tiers | M2 | blueprint §2.1, §7.4 |
| 10 | F10: Real-Time Polyphonic Pitch Extraction | Pure GDScript Goertzel/DSP, harmonic suppression, chord detection [60,64,67] | M2 | blueprint §2.1, §7.4 |
| 11 | F11: Microphone Capture & Bus Isolation | Two-bus layout (Bus 0 unmuted, Bus 1 muted with capture), stereo downmix, -46dB gate | M1 | blueprint §1.1, §7.2 |
| 12 | F12: Polyphonic Scoring Matcher | Chord matching, concurrent notes, partial hits, miss expiration | M3 | blueprint §3.3, §7.5 |
| 13 | F13: Sheet Music Image Ingestion | Loading PNG/JPEG scores, binary thresholding, dimension validation | M3 | blueprint §3.2 |
| 14 | F14: Projection Profiling OMR | 2D Integral Image, staff line profile, notehead pitch extraction | M3 | blueprint §3.2 |
| 15 | F15: Audio-Chart Alignment | Ingestion timeline alignment, beat-to-time conversion, calibration offset | M3 | blueprint §3.2 |
| 16 | F16: Standalone Verification & Test Runners | Godot headless runner (86+ assertions) & Python E2E runner (250 tests) | M5 / E2E | blueprint §5 |
| 17 | F17: Android Export Preset | ARM64-v8a target, RECORD_AUDIO permission, GL Compatibility renderer | M1 / M4 | blueprint §6.2 |
| 18 | F18: Windows Export Preset | Windows Desktop x86_64, runnable settings | M1 / M4 | blueprint §6.2 |
| 19 | F19: Headless Project Integrity | Headless execution without display/audio crashes | M1 / M5 | blueprint §5.1 |
| 20 | F20: E2E Test Suite Validation | 5-tier test matrix, 100% passing, exit code 0 | E2E / M5 | blueprint §5.2 |

---

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| E2E | E2E Testing Suite Track | Test infrastructure, 5 tiers (250 tests), synthetic audio generator, fixtures, `TEST_READY.md` | none | DONE (Verified 250/250 E2E tests across 5 tiers, `TEST_READY.md` certified) |
| M1 | Core Architecture & Two-Bus Audio Pipeline | `project.godot`, `default_bus_layout.tres`, `export_presets.cfg`, `onnx_pitch.gdextension`, `GameManager`, `AudioManager`, `AudioCaptureService` | none | DONE (Verified 76/76 unit, 114 stress, 78 py, boot ok) |
| M2 | Multi-Tier Polyphonic Pitch Inference Engine | `InferenceService`, `IAudioPitchModel`, `MockDriver`, `OnnxNativeDriver`, `NativePitchDetector` (pure GDScript DSP), `WebSocketDriver`, Python inference server | M1 | DONE (Verified 119/119 unit, 46/46 dsp, 169/169 routing, 30/30 py, 12/12 audit) |
| M3 | Grand Staff Highway, Level Loader & Polyphonic Scoring | `NoteData`, `NoteRenderer`, `GrandStaffHighway`, `highway.tscn`, `LevelLoader`, `OMRProcessor`, `omr_engine.py`, `ScoringService` | M1 | DONE (Verified 2355 highway checks, 68 runner checks, 146 scoring checks, 7/7 Python OMR pass, Gate PASS) |
| M4 | Responsive HUD, Permission Gate, Oscilloscope & Main Scene | `ResponsiveHUD`, `hud.tscn`, `PermissionScreen`, `permission_screen.tscn`, `OscilloscopeView`, `Main`, `main.tscn`, bundled assets (`assets/`) | M1, M2, M3 | DONE (Verified 130/130 challenger, 99/99 integration, 62/62 telemetry, 632 GDScript assertions pass, Gate PASS) |
| M5 | Final Verification & Integration Acceptance | 100% pass of `tests/test_inference_scoring_runner.gd` (86+ assertions) and `run_all_e2e_tests.py` (250 tests) | E2E, M1..M4 | DONE (Verified 105/105 Godot headless assertions + 250/250 Python E2E tests, Gate PASS) |

---

## Interface Contracts

### AudioCaptureService -> InferenceService
- `signal audio_chunk_ready(samples: PackedFloat32Array)`
- Format: 22,050 Hz, mono (stereo downmixed via $(L+R)*0.5$), float32 normalized $[-1.0, 1.0]$.
- Silence Policy: If $RMS < 0.005$ ($-46\text{ dB}$), zero-filled float array is emitted to maintain circular sample clock.

### InferenceService -> ScoringService / Highway
- `signal pitch_detected(detected_pitches: Array[int], confidence_map: Dictionary)`
- `signal onset_detected(onset_pitches: Array[int])`
- Pitches: MIDI integers (e.g., $60 = C_4$, $64 = E_4$, $67 = G_4$).

### ScoringService <-> GameManager / Highway
- `func set_active_chart(notes: Array[NoteData]) -> void`
- `func update_playhead(song_time: float) -> void`
- `func process_detected_pitches(pitches: Array[int], onsets: Array[int], current_time: float) -> void`
- `signal note_scored(note: NoteData, rating: String, points: int)`
- Ratings: `"PERFECT"` ($\le 0.050\text{s}$), `"GOOD"` ($\le 0.100\text{s}$), `"MISS"` ($> 0.100\text{s}$).

### AudioManager -> ScoringService / Highway
- `func get_song_position() -> float`
- Sub-frame interpolation: `get_playback_position() + get_time_since_last_mix() - get_output_latency() + audio_offset`.

---

## Code Layout
```
c:\Users\david\Documents\micgame-2\
├── project.godot
├── default_bus_layout.tres
├── export_presets.cfg
├── onnx_pitch.gdextension
├── assets/
│   ├── audio/
│   ├── charts/
│   ├── scores/
│   ├── models/
│   └── test_pieces/
├── scripts/
│   ├── game_manager.gd
│   ├── audio_manager.gd
│   ├── audio_capture_service.gd
│   ├── inference_service.gd
│   ├── scoring_service.gd
│   ├── level_loader.gd
│   ├── omr_processor.gd
│   ├── grand_staff_highway.gd
│   ├── note_data.gd
│   ├── note_renderer.gd
│   ├── responsive_hud.gd
│   ├── permission_screen.gd
│   ├── oscilloscope_view.gd
│   ├── main.gd
│   └── inference/
│       ├── audio_pitch_model.gd
│       ├── mock_driver.gd
│       ├── onnx_native_driver.gd
│       ├── native_pitch_detector.gd
│       └── websocket_driver.gd
├── scenes/
│   ├── main.tscn
│   ├── highway.tscn
│   ├── hud.tscn
│   └── permission_screen.tscn
├── python/
│   ├── inference_server.py
│   ├── basic_pitch_onnx.py
│   └── omr_engine.py
├── native/
│   ├── onnx_pitch_gdextension.c
│   └── *.h
├── tools/
│   └── generate_test_assets.py
└── tests/
    ├── test_inference_scoring_runner.gd
    ├── test_scoring_runner.gd
    ├── test_omr_runner.gd
    └── e2e/
        ├── run_all_e2e_tests.py
        ├── test_tier1_features.py
        ├── test_tier2_boundaries.py
        ├── test_tier3_combinations.py
        ├── test_tier4_scenarios.py
        └── test_tier5_adversarial.py
```
