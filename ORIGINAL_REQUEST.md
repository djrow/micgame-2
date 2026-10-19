# Original User Request

## Initial Request — 2026-10-17T16:54:52Z

Build the V2 Polyphonic Microphone Rhythm Game from the ground up in Godot 4 following `ground_up_recreation_blueprint.md`, focusing on the complete Godot 4 project, GDScript polyphonic DSP engine, Python WebSocket inference server, OMR sheet music digitizer, mobile-safe UI, and automated verification suites (gracefully stubbing or mocking compiled native C/ONNX binaries if native build toolchains are unavailable).

Working directory: c:\Users\david\Documents\micgame-2
Integrity mode: development

Reference material: `c:\Users\david\Documents\micgame-2\ground_up_recreation_blueprint.md`

## Requirements

### R1. V2 Autoload Architecture & Two-Bus Audio Pipeline
Implement the decoupled V2 singleton architecture (`GameManager`, `AudioManager`, `AudioCaptureService`, `InferenceService`, `ScoringService`) and `default_bus_layout.tres` with strict two-bus isolation: Bus 0 (`Master`, unmuted, `0.0 dB`) for accompaniment/SFX and Bus 1 (`Record`, muted, with a 1.0s `AudioEffectCapture` ring buffer) for microphone capture. Ensure `AudioCaptureService` never mutes bus index 0, `AudioManager` loads packaged and runtime audio streams via `ResourceLoader` with `FileAccess` fallback and `AudioStreamWAV.LOOP_FORWARD`, never calls `play()` inside `_process()`, and provides sub-frame interpolated playhead timing.

### R2. Multi-Tier Polyphonic Pitch Inference Engine
Implement the modular polyphonic pitch detection pipeline (`InferenceService`) with stereo-to-mono downmixing and `-46 dB` (`RMS < 0.005`) gating that maintains time-clock continuity during silence. Support all four modular tiers:
- **Tier 1 (Native GDExtension / ONNX Runtime)**: Provide the `onnx_pitch.gdextension` configuration, C source/binding interface for zero-copy buffer passing, and graceful fallback/stubbing when compiled `.dll`/`.so`/`.dylib` binaries or ONNX toolchains are not present in the environment.
- **Tier 2 (WebSocket Driver)**: Provide the local Python inference server (`python/inference_server.py` on `ws://127.0.0.1:8765`) and Godot WebSocket client driver.
- **Tier 3 (Pure GDScript Native Polyphonic DSP)**: Implement a working real-time polyphonic pitch detector in pure GDScript using Spectral Centroid, Autocorrelation, and Harmonic Product Spectrum (HPS) capable of detecting concurrent chord pitches (e.g., C Major Triad MIDI `[60, 64, 67]`).
- **Tier 4 (Mock Driver)**: Provide a deterministic fixture generator for automated test verification.

### R3. Grand Staff Highway, Level Loader, OMR Engine & Polyphonic Scoring
Implement `GrandStaffHighway` rendering the two-staff piano Grand Staff (`Y = 270.0` F5 to `Y = 450.0` G2, Middle C4 ledger/receptor line at `Y = 360.0`) with $\Delta Y = 9.0\text{ px}$ per diatonic step and $+16\text{ px}$ horizontal notehead offset for harmonic seconds. Implement `LevelLoader` supporting WAV/OGG/MP3 audio parsing and Optical Music Recognition (OMR) sheet music image (`PNG`/`JPG`) and JSON chart ingestion, plus synthetic sample songs/fixtures. Implement `ScoringService` with polyphonic chord matching across PERFECT ($\le 50\text{ ms}$, $+100 \times \text{multiplier}$), GOOD ($\le 100\text{ ms}$, $+50 \times \text{multiplier}$), and MISS ($> 100\text{ ms}$, combo reset) windows, including sustain re-trigger locking until note duration expires.

### R4. Mobile-Safe Responsive HUD, Permission Gate & Cross-Platform Configs
Implement `ResponsiveHUD` using Godot container hierarchies (`MarginContainer`, `HBoxContainer`, `VBoxContainer`, `PRESET_FULL_RECT`) dynamically respecting `DisplayServer.get_display_safe_area()`, an explicit mobile `PermissionScreen` that gates playback until `RECORD_AUDIO` permission is resolved and the user starts the game, and the real-time zero-crossing `OscilloscopeView` + Diagnostic Dock positioned safely in `Y = 480..610`. Configure `project.godot` (`1280x720`, `canvas_items`, `aspect="keep"`, `sensor_landscape`) and `export_presets.cfg` for Windows, Android (`arm64-v8a`, `record_audio`, `modify_audio_settings`, `gl_compatibility`), and iOS (`app_store_team_id="0000000000"`, `export_project_only=true`, Files/iTunes sharing enabled).

