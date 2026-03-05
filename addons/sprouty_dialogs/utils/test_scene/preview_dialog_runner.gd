@tool
extends Node

signal finished
signal variables_updated(values: Dictionary)
signal preview_log(entry: String)

const PREVIEW_DIALOG_BOX_PATH := "res://addons/sprouty_dialogs/utils/test_scene/preview_dialog_box.tscn"

var _dialog_data = null
var _start_id: String = ""
var _graph: Dictionary = {}

var _dialog_box = null
var _dialog_audio_player: AudioStreamPlayer = null
var _current_node: String = ""
var _next_node: String = ""
var _next_options: Array = []
var _current_option_keys: Array = []

var _preview_variables: Dictionary = {}
var _used_variables: Array = []
var _external_property_mocks: Dictionary = {}
var _external_method_mocks: Dictionary = {}
var _mock_only_refs: Dictionary = {}

var _track_mock_usage: bool = false
var _condition_used_mock: bool = false
var _last_condition_used_mock: bool = false


func start_preview(dialog_data, start_id: String, preview_parent: Node) -> bool:
	_dialog_data = dialog_data
	_start_id = start_id

	if not _dialog_data.graph_data.has(_start_id):
		printerr("[Sprouty Dialogs] Preview failed: start id graph not found: " + _start_id)
		return false

	_graph = _dialog_data.graph_data[_start_id]
	if _graph.is_empty():
		printerr("[Sprouty Dialogs] Preview failed: empty graph for start id: " + _start_id)
		return false

	_preview_variables = SproutyDialogsSettingsManager.get_setting("variables").duplicate(true)
	_used_variables = _collect_used_variables()
	_initialize_external_mocks()
	_emit_used_variable_values()
	_emit_preview_log("Preview sandbox active: external methods are not called; ONLY MOCK values are preview-only.")

	var box_scene: PackedScene = load(PREVIEW_DIALOG_BOX_PATH)
	if box_scene == null:
		printerr("[Sprouty Dialogs] Preview failed: cannot load preview dialog box scene")
		return false

	_dialog_box = box_scene.instantiate()
	if _dialog_box == null:
		printerr("[Sprouty Dialogs] Preview failed: preview dialog box root must extend DialogBox")
		return false

	preview_parent.add_child(_dialog_box)
	_dialog_box.continue_dialog.connect(_on_continue_dialog)
	_dialog_box.option_selected.connect(_on_option_selected)

	if _dialog_audio_player == null or not is_instance_valid(_dialog_audio_player):
		_dialog_audio_player = AudioStreamPlayer.new()
		_dialog_audio_player.name = "PreviewDialogueAudioPlayer"
		add_child(_dialog_audio_player)

	var first_node := _find_first_start_node()
	if first_node.is_empty():
		printerr("[Sprouty Dialogs] Preview failed: start node not found in graph")
		return false

	_process_node(first_node)
	return true


func get_used_variables() -> Array:
	return _used_variables.duplicate()


func get_used_variable_values() -> Dictionary:
	var result: Dictionary = {}
	for name in _used_variables:
		result[name] = _resolve_variable_value(name)
	return result


func set_preview_value(name: String, raw_value: String) -> bool:

	var slot = _resolve_internal_var_slot(name)
	if not slot.is_empty():
		var container: Dictionary = slot[0]
		var key: String = slot[1]
		var current_def: Dictionary = container[key]
		var previous_value = current_def.get("value", null)
		var value_type: int = int(current_def.get("type", TYPE_NIL))
		var metadata: Dictionary = current_def.get("metadata", {})
		var current_value = current_def.get("value", null)
		current_def["value"] = _parse_raw_value_for_type(raw_value, value_type, metadata, current_value)
		container[key] = current_def
		_emit_preview_log("SET: %s = %s -> %s" % [
			name,
			_format_preview_value(previous_value),
			_format_preview_value(current_def["value"])
		])
		_emit_used_variable_values()
		_refresh_current_options_if_needed()
		return true

	if _external_property_mocks.has(name):
		_external_property_mocks[name] = _parse_raw_value_from_current(raw_value, _external_property_mocks[name])
		_emit_preview_log("MOCK UPDATE: %s = %s" % [name, _format_preview_value(_external_property_mocks[name])])
		_emit_used_variable_values()
		_refresh_current_options_if_needed()
		return true

	if _external_method_mocks.has(name):
		_external_method_mocks[name] = _parse_raw_value_from_current(raw_value, _external_method_mocks[name])
		_emit_preview_log("MOCK UPDATE: %s = %s" % [name, _format_preview_value(_external_method_mocks[name])])
		_emit_used_variable_values()
		_refresh_current_options_if_needed()
		return true

	return false


