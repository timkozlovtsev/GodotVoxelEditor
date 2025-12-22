class_name VoxFormat
## Класс, отвечающий за работу с форматом [code].vox[/code].
##
## Реализует функции кодирования и декодирования воксельных моделей в формат [code].vox[/code].

# Идентификаторы чанков.
const ID_VOX := "VOX "
const VERSION := 150
const ID_MAIN := "MAIN"
const ID_SIZE := "SIZE"
const ID_XYZI := "XYZI"
const ID_RGBA := "RGBA"
const ID_OK := "Ok"
const ID_ERROR := "Error"
const ID_ERROR_SIZE := "Error: SIZE"
const ID_ERROR_MAIN := "Error: MAIN"
const ID_ERROR_XYZI := "Error: XYZI"
const ID_ERROR_RGBA := "Error: XYZI"
const ID_UNKNOWN := "Unknown"

static var _is_main_chunk_readed := false
static var _current_chunk_id := ""
static var _voxels_buffer := PackedByteArray()
static var _voxels_resolution : Vector3i
static var _palette_array : Array[Color] = []


## Сохраняет воксельную сетку в файл [code].vox[/code] формата.[br]
## Принимает воксельную сетку [param voxels], ее разрешение [param resolution],
## цветовую палитру [param palette] и опциональный параметр [param optional_path] - путь сохранения.
## Если путь не задан, будет вызвано диалоговое окно для выбора пути.[br]
## При успешном выполнении возвращает путь, по которому файл сохранен, иначе возвращает пустую строку.
static func encode(voxels: PackedByteArray, resolution: Vector3i, palette: Array[Color], optional_path: String = "") -> String:
	var path : String
	if optional_path.is_empty():
		path = await _file_dialog(FileDialog.FILE_MODE_SAVE_FILE)
	else:
		path = optional_path
	if path.is_empty():
		return ""
	var file = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(ID_VOX)
	file.store_32(VERSION)

	var size_chunk_content := PackedByteArray()
	size_chunk_content.resize(12)
	size_chunk_content.encode_u32(0, resolution.x)
	size_chunk_content.encode_u32(4, resolution.z)
	size_chunk_content.encode_u32(8, resolution.y)
	var size_chunk = _create_chunk(ID_SIZE, size_chunk_content, [])

	var xyzi_chunk_content := PackedByteArray()
	xyzi_chunk_content.resize(4)
	var stored_voxels : int = 0
	for x in range(resolution.x):
		for y in range(resolution.y):
			for z in range(resolution.z):
				if voxels[_flatten(x, y, z, resolution)] != 0:
					xyzi_chunk_content.append(x)
					xyzi_chunk_content.append(resolution.z - 1 - z)
					xyzi_chunk_content.append(y)
					xyzi_chunk_content.append(voxels[_flatten(x, y, z, resolution)])
					stored_voxels += 1
	xyzi_chunk_content.encode_u32(0, stored_voxels)
	var xyzi_chunk = _create_chunk(ID_XYZI, xyzi_chunk_content, [])

	var rgba_chunk_content := PackedByteArray()
	for i in range(255):
		rgba_chunk_content.append(palette[i + 1].r8)
		rgba_chunk_content.append(palette[i + 1].g8)
		rgba_chunk_content.append(palette[i + 1].b8)
		rgba_chunk_content.append(255)
	rgba_chunk_content.append_array(PackedByteArray([0, 0, 0, 0]))
	var rgba_chunk = _create_chunk(ID_RGBA, rgba_chunk_content, [])

	var main_chunk = _create_chunk(ID_MAIN, PackedByteArray(), [size_chunk, xyzi_chunk, rgba_chunk])
	file.store_buffer(main_chunk)
	return path


## Загружает воксельную сетку и цветовую палитру из файла [code].vox[/code] формата.
## Принимает опциональный параметр [param optional_path] - путь сохранения.
## Если путь не задан, будет вызвано диалоговое окно для выбора пути.[br]
## При успешном выполнении возвращает словарь:[br]
## По ключу [code]"path"[/code] передается путь, по которому файл загружен.
## По ключу [code]"voxels"[/code] передается воксельная сетка.
## По ключу [code]"path"[/code] передается
## По ключу [code]"path"[/code] передается
static func decode(optional_path: String = "") -> Dictionary:
	var path : String
	if optional_path.is_empty():
		path = await _file_dialog(FileDialog.FILE_MODE_OPEN_FILE)
	else:
		path = optional_path
	if path.is_empty():
		return {}
	var file = FileAccess.open(path, FileAccess.READ)
	if file.get_buffer(4).get_string_from_ascii() != ID_VOX:
		return {}
	var _version = file.get_32()
	var res = _read_chunk(file)
	print(res)
	if res == ID_OK:
		var decoded := {}
		decoded["path"] = path
		decoded["voxels"] = _voxels_buffer.duplicate()
		decoded["resolution"] = _voxels_resolution
		decoded["palette"] = _palette_array.duplicate()
		_reset()
		return decoded
	_reset()
	return {}