### R5. Automated Verification Suite
Build the complete verification suite referenced in Section 8 of the blueprint, along with any necessary test fixtures:
- **Godot Test Runner** (`tests/test_inference_scoring_runner.gd`): 86+ assertions covering Record bus lifecycle and isolation, stereo downmix, `-46 dB` RMS gating, polyphonic chord matching, sustain edge filtering, diatonic staff geometry & second-interval offsets, oscilloscope ring buffer, ONNX/fallback inference routing, and custom song OMR ingestion.
- **Python E2E Quality Matrix** (`tests/e2e/run_all_e2e_tests.py`): 250 automated tests across the 5 tiers (feature coverage, boundary conditions, cross-feature combinations, real-world scenarios, and adversarial inputs) verifying the codebase, configurations, DSP/OMR logic, WebSocket server, and Godot project integrity.

## Acceptance Criteria

### Audio & Bus Architecture
- [ ] `default_bus_layout.tres` explicitly serializes Bus 0 as `Master` (`mute = false`, `volume_db = 0.0`) and Bus 1 as `Record` (`mute = true`, `AudioEffectCapture` with `buffer_length = 1.0`), and `AudioCaptureService` guards against muting bus index 0.
- [ ] `AudioManager` loads audio streams via `ResourceLoader.exists()` / `has_cached()` with runtime `FileAccess` fallback, sets `LOOP_FORWARD` on `AudioStreamWAV`, never calls `play()` in `_process()`, and computes interpolated playhead position using `get_playback_position() + get_time_since_last_mix() - get_output_latency() + audio_offset`.

### Polyphonic Inference, Highway Geometry & Scoring
- [ ] `InferenceService` downmixes stereo frames via `(L + R) * 0.5`, gates silence below `RMS < 0.005` (`-46 dB`) by pushing silence frames to preserve clock sync, and routes seamlessly across the 4 model tiers (with pure GDScript DSP accurately detecting synthetic single notes and chords such as MIDI `[60, 64, 67]`).
- [ ] `GrandStaffHighway` places notes at exact diatonic Y coordinates ($\Delta Y = 9.0\text{ px}$ per step, C4 = `360.0`) and offsets adjacent harmonic seconds horizontally by $+16\text{ px}$.
- [ ] `ScoringService` evaluates polyphonic chords within $\pm 50\text{ ms}$ (PERFECT), $\pm 100\text{ ms}$ (GOOD), and $> 100\text{ ms}$ (MISS) windows and locks `is_hit` across sustain duration to prevent re-triggering.

### Mobile Safe Area, Export Configs & Test Suites
- [ ] `project.godot`, `onnx_pitch.gdextension`, and `export_presets.cfg` exist and contain all required Windows, Android, and iOS settings from Sections 5 and 6 of `ground_up_recreation_blueprint.md`.
- [ ] `tests/test_inference_scoring_runner.gd` contains at least 86 assertions across all required subsystems (and passes 100% if a Godot 4 binary is available on `PATH`, or is structurally validated by the E2E suite if Godot is not installed).
- [ ] `python tests/e2e/run_all_e2e_tests.py` executes 250 tests across 5 tiers and exits with code 0 and a 100% pass rate (250/250 passing).


## Follow-up — 2026-10-18T01:08:46Z

Resume and complete the V2 Polyphonic Microphone Rhythm Game in Godot 4 following `ground_up_recreation_blueprint.md`, focusing on the complete Godot 4 project, GDScript polyphonic DSP engine, Python WebSocket inference server, OMR sheet music digitizer, mobile-safe UI, and automated verification suites (gracefully stubbing or mocking compiled native C/ONNX binaries if native build toolchains are unavailable).

Working directory: c:\Users\david\Documents\micgame-2
Integrity mode: development

Reference material:
- `c:\Users\david\Documents\micgame-2\ground_up_recreation_blueprint.md`
- `c:\Users\david\Documents\micgame-2\PROJECT.md`
- `c:\Users\david\Documents\micgame-2\TEST_INFRA.md`
- `c:\Users\david\Documents\micgame-2\.agents\teamwork\orchestrator\BRIEFING.md`