func _refresh_current_options_if_needed() -> void:
	if _current_node.is_empty():
		return
	if not _graph.has(_current_node):
		return
	if not is_instance_valid(_dialog_box):
		return

	var node_data: Dictionary = _graph[_current_node]
	if str(node_data.get("node_type", "")) == "options_node":
		_process_options(node_data)


func is_only_mock_ref(name: String) -> bool:
	return _mock_only_refs.has(name)


func stop_preview() -> void:
	if is_instance_valid(_dialog_audio_player):
		_dialog_audio_player.stop()
		_dialog_audio_player.queue_free()
	_dialog_audio_player = null

	if is_instance_valid(_dialog_box):
		_dialog_box.queue_free()
	_dialog_box = null
	_current_node = ""
	_next_node = ""
	_next_options.clear()
	_current_option_keys.clear()


func _find_first_start_node() -> String:
	for node_name in _graph.keys():
		var node_data = _graph[node_name]
		if node_data is Dictionary and node_data.get("node_type", "") == "start_node":
			return node_name
	return ""


func _process_node(node_name: String) -> void:
	if node_name == "END":
		finish_preview()
		return

	if not _graph.has(node_name):
		finish_preview()
		return

	_current_node = node_name
	var node_data: Dictionary = _graph[node_name]
	var node_type: String = node_data.get("node_type", "")

	match node_type:
		"start_node":
			_process_node(_first_to_node(node_data))
		"dialogue_node":
			_process_dialogue(node_data)
		"options_node":
			_process_options(node_data)
		"condition_node":
			_process_condition(node_data)
		"set_variable_node":
			_process_set_variable(node_data)
		"wait_node":
			await get_tree().create_timer(float(node_data.get("wait_time", 0.0))).timeout
			_process_node(_first_to_node(node_data))
		"call_method_node":
			# Flow-only preview: never call external methods
			_emit_preview_log("CALL skipped (preview-only): %s.%s" % [
				str(node_data.get("autoload", "<none>")),
				str(node_data.get("method", "<none>"))
			])
			_process_node(_first_to_node(node_data))
		"signal_node":
			_emit_preview_log("SIGNAL emitted: %s" % str(node_data.get("signal_id", "<empty>")))
			_process_node(_first_to_node(node_data))
		_:
			_process_node(_first_to_node(node_data))


func _process_dialogue(node_data: Dictionary) -> void:
	var key: String = str(node_data.get("dialog_key", ""))
	var text := SproutyDialogsTranslationManager.get_translated_dialog(key, _dialog_data)
	if text.is_empty() and _dialog_data.dialogs.has(key) and _dialog_data.dialogs[key].has("default"):
		text = str(_dialog_data.dialogs[key]["default"])
	text = _parse_text(text)

	var character_name: String = str(node_data.get("character", ""))
	# Flow-only preview: character map stores UID ints, so avoid character resource translation path here.
	# Use the node character key directly to keep preview robust.
	var translated_name := _parse_text(character_name)
	var audio_path := str(node_data.get("audio_path", "")).strip_edges()
	if not audio_path.is_empty():
		_emit_preview_log("AUDIO play (preview): %s" % audio_path)
	_play_dialogue_audio(audio_path)

	_next_node = _first_to_node(node_data)
	_dialog_box.play_dialog(translated_name, text)


