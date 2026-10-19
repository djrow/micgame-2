class_name NoteRenderer
extends Node2D

## High-performance CanvasItem renderer for Grand Staff notes, sustains, ledgers,
## accidentals, and chord stems for V2.
## Accurately positions notes according to diatonic steps and applies horizontal
## chord offsets for harmonic seconds.

const NOTE_RADIUS: float = 8.5
const LEDGER_WIDTH: float = 28.0
const SUSTAIN_HEIGHT: float = 10.0

@export var treble_color: Color = Color(0.0, 0.85, 1.0, 1.0) # Bright Cyan
@export var bass_color: Color = Color(1.0, 0.65, 0.1, 1.0)   # Neon Amber
@export var hit_color: Color = Color(0.2, 0.9, 0.4, 0.8)     # Bright Green / Scored Hit
@export var miss_color: Color = Color(0.6, 0.2, 0.2, 0.4)    # Dim Red / Missed
@export var ledger_color: Color = Color(0.5, 0.6, 0.7, 0.85) # Staff Line Slate
@export var outline_color: Color = Color(1.0, 1.0, 1.0, 0.95)
@export var holding_color: Color = Color(1.0, 0.85, 0.2, 0.85) # Gold Amber

var active_notes: Array[NoteData] = []
var current_song_time: float = 0.0
var x_hit: float = 160.0
var scroll_speed: float = 400.0

func update_notes(notes: Array[NoteData], song_time: float, p_x_hit: float, p_scroll_speed: float) -> void:
	active_notes = notes
	current_song_time = song_time
	x_hit = p_x_hit
	scroll_speed = p_scroll_speed
	queue_redraw()

func _draw() -> void:
	if active_notes.is_empty():
		return

	var font: Font = ThemeDB.fallback_font
	var viewport_w: float = get_viewport_rect().size.x
	if viewport_w <= 0.0:
		viewport_w = 1280.0
	var min_draw_x: float = 28.0
	var max_draw_x: float = maxf(200.0, viewport_w - 20.0)

	# Pass 1: Draw sustain trails
	for note in active_notes:
		if note.duration_sec > 0.05:
			_draw_sustain_tail(note, min_draw_x, max_draw_x)

	# Pass 2: Draw chord stems connecting notes at identical onsets
	_draw_chord_stems()

	# Pass 3: Draw dynamic ledger lines
	for note in active_notes:
		var head_x: float = x_hit + (note.time_sec - current_song_time) * scroll_speed + note.chord_offset_x
		if head_x < min_draw_x or head_x > max_draw_x:
			continue
		for ly in note.ledger_y_positions:
			draw_line(
				Vector2(head_x - LEDGER_WIDTH * 0.5, ly),
				Vector2(head_x + LEDGER_WIDTH * 0.5, ly),
				ledger_color,
				2.0
			)

	# Pass 4: Draw accidentals (#)
	for note in active_notes:
		if note.is_accidental:
			var head_x: float = x_hit + (note.time_sec - current_song_time) * scroll_speed + note.chord_offset_x
			if head_x < min_draw_x or head_x > max_draw_x:
				continue
			_draw_sharp(Vector2(head_x - 16.0, note.y_pos), outline_color)

	# Pass 5: Draw note heads & pitch labels
	for note in active_notes:
		var head_x: float = x_hit + (note.time_sec - current_song_time) * scroll_speed + note.chord_offset_x
		if head_x < min_draw_x or head_x > max_draw_x:
			continue
		_draw_note_head(note, font)