## Resume Context (Prior Run Interrupted by System Shutdown)
- **Phase 0 (Survey & Planning)**: COMPLETED (`PROJECT.md`, `TEST_INFRA.md`, `ORIGINAL_REQUEST.md` on disk).
- **Milestone M1 (Core Architecture & Two-Bus Audio Pipeline)**: COMPLETED & GATE PASSED (all 114 GDScript and 78 Python stress assertions verified). Do not redo M1 unless regression tests fail.
- **Milestone M2 (Multi-Tier Polyphonic Pitch Inference Engine)**: COMPLETED & GATE PASSED (119/119 inference checks, 46/46 adversarial DSP checks, 169/169 multi-tier routing checks verified). Do not redo M2 unless regression tests fail.
- **Milestone M3 (Grand Staff Highway, Level Loader, OMR Engine & Polyphonic Scoring)**: IN PROGRESS — `m3_explorer_1`, `m3_explorer_2`, and `m3_explorer_3` completed their handoffs in `.agents\teamwork\m3_explorer_*`, and `m3_worker` had written `note_data.gd`, `note_renderer.gd`, `grand_staff_highway.gd`, `highway.tscn`, `level_loader.gd`, `omr_processor.gd`, `omr_engine.py`, `scoring_service.gd`, and `test_scoring_runner.gd` right as the machine shut down. Inspect and verify the M3 files on disk, complete M3 verification and Quality Gate, and then proceed to **Milestone M4**, **Milestone M5 / E2E Track**, and the final **Victory Audit**.

## Requirements

### R1. V2 Autoload Architecture & Two-Bus Audio Pipeline
Implement the decoupled V2 singleton architecture (`GameManager`, `AudioManager`, `AudioCaptureService`, `InferenceService`, `ScoringService`) and `default_bus_layout.tres` with strict two-bus isolation: Bus 0 (`Master`, unmuted, `0.0 dB`) for accompaniment/SFX and Bus 1 (`Record`, muted, with a 1.0s `AudioEffectCapture` ring buffer) for microphone capture. Ensure `AudioCaptureService` never mutes bus index 0, `AudioManager` loads packaged and runtime audio streams via `ResourceLoader` with `FileAccess` fallback and `AudioStreamWAV.LOOP_FORWARD`, never calls `play()` inside `_process()`, and provides sub-frame interpolated playhead timing.

### R2. Multi-Tier Polyphonic Pitch Inference Engine
Implement the modular polyphonic pitch detection pipeline (`InferenceService`) with stereo-to-mono downmixing and `-46 dB` (`RMS < 0.005`) gating that maintains time-clock continuity during silence. Support all four modular tiers:
- **Tier 1 (Native GDExtension / ONNX Runtime)**: Provide the `onnx_pitch.gdextension` configuration, C source/binding interface for zero-copy buffer passing, and graceful fallback/stubbing when compiled `.dll`/`.so`/`.dylib` binaries or ONNX toolchains are not present in the environment.
- **Tier 2 (WebSocket Driver)**: Provide the local Python inference server (`python/inference_server.py` on `ws://127.0.0.1:8765`) and Godot WebSocket client driver.
- **Tier 3 (Pure GDScript Native Polyphonic DSP)**: Implement a working real-time polyphonic pitch detector in pure GDScript using Spectral Centroid, Autocorrelation, and Harmonic Product Spectrum (HPS) / Goertzel capable of detecting concurrent chord pitches (e.g., C Major Triad MIDI `[60, 64, 67]`).
- **Tier 4 (Mock Driver)**: Provide a deterministic fixture generator for automated test verification.

### R3. Grand Staff Highway, Level Loader, OMR Engine & Polyphonic Scoring
Implement `GrandStaffHighway` rendering the two-staff piano Grand Staff (`Y = 270.0` F5 to `Y = 450.0` G2, Middle C4 ledger/receptor line at `Y = 360.0`) with $\Delta Y = 9.0\text{ px}$ per diatonic step and $+16\text{ px}$ horizontal notehead offset for harmonic seconds. Implement `LevelLoader` supporting WAV/OGG/MP3 audio parsing and Optical Music Recognition (OMR) sheet music image (`PNG`/`JPG`) and JSON chart ingestion, plus synthetic sample songs/fixtures. Implement `ScoringService` with polyphonic chord matching across PERFECT ($\le 50\text{ ms}$, $+100 \times \text{multiplier}$), GOOD ($\le 100\text{ ms}$, $+50 \times \text{multiplier}$), and MISS ($> 100\text{ ms}$, combo reset) windows, including sustain re-trigger locking until note duration expires.

