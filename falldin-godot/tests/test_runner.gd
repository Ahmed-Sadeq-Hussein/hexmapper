## Headless test suite.
##
##   godot --headless --path . --script res://tests/test_runner.gd
##
## Exits non-zero when anything fails.
extends SceneTree

const ASPECT := 194.0 / 224.0

var t := TestHarness.new()
var lib: AssetLibrary
var fixtures: String


func _initialize() -> void:
	fixtures = ProjectSettings.globalize_path("res://tests/fixtures")
	print("Falldin core tests — fixtures at %s" % fixtures)

	test_hex()
	test_library()
	test_document()
	test_draw_order()
	test_token_format()
	test_token_transform()
	test_legacy_v4()
	test_legacy_v3()
	test_legacy_v1()
	test_stamp()
	test_project_roundtrip()
	test_export()

	var failures := t.report()
	quit(1 if failures > 0 else 0)


# ------------------------------------------------------------------ hex ---

func test_hex() -> void:
	t.suite("Hex maths")
	# Values taken from the browser tool with hexW = 1, so the port and the
	# original agree on where a hex actually is.
	t.close_vec(Hex.center(0, 0), Vector2(0.5, ASPECT * 0.5), "centre of (0,0)")
	t.close_vec(Hex.center(1, 0), Vector2(1.25, ASPECT), "odd column drops half a row")
	t.close_vec(Hex.center(2, 0), Vector2(2.0, ASPECT * 0.5), "even column back on the row")
	t.close_vec(Hex.center(0, 3), Vector2(0.5, ASPECT * 3.5), "row step is the hex height")
	t.close_vec(Hex.center(3, 2), Vector2(2.75, ASPECT * 3.0), "odd column, third row")

	t.eq(Hex.neighbor(2, 2, Hex.Dir.N), Vector2i(2, 1), "N from an even column")
	t.eq(Hex.neighbor(2, 2, Hex.Dir.NE), Vector2i(3, 1), "NE from an even column")
	t.eq(Hex.neighbor(3, 2, Hex.Dir.NE), Vector2i(4, 2), "NE from an odd column")
	t.eq(Hex.neighbor(3, 2, Hex.Dir.SW), Vector2i(2, 3), "SW from an odd column")
	t.eq(Hex.OPPOSITE[Hex.Dir.NE], Hex.Dir.SW, "NE opposes SW")

	# Every centre must map back to its own cell, including the odd columns
	# where naive rounding lands next door.
	var wrong := 0
	for c in 12:
		for r in 9:
			if Hex.from_point(Hex.center(c, r)) != Vector2i(c, r):
				wrong += 1
	t.eq(wrong, 0, "every hex centre round-trips through from_point")

	# A point just inside the slanted edge belongs to this hex, not the next.
	var ctr := Hex.center(4, 3)
	t.eq(Hex.from_point(ctr + Vector2(0.24, 0.0)), Vector2i(4, 3), "point near the flat edge stays put")
	t.ok(Hex.contains_point(ctr, ctr + Vector2(0.0, ASPECT * 0.45)), "point inside the hex")
	t.ok(not Hex.contains_point(ctr, ctr + Vector2(0.49, ASPECT * 0.49)), "corner of the bbox is outside the hex")


# -------------------------------------------------------------- library ---

