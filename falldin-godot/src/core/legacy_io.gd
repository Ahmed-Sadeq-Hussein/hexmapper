## Readers for everything the browser tools wrote.
##
## Four generations of project file, two of stamp, one of token. They all load,
## because the maps already built with them are the reason this port exists.
class_name LegacyIO
extends RefCounted

## The browser's "Tile fill" slider, which never made it into a save file. It
## defaulted to 200 %, so that is what an import assumes unless told otherwise.
const DEFAULT_TILE_FILL := 2.0


## Build a piece from the browser's split representation.
##
## [param ov] is the per-piece transform (version 4 projects and version 2
## stamps). [param fallback] is the whole-hex transform older files used.
## A per-piece rotation wins over the 60 ° step, because that is what the
## browser did when it merged the two.
static func piece_from(
	tile: String, lib: AssetLibrary, fill: float, native: bool,
	ov: Variant, fallback: Dictionary, step_rot: float
) -> Piece:
	if tile.is_empty():
		return null
	var tr: Dictionary = fallback.duplicate()
	var has_own_rot := false
	if ov is Dictionary:
		var od: Dictionary = ov
		tr["sc"] = float(od.get("sc", tr.get("sc", 1.0)))
		tr["dx"] = float(od.get("dx", 0.0))
		tr["dy"] = float(od.get("dy", 0.0))
		tr["hue"] = float(od.get("hue", tr.get("hue", 0.0)))
		tr["sat"] = float(od.get("sat", tr.get("sat", 1.0)))
		tr["flip"] = bool(od.get("flip", false))
		tr["alpha"] = float(od.get("alpha", 1.0))
		tr["rot"] = deg_to_rad(float(od.get("rot", 0.0)))
		has_own_rot = true
	elif ov is Array:
		var oa: Array = ov
		tr["sc"] = float(oa[0])
		tr["dx"] = float(oa[1])
		tr["dy"] = float(oa[2])
		tr["rot"] = deg_to_rad(float(oa[3]))
		tr["hue"] = float(oa[4])
		tr["sat"] = float(oa[5])
		tr["flip"] = float(oa[6]) != 0.0
		tr["alpha"] = float(oa[7]) if oa.size() > 7 else 1.0
		has_own_rot = true

	var p := Piece.new()
	p.tile = tile
	# The browser drew at hexWidth * tileFill * nativeWidth * scale. Collapsing
	# that into one absolute width is the whole point: from here on the size is
	# a fact about the piece, not the product of three sliders.
	var native_w := 1.0
	var native_aspect := Hex.ASPECT
	if native and lib != null and lib.has(tile):
		var n := lib.native_size(tile)
		native_w = n.x
		native_aspect = n.y / maxf(0.0001, n.x)
	p.size = fill * native_w * float(tr.get("sc", 1.0))
	p.aspect = native_aspect
	p.offset = Vector2(float(tr.get("dx", 0.0)), float(tr.get("dy", 0.0)))
	p.rot = float(tr.get("rot", 0.0)) if has_own_rot else step_rot
	p.flip = bool(tr.get("flip", false))
	p.hue = float(tr.get("hue", 0.0))
	p.sat = float(tr.get("sat", 1.0))
	p.alpha = float(tr.get("alpha", 1.0))
	return p


## The whole-hex transform older files carried, as a piece transform.
static func legacy_transform(cell: Dictionary, hex_px: float = 72.0) -> Dictionary:
	return {
		"sc": float(cell.get("sc", 1.0)),
		# ox/oy were pixels at the authoring hex size; hex widths here.
		"dx": float(cell.get("ox", 0.0)) / hex_px,
		"dy": float(cell.get("oy", 0.0)) / hex_px,
		"rot": 0.0,
		"hue": float(cell.get("hue", 0.0)),
		"sat": float(cell.get("sat", 1.0)),
		"flip": false,
		"alpha": 1.0,
	}


## Load a browser project (falldin-hexmap.json, versions 1 to 4).
static func load_project(path: String, lib: AssetLibrary, tile_fill := DEFAULT_TILE_FILL) -> MapDocument:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		return null
	return from_project_dict(parsed, lib, tile_fill)


static func from_project_dict(d: Dictionary, lib: AssetLibrary, tile_fill := DEFAULT_TILE_FILL) -> MapDocument:
	var doc := MapDocument.new()
	var grid: Dictionary = d.get("grid", {})
	doc.cols = int(grid.get("cols", 24))
	doc.rows = int(grid.get("rows", 18))
	var hex_px := float(grid.get("hex", 64.0))
	var version := int(d.get("version", 1))
	var native := bool(d.get("nativeSize", version >= 4))
	if lib != null and d.has("extraK"):
		lib.extras_scale = float(d["extraK"])

	if version >= 4:
		_load_v4(d, doc, lib, tile_fill, native)
	elif version == 3:
		_load_v3(d, doc, lib, tile_fill, native, hex_px)
	else:
		_load_v1(d, doc, lib, tile_fill, native)

	for raw: Variant in d.get("tokens", []):
		var a: Array = raw
		var inst := TokenInstance.new()
		inst.def_id = str(a[0])
		inst.pos = Vector2(float(a[1]), float(a[2]))
		inst.scale = float(a[3]) if a.size() > 3 else 1.0
		inst.rot = deg_to_rad(float(a[4])) if a.size() > 4 else 0.0
		inst.flip = a.size() > 5 and float(a[5]) != 0.0
		doc.tokens.append(inst)
	var defs: Dictionary = d.get("tokenDefs", {})
	for id: String in defs:
		var t := TokenDef.from_dict(defs[id])
		if t != null:
			doc.register_token(t)
	return doc