func _process_options(node_data: Dictionary) -> void:
	var options: Array = []
	var disabled_flags: Array = []
	_next_options = []
	_current_option_keys = []

	var option_keys: Array = node_data.get("options_keys", [])
	var option_conditions: Array = node_data.get("options_conditions", [])
	var to_nodes: Array = node_data.get("to_node", [])

	for i in range(option_keys.size()):
		var key: String = str(option_keys[i])
		var text := SproutyDialogsTranslationManager.get_translated_dialog(key, _dialog_data)
		if text.is_empty() and _dialog_data.dialogs.has(key) and _dialog_data.dialogs[key].has("default"):
			text = str(_dialog_data.dialogs[key]["default"])
		text = _parse_text(text)

		var show_option := true
		var disabled := false
		var condition_suffix := ""

		if i < option_conditions.size() and option_conditions[i] is Dictionary:
			var cond: Dictionary = option_conditions[i]
			if cond.get("enabled", false):
				condition_suffix = " [if %s]" % _format_condition_text(cond)
				var res = _evaluate_condition(cond.get("first_var", {}), cond.get("second_var", {}), int(cond.get("operator", OP_EQUAL)))
				var met: bool = (res == true)
				var visibility := int(cond.get("visibility", 0))
				var short_key := _short_option_key(key)
				if _last_condition_used_mock:
					condition_suffix += " [ONLY MOCK]"
				_emit_preview_log("[%s]: %s -> %s%s" % [
					short_key,
					_format_condition_text(cond),
					"PASS" if met else "FAIL",
					" [ONLY MOCK]" if _last_condition_used_mock else ""
				])
				if not met:
					if visibility == 0:
						show_option = false
					else:
						disabled = true

		if show_option:
			options.append(text + condition_suffix)
			disabled_flags.append(disabled)
			if not disabled:
				if i < to_nodes.size():
					_next_options.append(to_nodes[i])
				else:
					_next_options.append("END")
				_current_option_keys.append(key)

	_dialog_box.display_options(options, disabled_flags)


func _process_condition(node_data: Dictionary) -> void:
	var result = _evaluate_condition(node_data.get("first_var", {}), node_data.get("second_var", {}), int(node_data.get("operator", OP_EQUAL)))
	var to_nodes: Array = node_data.get("to_node", [])
	_emit_preview_log("CONDITION: %s -> %s%s" % [
		_format_condition_text(node_data),
		"PASS" if result == true else "FAIL",
		" [ONLY MOCK]" if _last_condition_used_mock else ""
	])
	if result == true:
		_process_node(to_nodes[0] if to_nodes.size() > 0 else "END")
	else:
		_process_node(to_nodes[1] if to_nodes.size() > 1 else "END")


func _process_set_variable(node_data: Dictionary) -> void:
	var var_name: String = str(node_data.get("var_name", ""))
	var_name = var_name.strip_edges()

	# Flow-only preview never mutates external/global variables
	if var_name.is_empty() or "." in var_name:
		_emit_used_variable_values()
		_process_node(_first_to_node(node_data))
		return

	var slot = _resolve_internal_var_slot(var_name)
	if slot.is_empty():
		_emit_used_variable_values()
		_process_node(_first_to_node(node_data))
		return

	var container: Dictionary = slot[0]
	var key: String = slot[1]
	var current_def: Dictionary = container[key]

	var var_type: int = int(node_data.get("var_type", current_def.get("type", TYPE_NIL)))
	var op: int = int(node_data.get("operator", 0))
	var new_value = _coerce_value(var_type, node_data.get("new_value", null), node_data.get("var_metadata", {}))

	var result = SproutyDialogsVariableManager.get_assignment_result(var_type, op, current_def.get("value", null), new_value)
	_emit_preview_log("SET NODE: %s %s %s -> %s" % [
		var_name,
		_operator_to_assignment_text(op),
		_format_preview_value(new_value),
		_format_preview_value(result)
	])
	current_def["value"] = result
	container[key] = current_def

	_emit_used_variable_values()
	_process_node(_first_to_node(node_data))


