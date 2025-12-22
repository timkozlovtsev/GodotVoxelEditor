class_name PaletteHandler extends Node
## Класс, отвечающий за работу с цветовой палитрой.
##
## Реализует хранение и изменение цветовой палитры.

# Ссылка на контейнер для кнопок. Кнопки используются для установки выбранного индекса палитры и отображения цветов.
@export var _button_container : GridContainer
# Ссылка на пипетку. Используется для установки цвета в палитре по выбранному индексу.
@export var _color_picker : ColorPickerButton
## Стиль кнопки в нормальном состоянии.
@export var button_normal_stylebox : StyleBox
## Стиль кнопки в нажатом состоянии.
@export var button_pressed_stylebox : StyleBox
## Стиль кнопки при наведении мыши.
@export var button_hover_stylebox : StyleBox

## Вызывается при изменении цветовой палитры.
signal palette_changed(colors: Array[Color])

# Массив кнопок.
var _buttons : Array[Button]
# Массив цветов.
var _colors : Array[Color]
# Выбранный индекс палитры.
var _selected_button_index : int = 1

func _ready() -> void:
	_colors.resize(256)
	_buttons.resize(256)
	for i in range(1, 256):
		var button := Button.new()
		button.pressed.connect(_on_button_pressed.bind(i))
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.size_flags_vertical = Control.SIZE_EXPAND_FILL
		button.add_theme_stylebox_override("normal", button_normal_stylebox.duplicate())
		button.add_theme_stylebox_override("pressed", button_pressed_stylebox.duplicate())
		button.add_theme_stylebox_override("hover", button_hover_stylebox.duplicate())
		button.focus_mode = Control.FOCUS_CLICK
		_buttons[i] = button
		_set_color(i, Color.from_hsv(i / 255., 1, 1))
		_button_container.add_child(button)
	_color_picker.color = _colors[1]
	palette_changed.emit(_colors)


# Устанавливает выбранный индекс при нажатии соответствующей кнопки.
func _on_button_pressed(id: int) -> void:
	if id == 0:
		return
	_selected_button_index = id
	_color_picker.color = _colors[id]


# Вызывается при подтверждении выбора цвета пипеткой.
func _on_color_picker_button_color_changed(color: Color) -> void:
	_set_color(_selected_button_index, color)
	palette_changed.emit(_colors)


# Устанавливает цвет в палитре по выбранному индексу.
func _set_color(id: int, color: Color) -> void:
	_colors[id] = color
	(_buttons[id].get_theme_stylebox("normal") as StyleBoxFlat).bg_color = color
	(_buttons[id].get_theme_stylebox("hover") as StyleBoxFlat).bg_color = color


## Возвращает цвета палитры.
func get_colors() -> Array[Color]:
	return _colors


## Устанавливает цвета палитры.
func set_colors(colors: Array[Color]) -> void:
	for i in range(1, 256):
		_set_color(i, colors[i - 1])
	palette_changed.emit(_colors)


## Возвращает выбранный индекс палитры.
func get_selected_index() -> int:
	return _selected_button_index