func test_library() -> void:
	t.suite("Asset library")
	lib = AssetLibrary.new()
	var stats := lib.scan(fixtures)
	t.eq(int(stats.added), 15, "indexed every fixture tile")
	t.eq(lib.count(), 15, "library size")
	t.eq(lib.extras_count(), 5, "extras counted separately from hex tiles")

	t.close(lib.ref_px, 224.0, "reference width read from a plain hex tile")
	t.ok(lib.entries["Hex - Base Plains 1"].is_hex, "hex tile flagged as a hex")
	t.ok(not lib.entries["Extras - Town 1"].is_hex, "extra not flagged as a hex")

	# The heart of it: a 96 px town beside a 224 px hex tile is 43 % of a hex.
	t.close(lib.native_width("Extras - Town 1"), 96.0 / 224.0, "town sizes itself against a hex")
	t.close(lib.native_width("Extras - Town 2"), 120.0 / 224.0, "second town")
	t.close(lib.native_width("Extras - Tower 1"), 48.0 / 224.0, "narrow tower stays narrow")
	t.close(lib.native_width("Hex - Base Plains 1"), 1.0, "a plain hex tile is exactly one hex")
	# An oversized mountain tile should overhang its hex on its own.
	t.close(lib.native_width("Hex - Mountains 1"), 302.0 / 224.0, "oversized mountain overhangs")

	# Aspect comes from the art, so nothing is squashed into hex proportions.
	var tower := lib.native_size("Extras - Tower 1")
	t.close(tower.y / tower.x, 96.0 / 48.0, "tall tower keeps its own aspect")

	t.eq(lib.entries["Hex - River 1 N"].dir_suffix, "N", "direction suffix parsed")
	t.eq(lib.opposite_piece("Hex - River 1 N"), "Hex - River 1 S", "river finds its opposite half")
	t.eq(lib.opposite_piece("Extras - Town 1"), "", "a town has no opposite")
	t.eq(lib.entries["Extras - Town 1"].category, "Towns", "town categorised")
	t.eq(lib.entries["Hex - River 1 N"].category, "Hex · Lines", "river categorised")

	lib.extras_scale = 0.5
	t.close(lib.native_width("Extras - Town 1"), 96.0 / 224.0 * 0.5, "extras scale applies to extras")
	t.close(lib.native_width("Hex - Base Plains 1"), 1.0, "extras scale leaves hex tiles alone")
	lib.extras_scale = 1.0

	t.eq(lib.search("town").size(), 2, "search by name")
	t.eq(lib.search("", true).size(), 5, "extras-only filter")


# ------------------------------------------------------------- document ---

func test_document() -> void:
	t.suite("Document and undo")
	var doc := MapDocument.new()
	doc.cols = 10
	doc.rows = 8

	doc.begin_op()
	doc.place(Vector2i(2, 2), MapDocument.Layer.TERRAIN, Piece.make("Hex - Base Plains 1", lib))
	doc.place(Vector2i(2, 2), MapDocument.Layer.FEATURES, Piece.make("Extras - Town 1", lib))
	doc.commit_op()
	t.eq(doc.cells.size(), 1, "one cell touched")
	t.eq(doc.piece_count(), 2, "two pieces in it")
	t.close(doc.get_cell(Vector2i(2, 2)).features[0].size, 96.0 / 224.0, "feature took its native size")

	# The top piece is what a click means: the town, not the grass under it.
	t.eq(doc.get_cell(Vector2i(2, 2)).top().tile, "Extras - Town 1", "topmost piece is the feature")

	doc.begin_op()
	doc.place(Vector2i(2, 2), MapDocument.Layer.FEATURES, Piece.make("Extras - Farm 1", lib))
	doc.commit_op()
	t.eq(doc.piece_count(), 3, "features stack")
	doc.undo()
	t.eq(doc.piece_count(), 2, "undo removes only the last operation")
	t.eq(doc.get_cell(Vector2i(2, 2)).features.size(), 1, "the earlier feature survived the undo")

	# Repainting terrain keeps the nudge already applied to that hex.
	doc.get_cell(Vector2i(2, 2)).terrain.offset = Vector2(0.1, -0.05)
	doc.begin_op()
	doc.place(Vector2i(2, 2), MapDocument.Layer.TERRAIN, Piece.make("Hex - Base Plains 2", lib))
	doc.commit_op()
	t.close_vec(doc.get_cell(Vector2i(2, 2)).terrain.offset, Vector2(0.1, -0.05), "repainting terrain keeps the nudge")

	doc.begin_op()
	doc.erase(Vector2i(2, 2), MapDocument.Layer.FEATURES)
	doc.erase(Vector2i(2, 2), MapDocument.Layer.TERRAIN)
	doc.commit_op()
	t.eq(doc.cells.size(), 0, "an emptied hex is forgotten, not kept as a husk")

	# Rivers rotate in place rather than stacking duplicates.
	doc.begin_op()
	doc.place(Vector2i(1, 1), MapDocument.Layer.LINES, Piece.make("Hex - River 1 N", lib))
	doc.commit_op()
	t.ok(doc.rotate_existing_line(Vector2i(1, 1), "Hex - River 1 N"), "existing river found")
	t.close(doc.get_cell(Vector2i(1, 1)).lines[0].rot, PI / 3.0, "river rotated one sixth of a turn")
	t.eq(doc.get_cell(Vector2i(1, 1)).lines.size(), 1, "no duplicate river added")


# ------------------------------------------------------------ draw order ---

