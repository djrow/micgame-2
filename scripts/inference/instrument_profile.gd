class_name InstrumentProfile
extends RefCounted

## InstrumentProfile: Manages per-instrument and per-player model fine-tuning parameters,
## 88-bin ONNX output adapter weights, harmonic overtone suppression ratios, attack/sustain
## hysteresis thresholds, and persistent latency calibration settings.

const SAVE_PATH: String = "user://instrument_profile.json"
const N_BINS: int = 88
const MIDI_OFFSET: int = 21

const PRESET_IDS: Array[String] = [
	"balanced",
	"plucked_guitar",
	"bowed_strings",
	"woodwind_brass",
	"vocal",
	"custom_finetuned"
]

var preset_id: String = "balanced"
var profile_name: String = "Balanced / Piano"
var input_latency_offset_ms: float = 50.0
var custom_onnx_model_path: String = ""

# Neural ONNX & Hybrid Hysteresis Thresholds
var onnx_onset_threshold: float = 0.52
var onnx_sustain_threshold: float = 0.35

# DSP Attack / Sustain Crest & Magnitude Floors
var dsp_attack_crest_min: float = 3.8
var dsp_sustain_crest_min: float = 2.8
var dsp_attack_mag_floor: float = 0.050
var dsp_sustain_mag_floor: float = 0.032

# Harmonic Overtone Suppression Weights (2nd, 3rd, 4th harmonics)
var harmonic_2nd_suppression: float = 0.55
var harmonic_3rd_suppression: float = 0.40
var harmonic_4th_suppression: float = 0.45

# Sustain Hold & Noise Floor
var noise_floor_rms: float = 0.005
var sustain_hold_chunks: int = 24

# 88-Bin Neural Output Calibration Weights (MIDI 21..108)
var per_bin_gain_adapter: PackedFloat32Array = PackedFloat32Array()

func _init(initial_preset: String = "balanced") -> void:
	per_bin_gain_adapter.resize(N_BINS)
	per_bin_gain_adapter.fill(1.0)
	apply_preset(initial_preset)

static func get_preset_definitions() -> Dictionary:
	return {
		"balanced": {
			"profile_name": "Balanced / Piano",
			"onnx_onset_threshold": 0.52,
			"onnx_sustain_threshold": 0.35,
			"dsp_attack_crest_min": 3.8,
			"dsp_sustain_crest_min": 2.8,
			"dsp_attack_mag_floor": 0.050,
			"dsp_sustain_mag_floor": 0.032,
			"harmonic_2nd_suppression": 0.55,
			"harmonic_3rd_suppression": 0.40,
			"harmonic_4th_suppression": 0.45,
			"noise_floor_rms": 0.005,
			"sustain_hold_chunks": 24
		},
		"plucked_guitar": {
			"profile_name": "Plucked Strings (Guitar / Harp)",
			"onnx_onset_threshold": 0.48,
			"onnx_sustain_threshold": 0.30,
			"dsp_attack_crest_min": 3.4,
			"dsp_sustain_crest_min": 2.4,
			"dsp_attack_mag_floor": 0.045,
			"dsp_sustain_mag_floor": 0.026,
			"harmonic_2nd_suppression": 0.62,
			"harmonic_3rd_suppression": 0.45,
			"harmonic_4th_suppression": 0.48,
			"noise_floor_rms": 0.005,
			"sustain_hold_chunks": 32
		},
		"bowed_strings": {
			"profile_name": "Bowed Strings (Violin / Cello)",
			"onnx_onset_threshold": 0.46,
			"onnx_sustain_threshold": 0.32,
			"dsp_attack_crest_min": 3.2,
			"dsp_sustain_crest_min": 2.5,
			"dsp_attack_mag_floor": 0.042,
			"dsp_sustain_mag_floor": 0.028,
			"harmonic_2nd_suppression": 0.65,
			"harmonic_3rd_suppression": 0.50,
			"harmonic_4th_suppression": 0.50,
			"noise_floor_rms": 0.005,
			"sustain_hold_chunks": 28
		},
		"woodwind_brass": {
			"profile_name": "Woodwind & Brass (Flute / Sax / Horn)",
			"onnx_onset_threshold": 0.50,
			"onnx_sustain_threshold": 0.33,
			"dsp_attack_crest_min": 3.6,
			"dsp_sustain_crest_min": 2.6,
			"dsp_attack_mag_floor": 0.048,
			"dsp_sustain_mag_floor": 0.030,
			"harmonic_2nd_suppression": 0.58,
			"harmonic_3rd_suppression": 0.48,
			"harmonic_4th_suppression": 0.45,
			"noise_floor_rms": 0.005,
			"sustain_hold_chunks": 28
		},
		"vocal": {
			"profile_name": "Vocal / Singing",
			"onnx_onset_threshold": 0.45,
			"onnx_sustain_threshold": 0.30,
			"dsp_attack_crest_min": 3.0,
			"dsp_sustain_crest_min": 2.3,
			"dsp_attack_mag_floor": 0.040,
			"dsp_sustain_mag_floor": 0.025,
			"harmonic_2nd_suppression": 0.60,
			"harmonic_3rd_suppression": 0.45,
			"harmonic_4th_suppression": 0.45,
			"noise_floor_rms": 0.005,
			"sustain_hold_chunks": 30
		}
	}

