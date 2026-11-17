## The map: hexes of stacked pieces, plus free-standing tokens above them.
class_name MapDocument
extends RefCounted

signal changed

enum Layer { TERRAIN, LINES, FEATURES }

## One hex. Terrain replaces; the other two stack.
class Cell extends RefCounted:
	var terrain: Piece = null
	var lines: Array[Piece] = []
	var features: Array[Piece] = []

	func clone() -> Cell:
		var c := Cell.new()
		c.terrain = terrain.duplicate_piece() if terrain != null else null
		for p in lines:
			c.lines.append(p.duplicate_piece())
		for p in features:
			c.features.append(p.duplicate_piece())
		return c

	func is_empty() -> bool:
		return terrain == null and lines.is_empty() and features.is_empty()

	func layer(which: int) -> Array[Piece]:
		return lines if which == Layer.LINES else features

	## Topmost piece, which is what a click on this hex means.
	func top() -> Piece:
		if not features.is_empty():
			return features[-1]
		if not lines.is_empty():
			return lines[-1]
		return terrain

	func count() -> int:
		return (1 if terrain != null else 0) + lines.size() + features.size()


var cols: int = 24
var rows: int = 18
var cells: Dictionary = {}          ## Vector2i -> Cell
var tokens: Array[TokenInstance] = []
var token_defs: Dictionary = {}     ## id:String -> TokenDef
var hex_miles: float = 12.0         ## one hex in miles, for VTT exports

var _undo: Array = []
var _op: Dictionary = {}
var _op_tokens: Array = []
var _in_op: bool = false
const UNDO_LIMIT := 120


# ------------------------------------------------------------------ cells ---

func get_cell(at: Vector2i) -> Cell:
	return cells.get(at)


func ensure_cell(at: Vector2i) -> Cell:
	var c: Cell = cells.get(at)
	if c == null:
		c = Cell.new()
		cells[at] = c
	return c


func in_bounds(at: Vector2i) -> bool:
	return at.x >= 0 and at.y >= 0 and at.x < cols and at.y < rows


## Put [param piece] on [param at]. Terrain replaces and keeps the outgoing
## piece's transform, so re-painting the ground under a nudged tile does not
## snap it back.
func place(at: Vector2i, which: int, piece: Piece) -> void:
	touch(at)
	var c := ensure_cell(at)
	match which:
		Layer.TERRAIN:
			if c.terrain != null:
				piece.offset = c.terrain.offset
				piece.hue = c.terrain.hue
				piece.sat = c.terrain.sat
			c.terrain = piece
		Layer.LINES:
			c.lines.append(piece)
		_:
			c.features.append(piece)


## Drop the top piece of a layer; forget the cell once nothing is left.
func erase(at: Vector2i, which: int) -> bool:
	var c: Cell = cells.get(at)
	if c == null:
		return false
	touch(at)
	match which:
		Layer.TERRAIN:
			c.terrain = null
		Layer.LINES:
			if not c.lines.is_empty():
				c.lines.remove_at(c.lines.size() - 1)
		_:
			if not c.features.is_empty():
				c.features.remove_at(c.features.size() - 1)
	if c.is_empty():
		cells.erase(at)
	return true


## A river already in this hex is rotated a sixth of a turn rather than stacked,
## which is how you steer a bend without hunting for the right piece.
func rotate_existing_line(at: Vector2i, tile: String) -> bool:
	var c: Cell = cells.get(at)
	if c == null:
		return false
	for p in c.lines:
		if p.tile == tile:
			touch(at)
			var step := int(round(p.rot / (PI / 3.0)))
			p.rot = float((step + 1) % 6) * (PI / 3.0)
			return true
	return false


func piece_count() -> int:
	var n := 0
	for k: Vector2i in cells:
		n += (cells[k] as Cell).count()
	return n


func clear_cells() -> void:
	push_full_snapshot()
	cells.clear()
	changed.emit()


# ----------------------------------------------------------------- tokens ---

func add_token(inst: TokenInstance) -> void:
	_snapshot_tokens()
	tokens.append(inst)


func remove_token(idx: int) -> void:
	if idx < 0 or idx >= tokens.size():
		return
	_snapshot_tokens()
	tokens.remove_at(idx)


func register_token(def: TokenDef) -> void:
	if def != null and not def.id.is_empty():
		token_defs[def.id] = def


func token_def(id: String) -> TokenDef:
	return token_defs.get(id)


