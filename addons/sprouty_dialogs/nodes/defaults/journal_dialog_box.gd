@tool
extends DialogBox

@onready var _history_scroll: ScrollContainer = get_node_or_null("MainPanel/Margin/Layout/HistoryScroll")
@onready var _history_container: VBoxContainer = get_node_or_null("MainPanel/Margin/Layout/HistoryScroll/HistoryContainer")
@onready var _dialogue_entry_template: VBoxContainer = get_node_or_null("Templates/DialogueEntryTemplate")
@onready var _options_entry_template: VBoxContainer = get_node_or_null("Templates/OptionsEntryTemplate")

const OPTION_FADE_DURATION := 1.0
const OPTION_COLOR_NORMAL := Color(0.9, 0.9, 0.9, 1.0)
const OPTION_COLOR_DISABLED := Color(0.6, 0.6, 0.6, 1.0)
const OPTION_COLOR_HIGHLIGHT := Color(1.0, 0.9, 0.6, 1.0)
const SCROLL_SETTLE_FRAMES := 18

@export_category("Option Visuals")
@export var option_fade_duration: float = OPTION_FADE_DURATION
@export var option_color_normal: Color = OPTION_COLOR_NORMAL
@export var option_color_disabled: Color = OPTION_COLOR_DISABLED
@export var option_color_highlight: Color = OPTION_COLOR_HIGHLIGHT

var _current_speaker: String = ""
var _active_option_nodes: Array[DialogOption] = []

var _options_interactable: bool = false
var _is_typing_text: bool = false
var _is_fading_options: bool = false
var _pending_scroll_frames: int = 0

var _options_fade_tween: Tween


func _ready() -> void:
	super ()
	if is_instance_valid(_dialogue_entry_template):
		_dialogue_entry_template.visible = false
	if is_instance_valid(_options_entry_template):
		_options_entry_template.visible = false
	if is_instance_valid(option_template):
		option_template.visible = false
	if is_instance_valid(_history_container) and not _history_container.minimum_size_changed.is_connected(_on_history_content_resized):
		_history_container.minimum_size_changed.connect(_on_history_content_resized)


func _process(delta: float) -> void:
	if not _is_typing_text and not _is_fading_options and _pending_scroll_frames > 0:
		_pending_scroll_frames = max(0, _pending_scroll_frames - 1)

	if _should_force_bottom():
		_scroll_to_bottom()


func play_dialog(character_name: String, dialog: String) -> void:
	if not _is_started:
		await _on_dialog_box_open()

	hide_options()
	if not visible:
		show()

	_current_speaker = character_name
	_current_sentence = 0
	_sentences = []

	if dialog.is_empty():
		_sentences.append("")
	else:
		var dialog_lines := _split_dialog_by_lines(dialog)
		for line in dialog_lines:
			_sentences.append_array(_split_dialog_by_characters(line))

	_is_started = true
	_is_running = true
	_display_completed = false
	_display_new_sentence(_sentences[_current_sentence])
	dialog_starts.emit()


func display_options(options: Array, disabled_flags: Array = []) -> void:
	_is_displaying_options = true
	_options_interactable = false
	_is_fading_options = true

	if not is_instance_valid(_history_container):
		printerr("[SproutyDialogs] Journal dialog history container is not set.")
		return
	if not is_instance_valid(_options_entry_template):
		printerr("[SproutyDialogs] Journal options entry template is not set.")
		return
	if not is_instance_valid(option_template):
		printerr("[SproutyDialogs] Journal option template is not set.")
		return

	var options_entry := _options_entry_template.duplicate()
	options_entry.visible = true
	_history_container.add_child(options_entry)

	_active_option_nodes.clear()

	var selectable_index := 0
	for visual_index in options.size():
		var option_node := option_template.duplicate() as DialogOption
		if not is_instance_valid(option_node):
			continue

		option_node.set_text(str(options[visual_index]))
		option_node.add_theme_color_override("font_hover_color", option_color_highlight)
		option_node.add_theme_color_override("font_focus_color", option_color_highlight)
		option_node.add_theme_color_override("font_pressed_color", option_color_highlight)
		option_node.disabled = false
		option_node.focus_mode = Control.FOCUS_NONE
		option_node.mouse_filter = Control.MOUSE_FILTER_IGNORE

		var is_disabled: bool = visual_index < disabled_flags.size() and bool(disabled_flags[visual_index])
		var is_selectable := not is_disabled
		option_node.set_meta("sprouty_selectable", is_selectable)

		if is_selectable:
			var selectable_option_index := selectable_index
			selectable_index += 1
			option_node.pressed.connect(func(): option_selected.emit(selectable_option_index))
			option_node.mouse_entered.connect(_on_option_mouse_entered.bind(option_node))

		option_node.modulate = option_color_disabled if is_disabled else option_color_normal
		option_node.modulate.a = 0.0

		options_entry.add_child(option_node)
		option_node.show()
		_active_option_nodes.append(option_node)

	_scroll_to_bottom()
	_mark_content_changed()
	_on_options_displayed()
	show()
	_animate_options_in()


