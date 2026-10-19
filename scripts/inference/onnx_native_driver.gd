class_name OnnxNativeDriver
extends "res://scripts/inference/audio_pitch_model.gd"

## Native on-device ONNX runtime driver for Spotify Basic Pitch (nmp.onnx).
## Interfaces directly with GDExtension C bindings via Engine.get_meta("onnx_pitch_native").
## Supports zero-copy buffer passing, 43,844-sample sliding analysis, and worker threading.

const MODEL_PATH := "res://assets/models/nmp.onnx"
const FALLBACK_MODEL_PATH := "res://assets/models/basic_pitch.onnx"
const MODEL_SAMPLE_RATE := 22050
const AUDIO_WINDOW_SAMPLES := 43844
const N_FRAMES := 172
const N_BINS := 88
const MIDI_OFFSET := 21
const FRAME_HOP_SEC := 256.0 / 22050.0 # ~0.01161s per frame
const SUMMARY_FLOATS := 352
const FULL_FLOATS := 352 + (N_FRAMES * N_BINS * 2) # 30,624 floats

var _native_callable: Callable
var _is_ready: bool = false
var _summary_template: PackedFloat32Array
var _full_template: PackedFloat32Array

# Streaming ring buffer state
var _ring_buffer_22k: PackedFloat32Array = PackedFloat32Array()
var _ring_write_pos: int = 0
var _samples_since_eval: int = 0
var _eval_hop_samples: int = 4410 # ~200ms evaluation hop

# Threading state
var _worker_task_id: int = -1
var _pending_result: Dictionary = {}
var _mutex: Mutex = Mutex.new()

const NativePitchDetectorScript = preload("res://scripts/inference/native_pitch_detector.gd")

# Active output states
var _active_pitches: Array[int] = []
var _onnx_active_pitches: Array[int] = []
var _onnx_confidence_map: Dictionary = {}
var _recent_onsets: Array[int] = []
var _prev_onnx_pitches: Array[int] = []
var _confidence_map: Dictionary = {}
var _last_latency_ms: float = 0.0
var _inference_count: int = 0
var _fast_dsp: RefCounted = null
var _is_live_silent: bool = true
var _silent_samples_count: int = 0

# Fine-tunable Instrument & Player Neural Adapter Parameters
var onset_threshold: float = 0.52
var sustain_threshold: float = 0.35
var active_model_path: String = MODEL_PATH
var per_bin_gain_adapter: PackedFloat32Array = PackedFloat32Array()

func _init() -> void:
	_summary_template = PackedFloat32Array()
	_summary_template.resize(SUMMARY_FLOATS)
	_full_template = PackedFloat32Array()
	_full_template.resize(FULL_FLOATS)

	per_bin_gain_adapter.resize(N_BINS)
	per_bin_gain_adapter.fill(1.0)

	_ring_buffer_22k.resize(AUDIO_WINDOW_SAMPLES)
	_ring_buffer_22k.fill(0.0)

	var sr: float = float(AudioServer.get_mix_rate())
	if sr <= 0.0:
		sr = 48000.0
	_fast_dsp = NativePitchDetectorScript.new(sr)

	if is_available():
		initialize()

func apply_instrument_profile(d: Dictionary) -> void:
	if d.is_empty():
		return
	onset_threshold = clampf(float(d.get("onnx_onset_threshold", onset_threshold)), 0.30, 0.80)
	sustain_threshold = clampf(float(d.get("onnx_sustain_threshold", sustain_threshold)), 0.20, 0.65)
	if d.has("per_bin_gain_adapter") and d["per_bin_gain_adapter"] is Array:
		var arr: Array = d["per_bin_gain_adapter"]
		per_bin_gain_adapter.resize(N_BINS)
		for i in range(N_BINS):
			if i < arr.size():
				per_bin_gain_adapter[i] = clampf(float(arr[i]), 0.5, 1.5)
			else:
				per_bin_gain_adapter[i] = 1.0
	if _fast_dsp != null and _fast_dsp.has_method("apply_instrument_profile"):
		_fast_dsp.apply_instrument_profile(d)
	var custom_path: String = String(d.get("custom_onnx_model_path", "")).strip_edges()
	if not custom_path.is_empty() and custom_path != active_model_path and FileAccess.file_exists(custom_path):
		reload_model(custom_path)

