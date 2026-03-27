@tool
extends SproutyDialogsBaseNode

# -----------------------------------------------------------------------------
# Sprouty Dialogs Jump To Node
# -----------------------------------------------------------------------------
## Node to jump to another dialogue branch and return to the next output.
# -----------------------------------------------------------------------------

## Start ID input field.
@onready var _target_input: EditorSproutyDialogsComboBox = %TargetIdInput
## Start ID value.
@onready var _target_id: String = _target_input.text

## Empty field error style for input text.
var _input_error_style := preload("res://addons/sprouty_dialogs/editor/theme/input_text_error.tres")
## Flag to check if the error alert is displaying.
var _displaying_error: bool = false
## Error alert to show when the target input is invalid.
var _target_error_alert: EditorSproutyDialogsAlert

## Flag to check if the ID was modified.
var _id_modified: bool = false


func _ready():
	super()
	_target_input.input_changed.connect(_on_target_input_changed)
	_target_input.input_focus_exited.connect(_on_target_input_focus_exited)
	node_deselected.connect(_on_node_deselected)
	tree_exiting.connect(_on_tree_exiting)
	_refresh_target_options()

	if get_parent() and get_parent().has_signal("modified"):
		get_parent().modified.connect(_on_graph_modified)


#region === Node Data ==========================================================

func get_data() -> Dictionary:
	var dict := {}

	dict[name.to_snake_case()] = {
		"node_type": node_type,
		"node_index": node_index,
		"to_id": _target_id.to_upper(),
		"to_node": get_output_connections(),
		"to_dialog": to_dialog,
		"offset": position_offset,
		"size": size
	}
	return dict


func set_data(dict: Dictionary) -> void:
	node_type = dict["node_type"]
	node_index = dict["node_index"]
	to_node = dict["to_node"]
	position_offset = dict["offset"]
	size = dict["size"]

	if dict.has("to_dialog"):
		to_dialog = dict["to_dialog"]

	_target_id = dict.get("to_id", "")
	_target_input.set_value(_target_id)
	_refresh_target_options()

#endregion


## Refresh the available target IDs from the graph editor.
func _refresh_target_options() -> void:
	if get_parent() and get_parent().has_method("get_start_ids"):
		_target_input.set_options(get_parent().get_start_ids())


## Validate the target ID against the graph editor start IDs.
func _is_valid_target_id(target_id: String) -> bool:
	if target_id.is_empty() or not get_parent() or not get_parent().has_method("get_start_ids"):
		return false
	for start_id in get_parent().get_start_ids():
		if str(start_id).to_upper() == target_id.to_upper():
			return true
	return false


## Handle when the graph is modified.
func _on_graph_modified(_modified: bool) -> void:
	_refresh_target_options()


## Update the target ID and become it uppercase.
func _on_target_input_changed(new_text: String) -> void:
	if _displaying_error:
		_target_input.remove_theme_stylebox_override("normal")
		get_parent().alerts.hide_alert(_target_error_alert)
		_target_error_alert = null
		_displaying_error = false

	var target_text = new_text.to_upper()
	var caret_pos = _target_input.caret_column
	_target_input.text = target_text
	_target_input.caret_column = caret_pos

	if _target_id != target_text:
		var temp = _target_id
		_target_id = target_text
		_id_modified = true

		# --- UndoRedo --------------------------------------------------
		undo_redo.create_action("Edit Jump Target", 1)
		undo_redo.add_do_property(self, "_target_id", target_text)
		undo_redo.add_do_property(_target_input, "text", target_text)
		undo_redo.add_undo_property(self, "_target_id", temp)
		undo_redo.add_undo_property(_target_input, "text", temp)
		undo_redo.add_undo_method(self, "_on_target_input_focus_exited")

		undo_redo.add_do_method(self, "emit_signal", "modified", true)
		undo_redo.add_undo_method(self, "emit_signal", "modified", false)
		undo_redo.commit_action(false)
		# ---------------------------------------------------------------


## Show error alerts when the target input loses focus.
func _on_target_input_focus_exited() -> void:
	if _id_modified:
		_id_modified = false
		modified.emit(true)

	if _target_input.text.is_empty() or not _is_valid_target_id(_target_input.text):
		_target_input.add_theme_stylebox_override("normal", _input_error_style)
		if _target_error_alert == null:
			var message = "Jump To Node #" + str(node_index) + " needs a valid Start ID"
			if not _target_input.text.is_empty():
				message = "Jump To Node #" + str(node_index) + " cannot find the Start ID '" \
					+ _target_input.text + "'"
			_target_error_alert = get_parent().alerts.show_alert(message, 0)
		else:
			get_parent().alerts.focus_alert(_target_error_alert)
		_displaying_error = true


## Active error alert when input is empty on node deselected.
func _on_node_deselected() -> void:
	_on_target_input_focus_exited()


## Hide active error alert on node destroy.
func _on_tree_exiting() -> void:
	if get_parent() and _target_error_alert:
		get_parent().alerts.hide_alert(_target_error_alert)
