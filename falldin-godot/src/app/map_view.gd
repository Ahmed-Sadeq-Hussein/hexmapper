## The map canvas: draws the document and handles every pointer tool.
##
## A [Control] rather than a [Camera2D] scene, so screen-to-world is one
## explicit pair of functions instead of an inherited transform. That makes
## picking, snapping and export framing all agree by construction.
class_name MapView
extends Control

signal selection_changed
signal document_changed
signal status(text: String)

enum Tool { PAINT, ERASE, ADJUST, TOKEN, PAN, CROP }

const MIN_ZOOM := 4.0
const MAX_ZOOM := 400.0
const GRID_FADE_ZOOM := 14.0

var doc: MapDocument = MapDocument.new()
var lib: AssetLibrary = null

var tool: int = Tool.PAINT
var layer: int = MapDocument.Layer.TERRAIN
var brush: String = ""
var brush_rot_step: int = 0
var active_token: TokenDef = null

var zoom: float = 64.0            ## pixels per hex width
var origin: Vector2 = Vector2.ZERO  ## world point at the top-left corner
var show_grid: bool = true
var show_coords: bool = false
var auto_connect: bool = true
var snap_tokens: bool = true

## What the inspector is pointed at.
var sel_cell: Vector2i = Vector2i(-1, -1)
var sel_piece: Piece = null
var sel_token: int = -1

var _drag_mode := ""
var _drag_from := Vector2.ZERO
var _drag_origin := Vector2.ZERO
var _stroke: Dictionary = {}
var _tint_cache: Dictionary = {}
var _space_held := false
var crop: Rect2i = Rect2i()       ## selected block of hexes, empty for none


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process_unhandled_key_input(true)


# ------------------------------------------------------------ transforms ---

func world_to_screen(p: Vector2) -> Vector2:
	return (p - origin) * zoom


func screen_to_world(p: Vector2) -> Vector2:
	return p / zoom + origin


func visible_region() -> Rect2:
	var tl := screen_to_world(Vector2.ZERO)
	return Rect2(tl, size / zoom)


func zoom_by(factor: float, anchor: Vector2) -> void:
	var before := screen_to_world(anchor)
	zoom = clampf(zoom * factor, MIN_ZOOM, MAX_ZOOM)
	origin += before - screen_to_world(anchor)
	queue_redraw()


func frame_all() -> void:
	var b := doc.content_bounds()
	if not b.has_area():
		b = doc.grid_bounds()
	if not b.has_area():
		return
	zoom = clampf(minf(size.x / b.size.x, size.y / b.size.y) * 0.94, MIN_ZOOM, MAX_ZOOM)
	origin = b.get_center() - size / (2.0 * zoom)
	queue_redraw()


# ---------------------------------------------------------------- drawing ---

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.04, 0.07, 0.10))
	if lib == null:
		return
	var region := visible_region()
	if show_grid and zoom >= GRID_FADE_ZOOM:
		_draw_grid(region)

	for cmd in DrawList.build(doc, lib, region.grow(2.0), false):
		var tex := _texture_for(cmd)
		if tex == null:
			continue
		var px := cmd.size * zoom
		var at := world_to_screen(cmd.pos)
		draw_set_transform(at, cmd.rot, Vector2(-1.0 if cmd.flip else 1.0, 1.0))
		draw_texture_rect(tex, Rect2(-px * 0.5, px), false, Color(1, 1, 1, cmd.alpha))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	if show_coords and zoom >= 24.0:
		_draw_coords(region)
	_draw_selection()
	_draw_crop()


## Hue and saturation are baked into a cached texture rather than handled by a
## shader, because tinted pieces are rare and this shares its maths — and its
## tests — with the exporter.
func _texture_for(cmd: DrawList.Cmd) -> Texture2D:
	if cmd.token != null:
		return cmd.token.baked_texture()
	if not cmd.tinted():
		return lib.texture(cmd.tile, cmd.size.x * zoom)
	var key := "%s|%.2f|%.3f" % [cmd.tile, cmd.hue, cmd.sat]
	if _tint_cache.has(key):
		return _tint_cache[key]
	var img := lib.image(cmd.tile, cmd.size.x * zoom)
	if img == null:
		return null
	ImageExporter._tint(img, cmd.hue, cmd.sat, 1.0)
	var tex := ImageTexture.create_from_image(img)
	_tint_cache[key] = tex
	return tex


