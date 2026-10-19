class_name WebSocketDriver
extends "res://scripts/inference/audio_pitch_model.gd"

## Real-time streaming WebSocket driver for Basic Pitch ONNX inference server.
## Streams audio PCM buffers from Godot to localhost (ws://127.0.0.1:8765)
## and receives detected polyphonic MIDI pitches and onsets.

@export var server_url: String = "ws://127.0.0.1:8765"
@export var auto_reconnect: bool = true
@export var reconnect_interval_sec: float = 2.0
@export var send_int16: bool = false # False = raw IEEE float32 mono, True = int16 PCM
@export var min_send_samples: int = 0 # If > 0, batches samples before sending over WebSocket

var ws: WebSocketPeer = null
var is_connected: bool = false
var reconnect_timer: float = 0.0
var _reconnect_timer: float = 0.0
var _last_poll_msec: int = 0
var _config_sent: bool = false

var detected_pitches: Array[int] = []
var recent_onsets: Array[int] = []
var last_timestamp: float = 0.0
var confidence_map: Dictionary = {}
var last_latency_ms: float = 0.0
var inference_count: int = 0
var samples_sent: int = 0

var _tx_buffer: PackedFloat32Array = PackedFloat32Array()

func _init(url: String = "ws://127.0.0.1:8765") -> void:
	server_url = url
	connect_to_server()

## Connects or reconnects to the WebSocket inference server.
func connect_to_server() -> Error:
	ws = WebSocketPeer.new()
	is_connected = false
	_config_sent = false
	reconnect_timer = 0.0
	_reconnect_timer = 0.0
	var err: Error = ws.connect_to_url(server_url)
	if err != OK:
		model_error.emit("Failed to initiate connection to %s (Error code: %d)" % [server_url, err])
	return err

## Disconnects from the WebSocket server cleanly.
func disconnect_from_server() -> void:
	if ws != null:
		if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			ws.close(1000, "Clean client disconnect")
	is_connected = false
	_config_sent = false

## Streams audio samples to the WebSocket server.
func push_audio_samples(samples: PackedFloat32Array) -> void:
	poll()
	if samples.is_empty():
		return

	samples_sent += samples.size()

	if ws != null and ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		if not _config_sent:
			_send_handshake_config()
		if min_send_samples > 0:
			_tx_buffer.append_array(samples)
			if _tx_buffer.size() < min_send_samples:
				return
			_send_pcm_packet(_tx_buffer)
			_tx_buffer.clear()
		else:
			_send_pcm_packet(samples)

func _send_handshake_config() -> void:
	if ws == null or ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	var sr: int = int(AudioServer.get_mix_rate())
	if sr <= 0:
		sr = 48000
	var cfg_json: String = JSON.stringify({
		"cmd": "config",
		"sample_rate": sr,
		"pcm_format": "int16" if send_int16 else "float32",
		"response_format": "json"
	})
	ws.send_text(cfg_json)
	_config_sent = true

func _send_pcm_packet(samples: PackedFloat32Array) -> void:
	if send_int16:
		var int16_bytes := PackedByteArray()
		int16_bytes.resize(samples.size() * 2)
		for i in range(samples.size()):
			var v: float = samples[i]
			if is_nan(v) or is_inf(v):
				v = 0.0
			var clamped: float = clampf(v, -1.0, 1.0)
			var s16: int = int(round(clamped * 32767.0))
			int16_bytes.encode_s16(i * 2, s16)
		ws.put_packet(int16_bytes)
	else:
		var raw_bytes: PackedByteArray = samples.to_byte_array()
		ws.put_packet(raw_bytes)

## Polls WebSocket peer, updates state machine, and processes incoming responses.
func poll(delta: float = -1.0) -> void:
	var now_msec: int = Time.get_ticks_msec()
	var dt: float = delta
	if dt < 0.0:
		if _last_poll_msec > 0:
			dt = float(now_msec - _last_poll_msec) / 1000.0
		else:
			dt = 0.0
	_last_poll_msec = now_msec

	if ws == null:
		if auto_reconnect:
			connect_to_server()
		return

	ws.poll()
	var state: int = ws.get_ready_state()

	match state:
		WebSocketPeer.STATE_OPEN:
			if not is_connected:
				is_connected = true
				reconnect_timer = 0.0
				_reconnect_timer = 0.0
				_send_handshake_config()
				model_ready.emit()

			# Drain available incoming packets
			while ws.get_available_packet_count() > 0:
				var pkt: PackedByteArray = ws.get_packet()
				if ws.was_string_packet():
					_parse_json_response(pkt.get_string_from_utf8())
				else:
					_parse_binary_response(pkt)

		WebSocketPeer.STATE_CONNECTING:
			pass

		WebSocketPeer.STATE_CLOSING:
			pass

		WebSocketPeer.STATE_CLOSED:
			var was_active: bool = is_connected
			is_connected = false
			_config_sent = false
			if was_active:
				model_error.emit("WebSocket closed (Code: %d, Reason: %s)" % [ws.get_close_code(), ws.get_close_reason()])
			if auto_reconnect:
				_reconnect_timer += dt
				reconnect_timer = _reconnect_timer
				if _reconnect_timer >= reconnect_interval_sec:
					_reconnect_timer = 0.0
					reconnect_timer = 0.0
					connect_to_server()

