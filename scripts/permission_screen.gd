class_name PermissionScreen
extends CanvasLayer

## PermissionScreen: Mobile-Safe Audio Permission Gate for V2.
## Gates audio playback and microphone capture on Android / iOS / Web until
## RECORD_AUDIO permission is granted or explicitly acknowledged by the user.
## Provides automatic bypass or clean confirmation start on desktop / headless test environments.
## Features dynamic mobile safe-area padding querying DisplayServer.get_display_safe_area().

signal permission_granted()
signal permission_denied()
signal flow_completed()
signal skip_requested()

# Configuration
@export var auto_pass_desktop: bool = false # If true, desktop automatically skips gate without button click
@export var auto_pass_headless: bool = true # Headless test suites always auto-pass to prevent hanging
@export var default_status_text: String = "Status: Microphone permission required"

# State
var is_permission_granted: bool = false
var is_flow_active: bool = true

# Node references (supports both .tscn instantiation and runtime programmatic creation)
var dimmer: ColorRect = null
var safe_margin: MarginContainer = null
var modal_card: PanelContainer = null
var title_label: Label = null
var subtitle_label: Label = null
var description_label: Label = null
var status_pill: PanelContainer = null
var status_label: Label = null
var request_button: Button = null
var start_button: Button = null
var skip_button: Button = null

func _init() -> void:
	layer = 10 # High render priority over HUD and Highway

func _ready() -> void:
	_resolve_or_build_ui()
	_apply_safe_area()

	if get_viewport() != null and not get_viewport().size_changed.is_connected(_on_viewport_size_changed):
		get_viewport().size_changed.connect(_on_viewport_size_changed)

	# Initial platform state evaluation
	_evaluate_initial_platform_state()

func _on_viewport_size_changed() -> void:
	_apply_safe_area()

## Evaluates current OS platform and configures initial gate status
func _evaluate_initial_platform_state() -> void:
	var platform: String = OS.get_name()
	var is_headless: bool = (DisplayServer.get_name() == "headless")

	if is_headless and auto_pass_headless:
		# Auto-pass immediately for CI / headless test runners
		is_permission_granted = true
		is_flow_active = false
		visible = false
		call_deferred("_emit_completion", true)
		return

	if platform in ["Windows", "Linux", "macOS", "FreeBSD", "NetBSD", "OpenBSD", "BSD"]:
		# Desktop environments grant audio permission by default at the OS level
		is_permission_granted = true
		if auto_pass_desktop:
			is_flow_active = false
			visible = false
			call_deferred("_emit_completion", true)
			return
		else:
			_set_status("Desktop Audio Ready", Color(0.2, 0.9, 0.4, 1.0))
			if request_button:
				request_button.text = "Microphone Ready (Desktop)"
				request_button.disabled = true
			if start_button:
				start_button.disabled = false
				start_button.grab_focus()
	elif platform == "Android":
		# Android requires runtime user permission
		is_permission_granted = false
		_set_status("Status: Microphone permission required", Color(1.0, 0.8, 0.2, 1.0))
		if start_button:
			start_button.disabled = true
		if request_button:
			request_button.disabled = false
			request_button.grab_focus()
	elif platform == "iOS":
		# iOS prompts automatically upon audio capture start
		is_permission_granted = true
		_set_status("Status: Tap Start to enable iOS Audio", Color(0.3, 0.8, 1.0, 1.0))
		if request_button:
			request_button.disabled = true
		if start_button:
			start_button.disabled = false
			start_button.grab_focus()
	else:
		# Web / other platforms
		_set_status("Status: User gesture required for Audio", Color(1.0, 0.8, 0.2, 1.0))
		if start_button:
			start_button.disabled = false

## Requests microphone permission from the host OS
func request_permission() -> void:
	var platform: String = OS.get_name()
	_set_status("Requesting permission from system...", Color(0.4, 0.8, 1.0, 1.0))

	if platform == "Android":
		# Request Android RECORD_AUDIO permission
		var perm_ok: bool = OS.request_permission("android.permission.RECORD_AUDIO")
		# Also trigger standard permission alias
		OS.request_permission("RECORD_AUDIO")

		if perm_ok:
			is_permission_granted = true
			_set_status("Microphone permission granted!", Color(0.2, 0.9, 0.4, 1.0))
			if request_button:
				request_button.disabled = true
				request_button.text = "Permission Granted"
			if start_button:
				start_button.disabled = false
				start_button.grab_focus()
			permission_granted.emit()
		else:
			# On mobile, permission response may be asynchronous
			_set_status("Permission requested. Tap Start when ready.", Color(1.0, 0.85, 0.2, 1.0))
			if start_button:
				start_button.disabled = false
				start_button.grab_focus()
	else:
		is_permission_granted = true
		_set_status("Microphone permission granted!", Color(0.2, 0.9, 0.4, 1.0))
		if start_button:
			start_button.disabled = false
			start_button.grab_focus()
		permission_granted.emit()

	# Notify GameManager singleton if present in tree
	if has_node("/root/GameManager"):
		var gm = get_node("/root/GameManager")
		if gm.has_method("set_permission_granted"):
			gm.set_permission_granted(is_permission_granted)