func reload_model(model_path: String) -> bool:
	if not Engine.has_meta("onnx_pitch_native"):
		return false
	if _worker_task_id != -1:
		WorkerThreadPool.wait_for_task_completion(_worker_task_id)
		_worker_task_id = -1
	var meta_val: Variant = Engine.get_meta("onnx_pitch_native")
	if typeof(meta_val) != TYPE_CALLABLE:
		return false
	_native_callable = meta_val
	if not FileAccess.file_exists(model_path):
		return false
	var model_bytes: PackedByteArray = FileAccess.get_file_as_bytes(model_path)
	if model_bytes.is_empty():
		return false
	var rc: Variant = _native_callable.call(0, model_bytes, model_bytes.size())
	var ok: bool = (typeof(rc) == TYPE_INT and int(rc) == 1)
	if ok:
		_is_ready = true
		active_model_path = model_path
		model_ready.emit()
	return ok

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if _worker_task_id != -1:
			WorkerThreadPool.wait_for_task_completion(_worker_task_id)
			_worker_task_id = -1

## Returns true if the native GDExtension callable has been registered in the engine.
func is_available() -> bool:
	return Engine.has_meta("onnx_pitch_native")

## Returns true if the ONNX Runtime session has been loaded and initialized.
func is_ready() -> bool:
	return _is_ready

func is_model_ready() -> bool:
	return _is_ready

## Initializes the ONNX session from disk or packed resource bytes.
## Command 0: init session (model_bytes: PackedByteArray, size: int)
## Command 2: query status (returns 1 if session ready)
func initialize(model_path: String = MODEL_PATH) -> bool:
	if not Engine.has_meta("onnx_pitch_native"):
		return false
	var meta_val: Variant = Engine.get_meta("onnx_pitch_native")
	if typeof(meta_val) != TYPE_CALLABLE:
		return false
	_native_callable = meta_val

	# Check if already initialized in C memory (Command 2) when loading default path
	if model_path == active_model_path:
		var status_val: Variant = _native_callable.call(2)
		if typeof(status_val) == TYPE_INT and int(status_val) == 1:
			_is_ready = true
			model_ready.emit()
			return true

	var target_path: String = model_path
	if not FileAccess.file_exists(target_path):
		if FileAccess.file_exists(FALLBACK_MODEL_PATH):
			target_path = FALLBACK_MODEL_PATH
		else:
			model_error.emit("ONNX model file not found at '%s' or '%s'" % [model_path, FALLBACK_MODEL_PATH])
			return false

	var model_bytes: PackedByteArray = FileAccess.get_file_as_bytes(target_path)
	if model_bytes.is_empty():
		model_error.emit("ONNX model file '%s' is empty or could not be read" % target_path)
		return false

	# Command 0: Initialize ONNX session
	var rc: Variant = _native_callable.call(0, model_bytes, model_bytes.size())
	_is_ready = (typeof(rc) == TYPE_INT and int(rc) == 1)
	if _is_ready:
		active_model_path = target_path
		model_ready.emit()
	else:
		model_error.emit("ONNX native initialization failed with return code: %s" % str(rc))
	return _is_ready

