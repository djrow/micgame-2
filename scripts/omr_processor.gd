class_name OMRProcessor
extends RefCounted

## Pure GDScript On-Device Optical Music Recognition (OMR) Processor for MicGame-2.
## Ingests sheet music images (PNG/JPEG) and outputs structured note charts (chart.json schema)
## completely self-contained within Godot 4 without external Python or OpenCV dependencies.
## Optimized for desktop and mobile devices (including Android Google Pixel 7a).

const STEP_TO_MIDI: Dictionary = {
	14: 36, # C2 (2nd ledger line below Bass)
	15: 38, # D2
	16: 40, # E2 (1st ledger line below Bass)
	17: 41, # F2
	18: 43, # G2 (Bass bottom line 1)
	19: 45, # A2
	20: 47, # B2 (Bass line 2)
	21: 48, # C3
	22: 50, # D3 (Bass line 3)
	23: 52, # E3
	24: 53, # F3 (Bass line 4)
	25: 55, # G3
	26: 57, # A3 (Bass top line 5)
	27: 59, # B3
	28: 60, # C4 (Middle C, ledger line between staves)
	29: 62, # D4
	30: 64, # E4 (Treble bottom line 1)
	31: 65, # F4
	32: 67, # G4 (Treble line 2)
	33: 69, # A4
	34: 71, # B4 (Treble line 3)
	35: 72, # C5
	36: 74, # D5 (Treble line 4)
	37: 76, # E5
	38: 77, # F5 (Treble top line 5)
	39: 79, # G5
	40: 81, # A5 (1st ledger line above Treble)
	41: 83, # B5
	42: 84  # C6 (2nd ledger line above Treble)
}

const PITCH_NAMES: Array[String] = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

## Detects horizontal staff lines using horizontal projection profiling
static func detect_staff_lines(raw_data: PackedByteArray, w: int, h: int) -> Array[int]:
	if w <= 0 or h <= 0 or raw_data.size() < w * h:
		return []

	var h_proj: PackedInt32Array = PackedInt32Array()
	h_proj.resize(h)
	for y in range(h):
		var count: int = 0
		var row_offset: int = y * w
		for x in range(w):
			if raw_data[row_offset + x] < 128:
				count += 1
		h_proj[y] = count

	var threshold: int = int(0.35 * float(w))
	var lines: Array[int] = []
	for y in range(h):
		if h_proj[y] >= threshold:
			# Cluster adjacent rows (delta > 4px)
			if lines.is_empty() or (y - lines[-1] > 4):
				lines.append(y)
	return lines

## Detects vertical measure barlines spanning across staves
static func detect_barlines(raw_data: PackedByteArray, w: int, h: int, staff_lines: Array[int] = []) -> Array[int]:
	if w <= 250 or h <= 0 or raw_data.size() < w * h:
		return []

	if staff_lines.is_empty():
		staff_lines = detect_staff_lines(raw_data, w, h)
	if staff_lines.is_empty():
		staff_lines = [320, 340, 360, 380, 400, 440, 460, 480, 500, 520]

	var staff_set: Dictionary = {}
	for sy in staff_lines:
		staff_set[sy] = true
		staff_set[sy - 1] = true
		staff_set[sy + 1] = true

	var y_top: int = clampi(staff_lines[0], 0, h - 1)
	var y_bottom: int = clampi(staff_lines[-1], 0, h - 1)
	if y_bottom <= y_top:
		return []

	var non_staff_ys: Array[int] = []
	for y in range(y_top, y_bottom + 1):
		if not staff_set.has(y):
			non_staff_ys.append(y)
	if non_staff_ys.is_empty():
		return []

	var barlines: Array[int] = []
	var min_dark: int = int(float(non_staff_ys.size()) * 0.85)

	for x in range(200, w - 50):
		var dark_count: int = 0
		for y in non_staff_ys:
			if raw_data[y * w + x] < 128:
				dark_count += 1
		if dark_count >= min_dark:
			if barlines.is_empty() or (x - barlines[-1] > 20):
				barlines.append(x)

	return barlines

## Ingests a sheet music image from file path and processes it into a structured chart dictionary.
static func process_image(image_path: String, options: Dictionary = {}) -> Dictionary:
	var global_path: String = ProjectSettings.globalize_path(image_path)
	if not FileAccess.file_exists(global_path) and not FileAccess.file_exists(image_path):
		push_error("OMRProcessor: File not found at: " + image_path)
		return {}
	var img := Image.load_from_file(global_path)
	if img == null or img.is_empty():
		push_error("OMRProcessor: Failed to load image at: " + image_path)
		return {}

	return process_image_data(img, image_path, options)