func test_draw_order() -> void:
	t.suite("Draw order")
	var doc := MapDocument.new()
	doc.cols = 6
	doc.rows = 6
	# A town on (2,2) with plain ground on the hex below it. This is the exact
	# arrangement that used to bury the town: the lower hex's ground, drawn at
	# 200 % fill, covered the feature above it.
	doc.begin_op()
	for r in range(1, 5):
		doc.place(Vector2i(2, r), MapDocument.Layer.TERRAIN, Piece.make("Hex - Base Plains 1", lib))
	doc.place(Vector2i(2, 2), MapDocument.Layer.FEATURES, Piece.make("Extras - Town 1", lib))
	doc.place(Vector2i(2, 3), MapDocument.Layer.LINES, Piece.make("Hex - River 1 N", lib))
	doc.commit_op()

	var cmds := DrawList.build(doc, lib)
	t.eq(cmds.size(), 6, "one command per piece")

	var town_at := -1
	var river_at := -1
	var last_terrain := -1
	for i in cmds.size():
		match cmds[i].tile:
			"Extras - Town 1": town_at = i
			"Hex - River 1 N": river_at = i
			_: last_terrain = i
	t.ok(last_terrain < river_at, "every terrain tile is laid before any river")
	t.ok(river_at < town_at, "every river is laid before any feature")

	# Within the terrain pass, lower rows still overlap the ones above.
	var ys: Array[float] = []
	for c in cmds:
		if c.tile.begins_with("Hex - Base"):
			ys.append(c.pos.y)
	var sorted_ys := ys.duplicate()
	sorted_ys.sort()
	t.eq(ys, sorted_ys, "terrain still painted top row first")

	# Culling keeps the same order, just fewer commands.
	var near := Rect2(Hex.center(2, 2) - Vector2(0.6, 0.6), Vector2(1.2, 1.2))
	var few := DrawList.build(doc, lib, near)
	t.ok(few.size() < cmds.size(), "culling drops off-screen work")
	t.ok(few.size() > 0, "culling keeps what is on screen")


# ----------------------------------------------------------- token files ---

func test_token_format() -> void:
	t.suite("Token files (.ftok)")
	var path := fixtures.path_join("riverwatch.ftok")
	if not FileAccess.file_exists(path):
		t.ok(false, "fixture riverwatch.ftok is present")
		return
	var tok := TokenDef.load_file(path)
	t.ok(tok != null, "a .ftok written by the browser tool loads")
	if tok == null:
		return
	t.eq(tok.name, "Riverwatch", "name read")
	t.eq(tok.parts.size(), 4, "all four pieces read")
	t.ok(tok.size_hex.x > 0.5 and tok.size_hex.x < 2.0, "footprint is about one hex")
	t.ok(not tok.baked_png.is_empty(), "baked image decoded from the data URL")
	t.ok(tok.can_recompose(lib), "every part resolves against the loaded library")

	var img := tok.baked_image()
	t.ok(img != null and img.get_width() > 100, "baked PNG is a real image")

	# Round-trip through our own writer and back.
	var tmp := "user://roundtrip.ftok"
	t.eq(tok.save_file(tmp), OK, "token saves")
	var again := TokenDef.load_file(ProjectSettings.globalize_path(tmp))
	t.ok(again != null, "token reloads")
	if again != null:
		t.eq(again.parts.size(), tok.parts.size(), "part count survives the round trip")
		t.close(again.parts[0].size.x, tok.parts[0].size.x, "part width survives")
		t.close(again.size_hex.x, tok.size_hex.x, "footprint survives")
		t.close(again.pivot.x, tok.pivot.x, "pivot survives")

	# A token missing an asset must still be drawable from its bake.
	var orphan := TokenDef.new()
	orphan.parts.append(TokenDef.Part.new())
	orphan.parts[0].tile = "Not In This Pack"
	t.ok(not orphan.can_recompose(lib), "a missing asset blocks recomposition")