func _draw_grid(region: Rect2) -> void:
	var col := Color(0.79, 0.66, 0.30, clampf((zoom - GRID_FADE_ZOOM) / 30.0, 0.05, 0.30))
	var c0 := maxi(0, int(region.position.x / Hex.COL_STEP) - 1)
	var c1 := mini(doc.cols - 1, int(region.end.x / Hex.COL_STEP) + 1)
	var r0 := maxi(0, int(region.position.y / Hex.ROW_STEP) - 2)
	var r1 := mini(doc.rows - 1, int(region.end.y / Hex.ROW_STEP) + 2)
	var shape := Hex.outline()
	for c in range(c0, c1 + 1):
		for r in range(r0, r1 + 1):
			var at := world_to_screen(Hex.center(c, r))
			var pts := PackedVector2Array()
			for p in shape:
				pts.append(at + p * zoom)
			pts.append(pts[0])
			draw_polyline(pts, col, 1.0)


func _draw_coords(region: Rect2) -> void:
	var font := ThemeDB.fallback_font
	var col := Color(0.90, 0.78, 0.40, 0.85)
	var c0 := maxi(0, int(region.position.x / Hex.COL_STEP) - 1)
	var c1 := mini(doc.cols - 1, int(region.end.x / Hex.COL_STEP) + 1)
	for c in range(c0, c1 + 1):
		draw_string(font, Vector2(world_to_screen(Hex.center(c, 0)).x - 8, 14), str(c),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, col)
	var r0 := maxi(0, int(region.position.y / Hex.ROW_STEP) - 1)
	var r1 := mini(doc.rows - 1, int(region.end.y / Hex.ROW_STEP) + 1)
	for r in range(r0, r1 + 1):
		draw_string(font, Vector2(4, world_to_screen(Hex.center(0, r)).y + 4), str(r),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, col)


func _draw_selection() -> void:
	var accent := Color(0.40, 0.80, 1.0)
	if sel_token >= 0 and sel_token < doc.tokens.size():
		var inst := doc.tokens[sel_token]
		var b := inst.bounds(doc.token_def(inst.def_id))
		var r := Rect2(world_to_screen(b.position), b.size * zoom)
		draw_rect(r, accent, false, 2.0)
		draw_rect(Rect2(world_to_screen(inst.pos) - Vector2(3, 3), Vector2(6, 6)), accent)
		return
	if sel_cell.x < 0:
		return
	var shape := Hex.outline()
	var at := world_to_screen(Hex.center_of(sel_cell))
	var pts := PackedVector2Array()
	for p in shape:
		pts.append(at + p * zoom)
	pts.append(pts[0])
	draw_polyline(pts, accent, 2.0)
	if sel_piece != null:
		var px := sel_piece.draw_size() * zoom
		var c := at + sel_piece.offset * zoom
		draw_rect(Rect2(c - px * 0.5, px), Color(accent.r, accent.g, accent.b, 0.7), false, 1.5)


func _draw_crop() -> void:
	if crop.size.x <= 0:
		return
	var b := Hex.block_bounds(crop.position.x, crop.position.y, crop.end.x, crop.end.y)
	var r := Rect2(world_to_screen(b.position), b.size * zoom)
	draw_rect(r, Color(0.79, 0.66, 0.30, 0.10))
	draw_rect(r, Color(0.79, 0.66, 0.30, 0.9), false, 2.0)
	draw_string(ThemeDB.fallback_font, r.position + Vector2(8, 20),
		"%d × %d hexes" % [crop.size.x, crop.size.y],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.90, 0.78, 0.40))


# ------------------------------------------------------------------ input ---

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_on_button(event)
	elif event is InputEventMouseMotion:
		_on_motion(event)