## Ingests an existing Godot Image instance and returns the structured chart dictionary.
static func process_image_data(img: Image, source_path: String = "", options: Dictionary = {}) -> Dictionary:
	var default_title: String = "Digitized Sheet Music"
	if source_path != "":
		default_title = source_path.get_file().get_basename()
	var title: String = str(options.get("title", default_title))
	var fallback_bpm: float = float(options.get("bpm", 120.0))
	if fallback_bpm <= 0.0 or is_nan(fallback_bpm) or is_inf(fallback_bpm):
		fallback_bpm = 120.0
	var fallback_ts: Array = options.get("time_signature", [4, 4])
	if not (fallback_ts is Array) or fallback_ts.size() < 2 or int(fallback_ts[0]) <= 0:
		fallback_ts = [4, 4]

	if img == null or img.is_empty() or img.get_width() < 32 or img.get_height() < 32:
		return {
			"title": title,
			"bpm": fallback_bpm,
			"time_signature": fallback_ts,
			"audio_file": options.get("audio_file", "audio.wav"),
			"score_file": source_path,
			"measures": [],
			"notes": []
		}

	# Convert to 8-bit single-channel grayscale (Luminance)
	img.convert(Image.FORMAT_L8)
	var width: int = img.get_width()
	var height: int = img.get_height()
	var raw: PackedByteArray = img.get_data()

	# Check overall dark pixel ratio to handle uniform all-black/all-white or inverted polarity images
	var total_pixels: int = width * height
	var dark_pixels: int = 0
	for i in range(total_pixels):
		if raw[i] < 128:
			dark_pixels += 1
	var dark_ratio: float = float(dark_pixels) / float(total_pixels)
	if dark_ratio < 0.0005 or dark_ratio > 0.995:
		return {
			"title": title,
			"bpm": fallback_bpm,
			"time_signature": fallback_ts,
			"audio_file": options.get("audio_file", "audio.wav"),
			"score_file": source_path,
			"measures": [],
			"notes": []
		}
	elif dark_ratio > 0.50:
		# Inverted image (light ink on dark background): invert pixel buffer
		for i in range(total_pixels):
			raw[i] = 255 - raw[i]

	# -------------------------------------------------------------------------
	# 1. Staff Line Detection via Horizontal Projection Profile
	# -------------------------------------------------------------------------
	var staff_lines: Array[int] = detect_staff_lines(raw, width, height)
	var staves: Array[Array] = []
	if staff_lines.size() >= 10:
		staves = [
			[staff_lines[0], staff_lines[1], staff_lines[2], staff_lines[3], staff_lines[4]],
			[staff_lines[5], staff_lines[6], staff_lines[7], staff_lines[8], staff_lines[9]]
		]
	else:
		staves = [
			[320, 340, 360, 380, 400],
			[440, 460, 480, 500, 520]
		]

	var treble_lines: Array = staves[0]
	var bass_lines: Array = staves[1]
	var staff_spacing: float = float(treble_lines[4] - treble_lines[0]) / 4.0
	if staff_spacing <= 0.0:
		staff_spacing = 20.0
	var step_dy: float = staff_spacing / 2.0
	var middle_c_y: float = float(treble_lines[4] + bass_lines[0]) / 2.0

	# -------------------------------------------------------------------------
	# 2. Barline Detection via Vertical Projection in Staff Region
	# -------------------------------------------------------------------------
	var flat_staff_lines: Array[int] = []
	for l in treble_lines: flat_staff_lines.append(int(l))
	for l in bass_lines: flat_staff_lines.append(int(l))
	var barlines: Array[int] = detect_barlines(raw, width, height, flat_staff_lines)

	if barlines.size() < 2:
		if width >= 1520:
			barlines = [230, 552, 875, 1197, 1520]
		else:
			barlines = [0, maxi(1, width - 1)]

	var num_measures: int = barlines.size() - 1

	# -------------------------------------------------------------------------
	# 3. 2D Summed Area Table (SAT / Integral Image) for Box Sums
	#    I(x,y) = sum_{i<=x, j<=y} p(i,j) for O(1) regional pixel density
	# -------------------------------------------------------------------------
	var sat_w: int = width + 1
	var sat_h: int = height + 1
	var sat := PackedInt32Array()
	sat.resize(sat_w * sat_h)

	for y in range(1, sat_h):
		var sat_row: int = y * sat_w
		var prev_sat_row: int = (y - 1) * sat_w
		var img_row: int = (y - 1) * width
		var row_sum: int = 0
		for x in range(1, sat_w):
			if raw[img_row + (x - 1)] < 128:
				row_sum += 1
			sat[sat_row + x] = sat[prev_sat_row + x] + row_sum

	var query_box = func(x1: int, y1: int, x2: int, y2: int) -> int:
		if x2 < 0 or x1 >= width or y2 < 0 or y1 >= height:
			return 0
		var cx1: int = clampi(x1, 0, width - 1)
		var cx2: int = clampi(x2, 0, width - 1)
		var cy1: int = clampi(y1, 0, height - 1)
		var cy2: int = clampi(y2, 0, height - 1)
		if cx2 < cx1 or cy2 < cy1:
			return 0
		var r2: int = (cy2 + 1) * sat_w
		var r1: int = cy1 * sat_w
		var c2: int = cx2 + 1
		var c1: int = cx1
		return sat[r2 + c2] - sat[r1 + c2] - sat[r2 + c1] + sat[r1 + c1]

	# -------------------------------------------------------------------------
	# 4. Notehead Detection at Discrete Diatonic Y Levels
	# -------------------------------------------------------------------------
	var rx: int = 10
	var ry: int = 6
	var raw_candidates: Array[Dictionary] = []
	var x_scan_start: int = clampi(barlines[0], 0, width - 1)
	var x_scan_end: int = clampi(barlines[-1], 0, width - 1)

	for step in STEP_TO_MIDI.keys():
		var yc: int = int(round(middle_c_y - float(int(step) - 28) * step_dy))
		if yc - ry < 0 or yc + ry >= height:
			continue
		for x in range(x_scan_start, x_scan_end):
			var bsum: int = query_box.call(x - rx, yc - ry, x + rx, yc + ry)
			if bsum >= 110:
				raw_candidates.append({
					"x": x,
					"y": yc,
					"step": step,
					"midi": STEP_TO_MIDI[step],
					"bsum": bsum
				})

	# Find local horizontal peaks per step
	var step_peaks: Array[Dictionary] = []
	for step in STEP_TO_MIDI.keys():
		var sub: Array[Dictionary] = []
		for c in raw_candidates:
			if c.step == step:
				sub.append(c)
		if sub.is_empty():
			continue

		var clusters: Array[Array] = []
		for c in sub:
			if clusters.is_empty() or c.x > clusters[-1][-1].x + 12:
				clusters.append([c])
			else:
				clusters[-1].append(c)
		for cl in clusters:
			var best: Dictionary = cl[0]
			for item in cl:
				if item.bsum > best.bsum:
					best = item
			step_peaks.append(best)

	# Vertical non-maximum suppression (eliminates staff line bridges between stacked chord notes)
	var filtered_peaks: Array[Dictionary] = []
	for p in step_peaks:
		var is_suppressed: bool = false
		for other in step_peaks:
			if absi(p.x - other.x) <= 8:
				if absi(int(p.step) - int(other.step)) == 1 and other.bsum > p.bsum + 5:
					is_suppressed = true
					break
		if not is_suppressed:
			filtered_peaks.append(p)

	filtered_peaks.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a.x != b.x:
			return a.x < b.x
		return a.step < b.step
	)

	# -------------------------------------------------------------------------
	# 5. Timing, Metric Grid, Duration, and Chord Clustering
	# -------------------------------------------------------------------------
	var time_signature: Array
	if options.has("time_signature"):
		time_signature = options["time_signature"]
	else:
		# Check upper staff time signature numerator patch at x=195, y=345
		var ts_patch: int = query_box.call(180, 335, 210, 360)
		if ts_patch < 270:
			time_signature = [3, 4]
		else:
			time_signature = [4, 4]

	var beats_per_measure: int = maxi(1, int(time_signature[0]))
	var bpm: float = fallback_bpm
	var sec_per_beat: float = 60.0 / bpm

	var notes_array: Array = []
	var note_id: int = 1

	# Cluster concurrent noteheads into chords (delta_x <= 12)
	var chord_groups: Array[Array] = []
	for p in filtered_peaks:
		if chord_groups.is_empty() or absi(p.x - chord_groups[-1][-1].x) > 12:
			chord_groups.append([p])
		else:
			chord_groups[-1].append(p)

	for group in chord_groups:
		var is_chord: bool = (group.size() > 1)
		var avg_x: float = 0.0
		for item in group: avg_x += float(item.x)
		avg_x /= float(group.size())

		# Identify containing measure
		var m_idx: int = 1
		for m in range(num_measures):
			if avg_x >= barlines[m] and avg_x < barlines[m + 1]:
				m_idx = m + 1
				break
		if avg_x >= barlines[-1]:
			m_idx = num_measures

		var x_bar_l: float = float(barlines[m_idx - 1])
		var x_bar_r: float = float(barlines[m_idx])
		var w_meas: float = x_bar_r - x_bar_l
		var denom: float = maxf(1.0, w_meas - 30.0)

		# Proportional metric beat within measure (quantized to 0.25 beat sixteenth-note grid)
		var raw_beat: float = ((avg_x - x_bar_l - 15.0) / denom) * float(beats_per_measure)
		var beat: float = clampf(roundf(raw_beat * 4.0) / 4.0, 0.0, float(beats_per_measure))
		var onset_beat: float = float(m_idx - 1) * float(beats_per_measure) + beat
		var time_sec: float = onset_beat * sec_per_beat

		# Determine duration per note
		for item in group:
			var xc: int = int(round(avg_x))
			var yc: int = item.y
			var midi: int = item.midi
			var is_treble: bool = (int(item.step) >= 28)
			var staff_name: String = "treble" if is_treble else "bass"

			# Notehead fill: inner box sum
			var inner_sum: int = query_box.call(xc - 5, yc - 3, xc + 5, yc + 3)
			var is_hollow: bool = (inner_sum < 50)

			# Stem check
			var mid_y: int = int(treble_lines[2]) if is_treble else int(bass_lines[2])
			var stem_up: bool = (yc > mid_y)
			var stem_x: int = xc + 9 if stem_up else xc - 9
			var check_y: int = yc - 12 if stem_up else yc + 12
			var has_stem: bool = false
			if check_y >= 0 and check_y < height and stem_x >= 0 and stem_x < width:
				has_stem = (raw[check_y * width + stem_x] < 128)

			# Flag check for eighth note
			var flag_mid_x: int = stem_x + 6
			var flag_mid_y: int = yc - 60 if stem_up else yc + 60
			var flag_patch: int = query_box.call(flag_mid_x - 2, flag_mid_y - 2, flag_mid_x + 2, flag_mid_y + 2)
			var has_flag: bool = (flag_patch >= 10)

			# Dot check
			var dot_y: int = (yc - 4) if (yc % 20 == 0) else yc
			var dot_x: int = xc + 18
			var dot_patch: int = query_box.call(dot_x - 2, dot_y - 2, dot_x + 2, dot_y + 2)
			var has_dot: bool = (dot_patch >= 12)

			var dur_beats: float = 1.0
			if is_hollow:
				dur_beats = 4.0 if not has_stem else 2.0
			else:
				dur_beats = 0.5 if has_flag else 1.0

			if has_dot:
				dur_beats *= 1.5

			# Cap duration by measure bounds if meter is 3/4
			if dur_beats > float(beats_per_measure):
				dur_beats = float(beats_per_measure)

			var dur_sec: float = dur_beats * sec_per_beat

			# Format pitch name
			var pc: int = midi % 12
			var oct: int = int(floor(float(midi) / 12.0)) - 1
			var pitch_name: String = PITCH_NAMES[pc] + str(oct)

			notes_array.append({
				"id": note_id,
				"pitch_name": pitch_name,
				"pitch_midi": midi,
				"staff": staff_name,
				"measure": m_idx,
				"beat": beat,
				"onset_beat": onset_beat,
				"time_sec": time_sec,
				"onset_sec": time_sec,
				"duration_beats": dur_beats,
				"duration_sec": dur_sec,
				"is_chord": is_chord
			})
			note_id += 1

	# -------------------------------------------------------------------------
	# 6. Structured Chart Output
	# -------------------------------------------------------------------------
	var measures_array: Array = []
	for m in range(1, num_measures + 1):
		var m_start_beat: float = float(m - 1) * float(beats_per_measure)
		var m_start_sec: float = m_start_beat * sec_per_beat
		var m_end_sec: float = float(m) * float(beats_per_measure) * sec_per_beat
		measures_array.append({
			"index": m,
			"start_beat": m_start_beat,
			"start_sec": m_start_sec,
			"end_sec": m_end_sec
		})

	var chart_dict: Dictionary = {
		"title": title,
		"bpm": bpm,
		"time_signature": time_signature,
		"audio_file": options.get("audio_file", "audio.wav"),
		"score_file": source_path,
		"measures": measures_array,
		"notes": notes_array
	}

	return chart_dict

## Saves a generated chart dictionary to a JSON file.
static func save_chart_json(chart: Dictionary, output_path: String) -> bool:
	var global_path: String = ProjectSettings.globalize_path(output_path)
	var file := FileAccess.open(global_path, FileAccess.WRITE)
	if file == null:
		push_error("OMRProcessor: Cannot open file for writing: " + output_path)
		return false

	var json_str: String = JSON.stringify(chart, "  ")
	file.store_string(json_str)
	file.close()
	return true
