## Application shell.
##
## The interface is built in code rather than in a .tscn. That is deliberate:
## every widget and every wire-up is in one readable file that diffs cleanly and
## can be instantiated headlessly by the smoke test, which is worth more here
## than the convenience of the scene editor.
extends Control

const PALETTE_LIMIT := 320

var lib := AssetLibrary.new()
var view: MapView
var doc: MapDocument:
	get: return view.doc

# widgets
var _search: LineEdit
var _cats: OptionButton
var _tiles: ItemList
var _extras_only: CheckBox
var _stack: ItemList
var _token_list: ItemList
var _status: Label
var _inspector: VBoxContainer
var _size_slider: HSlider
var _rot_slider: HSlider
var _alpha_slider: HSlider
var _hue_slider: HSlider
var _sat_slider: HSlider
var _tool_buttons: Array[Button] = []
var _layer_buttons: Array[Button] = []
var _size_label: Label
var _updating := false

var _tokens: Array[TokenDef] = []
var _token_dir := ""
var _project_path := ""


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	_refresh_status()


# ------------------------------------------------------------------- UI ---

func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	root.add_child(_build_toolbar())

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(split)

	split.add_child(_build_palette())

	var right_split := HSplitContainer.new()
	right_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(right_split)

	view = MapView.new()
	view.lib = lib
	view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	view.custom_minimum_size = Vector2(360, 240)
	view.selection_changed.connect(_on_selection_changed)
	view.document_changed.connect(_refresh_status)
	view.status.connect(func(t: String) -> void: _status.text = t)
	right_split.add_child(view)

	right_split.add_child(_build_inspector())

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 12)
	var bar := PanelContainer.new()
	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", 8)
	pad.add_theme_constant_override("margin_top", 3)
	pad.add_theme_constant_override("margin_bottom", 3)
	pad.add_child(_status)
	bar.add_child(pad)
	root.add_child(bar)


func _build_toolbar() -> Control:
	var panel := PanelContainer.new()
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	panel.add_child(row)

	var title := Label.new()
	title.text = "  Falldin  "
	row.add_child(title)

	row.add_child(_button("Load Assets…", _pick_assets))
	row.add_child(_button("Open…", _pick_open))
	row.add_child(_button("Save", _save_project))
	row.add_child(_button("Save As…", _pick_save))
	row.add_child(_separator())
	row.add_child(_button("Import browser map…", _pick_legacy))
	row.add_child(_button("Token folder…", _pick_token_dir))
	row.add_child(_separator())
	row.add_child(_button("Export PNG…", _pick_export))
	row.add_child(_button("Fit", func() -> void: view.frame_all()))
	return panel


func _build_palette() -> Control:
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(250, 0)

	_search = LineEdit.new()
	_search.placeholder_text = "Search assets…"
	_search.text_changed.connect(func(_t: String) -> void: _refresh_palette())
	box.add_child(_search)

	_extras_only = CheckBox.new()
	_extras_only.text = "Extras only"
	_extras_only.toggled.connect(func(_p: bool) -> void: _refresh_palette())
	box.add_child(_extras_only)

	_cats = OptionButton.new()
	_cats.item_selected.connect(func(_i: int) -> void: _refresh_palette())
	box.add_child(_cats)

	_tiles = ItemList.new()
	_tiles.max_columns = 3
	_tiles.icon_mode = ItemList.ICON_MODE_TOP
	_tiles.fixed_icon_size = Vector2i(58, 50)
	_tiles.same_column_width = true
	_tiles.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tiles.item_selected.connect(_on_tile_picked)
	box.add_child(_tiles)
	return box


