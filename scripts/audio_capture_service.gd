extends Node

## AudioCaptureService: Decoupled V2 Autoload Service for real-time microphone capture.
## Manages AudioEffectCapture polling, Bus 0 (Master) isolation, stereo-to-mono downmixing,
## -46 dB (0.005 RMS) silence gating with sample-clock zero-padding, hardware device enumeration,
## and a 512-sample circular oscilloscope buffer.

# --- Signals ---
## Primary V2 Interface Contract signal to InferenceService
signal audio_chunk_ready(samples: PackedFloat32Array)

## Diagnostics & Telemetry Signals (HUD, Oscilloscope, Unit Tests)
signal audio_chunk_captured(mono_samples: PackedFloat32Array, rms: float, is_gated: bool)
signal raw_waveform_updated(raw_samples: PackedFloat32Array, rms: float, rms_db: float, is_gated: bool)
signal rms_level_updated(rms_linear: float, rms_db: float)
signal input_device_changed(device_name: String)
signal capture_started()
signal capture_stopped()

# --- Constants ---
const OSCILLOSCOPE_BUFFER_SIZE: int = 512
const DEFAULT_RECORD_BUS_NAME: String = "Record"
const DEFAULT_MIN_CHUNK_FRAMES: int = 256
const DEFAULT_RMS_THRESHOLD: float = 0.005 # -46.02 dB
const SILENCE_DB_FLOOR: float = -100.0

# --- Exported Configuration ---
@export var record_bus_name: String = DEFAULT_RECORD_BUS_NAME
@export var min_chunk_frames: int = DEFAULT_MIN_CHUNK_FRAMES
@export var rms_threshold: float = DEFAULT_RMS_THRESHOLD
@export var push_silence_when_gated: bool = true
@export var auto_start: bool = false # Managed via GameManager/PermissionScreen in V2
@export var hardware_mic_gain: float = 1.6 # Gentle +4 dB pre-gain so ambient noise stays gated

# --- Public State ---
var pitch_model: RefCounted = null
var is_capturing: bool = false
var capture_effect: AudioEffectCapture = null
var record_bus_idx: int = -1

var current_rms: float = 0.0
var current_rms_db: float = SILENCE_DB_FLOOR
var is_currently_gated: bool = false
var total_frames_captured: int = 0

var latest_raw_samples: PackedFloat32Array = PackedFloat32Array()
var oscilloscope_ring_buffer: PackedFloat32Array = PackedFloat32Array()

# --- Internal State ---
var _mic_player: AudioStreamPlayer = null
var _synth_phase: float = 0.0
var _switch_epoch: int = 0
var _live_agc_gain: float = 1.6
var _sustain_hold_frames: int = 0

func _init() -> void:
	oscilloscope_ring_buffer.resize(OSCILLOSCOPE_BUFFER_SIZE)
	oscilloscope_ring_buffer.fill(0.0)
	_setup_bus_and_capture()

func _ready() -> void:
	if auto_start or is_capturing:
		start_capture()

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if _mic_player != null:
			if _mic_player.playing:
				_mic_player.stop()
			_mic_player.stream = null