func _on_request_button_pressed() -> void:
	request_permission()

func _on_start_button_pressed() -> void:
	_complete_flow(is_permission_granted)

func _on_skip_button_pressed() -> void:
	skip_requested.emit()
	_complete_flow(false)

func _complete_flow(granted: bool) -> void:
	is_permission_granted = granted
	is_flow_active = false

	if has_node("/root/GameManager"):
		var gm = get_node("/root/GameManager")
		if gm.has_method("set_permission_granted"):
			gm.set_permission_granted(granted)

	if granted:
		permission_granted.emit()
	else:
		permission_denied.emit()

	flow_completed.emit()
	hide_screen()

func _emit_completion(granted: bool) -> void:
	_complete_flow(granted)

## Shows permission screen and activates input blocking
func show_screen() -> void:
	visible = true
	is_flow_active = true
	if start_button and not start_button.disabled:
		start_button.grab_focus()
	elif request_button and not request_button.disabled:
		request_button.grab_focus()

## Hides permission screen
func hide_screen() -> void:
	visible = false
	is_flow_active = false

## Updates status label text and color
func _set_status(text: String, col: Color) -> void:
	if status_label:
		status_label.text = text
		status_label.add_theme_color_override("font_color", col)

## Dynamically sets safe-area margins based on device display cutouts (Pixel 7a notch/nav bar)
func _apply_safe_area() -> void:
	if safe_margin == null:
		return

	var safe_rect: Rect2i = DisplayServer.get_display_safe_area()
	var vp_size: Vector2i = DisplayServer.window_get_size()

	var left_m: int = 32
	var top_m: int = 32
	var right_m: int = 32
	var bottom_m: int = 32

	if safe_rect.size.x > 0 and safe_rect.size.y > 0 and vp_size.x > 0 and vp_size.y > 0:
		var in_left: int = safe_rect.position.x
		var in_top: int = safe_rect.position.y
		var in_right: int = vp_size.x - (safe_rect.position.x + safe_rect.size.x)
		var in_bottom: int = vp_size.y - (safe_rect.position.y + safe_rect.size.y)

		left_m = maxi(32, in_left)
		top_m = maxi(32, in_top)
		right_m = maxi(32, in_right)
		bottom_m = maxi(32, in_bottom)

	safe_margin.add_theme_constant_override("margin_left", left_m)
	safe_margin.add_theme_constant_override("margin_top", top_m)
	safe_margin.add_theme_constant_override("margin_right", right_m)
	safe_margin.add_theme_constant_override("margin_bottom", bottom_m)

## Finds existing scene nodes or builds programmatic UI fallback if instantiated without .tscn
func _resolve_or_build_ui() -> void:
	dimmer = get_node_or_null("Dimmer")
	safe_margin = get_node_or_null("SafeAreaMargin")

	if safe_margin:
		modal_card = safe_margin.get_node_or_null("CenterContainer/ModalCard")
		if modal_card:
			var vbox = modal_card.get_node_or_null("Margin/ContentVBox")
			if vbox:
				title_label = vbox.get_node_or_null("TitleLabel")
				subtitle_label = vbox.get_node_or_null("SubtitleLabel")
				description_label = vbox.get_node_or_null("DescriptionLabel")
				status_pill = vbox.get_node_or_null("StatusPill")
				if status_pill:
					status_label = status_pill.get_node_or_null("StatusLabel")
				var btn_box = vbox.get_node_or_null("ButtonVBox")
				if btn_box:
					request_button = btn_box.get_node_or_null("RequestButton")
					start_button = btn_box.get_node_or_null("StartButton")
					skip_button = btn_box.get_node_or_null("SkipButton")

	# If nodes are already present from .tscn, connect signals and return
	if request_button and start_button and skip_button:
		if not request_button.pressed.is_connected(_on_request_button_pressed):
			request_button.pressed.connect(_on_request_button_pressed)
		if not start_button.pressed.is_connected(_on_start_button_pressed):
			start_button.pressed.connect(_on_start_button_pressed)
		if not skip_button.pressed.is_connected(_on_skip_button_pressed):
			skip_button.pressed.connect(_on_skip_button_pressed)
		return

	# Programmatic UI fallback: builds complete node graph if instanced as PermissionScreen.new()
	_build_programmatic_ui()