## Tokens whose bounds contain [param p], topmost first.
func tokens_at(p: Vector2) -> Array[int]:
	var out: Array[int] = []
	for i in range(tokens.size() - 1, -1, -1):
		var inst := tokens[i]
		if inst.bounds(token_def(inst.def_id)).has_point(p):
			out.append(i)
	return out


## Several tokens can share a hex. Nudge a new one clear of any that already sit
## on this spot so none of them is hidden underneath another.
func free_spot_near(p: Vector2) -> Vector2:
	var out := p
	var guard := 0
	while guard < 24 and _occupied(out):
		var a := float(guard) * PI / 3.0
		var r := 0.09 * float(1 + guard / 6)
		out += Vector2(cos(a), sin(a)) * r
		guard += 1
	return out


func _occupied(p: Vector2) -> bool:
	for inst in tokens:
		if inst.pos.distance_squared_to(p) < 0.0004:
			return true
	return false


# ------------------------------------------------------------------- undo ---

func begin_op() -> void:
	_op = {}
	_op_tokens = []
	_in_op = true


## Record a cell's state before it is changed. Cheap: only touched cells are kept.
func touch(at: Vector2i) -> void:
	if not _in_op or _op.has(at):
		return
	var c: Cell = cells.get(at)
	_op[at] = c.clone() if c != null else null


func _snapshot_tokens() -> void:
	if not _in_op or not _op_tokens.is_empty():
		return
	for t in tokens:
		_op_tokens.append(t.duplicate_instance())
	if _op_tokens.is_empty():
		_op_tokens = [null]  # marker: the list was empty, not "unrecorded"


func commit_op() -> void:
	_in_op = false
	if _op.is_empty() and _op_tokens.is_empty():
		return
	_undo.append({"cells": _op, "tokens": _op_tokens})
	if _undo.size() > UNDO_LIMIT:
		_undo.pop_front()
	_op = {}
	_op_tokens = []
	changed.emit()


## For operations that rewrite everything at once, such as a crop.
func push_full_snapshot() -> void:
	var snap := {}
	for k: Vector2i in cells:
		snap[k] = (cells[k] as Cell).clone()
	var toks: Array = []
	for t in tokens:
		toks.append(t.duplicate_instance())
	_undo.append({"full": snap, "tokens": toks if not toks.is_empty() else [null]})
	if _undo.size() > UNDO_LIMIT:
		_undo.pop_front()


func can_undo() -> bool:
	return not _undo.is_empty()


func undo() -> bool:
	if _undo.is_empty():
		return false
	var step: Dictionary = _undo.pop_back()
	if step.has("full"):
		cells = step["full"]
	else:
		for at: Vector2i in step["cells"]:
			var prev: Cell = step["cells"][at]
			if prev == null:
				cells.erase(at)
			else:
				cells[at] = prev
	var toks: Array = step.get("tokens", [])
	if not toks.is_empty():
		tokens.clear()
		for t: Variant in toks:
			if t != null:
				tokens.append(t)
	changed.emit()
	return true


# ----------------------------------------------------------------- extent ---

## Everything the map occupies, in hex widths, tokens included. This is what an
## export frames.
func content_bounds() -> Rect2:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for at: Vector2i in cells:
		var c: Cell = cells[at]
		var ctr := Hex.center_of(at)
		var pieces: Array[Piece] = []
		if c.terrain != null:
			pieces.append(c.terrain)
		pieces.append_array(c.lines)
		pieces.append_array(c.features)
		for p in pieces:
			var half := p.draw_size() * 0.5
			var ext := _rotated_half_extent(half, p.rot)
			var at_pos := ctr + p.offset
			lo = lo.min(at_pos - ext)
			hi = hi.max(at_pos + ext)
	for inst in tokens:
		var b := inst.bounds(token_def(inst.def_id))
		lo = lo.min(b.position)
		hi = hi.max(b.end)
	if lo.x > hi.x:
		return Rect2()
	return Rect2(lo, hi - lo)


## The grid's own rectangle, ignoring overhang. Used when an export should line
## up with the hex grid rather than with the art.
func grid_bounds(c0: int = -1, r0: int = -1, c1: int = -1, r1: int = -1) -> Rect2:
	if c0 < 0:
		return Hex.block_bounds(0, 0, cols - 1, rows - 1)
	return Hex.block_bounds(c0, r0, c1, r1)


static func _rotated_half_extent(half: Vector2, rot: float) -> Vector2:
	if is_zero_approx(rot):
		return half
	var c := absf(cos(rot))
	var s := absf(sin(rot))
	return Vector2(half.x * c + half.y * s, half.x * s + half.y * c)