## Configures Record bus, attaches AudioEffectCapture, and strictly protects Bus 0 (Master)
func _setup_bus_and_capture() -> void:
	record_bus_idx = AudioServer.get_bus_index(record_bus_name)
	if record_bus_idx == -1:
		# Dynamically create Record bus if missing (e.g. headless tests)
		record_bus_idx = AudioServer.bus_count
		AudioServer.add_bus(record_bus_idx)
		AudioServer.set_bus_name(record_bus_idx, record_bus_name)
		AudioServer.set_bus_send(record_bus_idx, &"") # Empty send prevents acoustic loop

	# CRITICAL SAFETY GUARD: NEVER mute Bus 0 (Master)
	assert(record_bus_idx > 0, "Record bus must never be Bus 0 (Master)!")
	if record_bus_idx > 0:
		AudioServer.set_bus_mute(record_bus_idx, true)
		AudioServer.set_bus_send(record_bus_idx, &"")
	else:
		push_error("AudioCaptureService: CRITICAL - Refusing to mute Bus 0 (Master)!")

	# Guarantee Master bus is unmuted at full volume
	var master_idx: int = AudioServer.get_bus_index("Master")
	if master_idx == 0:
		AudioServer.set_bus_mute(0, false)
		AudioServer.set_bus_volume_db(0, 0.0)

	# Locate or instantiate AudioEffectCapture
	var effect_count: int = AudioServer.get_bus_effect_count(record_bus_idx)
	for i in range(effect_count):
		var eff: AudioEffect = AudioServer.get_bus_effect(record_bus_idx, i)
		if eff is AudioEffectCapture:
			capture_effect = eff
			break

	if capture_effect == null:
		capture_effect = AudioEffectCapture.new()
		capture_effect.buffer_length = 1.0 # 1.0s circular capture ring buffer
		AudioServer.add_bus_effect(record_bus_idx, capture_effect)

	# Auto-prefer physical hardware microphone over virtual Voicemeeter bus on startup,
	# and prefer dedicated/USB microphones over built-in "Microphone Array" (which often has OS noise-suppression APOs)
	if DisplayServer.get_name() != "headless":
		var cur_dev: String = AudioServer.input_device
		if cur_dev.is_empty() or cur_dev == "Default":
			var dev_list: PackedStringArray = AudioServer.get_input_device_list()
			var has_virtual_bus: bool = false
			var preferred_physical_mic: String = ""
			var fallback_array_mic: String = ""
			for d in dev_list:
				var d_low: String = d.to_lower()
				if d_low.contains("voicemeeter") or d_low.contains("vb-audio"):
					has_virtual_bus = true
				elif d != "Default" and d_low.contains("microphone"):
					if d_low.contains("array"):
						if fallback_array_mic.is_empty():
							fallback_array_mic = d
					elif preferred_physical_mic.is_empty():
						preferred_physical_mic = d
			var chosen_mic: String = preferred_physical_mic if not preferred_physical_mic.is_empty() else fallback_array_mic
			if has_virtual_bus and not chosen_mic.is_empty():
				AudioServer.input_device = chosen_mic

	# Internal AudioStreamPlayer to drive hardware microphone into the Record bus
	if _mic_player == null:
		_mic_player = AudioStreamPlayer.new()
		_mic_player.name = "InternalMicPlayer"
		_mic_player.bus = record_bus_name
		_mic_player.stream = AudioStreamMicrophone.new()
		add_child(_mic_player)

## Returns list of available hardware microphone input devices
func get_input_devices() -> PackedStringArray:
	var devices: PackedStringArray = AudioServer.get_input_device_list()
	if devices.is_empty():
		return PackedStringArray(["Default"])
	return devices

## Returns active microphone device name
func get_current_input_device() -> String:
	var dev: String = AudioServer.input_device
	return dev if not dev.is_empty() else "Default"

## Switches active input device and resets mic stream cleanly without WASAPI input_start race
func set_input_device(device_name: String) -> bool:
	if device_name.is_empty():
		return false
	var devices: PackedStringArray = AudioServer.get_input_device_list()
	if not devices.is_empty() and not devices.has(device_name) and device_name != "Default":
		return false

	# Avoid redundant teardown/restart if already capturing on the requested device
	if AudioServer.input_device == device_name and _mic_player != null and _mic_player.playing and is_capturing:
		input_device_changed.emit(device_name)
		return true

	_switch_epoch += 1
	var epoch: int = _switch_epoch
	var should_play: bool = (_mic_player != null and _mic_player.playing) or is_capturing

	# Stop and release old AudioStreamMicrophone BEFORE switching AudioServer.input_device
	if _mic_player != null:
		if _mic_player.playing:
			_mic_player.stop()
		_mic_player.stream = null

	AudioServer.input_device = device_name
	if capture_effect != null:
		capture_effect.clear_buffer()

	if _mic_player != null:
		if is_inside_tree() and DisplayServer.get_name() != "headless" and get_tree() != null:
			# Allow WASAPI audio thread ~60ms to finish input_stop() before opening new device
			get_tree().create_timer(0.06).timeout.connect(func():
				if epoch != _switch_epoch or not is_inside_tree() or _mic_player == null:
					return
				_mic_player.stream = AudioStreamMicrophone.new()
				if should_play or is_capturing:
					_mic_player.play()
				if capture_effect != null:
					capture_effect.clear_buffer()
			)
		else:
			_mic_player.stream = AudioStreamMicrophone.new()
			if should_play and is_inside_tree():
				_mic_player.play()

	input_device_changed.emit(device_name)
	return true

## Returns a copy of the current 512-sample oscilloscope circular buffer
func get_oscilloscope_samples() -> PackedFloat32Array:
	return oscilloscope_ring_buffer.duplicate()

