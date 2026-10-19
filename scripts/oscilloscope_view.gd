class_name OscilloscopeView
extends Control

## OscilloscopeView: Real-Time Zero-Crossing Oscilloscope & Audio Telemetry Control.
## Renders time-domain waveform with rising-edge zero-crossing trigger stabilization,
## graticule grid, noise-gate threshold guides, auto-gain scaling, live RMS/pitch readout,
## and dynamic dB VU bar. Positioned safely within Y = 480..610 (Blueprint §2.3, §5.1, §5.3).

# --- Constants ---
const DISPLAY_SAMPLES: int = 256
const RING_BUFFER_SIZE: int = 512
const DOCK_Y_MIN: float = 480.0
const DOCK_Y_MAX: float = 610.0
const DOCK_HEIGHT: float = 130.0
const DEFAULT_RMS_THRESHOLD: float = 0.005 # -46.02 dB
const SILENCE_DB_FLOOR: float = -100.0

const COLOR_TRACE_DEFAULT: Color = Color(0.2, 0.8, 1.0, 0.85)
const COLOR_TRACE_ACTIVE: Color = Color(0.15, 1.0, 0.55, 0.98)
const COLOR_TRACE_GLOW: Color = Color(0.1, 0.5, 0.9, 0.28)
const COLOR_CRT_BG: Color = Color(0.03, 0.05, 0.08, 0.94)
const COLOR_GRID_LINE: Color = Color(0.14, 0.22, 0.32, 0.55)
const COLOR_GRID_CENTER: Color = Color(0.22, 0.35, 0.48, 0.80)
const COLOR_GATE_GUIDE: Color = Color(1.0, 0.72, 0.15, 0.45)

const NOTE_NAMES: Array[String] = [
	"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"
]

# --- Exported Properties ---
@export var rms_threshold: float = DEFAULT_RMS_THRESHOLD
@export var auto_gain: bool = true
@export var auto_connect: bool = true
@export var trace_color: Color = COLOR_TRACE_DEFAULT
@export var show_vu_meter: bool = true
@export var show_telemetry_text: bool = true

# --- Public State ---
var waveform_buffer: PackedFloat32Array = PackedFloat32Array()
var current_rms: float = 0.0
var current_rms_db: float = SILENCE_DB_FLOOR
var is_gated: bool = true
var sample_rate: int = 48000
var peak_amplitude: float = 0.0
var peak_db_hold: float = SILENCE_DB_FLOOR
var estimated_freq_hz: float = 0.0
var current_display_gain: float = 1.0

# Pitch & Inference Telemetry
var active_pitches: Array = []
var confidence_map: Dictionary = {}
var backend_name: String = ""

# --- Internal State ---
var _peak_hold_timer: float = 0.0
var _services_bound: bool = false

func _init() -> void:
	waveform_buffer.resize(RING_BUFFER_SIZE)
	waveform_buffer.fill(0.0)
	custom_minimum_size = Vector2(400.0, DOCK_HEIGHT)

func _ready() -> void:
	if auto_connect:
		connect_services()

func _exit_tree() -> void:
	disconnect_services()

func _process(delta: float) -> void:
	# Peak hold decay timer (No play() calls inside _process)
	if _peak_hold_timer > 0.0:
		_peak_hold_timer -= delta
	else:
		peak_db_hold = maxf(SILENCE_DB_FLOOR, peak_db_hold - delta * 25.0)
	queue_redraw()

## Automatically connects to AudioCaptureService and InferenceService singletons if available
func connect_services() -> void:
	if _services_bound:
		return

	var cap = get_node_or_null("/root/AudioCaptureService")
	if cap != null:
		if cap.has_signal("raw_waveform_updated") and not cap.raw_waveform_updated.is_connected(_on_raw_waveform_updated):
			cap.raw_waveform_updated.connect(_on_raw_waveform_updated)
		elif cap.has_signal("audio_chunk_ready") and not cap.audio_chunk_ready.is_connected(_on_audio_chunk_ready):
			cap.audio_chunk_ready.connect(_on_audio_chunk_ready)

	var inf = get_node_or_null("/root/InferenceService")
	if inf != null:
		if inf.has_signal("pitch_detected") and not inf.pitch_detected.is_connected(_on_pitch_detected):
			inf.pitch_detected.connect(_on_pitch_detected)
		if inf.has_signal("backend_changed") and not inf.backend_changed.is_connected(_on_backend_changed):
			inf.backend_changed.connect(_on_backend_changed)
		if inf.has_method("get_tier_name"):
			backend_name = inf.get_tier_name()

	_services_bound = true

