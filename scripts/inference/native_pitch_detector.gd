class_name NativePitchDetector
extends "res://scripts/inference/audio_pitch_model.gd"

## Pure GDScript real-time polyphonic pitch and onset detector (Tier 3 Inference Engine).
## Implements Goertzel algorithm over MIDI notes 36 (C2) to 84 (C6), 2x downsampling,
## Generalized Hamming windowing (alpha=0.54), DC blocking via mean subtraction,
## harmonic suppression, and chord extraction conforming to AudioPitchModel.

const MIN_MIDI: int = 36 # C2 (~65.41 Hz)
const MAX_MIDI: int = 84 # C6 (~1046.50 Hz)
const NUM_BINS: int = MAX_MIDI - MIN_MIDI + 1 # 49 bins
const WINDOW_SIZE: int = 2048
const DEFAULT_EVAL_HOP: int = 1024 # ~21ms at 48kHz, ~46ms at 22.05kHz

var sample_rate: float = 48000.0
var eval_hop_samples: int = DEFAULT_EVAL_HOP
var ring_buffer: PackedFloat32Array = PackedFloat32Array()

# Precomputed DSP Tables
var _hann_window: PackedFloat32Array = PackedFloat32Array()
var _midi_freqs: PackedFloat32Array = PackedFloat32Array()
var _goertzel_coeffs: PackedFloat32Array = PackedFloat32Array()

# Zero-Allocation Reusable Scratch Buffers
var _windowed_buffer: PackedFloat32Array = PackedFloat32Array()
var _raw_mag: PackedFloat32Array = PackedFloat32Array()
var _norm_mag: PackedFloat32Array = PackedFloat32Array()
var _suppressed_mag: PackedFloat32Array = PackedFloat32Array()
var _prev_energies: PackedFloat32Array = PackedFloat32Array()
var _last_onset_sec: Dictionary = {}

# Public State & Telemetry
var detected_pitches: Array[int] = []
var recent_onsets: Array[int] = []
var confidence_map: Dictionary = {}
var last_latency_ms: float = 0.0
var inference_count: int = 0
var _samples_since_eval: int = 0
var _candidate_streak_pitches: Array[int] = []
var _emitted_active_pitches: Array[int] = []

# Fine-tunable Instrument & Player DSP Parameters
var attack_crest_min: float = 3.8
var sustain_crest_min: float = 2.8
var attack_mag_floor: float = 0.050
var sustain_mag_floor: float = 0.032
var harmonic_2nd_suppression: float = 0.55
var harmonic_3rd_suppression: float = 0.40
var harmonic_4th_suppression: float = 0.45

func apply_instrument_profile(d: Dictionary) -> void:
	if d.is_empty():
		return
	attack_crest_min = clampf(float(d.get("dsp_attack_crest_min", attack_crest_min)), 2.2, 6.0)
	sustain_crest_min = clampf(float(d.get("dsp_sustain_crest_min", sustain_crest_min)), 1.8, 5.0)
	attack_mag_floor = clampf(float(d.get("dsp_attack_mag_floor", attack_mag_floor)), 0.020, 0.150)
	sustain_mag_floor = clampf(float(d.get("dsp_sustain_mag_floor", sustain_mag_floor)), 0.015, 0.120)
	harmonic_2nd_suppression = clampf(float(d.get("harmonic_2nd_suppression", harmonic_2nd_suppression)), 0.20, 0.85)
	harmonic_3rd_suppression = clampf(float(d.get("harmonic_3rd_suppression", harmonic_3rd_suppression)), 0.15, 0.75)
	harmonic_4th_suppression = clampf(float(d.get("harmonic_4th_suppression", harmonic_4th_suppression)), 0.15, 0.75)

func _init(sr: float = 48000.0) -> void:
	sample_rate = maxf(8000.0, sr)
	ring_buffer.resize(WINDOW_SIZE)
	ring_buffer.fill(0.0)

	_hann_window.resize(WINDOW_SIZE)
	_windowed_buffer.resize(WINDOW_SIZE)
	# Generalized Hamming window (alpha=0.54) narrows -6dB bandwidth to 42.4 Hz,
	# resolving low triads (A Minor [57,60,64], F Major [53,57,60]) at 48 kHz.
	for i in range(WINDOW_SIZE):
		_hann_window[i] = 0.54 - 0.46 * cos(TAU * float(i) / float(WINDOW_SIZE - 1))

	_midi_freqs.resize(NUM_BINS)
	_goertzel_coeffs.resize(NUM_BINS)
	_raw_mag.resize(NUM_BINS)
	_norm_mag.resize(NUM_BINS)
	_suppressed_mag.resize(NUM_BINS)
	_prev_energies.resize(NUM_BINS)
	_prev_energies.fill(0.0)

	for b in range(NUM_BINS):
		var midi: int = MIN_MIDI + b
		_midi_freqs[b] = 440.0 * pow(2.0, float(midi - 69) / 12.0)
		_last_onset_sec[midi] = -999.0

	_update_coefficients()
	model_ready.emit()

