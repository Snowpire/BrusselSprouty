@tool
extends DialogBox


func _enter_tree() -> void:
	if not Engine.is_editor_hint():
		super._enter_tree()
		return

	if typing_speed > 0.0 and _type_timer == null:
		_type_timer = Timer.new()
		add_child(_type_timer)
		_type_timer.wait_time = typing_speed
		_type_timer.timeout.connect(_on_type_timer_timeout)

	if _can_skip_timer == null:
		_can_skip_timer = Timer.new()
		add_child(_can_skip_timer)
		_can_skip_timer.wait_time = SproutyDialogsSettingsManager.get_setting("can_skip_delay")
		_can_skip_timer.timeout.connect(func(): _can_skip = true)

	hide()


func _ready() -> void:
	super._ready()

	if not Engine.is_editor_hint():
		return

	if not dialog_display:
		printerr("[Sprouty Dialogs] Preview dialog display is not set.")
		return

	if not dialog_display.is_connected("meta_clicked", _on_dialog_meta_clicked):
		dialog_display.meta_clicked.connect(_on_dialog_meta_clicked)

	dialog_display.bbcode_enabled = true

	if option_template:
		option_template = option_template.duplicate()
	if continue_indicator:
		continue_indicator.hide()
	if options_container:
		options_container.hide()


func _input(event: InputEvent) -> void:
	if not _is_running:
		return

	if _is_displaying_options:
		_handle_option_shortcuts(event)
		return

	var continue_action: String = str(
		SproutyDialogsSettingsManager.get_setting("continue_input_action")
	)
	if continue_action.is_empty() or not InputMap.has_action(continue_action):
		if InputMap.has_action("dialogic_default_action"):
			continue_action = "dialogic_default_action"
		else:
			continue_action = "ui_accept"

	var continue_pressed := Input.is_action_just_pressed(continue_action)
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			continue_pressed = true

	if not _display_completed and _can_skip and continue_pressed:
		_skip_dialog_typing()
	elif _display_completed and continue_pressed:
		if _current_sentence < _sentences.size() - 1:
			_current_sentence += 1
			_display_new_sentence(_sentences[_current_sentence])
		else:
			continue_dialog.emit()


func _handle_option_shortcuts(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return

	# Do not consume numeric hotkeys while editing text fields in preview HUD.
	var focused: Control = get_viewport().gui_get_focus_owner()
	if focused != null and (focused is LineEdit or focused is TextEdit):
		return

	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return

	var keycode := key_event.keycode
	if keycode < KEY_1 or keycode > KEY_9:
		return

	var target := int(keycode - KEY_1)
	var buttons: Array[Button] = []
	if options_container:
		for child in options_container.get_children():
			if child is Button and not child.disabled:
				buttons.append(child)

	if target >= 0 and target < buttons.size():
		buttons[target].pressed.emit()


func display_options(options: Array, disabled_flags: Array = []) -> void:
	_is_displaying_options = true

	if not options_container:
		return
	if not option_template:
		return

	for child in options_container.get_children():
		child.queue_free()

	var selectable_index := 0
	for index in options.size():
		var option_node = option_template.duplicate()
		option_node.set_text(options[index])

		var is_disabled: bool = index < disabled_flags.size() and bool(disabled_flags[index])
		option_node.disabled = is_disabled
		option_node.modulate = Color(0.6, 0.6, 0.6, 1.0) if is_disabled else Color(1, 1, 1, 1)

		if is_disabled:
			option_node.focus_mode = Control.FOCUS_NONE
		else:
			var option_index: int = selectable_index
			selectable_index += 1
			if option_node is Button:
				option_node.pressed.connect(_on_preview_option_pressed.bind(option_index))

		options_container.add_child(option_node)
		option_node.show()

	_on_options_displayed()
	show()


func _on_preview_option_pressed(option_index: int) -> void:
	option_selected.emit(option_index)