## Disconnects bound singleton signals safely
func disconnect_services() -> void:
	if not _services_bound:
		return

	var cap = get_node_or_null("/root/AudioCaptureService")
	if cap != null:
		if cap.has_signal("raw_waveform_updated") and cap.raw_waveform_updated.is_connected(_on_raw_waveform_updated):
			cap.raw_waveform_updated.disconnect(_on_raw_waveform_updated)
		if cap.has_signal("audio_chunk_ready") and cap.audio_chunk_ready.is_connected(_on_audio_chunk_ready):
			cap.audio_chunk_ready.disconnect(_on_audio_chunk_ready)

	var inf = get_node_or_null("/root/InferenceService")
	if inf != null:
		if inf.has_signal("pitch_detected") and inf.pitch_detected.is_connected(_on_pitch_detected):
			inf.pitch_detected.disconnect(_on_pitch_detected)
		if inf.has_signal("backend_changed") and inf.backend_changed.is_connected(_on_backend_changed):
			inf.backend_changed.disconnect(_on_backend_changed)

	_services_bound = false

# --- Signal Callbacks ---
func _on_raw_waveform_updated(raw_samples: PackedFloat32Array, rms: float, rms_db: float, gated: bool) -> void:
	update_waveform(raw_samples, rms, rms_db, gated, sample_rate)

func _on_audio_chunk_ready(samples: PackedFloat32Array) -> void:
	push_samples(samples)

func _on_pitch_detected(detected_pitches: Array[int], confidences: Dictionary) -> void:
	update_pitch_telemetry(detected_pitches, confidences, backend_name)

func _on_backend_changed(new_backend: int) -> void:
	var inf = get_node_or_null("/root/InferenceService")
	if inf != null and inf.has_method("get_tier_name"):
		backend_name = inf.get_tier_name(new_backend)

# --- Ingestion & Telemetry API ---

## Primary ingestion method called by AudioCaptureService, HUD, or test suites.
func update_waveform(samples: PackedFloat32Array, rms: float, rms_db: float, gated: bool, sr: int = 48000) -> void:
	if not samples.is_empty():
		var n: int = samples.size()
		if n == RING_BUFFER_SIZE:
			waveform_buffer = samples.duplicate()
		elif n >= RING_BUFFER_SIZE:
			waveform_buffer = samples.slice(n - RING_BUFFER_SIZE, n)
		else:
			# Shift existing buffer and insert new chunk
			var keep: int = RING_BUFFER_SIZE - n
			var new_buf := PackedFloat32Array()
			new_buf.resize(RING_BUFFER_SIZE)
			for i in range(keep):
				new_buf[i] = waveform_buffer[i + n]
			for i in range(n):
				var v: float = samples[i]
				new_buf[keep + i] = 0.0 if (is_nan(v) or is_inf(v)) else clampf(v, -1.5, 1.5)
			waveform_buffer = new_buf

	current_rms = rms
	current_rms_db = rms_db
	is_gated = gated
	if sr > 0:
		sample_rate = sr

	_analyze_buffer()
	queue_redraw()

## Circularly ingests a raw chunk of audio samples without precomputed RMS
func push_samples(samples: PackedFloat32Array) -> void:
	var n: int = samples.size()
	if n == 0:
		return

	if waveform_buffer.size() != RING_BUFFER_SIZE:
		waveform_buffer.resize(RING_BUFFER_SIZE)
		waveform_buffer.fill(0.0)

	if n >= RING_BUFFER_SIZE:
		var start_idx: int = n - RING_BUFFER_SIZE
		for i in range(RING_BUFFER_SIZE):
			var v: float = samples[start_idx + i]
			waveform_buffer[i] = 0.0 if (is_nan(v) or is_inf(v)) else clampf(v, -1.5, 1.5)
	else:
		var keep: int = RING_BUFFER_SIZE - n
		for i in range(keep):
			waveform_buffer[i] = waveform_buffer[i + n]
		for i in range(n):
			var v: float = samples[i]
			waveform_buffer[keep + i] = 0.0 if (is_nan(v) or is_inf(v)) else clampf(v, -1.5, 1.5)

	# Compute RMS from buffer
	var sum_sq: float = 0.0
	for i in range(RING_BUFFER_SIZE):
		var v: float = waveform_buffer[i]
		sum_sq += v * v
	current_rms = sqrt(sum_sq / float(RING_BUFFER_SIZE))
	current_rms_db = 20.0 * log(current_rms) / log(10.0) if current_rms > 0.0000001 else SILENCE_DB_FLOOR
	is_gated = (current_rms < rms_threshold)

	_analyze_buffer()
	queue_redraw()

