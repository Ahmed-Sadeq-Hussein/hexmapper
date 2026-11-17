## A stamp: a patch of hexes you can drop as a unit.
##
## Stamps store tile names and transforms, never pixels, so placing one produces
## ordinary map cells that render at full resolution like anything else.
class_name StampDef
extends RefCounted

const FORMAT := "falldin-stamp"

class StampCell extends RefCounted:
	## Offset from the stamp's anchor hex, in hex widths, as authored.
	var offset: Vector2 = Vector2.ZERO
	## The same offset as a parity-free cube delta, resolved on load. This is
	## what placement uses, so the patch keeps its shape wherever it is dropped.
	var cube_delta: Vector3i = Vector3i.ZERO
	var terrain: Piece = null
	var lines: Array[Piece] = []
	var features: Array[Piece] = []

var name: String = ""
var cells: Array[StampCell] = []
var thumb_png: PackedByteArray = PackedByteArray()
var source_file: String = ""


## Read a .stamp.json from the browser stamp builder.
##
## Version 2 carries an `ov` block with one transform per piece. Version 1 had a
## single transform for the whole hex, so it is spread across every piece in
## that hex — which is exactly what it used to mean when drawn.
static func from_dict(d: Dictionary, lib: AssetLibrary, tile_fill: float = 2.0) -> StampDef:
	if str(d.get("format", "")) != FORMAT:
		return null
	var s := StampDef.new()
	s.name = str(d.get("name", "stamp"))
	var fill := float(d.get("tileFill", tile_fill))
	# Native sizing arrived with version 2. A version 1 stamp was authored when
	# every asset was stretched to hex size, so that is how it must still look.
	var native := bool(d.get("nativeSize", int(d.get("version", 1)) >= 2))
	if d.has("extraK") and lib != null:
		lib.extras_scale = float(d["extraK"])
	for raw: Variant in d.get("cells", []):
		var cd: Dictionary = raw
		var cell := StampCell.new()
		# dyu was measured in hex HEIGHTS by the browser tool, dxu in widths.
		cell.offset = Vector2(float(cd.get("dxu", 0.0)), float(cd.get("dyu", 0.0)) * Hex.ASPECT)
		var ov: Dictionary = cd.get("ov", {})
		var fallback := LegacyIO.legacy_transform(cd)
		var base_name := str(cd.get("base", ""))
		if not base_name.is_empty():
			cell.terrain = LegacyIO.piece_from(
				base_name, lib, fill, native, ov.get("base"), fallback, 0.0)
		cell.lines = _read_layer(cd.get("lines", []), ov.get("lines", []), lib, fill, native, fallback)
		cell.features = _read_layer(cd.get("features", []), ov.get("features", []), lib, fill, native, fallback)
		s.cells.append(cell)
	s.thumb_png = TokenDef._decode_data_url(str(d.get("thumb", "")))
	s._resolve_layout()
	return s


## Work out which column parity the stamp was authored against, then store each
## hex as a cube delta from the anchor.
##
## The offsets in the file are raw distances from whichever hex happened to be
## top-left when the stamp was saved. Whether that hex sat on an odd or an even
## column changes where its diagonal neighbours fall, and the file does not say
## which it was — so try both and keep the one whose hexes land squarely on
## their centres.
func _resolve_layout() -> void:
	var best_parity := 0
	var best_error := INF
	for parity in 2:
		var anchor := Vector2i(parity, 1)
		var origin := Hex.center_of(anchor)
		var error := 0.0
		for cell in cells:
			var target := Hex.from_point(origin + cell.offset)
			error += Hex.center_of(target).distance_squared_to(origin + cell.offset)
		if error < best_error:
			best_error = error
			best_parity = parity
	var anchor := Vector2i(best_parity, 1)
	var origin := Hex.center_of(anchor)
	var anchor_cube := Hex.to_cube(anchor)
	for cell in cells:
		var target := Hex.from_point(origin + cell.offset)
		cell.cube_delta = Hex.to_cube(target) - anchor_cube


static func _read_layer(
	raw_list: Array, ov_list: Variant, lib: AssetLibrary,
	fill: float, native: bool, fallback: Dictionary
) -> Array[Piece]:
	var out: Array[Piece] = []
	var ovs: Array = ov_list if ov_list is Array else []
	for i in raw_list.size():
		var entry: Variant = raw_list[i]
		var tile := ""
		var step := 0.0
		if entry is Array:
			tile = str(entry[0])
			step = float(entry[1]) * (PI / 3.0) if (entry as Array).size() > 1 else 0.0
		elif entry is Dictionary:
			tile = str((entry as Dictionary).get("n", ""))
			step = float((entry as Dictionary).get("rot", 0.0))
		else:
			tile = str(entry)
		if tile.is_empty():
			continue
		var ov: Variant = ovs[i] if i < ovs.size() else null
		var p := LegacyIO.piece_from(tile, lib, fill, native, ov, fallback, step)
		if p != null:
			out.append(p)
	return out


static func load_file(path: String, lib: AssetLibrary) -> Array[StampDef]:
	var out: Array[StampDef] = []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		return out
	var d: Dictionary = parsed
	if str(d.get("format", "")) == "falldin-stamp-pack":
		for raw: Variant in d.get("stamps", []):
			var s := from_dict(raw, lib)
			if s != null:
				s.source_file = path
				out.append(s)
	else:
		var s := from_dict(d, lib)
		if s != null:
			s.source_file = path
			out.append(s)
	return out


## Stamp this patch onto [param doc] with its anchor at [param at].
func apply_to(doc: MapDocument, at: Vector2i) -> int:
	var anchor_cube := Hex.to_cube(at)
	var missing := 0
	for cell in cells:
		var target := Hex.from_cube(anchor_cube + cell.cube_delta)
		if not doc.in_bounds(target):
			continue
		doc.touch(target)
		var c := doc.ensure_cell(target)
		if cell.terrain != null:
			c.terrain = cell.terrain.duplicate_piece()
		for p in cell.lines:
			c.lines.append(p.duplicate_piece())
		for p in cell.features:
			c.features.append(p.duplicate_piece())
	return missing