## Runs native ONNX Basic Pitch inference and returns live active pitches + 88-bin probabilities.
## Command 1: run inference (samples: PackedFloat32Array, sample_count: int, template: PackedFloat32Array, template_size: int)
func transcribe_live_window(
	samples_22k: PackedFloat32Array,
	note_threshold: float = 0.45,
	use_full_window: bool = false
) -> Dictionary:
	if not _is_ready and not initialize():
		return {"ok": false, "active_pitches": [], "frame_probs": []}
	if samples_22k.is_empty():
		return {"ok": false, "active_pitches": [], "frame_probs": []}

	var res: Variant = _native_callable.call(
		1,
		samples_22k,
		samples_22k.size(),
		_summary_template,
		SUMMARY_FLOATS
	)
	if typeof(res) != TYPE_PACKED_FLOAT32_ARRAY:
		return {"ok": false, "active_pitches": [], "frame_probs": []}

	var out: PackedFloat32Array = res
	if out.size() < SUMMARY_FLOATS:
		return {"ok": false, "active_pitches": [], "frame_probs": []}

	# For live streaming windows, verify that the recent 200ms tail has non-silent energy
	if not use_full_window and samples_22k.size() >= 4410:
		var tail_count: int = 4410
		var tail_start_idx: int = samples_22k.size() - tail_count
		var sum_sq: float = 0.0
		for i in range(tail_start_idx, samples_22k.size()):
			var v: float = samples_22k[i]
			if not is_nan(v) and not is_inf(v):
				sum_sq += v * v
		var tail_rms: float = sqrt(sum_sq / float(tail_count))
		if tail_rms < 0.008:
			var zero_probs: Array = []
			zero_probs.resize(N_BINS)
			zero_probs.fill(0.0)
			return {"ok": true, "active_pitches": [], "frame_probs": zero_probs}

	var note_offset: int = 176 if use_full_window else 0
	var onset_offset: int = 264 if use_full_window else 88

	# Only fall back to full window for short non-streaming buffers (< AUDIO_WINDOW_SAMPLES)
	if not use_full_window and samples_22k.size() < AUDIO_WINDOW_SAMPLES:
		var max_tail: float = 0.0
		var max_full: float = 0.0
		for b in range(N_BINS):
			if out[b] > max_tail:
				max_tail = out[b]
			if out[176 + b] > max_full:
				max_full = out[176 + b]
		if max_tail < note_threshold and max_full >= note_threshold:
			note_offset = 176
			onset_offset = 264

	var frame_probs: Array = []
	frame_probs.resize(N_BINS)
	var candidate_bins: Array[int] = []
	var elevated_bins: int = 0
	var has_adapter: bool = (per_bin_gain_adapter.size() == N_BINS)

	for b in range(N_BINS):
		var gain: float = per_bin_gain_adapter[b] if has_adapter else 1.0
		var np: float = clampf(out[note_offset + b] * gain, 0.0, 1.0)
		var op: float = clampf(out[onset_offset + b] * gain, 0.0, 1.0)
		frame_probs[b] = snappedf(np, 0.0001)
		if np >= 0.22:
			elevated_bins += 1
		var prev_gain: float = per_bin_gain_adapter[b - 1] if (has_adapter and b > 0) else 1.0
		var next_gain: float = per_bin_gain_adapter[b + 1] if (has_adapter and b + 1 < N_BINS) else 1.0
		var prev_np: float = clampf(out[note_offset + b - 1] * prev_gain, 0.0, 1.0) if b > 0 else 0.0
		var next_np: float = clampf(out[note_offset + b + 1] * next_gain, 0.0, 1.0) if b + 1 < N_BINS else 0.0
		var is_peak: bool = (np >= prev_np and np >= next_np)
		if is_peak and (np >= note_threshold or (np >= note_threshold * 0.85 and op >= 0.50)):
			candidate_bins.append(b)

	# Broadband noise / percussive splatter rejection: real tonal chords excite <= 12 bins
	if elevated_bins > 12:
		return {
			"ok": true,
			"active_pitches": [],
			"frame_probs": frame_probs
		}

	# Sort candidates by descending note probability and keep top polyphonic voices
	candidate_bins.sort_custom(func(a: int, b: int) -> bool:
		return out[note_offset + a] > out[note_offset + b]
	)

	var top_prob: float = out[note_offset + candidate_bins[0]] if not candidate_bins.is_empty() else 0.0
	var active_pitches: Array[int] = []
	for b in candidate_bins:
		if out[note_offset + b] < top_prob * 0.60:
			continue
		var midi_pitch: int = b + MIDI_OFFSET
		if midi_pitch < 36 or midi_pitch > 96:
			continue
		active_pitches.append(midi_pitch)
		if active_pitches.size() >= 4:
			break

	active_pitches.sort()
	return {
		"ok": true,
		"active_pitches": active_pitches,
		"frame_probs": frame_probs
	}

