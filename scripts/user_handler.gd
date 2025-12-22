class_name UserHandler extends Node
## Класс, отвечающий за обработку пользовательского ввода.
##
## Обрабатывает нажатия на кнопки выбора инструментов, выбора типа выделения, сохранения и загрузки.
## Реализует перемещение и поворот камеры.
## Вызывает методы рендеринга, редактирования и установки активных вокселей у воксельной сетки.

const _action_viewport_click := "viewport_click"
const _action_orbit_view := "orbit_view"
const _action_pan_view := "pan_view"
const _action_zoom_out_view := "zoom_out_view"
const _action_zoom_in_view := "zoom_in_view"

## Инструменты редактирования.
enum Tool {
	Add = 1, ## Инструмент добавления вокселей.
	Delete = 2, ## Инструмент удаления вокселей.
	Paint = 3 ## Инструмент покраски вокселей.
}

## Типы выделения вокселей.
enum SelectionType {
	Box = 1, ## Выделение вокселей прямоугольным параллелепипедом.
	Face = 2, ## Выделение смежных вокселей, лежащих в одной плоскости.
	Brush = 3 ## Выделение вокселей сферической кистью.
}

# Ссылка на SubViewport, на который рендерится изображение.
@export var _sub_viewport : SubViewport
# Ссылка на объект воксельной сетки.
@export var _voxel_grid : VoxelGrid
# Ссылка на основную камеру.
@export var _camera : Camera3D
# Чувствительность перемещения камеры по орбите вокруг модели.
@export var _orbit_sensitivity : float
# Чувствительность панорамирования камеры.
@export var _pan_sensitivity : float


@export var _file_name_label : Label
@export var _resolution_x_line_edit : LineEdit
@export var _resolution_y_line_edit : LineEdit
@export var _resolution_z_line_edit : LineEdit
@export var _tool_add_button : Button
@export var _tool_delete_button : Button
@export var _tool_paint_button : Button
@export var _selection_type_box_button : Button
@export var _selection_type_face_button : Button
@export var _selection_type_brush_button : Button
@export var _brush_radius_line_edit : LineEdit
@export var _save_button : Button
@export var _save_as_button : Button
@export var _load_button : Button

var _current_path := ""

var _mouse_position := Vector2.ZERO
var _mouse_delta := Vector2.ZERO
var _pivot_offset := Vector3.ZERO
var _editing_selection_type := SelectionType.Box
var _editing_tool := Tool.Add

func _ready() -> void:
	_resolution_x_line_edit.text_submitted.connect(_set_resolution)
	_resolution_y_line_edit.text_submitted.connect(_set_resolution)
	_resolution_z_line_edit.text_submitted.connect(_set_resolution)
	_tool_add_button.pressed.connect(_on_tool_add_button_pressed)
	_tool_delete_button.pressed.connect(_on_tool_delete_button_pressed)
	_tool_paint_button.pressed.connect(_on_tool_paint_button_pressed)
	_selection_type_box_button.pressed.connect(_on_selection_type_box_button_pressed)
	_selection_type_face_button.pressed.connect(_on_selection_type_face_button_pressed)
	_selection_type_brush_button.pressed.connect(_on_selection_type_brush_button_pressed)
	_brush_radius_line_edit.text_submitted.connect(_on_brush_size_line_edit_text_submitted)
	_save_button.pressed.connect(_on_save_button_pressed)
	_save_as_button.pressed.connect(_on_save_as_button_pressed)
	_load_button.pressed.connect(_on_load_button_pressed)

	_voxel_grid.grid_resolution_applied.connect(_on_grid_resolution_applied)
	_voxel_grid.compute_handler.brush_size = 1


func _physics_process(delta: float) -> void:
	var need_to_be_rendered := _process_camera(delta)
	_process_editing()
	if need_to_be_rendered:
		_process_rendering()


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_mouse_position = event.position
		_mouse_delta = event.relative


func _process_camera(delta: float) -> bool:
	var mouse_pos = _sub_viewport.get_mouse_position()
	if !_sub_viewport.get_visible_rect().has_point(mouse_pos):
		return false

	var pivot := _voxel_grid.get_grid_center()
	var cam_global := _camera.global_position
	var zoom_input : float = 0
	var need_to_be_rendered := _mouse_delta != Vector2.ZERO
	if Input.is_action_just_pressed(_action_zoom_in_view):
		zoom_input = -1
	if Input.is_action_just_pressed(_action_zoom_out_view):
		zoom_input = 1
	if zoom_input != 0:
		need_to_be_rendered = true
	_camera.translate_object_local(Vector3(0, 0, zoom_input * 2))
	if _camera.global_basis.z.dot(_camera.global_position - pivot - _pivot_offset) < 0:
		_camera.global_position = pivot + _pivot_offset + _camera.basis.z * .01

	if Input.is_action_pressed(_action_pan_view):
		var translation = Vector3(-_mouse_delta.x, _mouse_delta.y, 0) * delta * _pan_sensitivity
		translation = _camera.global_basis * translation
		_pivot_offset += translation
		_camera.global_translate(translation)
		need_to_be_rendered = true

	if Input.is_action_pressed(_action_orbit_view):
		var rotY = Quaternion(Vector3.UP, -_mouse_delta.x * delta * _orbit_sensitivity)
		var rotX = Quaternion(_camera.basis.x, -_mouse_delta.y * delta * _orbit_sensitivity)
		var new : Vector3 = rotY * (cam_global - pivot - _pivot_offset)
		if (rotX * new).normalized().signed_angle_to(Vector3.UP, -_camera.basis.x) > deg_to_rad(.001):
			new = rotX * new
		_camera.global_position = new + pivot + _pivot_offset
		_camera.look_at(pivot + _pivot_offset)
		need_to_be_rendered = true
	_mouse_delta = Vector2.ZERO
	return need_to_be_rendered