func test_token_transform() -> void:
	t.suite("Token placement maths")
	var doc := MapDocument.new()
	var def := TokenDef.new()
	def.id = "tok_test"
	def.size_hex = Vector2(1.0, 0.8)
	def.pivot = Vector2(0.5, 0.5)
	var part := TokenDef.Part.new()
	part.tile = "Extras - Town 1"
	part.pos = Vector2(0.25, 0.0)
	part.size = Vector2(0.4, 0.3)
	def.parts.append(part)
	doc.register_token(def)

	var inst := TokenInstance.new()
	inst.def_id = "tok_test"
	inst.pos = Vector2(5.0, 3.0)
	doc.tokens.append(inst)

	var baked := DrawList.build(doc, lib, Rect2(), false)
	t.eq(baked.size(), 1, "an un-recomposed token is one command")
	t.close_vec(baked[0].pos, Vector2(5.0, 3.0), "centred pivot puts the quad on the anchor")
	t.close_vec(baked[0].size, Vector2(1.0, 0.8), "baked size is the footprint")

	var parts := DrawList.build(doc, lib, Rect2(), true)
	t.eq(parts.size(), 1, "recomposed token emits its parts")
	t.close_vec(parts[0].pos, Vector2(5.25, 3.0), "part offset applied")
	t.close_vec(parts[0].size, Vector2(0.4, 0.3), "part size applied")

	# Scale multiplies both the offset and the size.
	inst.scale = 2.0
	parts = DrawList.build(doc, lib, Rect2(), true)
	t.close_vec(parts[0].pos, Vector2(5.5, 3.0), "scale multiplies the part offset")
	t.close_vec(parts[0].size, Vector2(0.8, 0.6), "scale multiplies the part size")

	# Rotation carries the part around the anchor.
	inst.scale = 1.0
	inst.rot = PI / 2.0
	parts = DrawList.build(doc, lib, Rect2(), true)
	t.close_vec(parts[0].pos, Vector2(5.0, 3.25), "a quarter turn swings the part around the anchor")
	t.close(parts[0].rot, PI / 2.0, "part inherits the instance rotation")

	# Flipping mirrors the offset and the piece.
	inst.rot = 0.0
	inst.flip = true
	parts = DrawList.build(doc, lib, Rect2(), true)
	t.close_vec(parts[0].pos, Vector2(4.75, 3.0), "flip mirrors the part offset")
	t.ok(parts[0].flip, "flip carries to the part")

	# An off-centre pivot must not move the anchor.
	inst.flip = false
	def.pivot = Vector2(0.0, 1.0)
	baked = DrawList.build(doc, lib, Rect2(), false)
	t.close_vec(baked[0].pos, Vector2(5.5, 2.6), "bottom-left pivot offsets the quad, not the anchor")

	# Several tokens in one hex must not land on top of each other.
	var spot := Hex.center(3, 3)
	doc.tokens.clear()
	var placed: Array[Vector2] = []
	for i in 4:
		var p := doc.free_spot_near(spot)
		var ti := TokenInstance.new()
		ti.def_id = "tok_test"
		ti.pos = p
		doc.tokens.append(ti)
		placed.append(p)
	var collisions := 0
	for i in placed.size():
		for j in range(i + 1, placed.size()):
			if placed[i].distance_to(placed[j]) < 0.02:
				collisions += 1
	t.eq(collisions, 0, "four tokens in one hex all stay reachable")
	for p in placed:
		t.ok(Hex.from_point(p) == Vector2i(3, 3), "fanned token stays in its hex")


# --------------------------------------------------------- legacy import ---