## Runs full [172, 88] matrix extraction for precise offline note transcription.
func transcribe_full_notes(
	samples_22k: PackedFloat32Array,
	note_threshold: float = 0.45,
	onset_threshold: float = 0.30,
	min_note_frames: int = 3
) -> Dictionary:
	if not _is_ready and not initialize():
		return {"ok": false, "notes": [], "active_pitches": [], "frame_probs": []}
	if samples_22k.is_empty():
		return {"ok": false, "notes": [], "active_pitches": [], "frame_probs": []}

	var res: Variant = _native_callable.call(
		1,
		samples_22k,
		samples_22k.size(),
		_full_template,
		FULL_FLOATS
	)
	if typeof(res) != TYPE_PACKED_FLOAT32_ARRAY:
		return {"ok": false, "notes": [], "active_pitches": [], "frame_probs": []}

	var out: PackedFloat32Array = res
	if out.size() < FULL_FLOATS:
		return transcribe_live_window(samples_22k, note_threshold, true)

	var notes_base: int = 352
	var onsets_base: int = 352 + (N_FRAMES * N_BINS)
	var notes_list: Array = []
	var active_set: Dictionary = {}

	for p in range(N_BINS):
		var midi_pitch: int = p + MIDI_OFFSET
		if midi_pitch < 36 or midi_pitch > 96:
			continue
		var in_note: bool = false
		var start_frame: int = 0
		var peak_conf: float = 0.0

		for f in range(N_FRAMES):
			var idx: int = f * N_BINS + p
			var n_prob: float = out[notes_base + idx]
			var o_prob: float = out[onsets_base + idx]
			var prev_p: float = out[notes_base + f * N_BINS + (p - 1)] if p > 0 else 0.0
			var next_p: float = out[notes_base + f * N_BINS + (p + 1)] if p + 1 < N_BINS else 0.0
			var is_spectral_peak: bool = (n_prob >= prev_p) and (n_prob >= next_p)

			if not in_note:
				if is_spectral_peak and (n_prob >= note_threshold or (o_prob >= onset_threshold and n_prob >= note_threshold * 0.7)):
					in_note = true
					start_frame = f
					peak_conf = n_prob
			else:
				if is_spectral_peak and n_prob >= note_threshold * 0.75:
					if o_prob >= onset_threshold and (f - start_frame) >= min_note_frames:
						notes_list.append({
							"pitch": midi_pitch,
							"onset_sec": snappedf(start_frame * FRAME_HOP_SEC, 0.0001),
							"duration_sec": snappedf((f - start_frame) * FRAME_HOP_SEC, 0.0001),
							"confidence": snappedf(peak_conf, 0.0001)
						})
						active_set[midi_pitch] = true
						start_frame = f
						peak_conf = n_prob
					else:
						peak_conf = maxf(peak_conf, n_prob)
				else:
					var dur_frames: int = f - start_frame
					if dur_frames >= min_note_frames:
						notes_list.append({
							"pitch": midi_pitch,
							"onset_sec": snappedf(start_frame * FRAME_HOP_SEC, 0.0001),
							"duration_sec": snappedf(dur_frames * FRAME_HOP_SEC, 0.0001),
							"confidence": snappedf(peak_conf, 0.0001)
						})
						active_set[midi_pitch] = true
					in_note = false

		if in_note and (N_FRAMES - start_frame) >= min_note_frames:
			notes_list.append({
				"pitch": midi_pitch,
				"onset_sec": snappedf(start_frame * FRAME_HOP_SEC, 0.0001),
				"duration_sec": snappedf((N_FRAMES - start_frame) * FRAME_HOP_SEC, 0.0001),
				"confidence": snappedf(peak_conf, 0.0001)
			})
			active_set[midi_pitch] = true

	var frame_probs: Array = []
	frame_probs.resize(N_BINS)
	for b in range(N_BINS):
		frame_probs[b] = snappedf(out[176 + b], 0.0001)

	var active_pitches: Array[int] = []
	for k in active_set.keys():
		active_pitches.append(int(k))
	active_pitches.sort()

	return {
		"ok": true,
		"notes": notes_list,
		"active_pitches": active_pitches,
		"frame_probs": frame_probs
	}

# --- IAudioPitchModel Polymorphic Interface Implementation ---

