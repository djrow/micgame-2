# E2E Test Infra: V2 Polyphonic Microphone Rhythm Game (micgame-2)

## Test Philosophy
- Opaque-box, requirement-driven. Derived strictly from `ORIGINAL_REQUEST.md` and `ground_up_recreation_blueprint.md`.
- No internal module coupling; interacts with the project via configuration files, exported presets, audio processing contracts, scoring equations, and headless Godot execution.
- Methodology: Category-Partition + Boundary Value Analysis + Pairwise Combinatorial Testing + Real-World Workload Testing + Adversarial Hardening.

## Feature Inventory & Test Matrix
| # | Feature | Source (requirement) | Tier 1 (Coverage) | Tier 2 (Boundary) | Tier 3 (Cross) |
|---|---------|---------------------|:-----------------:|:-----------------:|:--------------:|
| F01 | Godot Config & Autoloads | ORIGINAL_REQUEST §R1 | 5 | 5 | ✓ |
| F02 | Grand Staff Highway Geometry | ORIGINAL_REQUEST §R3 | 5 | 5 | ✓ |
| F03 | Diatonic Note Placement | ORIGINAL_REQUEST §R3 | 5 | 5 | ✓ |
| F04 | Hit Detection & Scoring Logic | ORIGINAL_REQUEST §R3 | 5 | 5 | ✓ |
| F05 | Audio Playhead Synchronization | ORIGINAL_REQUEST §R1 | 5 | 5 | ✓ |
| F06 | Bundled Test Pieces | ORIGINAL_REQUEST §R3 | 5 | 5 | ✓ |
| F07 | Asset Generation Pipeline | ORIGINAL_REQUEST §R3 | 5 | 5 | ✓ |
| F08 | Basic Pitch ONNX Model / Fallback | ORIGINAL_REQUEST §R2 | 5 | 5 | ✓ |
| F09 | Modular Inference Interface | ORIGINAL_REQUEST §R2 | 5 | 5 | ✓ |
| F10 | Polyphonic Pitch Extraction (DSP) | ORIGINAL_REQUEST §R2 | 5 | 5 | ✓ |
| F11 | Microphone Capture & Two-Bus Isolation | ORIGINAL_REQUEST §R1 | 5 | 5 | ✓ |
| F12 | Polyphonic Scoring Matcher | ORIGINAL_REQUEST §R3 | 5 | 5 | ✓ |
| F13 | Sheet Music Image Ingestion | ORIGINAL_REQUEST §R3 | 5 | 5 | ✓ |
| F14 | Projection Profiling OMR | ORIGINAL_REQUEST §R3 | 5 | 5 | ✓ |
| F15 | Audio-Chart Alignment | ORIGINAL_REQUEST §R3 | 5 | 5 | ✓ |
| F16 | Standalone Verification Runners | ORIGINAL_REQUEST §R5 | 5 | 5 | ✓ |
| F17 | Android (Pixel 7a) Export Preset | ORIGINAL_REQUEST §R4 | 5 | 5 | ✓ |
| F18 | Windows Desktop Export Preset | ORIGINAL_REQUEST §R4 | 5 | 5 | ✓ |
| F19 | Headless Project Validation | ORIGINAL_REQUEST §R5 | 5 | 5 | ✓ |
| F20 | E2E Test Suite Validation | ORIGINAL_REQUEST §R5 | 5 | 5 | ✓ |
| **Total** | 20 Features | | **100 tests** | **100 tests** | **20 tests** |

## Test Architecture
- **Primary E2E Runner**: `tests/e2e/run_all_e2e_tests.py`
  - Invocation: `python tests/e2e/run_all_e2e_tests.py`
  - Pass/Fail Semantics: 250/250 tests must pass with 0 errors, 0 failures, exiting with code 0.
- **Headless Godot Runner**: `tests/test_inference_scoring_runner.gd`
  - Invocation: `& "C:\Users\david\Downloads\Godot_v4.7.2-stable_win64_console.exe" --headless --path . -s tests/test_inference_scoring_runner.gd`
  - Pass/Fail Semantics: 86+ (target 95–105) assertions pass, exiting with code 0 via `quit(0)`.
- **Directory Layout**:
  - `tests/e2e/run_all_e2e_tests.py` — Orchestrator & reporter
  - `tests/e2e/test_tier1_features.py` — 100 feature coverage tests
  - `tests/e2e/test_tier2_boundaries.py` — 100 boundary & corner tests
  - `tests/e2e/test_tier3_combinations.py` — 20 cross-feature tests
  - `tests/e2e/test_tier4_scenarios.py` — 10 full user journey scenarios
  - `tests/e2e/test_tier5_adversarial.py` — 20 adversarial stress & precision tests

## Real-World Application Scenarios (Tier 4)
| # | Scenario | Features Exercised | Complexity |
|---|----------|--------------------|------------|
| S01 | Clean Install & First Startup | F01, F11, F17, F18, F19 | Low |
| S02 | Full Playthrough: Ode to Joy (Monophonic) | F02, F03, F04, F05, F06, F10 | Medium |
| S03 | Full Playthrough: Bach Minuet (2-Part Harmony) | F02, F03, F04, F05, F06, F12 | High |
| S04 | Full Playthrough: Cadence Triads (Polyphonic Chords) | F02, F03, F04, F08, F10, F12 | High |
| S05 | Custom Sheet Music Import & Digitization (OMR) | F13, F14, F15, F02 | High |
| S06 | Player Mistakes & Recovery (Partial Chords, Misses) | F04, F12, F05 | Medium |
| S07 | Noisy Room Acoustic Calibration (-46 dB Gate) | F11, F10, F04 | Medium |
| S08 | Low-Latency Desktop Inference Session | F08, F09, F10, F05 | High |
| S09 | Mobile Export Build & Packaging Check | F01, F17, F18 | Medium |
| S10 | Full CI Headless Verification Cycle | F16, F19, F20 | High |

## Coverage Thresholds
- Tier 1: 100 tests (5 per feature across 20 features)
- Tier 2: 100 tests (5 per feature across 20 features)
- Tier 3: 20 tests (pairwise and multi-feature combinations)
- Tier 4: 10 realistic application scenarios
- Tier 5: 20 adversarial tests
- **Total: 250 tests, 100% passing rate required**