func test_legacy_v4() -> void:
	t.suite("Import: browser project v4")
	# Shaped exactly like hex-editor.html's serializeProject().
	var d := {
		"version": 4,
		"grid": {"cols": 12, "rows": 9, "hex": 64},
		"nativeSize": true, "extraK": 1.0,
		"dict": ["Hex - Base Plains 1", "Extras - Town 1", "Hex - River 1 S"],
		"cells": [
			# key, terrain index, lines, features, terrain transform
			["2,2", 0, [], [[1, 0, [0.5, 0.1, -0.15, 0.0, 0.0, 1.0, 0, 1.0]]], 0],
			["3,3", 0, [[2, 1, 0]], [], 0],
			["4,4", -1, [], [[1, 0, 0]], 0],
		],
		"tokens": [["tok_x", 3.5, 2.17, 1.5, 90.0, 1]],
		"tokenDefs": {},
	}
	var doc := LegacyIO.from_project_dict(d, lib)
	t.ok(doc != null, "project parsed")
	t.eq(doc.cols, 12, "columns")
	t.eq(doc.cells.size(), 3, "three cells")

	# Size is the browser's hexWidth × tileFill × nativeWidth × scale, collapsed
	# into one absolute number. 2.0 × (96/224) × 0.5.
	var town: Piece = doc.get_cell(Vector2i(2, 2)).features[0]
	t.close(town.size, 2.0 * (96.0 / 224.0) * 0.5, "per-piece scale folded into an absolute width")
	t.close_vec(town.offset, Vector2(0.1, -0.15), "per-piece offset carried over")
	t.close(town.aspect, 86.0 / 96.0, "aspect taken from the art, not the hex")

	var ground: Piece = doc.get_cell(Vector2i(2, 2)).terrain
	t.close(ground.size, 2.0, "a plain hex tile fills 200 % as it did in the browser")

	# A 60° step with no transform block still rotates.
	var river: Piece = doc.get_cell(Vector2i(3, 3)).lines[0]
	t.close(river.rot, PI / 3.0, "rotation step honoured when there is no transform block")

	# Terrain can be absent while a feature is present.
	t.ok(doc.get_cell(Vector2i(4, 4)).terrain == null, "a feature without ground still loads")

	t.eq(doc.tokens.size(), 1, "placed token read")
	t.close_vec(doc.tokens[0].pos, Vector2(3.5, 2.17), "token position is already in hex widths")
	t.close(doc.tokens[0].scale, 1.5, "token scale")
	t.close(doc.tokens[0].rot, PI / 2.0, "token rotation converted from degrees")
	t.ok(doc.tokens[0].flip, "token flip")

	# nativeSize off means the browser stretched everything to hex size.
	var d2 := d.duplicate(true)
	d2["nativeSize"] = false
	var doc2 := LegacyIO.from_project_dict(d2, lib)
	t.close(doc2.get_cell(Vector2i(2, 2)).features[0].size, 2.0 * 0.5,
		"with native sizing off, a town is hex-sized — the old look, preserved")


func test_legacy_v3() -> void:
	t.suite("Import: browser project v3")
	# v3 had one transform for the whole hex, and pixel offsets.
	var d := {
		"version": 3,
		"grid": {"cols": 8, "rows": 6, "hex": 64},
		"dict": ["Hex - Base Plains 1", "Extras - Town 1"],
		"cells": [["1,1", 0, [], [[1, 0]], 32.0, -16.0, 1.4, 10.0, 1.1]],
	}
	var doc := LegacyIO.from_project_dict(d, lib)
	t.eq(doc.cells.size(), 1, "cell parsed")
	var cell := doc.get_cell(Vector2i(1, 1))
	# v3 predates native sizing, so everything was drawn at hex size × scale.
	t.close(cell.terrain.size, 2.0 * 1.4, "whole-hex scale applied to the ground")
	t.close(cell.features[0].size, 2.0 * 1.4, "and to the feature — the old behaviour, unchanged")
	t.close_vec(cell.terrain.offset, Vector2(0.5, -0.25), "pixel nudge converted to hex widths")
	t.close(cell.terrain.hue, 10.0, "hue carried")
	t.close(cell.features[0].sat, 1.1, "saturation spread to every piece in the hex")


func test_legacy_v1() -> void:
	t.suite("Import: browser project v1")
	var d := {
		"version": 1,
		"grid": {"cols": 6, "rows": 6, "hex": 64},
		"cells": {
			"0,0": {"base": "Hex - Base Plains 1", "lines": ["Hex - River 1 N"], "features": []},
			"1,1": {"base": "Hex - Base Water 1", "lines": [], "features": [{"n": "Extras - Town 1", "rot": 1.0472}]},
		},
	}
	var doc := LegacyIO.from_project_dict(d, lib)
	t.eq(doc.cells.size(), 2, "both cells parsed")
	t.eq(doc.get_cell(Vector2i(0, 0)).lines[0].tile, "Hex - River 1 N", "bare string river entry")
	t.close(doc.get_cell(Vector2i(1, 1)).features[0].rot, 1.0472, "object entry with a radian rotation")