func _draw_sustain_tail(note: NoteData, min_draw_x: float = 28.0, max_draw_x: float = 1260.0) -> void:
	var raw_head_x: float = x_hit + (note.time_sec - current_song_time) * scroll_speed + note.chord_offset_x
	var raw_tail_x: float = raw_head_x + note.duration_sec * scroll_speed
	if raw_tail_x < min_draw_x or raw_head_x > max_draw_x:
		return
	var head_x: float = clampf(raw_head_x, min_draw_x, max_draw_x)
	var tail_x: float = clampf(raw_tail_x, min_draw_x, max_draw_x)
	var w: float = tail_x - head_x
	if w <= 1.0:
		return
	var rect: Rect2 = Rect2(head_x, note.y_pos - SUSTAIN_HEIGHT * 0.5, w, SUSTAIN_HEIGHT)

	var is_holding: bool = (raw_head_x <= x_hit and raw_tail_x >= x_hit and note.is_hit)
	var fill_color: Color
	if note.is_missed:
		fill_color = miss_color
	elif is_holding:
		fill_color = holding_color
	elif note.is_hit:
		fill_color = Color(0.2, 0.9, 0.4, 0.5)
	else:
		fill_color = Color(0.0, 0.75, 1.0, 0.35) if note.staff == "treble" else Color(1.0, 0.6, 0.1, 0.35)

	draw_rect(rect, fill_color, true)
	var border_color: Color = Color(1.0, 0.85, 0.2, 0.9) if is_holding else (
		Color(0.0, 0.85, 1.0, 0.8) if note.staff == "treble" else Color(1.0, 0.65, 0.2, 0.8)
	)
	draw_rect(rect, border_color, false, 1.5)

	# Rounded tail end cap if not clipped on right
	if raw_tail_x <= max_draw_x:
		draw_circle(Vector2(tail_x, note.y_pos), SUSTAIN_HEIGHT * 0.5, fill_color)
		draw_arc(Vector2(tail_x, note.y_pos), SUSTAIN_HEIGHT * 0.5, -PI * 0.5, PI * 0.5, 8, border_color, 1.5)

func _draw_chord_stems() -> void:
	var chord_groups: Dictionary = {}
	for note in active_notes:
		var key: int = int(round(note.time_sec * 1000.0))
		if not chord_groups.has(key):
			chord_groups[key] = []
		chord_groups[key].append(note)

	for key in chord_groups:
		var group: Array = chord_groups[key]
		if group.size() > 1:
			var min_y: float = 9999.0
			var max_y: float = -9999.0
			var first_x: float = 0.0
			for n in group:
				min_y = minf(min_y, n.y_pos)
				max_y = maxf(max_y, n.y_pos)
				first_x = x_hit + (n.time_sec - current_song_time) * scroll_speed

			if max_y - min_y >= 8.0:
				draw_line(
					Vector2(first_x + NOTE_RADIUS - 1.0, min_y),
					Vector2(first_x + NOTE_RADIUS - 1.0, max_y),
					outline_color,
					2.0
				)

func _draw_sharp(pos: Vector2, col: Color) -> void:
	# Two vertical bars
	draw_line(pos + Vector2(-4, -8), pos + Vector2(-4, 8), col, 1.5)
	draw_line(pos + Vector2(2, -8), pos + Vector2(2, 8), col, 1.5)
	# Two slightly tilted horizontal crossbars
	draw_line(pos + Vector2(-7, -2), pos + Vector2(5, -4), col, 2.0)
	draw_line(pos + Vector2(-7, 3), pos + Vector2(5, 1), col, 2.0)

func _draw_note_head(note: NoteData, font: Font) -> void:
	var head_x: float = x_hit + (note.time_sec - current_song_time) * scroll_speed + note.chord_offset_x
	var center: Vector2 = Vector2(head_x, note.y_pos)

	var base_color: Color = treble_color if note.staff == "treble" else bass_color
	var color: Color
	if note.is_hit:
		color = hit_color
	elif note.is_missed:
		color = miss_color
	else:
		color = base_color

	# Outer outline & filled body
	draw_circle(center, NOTE_RADIUS, color)
	draw_arc(center, NOTE_RADIUS, 0, TAU, 16, outline_color, 1.5)

	# Dark inner ring for classical notehead styling
	if not note.is_hit and not note.is_missed:
		draw_circle(center, NOTE_RADIUS - 2.5, Color(0.06, 0.08, 0.12, 0.85))
		draw_circle(center, NOTE_RADIUS - 4.5, color)
		# Specular highlight
		draw_circle(center + Vector2(-2.2, -2.2), 2.0, Color(1.0, 1.0, 1.0, 0.8))

	# Pitch label above/below notehead
	if font:
		var label_y: float = note.y_pos - 11.0 if note.staff == "treble" else note.y_pos + 19.0
		draw_string(font, Vector2(head_x - 10.0, label_y), note.pitch_name, HORIZONTAL_ALIGNMENT_CENTER, -1, 10, Color(0.85, 0.9, 1.0, 0.85))
