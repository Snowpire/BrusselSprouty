@tool
extends Window
const PREVIEW_RUNNER_PATH := "res://addons/sprouty_dialogs/utils/test_scene/preview_dialog_runner.gd"

@onready var preview_root: Control = $PreviewRoot

var _runner = null
var _vars_panel: PanelContainer = null
var _vars_list: VBoxContainer = null
var _log_panel: PanelContainer = null
var _log_label: RichTextLabel = null


func _ready() -> void:
	close_requested.connect(_on_close_requested)
	visibility_changed.connect(_on_visibility_changed)


func preview_dialog(dialog_path: String, start_id: String) -> void:
	_clear_preview_ui()

	var data = load(dialog_path)
	if data == null:
		printerr("[Sprouty Dialogs] Preview failed: invalid dialogue resource: " + dialog_path)
		return
	if not ("graph_data" in data and "dialogs" in data and "characters" in data):
		printerr("[Sprouty Dialogs] Preview failed: resource is not valid dialogue data: " + dialog_path)
		return

	if preview_root == null:
		printerr("[Sprouty Dialogs] Preview failed: PreviewRoot not found.")
		return

	var runner_script = load(PREVIEW_RUNNER_PATH)
	if runner_script == null:
		printerr("[Sprouty Dialogs] Preview failed: cannot load preview runner script: " + PREVIEW_RUNNER_PATH)
		return
	if runner_script is GDScript and not runner_script.can_instantiate():
		printerr("[Sprouty Dialogs] Preview failed: runner script has parse errors and cannot instantiate: " + PREVIEW_RUNNER_PATH)
		return

	_runner = runner_script.new()
	if _runner == null:
		printerr("[Sprouty Dialogs] Preview failed: cannot instantiate preview runner script")
		return

	add_child(_runner)
	_runner.finished.connect(_on_preview_finished, CONNECT_ONE_SHOT)
	_runner.variables_updated.connect(_on_variables_updated)
	_runner.preview_log.connect(_on_preview_log)

	if not _runner.start_preview(data, start_id, preview_root):
		_runner.queue_free()
		_runner = null
		return

	_ensure_vars_panel()
	_ensure_log_panel()
	_on_variables_updated(_runner.get_used_variable_values())

	popup_centered_ratio(0.7)
	grab_focus()


func _on_preview_finished() -> void:
	_clear_preview_ui()


func _on_variables_updated(values: Dictionary) -> void:
	if _vars_list == null:
		return

	for child in _vars_list.get_children():
		child.queue_free()

	if values.is_empty():
		var empty_label = Label.new()
		empty_label.text = "No variables used in this path."
		_vars_list.add_child(empty_label)
		return

	var keys: Array = values.keys()
	keys.sort()
	for key in keys:
		var key_name = str(key)
		var row = HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.alignment = BoxContainer.ALIGNMENT_BEGIN
		var is_only_mock = _runner != null and is_instance_valid(_runner) and _runner.has_method("is_only_mock_ref") and _runner.is_only_mock_ref(str(key))

		var mock_badge = Control.new()
		mock_badge.visible = is_only_mock
		mock_badge.custom_minimum_size = Vector2(18, 0)

		var mock_icon = TextureRect.new()
		mock_icon.custom_minimum_size = Vector2(12, 12)
		mock_icon.position = Vector2(3, 5)
		mock_icon.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		if has_theme_icon("StatusWarning", "EditorIcons"):
			mock_icon.texture = get_theme_icon("StatusWarning", "EditorIcons")
		mock_icon.modulate = Color(1.0, 0.86, 0.2)
		mock_icon.tooltip_text = "ONLY MOCK: preview stand-in value, not the real runtime value.\nPreview cannot call methods outside its sandbox.\nChanging this only affects this preview session."
		mock_badge.add_child(mock_icon)

		var name_label = LineEdit.new()
		name_label.editable = false
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.mouse_filter = Control.MOUSE_FILTER_STOP
		name_label.text = key_name
		name_label.tooltip_text = key_name

		var value_input = LineEdit.new()
		value_input.custom_minimum_size = Vector2(120, 0)
		value_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		value_input.text = _format_preview_value(values[key])
		value_input.placeholder_text = "Enter value"

		var set_button = Button.new()
		set_button.text = "Set"

		set_button.pressed.connect(_on_set_variable_pressed.bind(key_name, value_input))
		value_input.text_submitted.connect(_on_var_text_submitted.bind(key_name, value_input))

		row.add_child(mock_badge)
		row.add_child(name_label)
		row.add_child(value_input)
		row.add_child(set_button)
		_vars_list.add_child(row)


