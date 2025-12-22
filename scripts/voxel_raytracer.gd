class_name VoxelRaytracer
## Внутренний класс, реализующий трассировку луча по воксельной сетке.

const FLOAT_MAX : float = 3.4028235e+38;

var _grid : VoxelGrid


func _init(grid: VoxelGrid):
	_grid = grid


func _get_normal(axis: int, istep: Vector3i) -> Vector3i:
	return [
		Vector3i(-istep.x, 0, 0),
		Vector3i(0, -istep.y, 0),
		Vector3i(0, 0, -istep.z)
	][axis];


func _grid_traversal(origin: Vector3, dir: Vector3) -> Dictionary:
	var inv_dir := dir.inverse()
	var sgn_dir := Vector3(sign(inv_dir.x), sign(inv_dir.y), sign(inv_dir.z));
	inv_dir.x = clamp(inv_dir.x, -FLOAT_MAX, FLOAT_MAX)
	inv_dir.y = clamp(inv_dir.y, -FLOAT_MAX, FLOAT_MAX)
	inv_dir.z = clamp(inv_dir.z, -FLOAT_MAX, FLOAT_MAX)
	var aabb = AABB(Vector3.ZERO, _grid.grid_resolution)
	var res = aabb.intersects_ray(origin, dir)
	var ret = Dictionary()
	if res == null:
		ret["valid"] = false
		return ret
	origin = res - dir * 0.0001

	var coord := Vector3i(floor(origin))
	var t := (Vector3(coord) - origin + 0.5 * (Vector3.ONE + sgn_dir)) * inv_dir

	@warning_ignore("narrowing_conversion")
	var istep := Vector3i(sgn_dir.x, sgn_dir.y, sgn_dir.z)
	var delta := inv_dir * sgn_dir

	@warning_ignore("unused_variable")
	var axis : int = 0
	while true:
		if t.x < t.y:
			if t.x < t.z:
				axis = 0
				coord.x += istep.x
				if coord.x < 0 || coord.x >= _grid.grid_resolution.x:
					#coord.x -= istep.x
					break
				t.x += delta.x
			else:
				axis = 2
				coord.z += istep.z
				if coord.z < 0 || coord.z >= _grid.grid_resolution.z:
					#coord.z -= istep.z
					break
				t.z += delta.z
		else:
			if t.y < t.z:
				axis = 1
				coord.y += istep.y
				if coord.y < 0 || coord.y >= _grid.grid_resolution.y:
					#coord.y -= istep.y
					break
				t.y += delta.y
			else:
				axis = 2
				coord.z += istep.z
				if coord.z < 0 || coord.z >= _grid.grid_resolution.z:
					#coord.z -= istep.z
					break
				t.z += delta.z
		var voxel = _grid.get_voxel_index(coord)
		if voxel["valid"]:
			if voxel["index"] != _grid.EMPTY_VOX_ID:
				break
	ret["valid"] = true
	ret["coord"] = coord
	ret["normal"] = _get_normal(axis, istep)
	return ret


func _trace_ray(from_mouse_pos: Vector2) -> Array[Vector3i]:
	var dir = _grid.camera.project_ray_normal(from_mouse_pos)
	var origin = _grid.camera.global_position
	var res = _grid_traversal(origin, dir)
	if res["valid"]:
		return [res["coord"], res["normal"]]
	return [-Vector3i.ONE, -Vector3i.ONE]