func hide_options() -> void:
	if is_instance_valid(_options_fade_tween):
		_options_fade_tween.kill()

	for option_node in _active_option_nodes:
		if not is_instance_valid(option_node):
			continue
		option_node.disabled = true
		option_node.focus_mode = Control.FOCUS_NONE
		option_node.modulate = option_color_disabled

	_active_option_nodes.clear()

	_options_interactable = false
	_is_fading_options = false
	_pending_scroll_frames = 0
	_is_displaying_options = false


func stop_dialog(close_dialog: bool = false) -> void:
	await super.stop_dialog(close_dialog)
	if close_dialog:
		_clear_history()


func _display_new_sentence(sentence: String) -> void:
	var entry := _new_dialogue_entry()
	if entry.is_empty():
		return

	name_display = entry["name"]
	dialog_display = entry["dialog"]
	name_display.text = _current_speaker
	name_display.visible = _current_speaker != ""

	dialog_display.text = sentence
	var regex := RegEx.new()
	regex.compile("\\[.*?\\]")
	var clean_sentence := regex.sub(sentence, "", true)
	_sentence_lenght = clean_sentence.length()

	_is_typing_text = true
	_mark_content_changed()

	if typing_speed <= 0.0 or not is_instance_valid(_type_timer):
		dialog_display.visible_characters = dialog_display.text.length()
		_on_display_completed()
	else:
		dialog_display.visible_characters = 0
		if continue_indicator:
			continue_indicator.hide()
		_display_completed = false
		_type_timer.start()

	_scroll_to_bottom()


func _on_display_completed() -> void:
	_is_typing_text = false
	_mark_content_changed()
	super._on_display_completed()


func _on_type_timer_timeout() -> void:
	super._on_type_timer_timeout()
	_mark_content_changed()
	_scroll_to_bottom()


func _should_force_bottom() -> bool:
	return _is_typing_text or _is_fading_options or _pending_scroll_frames > 0


func _scroll_to_bottom() -> void:
	if not is_instance_valid(_history_scroll):
		return
	var scroll_bar := _history_scroll.get_v_scroll_bar()
	if not is_instance_valid(scroll_bar):
		return
	_history_scroll.scroll_vertical = int(scroll_bar.max_value)


func _new_dialogue_entry() -> Dictionary:
	if not is_instance_valid(_dialogue_entry_template) or not is_instance_valid(_history_container):
		return {}

	var entry_root := _dialogue_entry_template.duplicate() as VBoxContainer
	entry_root.visible = true

	var name_label := entry_root.get_node_or_null("Name") as RichTextLabel
	var dialog_label := entry_root.get_node_or_null("Dialog") as RichTextLabel
	if not is_instance_valid(name_label) or not is_instance_valid(dialog_label):
		entry_root.queue_free()
		return {}

	dialog_label.bbcode_enabled = true
	if not dialog_label.meta_clicked.is_connected(_on_dialog_meta_clicked):
		dialog_label.meta_clicked.connect(_on_dialog_meta_clicked)

	_history_container.add_child(entry_root)

	return {
		"root": entry_root,
		"name": name_label,
		"dialog": dialog_label,
	}


func _clear_history() -> void:
	if not is_instance_valid(_history_container):
		return

	for child in _history_container.get_children():
		if child == _dialogue_entry_template or child == _options_entry_template:
			continue
		child.queue_free()


func _animate_options_in() -> void:
	if is_instance_valid(_options_fade_tween):
		_options_fade_tween.kill()
	_options_fade_tween = create_tween()

	for option_node in _active_option_nodes:
		if not is_instance_valid(option_node):
			continue
		_options_fade_tween.parallel().tween_property(option_node, "modulate:a", 1.0, option_fade_duration)

	_options_fade_tween.finished.connect(_on_options_fade_finished, CONNECT_ONE_SHOT)


func _on_options_fade_finished() -> void:
	_is_fading_options = false
	_options_interactable = true
	_mark_content_changed()

	for i in range(_active_option_nodes.size()):
		var option_node := _active_option_nodes[i]
		if not is_instance_valid(option_node):
			continue
		var selectable: bool = bool(option_node.get_meta("sprouty_selectable", false))
		option_node.disabled = not selectable
		option_node.focus_mode = Control.FOCUS_ALL if selectable else Control.FOCUS_NONE
		option_node.mouse_filter = Control.MOUSE_FILTER_STOP if selectable else Control.MOUSE_FILTER_IGNORE
		option_node.modulate = option_color_normal if selectable else option_color_disabled

	for option_node in _active_option_nodes:
		if not is_instance_valid(option_node):
			continue
		if option_node is Button and not option_node.disabled:
			(option_node as Button).grab_focus()
			break


func _mark_content_changed() -> void:
	_pending_scroll_frames = SCROLL_SETTLE_FRAMES


func _on_option_mouse_entered(option_node: DialogOption) -> void:
	if not _options_interactable:
		return
	if not is_instance_valid(option_node):
		return
	if option_node.disabled:
		return
	option_node.grab_focus()


func _on_history_content_resized() -> void:
	if _is_typing_text or _is_fading_options or _pending_scroll_frames > 0:
		_mark_content_changed()