func _on_preview_log(entry: String) -> void:
	if _log_label == null:
		return

	var prefix = "[color=gray][%s][/color] " % Time.get_time_string_from_system()
	if _log_label.text.is_empty():
		_log_label.text = prefix + entry
	else:
		_log_label.text += "\n" + prefix + entry
	_log_label.scroll_to_line(_log_label.get_line_count())


func _on_close_requested() -> void:
	hide()
	_clear_preview_ui()


func _on_visibility_changed() -> void:
	if not visible:
		_clear_preview_ui()


func _clear_preview_ui() -> void:
	var runner = _runner
	_runner = null

	if is_instance_valid(runner):
		if runner.finished.is_connected(_on_preview_finished):
			runner.finished.disconnect(_on_preview_finished)
		if runner.variables_updated.is_connected(_on_variables_updated):
			runner.variables_updated.disconnect(_on_variables_updated)
		if runner.preview_log.is_connected(_on_preview_log):
			runner.preview_log.disconnect(_on_preview_log)
		runner.stop_preview()
		runner.queue_free()

	if is_instance_valid(preview_root):
		for child in preview_root.get_children():
			child.queue_free()

	if is_instance_valid(_vars_panel):
		_vars_panel.queue_free()
	if is_instance_valid(_log_panel):
		_log_panel.queue_free()
	_vars_panel = null
	_vars_list = null
	_log_panel = null
	_log_label = null


func _ensure_vars_panel() -> void:
	if _vars_panel != null and is_instance_valid(_vars_panel):
		return

	_vars_panel = PanelContainer.new()
	_vars_panel.name = "VariablesPanel"
	_vars_panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	_vars_panel.anchor_left = 1.0
	_vars_panel.anchor_top = 0.0
	_vars_panel.anchor_right = 1.0
	_vars_panel.anchor_bottom = 1.0
	_vars_panel.offset_left = -320.0
	_vars_panel.offset_top = 12.0
	_vars_panel.offset_right = -12.0
	_vars_panel.offset_bottom = -12.0
	add_child(_vars_panel)

	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	_vars_panel.add_child(margin)

	var content = VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(content)

	var title = Label.new()
	title.text = "Variables"
	content.add_child(title)

	var scroll = ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(scroll)

	_vars_list = VBoxContainer.new()
	_vars_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vars_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(_vars_list)


func _ensure_log_panel() -> void:
	if _log_panel != null and is_instance_valid(_log_panel):
		return

	_log_panel = PanelContainer.new()
	_log_panel.name = "PreviewLogPanel"
	_log_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_log_panel.custom_minimum_size = Vector2(560, 260)
	_log_panel.position = Vector2(12.0, 12.0)
	_log_panel.size = Vector2(560.0, 260.0)
	add_child(_log_panel)

	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	_log_panel.add_child(margin)

	var content = VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(content)

	var title = Label.new()
	title.text = "Flow Log"
	content.add_child(title)

	_log_label = RichTextLabel.new()
	_log_label.bbcode_enabled = true
	_log_label.fit_content = false
	_log_label.scroll_active = true
	_log_label.selection_enabled = true
	_log_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_log_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log_label.custom_minimum_size = Vector2(0, 180)
	_log_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_log_label.text = ""
	content.add_child(_log_label)


func _on_set_variable_pressed(name: String, value_input: LineEdit) -> void:
	if _runner == null or not is_instance_valid(_runner):
		return
	if not _runner.has_method("set_preview_value"):
		return

	var ok = _runner.set_preview_value(name, value_input.text)
	if ok and _runner.has_method("get_used_variable_values"):
		_on_variables_updated(_runner.get_used_variable_values())


func _on_var_text_submitted(_text: String, name: String, value_input: LineEdit) -> void:
	_on_set_variable_pressed(name, value_input)


func _format_preview_value(value: Variant) -> String:
	if value == null:
		return "<unresolved>"
	if value is float:
		var f = float(value)
		if is_equal_approx(f, round(f)):
			return str(int(round(f)))
		return str(f)
	return str(value)
