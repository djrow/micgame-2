extends Node

## Centralized Audio Playback and Hardware Playhead Synchronization Singleton for V2.
## Manages accompaniment backing tracks and sound effects on the Master bus (Bus 0).
## Computes sub-frame interpolated hardware playhead timing:
##   song_time = get_playback_position() + get_time_since_last_mix() - get_output_latency() + audio_offset
## Strictly prohibits calling play() in _process() to prevent mobile engine stutter.

signal song_started(stream: AudioStream)
signal song_paused()
signal song_resumed()
signal song_stopped()
signal song_finished()
signal playhead_seeked(new_time: float)
signal loop_cycled(cycle_count: int)

const MASTER_BUS_NAME: StringName = &"Master"
const RECORD_BUS_NAME: StringName = &"Record"

@export var audio_offset_sec: float = 0.0
@export var auto_loop: bool = true

var master_bus_idx: int = 0
var record_bus_idx: int = 1

var is_playing: bool = false
var is_paused: bool = false
var current_song_time: float = 0.0
var song_duration: float = 0.0
var loop_count: int = 0

var _last_playback_pos: float = 0.0
var _music_player: AudioStreamPlayer = null
var _sfx_player: AudioStreamPlayer = null
var _current_stream: AudioStream = null

func _init() -> void:
	_setup_bus_indices()

func _ready() -> void:
	_setup_players()

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if _music_player != null:
			if _music_player.playing:
				_music_player.stop()
			_music_player.stream = null
		if _sfx_player != null:
			if _sfx_player.playing:
				_sfx_player.stop()
			_sfx_player.stream = null
		_current_stream = null

func _setup_bus_indices() -> void:
	master_bus_idx = AudioServer.get_bus_index(MASTER_BUS_NAME)
	if master_bus_idx == -1:
		master_bus_idx = 0
	record_bus_idx = AudioServer.get_bus_index(RECORD_BUS_NAME)
	if record_bus_idx == -1:
		record_bus_idx = 1
	if master_bus_idx >= 0:
		AudioServer.set_bus_mute(master_bus_idx, false)
		AudioServer.set_bus_volume_db(master_bus_idx, 0.0)

func _setup_players() -> void:
	if _music_player == null:
		_music_player = AudioStreamPlayer.new()
		_music_player.name = "MusicPlayer"
		_music_player.bus = MASTER_BUS_NAME
		_music_player.finished.connect(_on_music_finished)
		add_child(_music_player)

	if _sfx_player == null:
		_sfx_player = AudioStreamPlayer.new()
		_sfx_player.name = "SFXPlayer"
		_sfx_player.bus = MASTER_BUS_NAME
		add_child(_sfx_player)

## Loads audio streams using ResourceLoader with runtime FileAccess fallback
func load_audio_stream(audio_path: String) -> AudioStream:
	if audio_path.is_empty():
		return null

	# 1. ResourceLoader fast-path for editor imports / APK / PCK (.sample)
	if ResourceLoader.has_cached(audio_path) or ResourceLoader.exists(audio_path):
		var res: Resource = load(audio_path)
		if res is AudioStream:
			_configure_stream_loop(res)
			return res

	# 2. Check localized and globalized filesystem paths for loose runtime files
	var abs_path: String = ProjectSettings.globalize_path(audio_path)
	var resolved_path: String = audio_path
	if not FileAccess.file_exists(resolved_path):
		if FileAccess.file_exists(abs_path):
			resolved_path = abs_path
		else:
			push_error("AudioManager: Audio file not found: " + audio_path)
			return null

	# 3. Read loose file bytes
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(resolved_path)
	if bytes.is_empty():
		push_error("AudioManager: Audio file empty or could not be read: " + resolved_path)
		return null

	var ext: String = resolved_path.get_extension().to_lower()
	if ext == "wav":
		var wav: AudioStreamWAV = _load_wav_from_bytes(bytes)
		if wav:
			_configure_stream_loop(wav)
		return wav
	elif ext == "ogg":
		var ogg = AudioStreamOggVorbis.load_from_buffer(bytes)
		if ogg:
			_configure_stream_loop(ogg)
		return ogg
	elif ext == "mp3":
		var mp3: AudioStreamMP3 = AudioStreamMP3.new()
		mp3.data = bytes
		_configure_stream_loop(mp3)
		return mp3
	else:
		push_error("AudioManager: Unsupported audio format: " + ext)
		return null

func _configure_stream_loop(stream: AudioStream) -> void:
	if stream is AudioStreamWAV:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	elif stream is AudioStreamOggVorbis:
		stream.loop = true
	elif stream is AudioStreamMP3:
		stream.loop = true