func test_stamp() -> void:
	t.suite("Import: stamps")
	var v2 := {
		"format": "falldin-stamp", "version": 2, "name": "walled town",
		"tileFill": 2.0, "nativeSize": true, "extraK": 1.0,
		"cells": [
			{
				"dxu": 0.0, "dyu": 0.0, "base": "Hex - Base Plains 1",
				"lines": [], "features": [["Extras - Town 1", 0]],
				"ov": {
					"base": null,
					"lines": [],
					"features": [{"sc": 0.6, "dx": 0.05, "dy": -0.1, "rot": 0.0, "hue": 0.0, "sat": 1.0, "flip": false, "alpha": 1.0}],
				},
			},
			{"dxu": 0.75, "dyu": 0.5, "base": "Hex - Base Water 1", "lines": [], "features": []},
		],
	}
	var stamp := StampDef.from_dict(v2, lib)
	t.ok(stamp != null, "v2 stamp parsed")
	t.eq(stamp.cells.size(), 2, "two hexes in the stamp")
	t.close(stamp.cells[0].features[0].size, 2.0 * (96.0 / 224.0) * 0.6, "per-piece scale from the ov block")
	# dyu was in hex heights; it has to become hex widths to land right.
	t.close_vec(stamp.cells[1].offset, Vector2(0.75, 0.5 * ASPECT), "row offset converted from hex heights")

	var doc := MapDocument.new()
	doc.cols = 10
	doc.rows = 10
	doc.begin_op()
	stamp.apply_to(doc, Vector2i(3, 3))
	doc.commit_op()
	t.eq(doc.cells.size(), 2, "stamp laid two hexes onto the map")
	t.ok(doc.get_cell(Vector2i(3, 3)) != null, "anchor hex filled")
	t.eq(doc.get_cell(Vector2i(3, 3)).features[0].tile, "Extras - Town 1", "feature landed with the stamp")
	# The second hex of the stamp sits south-east of the anchor, and must land
	# on the anchor's real SE neighbour rather than on a fixed column offset.
	var se := Hex.neighbor(3, 3, Hex.Dir.SE)
	t.ok(doc.get_cell(se) != null, "the stamp's second hex landed on the anchor's SE neighbour")

	# And the shape must not change with the anchor's column parity — the same
	# stamp dropped on an odd column has to come out the same shape.
	var even_doc := MapDocument.new()
	even_doc.cols = 12
	even_doc.rows = 12
	even_doc.begin_op()
	stamp.apply_to(even_doc, Vector2i(4, 4))
	even_doc.commit_op()
	var odd_doc := MapDocument.new()
	odd_doc.cols = 12
	odd_doc.rows = 12
	odd_doc.begin_op()
	stamp.apply_to(odd_doc, Vector2i(5, 4))
	odd_doc.commit_op()
	var even_shape: Array[Vector3i] = []
	for k: Vector2i in even_doc.cells:
		even_shape.append(Hex.to_cube(k) - Hex.to_cube(Vector2i(4, 4)))
	var odd_shape: Array[Vector3i] = []
	for k: Vector2i in odd_doc.cells:
		odd_shape.append(Hex.to_cube(k) - Hex.to_cube(Vector2i(5, 4)))
	even_shape.sort()
	odd_shape.sort()
	t.eq(odd_shape, even_shape, "a stamp keeps its shape on an odd column too")

	# A v1 stamp, with one transform for the whole hex and no ov block.
	var v1 := {
		"format": "falldin-stamp", "version": 1, "name": "old", "tileFill": 2.0,
		"cells": [{
			"dxu": 0.0, "dyu": 0.0, "base": "Hex - Base Plains 1",
			"ox": 6.0, "oy": -4.0, "sc": 1.6, "hue": 20.0, "sat": 1.2,
			"lines": [], "features": [["Extras - Town 1", 0]],
		}],
	}
	var old := StampDef.from_dict(v1, lib)
	t.ok(old != null, "v1 stamp parsed")
	t.close(old.cells[0].terrain.size, 2.0 * 1.6, "v1 whole-hex scale reaches the ground")
	t.close(old.cells[0].features[0].size, 2.0 * 1.6, "and the feature, as it used to look")
	t.close(old.cells[0].terrain.hue, 20.0, "v1 hue carried")


# ------------------------------------------------------- native project ---