func push_audio_samples(samples: PackedFloat32Array) -> void:
	if not _is_ready:
		if not initialize():
			return
	if samples.is_empty():
		return

	poll()

	var sum_sq: float = 0.0
	var peak: float = 0.0
	var n: int = samples.size()
	for i in range(n):
		var s: float = samples[i]
		if not is_nan(s) and not is_inf(s):
			sum_sq += s * s
			var a: float = absf(s)
			if a > peak:
				peak = a
	var chunk_rms: float = sqrt(sum_sq / float(n))
	var is_chunk_silent: bool = (chunk_rms < 0.004 or peak < 0.006)

	var sr: float = float(AudioServer.get_mix_rate())
	if sr <= 0.0:
		sr = 48000.0

	# Fast-attack polyphonic DSP companion for instant <25ms response and silence tracking
	if _fast_dsp != null and _fast_dsp.has_method("push_audio_samples"):
		_fast_dsp.push_audio_samples(samples, sr)
		_last_latency_ms = _fast_dsp.get_last_latency_ms()

	if is_chunk_silent:
		_silent_samples_count += n
		_append_resampled_22k(samples, sr)
		if _silent_samples_count >= 1024:
			_is_live_silent = true
			_prev_onnx_pitches.clear()
			_onnx_active_pitches.clear()
			_onnx_confidence_map.clear()
			_recent_onsets.clear()
			if not _active_pitches.is_empty() or not _confidence_map.is_empty():
				_active_pitches.clear()
				_confidence_map.clear()
				pitches_detected.emit(_active_pitches)
			if _silent_samples_count >= 2048:
				_ring_buffer_22k.fill(0.0)
				_samples_since_eval = 0
		return

	_silent_samples_count = 0
	_is_live_silent = false

	if _fast_dsp != null:
		var dsp_pitches: Array[int] = _fast_dsp.get_detected_pitches()
		var dsp_conf: Dictionary = _fast_dsp.get_confidence_map()
		var dsp_onsets: Array[int] = _fast_dsp.pop_recent_onsets()
		if not dsp_pitches.is_empty():
			_active_pitches = dsp_pitches.duplicate()
			_confidence_map = dsp_conf.duplicate()
			_recent_onsets = dsp_onsets.duplicate()
			pitches_detected.emit(_active_pitches)
			if not dsp_onsets.is_empty():
				onsets_detected.emit(dsp_onsets)
		elif not _onnx_active_pitches.is_empty():
			# Maintain ONNX-locked sustained note even if Goertzel _fast_dsp momentarily dips
			_active_pitches = _onnx_active_pitches.duplicate()
			_confidence_map = _onnx_confidence_map.duplicate()
			_recent_onsets.clear()
			pitches_detected.emit(_active_pitches)

	var added: int = _append_resampled_22k(samples, sr)
	_samples_since_eval += added

	if _worker_task_id == -1 and _samples_since_eval >= _eval_hop_samples:
		_samples_since_eval = 0
		var win: PackedFloat32Array = _get_ordered_22k_window()
		_worker_task_id = WorkerThreadPool.add_task(_run_worker.bind(win), false, "BasicPitchNativeWorker")

func poll(_delta: float = 0.0) -> void:
	_consume_worker_if_done()

func get_detected_pitches() -> Array[int]:
	return _active_pitches.duplicate()

func get_recent_onsets(clear: bool = false) -> Array[int]:
	var copy: Array[int] = _recent_onsets.duplicate()
	if clear:
		_recent_onsets.clear()
	return copy

func pop_recent_onsets() -> Array[int]:
	return get_recent_onsets(true)

func get_confidence_map() -> Dictionary:
	return _confidence_map.duplicate()

func get_last_latency_ms() -> float:
	return _last_latency_ms

func reset() -> void:
	if _worker_task_id != -1:
		WorkerThreadPool.wait_for_task_completion(_worker_task_id)
		_worker_task_id = -1
	if _fast_dsp != null and _fast_dsp.has_method("reset"):
		_fast_dsp.reset()
	_ring_buffer_22k.fill(0.0)
	_ring_write_pos = 0
	_samples_since_eval = 0
	_active_pitches.clear()
	_onnx_active_pitches.clear()
	_onnx_confidence_map.clear()
	_recent_onsets.clear()
	_prev_onnx_pitches.clear()
	_confidence_map.clear()
	_pending_result.clear()
	_is_live_silent = true
	_silent_samples_count = 0

# --- Internal Audio Resampling & Worker Helpers ---