func apply_preset(target_preset_id: String) -> void:
	var defs: Dictionary = get_preset_definitions()
	if not defs.has(target_preset_id):
		if target_preset_id == "custom_finetuned":
			preset_id = "custom_finetuned"
			profile_name = "Custom Fine-Tuned Instrument"
		return

	preset_id = target_preset_id
	var d: Dictionary = defs[target_preset_id]
	profile_name = String(d.get("profile_name", "Balanced / Piano"))
	onnx_onset_threshold = float(d.get("onnx_onset_threshold", 0.52))
	onnx_sustain_threshold = float(d.get("onnx_sustain_threshold", 0.35))
	dsp_attack_crest_min = float(d.get("dsp_attack_crest_min", 3.8))
	dsp_sustain_crest_min = float(d.get("dsp_sustain_crest_min", 2.8))
	dsp_attack_mag_floor = float(d.get("dsp_attack_mag_floor", 0.050))
	dsp_sustain_mag_floor = float(d.get("dsp_sustain_mag_floor", 0.032))
	harmonic_2nd_suppression = float(d.get("harmonic_2nd_suppression", 0.55))
	harmonic_3rd_suppression = float(d.get("harmonic_3rd_suppression", 0.40))
	harmonic_4th_suppression = float(d.get("harmonic_4th_suppression", 0.45))
	noise_floor_rms = float(d.get("noise_floor_rms", 0.005))
	sustain_hold_chunks = int(d.get("sustain_hold_chunks", 24))
	per_bin_gain_adapter.resize(N_BINS)
	per_bin_gain_adapter.fill(1.0)