### R4. Mobile-Safe Responsive HUD, Permission Gate & Cross-Platform Configs
Implement `ResponsiveHUD` using Godot container hierarchies (`MarginContainer`, `HBoxContainer`, `VBoxContainer`, `PRESET_FULL_RECT`) dynamically respecting `DisplayServer.get_display_safe_area()`, an explicit mobile `PermissionScreen` that gates playback until `RECORD_AUDIO` permission is resolved and the user starts the game, and the real-time zero-crossing `OscilloscopeView` + Diagnostic Dock positioned safely in `Y = 480..610`. Configure `project.godot` (`1280x720`, `canvas_items`, `aspect="keep"`, `sensor_landscape`) and `export_presets.cfg` for Windows, Android (`arm64-v8a`, `record_audio`, `modify_audio_settings`, `gl_compatibility`), and iOS (`app_store_team_id="0000000000"`, `export_project_only=true`, Files/iTunes sharing enabled).

### R5. Automated Verification Suite
Build the complete verification suite referenced in Section 8 of the blueprint, along with any necessary test fixtures:
- **Godot Test Runner** (`tests/test_inference_scoring_runner.gd`): 86+ assertions covering Record bus lifecycle and isolation, stereo downmix, `-46 dB` RMS gating, polyphonic chord matching, sustain edge filtering, diatonic staff geometry & second-interval offsets, oscilloscope ring buffer, ONNX/fallback inference routing, and custom song OMR ingestion.
- **Python E2E Quality Matrix** (`tests/e2e/run_all_e2e_tests.py`): 250 automated tests across the 5 tiers (feature coverage, boundary conditions, cross-feature combinations, real-world scenarios, and adversarial inputs) verifying the codebase, configurations, DSP/OMR logic, WebSocket server, and Godot project integrity.

## Acceptance Criteria

### Audio & Bus Architecture
- [ ] `default_bus_layout.tres` explicitly serializes Bus 0 as `Master` (`mute = false`, `volume_db = 0.0`) and Bus 1 as `Record` (`mute = true`, `AudioEffectCapture` with `buffer_length = 1.0`), and `AudioCaptureService` guards against muting bus index 0.
- [ ] `AudioManager` loads audio streams via `ResourceLoader.exists()` / `has_cached()` with runtime `FileAccess` fallback, sets `LOOP_FORWARD` on `AudioStreamWAV`, never calls `play()` in `_process()`, and computes interpolated playhead position using `get_playback_position() + get_time_since_last_mix() - get_output_latency() + audio_offset`.

### Polyphonic Inference, Highway Geometry & Scoring
- [ ] `InferenceService` downmixes stereo frames via `(L + R) * 0.5`, gates silence below `RMS < 0.005` (`-46 dB`) by pushing silence frames to preserve clock sync, and routes seamlessly across the 4 model tiers (with pure GDScript DSP accurately detecting synthetic single notes and chords such as MIDI `[60, 64, 67]`).
- [ ] `GrandStaffHighway` places notes at exact diatonic Y coordinates ($\Delta Y = 9.0\text{ px}$ per step, C4 = `360.0`) and offsets adjacent harmonic seconds horizontally by $+16\text{ px}$.
- [ ] `ScoringService` evaluates polyphonic chords within $\pm 50\text{ ms}$ (PERFECT), $\pm 100\text{ ms}$ (GOOD), and $> 100\text{ ms}$ (MISS) windows and locks `is_hit` across sustain duration to prevent re-triggering.

### Mobile Safe Area, Export Configs & Test Suites
- [ ] `project.godot`, `onnx_pitch.gdextension`, and `export_presets.cfg` exist and contain all required Windows, Android, and iOS settings from Sections 5 and 6 of `ground_up_recreation_blueprint.md`.
- [ ] `tests/test_inference_scoring_runner.gd` contains at least 86 assertions across all required subsystems (and passes 100% if a Godot 4 binary is available on `PATH`, or is structurally validated by the E2E suite if Godot is not installed).
- [ ] `python tests/e2e/run_all_e2e_tests.py` executes 250 tests across 5 tiers and exits with code 0 and a 100% pass rate (250/250 passing).