func _append_resampled_22k(samples: PackedFloat32Array, sr: float) -> int:
	if samples.is_empty():
		return 0
	var ratio: float = sr / 22050.0
	if ratio <= 0.0:
		ratio = 48000.0 / 22050.0
	var out_count: int = int(floor(float(samples.size()) / ratio))
	if out_count <= 0:
		return 0
	var ring_size: int = _ring_buffer_22k.size()
	for i in range(out_count):
		var a: int = int(float(i) * ratio)
		var b: int = mini(maxi(int(float(i + 1) * ratio), a + 1), samples.size())
		var acc: float = 0.0
		for k in range(a, b):
			acc += samples[k]
		_ring_buffer_22k[_ring_write_pos] = acc / float(b - a)
		_ring_write_pos = (_ring_write_pos + 1) % ring_size
	return out_count

func _get_ordered_22k_window() -> PackedFloat32Array:
	var ring_size: int = _ring_buffer_22k.size()
	var ordered := PackedFloat32Array()
	ordered.resize(ring_size)
	var idx: int = _ring_write_pos
	for i in range(ring_size):
		ordered[i] = _ring_buffer_22k[idx]
		idx += 1
		if idx >= ring_size:
			idx = 0
	return ordered

func _run_worker(win_22k: PackedFloat32Array) -> void:
	var t0: int = Time.get_ticks_usec()
	# Use sustain_threshold so sustained notes (>1-2s after attack) remain tracked via hysteresis
	var res: Dictionary = transcribe_live_window(win_22k, sustain_threshold, false)
	var elapsed_ms: float = float(Time.get_ticks_usec() - t0) / 1000.0
	res["latency_ms"] = elapsed_ms

	_mutex.lock()
	_pending_result = res
	_mutex.unlock()

func _consume_worker_if_done() -> void:
	if _worker_task_id != -1 and WorkerThreadPool.is_task_completed(_worker_task_id):
		WorkerThreadPool.wait_for_task_completion(_worker_task_id)
		_worker_task_id = -1

		_mutex.lock()
		var res: Dictionary = _pending_result.duplicate(true)
		_pending_result.clear()
		_mutex.unlock()

		if _is_live_silent:
			_onnx_active_pitches.clear()
			_onnx_confidence_map.clear()
			_recent_onsets.clear()
			return

		if bool(res.get("ok", false)):
			var pitches: Array = res.get("active_pitches", [])
			var frame_probs: Array = res.get("frame_probs", [])
			_last_latency_ms = float(res.get("latency_ms", _last_latency_ms))
			_inference_count += 1

			var new_onnx_onsets: Array[int] = []
			var next_active: Array[int] = []
			var next_conf: Dictionary = {}

			for p_var in pitches:
				var p: int = int(p_var)
				var bin_idx: int = p - MIDI_OFFSET
				var prob: float = float(frame_probs[bin_idx]) if (bin_idx >= 0 and bin_idx < frame_probs.size()) else 0.0
				var already_sustaining: bool = _onnx_active_pitches.has(p) or _active_pitches.has(p)

				if already_sustaining:
					# Hysteresis: keep already-active sustained notes alive down to sustain_threshold
					if prob < sustain_threshold:
						continue
				else:
					# Strict onset filter: new notes require >= onset_threshold probability and 2-hop persistence
					if prob < onset_threshold or not _prev_onnx_pitches.has(p):
						continue
					new_onnx_onsets.append(p)

				next_active.append(p)
				next_conf[str(p)] = prob

			var raw_onnx: Array[int] = []
			for p_var in pitches:
				var p: int = int(p_var)
				var bin_idx: int = p - MIDI_OFFSET
				var prob: float = float(frame_probs[bin_idx]) if (bin_idx >= 0 and bin_idx < frame_probs.size()) else 0.0
				if prob >= onset_threshold - 0.02:
					raw_onnx.append(p)
			_prev_onnx_pitches = raw_onnx

			next_active.sort()
			_onnx_active_pitches = next_active.duplicate()
			_onnx_confidence_map = next_conf.duplicate()

			if not next_active.is_empty():
				_active_pitches = next_active
				_confidence_map = next_conf
				_recent_onsets = new_onnx_onsets.duplicate()
				pitches_detected.emit(_active_pitches)
				if not new_onnx_onsets.is_empty():
					onsets_detected.emit(new_onnx_onsets)



