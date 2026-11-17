## Batch renderer. No window, no editor, no browser.
##
##   godot --headless --path . --script res://tools/render_cli.gd -- \
##       --assets "/path/to/World Map Hex Tiles" \
##       --map    map.falldin \
##       --out    poster.png \
##       --ppx    933
##
## Accepts Falldin projects and the browser tool's falldin-hexmap.json alike.
extends SceneTree

const USAGE := """
Falldin batch renderer

  --assets PATH    tile pack folder (repeatable)
  --map PATH       .falldin project, or a browser falldin-hexmap.json
  --out PATH       output .png            (default: alongside the map)
  --ppx N          pixels per hex         (default: the pack's own resolution)
  --max-pixels N   allocation ceiling     (default: 400000000)
  --bg RRGGBBAA    background colour      (default: transparent)
  --region c0,r0,c1,r1   render only this block of hexes
  --grid           frame to the hex grid instead of the art's overhang
  --baked-tokens   use each token's baked image instead of rebuilding it
  --tile-fill N    how wide a hex tile was drawn in the browser (default 2.0)
"""


func _initialize() -> void:
	var args := _parse(OS.get_cmdline_user_args())
	if args.has("help") or not args.has("map"):
		print(USAGE)
		quit(0 if args.has("help") else 2)
		return

	var lib := AssetLibrary.new()
	var asset_roots: Array = args.get("assets", [])
	for root: String in asset_roots:
		var stats := lib.scan(root)
		print("assets: %s -> %d tiles (%d files)" % [root, stats.added, stats.found])
	if lib.count() == 0:
		printerr("No assets found. Pass --assets with your tile pack folder.")
		quit(3)
		return
	print("reference hex: %d px" % int(lib.ref_px))

	var map_path := str(args["map"])
	var doc := _load_map(map_path, lib, float(args.get("tile-fill", LegacyIO.DEFAULT_TILE_FILL)))
	if doc == null:
		printerr("Could not read map: %s" % map_path)
		quit(4)
		return
	print("map: %d hexes, %d pieces, %d tokens" % [doc.cells.size(), doc.piece_count(), doc.tokens.size()])

	var opts := ImageExporter.Options.new()
	opts.px_per_hex = float(args.get("ppx", 0.0))
	opts.max_pixels = int(args.get("max-pixels", 400_000_000))
	opts.recompose_tokens = not args.has("baked-tokens")
	opts.align_to_grid = args.has("grid")
	if args.has("bg"):
		opts.background = Color.html(str(args["bg"]))
	if args.has("region"):
		var r: PackedStringArray = str(args["region"]).split(",")
		if r.size() == 4:
			opts.region = Hex.block_bounds(int(r[0]), int(r[1]), int(r[2]), int(r[3]))

	print("rendering…")
	var res := ImageExporter.render(doc, lib, opts)
	if res.image == null:
		printerr("Nothing to render.")
		quit(5)
		return

	var out_path := str(args.get("out", map_path.get_basename() + ".png"))
	var err := res.image.save_png(out_path)
	if err != OK:
		printerr("Could not write %s (error %d)" % [out_path, err])
		quit(6)
		return

	var mp := float(res.size().x) * float(res.size().y) / 1_000_000.0
	print("wrote %s — %d × %d (%.1f MP) at %d px/hex in %.1f s" % [
		out_path, res.size().x, res.size().y, mp, int(res.px_per_hex), res.elapsed_ms / 1000.0])
	if res.scaled_down:
		print("note: scaled down to stay inside --max-pixels")
	if not res.missing.is_empty():
		print("missing %d asset(s): %s" % [res.missing.size(), ", ".join(res.missing)])
	lib.save_cache()
	quit(0)


func _load_map(path: String, lib: AssetLibrary, tile_fill: float) -> MapDocument:
	var doc := ProjectIO.load_file(path)
	if doc != null:
		return doc
	return LegacyIO.load_project(path, lib, tile_fill)


## Flags are --name or --name value; --assets may appear more than once.
static func _parse(argv: PackedStringArray) -> Dictionary:
	var out := {}
	var i := 0
	while i < argv.size():
		var a := argv[i]
		if not a.begins_with("--"):
			i += 1
			continue
		var key := a.substr(2)
		var has_value := i + 1 < argv.size() and not argv[i + 1].begins_with("--")
		var value: String = argv[i + 1] if has_value else ""
		if key == "assets":
			if not out.has("assets"):
				out["assets"] = []
			(out["assets"] as Array).append(value)
		elif has_value:
			out[key] = value
		else:
			out[key] = true
		i += 2 if has_value else 1
	return out