## Fine-tunes the model adapter and DSP profile from a live audio recording of the player's instrument.
## Measures attack vs. sustain envelope, spectral crest factor, harmonic overtone ratios (f0 vs 2f0/3f0/4f0),
## and computes an 88-bin neural output gain adapter for the player's instrument register.
func learn_from_instrument_samples(samples: PackedFloat32Array, sr: float = 48000.0) -> Dictionary:
	var n: int = samples.size()
	if n < 2048 or sr <= 0.0:
		return {"ok": false, "reason": "Insufficient audio samples for instrument fine-tuning"}

	# 1. Segment into 2048-sample analysis frames and compute frame RMS + peak
	var frame_size: int = 2048
	var hop: int = 1024
	var active_rms_list: Array[float] = []
	var quiet_rms_list: Array[float] = []
	var peak_rms: float = 0.0

	var pos: int = 0
	while pos + frame_size <= n:
		var sum_sq: float = 0.0
		for i in range(frame_size):
			var v: float = samples[pos + i]
			if not is_nan(v) and not is_inf(v):
				sum_sq += v * v
		var f_rms: float = sqrt(sum_sq / float(frame_size))
		if f_rms > peak_rms:
			peak_rms = f_rms
		if f_rms >= 0.010:
			active_rms_list.append(f_rms)
		else:
			quiet_rms_list.append(f_rms)
		pos += hop

	if active_rms_list.is_empty():
		return {"ok": false, "reason": "No audible instrument notes detected above noise floor"}

	# 2. Measure sustain-to-attack envelope ratio
	var mean_active_rms: float = 0.0
	for r in active_rms_list:
		mean_active_rms += r
	mean_active_rms /= float(active_rms_list.size())
	var sustain_ratio: float = clampf(mean_active_rms / maxf(peak_rms, 0.001), 0.25, 0.95)

	# 3. Analyze harmonic overtone ratios (f0 vs 2f0, 3f0, 4f0) acrossMIDI 36..84 using Goertzel
	var min_midi: int = 36
	var max_midi: int = 84
	var num_dsp_bins: int = max_midi - min_midi + 1
	var step: int = 2 if sr >= 32000.0 else 1
	var eff_sr: float = sr / float(step)
	var n_pts: int = frame_size / step

	var avg_bin_mag := PackedFloat32Array()
	avg_bin_mag.resize(num_dsp_bins)
	avg_bin_mag.fill(0.0)

	var coeffs := PackedFloat32Array()
	coeffs.resize(num_dsp_bins)
	for b in range(num_dsp_bins):
		var freq: float = 440.0 * pow(2.0, float((min_midi + b) - 69) / 12.0)
		coeffs[b] = 2.0 * cos(TAU * freq / eff_sr)

	var crest_sum: float = 0.0
	var active_frames_analyzed: int = 0

	pos = 0
	while pos + frame_size <= n:
		var sum_sq: float = 0.0
		for i in range(frame_size):
			var v: float = samples[pos + i]
			if not is_nan(v) and not is_inf(v):
				sum_sq += v * v
		var f_rms: float = sqrt(sum_sq / float(frame_size))
		if f_rms >= 0.010:
			var frame_max: float = 0.0001
			var frame_sum: float = 0.0
			for b in range(num_dsp_bins):
				var coeff: float = coeffs[b]
				var s1: float = 0.0
				var s2: float = 0.0
				var idx: int = pos
				for _k in range(n_pts):
					var s0: float = samples[idx] + coeff * s1 - s2
					s2 = s1
					s1 = s0
					idx += step
				var pwr: float = maxf(0.0, s1 * s1 + s2 * s2 - coeff * s1 * s2)
				var mag: float = sqrt(pwr) / float(n_pts)
				avg_bin_mag[b] += mag
				frame_sum += mag
				if mag > frame_max:
					frame_max = mag
			var frame_mean: float = frame_sum / float(num_dsp_bins)
			crest_sum += frame_max / maxf(frame_mean, 0.00001)
			active_frames_analyzed += 1
		pos += hop

	if active_frames_analyzed > 0:
		for b in range(num_dsp_bins):
			avg_bin_mag[b] /= float(active_frames_analyzed)

	var mean_crest: float = (crest_sum / float(maxi(1, active_frames_analyzed)))

	# Find dominant fundamental bin to estimate overtone ratios (octave +12, fifth +19, double-octave +24)
	var dom_bin: int = 0
	var dom_val: float = 0.0001
	for b in range(num_dsp_bins):
		if avg_bin_mag[b] > dom_val:
			dom_val = avg_bin_mag[b]
			dom_bin = b

	var ratio_2nd: float = (avg_bin_mag[dom_bin + 12] / dom_val) if (dom_bin + 12 < num_dsp_bins) else 0.35
	var ratio_3rd: float = (avg_bin_mag[dom_bin + 19] / dom_val) if (dom_bin + 19 < num_dsp_bins) else 0.25
	var ratio_4th: float = (avg_bin_mag[dom_bin + 24] / dom_val) if (dom_bin + 24 < num_dsp_bins) else 0.25

	# 4. Adapt parameters to the measured instrument & player characteristics
	preset_id = "custom_finetuned"
	profile_name = "Custom Fine-Tuned Instrument"

	# Plucked / percussive instruments have lower sustain_ratio (<0.55); sustained instruments have higher (>0.65)
	onnx_onset_threshold = clampf(0.44 + (sustain_ratio * 0.10), 0.44, 0.55)
	onnx_sustain_threshold = clampf(0.28 + (sustain_ratio * 0.10), 0.28, 0.38)

	dsp_attack_crest_min = clampf(mean_crest * 0.55, 3.0, 4.2)
	dsp_sustain_crest_min = clampf(dsp_attack_crest_min * 0.74, 2.2, 3.2)

	harmonic_2nd_suppression = clampf(0.48 + ratio_2nd * 0.25, 0.48, 0.72)
	harmonic_3rd_suppression = clampf(0.35 + ratio_3rd * 0.22, 0.35, 0.62)
	harmonic_4th_suppression = clampf(0.38 + ratio_4th * 0.22, 0.38, 0.62)

	sustain_hold_chunks = int(round(clampf(36.0 - sustain_ratio * 16.0, 20.0, 36.0)))

	# 5. Update 88-bin neural output gain adapter: gently boost the active register of this instrument
	per_bin_gain_adapter.resize(N_BINS)
	per_bin_gain_adapter.fill(1.0)
	for b in range(num_dsp_bins):
		var midi: int = min_midi + b
		var onnx_bin: int = midi - MIDI_OFFSET
		if onnx_bin >= 0 and onnx_bin < N_BINS:
			var rel_energy: float = clampf(avg_bin_mag[b] / dom_val, 0.0, 1.0)
			# Subtle 0.95..1.12 register calibration so the player's instrument register has balanced sensitivity
			per_bin_gain_adapter[onnx_bin] = snappedf(0.96 + rel_energy * 0.14, 0.001)

	return {
		"ok": true,
		"preset_id": preset_id,
		"profile_name": profile_name,
		"active_frames": active_frames_analyzed,
		"dominant_midi": min_midi + dom_bin,
		"sustain_ratio": snappedf(sustain_ratio, 0.01),
		"mean_crest": snappedf(mean_crest, 0.1),
		"onnx_onset_threshold": snappedf(onnx_onset_threshold, 0.01),
		"onnx_sustain_threshold": snappedf(onnx_sustain_threshold, 0.01),
		"harmonic_2nd_suppression": snappedf(harmonic_2nd_suppression, 0.01)
	}