static func _create_chunk(id: String, content: PackedByteArray, children: Array[PackedByteArray]) -> PackedByteArray:
	var chunk := PackedByteArray()
	chunk.append_array(id.to_ascii_buffer())
	chunk.resize(12)
	chunk.encode_u32(4, content.size())
	var children_size : int = 0
	for i in children:
		children_size += i.size()
	chunk.encode_u32(8, children_size)
	chunk.append_array(content)
	for i in children:
		chunk.append_array(i)
	return chunk


static func _read_chunk(file: FileAccess) -> String:
	var chunk_start = file.get_position()
	var id = file.get_buffer(4).get_string_from_ascii()
	var content_size := file.get_32()
	var child_size := file.get_32()
	if id == ID_MAIN:
		print("Reading " + id)
	else:
		print("\tReading " + id)
		print("\tContent size = " + str(content_size))
		print("\tChild size = " + str(child_size))
	match id:
		ID_MAIN:
			_current_chunk_id = ID_MAIN
			if _is_main_chunk_readed:
				return ID_ERROR_MAIN
			_is_main_chunk_readed = true
			_skip_bytes(file, content_size)
			while file.get_position() < chunk_start + child_size:
				print("\tResult " + _read_chunk(file))
			return ID_OK
		ID_SIZE:
			if _current_chunk_id == ID_SIZE:
				return ID_ERROR_SIZE
			_current_chunk_id = ID_SIZE
			if content_size != 12:
				return ID_ERROR_SIZE
			var x = file.get_32()
			var z = file.get_32()
			var y = file.get_32()
			_voxels_buffer.resize(x * y * z)
			_voxels_resolution = Vector3i(x, y, z)
			_skip_bytes(file, child_size)
			return ID_OK
		ID_XYZI:
			if _current_chunk_id != ID_SIZE:
				return ID_ERROR_XYZI
			_current_chunk_id = ID_XYZI
			if content_size < 4:
				return ID_ERROR_XYZI
			@warning_ignore("integer_division")
			var num_voxels = file.get_32()
			for k in range(num_voxels):
				var x = file.get_8()
				var z = _voxels_resolution.z - 1 - file.get_8()
				var y = file.get_8()
				var i = file.get_8()
				var index = _flatten(x, y, z, _voxels_resolution)
				if index >= _voxels_buffer.size():
					return ID_ERROR_XYZI
				_voxels_buffer[index] = i
			_skip_bytes(file, child_size)
			return ID_OK
		ID_RGBA:
			_current_chunk_id = ID_RGBA
			if content_size != 4 * 256:
				return ID_ERROR_RGBA
			_palette_array.resize(256)
			_palette_array.fill(Color.BLACK)
			for i in range(255):
				_palette_array[i].r8 = file.get_8()
				_palette_array[i].g8 = file.get_8()
				_palette_array[i].b8 = file.get_8()
				var _a = file.get_8()
			_skip_bytes(file, child_size)
			return ID_OK
	_skip_bytes(file, content_size + child_size)
	return ID_UNKNOWN + " " + id


static func _file_dialog(file_mode: FileDialog.FileMode) -> String:
	var fd := FileDialog.new()
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.file_mode = file_mode
	fd.mode = Window.MODE_MAXIMIZED
	fd.add_filter("*.vox")
	(Engine.get_main_loop() as SceneTree).root.add_child(fd)
	var viewport_rect = (Engine.get_main_loop() as SceneTree).root.get_viewport().get_visible_rect()
	print(viewport_rect.size)
	fd.popup()
	fd.size = viewport_rect.size
	await fd.file_selected
	var path = fd.current_path
	print(path)
	fd.queue_free()
	return path


static func _skip_bytes(file: FileAccess, bytes: int) -> void:
	file.seek(file.get_position() + bytes)


static func _flatten(x: int, y: int, z: int, size: Vector3i) -> int:
	return z * size.y * size.x + y * size.x + x


static func _reset() -> void:
	_is_main_chunk_readed = false
	_current_chunk_id = ""
	_voxels_buffer = PackedByteArray()
	_voxels_resolution = Vector3i.ZERO
	_palette_array = []