## Starts microphone capture
func start_capture() -> void:
	if is_capturing:
		if is_inside_tree() and _mic_player != null and not _mic_player.playing:
			if _mic_player.stream == null:
				_mic_player.stream = AudioStreamMicrophone.new()
			_mic_player.play()
		return

	if OS.get_name() == "Android":
		OS.request_permission("android.permission.RECORD_AUDIO")

	if is_inside_tree() and _mic_player != null and not _mic_player.playing:
		if _mic_player.stream == null:
			_mic_player.stream = AudioStreamMicrophone.new()
		_mic_player.play()

	if capture_effect != null:
		capture_effect.clear_buffer()

	is_capturing = true
	capture_started.emit()

## Stops microphone capture
func stop_capture() -> void:
	if not is_capturing:
		return
	if _mic_player != null and _mic_player.playing:
		_mic_player.stop()
	is_capturing = false
	capture_stopped.emit()

## Allows injecting pitch model runner directly (for tests or backward compatibility)
func set_pitch_model(model: RefCounted) -> void:
	pitch_model = model

func _process(_delta: float) -> void:
	if not is_capturing or capture_effect == null:
		return

	# Strictly NO calls to _mic_player.play() inside _process() (Blueprint §2.3 mobile safety)
	var available: int = capture_effect.get_frames_available()
	if available < min_chunk_frames:
		return

	var stereo_buffer: PackedVector2Array = capture_effect.get_buffer(available)
	var n_frames: int = stereo_buffer.size()
	if n_frames > 0 and hardware_mic_gain > 0.0:
		# Compute raw hardware RMS before gain to drive sustain makeup AGC
		# (counteracts OS/Realtek noise-suppression attenuation on long sustained notes)
		var raw_sum_sq: float = 0.0
		for i in range(n_frames):
			var m: float = (stereo_buffer[i].x + stereo_buffer[i].y) * 0.5
			if not is_nan(m) and not is_inf(m):
				raw_sum_sq += m * m
		var raw_rms: float = sqrt(raw_sum_sq / float(n_frames))

		# Open gate when raw_rms * hardware_mic_gain >= rms_threshold (~0.0031 raw RMS),
		# and hold open during sustained notes down to raw_rms >= 0.0007 (-63 dB)
		var open_raw_thresh: float = rms_threshold / maxf(hardware_mic_gain, 1.0)
		var sustain_raw_thresh: float = open_raw_thresh * 0.22
		if raw_rms >= open_raw_thresh:
			_sustain_hold_frames = 16000 # ~330ms hold time at 48kHz
		elif _sustain_hold_frames > 0 and raw_rms >= sustain_raw_thresh:
			# Refresh hold while user continues sustaining a quiet/attenuated note
			_sustain_hold_frames = maxi(_sustain_hold_frames, 9600)
		else:
			_sustain_hold_frames = maxi(0, _sustain_hold_frames - n_frames)

		var target_gain: float = hardware_mic_gain
		if _sustain_hold_frames > 0 and raw_rms >= sustain_raw_thresh:
			# Smooth makeup gain keeps long sustained notes around ~0.05 RMS even if OS attenuates them
			target_gain = clampf(0.05 / maxf(raw_rms, 0.0007), hardware_mic_gain, 14.0)
			_live_agc_gain = lerpf(_live_agc_gain, target_gain, 0.25)
		else:
			_live_agc_gain = lerpf(_live_agc_gain, hardware_mic_gain, 0.35)

		for i in range(n_frames):
			var f: Vector2 = stereo_buffer[i]
			stereo_buffer[i] = Vector2(
				clampf(f.x * _live_agc_gain, -1.0, 1.0),
				clampf(f.y * _live_agc_gain, -1.0, 1.0)
			)
	process_stereo_buffer(stereo_buffer)