## Parses JSON responses from Python server.
func _parse_json_response(json_text: String) -> void:
	var json: JSON = JSON.new()
	var err: Error = json.parse(json_text)
	if err != OK:
		model_error.emit("Failed to parse JSON response: %d" % err)
		return

	var data: Variant = json.data
	if not (data is Dictionary):
		return

	var msg_type: String = String(data.get("type", "pitches"))
	if msg_type == "pitches" or data.has("pitches"):
		var raw_pitches: Variant = data.get("pitches", [])
		var new_pitches: Array[int] = []
		if raw_pitches is Array:
			for p in raw_pitches:
				new_pitches.append(int(p))
		detected_pitches = new_pitches

		var raw_onsets: Variant = data.get("onsets", [])
		var new_onsets: Array[int] = []
		if raw_onsets is Array:
			for o in raw_onsets:
				new_onsets.append(int(o))
		recent_onsets = new_onsets

		last_timestamp = float(data.get("timestamp", 0.0))
		if data.has("latency_ms"):
			last_latency_ms = float(data.get("latency_ms", 0.0))
		var raw_conf: Variant = data.get("confidence", {})
		if raw_conf is Dictionary:
			confidence_map = raw_conf

		inference_count += 1

		if not detected_pitches.is_empty():
			pitches_detected.emit(detected_pitches)
		if not recent_onsets.is_empty():
			onsets_detected.emit(recent_onsets)

## Parses compact binary responses.
func _parse_binary_response(pkt: PackedByteArray) -> void:
	if pkt.size() < 2:
		return

	var n_pitches: int = pkt[0]
	if pkt.size() < 1 + n_pitches + 1:
		return

	var new_pitches: Array[int] = []
	for i in range(n_pitches):
		new_pitches.append(int(pkt[1 + i]))
	detected_pitches = new_pitches

	var onset_offset: int = 1 + n_pitches
	var n_onsets: int = pkt[onset_offset]
	var new_onsets: Array[int] = []
	for j in range(n_onsets):
		if onset_offset + 1 + j < pkt.size():
			new_onsets.append(int(pkt[onset_offset + 1 + j]))
	recent_onsets = new_onsets

	inference_count += 1

	if not detected_pitches.is_empty():
		pitches_detected.emit(detected_pitches)
	if not recent_onsets.is_empty():
		onsets_detected.emit(recent_onsets)

func get_detected_pitches() -> Array[int]:
	return detected_pitches.duplicate()

func get_recent_onsets(clear: bool = false) -> Array[int]:
	var copy: Array[int] = recent_onsets.duplicate()
	if clear:
		recent_onsets.clear()
	return copy

func pop_recent_onsets() -> Array[int]:
	return get_recent_onsets(true)

func is_model_ready() -> bool:
	return is_connected and ws != null and ws.get_ready_state() == WebSocketPeer.STATE_OPEN

func reset() -> void:
	detected_pitches.clear()
	recent_onsets.clear()
	confidence_map.clear()
	_tx_buffer.clear()
	reconnect_timer = 0.0
	_reconnect_timer = 0.0

func get_confidence_map() -> Dictionary:
	return confidence_map.duplicate()

func get_last_latency_ms() -> float:
	return last_latency_ms

func get_status_summary() -> Dictionary:
	var ready_status: bool = is_model_ready()
	return {
		"backend": "WebSocket Python ONNX" if ready_status else "WebSocket (Disconnected)",
		"is_connected": is_connected,
		"is_ready": ready_status,
		"latency_ms": last_latency_ms,
		"inference_count": inference_count,
		"samples_sent": samples_sent,
		"pitches": detected_pitches,
		"confidence": confidence_map
	}
