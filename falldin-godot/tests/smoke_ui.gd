## Drives the real interface with no window attached.
##
## Nothing renders headlessly, so this proves nothing about how the app looks.
## What it does prove is that every widget builds, every signal is wired to a
## method that exists with the right signature, and that a full session — load
## assets, paint, select, adjust, import, place a token, export — runs without
## touching a null.
extends SceneTree

var t := TestHarness.new()
var app: Control
var _ran := false


func _initialize() -> void:
	print("Falldin interface smoke test")
	app = load("res://src/app/main.tscn").instantiate()
	root.add_child(app)


## _ready is deferred until a frame is processed, so the widgets do not exist
## yet inside _initialize. Run once the first frame has gone by.
func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	_run()
	return true


func _run() -> void:
	var fixtures := ProjectSettings.globalize_path("res://tests/fixtures")
	t.suite("Application shell")
	t.ok(app != null, "main scene instantiates")
	t.ok(app.view != null, "map view built")

	app.load_assets(fixtures)
	t.eq(app.lib.count(), 15, "palette loaded the fixtures")
	t.ok(app._tiles.item_count > 0, "palette shows items")

	# Pick a tile the way a click does, then check the layer followed.
	var idx := -1
	for i in app._tiles.item_count:
		if str(app._tiles.get_item_metadata(i)) == "Extras - Town 1":
			idx = i
	t.ok(idx >= 0, "town is in the palette")
	app._on_tile_picked(idx)
	t.eq(app.view.brush, "Extras - Town 1", "brush set from the palette")
	t.eq(app.view.layer, MapDocument.Layer.FEATURES, "picking an extra selects the feature layer")

	for i in app._tiles.item_count:
		if str(app._tiles.get_item_metadata(i)) == "Hex - River 1 N":
			app._on_tile_picked(i)
	t.eq(app.view.layer, MapDocument.Layer.LINES, "picking a river selects the river layer")

	# Paint through the view's own code path, including auto-connect.
	t.suite("Painting")
	var view: MapView = app.view
	view.doc.begin_op()
	view.brush = "Hex - Base Plains 1"
	view.layer = MapDocument.Layer.TERRAIN
	for c in 5:
		for r in 4:
			view._paint(Vector2i(c, r))
	view.doc.commit_op()
	t.eq(view.doc.cells.size(), 20, "painted a block of terrain")

	view.doc.begin_op()
	view.brush = "Hex - River 1 N"
	view.layer = MapDocument.Layer.LINES
	view.brush_rot_step = 0
	view._paint(Vector2i(2, 2))
	view.doc.commit_op()
	var north := Hex.neighbor(2, 2, Hex.Dir.N)
	var nb := view.doc.get_cell(north)
	t.ok(nb != null and not nb.lines.is_empty(), "auto-connect dropped the matching half on the neighbour")
	if nb != null and not nb.lines.is_empty():
		t.eq(nb.lines[0].tile, "Hex - River 1 S", "and it is the opposite piece")

	view.doc.begin_op()
	view.brush = "Extras - Town 1"
	view.layer = MapDocument.Layer.FEATURES
	view._paint(Vector2i(2, 2))
	view.doc.commit_op()
	t.close(view.doc.get_cell(Vector2i(2, 2)).features[0].size, 96.0 / 224.0,
		"a painted town takes its native size")

	# Selecting and adjusting, which is what the inspector drives.
	t.suite("Inspector")
	view._select_cell(Vector2i(2, 2))
	t.ok(view.sel_piece != null, "clicking a hex selects its topmost piece")
	t.eq(view.sel_piece.tile, "Extras - Town 1", "the town, not the grass under it")
	t.ok(app._stack.item_count >= 3, "the hex's whole stack is listed (%d rows)" % app._stack.item_count)

	app._on_stack_picked(0)
	t.eq(view.sel_piece.tile, "Hex - Base Plains 1", "picking a row selects that layer's piece")
	view.select_piece(Vector2i(2, 2), MapDocument.Layer.FEATURES, 0)
	t.eq(view.sel_piece.tile, "Extras - Town 1", "and back to the feature")

	app._on_size(60.0)
	t.close(view.sel_piece.size, 0.6, "size slider moves only the selected piece")
	t.close(view.doc.get_cell(Vector2i(2, 2)).terrain.size, 1.0, "the ground under it did not move")
	app._on_rot(30.0)
	t.close(view.sel_piece.rot, deg_to_rad(30.0), "rotation slider", 0.001)
	app._on_hue(40.0)
	app._on_sat(130.0)
	t.close(view.sel_piece.hue, 40.0, "hue slider")
	app._resize_selected(0.25)
	t.close(view.sel_piece.size, 0.25, "quick size button")
	app._reset_selected()
	t.close(view.sel_piece.size, 96.0 / 224.0, "reset returns it to its native size")
	t.close(view.sel_piece.hue, 0.0, "reset clears the tint")

	# Tokens, through the same folder the browser token maker writes.
	t.suite("Tokens")
	app.load_token_dir(fixtures)
	t.ok(app._tokens.size() >= 1, "token folder read (%d)" % app._tokens.size())
	if not app._tokens.is_empty():
		app._on_token_picked(0)
		t.eq(view.tool, MapView.Tool.TOKEN, "picking a token switches to the token tool")
		var spot := Hex.center(3, 2)
		view._token_press(spot)
		t.eq(view.doc.tokens.size(), 1, "first token placed on an empty hex")
		view._token_press(spot)
		t.eq(view.doc.tokens.size(), 1, "clicking it again picks it up rather than duplicating it")
		t.eq(view.sel_token, 0, "and selects it")
		# Shift is what stacks a second and third piece of art on the same hex.
		view._token_press(spot, true)
		view._token_press(spot, true)
		t.eq(view.doc.tokens.size(), 3, "shift-click stacks three tokens on one hex")
		var all_in_hex := true
		for inst in view.doc.tokens:
			if Hex.from_point(inst.pos) != Vector2i(3, 2):
				all_in_hex = false
		t.ok(all_in_hex, "all three stayed in that hex")
		var hits := view.doc.tokens_at(view.doc.tokens[0].pos)
		t.ok(hits.size() >= 1, "a token under the cursor is found")
		# Clicking the same spot again walks down the stack.
		# Overlapping tokens: clicking the same spot walks down the stack so a
		# buried one is still reachable.
		var overlap := view.doc.tokens[0].pos
		var stack := view.doc.tokens_at(overlap)
		var seen := {}
		for i in 6:
			view._token_press(overlap)
			seen[view.sel_token] = true
		t.ok(seen.size() == stack.size() and stack.size() > 1,
			"repeated clicks reach every token under the cursor (" + str(seen.size()) + " of " + str(stack.size()) + ")")

	# Importing a browser project through the menu path.
	t.suite("Import and export")
	var legacy := {
		"version": 4, "grid": {"cols": 8, "rows": 6, "hex": 64},
		"nativeSize": true, "extraK": 1.0,
		"dict": ["Hex - Base Plains 1", "Extras - Town 1"],
		"cells": [["1,1", 0, [], [[1, 0, 0]], 0], ["2,2", 0, [], [], 0]],
	}
	var legacy_path := "user://legacy.json"
	var f := FileAccess.open(legacy_path, FileAccess.WRITE)
	f.store_string(JSON.stringify(legacy))
	f.close()
	app.import_legacy(ProjectSettings.globalize_path(legacy_path))
	t.eq(app.doc.cells.size(), 2, "browser project imported through the menu path")

	var out := ProjectSettings.globalize_path("user://smoke_export.png")
	app.export_png(out)
	t.ok(FileAccess.file_exists(out), "export wrote a PNG")
	if FileAccess.file_exists(out):
		var img := Image.load_from_file(out)
		t.ok(img != null and img.get_width() > 100,
			"and it is a real image (" + (str(img.get_width()) + " x " + str(img.get_height()) if img != null else "none") + ")")
	t.ok(app._status.text.contains("Exported"), "status line reports the export")

	var proj := ProjectSettings.globalize_path("user://smoke.falldin")
	app._project_path = proj
	app._save_project()
	t.ok(FileAccess.file_exists(proj), "project saved")
	app.open_project(proj)
	t.eq(app.doc.cells.size(), 2, "and reopened")

	# Camera maths must agree in both directions.
	t.suite("View transforms")
	view.zoom = 64.0
	view.origin = Vector2(3.0, 2.0)
	var p := Vector2(5.5, 4.25)
	t.close_vec(view.screen_to_world(view.world_to_screen(p)), p, "screen and world round-trip")
	var before := view.screen_to_world(Vector2(400, 300))
	view.zoom_by(2.0, Vector2(400, 300))
	t.close_vec(view.screen_to_world(Vector2(400, 300)), before, "zoom keeps the point under the cursor", 0.002)

	var failures := t.report()
	quit(1 if failures > 0 else 0)