func test_project_roundtrip() -> void:
	t.suite("Native project format")
	var doc := MapDocument.new()
	doc.cols = 14
	doc.rows = 11
	doc.hex_miles = 12.0
	doc.begin_op()
	for c in 6:
		for r in 4:
			doc.place(Vector2i(c, r), MapDocument.Layer.TERRAIN, Piece.make("Hex - Base Plains 1", lib))
	var town := Piece.make("Extras - Town 1", lib)
	town.size = 0.37
	town.offset = Vector2(0.06, -0.12)
	town.rot = deg_to_rad(15.0)
	town.hue = 24.0
	town.sat = 1.15
	town.alpha = 0.9
	town.flip = true
	doc.place(Vector2i(2, 2), MapDocument.Layer.FEATURES, town)
	doc.place(Vector2i(3, 2), MapDocument.Layer.LINES, Piece.make("Hex - River 1 S", lib))
	doc.commit_op()

	var def := TokenDef.load_file(fixtures.path_join("riverwatch.ftok"))
	if def != null:
		doc.register_token(def)
		var inst := TokenInstance.new()
		inst.def_id = def.id
		inst.pos = Hex.center(4, 2)
		inst.scale = 1.25
		inst.rot = deg_to_rad(20.0)
		doc.tokens.append(inst)

	var path := "user://roundtrip.falldin"
	t.eq(ProjectIO.save(doc, path), OK, "project saves")
	var back := ProjectIO.load_file(ProjectSettings.globalize_path(path))
	t.ok(back != null, "project reloads")
	if back == null:
		return
	t.eq(back.cols, doc.cols, "columns survive")
	t.eq(back.cells.size(), doc.cells.size(), "cell count survives")
	t.eq(back.piece_count(), doc.piece_count(), "piece count survives")

	var t2: Piece = back.get_cell(Vector2i(2, 2)).features[0]
	t.close(t2.size, 0.37, "size survives")
	t.close_vec(t2.offset, Vector2(0.06, -0.12), "offset survives")
	t.close(t2.rot, deg_to_rad(15.0), "rotation survives", 0.001)
	t.close(t2.hue, 24.0, "hue survives")
	t.close(t2.sat, 1.15, "saturation survives")
	t.close(t2.alpha, 0.9, "opacity survives")
	t.ok(t2.flip, "flip survives")
	t.close(t2.aspect, 86.0 / 96.0, "aspect survives")

	t.eq(back.tokens.size(), doc.tokens.size(), "tokens survive")
	if not back.tokens.is_empty():
		t.close(back.tokens[0].scale, 1.25, "token scale survives")
		t.close(back.tokens[0].rot, deg_to_rad(20.0), "token rotation survives", 0.001)
		var rdef := back.token_def(back.tokens[0].def_id)
		t.ok(rdef != null, "the token's definition travels inside the project")
		if rdef != null:
			t.eq(rdef.parts.size(), 4, "its recipe survives, so an HD render still rebuilds it")
			t.ok(not rdef.baked_png.is_empty(), "its baked image survives, so it draws without the pack")

	# The two documents must produce identical draw lists.
	var a := DrawList.build(doc, lib)
	var b := DrawList.build(back, lib)
	t.eq(a.size(), b.size(), "same number of draw commands")
	var mismatched := 0
	for i in mini(a.size(), b.size()):
		if a[i].tile != b[i].tile or a[i].pos.distance_to(b[i].pos) > 0.001 \
			or a[i].size.distance_to(b[i].size) > 0.001:
			mismatched += 1
	t.eq(mismatched, 0, "every command matches after a save and load")

	# Bounds are what an export frames.
	var bounds := doc.content_bounds()
	t.ok(bounds.size.x > 4.0 and bounds.size.y > 2.0, "content bounds cover the painted area")


# --------------------------------------------------------------- export ---