func _first_to_node(node_data: Dictionary) -> String:
	var list: Array = node_data.get("to_node", [])
	if list.is_empty():
		return "END"
	return str(list[0])


func _on_continue_dialog() -> void:
	_process_node(_next_node)


func _on_option_selected(option_index: int) -> void:
	if option_index < 0 or option_index >= _next_options.size():
		return
	_dialog_box.hide_options()
	_process_node(_next_options[option_index])


func _play_dialogue_audio(audio_path: String) -> void:
	if _dialog_audio_player == null or not is_instance_valid(_dialog_audio_player):
		return

	var path := audio_path.strip_edges()
	if path.is_empty():
		_dialog_audio_player.stop()
		return

	var stream = load(path)
	if stream is AudioStream:
		_dialog_audio_player.stop()
		_dialog_audio_player.stream = stream
		_dialog_audio_player.play()
	else:
		printerr("[Sprouty Dialogs] Invalid dialogue audio stream in preview: " + path)


func finish_preview() -> void:
	finished.emit()


func _emit_used_variable_values() -> void:
	variables_updated.emit(get_used_variable_values())


func _collect_used_variables() -> Array:
	var used: Dictionary = {}
	var start_node := _find_first_start_node()
	if start_node.is_empty():
		return []

	var queue: Array = [start_node]
	var visited: Dictionary = {}

	while not queue.is_empty():
		var node_name: String = str(queue.pop_front())
		if visited.has(node_name):
			continue
		visited[node_name] = true

		if not _graph.has(node_name):
			continue

		var node_data: Dictionary = _graph[node_name]
		var node_type: String = str(node_data.get("node_type", ""))

		if node_type == "set_variable_node":
			_collect_var_name(str(node_data.get("var_name", "")), used)
		elif node_type == "condition_node":
			_collect_var_operand(node_data.get("first_var", {}), used)
			_collect_var_operand(node_data.get("second_var", {}), used)
		elif node_type == "options_node":
			for cond in node_data.get("options_conditions", []):
				if cond is Dictionary:
					_collect_var_operand(cond.get("first_var", {}), used)
					_collect_var_operand(cond.get("second_var", {}), used)

		if node_type == "dialogue_node":
			var key: String = str(node_data.get("dialog_key", ""))
			_collect_vars_from_text(SproutyDialogsTranslationManager.get_translated_dialog(key, _dialog_data), used)

		if node_type == "options_node":
			for key in node_data.get("options_keys", []):
				_collect_vars_from_text(SproutyDialogsTranslationManager.get_translated_dialog(str(key), _dialog_data), used)

		for next_name in node_data.get("to_node", []):
			var n = str(next_name)
			if n != "END" and not visited.has(n):
				queue.append(n)

	var keys: Array = []
	for k in used.keys():
		keys.append(k)
	keys.sort()
	return keys


func _collect_var_operand(var_data: Dictionary, used: Dictionary) -> void:
	if var_data.is_empty():
		return
	var operand_type := int(var_data.get("type", -1))
	if operand_type == 40:
		_collect_var_name(str(var_data.get("value", "")), used)
		return

	# Also collect external property references used in expression operands
	if operand_type == TYPE_STRING:
		var md: Dictionary = var_data.get("metadata", {})
		if md.has("hint") and int(md["hint"]) == PROPERTY_HINT_EXPRESSION:
			_extract_external_refs(str(var_data.get("value", "")), used)


func _collect_var_name(name: String, used: Dictionary) -> void:
	var trimmed := name.strip_edges()
	if trimmed.is_empty():
		return
	if trimmed.contains("(") or trimmed.contains(")"):
		_extract_external_refs(trimmed, used)
		return
	used[trimmed] = true


