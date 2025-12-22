class_name VoxelGrid extends Node
## Основной класс, отвечающий за работу с воксельной сеткой.
##
## Связывает обработчики цветовой палитры и вычислительных шейдеров.[br]
## Реализует хранение воксельной сетки и ее настроек, хранение истории изменений,
## хранение информации о активных вокселях.[br]
## Предоставляет методы для изменения настроек сетки, изменения и отображения вокселей, отмены/повторения действий,
## сохранения/загрузки в файл [code].vox[/code] формата.

const EMPTY_VOX_ID : int = 0

## Разрешение воксельной сетки
@export var grid_resolution := Vector3i(32, 32, 32)
## Ссылка на обработчик цветовой палитры
@export var palette_handler : PaletteHandler
## Ссылка на обработчик вычислительных шейдеров
@export var compute_handler : ComputeHandler
## Ссылка на камеру
@export var camera : Camera3D

## Основная воксельная сетка. Все действия выполняются на ней.[br]
## Данные упакованны в [PackedByteArray], где каждый байт отвечает за индекс соответствующего вокселя.[br]
## Не рекомендуется вручную изменять воксельную сетку. Но при необходимости можно использовать внутренние методы.[br]
## Для преобразования трехмерных координат вокселя в линейный индекс используется метод [method _flatten].[br]
## Для установки индекса вокселя по координатам используется метод [method _set_voxel].[br]
## Вносимые изменения не передаются в вычислительный шейдер и не сохраняются в истории изменений автоматически.
## Для ручной передачи и сохранения изменений используются методы [method _push_grid] и [method _update_grid_history].
var grid_3D := PackedByteArray()

# Переменные для работы истории изменений.
var _grid_3d_history : Array[PackedByteArray] = []
var _grid_resolution_history : Array[Vector3i] = []
var _history_index : int = 0
var _history_last_index : int = 0
var _history_max_size = 32

## Координаты активного вокселя.
var active_voxel := Vector3i.ZERO
## Нормаль грани активного вокселя, на которую указывает мышь.
var active_voxel_normal := Vector3i.ZERO
## Координаты второстепенного вокселя.
var secondary_voxel := Vector3i.ZERO
## Нормаль грани второстепенного вокселя, на которую указывает мышь.
var secondary_voxel_normal := Vector3i.ZERO

var _voxel_raytracer := VoxelRaytracer.new(self)
var _wait_for_file_dialog := false

## Вызывается при изменении разрешения сетки.
signal grid_resolution_applied(old_resolution: Vector3i, new_resolution: Vector3i)


func _ready() -> void:
	grid_3D.resize(grid_resolution.x * grid_resolution.y * grid_resolution.z)
	grid_3D.fill(EMPTY_VOX_ID)
	_apply_voxel_resolution(Vector3i.ZERO)
	_generate_model()
	_reset_grid_history()


## Устанавливает переменной [member grid_resolution] значение [param resolution].[br]
## Если [member grid_resolution] изменилось, сохраняет его в историю изменений.
func set_voxel_resolution(resolution: Vector3i) -> void:
	var old_resolution = grid_resolution
	for i in range(3):
		if resolution[i] > 0 and resolution[i] < 256:
			grid_resolution[i] = resolution[i]
	if old_resolution != grid_resolution:
		var new_grid = PackedByteArray()
		new_grid.resize(grid_resolution.x * grid_resolution.y * grid_resolution.z)
		new_grid.fill(EMPTY_VOX_ID)
		for x in range(old_resolution.x):
			for y in range(old_resolution.y):
				for z in range(old_resolution.z):
					var voxel = grid_3D[_flatten(Vector3i(x, y, z), old_resolution)]
					if _is_coord_valid(Vector3i(x, y, z), grid_resolution):
						new_grid[_flatten(Vector3i(x, y, z), grid_resolution)] = voxel
		_set_grid(new_grid)
		_update_grid_history()
	_apply_voxel_resolution(old_resolution)