func _build_inspector() -> Control:
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(272, 0)
	_inspector = VBoxContainer.new()
	_inspector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_inspector)

	_inspector.add_child(_heading("Tool"))
	var tools := GridContainer.new()
	tools.columns = 3
	for spec in [["Paint", MapView.Tool.PAINT], ["Erase", MapView.Tool.ERASE],
			["Move/Size", MapView.Tool.ADJUST], ["Token", MapView.Tool.TOKEN],
			["Crop", MapView.Tool.CROP], ["Pan", MapView.Tool.PAN]]:
		var b := Button.new()
		b.text = str(spec[0])
		b.toggle_mode = true
		b.button_pressed = int(spec[1]) == MapView.Tool.PAINT
		var which := int(spec[1])
		b.pressed.connect(func() -> void: _set_tool(which))
		_tool_buttons.append(b)
		tools.add_child(b)
	_inspector.add_child(tools)

	_inspector.add_child(_heading("Layer"))
	var layers := HBoxContainer.new()
	for spec in [["Terrain", MapDocument.Layer.TERRAIN], ["River/Path", MapDocument.Layer.LINES],
			["Feature", MapDocument.Layer.FEATURES]]:
		var b := Button.new()
		b.text = str(spec[0])
		b.toggle_mode = true
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.button_pressed = int(spec[1]) == MapDocument.Layer.TERRAIN
		var which := int(spec[1])
		b.pressed.connect(func() -> void: _set_layer(which))
		_layer_buttons.append(b)
		layers.add_child(b)
	_inspector.add_child(layers)

	var connect_box := CheckBox.new()
	connect_box.text = "Auto-connect rivers"
	connect_box.button_pressed = true
	connect_box.toggled.connect(func(p: bool) -> void: view.auto_connect = p)
	_inspector.add_child(connect_box)

	var grid_box := CheckBox.new()
	grid_box.text = "Show hex grid"
	grid_box.button_pressed = true
	grid_box.toggled.connect(func(p: bool) -> void:
		view.show_grid = p
		view.queue_redraw())
	_inspector.add_child(grid_box)

	var coord_box := CheckBox.new()
	coord_box.text = "Show coordinates"
	coord_box.toggled.connect(func(p: bool) -> void:
		view.show_coords = p
		view.queue_redraw())
	_inspector.add_child(coord_box)

	_inspector.add_child(_heading("Pieces in this hex"))
	_stack = ItemList.new()
	_stack.custom_minimum_size = Vector2(0, 110)
	_stack.item_selected.connect(_on_stack_picked)
	_inspector.add_child(_stack)

	_inspector.add_child(_heading("Transform"))
	_size_label = Label.new()
	_size_label.text = "nothing selected"
	_inspector.add_child(_size_label)
	_size_slider = _slider("Size", 2, 400, 100, _on_size)
	_rot_slider = _slider("Rotation", -180, 180, 0, _on_rot)
	_alpha_slider = _slider("Opacity", 5, 100, 100, _on_alpha)
	_hue_slider = _slider("Hue", -180, 180, 0, _on_hue)
	_sat_slider = _slider("Saturation", 0, 260, 100, _on_sat)

	var quick := GridContainer.new()
	quick.columns = 4
	for v: float in [0.25, 0.5, 1.0]:
		var b := Button.new()
		b.text = "%g hex" % v
		var val: float = v
		b.pressed.connect(func() -> void: _resize_selected(val))
		quick.add_child(b)
	quick.add_child(_button("native", func() -> void:
		if view.sel_piece != null:
			_resize_selected(lib.native_width(view.sel_piece.tile))))
	_inspector.add_child(quick)

	var row := HBoxContainer.new()
	row.add_child(_button("Flip", func() -> void:
		if view.sel_piece != null:
			view.sel_piece.flip = not view.sel_piece.flip
			view.queue_redraw()))
	row.add_child(_button("Reset", _reset_selected))
	_inspector.add_child(row)

	_inspector.add_child(_heading("Tokens"))
	_token_list = ItemList.new()
	_token_list.custom_minimum_size = Vector2(0, 150)
	_token_list.max_columns = 2
	_token_list.icon_mode = ItemList.ICON_MODE_TOP
	_token_list.fixed_icon_size = Vector2i(72, 52)
	_token_list.item_selected.connect(_on_token_picked)
	_inspector.add_child(_token_list)

	var snap := CheckBox.new()
	snap.text = "Snap to hex centres"
	snap.button_pressed = true
	snap.toggled.connect(func(p: bool) -> void: view.snap_tokens = p)
	_inspector.add_child(snap)
	return scroll


func _heading(text: String) -> Control:
	var l := Label.new()
	l.text = text.to_upper()
	l.add_theme_font_size_override("font_size", 11)
	l.add_theme_color_override("font_color", Color(0.79, 0.66, 0.30))
	return l


func _separator() -> Control:
	var s := VSeparator.new()
	return s