func _update_coefficients() -> void:
	var step: int = 2 if sample_rate >= 32000.0 else 1
	var eff_sr: float = sample_rate / float(step)
	for b in range(NUM_BINS):
		var omega: float = TAU * _midi_freqs[b] / eff_sr
		_goertzel_coeffs[b] = 2.0 * cos(omega)

func is_model_ready() -> bool:
	return true

func reset() -> void:
	ring_buffer.fill(0.0)
	_prev_energies.fill(0.0)
	detected_pitches.clear()
	recent_onsets.clear()
	confidence_map.clear()
	_candidate_streak_pitches.clear()
	_emitted_active_pitches.clear()
	_samples_since_eval = 0
	for k in _last_onset_sec.keys():
		_last_onset_sec[k] = -999.0

func push_audio_samples(samples: PackedFloat32Array, sr: float = -1.0) -> void:
	if sr > 0.0 and absf(sr - sample_rate) > 1.0:
		sample_rate = sr
		_update_coefficients()

	var n: int = samples.size()
	if n == 0:
		return

	var is_full_window_injection: bool = (n >= WINDOW_SIZE)
	if is_full_window_injection:
		for i in range(WINDOW_SIZE):
			var v: float = samples[n - WINDOW_SIZE + i]
			ring_buffer[i] = 0.0 if (is_nan(v) or is_inf(v)) else v
	else:
		var keep: int = WINDOW_SIZE - n
		for i in range(keep):
			ring_buffer[i] = ring_buffer[i + n]
		for i in range(n):
			var v: float = samples[i]
			ring_buffer[keep + i] = 0.0 if (is_nan(v) or is_inf(v)) else v

	_samples_since_eval += n
	if _samples_since_eval >= eval_hop_samples:
		_samples_since_eval = 0
		_evaluate_window( not is_full_window_injection )

func get_detected_pitches() -> Array[int]:
	return detected_pitches.duplicate()

func get_recent_onsets(clear: bool = false) -> Array[int]:
	var res: Array[int] = recent_onsets.duplicate()
	if clear:
		recent_onsets.clear()
	return res

func pop_recent_onsets() -> Array[int]:
	return get_recent_onsets(true)

func get_confidence_map() -> Dictionary:
	return confidence_map.duplicate()

func get_last_latency_ms() -> float:
	return last_latency_ms

func poll(_delta: float = 0.0) -> void:
	pass

func _clear_on_silence_or_noise(t0: int) -> void:
	detected_pitches.clear()
	recent_onsets.clear()
	confidence_map.clear()
	_candidate_streak_pitches.clear()
	_emitted_active_pitches.clear()
	_prev_energies.fill(0.0)
	pitches_detected.emit(detected_pitches)
	last_latency_ms = float(Time.get_ticks_usec() - t0) / 1000.0

