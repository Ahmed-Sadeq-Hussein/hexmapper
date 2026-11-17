## Falldin's own map format (.falldin, JSON inside).
##
## Sizes are absolute hex widths, so a file does not depend on which sliders
## were set when it was written. Tile names go through a dictionary because a
## large map repeats a few hundred names tens of thousands of times.
class_name ProjectIO
extends RefCounted

const FORMAT := "falldin-map"
const VERSION := 5


static func save(doc: MapDocument, path: String) -> Error:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ERR_CANT_OPEN
	f.store_string(JSON.stringify(to_dict(doc)))
	return OK


static func to_dict(doc: MapDocument) -> Dictionary:
	var names: Array = []
	var index := {}
	var id_of := func(tile: String) -> int:
		if index.has(tile):
			return index[tile]
		var i := names.size()
		names.append(tile)
		index[tile] = i
		return i

	var out_cells: Array = []
	var keys: Array = doc.cells.keys()
	keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.y < b.y if a.y != b.y else a.x < b.x)
	for at: Vector2i in keys:
		var c: MapDocument.Cell = doc.cells[at]
		out_cells.append([
			at.x, at.y,
			_encode_piece(c.terrain, id_of),
			_encode_layer(c.lines, id_of),
			_encode_layer(c.features, id_of),
		])

	var out_tokens: Array = []
	for t in doc.tokens:
		out_tokens.append(t.to_dict())
	var defs := {}
	var used := {}
	for t in doc.tokens:
		used[t.def_id] = true
	for id: String in used:
		var def := doc.token_def(id)
		if def != null:
			defs[id] = def.to_dict()

	return {
		"format": FORMAT, "version": VERSION,
		"cols": doc.cols, "rows": doc.rows, "hexMiles": doc.hex_miles,
		"tiles": names, "cells": out_cells,
		"tokens": out_tokens, "tokenDefs": defs,
	}


static func _encode_piece(p: Piece, id_of: Callable) -> Variant:
	if p == null:
		return null
	var d := p.to_dict()
	d["t"] = id_of.call(p.tile)
	return d


static func _encode_layer(list: Array[Piece], id_of: Callable) -> Array:
	var out: Array = []
	for p in list:
		out.append(_encode_piece(p, id_of))
	return out


static func load_file(path: String) -> MapDocument:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		return null
	return from_dict(parsed)


static func from_dict(d: Dictionary) -> MapDocument:
	if str(d.get("format", "")) != FORMAT:
		return null
	var doc := MapDocument.new()
	doc.cols = int(d.get("cols", 24))
	doc.rows = int(d.get("rows", 18))
	doc.hex_miles = float(d.get("hexMiles", 12.0))
	var names: Array = d.get("tiles", [])
	for raw: Variant in d.get("cells", []):
		var row: Array = raw
		var at := Vector2i(int(row[0]), int(row[1]))
		var cell := doc.ensure_cell(at)
		cell.terrain = _decode_piece(row[2], names)
		cell.lines = _decode_layer(row[3], names)
		cell.features = _decode_layer(row[4], names)
		if cell.is_empty():
			doc.cells.erase(at)
	for raw: Variant in d.get("tokens", []):
		doc.tokens.append(TokenInstance.from_dict(raw))
	var defs: Dictionary = d.get("tokenDefs", {})
	for id: String in defs:
		var t := TokenDef.from_dict(defs[id])
		if t != null:
			doc.register_token(t)
	return doc


static func _decode_piece(raw: Variant, names: Array) -> Piece:
	if not (raw is Dictionary):
		return null
	var d: Dictionary = (raw as Dictionary).duplicate()
	var idx := int(d.get("t", -1))
	if idx < 0 or idx >= names.size():
		return null
	d["t"] = str(names[idx])
	return Piece.from_dict(d)


static func _decode_layer(raw: Variant, names: Array) -> Array[Piece]:
	var out: Array[Piece] = []
	if not (raw is Array):
		return out
	for item: Variant in raw:
		var p := _decode_piece(item, names)
		if p != null:
			out.append(p)
	return out