func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	return b


func _slider(label: String, lo: float, hi: float, value: float, cb: Callable) -> HSlider:
	var l := Label.new()
	l.text = label
	l.add_theme_font_size_override("font_size", 11)
	_inspector.add_child(l)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.value = value
	s.value_changed.connect(cb)
	_inspector.add_child(s)
	return s


# -------------------------------------------------------------- palette ---

func _refresh_categories() -> void:
	_cats.clear()
	_cats.add_item("All")
	for c: String in lib.sorted_categories():
		_cats.add_item("%s (%d)" % [c, (lib.categories[c] as Array).size()])


func _current_category() -> String:
	var i := _cats.selected
	if i <= 0:
		return ""
	var cats := lib.sorted_categories()
	return cats[i - 1] if i - 1 < cats.size() else ""


func _refresh_palette() -> void:
	_tiles.clear()
	var cat := _current_category()
	var names: Array = lib.in_category(cat) if not cat.is_empty() else lib.search("", _extras_only.button_pressed)
	var query := _search.text.strip_edges().to_lower()
	var shown := 0
	for base: String in names:
		if _extras_only.button_pressed and (lib.entries[base] as AssetLibrary.Entry).is_hex:
			continue
		if not query.is_empty() and not base.to_lower().contains(query):
			continue
		var idx := _tiles.add_item(base, lib.texture(base, 96.0))
		_tiles.set_item_tooltip(idx, base + " — " + str(int(lib.native_width(base) * 100.0)) + "% of a hex")
		_tiles.set_item_metadata(idx, base)
		shown += 1
		if shown >= PALETTE_LIMIT:
			_tiles.add_item("…%d more, narrow the search" % (names.size() - shown))
			break


func _on_tile_picked(index: int) -> void:
	var base: Variant = _tiles.get_item_metadata(index)
	if base == null:
		return
	view.brush = str(base)
	var entry: AssetLibrary.Entry = lib.entries[str(base)]
	# Picking a river selects the river layer, picking a town the feature layer.
	if entry.category == "Hex · Lines":
		_set_layer(MapDocument.Layer.LINES)
	elif not entry.is_hex:
		_set_layer(MapDocument.Layer.FEATURES)
	else:
		_set_layer(MapDocument.Layer.TERRAIN)
	_status.text = "Brush: " + str(base) + " (" + str(int(lib.native_width(str(base)) * 100.0)) + "% of a hex)"


# ------------------------------------------------------------ selection ---

func _set_tool(which: int) -> void:
	view.tool = which
	for i in _tool_buttons.size():
		_tool_buttons[i].button_pressed = i == which


func _set_layer(which: int) -> void:
	view.layer = which
	for i in _layer_buttons.size():
		_layer_buttons[i].button_pressed = i == which


func _on_selection_changed() -> void:
	_updating = true
	_stack.clear()
	var p := view.sel_piece
	if view.sel_token >= 0 and view.sel_token < doc.tokens.size():
		var inst := doc.tokens[view.sel_token]
		var def := doc.token_def(inst.def_id)
		_size_label.text = "token: %s" % (def.name if def != null else inst.def_id)
		_size_slider.value = clampf(inst.scale * 100.0, 2, 400)
		_rot_slider.value = rad_to_deg(inst.rot)
		_alpha_slider.value = 100
	elif p != null:
		var cell := doc.get_cell(view.sel_cell)
		if cell != null:
			if cell.terrain != null:
				_add_stack_row("Terrain", cell.terrain, MapDocument.Layer.TERRAIN, 0)
			for i in cell.lines.size():
				_add_stack_row("River", cell.lines[i], MapDocument.Layer.LINES, i)
			for i in cell.features.size():
				_add_stack_row("Feature", cell.features[i], MapDocument.Layer.FEATURES, i)
		_size_label.text = "%s — %.2f × %.2f hex" % [p.tile, p.size, p.size * p.aspect]
		_size_slider.value = clampf(p.size * 100.0, 2, 400)
		_rot_slider.value = rad_to_deg(p.rot)
		_alpha_slider.value = p.alpha * 100.0
		_hue_slider.value = p.hue
		_sat_slider.value = p.sat * 100.0
	else:
		_size_label.text = "nothing selected"
	_updating = false