## Updates live pitch and inference telemetry displayed in the dock overlay
func update_pitch_telemetry(pitches: Array, confidences: Dictionary = {}, backend: String = "") -> void:
	active_pitches.clear()
	for p in pitches:
		active_pitches.append(int(p))
	confidence_map = confidences.duplicate()
	if not backend.is_empty():
		backend_name = backend
	queue_redraw()

## Resets all audio buffer and telemetry data
func clear() -> void:
	waveform_buffer.fill(0.0)
	current_rms = 0.0
	current_rms_db = SILENCE_DB_FLOOR
	is_gated = true
	peak_amplitude = 0.0
	peak_db_hold = SILENCE_DB_FLOOR
	_peak_hold_timer = 0.0
	estimated_freq_hz = 0.0
	current_display_gain = 1.0
	active_pitches.clear()
	confidence_map.clear()
	queue_redraw()

# --- Internal Buffer Analysis ---

func _analyze_buffer() -> void:
	var pk: float = 0.0
	var zero_crossings: int = 0
	var n: int = waveform_buffer.size()

	for i in range(n):
		var v: float = waveform_buffer[i]
		if is_nan(v) or is_inf(v):
			v = 0.0
			waveform_buffer[i] = 0.0
		var a: float = absf(v)
		if a > pk:
			pk = a
		# Strict rising-edge zero-crossing count
		if i > 0 and waveform_buffer[i - 1] <= 0.0 and waveform_buffer[i] > 0.0:
			zero_crossings += 1

	peak_amplitude = pk

	if current_rms_db > peak_db_hold:
		peak_db_hold = current_rms_db
		_peak_hold_timer = 1.2

	# Frequency estimation via rising zero crossings
	if not is_gated and n > 0 and zero_crossings >= 2:
		var duration_sec: float = float(n) / float(maxi(1, sample_rate))
		estimated_freq_hz = float(zero_crossings) / duration_sec
	else:
		estimated_freq_hz = 0.0

	# Auto-gain scaling
	if auto_gain:
		var target_gain: float = 1.0
		if pk > 0.0002 and pk < 0.55:
			target_gain = clampf(0.65 / pk, 1.0, 25.0)
		current_display_gain = lerpf(current_display_gain, target_gain, 0.25)
	else:
		current_display_gain = 1.0

# --- Zero-Crossing Trigger Detection ---

func _find_trigger_offset() -> int:
	var n: int = waveform_buffer.size()
	var max_search: int = maxi(1, n - DISPLAY_SAMPLES - 1)
	var hysteresis: float = maxf(0.002, peak_amplitude * 0.04)

	# Search for rising zero-crossing with hysteresis threshold
	for i in range(1, max_search):
		if waveform_buffer[i - 1] <= 0.0 and waveform_buffer[i] > hysteresis:
			return i
	return 0

# --- Helper Methods ---

## Converts MIDI pitch integer to standard scientific pitch notation string
static func midi_to_note_name(midi: int) -> String:
	if midi < 0 or midi > 127:
		return "N/A"
	var octave: int = (midi / 12) - 1
	var note_idx: int = midi % 12
	return "%s%d (%d)" % [NOTE_NAMES[note_idx], octave, midi]

## Positions node to match the Diagnostic Dock safe zone (Y = 480..610)
func snap_to_diagnostic_dock_zone(parent_width: float = 1280.0) -> void:
	position.y = DOCK_Y_MIN
	size.y = DOCK_HEIGHT
	if parent_width > 0.0:
		size.x = parent_width

## Returns the diagnostic dock safe rect
func get_dock_rect() -> Rect2:
	return Rect2(position.x, DOCK_Y_MIN, size.x, DOCK_HEIGHT)

# --- Drawing Implementation ---