func _evaluate_window(require_streak: bool = false) -> void:
	var t0: int = Time.get_ticks_usec()
	inference_count += 1

	# DC Bias elimination: compute window mean and remove DC offset
	var sum_s: float = 0.0
	for i in range(WINDOW_SIZE):
		sum_s += ring_buffer[i]
	var mean_s: float = sum_s / float(WINDOW_SIZE)

	var sum_sq: float = 0.0
	var peak: float = 0.0
	for i in range(WINDOW_SIZE):
		var s: float = ring_buffer[i] - mean_s
		sum_sq += s * s
		var a: float = absf(s)
		if a > peak:
			peak = a

	var is_sustaining: bool = not _emitted_active_pitches.is_empty()
	var min_rms: float = 0.004 if is_sustaining else 0.008
	var min_peak: float = 0.007 if is_sustaining else 0.014

	var rms: float = sqrt(sum_sq / float(WINDOW_SIZE))
	if rms < min_rms or peak < min_peak:
		_clear_on_silence_or_noise(t0)
		return

	var inv_peak: float = 1.0 / maxf(peak, 0.01)
	for i in range(WINDOW_SIZE):
		_windowed_buffer[i] = (ring_buffer[i] - mean_s) * inv_peak * _hann_window[i]

	var step: int = 2 if sample_rate >= 32000.0 else 1
	var n_pts: int = WINDOW_SIZE / step
	var inv_n_pts: float = 1.0 / float(n_pts)

	for b in range(NUM_BINS):
		var coeff: float = _goertzel_coeffs[b]
		var s1: float = 0.0
		var s2: float = 0.0
		var idx: int = 0
		for _k in range(n_pts):
			var s0: float = _windowed_buffer[idx] + coeff * s1 - s2
			s2 = s1
			s1 = s0
			idx += step
		var power: float = s1 * s1 + s2 * s2 - coeff * s1 * s2
		_raw_mag[b] = sqrt(maxf(0.0, power)) * inv_n_pts

	var max_mag: float = 0.0001
	var sum_mag: float = 0.0
	for b in range(NUM_BINS):
		var m: float = _raw_mag[b]
		sum_mag += m
		if m > max_mag:
			max_mag = m

	# Spectral Crest Factor & Absolute Magnitude Floor with sustain hysteresis:
	# Strict thresholds to open from silence/noise; relaxed thresholds to hold an active sustained note.
	var mean_mag: float = sum_mag / float(NUM_BINS)
	var spectral_crest: float = max_mag / maxf(mean_mag, 0.00001)
	var min_mag_floor: float = sustain_mag_floor if is_sustaining else attack_mag_floor
	var min_crest: float = sustain_crest_min if is_sustaining else attack_crest_min
	if max_mag < min_mag_floor or spectral_crest < min_crest:
		_clear_on_silence_or_noise(t0)
		return

	var inv_max: float = 1.0 / max_mag
	var broadband_bins: int = 0
	for b in range(NUM_BINS):
		_norm_mag[b] = _raw_mag[b] * inv_max
		_suppressed_mag[b] = _norm_mag[b]
		if _norm_mag[b] >= 0.38:
			broadband_bins += 1

	# Reject noisy/percussive spectra where >13 of 49 bins exceed 38% of peak magnitude
	if broadband_bins > 13:
		_clear_on_silence_or_noise(t0)
		return

	for b in range(NUM_BINS):
		if _norm_mag[b] >= 0.45:
			if b + 12 < NUM_BINS:
				_suppressed_mag[b + 12] = maxf(0.0, _suppressed_mag[b + 12] - _norm_mag[b] * harmonic_2nd_suppression)
			if b + 19 < NUM_BINS:
				_suppressed_mag[b + 19] = maxf(0.0, _suppressed_mag[b + 19] - _norm_mag[b] * harmonic_3rd_suppression)
			if b + 24 < NUM_BINS:
				_suppressed_mag[b + 24] = maxf(0.0, _suppressed_mag[b + 24] - _norm_mag[b] * harmonic_4th_suppression)

	var min_val: float = 0.38 if is_sustaining else 0.48
	var candidates: Array[Dictionary] = []
	for b in range(NUM_BINS):
		var val: float = _suppressed_mag[b]
		if val < min_val:
			continue
		var is_local_max: bool = true
		if b > 0 and _suppressed_mag[b - 1] > val:
			is_local_max = false
		if b < NUM_BINS - 1 and _suppressed_mag[b + 1] >= val:
			is_local_max = false
		if is_local_max:
			candidates.append({"bin": b, "midi": MIN_MIDI + b, "conf": clampf(val, 0.0, 1.0)})

	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["conf"]) > float(b["conf"])
	)

	var raw_top_pitches: Array[int] = []
	var new_pitches: Array[int] = []
	var frame_onsets: Array[int] = []
	var new_conf: Dictionary = {}
	var now_sec: float = float(Time.get_ticks_msec()) / 1000.0

	var max_polyphony: int = mini(4, candidates.size())
	for i in range(max_polyphony):
		var c: Dictionary = candidates[i]
		var midi: int = int(c["midi"])
		var conf: float = float(c["conf"])
		raw_top_pitches.append(midi)

		# In live chunked streaming, require a pitch to persist across 2 consecutive hops (~42ms),
		# allowing +/-1 semitone tolerance for vocal/instrument vibrato during sustained notes
		var has_streak: bool = (
			_candidate_streak_pitches.has(midi)
			or _candidate_streak_pitches.has(midi - 1)
			or _candidate_streak_pitches.has(midi + 1)
			or _emitted_active_pitches.has(midi)
		)
		if require_streak and not has_streak:
			continue

		new_pitches.append(midi)
		new_conf[str(midi)] = snappedf(conf, 0.001)

		var last_t: float = float(_last_onset_sec.get(midi, -999.0))
		if not _emitted_active_pitches.has(midi) and (now_sec - last_t >= 0.220):
			if not frame_onsets.has(midi):
				frame_onsets.append(midi)
			_last_onset_sec[midi] = now_sec

	_candidate_streak_pitches = raw_top_pitches
	new_pitches.sort()
	_emitted_active_pitches = new_pitches.duplicate()

	for b in range(NUM_BINS):
		_prev_energies[b] = _suppressed_mag[b]

	detected_pitches = new_pitches
	recent_onsets = frame_onsets.duplicate()
	confidence_map = new_conf
	last_latency_ms = float(Time.get_ticks_usec() - t0) / 1000.0

	pitches_detected.emit(detected_pitches)
	if not frame_onsets.is_empty():
		onsets_detected.emit(frame_onsets.duplicate())