func _add_stack_row(kind: String, p: Piece, which: int, index: int) -> void:
	var i := _stack.add_item("%s · %s (%.2f)" % [kind, p.tile, p.size], lib.texture(p.tile, 32.0))
	_stack.set_item_metadata(i, {"layer": which, "index": index})
	if p == view.sel_piece:
		_stack.select(i)


func _on_stack_picked(index: int) -> void:
	var meta: Variant = _stack.get_item_metadata(index)
	if meta is Dictionary:
		view.select_piece(view.sel_cell, int(meta["layer"]), int(meta["index"]))


func _resize_selected(width: float) -> void:
	if view.sel_piece == null:
		return
	doc.begin_op()
	doc.touch(view.sel_cell)
	view.sel_piece.size = maxf(0.02, width)
	doc.commit_op()
	_on_selection_changed()
	view.queue_redraw()


func _reset_selected() -> void:
	var p := view.sel_piece
	if p == null:
		return
	doc.begin_op()
	doc.touch(view.sel_cell)
	p.offset = Vector2.ZERO
	p.rot = 0.0
	p.flip = false
	p.hue = 0.0
	p.sat = 1.0
	p.alpha = 1.0
	p.size = lib.native_width(p.tile)
	doc.commit_op()
	_on_selection_changed()
	view.invalidate_textures()


func _on_size(v: float) -> void:
	if _updating:
		return
	if view.sel_token >= 0:
		doc.tokens[view.sel_token].scale = v / 100.0
	elif view.sel_piece != null:
		view.sel_piece.size = v / 100.0
		_size_label.text = "%s — %.2f × %.2f hex" % [
			view.sel_piece.tile, view.sel_piece.size, view.sel_piece.size * view.sel_piece.aspect]
	view.queue_redraw()


func _on_rot(v: float) -> void:
	if _updating:
		return
	if view.sel_token >= 0:
		doc.tokens[view.sel_token].rot = deg_to_rad(v)
	elif view.sel_piece != null:
		view.sel_piece.rot = deg_to_rad(v)
	view.queue_redraw()


func _on_alpha(v: float) -> void:
	if _updating or view.sel_piece == null:
		return
	view.sel_piece.alpha = v / 100.0
	view.queue_redraw()


func _on_hue(v: float) -> void:
	if _updating or view.sel_piece == null:
		return
	view.sel_piece.hue = v
	view.invalidate_textures()


func _on_sat(v: float) -> void:
	if _updating or view.sel_piece == null:
		return
	view.sel_piece.sat = v / 100.0
	view.invalidate_textures()


# ------------------------------------------------------------ file stuff ---

func _dialog(mode: int, filters: PackedStringArray, cb: Callable) -> void:
	var d := FileDialog.new()
	d.access = FileDialog.ACCESS_FILESYSTEM
	d.file_mode = mode
	d.filters = filters
	d.use_native_dialog = true
	add_child(d)
	if mode == FileDialog.FILE_MODE_OPEN_DIR:
		d.dir_selected.connect(func(p: String) -> void:
			cb.call(p)
			d.queue_free())
	else:
		d.file_selected.connect(func(p: String) -> void:
			cb.call(p)
			d.queue_free())
	d.canceled.connect(func() -> void: d.queue_free())
	d.popup_centered_ratio(0.7)


func _pick_assets() -> void:
	_dialog(FileDialog.FILE_MODE_OPEN_DIR, PackedStringArray(), load_assets)


func load_assets(path: String) -> void:
	var stats := lib.scan(path)
	lib.save_cache()
	_refresh_categories()
	_refresh_palette()
	view.invalidate_textures()
	_status.text = "%d assets (%d extras) · reference hex %d px" % [
		lib.count(), lib.extras_count(), int(lib.ref_px)]


func _pick_open() -> void:
	_dialog(FileDialog.FILE_MODE_OPEN_FILE, PackedStringArray(["*.falldin ; Falldin map"]), open_project)


func open_project(path: String) -> void:
	var d := ProjectIO.load_file(path)
	if d == null:
		_status.text = "Could not read %s" % path.get_file()
		return
	_adopt(d, path)


func _pick_legacy() -> void:
	_dialog(FileDialog.FILE_MODE_OPEN_FILE,
		PackedStringArray(["*.json ; Browser hexmapper project"]), import_legacy)