func test_export() -> void:
	t.suite("Image export")
	var doc := MapDocument.new()
	doc.cols = 6
	doc.rows = 5
	doc.begin_op()
	for c in 5:
		for r in 4:
			doc.place(Vector2i(c, r), MapDocument.Layer.TERRAIN, Piece.make("Hex - Base Plains 1", lib))
	# A town on (2,2), with ground on the hex below it. On screen and in an
	# export alike, the town must survive the hex below being painted.
	doc.place(Vector2i(2, 2), MapDocument.Layer.FEATURES, Piece.make("Extras - Town 1", lib))
	doc.commit_op()

	var opts := ImageExporter.Options.new()
	opts.px_per_hex = 224.0
	opts.background = Color(0, 0, 0, 0)
	var res := ImageExporter.render(doc, lib, opts)
	t.ok(res.image != null, "export produced an image")
	if res.image == null:
		return
	t.eq(res.missing.size(), 0, "no assets went missing")
	t.close(res.px_per_hex, 224.0, "asked-for resolution honoured")
	t.ok(res.size().x > 800 and res.size().y > 600, "image covers the painted area (%s)" % res.size())

	# The town's roof is a distinct red; find it in the output.
	var town_centre := Hex.center(2, 2)
	var to_px := func(p: Vector2) -> Vector2i:
		return Vector2i(
			int((p.x - res.region.position.x) * res.px_per_hex),
			int((p.y - res.region.position.y) * res.px_per_hex))
	var at := to_px.call(town_centre) as Vector2i
	var found_roof := false
	for dy in range(-40, 41, 4):
		for dx in range(-40, 41, 4):
			var px := at + Vector2i(dx, dy)
			if px.x < 0 or px.y < 0 or px.x >= res.image.get_width() or px.y >= res.image.get_height():
				continue
			var col := res.image.get_pixel(px.x, px.y)
			if col.r > 0.55 and col.g < 0.40 and col.b < 0.35 and col.a > 0.9:
				found_roof = true
				break
		if found_roof:
			break
	t.ok(found_roof, "the town is visible in the export, not buried under the next hex's ground")

	# Ground everywhere it should be, and nothing where it should not.
	var ground := to_px.call(Hex.center(0, 0)) as Vector2i
	t.ok(res.image.get_pixel(ground.x, ground.y).a > 0.9, "terrain rendered")

	# Tokens go through the same path.
	var def := TokenDef.load_file(fixtures.path_join("riverwatch.ftok"))
	if def != null:
		doc.register_token(def)
		var inst := TokenInstance.new()
		inst.def_id = def.id
		inst.pos = Hex.center(1, 1)
		doc.tokens.append(inst)
		var with_token := ImageExporter.render(doc, lib, opts)
		t.eq(with_token.missing.size(), 0, "token parts all resolved from the library")
		t.ok(with_token.image != null, "export with a token succeeded")

		# Recomposed from parts, a token is sharp at any resolution; the baked
		# fallback is not. Both must at least draw something.
		var baked_opts := ImageExporter.Options.new()
		baked_opts.px_per_hex = 224.0
		baked_opts.recompose_tokens = false
		var baked := ImageExporter.render(doc, lib, baked_opts)
		t.ok(baked.image != null, "export from the baked image succeeded")

	# Rotation: a river laid at 60° must not come out axis-aligned.
	var rot_doc := MapDocument.new()
	rot_doc.cols = 3
	rot_doc.rows = 3
	rot_doc.begin_op()
	var river := Piece.make("Hex - River 1 N", lib)
	river.rot = PI / 3.0
	rot_doc.place(Vector2i(1, 1), MapDocument.Layer.LINES, river)
	rot_doc.commit_op()
	var rot_res := ImageExporter.render(rot_doc, lib, opts)
	t.ok(rot_res.image != null, "rotated piece exported")
	if rot_res.image != null:
		# The unrotated art is a vertical bar from the centre upward. After a
		# sixth of a turn its far end has moved right of centre.
		var opaque_min_x := 1 << 20
		var opaque_max_x := -1
		for y in rot_res.image.get_height():
			for x in rot_res.image.get_width():
				if rot_res.image.get_pixel(x, y).a > 0.5:
					opaque_min_x = mini(opaque_min_x, x)
					opaque_max_x = maxi(opaque_max_x, x)
		t.ok(opaque_max_x > opaque_min_x, "rotated art occupies a horizontal span")
		t.ok(opaque_max_x - opaque_min_x > 40, "the span is wide, so the bar really did tilt")

	# The resolution guard scales down instead of trying to allocate the moon.
	var huge := ImageExporter.Options.new()
	huge.px_per_hex = 4000.0
	huge.max_pixels = 4_000_000
	var capped := ImageExporter.render(doc, lib, huge)
	t.ok(capped.scaled_down, "an over-large render is scaled to fit the budget")
	t.ok(capped.size().x * capped.size().y <= 4_200_000, "and lands inside it (%s)" % capped.size())

	# Well past what a browser canvas can hold: 16 000 px a side is the limit
	# there, and 120 MP the area cap.
	var wide := ImageExporter.Options.new()
	wide.px_per_hex = 224.0
	var big_doc := MapDocument.new()
	big_doc.cols = 150
	big_doc.rows = 4
	big_doc.begin_op()
	for c in 150:
		big_doc.place(Vector2i(c, 1), MapDocument.Layer.TERRAIN, Piece.make("Hex - Base Plains 1", lib))
	big_doc.commit_op()
	var wide_res := ImageExporter.render(big_doc, lib, wide)
	# A browser canvas refuses anything past 16 384 px on a side.
	t.ok(wide_res.size().x > 16384, "a render wider than any browser canvas allows (%d px)" % wide_res.size().x)
	t.ok(not wide_res.scaled_down, "and it was not scaled down to get there")