func _process_rendering() -> void:
	_voxel_grid.compute_rendering()


func _process_editing() -> void:
	var mouse_pos = _sub_viewport.get_mouse_position()
	if !_sub_viewport.get_visible_rect().has_point(mouse_pos):
		return
	if Input.is_action_just_pressed("ui_undo"):
		_voxel_grid.undo()
		return
	if Input.is_action_just_pressed("ui_redo"):
		_voxel_grid.redo()
		return

	var editing_just_started := Input.is_action_just_pressed(_action_viewport_click)
	var commit_changes := Input.is_action_just_released(_action_viewport_click)

	if Input.is_action_pressed(_action_viewport_click):
		_voxel_grid.update_secondary_voxel(mouse_pos)
		_voxel_grid.compute_editing(_editing_tool, _editing_selection_type, editing_just_started, commit_changes)
	else:
		if commit_changes:
			_voxel_grid.compute_editing(_editing_tool, _editing_selection_type, editing_just_started, commit_changes)
		_voxel_grid.update_active_voxel(mouse_pos)
		_voxel_grid.compute_rendering()


func _reset_view() -> void:
	_camera.global_position = _voxel_grid.get_grid_center() * 3
	_camera.look_at(_voxel_grid.get_grid_center())
	_pivot_offset = Vector3.ZERO


func _set_resolution(_text: String = "") -> void:
	var resolution = Vector3i.ZERO
	var x = _resolution_x_line_edit.text
	var y = _resolution_y_line_edit.text
	var z = _resolution_z_line_edit.text
	if x.is_valid_int():
		resolution.x = x.to_int()
	if y.is_valid_int():
		resolution.y = y.to_int()
	if z.is_valid_int():
		resolution.z = z.to_int()
	_voxel_grid.set_voxel_resolution(resolution)


func _on_grid_resolution_applied(old_resolution: Vector3i, new_resolution: Vector3i) -> void:
	if new_resolution != old_resolution:
		_reset_view()
	_resolution_x_line_edit.text = str(new_resolution.x)
	_resolution_y_line_edit.text = str(new_resolution.y)
	_resolution_z_line_edit.text = str(new_resolution.z)


func _on_save_button_pressed() -> void:
	var path : String
	if _current_path.is_empty():
		path = await _voxel_grid.save_vox()
	else:
		path = await _voxel_grid.save_vox(_current_path)
	if not path.is_empty():
		_current_path = path
		_file_name_label.text = path


func _on_load_button_pressed() -> void:
	var path := await _voxel_grid.load_vox()
	if not path.is_empty():
		_current_path = path
		_file_name_label.text = path
		_reset_view()


func _on_save_as_button_pressed() -> void:
	var path := await _voxel_grid.save_vox()
	if not path.is_empty():
		_file_name_label.text = path


func _on_selection_type_brush_button_pressed() -> void:
	_editing_selection_type = SelectionType.Brush


func _on_selection_type_face_button_pressed() -> void:
	_editing_selection_type = SelectionType.Face


func _on_selection_type_box_button_pressed() -> void:
	_editing_selection_type = SelectionType.Box


func _on_tool_paint_button_pressed() -> void:
	_editing_tool = Tool.Paint


func _on_tool_delete_button_pressed() -> void:
	_editing_tool = Tool.Delete


func _on_tool_add_button_pressed() -> void:
	_editing_tool = Tool.Add


func _on_brush_size_line_edit_text_submitted(text: String) -> void:
	if text.is_valid_int:
		var brush_size = text.to_int()
		if 1 <= brush_size:
			if brush_size <= _voxel_grid.grid_resolution.x:
				_voxel_grid.compute_handler.brush_size = brush_size
			elif brush_size <= _voxel_grid.grid_resolution.y:
				_voxel_grid.compute_handler.brush_size = brush_size
			elif brush_size <= _voxel_grid.grid_resolution.z:
				_voxel_grid.compute_handler.brush_size = brush_size