func _collect_vars_from_text(text: String, used: Dictionary) -> void:
	if text.is_empty() or not text.contains("{"):
		return
	var regex := RegEx.new()
	regex.compile("{([^{}]*)}")
	for m in regex.search_all(text):
		var token := m.get_string(1)
		_collect_var_name(token, used)
		_extract_external_refs(token, used)


func _extract_external_refs(expression: String, used: Dictionary) -> void:
	if expression.is_empty() or not expression.contains("."):
		return

	var method_regex := RegEx.new()
	# Match method references like Autoload.some_method(...)
	method_regex.compile("\\b([A-Za-z_][A-Za-z0-9_]*\\.[A-Za-z_][A-Za-z0-9_]*\\([^)]*\\))")
	for m in method_regex.search_all(expression):
		var method_ref := m.get_string(1)
		used[method_ref] = true

	var regex := RegEx.new()
	# Match dotted identifiers like Autoload.some_property
	regex.compile("\\b([A-Za-z_][A-Za-z0-9_]*\\.[A-Za-z_][A-Za-z0-9_]*)\\b")

	for m in regex.search_all(expression):
		var ref := m.get_string(1)
		# Skip method calls, keep property references only
		if expression.contains(ref + "("):
			continue
		used[ref] = true


func _parse_text(text: String) -> String:
	if text.is_empty() or not text.contains("{"):
		return text
	var regex := RegEx.new()
	regex.compile("{([^{}]*)}")
	for match in regex.search_all(text):
		var token := match.get_string(1)
		var value = _resolve_variable_value(token)
		if value != null:
			text = text.replace("{" + token + "}", _format_preview_value(value))
	return text


func _format_preview_value(value: Variant) -> String:
	if value is float:
		var f := float(value)
		if is_equal_approx(f, round(f)):
			return str(int(round(f)))
		return str(f)
	return str(value)


func _resolve_variable_value(name: String) -> Variant:
	var n := name.strip_edges()
	if n.is_empty():
		return null
	if n.contains("(") or n.contains(")"):
		if _external_method_mocks.has(n):
			if _track_mock_usage:
				_condition_used_mock = true
			return _external_method_mocks[n]
		return null

	var slot = _resolve_internal_var_slot(n)
	if not slot.is_empty():
		var container: Dictionary = slot[0]
		var key: String = slot[1]
		return container[key].get("value", null)

	if "." in n:
		if _external_property_mocks.has(n):
			if _track_mock_usage and _mock_only_refs.has(n):
				_condition_used_mock = true
			return _external_property_mocks[n]

		var from = n.get_slice(".", 0)
		var prop = n.substr(from.length() + 1)
		if prop.contains("(") or prop.contains(")"):
			return null
		var autoload = get_tree().root.get_node_or_null(from)
		if autoload == null:
			return null
		var props = autoload.get_property_list()
		for p in props:
			if p is Dictionary and p.get("name", "") == prop:
				return autoload.get(prop)

	return null


func _resolve_internal_var_slot(name: String) -> Array:
	if name.is_empty():
		return []

	if _preview_variables.has(name) and not _preview_variables[name].has("variables"):
		return [_preview_variables, name]

	if "/" in name:
		var parts = name.split("/")
		var current: Dictionary = _preview_variables
		for i in range(parts.size()):
			var part: String = parts[i]
			if not current.has(part):
				return []
			if i == parts.size() - 1:
				if current[part] is Dictionary and not current[part].has("variables"):
					return [current, part]
				return []
			var child = current[part]
			if child is Dictionary and child.has("variables"):
				current = child["variables"]
			else:
				return []

	return []


func _coerce_value(var_type: int, value: Variant, metadata: Dictionary) -> Variant:
	if var_type == TYPE_STRING:
		if metadata.has("hint") and metadata["hint"] == PROPERTY_HINT_EXPRESSION:
			# Flow-only preview: expressions are treated as plain text
			return str(value)
		return _parse_text(str(value))
	if var_type == TYPE_INT:
		return int(value)
	if var_type == TYPE_FLOAT:
		return float(value)
	if var_type == TYPE_BOOL:
		return bool(value)
	return value