func _on_button(e: InputEventMouseButton) -> void:
	if e.button_index == MOUSE_BUTTON_WHEEL_UP or e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		if not e.pressed:
			return
		var up := e.button_index == MOUSE_BUTTON_WHEEL_UP
		if e.ctrl_pressed or _wheel_zooms():
			zoom_by(1.12 if up else 1.0 / 1.12, e.position)
		elif tool == Tool.ADJUST and sel_piece != null:
			_begin_edit()
			sel_piece.size = clampf(sel_piece.size * (1.06 if up else 1.0 / 1.06), 0.02, 8.0)
			_end_edit()
		elif tool == Tool.TOKEN and sel_token >= 0:
			_begin_edit()
			doc.tokens[sel_token].scale = clampf(
				doc.tokens[sel_token].scale * (1.06 if up else 1.0 / 1.06), 0.05, 12.0)
			_end_edit()
		else:
			origin.y += (-40.0 if up else 40.0) / zoom
			queue_redraw()
		accept_event()
		return

	if not e.pressed:
		if _drag_mode == "paint" or _drag_mode == "edit" or _drag_mode == "token":
			doc.commit_op()
			document_changed.emit()
		if _drag_mode == "crop":
			_finish_crop(e.position)
		_drag_mode = ""
		return

	grab_focus()
	var world := screen_to_world(e.position)
	var cell := Hex.from_point(world, Vector2i(doc.cols, doc.rows))

	if e.button_index == MOUSE_BUTTON_MIDDLE or _space_held or tool == Tool.PAN:
		_drag_mode = "pan"
		_drag_from = e.position
		_drag_origin = origin
		return

	if e.button_index == MOUSE_BUTTON_RIGHT:
		if tool == Tool.TOKEN:
			var hits := doc.tokens_at(world)
			if not hits.is_empty():
				doc.begin_op()
				doc.remove_token(hits[0])
				doc.commit_op()
				sel_token = -1
				_changed()
			return
		doc.begin_op()
		doc.erase(cell, layer)
		doc.commit_op()
		_changed()
		return

	match tool:
		Tool.PAINT, Tool.ERASE:
			doc.begin_op()
			_drag_mode = "paint"
			_stroke = {cell: true}
			if tool == Tool.ERASE:
				doc.erase(cell, layer)
			else:
				_paint(cell)
			_changed()
		Tool.ADJUST:
			_select_cell(cell)
			if sel_piece != null:
				doc.begin_op()
				doc.touch(cell)
				_drag_mode = "edit"
				_drag_from = world
				_drag_origin = sel_piece.offset
		Tool.TOKEN:
			# Shift forces a new token even when one already covers the hex,
			# which is the only way to stack a second piece of art on a spot
			# that is already occupied.
			_token_press(world, e.shift_pressed)
		Tool.CROP:
			_drag_mode = "crop"
			_drag_from = e.position
			crop = Rect2i(cell, Vector2i.ZERO)
			queue_redraw()


func _on_motion(e: InputEventMouseMotion) -> void:
	match _drag_mode:
		"pan":
			origin = _drag_origin - (e.position - _drag_from) / zoom
			queue_redraw()
		"paint":
			var cell := Hex.from_point(screen_to_world(e.position), Vector2i(doc.cols, doc.rows))
			if _stroke.has(cell):
				return
			_stroke[cell] = true
			if tool == Tool.ERASE:
				doc.erase(cell, layer)
			else:
				_paint(cell)
			queue_redraw()
		"edit":
			if sel_piece != null:
				sel_piece.offset = _drag_origin + (screen_to_world(e.position) - _drag_from)
				queue_redraw()
		"token":
			if sel_token >= 0:
				doc.tokens[sel_token].pos = _drag_origin + (screen_to_world(e.position) - _drag_from)
				queue_redraw()
		"crop":
			var cell := Hex.from_point(screen_to_world(e.position), Vector2i(doc.cols, doc.rows))
			var a := Hex.from_point(screen_to_world(_drag_from), Vector2i(doc.cols, doc.rows))
			crop = Rect2i(a.min(cell), (a.max(cell) - a.min(cell)) + Vector2i.ONE)
			queue_redraw()
		_:
			if tool == Tool.PAINT and Input.is_key_pressed(KEY_ALT):
				pass


func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if k.keycode == KEY_SPACE:
		_space_held = k.pressed
		return
	if not k.pressed:
		return
	if k.ctrl_pressed and k.keycode == KEY_Z:
		if doc.undo():
			_changed()
		accept_event()
		return
	match k.keycode:
		KEY_R:
			_rotate_brush(-1 if k.shift_pressed else 1)
		KEY_0:
			frame_all()
		KEY_DELETE, KEY_BACKSPACE:
			if tool == Tool.TOKEN and sel_token >= 0:
				doc.begin_op()
				doc.remove_token(sel_token)
				doc.commit_op()
				sel_token = -1
				_changed()
		KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN:
			_nudge(k)


func _nudge(k: InputEventKey) -> void:
	var step := 0.05 if k.shift_pressed else 0.01
	var d := Vector2.ZERO
	match k.keycode:
		KEY_LEFT: d = Vector2(-step, 0)
		KEY_RIGHT: d = Vector2(step, 0)
		KEY_UP: d = Vector2(0, -step)
		KEY_DOWN: d = Vector2(0, step)
	if tool == Tool.TOKEN and sel_token >= 0:
		_begin_edit()
		doc.tokens[sel_token].pos += d
		_end_edit()
	elif sel_piece != null:
		_begin_edit()
		doc.touch(sel_cell)
		sel_piece.offset += d
		_end_edit()