## Запускает редактирование воксельной сетки с использованием интструмента [param editing_tool] и
## типа выделения [param editing_selection_type].
## Если [code]editing_just_started[/code] равно [code]true[/code], то принимается, что редактирование началось только что.
## Если [code]commit[/code] равно [code]true[/code], то сделанные изменения сохраняются,
## иначе метод работает как режим предпросмотра.
func compute_editing(editing_tool: UserHandler.Tool,
		editing_selection_type: UserHandler.SelectionType,
		editing_just_started: bool,
		commit: bool) -> void:
	if _wait_for_file_dialog:
		return
	compute_handler.editing_tool = int(editing_tool)
	compute_handler.editing_selection_type = int(editing_selection_type)
	compute_handler.editing_color_index = palette_handler.get_selected_index()
	var voxels = compute_handler.compute_edit(editing_just_started, commit)
	if commit:
		_set_grid(voxels)
		_update_grid_history()


## Запускает рендеринг воксельной сетки.
func compute_rendering() -> void:
	if _wait_for_file_dialog:
		return
	if compute_handler.is_node_ready():
		compute_handler.compute_render()


## Отменяет последнее действие
func undo() -> void:
	_change_history_index(-1)


## Повторяет последнее действие
func redo() -> void:
	_change_history_index(1)


func _change_history_index(change: int) -> void:
	if _wait_for_file_dialog:
		return
	var old_index = _history_index
	_history_index = clampi(_history_index + sign(change), 0, _history_last_index)
	if old_index == _history_index:
		return
	_set_grid(_grid_3d_history[_history_index])
	var old_resolution = grid_resolution
	grid_resolution = _grid_resolution_history[_history_index]
	_apply_voxel_resolution(old_resolution)


## Обновляет [member active_voxel] и [member active_voxel_normal] на основе
## вокселя, на который указывает луч, выпускаемый из позиции [param mouse_pos] в пространстве камеры.
func update_active_voxel(mouse_pos: Vector2) -> void:
	if _wait_for_file_dialog:
		return
	var voxels = _voxel_raytracer._trace_ray(mouse_pos)
	active_voxel = voxels[0]
	active_voxel_normal = voxels[1]
	compute_handler.active_voxel = active_voxel
	compute_handler.active_voxel_normal = active_voxel_normal


## Обновляет [member active_voxel] и [member active_voxel_normal] аналогично
## [method update_active_voxel]
func update_secondary_voxel(mouse_pos: Vector2) -> void:
	if _wait_for_file_dialog:
		return
	var voxels = _voxel_raytracer._trace_ray(mouse_pos)
	secondary_voxel = voxels[0]
	secondary_voxel_normal = voxels[1]
	compute_handler.secondary_voxel = secondary_voxel
	compute_handler.secondary_voxel_normal = secondary_voxel_normal


## Принимает координаты [param coord].[br]
## Возвращает словарь:[br]
## По ключу [code]"valid"[/code] передается [code]true[/code], если координаты валидные,
## иначе [code]false[/code].[br]
## По ключу [code]"index"[/code] передается индекс вокселя по координатам (только если координаты валидные).
func get_voxel_index(coord: Vector3i) -> Dictionary:
	var d := Dictionary()
	if _is_coord_valid(coord):
		if grid_3D[_flatten(coord)] != EMPTY_VOX_ID:
			d["valid"] = true
			d["index"] = grid_3D[_flatten(coord)]
			return d
	d["valid"] = false
	return d


## Возвращает центр воксельной сетки в мировом пространстве.
func get_grid_center() -> Vector3:
	return Vector3.ONE * (grid_resolution / 2.)


