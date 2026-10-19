extends Node

## InferenceService: Autoload Singleton for multi-tier polyphonic pitch detection.
## Coordinates audio chunk ingestion from AudioCaptureService, routes samples through
## the active AudioPitchModel driver tier, manages automatic graceful fallbacks,
## and broadcasts detected pitches and onsets to ScoringService and GrandStaffHighway.

enum ModelTier {
	NATIVE_ONNX = 1,
	WEBSOCKET = 2,
	GD_DSP = 3,
	MOCK = 4
}

# --- Service Signals (V2 Interface Contract) ---
## Emitted when active sustained pitches are detected, with per-pitch confidence scores.
signal pitch_detected(detected_pitches: Array[int], confidence_map: Dictionary)

## Emitted when new musical note onsets/attacks are detected.
signal onset_detected(onset_pitches: Array[int])

## Diagnostics and telemetry signals
signal audio_chunk_processed(samples_count: int)
signal backend_changed(new_backend: int)
signal fallback_triggered(attempted_tier: int, fallback_tier: int, reason: String)

# Preloaded driver scripts
const AudioPitchModelScript = preload("res://scripts/inference/audio_pitch_model.gd")
const MockDriverScript = preload("res://scripts/inference/mock_driver.gd")
const OnnxNativeDriverScript = preload("res://scripts/inference/onnx_native_driver.gd")
const WebSocketDriverScript = preload("res://scripts/inference/websocket_driver.gd")
const NativePitchDetectorScript = preload("res://scripts/inference/native_pitch_detector.gd")

# --- Public Configuration & State ---
@export var default_tier: int = ModelTier.NATIVE_ONNX
@export var websocket_url: String = "ws://127.0.0.1:8765"
@export var auto_connect_audio_capture: bool = true

var active_tier: int = ModelTier.NATIVE_ONNX
var active_driver: RefCounted = null # AudioPitchModel
var active_pitches: Array[int] = []
var confidence_map: Dictionary = {}
var is_active: bool = true

# Internal driver cache to prevent re-allocation churn
var _driver_cache: Dictionary = {}

func _init() -> void:
	pass

func _ready() -> void:
	# Wire into AudioCaptureService if auto-connection enabled
	if auto_connect_audio_capture:
		_bind_audio_capture_service()

	# Initialize default tier (or fallback if unavailable)
	set_tier(default_tier)

func _process(delta: float) -> void:
	if not is_active or active_driver == null:
		return
	if active_driver.has_method("poll"):
		active_driver.poll(delta)

## Connects to AudioCaptureService.audio_chunk_ready signal
func _bind_audio_capture_service() -> void:
	if has_node("/root/AudioCaptureService"):
		var cap: Node = get_node("/root/AudioCaptureService")
		if cap.has_signal("audio_chunk_ready"):
			var cb: Callable = Callable(self, "push_audio_samples")
			if not cap.is_connected("audio_chunk_ready", cb):
				cap.connect("audio_chunk_ready", cb)

## Sets the active model inference tier with graceful fallback if unavailable.
func set_tier(tier: int) -> void:
	var target_tier: int = tier

	# Graceful fallback: Tier 1 (Native ONNX) -> Tier 3 (GD_DSP) -> Tier 4 (Mock)
	if target_tier == ModelTier.NATIVE_ONNX and not is_tier_available(ModelTier.NATIVE_ONNX):
		var fallback: int = ModelTier.GD_DSP if is_tier_available(ModelTier.GD_DSP) else ModelTier.MOCK
		push_warning("InferenceService: Tier 1 (NATIVE_ONNX) unavailable on this system. Falling back to Tier %s (%s)." % [
			str(fallback), get_tier_name(fallback)
		])
		fallback_triggered.emit(ModelTier.NATIVE_ONNX, fallback, "Native GDExtension or ONNX model unavailable")
		target_tier = fallback

	# Disconnect existing driver signals
	if active_driver != null:
		_unbind_driver_signals(active_driver)

	# Fetch or instantiate driver
	active_driver = _get_or_create_driver(target_tier)
	active_tier = target_tier

	if active_driver != null:
		_bind_driver_signals(active_driver)

	backend_changed.emit(active_tier)

## Returns current active model tier enum value.
func get_tier() -> int:
	return active_tier

## Returns human-readable name of model tier.
func get_tier_name(tier: int = -1) -> String:
	var t: int = tier if tier >= 0 else active_tier
	match t:
		ModelTier.NATIVE_ONNX:
			return "Native ONNX (nmp.onnx)"
		ModelTier.WEBSOCKET:
			return "WebSocket Server (Python)"
		ModelTier.GD_DSP:
			return "Pure GDScript Goertzel DSP"
		ModelTier.MOCK:
			return "Deterministic Mock Driver"
		_:
			return "Unknown Tier (%d)" % t