func _build_programmatic_ui() -> void:
	if dimmer == null:
		dimmer = ColorRect.new()
		dimmer.name = "Dimmer"
		dimmer.set_anchors_preset(Control.PRESET_FULL_RECT)
		dimmer.color = Color(0.04, 0.06, 0.09, 0.94)
		add_child(dimmer)

	if safe_margin == null:
		safe_margin = MarginContainer.new()
		safe_margin.name = "SafeAreaMargin"
		safe_margin.set_anchors_preset(Control.PRESET_FULL_RECT)
		add_child(safe_margin)

	var center := CenterContainer.new()
	center.name = "CenterContainer"
	safe_margin.add_child(center)

	modal_card = PanelContainer.new()
	modal_card.name = "ModalCard"
	modal_card.custom_minimum_size = Vector2(620, 380)

	var card_style := StyleBoxFlat.new()
	card_style.bg_color = Color(0.07, 0.10, 0.15, 0.98)
	card_style.border_color = Color(0.25, 0.45, 0.70, 0.85)
	card_style.set_border_width_all(2)
	card_style.set_corner_radius_all(12)
	modal_card.add_theme_stylebox_override("panel", card_style)
	center.add_child(modal_card)

	var card_margin := MarginContainer.new()
	card_margin.add_theme_constant_override("margin_left", 28)
	card_margin.add_theme_constant_override("margin_top", 24)
	card_margin.add_theme_constant_override("margin_right", 28)
	card_margin.add_theme_constant_override("margin_bottom", 24)
	modal_card.add_child(card_margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)
	card_margin.add_child(vbox)

	title_label = Label.new()
	title_label.text = "MICROPHONE PERMISSION"
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_label.add_theme_font_size_override("font_size", 22)
	title_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 1.0))
	vbox.add_child(title_label)

	subtitle_label = Label.new()
	subtitle_label.text = "Real-Time Audio Pitch Detection Setup"
	subtitle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle_label.add_theme_font_size_override("font_size", 13)
	subtitle_label.add_theme_color_override("font_color", Color(0.35, 0.75, 1.0, 1.0))
	vbox.add_child(subtitle_label)

	description_label = Label.new()
	description_label.text = "This game uses your device microphone to detect the pitch of your voice or musical instrument in real time.\n\nAll polyphonic audio inference runs 100% locally on your device. No audio recordings are ever saved or uploaded."
	description_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	description_label.add_theme_font_size_override("font_size", 13)
	description_label.add_theme_color_override("font_color", Color(0.8, 0.86, 0.92, 1.0))
	vbox.add_child(description_label)

	status_pill = PanelContainer.new()
	var pill_style := StyleBoxFlat.new()
	pill_style.bg_color = Color(0.04, 0.06, 0.10, 0.90)
	pill_style.border_color = Color(0.2, 0.35, 0.5, 0.6)
	pill_style.set_border_width_all(1)
	pill_style.set_corner_radius_all(6)
	status_pill.add_theme_stylebox_override("panel", pill_style)
	vbox.add_child(status_pill)

	var pill_margin := MarginContainer.new()
	pill_margin.add_theme_constant_override("margin_top", 6)
	pill_margin.add_theme_constant_override("margin_bottom", 6)
	pill_margin.add_theme_constant_override("margin_left", 12)
	pill_margin.add_theme_constant_override("margin_right", 12)
	status_pill.add_child(pill_margin)

	status_label = Label.new()
	status_label.text = default_status_text
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.add_theme_font_size_override("font_size", 12)
	status_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2, 1.0))
	pill_margin.add_child(status_label)

	var btn_vbox := VBoxContainer.new()
	btn_vbox.add_theme_constant_override("separation", 8)
	vbox.add_child(btn_vbox)

	request_button = Button.new()
	request_button.text = "Grant Microphone Permission"
	request_button.custom_minimum_size = Vector2(0, 42)
	request_button.pressed.connect(_on_request_button_pressed)
	btn_vbox.add_child(request_button)

	start_button = Button.new()
	start_button.text = "Start Game"
	start_button.custom_minimum_size = Vector2(0, 42)
	start_button.pressed.connect(_on_start_button_pressed)
	btn_vbox.add_child(start_button)

	skip_button = Button.new()
	skip_button.text = "Practice Mode (Keyboard Strum)"
	skip_button.custom_minimum_size = Vector2(0, 32)
	skip_button.pressed.connect(_on_skip_button_pressed)
	btn_vbox.add_child(skip_button)