## Сохраняет модель в файл по пути [param optional_path] в [code].vox[/code] формате.
## Если путь пустой, то будет вызвано диалоговое окно для выбора пути.
## Возвращает путь, по которому файл сохранен.
func save_vox(optional_path : String = "") -> String:
	_wait_for_file_dialog = true
	var res = await VoxFormat.encode(grid_3D, grid_resolution, palette_handler.get_colors(), optional_path)
	_wait_for_file_dialog = false;
	return res


## Загружает модель из файла [code].vox[/code] формата. Перед загрузкой вызывает диалоговое окно для выбора пути до файла.
## Возвращает путь, по которому файл загружен.
func load_vox() -> String:
	_wait_for_file_dialog = true
	var decoded := await VoxFormat.decode()
	if decoded.size() == 0:
		return ""
	set_voxel_resolution(decoded["resolution"])
	_set_grid(decoded["voxels"])
	_reset_grid_history()
	_push_grid()
	palette_handler.set_colors(decoded["palette"])
	call_deferred("_stop_file_dialog_waiting")
	return decoded["path"]


# Создает начальную модель (заполняет воксельную сетку индексом 1).
func _generate_model() -> void:
	for z in range(grid_resolution.z):
		for y in range(grid_resolution.y):
			for x in range(grid_resolution.x):
				var coord = Vector3i(x, y, z)
				_set_voxel(coord, 1)
	_push_grid()


# Применяет новое разрешение воксельной сетки
func _apply_voxel_resolution(old_resolution: Vector3i) -> void:
	if not is_node_ready():
		return
	grid_resolution_applied.emit(old_resolution, grid_resolution)
	compute_handler.set_voxel_resolution(old_resolution, grid_resolution)
	_push_grid()


# Передает воксельную сетку в обработчик вычислительных шейдеров.
func _push_grid() -> void:
	compute_handler.call_deferred("set_voxels", grid_3D)


# Устанавливает индекс [param index] вокселю по координатам [param coord].
func _set_voxel(coord: Vector3i, index: int) -> void:
	if _is_coord_valid(coord):
		grid_3D[_flatten(coord)] = index


# Устанавливает воксельную сетку полностью.
func _set_grid(voxels: PackedByteArray) -> void:
	grid_3D = voxels;


# Возвращает трехмерные координаты [param coord], преобразованные в линейный индекс
# на основе разрешения сетки [param resolution].
func _flatten(coord: Vector3i, resolution: Vector3i = grid_resolution) -> int:
	return coord.z * resolution.y * resolution.x + coord.y * resolution.x + coord.x


# Возвращает [code]true[/code], если координаты [param coord] валидны для
# разрешения сетки [param resolution]
func _is_coord_valid(coord: Vector3i, resolution: Vector3i = grid_resolution) -> bool:
	for i in range(3):
		if coord[i] < 0 or coord[i] >= resolution[i]:
			return false
	return true


# Сбрасывает историю изменений.
func _reset_grid_history() -> void:
	_grid_3d_history.resize(_history_max_size)
	_grid_resolution_history.resize(_history_max_size)
	_grid_3d_history.fill(PackedByteArray())
	_grid_resolution_history.fill(Vector3i.ZERO)
	_grid_3d_history[0] = grid_3D
	_grid_resolution_history[0] = grid_resolution
	_history_index = 0
	_history_last_index = 0


# Устанавливает в [member _wait_for_file_dialog] значение [code]false[/code]
func _stop_file_dialog_waiting() -> void:
	_wait_for_file_dialog = false


# Сохраняет текущее состояние воксельной сетки в историю изменений
func _update_grid_history() -> void:
	_history_index = clampi(_history_index + 1, 0, _history_max_size - 1)
	_history_last_index = _history_index
	if _history_index == _history_max_size - 1:
		_grid_3d_history.pop_front()
		_grid_3d_history.push_back(grid_3D)
		_grid_resolution_history.pop_front()
		_grid_resolution_history.push_back(grid_resolution)
	else:
		_grid_3d_history[_history_index] = grid_3D
		_grid_resolution_history[_history_index] = grid_resolution
