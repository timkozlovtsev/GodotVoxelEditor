class_name ComputeHandler extends Node
## Класс, отвечающий за работу с вычислительными шейдерами.
##
## Реализует рендеринг и редактирование воксельной сетки.


@export var sub_viewport : SubViewport
@export var camera : Camera3D
@export var texture_size_mult := 1.0

const STATE_FLAG_MASK_CHANGED : int = 1
const STATE_FLAG_RECALCULATE_VOX_MASK : int = 2

const MASK_BIT : int = 1;
const MARK_FOR_EDITING_BIT : int = 2;
const VISITED_BIT : int = 4;

var _rd := RenderingServer.get_rendering_device()
var _rendering_shader := _load_shader("res://shaders/compute_renderer.glsl")
var _editing_shader := _load_shader("res://shaders/compute_editor.glsl")
var _rendering_pipeline := _rd.compute_pipeline_create(_rendering_shader)
var _editing_pipeline := _rd.compute_pipeline_create(_editing_shader)

@onready var _texture_size : Vector2i = sub_viewport.size * texture_size_mult
var _texture_rd_2d : RID
var _texture_rd_3d_A : RID
var _texture_rd_3d_B : RID
var _texture_rd_3d_voxmask : RID
var _render_texture := Texture2DRD.new()
var _render_from_A : bool

var _camera_data_buffer : RID
var _voxel_data_buffer : RID
var _palette_data_buffer : RID
var _editing_data_buffer : RID
var _uniform_camera_data_buffer : RDUniform
var _uniform_palette_data_buffer : RDUniform
var _uniform_editing_data_buffer : RDUniform
var _uniform_texture_rd_2d : RDUniform
var _uniform_texture_rd_3d_A : RDUniform
var _uniform_texture_rd_3d_B : RDUniform
var _uniform_texture_rd_3d_voxmask : RDUniform
var _rendering_uniform_set : RID
var _editing_uniform_set : RID

## Разрешение воксельной сетки
var grid_resolution : Vector3i
var _camera_projection : Projection
var _projection_bytes : PackedByteArray
var _camera_basis : Basis
var _camera_origin : Vector3
var _transform_bytes : PackedByteArray

## Координаты активного вокселя.
var active_voxel := -Vector3i.ONE
## Нормаль грани активного вокселя, на которую указывает мышь.
var active_voxel_normal := Vector3i.ZERO
## Координаты второстепенного вокселя.
var secondary_voxel := -Vector3i.ONE
## Нормаль грани второстепенного вокселя, на которую указывает мышь.
var secondary_voxel_normal := Vector3i.ZERO

## Идентификатор используемого инструмента редактирования.
var editing_tool : int
## Идентификатор используемого типа выделения.
var editing_selection_type : int
## Индекс используемого цвета.
var editing_color_index : int
## Размер инструмента кисть.
var brush_size : int

var _initialized := false
var _editing_state_flags : int

var _zero_mask = PackedByteArray()

func _ready() -> void:
	ProjectSettings.set_setting("physics/common/physics_fps", 45)
	_init_compute()


## Устанавливает воксели для рендеринга и редактирования
func set_voxels(voxels: PackedByteArray) -> void:
	_rd.texture_update(_texture_rd_3d_A, 0, voxels)
	_rd.texture_update(_texture_rd_3d_B, 0, voxels)
	_render_from_A = true
	compute_render()


## Устанавливает разрешение воксельной сетки
func set_voxel_resolution(old_resolution: Vector3i, resolution: Vector3i) -> void:
	if old_resolution == resolution:
		return
	grid_resolution = resolution
	_init_texture_3d()
	_create_rendering_uniform_set()
	_create_editing_uniform_set()


## Выполняет рендеринг воксельной сетки
func compute_render() -> void:
	_camera_projection = camera.get_camera_projection()
	_camera_projection = _camera_projection.inverse()
	_projection_bytes = PackedFloat32Array([
		_camera_projection[0][0], _camera_projection[0][1], _camera_projection[0][2], _camera_projection[0][3],
		_camera_projection[1][0], _camera_projection[1][1], _camera_projection[1][2], _camera_projection[1][3],
		_camera_projection[2][0], _camera_projection[2][1], _camera_projection[2][2], _camera_projection[2][3],
		_camera_projection[3][0], _camera_projection[3][1], _camera_projection[3][2], _camera_projection[3][3]
	]).to_byte_array()

	_camera_basis = camera.global_transform.basis
	_camera_origin = camera.global_transform.origin
	_transform_bytes = PackedFloat32Array([
		_camera_basis.x.x, _camera_basis.x.y, _camera_basis.x.z, 1.0,
		_camera_basis.y.x, _camera_basis.y.y, _camera_basis.y.z, 1.0,
		_camera_basis.z.x, _camera_basis.z.y, _camera_basis.z.z, 1.0,
		_camera_origin.x, _camera_origin.y, _camera_origin.z, 1.0
	]).to_byte_array()
	_projection_bytes.append_array(_transform_bytes)

	var grid_data_bytes = _create_grid_data()

	_rd.buffer_update(_camera_data_buffer, 0, _projection_bytes.size(), _projection_bytes)
	var x_groups := ceili(_texture_size.x / 16.)
	var y_groups := ceili(_texture_size.y / 16.)
	var compute_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(compute_list, _rendering_pipeline)
	_rd.compute_list_bind_uniform_set(compute_list, _rendering_uniform_set, 0)
	_rd.compute_list_set_push_constant(compute_list, grid_data_bytes, grid_data_bytes.size())
	_rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
	_rd.compute_list_end()