func to_dict() -> Dictionary:
	var adapter_arr: Array = []
	for i in range(per_bin_gain_adapter.size()):
		adapter_arr.append(snappedf(per_bin_gain_adapter[i], 0.0001))
	return {
		"preset_id": preset_id,
		"profile_name": profile_name,
		"input_latency_offset_ms": snappedf(input_latency_offset_ms, 0.5),
		"custom_onnx_model_path": custom_onnx_model_path,
		"onnx_onset_threshold": snappedf(onnx_onset_threshold, 0.001),
		"onnx_sustain_threshold": snappedf(onnx_sustain_threshold, 0.001),
		"dsp_attack_crest_min": snappedf(dsp_attack_crest_min, 0.01),
		"dsp_sustain_crest_min": snappedf(dsp_sustain_crest_min, 0.01),
		"dsp_attack_mag_floor": snappedf(dsp_attack_mag_floor, 0.001),
		"dsp_sustain_mag_floor": snappedf(dsp_sustain_mag_floor, 0.001),
		"harmonic_2nd_suppression": snappedf(harmonic_2nd_suppression, 0.001),
		"harmonic_3rd_suppression": snappedf(harmonic_3rd_suppression, 0.001),
		"harmonic_4th_suppression": snappedf(harmonic_4th_suppression, 0.001),
		"noise_floor_rms": snappedf(noise_floor_rms, 0.0001),
		"sustain_hold_chunks": sustain_hold_chunks,
		"per_bin_gain_adapter": adapter_arr
	}

func from_dict(d: Dictionary) -> void:
	if d.is_empty():
		return
	preset_id = String(d.get("preset_id", preset_id))
	profile_name = String(d.get("profile_name", profile_name))
	input_latency_offset_ms = clampf(float(d.get("input_latency_offset_ms", input_latency_offset_ms)), -200.0, 300.0)
	custom_onnx_model_path = String(d.get("custom_onnx_model_path", custom_onnx_model_path))
	onnx_onset_threshold = clampf(float(d.get("onnx_onset_threshold", onnx_onset_threshold)), 0.30, 0.80)
	onnx_sustain_threshold = clampf(float(d.get("onnx_sustain_threshold", onnx_sustain_threshold)), 0.20, 0.65)
	dsp_attack_crest_min = clampf(float(d.get("dsp_attack_crest_min", dsp_attack_crest_min)), 2.2, 6.0)
	dsp_sustain_crest_min = clampf(float(d.get("dsp_sustain_crest_min", dsp_sustain_crest_min)), 1.8, 5.0)
	dsp_attack_mag_floor = clampf(float(d.get("dsp_attack_mag_floor", dsp_attack_mag_floor)), 0.020, 0.150)
	dsp_sustain_mag_floor = clampf(float(d.get("dsp_sustain_mag_floor", dsp_sustain_mag_floor)), 0.015, 0.120)
	harmonic_2nd_suppression = clampf(float(d.get("harmonic_2nd_suppression", harmonic_2nd_suppression)), 0.20, 0.85)
	harmonic_3rd_suppression = clampf(float(d.get("harmonic_3rd_suppression", harmonic_3rd_suppression)), 0.15, 0.75)
	harmonic_4th_suppression = clampf(float(d.get("harmonic_4th_suppression", harmonic_4th_suppression)), 0.15, 0.75)
	noise_floor_rms = clampf(float(d.get("noise_floor_rms", noise_floor_rms)), 0.002, 0.030)
	sustain_hold_chunks = clampi(int(d.get("sustain_hold_chunks", sustain_hold_chunks)), 8, 60)

	if d.has("per_bin_gain_adapter") and d["per_bin_gain_adapter"] is Array:
		var arr: Array = d["per_bin_gain_adapter"]
		per_bin_gain_adapter.resize(N_BINS)
		for i in range(N_BINS):
			if i < arr.size():
				per_bin_gain_adapter[i] = clampf(float(arr[i]), 0.5, 1.5)
			else:
				per_bin_gain_adapter[i] = 1.0

func save_to_disk(path: String = SAVE_PATH) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(to_dict(), "\t"))
	file.close()
	return true

func load_from_disk(path: String = SAVE_PATH) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var txt: String = FileAccess.get_file_as_string(path)
	if txt.is_empty():
		return false
	var parsed: Variant = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		return false
	from_dict(parsed)
	return true