func _draw() -> void:
	var rect: Rect2 = Rect2(Vector2.ZERO, size)
	if rect.size.x < 40.0 or rect.size.y < 30.0:
		return

	var scope_left: float = 4.0
	var scope_top: float = 2.0
	var vu_width: float = 22.0 if show_vu_meter else 0.0
	var vu_gap: float = 6.0 if show_vu_meter else 0.0
	var scope_w: float = maxf(20.0, rect.size.x - vu_width - vu_gap - scope_left - 2.0)
	var scope_h: float = maxf(20.0, rect.size.y - 4.0)
	var scope_rect := Rect2(scope_left, scope_top, scope_w, scope_h)

	# 1. Background CRT Panel
	draw_rect(scope_rect, COLOR_CRT_BG, true)

	# 2. Graticule Grid Lines
	var center_y: float = scope_top + scope_h * 0.5
	var usable_half_h: float = (scope_h - 32.0) * 0.5

	# Horizontal division lines (+1.0, +0.5, 0.0, -0.5, -1.0)
	for frac in [-1.0, -0.5, 0.0, 0.5, 1.0]:
		var y: float = center_y - frac * usable_half_h
		var col: Color = COLOR_GRID_CENTER if is_zero_approx(frac) else COLOR_GRID_LINE
		draw_line(Vector2(scope_left, y), Vector2(scope_left + scope_w, y), col, 1.0)

	# Vertical time division lines (8 divisions)
	for div_i in range(1, 8):
		var x: float = scope_left + scope_w * (float(div_i) / 8.0)
		draw_line(Vector2(x, scope_top), Vector2(x, scope_top + scope_h), COLOR_GRID_LINE, 1.0)

	# 3. Noise Gate Threshold Guides
	var gate_vis: float = clampf(rms_threshold * current_display_gain, 0.02, 0.95)
	var gate_y_top: float = center_y - gate_vis * usable_half_h
	var gate_y_bot: float = center_y + gate_vis * usable_half_h
	draw_dashed_line(Vector2(scope_left, gate_y_top), Vector2(scope_left + scope_w, gate_y_top), COLOR_GATE_GUIDE, 1.0, 5.0)
	draw_dashed_line(Vector2(scope_left, gate_y_bot), Vector2(scope_left + scope_w, gate_y_bot), COLOR_GATE_GUIDE, 1.0, 5.0)

	# 4. Triggered Time-Domain Waveform Trace
	var n_buf: int = waveform_buffer.size()
	if n_buf >= 2:
		var trig: int = _find_trigger_offset()
		var count: int = mini(DISPLAY_SAMPLES, n_buf - trig)
		if count >= 2:
			var pts := PackedVector2Array()
			pts.resize(count)
			for i in range(count):
				var px: float = scope_left + (float(i) / float(count - 1)) * (scope_w - 6.0) + 3.0
				var sample_val: float = clampf(waveform_buffer[trig + i] * current_display_gain, -1.05, 1.05)
				var py: float = center_y - sample_val * usable_half_h
				pts[i] = Vector2(px, py)

			var trace_core: Color = COLOR_TRACE_ACTIVE if not is_gated else trace_color
			var trace_glow: Color = COLOR_TRACE_GLOW if is_gated else Color(0.15, 1.0, 0.55, 0.30)

			draw_polyline(pts, trace_glow, 5.0, true)
			draw_polyline(pts, trace_core, 2.0, true)

	# Outer border of scope
	var border_col: Color = Color(0.15, 0.95, 0.55, 0.85) if not is_gated else Color(0.25, 0.40, 0.58, 0.85)
	draw_rect(scope_rect, border_col, false, 1.5)

	# 5. Telemetry Overlay Labels inside Scope
	if show_telemetry_text:
		var font: Font = ThemeDB.fallback_font
		if font != null:
			# Top header (clamped width so it never collides with gate status on the right)
			var header_str: String = "OSCILLOSCOPE  [%d Hz]" % sample_rate
			if not backend_name.is_empty():
				header_str += "  (%s)" % backend_name
			var max_header_w: float = maxf(80.0, scope_w - 165.0)
			draw_string(font, Vector2(scope_left + 8.0, scope_top + 14.0), header_str, HORIZONTAL_ALIGNMENT_LEFT, max_header_w, 11, Color(0.75, 0.88, 1.0, 0.90))

			var gate_str: String = "GATE: OPEN" if not is_gated else "GATE: MUTED (< -46 dB)"
			var gate_text_col: Color = Color(0.2, 1.0, 0.5, 0.95) if not is_gated else Color(1.0, 0.72, 0.25, 0.85)
			draw_string(font, Vector2(maxf(scope_left + 8.0, scope_left + scope_w - 150.0), scope_top + 14.0), gate_str, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, gate_text_col)

			# Bottom telemetry: RMS, Peak, Estimated Frequency
			var db_display: String = "%.1f dB" % maxf(-60.0, current_rms_db) if current_rms_db > -90.0 else "-INF dB"
			var freq_display: String = "  |  ~%.1f Hz" % estimated_freq_hz if estimated_freq_hz >= 30.0 and estimated_freq_hz <= 2500.0 else ""
			var bottom_left: String = "RMS: %s  |  Peak: %.3f%s" % [db_display, peak_amplitude, freq_display]

			# Pitch readout
			if not active_pitches.is_empty():
				var pitch_strings: Array[String] = []
				for p in active_pitches:
					var conf_val: float = float(confidence_map.get(p, 0.0))
					if conf_val > 0.01:
						pitch_strings.append("%s [%d%%]" % [midi_to_note_name(p), int(conf_val * 100.0)])
					else:
						pitch_strings.append(midi_to_note_name(p))
				var pitch_str: String = "Chord: " + ", ".join(pitch_strings) if pitch_strings.size() > 1 else "Note: " + pitch_strings[0]
				bottom_left += "  |  " + pitch_str

			var max_bottom_w: float = maxf(80.0, scope_w - 90.0)
			draw_string(font, Vector2(scope_left + 8.0, scope_top + scope_h - 6.0), bottom_left, HORIZONTAL_ALIGNMENT_LEFT, max_bottom_w, 11, Color(0.80, 0.90, 1.0, 0.88))
			draw_string(font, Vector2(maxf(scope_left + 8.0, scope_left + scope_w - 75.0), scope_top + scope_h - 6.0), "Gain: %.1fx" % current_display_gain, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.65, 0.78, 0.92, 0.80))

	# 6. Vertical VU Level Meter Bar on the Right
	if show_vu_meter:
		var vu_rect := Rect2(scope_left + scope_w + vu_gap, scope_top, vu_width, scope_h)
		draw_rect(vu_rect, Color(0.04, 0.06, 0.10, 0.95), true)

		# Normalize dB from [-60..0] to [0..1]
		var db_norm: float = clampf((current_rms_db + 60.0) / 60.0, 0.0, 1.0)
		var fill_h: float = (scope_h - 4.0) * db_norm
		if fill_h > 1.0:
			var fill_rect := Rect2(vu_rect.position.x + 2.0, scope_h - 2.0 - fill_h, vu_width - 4.0, fill_h)
			var bar_col: Color = Color(0.15, 0.95, 0.50, 0.95)
			if current_rms_db > -6.0:
				bar_col = Color(1.0, 0.25, 0.30, 0.95)
			elif current_rms_db > -18.0:
				bar_col = Color(1.0, 0.84, 0.15, 0.95)
			elif is_gated:
				bar_col = Color(0.30, 0.65, 0.90, 0.70)
			draw_rect(fill_rect, bar_col, true)

		# Gate threshold tick on VU bar (-46 dB -> (60 - 46)/60 = 0.233)
		var gate_db_norm: float = clampf((20.0 * log(maxf(0.00001, rms_threshold)) / log(10.0) + 60.0) / 60.0, 0.0, 1.0)
		var gate_vu_y: float = scope_h - 2.0 - (scope_h - 4.0) * gate_db_norm
		draw_line(Vector2(vu_rect.position.x, gate_vu_y), Vector2(vu_rect.position.x + vu_width, gate_vu_y), Color(1.0, 0.72, 0.15, 0.90), 2.0)

		# Peak Hold Line on VU bar
		var peak_norm: float = clampf((peak_db_hold + 60.0) / 60.0, 0.0, 1.0)
		if peak_norm > 0.02:
			var pk_y: float = scope_h - 2.0 - (scope_h - 4.0) * peak_norm
			draw_line(Vector2(vu_rect.position.x + 1.0, pk_y), Vector2(vu_rect.position.x + vu_width - 1.0, pk_y), Color(1.0, 1.0, 1.0, 0.95), 2.0)

		draw_rect(vu_rect, Color(0.25, 0.40, 0.58, 0.85), false, 1.5)