## Выполняет редактирование воксельной сетки
func compute_edit(editing_just_started: bool, commit: bool) -> PackedByteArray:
	if editing_just_started:
		_switch_rendering_texture()
		_rd.texture_update(_texture_rd_3d_voxmask, 0, _zero_mask)
		_editing_state_flags = 0
		_editing_state_flags |= STATE_FLAG_RECALCULATE_VOX_MASK
	var grid_data_bytes = _create_grid_data()
	var x_groups := ceili(grid_resolution.x / 8.)
	var y_groups := ceili(grid_resolution.y / 8.)
	var z_groups := ceili(grid_resolution.z / 8.)
	while true:
		_editing_state_flags &= ~STATE_FLAG_MASK_CHANGED
		var editing_data_bytes := PackedInt32Array([
			editing_tool,
			editing_selection_type,
			editing_color_index,
			_editing_state_flags,
			brush_size
		]).to_byte_array()
		_rd.buffer_update(_editing_data_buffer, 0, editing_data_bytes.size(), editing_data_bytes)
		var compute_list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(compute_list, _editing_pipeline)
		_rd.compute_list_bind_uniform_set(compute_list, _editing_uniform_set, 0)
		_rd.compute_list_set_push_constant(compute_list, grid_data_bytes, grid_data_bytes.size())
		_rd.compute_list_dispatch(compute_list, x_groups, y_groups, z_groups)
		_rd.compute_list_end()
		editing_data_bytes = _rd.buffer_get_data(_editing_data_buffer, 0, 16)
		_editing_state_flags = editing_data_bytes.decode_u32(12)
		if !_has_flag(_editing_state_flags, STATE_FLAG_MASK_CHANGED):
			_editing_state_flags &= ~STATE_FLAG_RECALCULATE_VOX_MASK
			break
	if commit:
		if _render_from_A:
			return _rd.texture_get_data(_texture_rd_3d_A, 0)
		else:
			return _rd.texture_get_data(_texture_rd_3d_B, 0)
	return PackedByteArray()


# Меняет трехмерную текстуру, на основе которой произодится рендеринг.
func _switch_rendering_texture() -> void:
	_render_from_A = not _render_from_A


# Инициализирует выходную текстуру.
func _init_texture_2d() -> void:
	var tf_2d = RDTextureFormat.new()
	tf_2d.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	tf_2d.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	tf_2d.width = _texture_size.x
	tf_2d.height = _texture_size.y
	tf_2d.usage_bits = (
			RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
			RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
			RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
		)
	_texture_rd_2d = _rd.texture_create(tf_2d, RDTextureView.new())
	_uniform_texture_rd_2d = _create_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, _texture_rd_2d, 3)
	_init_render_texture()


# Инициализирует трехмерные текстуры для хранения данных воксельной сетки.
func _init_texture_3d() -> void:
	var tf_3d = RDTextureFormat.new()
	tf_3d.format = RenderingDevice.DATA_FORMAT_R8_UINT
	tf_3d.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	tf_3d.width = grid_resolution.x
	tf_3d.height = grid_resolution.y
	tf_3d.depth = grid_resolution.z
	tf_3d.usage_bits = (
			RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
			RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
			RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT |
			RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	)
	_texture_rd_3d_A = _rd.texture_create(tf_3d, RDTextureView.new())
	_texture_rd_3d_B = _rd.texture_create(tf_3d, RDTextureView.new())
	_uniform_texture_rd_3d_A = _create_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, _texture_rd_3d_A, 0)
	_uniform_texture_rd_3d_B = _create_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, _texture_rd_3d_B, 1)

	var mask = PackedInt32Array()
	mask.resize(grid_resolution.x * grid_resolution.y * grid_resolution.z)
	mask.fill(0)
	_zero_mask = mask.to_byte_array()
	tf_3d.format = RenderingDevice.DATA_FORMAT_R32_UINT
	_texture_rd_3d_voxmask = _rd.texture_create(tf_3d, RDTextureView.new())
	_uniform_texture_rd_3d_voxmask = _create_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, _texture_rd_3d_voxmask, 3)


# Устанавливает выходную текстуру в качестве текстуры, которая будет отображаться на экране
func _init_render_texture() -> void:
	_render_texture.texture_rd_rid = _texture_rd_2d
	sub_viewport.get_node("TextureRect").texture = _render_texture


# Инициализирует буфер данных камеры.
func _init_camera_data_buffer() -> void:
	_camera_data_buffer = _rd.storage_buffer_create(128)
	_uniform_camera_data_buffer = _create_uniform(
		RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, _camera_data_buffer, 4)