func _evaluate_condition(first_var: Dictionary, second_var: Dictionary, operator: int) -> Variant:
	_track_mock_usage = true
	_condition_used_mock = false
	var left = _resolve_operand_value(first_var)
	var right = _resolve_operand_value(second_var)
	_track_mock_usage = false
	_last_condition_used_mock = _condition_used_mock
	if left == null or right == null:
		return false

	match operator:
		OP_EQUAL:
			return left == right
		OP_NOT_EQUAL:
			return left != right
		OP_LESS:
			return left < right
		OP_LESS_EQUAL:
			return left <= right
		OP_GREATER:
			return left > right
		OP_GREATER_EQUAL:
			return left >= right
		OP_IN:
			return left in right
		_:
			return false


func _initialize_external_mocks() -> void:
	_external_property_mocks.clear()
	_external_method_mocks.clear()
	_mock_only_refs.clear()

	for ref in _used_variables:
		var key := str(ref)
		if not key.contains("."):
			continue

		if key.contains("(") and key.contains(")"):
			_external_method_mocks[key] = _default_mock_for_ref(key)
			_mock_only_refs[key] = true
			continue

		var live = _resolve_external_property_live_value(key)
		if live == null:
			_external_property_mocks[key] = _default_mock_for_ref(key)
			_mock_only_refs[key] = true
		else:
			_external_property_mocks[key] = live


func _resolve_external_property_live_value(ref: String) -> Variant:
	if not ref.contains("."):
		return null
	if ref.contains("(") or ref.contains(")"):
		return null

	var from = ref.get_slice(".", 0)
	var prop = ref.substr(from.length() + 1)
	if prop.contains("(") or prop.contains(")"):
		return null

	var autoload = get_tree().root.get_node_or_null(from)
	if autoload == null:
		return null

	for p in autoload.get_property_list():
		if p is Dictionary and p.get("name", "") == prop:
			return autoload.get(prop)

	return null


func _default_mock_for_ref(ref: String) -> Variant:
	var lower = ref.to_lower()
	if ".is_" in lower or ".has_" in lower or "_enabled" in lower or "_available" in lower:
		return false
	if "count" in lower or "amount" in lower or "level" in lower or "index" in lower:
		return 0
	return "<mock>"


func _resolve_operand_value(var_data: Dictionary) -> Variant:
	if var_data.is_empty():
		return null

	var type_id: int = int(var_data.get("type", TYPE_NIL))
	var value = var_data.get("value", null)

	if type_id == 40:
		return _resolve_variable_value(str(value))

	if type_id == TYPE_STRING:
		var metadata: Dictionary = var_data.get("metadata", {})
		if metadata.has("hint") and int(metadata.get("hint", -1)) == PROPERTY_HINT_EXPRESSION:
			return _resolve_expression_operand(str(value))
		return _parse_text(str(value))

	if type_id == TYPE_INT:
		return int(value)
	if type_id == TYPE_FLOAT:
		return float(value)
	if type_id == TYPE_BOOL:
		return bool(value)

	return value


func _resolve_expression_operand(expression: String) -> Variant:
	var expr := expression.strip_edges()
	if expr.is_empty():
		return null

	if _external_method_mocks.has(expr):
		if _track_mock_usage:
			_condition_used_mock = true
		return _external_method_mocks[expr]

	if _external_property_mocks.has(expr):
		if _track_mock_usage and _mock_only_refs.has(expr):
			_condition_used_mock = true
		return _external_property_mocks[expr]

	if "." in expr and not ("(" in expr or ")" in expr):
		return _resolve_variable_value(expr)

	var lower := expr.to_lower()
	if lower == "true":
		return true
	if lower == "false":
		return false
	if expr.is_valid_int():
		return int(expr)
	if expr.is_valid_float():
		return float(expr)

	return null


func _emit_preview_log(entry: String) -> void:
	preview_log.emit(entry)