## Returns true if the requested tier can be run in the current environment.
func is_tier_available(tier: int) -> bool:
	match tier:
		ModelTier.NATIVE_ONNX:
			return Engine.has_meta("onnx_pitch_native")
		ModelTier.WEBSOCKET:
			return true
		ModelTier.GD_DSP:
			return true
		ModelTier.MOCK:
			return true
		_:
			return false

## Primary audio ingestion entry point from AudioCaptureService.
func push_audio_samples(samples: PackedFloat32Array) -> void:
	if not is_active or samples.is_empty():
		return
	if active_driver != null and active_driver.has_method("push_audio_samples"):
		active_driver.push_audio_samples(samples)
	audio_chunk_processed.emit(samples.size())

## Alias for push_audio_samples matching blueprint class diagram.
func push_samples(samples: PackedFloat32Array) -> void:
	push_audio_samples(samples)

## Returns currently sustained MIDI note numbers.
func get_active_pitches() -> Array[int]:
	if active_driver != null and active_driver.has_method("get_detected_pitches"):
		return active_driver.get_detected_pitches()
	return active_pitches.duplicate()

## Returns recent note onsets, optionally clearing them.
func get_recent_onsets(clear: bool = false) -> Array[int]:
	if active_driver != null and active_driver.has_method("get_recent_onsets"):
		return active_driver.get_recent_onsets(clear)
	return []

## Convenience method to atomically retrieve and clear recent onsets.
func pop_recent_onsets() -> Array[int]:
	return get_recent_onsets(true)

## Returns confidence map dictionary { "midi_string": float_confidence }.
func get_confidence_map() -> Dictionary:
	if active_driver != null and active_driver.has_method("get_confidence_map"):
		return active_driver.get_confidence_map()
	return confidence_map.duplicate()

## Resets active driver state and buffers.
func reset() -> void:
	active_pitches.clear()
	confidence_map.clear()
	if active_driver != null and active_driver.has_method("reset"):
		active_driver.reset()

## Polls active driver.
func poll(delta: float = 0.0) -> void:
	if active_driver != null and active_driver.has_method("poll"):
		active_driver.poll(delta)

## Returns comprehensive status telemetry for HUD diagnostic dock.
func get_status_summary() -> Dictionary:
	var is_ready: bool = active_driver != null and active_driver.has_method("is_model_ready") and active_driver.is_model_ready()
	var latency_ms: float = active_driver.get_last_latency_ms() if (active_driver and active_driver.has_method("get_last_latency_ms")) else 0.0
	return {
		"tier": active_tier,
		"tier_name": get_tier_name(active_tier),
		"is_ready": is_ready,
		"active_pitches": get_active_pitches(),
		"confidence_map": get_confidence_map(),
		"latency_ms": latency_ms
	}

# --- Driver Instantiation & Signal Management ---

func _get_or_create_driver(tier: int) -> RefCounted:
	if _driver_cache.has(tier):
		return _driver_cache[tier]

	var drv: RefCounted = null
	match tier:
		ModelTier.NATIVE_ONNX:
			drv = OnnxNativeDriverScript.new()
		ModelTier.WEBSOCKET:
			drv = WebSocketDriverScript.new(websocket_url)
		ModelTier.GD_DSP:
			var sr: float = float(AudioServer.get_mix_rate())
			if sr <= 0.0:
				sr = 48000.0
			drv = NativePitchDetectorScript.new(sr)
		ModelTier.MOCK:
			drv = MockDriverScript.new()
		_:
			drv = MockDriverScript.new()

	_driver_cache[tier] = drv
	return drv

func _bind_driver_signals(drv: RefCounted) -> void:
	if drv.has_signal("pitches_detected"):
		drv.connect("pitches_detected", Callable(self, "_on_driver_pitches_detected"))
	if drv.has_signal("onsets_detected"):
		drv.connect("onsets_detected", Callable(self, "_on_driver_onsets_detected"))

func _unbind_driver_signals(drv: RefCounted) -> void:
	if drv.has_signal("pitches_detected"):
		var cb_p: Callable = Callable(self, "_on_driver_pitches_detected")
		if drv.is_connected("pitches_detected", cb_p):
			drv.disconnect("pitches_detected", cb_p)
	if drv.has_signal("onsets_detected"):
		var cb_o: Callable = Callable(self, "_on_driver_onsets_detected")
		if drv.is_connected("onsets_detected", cb_o):
			drv.disconnect("onsets_detected", cb_o)

func _on_driver_pitches_detected(pitches: Array[int]) -> void:
	active_pitches = pitches
	if active_driver != null and active_driver.has_method("get_confidence_map"):
		confidence_map = active_driver.get_confidence_map()
	else:
		confidence_map.clear()
		for p in pitches:
			confidence_map[str(p)] = 1.0
	pitch_detected.emit(active_pitches, confidence_map)

func _on_driver_onsets_detected(onsets: Array[int]) -> void:
	onset_detected.emit(onsets)