func import_legacy(path: String) -> void:
	var d := LegacyIO.load_project(path, lib)
	if d == null:
		_status.text = "Could not read %s" % path.get_file()
		return
	_adopt(d, "")
	_status.text = "Imported %s — %d hexes, %d pieces" % [path.get_file(), d.cells.size(), d.piece_count()]


func _adopt(d: MapDocument, path: String) -> void:
	view.doc = d
	_project_path = path
	view.sel_cell = Vector2i(-1, -1)
	view.sel_piece = null
	view.sel_token = -1
	view.frame_all()
	_refresh_status()


func _pick_save() -> void:
	_dialog(FileDialog.FILE_MODE_SAVE_FILE, PackedStringArray(["*.falldin ; Falldin map"]),
		func(p: String) -> void:
			_project_path = p
			_save_project())


func _save_project() -> void:
	if _project_path.is_empty():
		_pick_save()
		return
	if ProjectIO.save(doc, _project_path) == OK:
		_status.text = "Saved %s" % _project_path.get_file()
	else:
		_status.text = "Could not write %s" % _project_path.get_file()


func _pick_token_dir() -> void:
	_dialog(FileDialog.FILE_MODE_OPEN_DIR, PackedStringArray(), load_token_dir)


## Read every .ftok in a folder — the same folder the browser token maker writes.
func load_token_dir(path: String) -> void:
	_token_dir = path
	_tokens.clear()
	var d := DirAccess.open(path)
	if d != null:
		d.list_dir_begin()
		var name := d.get_next()
		while name != "":
			if not d.current_is_dir() and name.to_lower().ends_with(".ftok"):
				var t := TokenDef.load_file(path.path_join(name))
				if t != null:
					_tokens.append(t)
			name = d.get_next()
		d.list_dir_end()
	_tokens.sort_custom(func(a: TokenDef, b: TokenDef) -> bool: return a.name < b.name)
	_refresh_tokens()
	_status.text = "%d token(s) in %s" % [_tokens.size(), path.get_file()]


func _refresh_tokens() -> void:
	_token_list.clear()
	for t in _tokens:
		var tex: Texture2D = null
		if not t.thumb_png.is_empty():
			var img := Image.new()
			if img.load_png_from_buffer(t.thumb_png) == OK:
				tex = ImageTexture.create_from_image(img)
		if tex == null:
			tex = t.baked_texture()
		var i := _token_list.add_item(t.name, tex)
		_token_list.set_item_tooltip(i, "%s — %.2f hexes wide" % [t.name, t.size_hex.x])


func _on_token_picked(index: int) -> void:
	if index < 0 or index >= _tokens.size():
		return
	view.active_token = _tokens[index]
	_set_tool(MapView.Tool.TOKEN)
	_status.text = "Token: %s — click the map to place it" % _tokens[index].name


func _pick_export() -> void:
	_dialog(FileDialog.FILE_MODE_SAVE_FILE, PackedStringArray(["*.png ; PNG image"]), export_png)


func export_png(path: String) -> void:
	var opts := ImageExporter.Options.new()
	if view.crop.size.x > 0:
		opts.region = Hex.block_bounds(view.crop.position.x, view.crop.position.y,
			view.crop.end.x, view.crop.end.y)
	_status.text = "Rendering…"
	var res := ImageExporter.render(doc, lib, opts)
	if res.image == null:
		_status.text = "Nothing to export"
		return
	if res.image.save_png(path) != OK:
		_status.text = "Could not write %s" % path.get_file()
		return
	var mp := float(res.size().x) * float(res.size().y) / 1_000_000.0
	_status.text = "Exported %d × %d (%.1f MP) at %d px/hex in %.1f s%s" % [
		res.size().x, res.size().y, mp, int(res.px_per_hex),
		res.elapsed_ms / 1000.0, "  ·  scaled to fit the memory budget" if res.scaled_down else ""]


func _refresh_status() -> void:
	if _status == null:
		return
	if lib.count() == 0:
		_status.text = "Load your tile pack to begin — Load Assets…"
		return
	_status.text = "%d hexes · %d pieces · %d tokens" % [
		doc.cells.size(), doc.piece_count(), doc.tokens.size()]