func _format_condition_text(cond: Dictionary) -> String:
	var first_txt := _format_operand_text(cond.get("first_var", {}))
	var op_txt := _operator_to_text(int(cond.get("operator", OP_EQUAL)))
	var second_txt := _format_operand_text(cond.get("second_var", {}))
	var visibility := int(cond.get("visibility", 0))
	var visibility_txt := "hidden" if visibility == 0 else "disabled"
	return "%s %s %s | %s" % [first_txt, op_txt, second_txt, visibility_txt]


func _format_operand_text(var_data: Dictionary) -> String:
	if var_data.is_empty():
		return "<empty>"
	var type_id := int(var_data.get("type", TYPE_NIL))
	var value = var_data.get("value", null)
	if type_id == 40:
		return str(value)
	if type_id == TYPE_STRING:
		return '"%s"' % str(value)
	if type_id == TYPE_BOOL:
		return "true" if bool(value) else "false"
	return str(value)


func _operator_to_text(operator: int) -> String:
	match operator:
		OP_EQUAL:
			return "=="
		OP_NOT_EQUAL:
			return "!="
		OP_LESS:
			return "<"
		OP_LESS_EQUAL:
			return "<="
		OP_GREATER:
			return ">"
		OP_GREATER_EQUAL:
			return ">="
		OP_IN:
			return "in"
		_:
			return "?"


func _short_option_key(option_key: String) -> String:
	var marker_index := option_key.find("_OPT")
	if marker_index >= 0:
		return option_key.substr(marker_index + 1)
	return option_key


func _operator_to_assignment_text(operator: int) -> String:
	var assign_enum = SproutyDialogsVariableUtils.ASSIGN_OPS
	match operator:
		assign_enum.ASSIGN:
			return "="
		assign_enum.ADD_ASSIGN:
			return "+="
		assign_enum.SUB_ASSIGN:
			return "-="
		assign_enum.MUL_ASSIGN:
			return "*="
		assign_enum.DIV_ASSIGN:
			return "/="
		assign_enum.EXP_ASSIGN:
			return "**="
		assign_enum.MOD_ASSIGN:
			return "%="
		_:
			return "?="


func _parse_raw_value_for_type(raw_value: String, value_type: int,
		metadata: Dictionary, current_value: Variant) -> Variant:
	var raw := raw_value.strip_edges()

	if value_type == TYPE_BOOL:
		var lower := raw.to_lower()
		if lower in ["true", "1", "yes", "on"]:
			return true
		if lower in ["false", "0", "no", "off", ""]:
			return false
		return bool(current_value)

	if value_type == TYPE_INT:
		if raw.is_valid_int():
			return int(raw)
		if raw.is_valid_float():
			return int(round(float(raw)))
		return int(current_value) if (current_value is int or current_value is float) else 0

	if value_type == TYPE_FLOAT:
		if raw.is_valid_float() or raw.is_valid_int():
			return float(raw)
		return float(current_value) if (current_value is float or current_value is int) else 0.0

	if value_type == TYPE_STRING:
		if metadata.has("hint") and int(metadata.get("hint", -1)) == PROPERTY_HINT_EXPRESSION:
			return raw
		return raw

	return _parse_raw_value_from_current(raw, current_value)


func _parse_raw_value_from_current(raw_value: String, current_value: Variant) -> Variant:
	var raw := raw_value.strip_edges()
	if current_value is bool:
		var lower := raw.to_lower()
		if lower in ["true", "1", "yes", "on"]:
			return true
		if lower in ["false", "0", "no", "off", ""]:
			return false
		return current_value

	if current_value is int:
		if raw.is_valid_int():
			return int(raw)
		if raw.is_valid_float():
			return int(round(float(raw)))
		return current_value

	if current_value is float:
		if raw.is_valid_float() or raw.is_valid_int():
			return float(raw)
		return current_value

	if raw.is_valid_int():
		return int(raw)
	if raw.is_valid_float():
		return float(raw)
	var lower := raw.to_lower()
	if lower in ["true", "false"]:
		return lower == "true"
	return raw