# Инициализирует буфер данных цветовой палитры.
func _init_palette_data_buffer() -> void:
	if _palette_data_buffer.is_valid():
		return
	_palette_data_buffer = _rd.storage_buffer_create(256 * 4 * 4)
	_uniform_palette_data_buffer = _create_uniform(
		RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, _palette_data_buffer, 2)


# Инициализирует буфер данных редактирования.
func _init_editing_data_buffer() -> void:
	if _editing_data_buffer.is_valid():
		return
	_editing_data_buffer = _rd.storage_buffer_create(20)
	_uniform_editing_data_buffer = _create_uniform(
		RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, _editing_data_buffer, 2)


# Запускает инициализацию всех необходимых буферов, текстур
# и создает коллекции универсальных наборов данных.
func _init_compute():
	_init_texture_2d()
	_init_texture_3d()
	_init_camera_data_buffer()
	_init_palette_data_buffer()
	_init_editing_data_buffer()
	_initialized = true
	_create_rendering_uniform_set()
	_create_editing_uniform_set()


# Создает новый набор универсальных данных.
func _create_uniform(type: RenderingDevice.UniformType, rid: RID, binding: int) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = type
	uniform.binding = binding
	uniform.add_id(rid)
	return uniform


# Создает коллекцию универсальных наборов данных для рендеринга.
func _create_rendering_uniform_set() -> void:
	if not _initialized:
		return
	if _rendering_uniform_set.is_valid():
		_rd.free_rid(_rendering_uniform_set)
	_rendering_uniform_set = _rd.uniform_set_create(
		[_uniform_camera_data_buffer,
		_uniform_palette_data_buffer,
		_uniform_texture_rd_2d,
		_uniform_texture_rd_3d_A,
		_uniform_texture_rd_3d_B],
		_rendering_shader, 0)


# Создает коллекцию универсальных наборов данных для редактирования.
func _create_editing_uniform_set() -> void:
	if not _initialized:
		return
	if _editing_uniform_set.is_valid():
		_rd.free_rid(_editing_uniform_set)
	_editing_uniform_set = _rd.uniform_set_create(
		[_uniform_texture_rd_3d_A,
		_uniform_texture_rd_3d_B,
		_uniform_editing_data_buffer,
		_uniform_texture_rd_3d_voxmask],
		_editing_shader, 0)


# Создает данные воксельной сетки.
func _create_grid_data() -> PackedByteArray:
	var _dummy : int = 0
	return PackedInt32Array([
		active_voxel.x,
		active_voxel.y,
		active_voxel.z,
		0,
		active_voxel_normal.x,
		active_voxel_normal.y,
		active_voxel_normal.z,
		0,
		secondary_voxel.x,
		secondary_voxel.y,
		secondary_voxel.z,
		0,
		secondary_voxel_normal.x,
		secondary_voxel_normal.y,
		secondary_voxel_normal.z,
		0,
		grid_resolution.x,
		grid_resolution.y,
		grid_resolution.z,
		0,
		int(_render_from_A),
		_dummy,
		_dummy,
		_dummy
	]).to_byte_array()


func _exit_tree() -> void:
	_free_rids()


# Освобождает память от объектов.
func _free_rids() -> void:
	_rd.free_rid(_texture_rd_2d)
	_rd.free_rid(_texture_rd_3d_A)
	_rd.free_rid(_texture_rd_3d_B)
	_rd.free_rid(_texture_rd_3d_voxmask)
	_rd.free_rid(_camera_data_buffer)
	_rd.free_rid(_voxel_data_buffer)
	_rd.free_rid(_editing_data_buffer)
	_rd.free_rid(_palette_data_buffer)
	_rd.free_rid(_rendering_uniform_set)
	_rd.free_rid(_editing_uniform_set)
	_rd.free_rid(_editing_shader)
	_rd.free_rid(_rendering_shader)


# Обновляет параметры выходной текстуры при изменении размера окна.
func _on_sub_viewport_size_changed() -> void:
	if not is_node_ready():
		return
	_texture_size = sub_viewport.size * texture_size_mult
	_init_texture_2d()
	_create_rendering_uniform_set()
	compute_render()


# Обновляет буфер цветовой палитры при ее изменении.
func _on_color_handler_palette_changed(colors: Array[Color]) -> void:
	var vectors := PackedVector4Array()
	vectors.resize(256)
	if not _palette_data_buffer.is_valid():
		_init_palette_data_buffer()
	for i in range(256):
		vectors[i].x = colors[i].r
		vectors[i].y = colors[i].g
		vectors[i].z = colors[i].b
		vectors[i].w = 1.0
	var bytes = vectors.to_byte_array()
	_rd.buffer_update(_palette_data_buffer, 0, bytes.size(), bytes)
	_create_rendering_uniform_set()


# Загружает шейдер из файла.
func _load_shader(path: String) -> RID:
	var shader_file := load(path)
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	return _rd.shader_create_from_spirv(shader_spirv)


# Возвращает [code]true[/code], если набор флагов [param flags] содержит флаг [param bit].
func _has_flag(flags: int, bit: int) -> bool:
	return (flags & bit) == bit