## Processes stereo frames: downmixes to mono, computes RMS, applies noise gate,
## updates oscilloscope buffer, and emits audio chunks.
func process_stereo_buffer(stereo_buffer: PackedVector2Array) -> PackedFloat32Array:
	var n_frames: int = stereo_buffer.size()
	if n_frames == 0:
		return PackedFloat32Array()

	var mono: PackedFloat32Array = PackedFloat32Array()
	mono.resize(n_frames)
	var sum_squares: float = 0.0

	for i in range(n_frames):
		var left: float = stereo_buffer[i].x
		var right: float = stereo_buffer[i].y
		# Sanitize NaN/Inf
		if is_nan(left) or is_inf(left): left = 0.0
		if is_nan(right) or is_inf(right): right = 0.0
		var s: float = (left + right) * 0.5
		mono[i] = s
		sum_squares += s * s

	total_frames_captured += n_frames
	latest_raw_samples = mono
	_update_oscilloscope_buffer(mono)

	var rms: float = sqrt(sum_squares / float(n_frames))
	current_rms = rms
	current_rms_db = 20.0 * log(rms) / log(10.0) if rms > 0.0000001 else SILENCE_DB_FLOOR
	# Hysteresis: when gate is already open during active capture, stay open down to 60% of threshold
	var effective_threshold: float = rms_threshold
	if not is_currently_gated and _sustain_hold_frames > 0:
		effective_threshold = rms_threshold * 0.50
	is_currently_gated = (rms < effective_threshold)

	rms_level_updated.emit(current_rms, current_rms_db)
	raw_waveform_updated.emit(mono, current_rms, current_rms_db, is_currently_gated)

	var forward_samples: PackedFloat32Array = mono
	if is_currently_gated:
		if push_silence_when_gated:
			forward_samples = PackedFloat32Array()
			forward_samples.resize(n_frames)
			forward_samples.fill(0.0)
		else:
			forward_samples = PackedFloat32Array()

	# Pluggable pitch model direct forwarding
	if pitch_model != null and pitch_model.has_method("push_audio_samples"):
		if not forward_samples.is_empty() or (is_currently_gated and push_silence_when_gated):
			pitch_model.push_audio_samples(forward_samples)

	# Signal emission
	audio_chunk_ready.emit(forward_samples)
	audio_chunk_captured.emit(forward_samples, current_rms, is_currently_gated)
	return forward_samples

## Updates 512-sample circular oscilloscope buffer
func _update_oscilloscope_buffer(mono: PackedFloat32Array) -> void:
	var n: int = mono.size()
	if n == 0:
		return
	if oscilloscope_ring_buffer.size() != OSCILLOSCOPE_BUFFER_SIZE:
		oscilloscope_ring_buffer.resize(OSCILLOSCOPE_BUFFER_SIZE)
		oscilloscope_ring_buffer.fill(0.0)

	if n >= OSCILLOSCOPE_BUFFER_SIZE:
		var start_idx: int = n - OSCILLOSCOPE_BUFFER_SIZE
		for i in range(OSCILLOSCOPE_BUFFER_SIZE):
			var v: float = mono[start_idx + i]
			oscilloscope_ring_buffer[i] = 0.0 if (is_nan(v) or is_inf(v)) else clampf(v, -1.5, 1.5)
	else:
		var keep: int = OSCILLOSCOPE_BUFFER_SIZE - n
		for i in range(keep):
			oscilloscope_ring_buffer[i] = oscilloscope_ring_buffer[i + n]
		for i in range(n):
			var v: float = mono[i]
			oscilloscope_ring_buffer[keep + i] = 0.0 if (is_nan(v) or is_inf(v)) else clampf(v, -1.5, 1.5)

## Convenience method to inject mono samples directly into the capture pipeline (used by test suites)
func inject_mono_samples(mono_samples: PackedFloat32Array) -> PackedFloat32Array:
	var stereo := PackedVector2Array()
	stereo.resize(mono_samples.size())
	for i in range(mono_samples.size()):
		var v: float = mono_samples[i]
		stereo[i] = Vector2(v, v)
	return process_stereo_buffer(stereo)

## Injects synthetic chord into pipeline to verify oscilloscope, RMS, and pitch inference
func inject_test_chord(midi_pitches: Array = [60, 64, 67], duration_frames: int = 2048, amplitude: float = 0.28) -> PackedFloat32Array:
	var sr: float = float(get_sample_rate())
	if sr <= 0.0:
		sr = 48000.0
	var mono := PackedFloat32Array()
	mono.resize(duration_frames)
	var n_voices: int = maxi(1, midi_pitches.size())
	var voice_amp: float = amplitude / float(n_voices)

	for i in range(duration_frames):
		var t: float = (_synth_phase + float(i)) / sr
		var sample_val: float = 0.0
		for p in midi_pitches:
			var freq: float = 440.0 * pow(2.0, float(int(p) - 69) / 12.0)
			sample_val += voice_amp * (0.80 * sin(TAU * freq * t) + 0.20 * sin(TAU * freq * 2.0 * t))
		mono[i] = sample_val

	_synth_phase = fmod(_synth_phase + float(duration_frames), sr * 10.0)
	return inject_mono_samples(mono)

## Returns current mix rate from AudioServer (fallback to 48000 if headless)
func get_sample_rate() -> int:
	var rate: int = int(AudioServer.get_mix_rate())
	return rate if rate > 0 else 48000