func _wheel_zooms() -> bool:
	return tool != Tool.ADJUST and tool != Tool.TOKEN


func _rotate_brush(dir: int) -> void:
	brush_rot_step = posmod(brush_rot_step + dir, 6)
	status.emit("Brush rotation %d°" % (brush_rot_step * 60))


# ------------------------------------------------------------- operations ---

func _paint(cell: Vector2i) -> void:
	if brush.is_empty() or lib == null or not doc.in_bounds(cell):
		return
	var rot := float(brush_rot_step) * (PI / 3.0)
	if layer == MapDocument.Layer.LINES and doc.rotate_existing_line(cell, brush):
		return
	doc.place(cell, layer, Piece.make(brush, lib, rot))
	if layer == MapDocument.Layer.LINES and auto_connect and brush_rot_step == 0:
		_auto_connect(cell)


## Drop the matching half of a river on the neighbour it flows into, so a line
## drawn hex by hex actually joins up.
func _auto_connect(cell: Vector2i) -> void:
	var entry: AssetLibrary.Entry = lib.entries.get(brush)
	if entry == null or entry.dir_suffix.is_empty():
		return
	if not Hex.NAME_TO_DIR.has(entry.dir_suffix):
		return
	var opposite := lib.opposite_piece(brush)
	if opposite.is_empty():
		return
	var nb := Hex.neighbor(cell.x, cell.y, Hex.NAME_TO_DIR[entry.dir_suffix])
	if not doc.in_bounds(nb):
		return
	var target := doc.get_cell(nb)
	if target != null:
		for p in target.lines:
			if p.tile == opposite and is_zero_approx(p.rot):
				return
	doc.place(nb, MapDocument.Layer.LINES, Piece.make(opposite, lib))


func _select_cell(cell: Vector2i) -> void:
	sel_token = -1
	var c := doc.get_cell(cell)
	sel_cell = cell if c != null else Vector2i(-1, -1)
	sel_piece = c.top() if c != null else null
	selection_changed.emit()
	queue_redraw()


## Select a piece by layer and index, so the inspector can walk a hex's stack.
func select_piece(cell: Vector2i, which: int, index: int) -> void:
	var c := doc.get_cell(cell)
	if c == null:
		return
	sel_cell = cell
	sel_token = -1
	if which == MapDocument.Layer.TERRAIN:
		sel_piece = c.terrain
	else:
		var arr := c.layer(which)
		sel_piece = arr[index] if index >= 0 and index < arr.size() else null
	selection_changed.emit()
	queue_redraw()


func _token_press(world: Vector2, force_place: bool = false) -> void:
	var hits := doc.tokens_at(world)
	if not hits.is_empty() and not force_place:
		# Clicking the same spot again walks down the stack, so a token under
		# another in the same hex is still reachable.
		var at := hits.find(sel_token)
		sel_token = hits[(at + 1) % hits.size()] if at >= 0 else hits[0]
		sel_cell = Vector2i(-1, -1)
		sel_piece = null
		doc.begin_op()
		_drag_mode = "token"
		_drag_from = world
		_drag_origin = doc.tokens[sel_token].pos
		selection_changed.emit()
		queue_redraw()
		return
	if active_token == null:
		status.emit("Pick a token in the Tokens panel first  ·  Shift+click stacks another on an occupied hex")
		return
	var at_pos := world
	if snap_tokens and active_token.snap_to_hex:
		at_pos = Hex.center_of(Hex.from_point(world, Vector2i(doc.cols, doc.rows)))
	at_pos = doc.free_spot_near(at_pos)
	doc.register_token(active_token)
	doc.begin_op()
	var inst := TokenInstance.new()
	inst.def_id = active_token.id
	inst.pos = at_pos
	doc.add_token(inst)
	doc.commit_op()
	sel_token = doc.tokens.size() - 1
	_changed()
	selection_changed.emit()


func _finish_crop(_at: Vector2) -> void:
	if crop.size.x <= 0 or crop.size.y <= 0:
		crop = Rect2i()
	queue_redraw()


func _begin_edit() -> void:
	doc.begin_op()


func _end_edit() -> void:
	doc.commit_op()
	_changed()


func _changed() -> void:
	document_changed.emit()
	queue_redraw()


func invalidate_textures() -> void:
	_tint_cache.clear()
	queue_redraw()