func _load_wav_from_bytes(data: PackedByteArray) -> AudioStreamWAV:
	if data.size() < 44:
		push_error("AudioManager: WAV byte buffer too small for RIFF header.")
		return null

	var riff: String = data.slice(0, 4).get_string_from_ascii()
	var wave: String = data.slice(8, 12).get_string_from_ascii()
	if riff != "RIFF" or wave != "WAVE":
		push_error("AudioManager: Invalid RIFF WAVE header.")
		return null

	var channels: int = 1
	var sample_rate: int = 44100
	var bits_per_sample: int = 16
	var audio_format: int = 1
	var audio_data_start: int = 44
	var audio_data_len: int = data.size() - 44

	var offset: int = 12
	while offset + 8 <= data.size():
		var chunk_id: String = data.slice(offset, offset + 4).get_string_from_ascii()
		var chunk_size: int = data.decode_u32(offset + 4)
		offset += 8
		if chunk_size < 0:
			break

		var padded_chunk_size: int = (chunk_size + 1) & ~1
		if chunk_id == "fmt ":
			if offset + 16 <= data.size():
				audio_format = data.decode_u16(offset)
				channels = maxi(1, data.decode_u16(offset + 2))
				sample_rate = maxi(8000, data.decode_u32(offset + 4))
				bits_per_sample = data.decode_u16(offset + 14)
			offset += padded_chunk_size
		elif chunk_id == "data":
			audio_data_start = offset
			audio_data_len = chunk_size
			offset += padded_chunk_size
			break
		else:
			offset += padded_chunk_size

	var wav: AudioStreamWAV = AudioStreamWAV.new()
	wav.mix_rate = sample_rate
	wav.stereo = (channels >= 2)
	if bits_per_sample == 8:
		wav.format = AudioStreamWAV.FORMAT_8_BITS
	elif bits_per_sample == 16:
		wav.format = AudioStreamWAV.FORMAT_16_BITS
	else:
		wav.format = AudioStreamWAV.FORMAT_16_BITS

	var safe_start: int = clampi(audio_data_start, 0, data.size())
	var safe_end: int = clampi(safe_start + maxi(0, audio_data_len), safe_start, data.size())
	wav.data = data.slice(safe_start, safe_end)
	return wav

func play_music(stream: AudioStream = null, loop: bool = true, start_time: float = 0.0) -> void:
	if stream != null:
		_current_stream = stream
		_configure_stream_loop(_current_stream)
		if _music_player:
			_music_player.stream = _current_stream
		song_duration = _current_stream.get_length()

	if _music_player == null or _music_player.stream == null:
		push_error("AudioManager: Cannot play music; no stream loaded.")
		return

	auto_loop = loop
	current_song_time = maxf(0.0, start_time)
	_last_playback_pos = current_song_time
	is_playing = true
	is_paused = false

	if is_inside_tree():
		_music_player.play(current_song_time)
		song_started.emit(_music_player.stream)

func pause_music() -> void:
	if not is_playing or is_paused:
		return
	is_paused = true
	if _music_player and _music_player.playing:
		_music_player.stop()
	song_paused.emit()

func resume_music() -> void:
	if not is_paused:
		return
	is_paused = false
	if _music_player and is_inside_tree():
		_music_player.play(current_song_time)
		song_resumed.emit()

func stop_music() -> void:
	is_playing = false
	is_paused = false
	current_song_time = 0.0
	_last_playback_pos = 0.0
	if _music_player and _music_player.playing:
		_music_player.stop()
	song_stopped.emit()

func seek(target_time: float) -> void:
	target_time = maxf(0.0, target_time)
	current_song_time = target_time
	_last_playback_pos = target_time
	if _music_player and is_playing and not is_paused:
		_music_player.seek(target_time)
	playhead_seeked.emit(target_time)

func get_song_position() -> float:
	return current_song_time

func get_interpolated_playhead() -> float:
	return current_song_time

func play_sfx(stream: AudioStream, volume_db: float = 0.0) -> void:
	if _sfx_player == null or stream == null:
		return
	_sfx_player.stream = stream
	_sfx_player.volume_db = volume_db
	_sfx_player.play()

func set_master_volume_db(volume_db: float) -> void:
	AudioServer.set_bus_volume_db(master_bus_idx, volume_db)

func set_master_mute(mute: bool) -> void:
	AudioServer.set_bus_mute(master_bus_idx, mute)

func get_master_volume_db() -> float:
	return AudioServer.get_bus_volume_db(master_bus_idx)

func is_master_muted() -> bool:
	return AudioServer.is_bus_mute(master_bus_idx)

func _process(delta: float) -> void:
	if not is_playing or is_paused:
		return

	# Playhead calculation via hardware sub-frame interpolation:
	# song_time = playback_pos + time_since_last_mix - latency + audio_offset
	# Strictly NO calls to _music_player.play() inside _process()
	if _music_player and _music_player.playing:
		var pos: float = _music_player.get_playback_position()
		var time_since_mix: float = AudioServer.get_time_since_last_mix()
		var latency: float = AudioServer.get_output_latency()
		var calculated_time: float = pos + time_since_mix - latency + audio_offset_sec

		if pos < _last_playback_pos - 0.5:
			loop_count += 1
			current_song_time = maxf(0.0, calculated_time)
			loop_cycled.emit(loop_count)
		elif calculated_time >= current_song_time:
			current_song_time = calculated_time

		_last_playback_pos = pos
	else:
		# Fallback clock for headless mode / mock testing / audio server stopped
		current_song_time += delta

func _on_music_finished() -> void:
	if auto_loop:
		loop_count += 1
		current_song_time = 0.0
		_last_playback_pos = 0.0
		loop_cycled.emit(loop_count)
		if _music_player and is_inside_tree():
			_music_player.play(0.0)
	else:
		is_playing = false
		song_finished.emit()