static func _split_key(key: String) -> Vector2i:
	var parts := key.split(",")
	if parts.size() != 2:
		return Vector2i.ZERO
	return Vector2i(int(parts[0]), int(parts[1]))


static func _load_v4(d: Dictionary, doc: MapDocument, lib: AssetLibrary, fill: float, native: bool) -> void:
	var dict: Array = d.get("dict", [])
	var empty := {}
	for raw: Variant in d.get("cells", []):
		var row: Array = raw
		var at := _split_key(str(row[0]))
		var cell := doc.ensure_cell(at)
		var base_idx := int(row[1])
		if base_idx >= 0 and base_idx < dict.size():
			cell.terrain = piece_from(str(dict[base_idx]), lib, fill, native,
				row[4] if row.size() > 4 and row[4] is Array else null, empty, 0.0)
		cell.lines = _v4_layer(row[2], dict, lib, fill, native)
		cell.features = _v4_layer(row[3], dict, lib, fill, native)
		if cell.is_empty():
			doc.cells.erase(at)


static func _v4_layer(raw: Variant, dict: Array, lib: AssetLibrary, fill: float, native: bool) -> Array[Piece]:
	var out: Array[Piece] = []
	if not (raw is Array):
		return out
	for item: Variant in raw:
		var a: Array = item
		var idx := int(a[0])
		if idx < 0 or idx >= dict.size():
			continue
		var step := float(a[1]) * (PI / 3.0) if a.size() > 1 else 0.0
		var ov: Variant = a[2] if a.size() > 2 and a[2] is Array else null
		var p := piece_from(str(dict[idx]), lib, fill, native, ov, {}, step)
		if p != null:
			out.append(p)
	return out


static func _load_v3(d: Dictionary, doc: MapDocument, lib: AssetLibrary, fill: float, native: bool, hex_px: float) -> void:
	var dict: Array = d.get("dict", [])
	for raw: Variant in d.get("cells", []):
		var row: Array = raw
		var at := _split_key(str(row[0]))
		var legacy := legacy_transform({
			"sc": row[6] if row.size() > 6 else 1.0,
			"ox": row[4] if row.size() > 4 else 0.0,
			"oy": row[5] if row.size() > 5 else 0.0,
			"hue": row[7] if row.size() > 7 else 0.0,
			"sat": row[8] if row.size() > 8 else 1.0,
		}, hex_px)
		var cell := doc.ensure_cell(at)
		var base_idx := int(row[1])
		if base_idx >= 0 and base_idx < dict.size():
			cell.terrain = piece_from(str(dict[base_idx]), lib, fill, native, null, legacy, 0.0)
		cell.lines = _v3_layer(row[2], dict, lib, fill, native, legacy)
		cell.features = _v3_layer(row[3], dict, lib, fill, native, legacy)
		if cell.is_empty():
			doc.cells.erase(at)


static func _v3_layer(raw: Variant, dict: Array, lib: AssetLibrary, fill: float, native: bool, legacy: Dictionary) -> Array[Piece]:
	var out: Array[Piece] = []
	if not (raw is Array):
		return out
	for item: Variant in raw:
		var a: Array = item
		var idx := int(a[0])
		if idx < 0 or idx >= dict.size():
			continue
		var step := float(a[1]) * (PI / 3.0) if a.size() > 1 else 0.0
		var p := piece_from(str(dict[idx]), lib, fill, native, null, legacy, step)
		if p != null:
			out.append(p)
	return out


static func _load_v1(d: Dictionary, doc: MapDocument, lib: AssetLibrary, fill: float, native: bool) -> void:
	var cells: Dictionary = d.get("cells", {})
	for key: String in cells:
		var cd: Dictionary = cells[key]
		var at := _split_key(key)
		var legacy := legacy_transform(cd)
		var cell := doc.ensure_cell(at)
		var base_name := str(cd.get("base", ""))
		if not base_name.is_empty():
			cell.terrain = piece_from(base_name, lib, fill, native, null, legacy, 0.0)
		cell.lines = _v1_layer(cd.get("lines", []), lib, fill, native, legacy)
		cell.features = _v1_layer(cd.get("features", []), lib, fill, native, legacy)
		if cell.is_empty():
			doc.cells.erase(at)


static func _v1_layer(raw: Variant, lib: AssetLibrary, fill: float, native: bool, legacy: Dictionary) -> Array[Piece]:
	var out: Array[Piece] = []
	if not (raw is Array):
		return out
	for item: Variant in raw:
		var tile := ""
		var rot := 0.0
		if item is String:
			tile = item
		elif item is Dictionary:
			tile = str((item as Dictionary).get("n", ""))
			rot = float((item as Dictionary).get("rot", 0.0))
		elif item is Array:
			tile = str((item as Array)[0])
			rot = float((item as Array)[1]) * (PI / 3.0) if (item as Array).size() > 1 else 0.0
		if tile.is_empty():
			continue
		var p := piece_from(tile, lib, fill, native, null, legacy, rot)
		if p != null:
			out.append(p)
	return out
