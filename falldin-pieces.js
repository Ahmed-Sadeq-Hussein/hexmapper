/* =====================================================================================
   Falldin hexmapper — shared piece (stamp) format
   Loaded by hex-editor.html (and by the stamp creator), so both tools read pieces the same way.
   Keep this file next to the .html files.

   PIECE FILE, version 3:
   {
     format:  'falldin-stamp',
     version: 3,
     name:    'walled city',
     settings:{ tileFill: 2, nativeSize: true, extraK: 1 },   // how the piece was drawn when authored
     cells: [ { q:0, a:0,                                     // AXIAL hex offset from the piece's anchor hex
                base: obj | null, lines: [obj], features: [obj] } ],   // a cell may be empty: it is still
                                                              // part of the piece's footprint (its shape)
     art:   { '<id>': { src:'data:image/png;base64,...' } },  // your own images, embedded so one file is enough
     thumb:   'data:image/png;base64,...'
   }
   obj = { n:'Hex - Plains (lush) 1', rot:0 (degrees), sc, dx, dy, flip, hue, sat, alpha }
         every field except n is optional; dx / dy are in HEX WIDTHS, so they survive any zoom or DPI.
   art obj = { a:'<id>', w:2.4, ... }  — your own image instead of a pack tile; w = its width in hex widths.
         With trim:true the image stored under a: is already cut to the piece's hex outline, and
         orig:'<id>' points at the untrimmed original so the Stamp Creator can keep editing it.

   Axial coordinates make a piece a rigid shape on the hex lattice: it lands identically on any
   hex, odd or even column, and can later be rotated in 60° steps.
   ===================================================================================== */
(function(G){
"use strict";
const HEXAR = 194/224;                          // flat-top hex: height / width
const TR_DEF = { sc:1, dx:0, dy:0, flip:false, hue:0, sat:1, alpha:1, w:1 };   // w: width of an art object, in hex widths
const DEG = Math.PI/180;

// odd-q offset (column, row; odd columns shifted down) <-> axial (q, a)
function toAxial(c, r){ return [c, r - ((c - (c & 1)) / 2)]; }
function toOffset(q, a){ return [q, a + ((q - (q & 1)) / 2)]; }

const r4 = v => Math.round(v * 1e4) / 1e4;

// Normalised in-memory object: rot in RADIANS, every field present.
function objIn(raw, legacy){
  if(raw == null) return null;
  const o = Object.assign({}, TR_DEF, legacy || {});
  if(typeof raw === 'string'){ o.n = raw; o.rot = 0; return o; }
  if(Array.isArray(raw)){ o.n = raw[0]; o.rot = (raw[1] || 0) * (Math.PI/3); return o; }   // old [name, 60°-step]
  if(raw.a !== undefined){ o.a = String(raw.a); if(raw.orig) o.orig = String(raw.orig); if(raw.trim) o.trim = true; }
  else o.n = raw.n;
  for(const k of Object.keys(TR_DEF)) if(raw[k] !== undefined) o[k] = raw[k];
  o.flip = !!o.flip;
  o.rot = (raw.rot || 0) * DEG;
  return o;
}
// Only the non-default transform fields (rot excluded) — null when there are none.
function trOut(o){
  const out = {};
  for(const k of Object.keys(TR_DEF)){
    const v = o[k]; if(v === undefined || v === TR_DEF[k]) continue;
    out[k] = (typeof v === 'number') ? r4(v) : v;
  }
  return Object.keys(out).length ? out : null;
}
function objOut(o){                              // normalised object -> file object
  const out = (o.a !== undefined) ? { a:o.a } : { n:o.n };
  if(o.a !== undefined && o.trim){ out.trim = true; if(o.orig) out.orig = o.orig; }
  const rot = r4((o.rot || 0) / DEG); if(rot) out.rot = rot;
  return Object.assign(out, trOut(o) || {});
}

/* Read any stamp file (v1, v2 or v3) into one normalised shape:
   { name, thumb, settings:{tileFill,nativeSize,extraK}, cells:[{q,a,base,lines,features}] }
   Objects come back from objIn(). */
function readPiece(st){
  if(!st || st.format !== 'falldin-stamp') throw new Error('Not a Falldin stamp');
  const ver = st.version || 1;
  if(ver >= 3){
    const s = st.settings || {};
    return {
      name: st.name || 'piece', thumb: st.thumb || '', art: st.art || {},
      settings: { tileFill: s.tileFill || 2, nativeSize: s.nativeSize !== false, extraK: s.extraK || 1 },
      cells: (st.cells || []).map(c => ({
        q: c.q | 0, a: c.a | 0,
        base: c.base ? objIn(c.base) : null,
        lines: (c.lines || []).map(x => objIn(x)),
        features: (c.features || []).map(x => objIn(x)),
      })),
    };
  }
  // v1 / v2: positions are centre offsets in hex units (dxu = x / hex width, dyu = y / hex height)
  // from an anchor hex. Hex centres sit at y = a + q/2 + 0.5 in axial terms, so the axial step is exact.
  const cells = (st.cells || []).map(c => {
    const q = Math.round((c.dxu || 0) / 0.75);
    const a = Math.round((c.dyu || 0) - q / 2);
    const ov = c.ov || null;
    // pre-v2 stamps kept one cell-wide nudge in pixels at a 72 px hex, plus a cell-wide size / colour
    const legacy = ov ? null : { sc:c.sc || 1, dx:(c.ox || 0) / 72, dy:(c.oy || 0) / 72, hue:c.hue || 0, sat:(c.sat === undefined ? 1 : c.sat) };
    const withTr = (raw, tr) => {
      const o = objIn(raw, legacy);
      if(tr){ for(const k of Object.keys(TR_DEF)) if(tr[k] !== undefined) o[k] = tr[k]; o.flip = !!o.flip;
              if(tr.rot !== undefined) o.rot = tr.rot * DEG; }
      return o;
    };
    return {
      q, a,
      base: c.base ? withTr(c.base, ov && ov.base) : null,
      lines: (c.lines || []).map((x, i) => withTr(x, ov && ov.lines && ov.lines[i])),
      features: (c.features || []).map((x, i) => withTr(x, ov && ov.features && ov.features[i])),
    };
  });
  return {
    name: st.name || 'piece', thumb: st.thumb || '', art: {},
    settings: { tileFill: st.tileFill || 2, nativeSize: !!st.nativeSize, extraK: st.extraK || 1 },
    cells,
  };
}

// Build a v3 file from normalised cells ({q,a,base,lines,features} with objIn-style objects).
function writePiece(name, settings, cells, thumb, art){
  return {
    format: 'falldin-stamp', version: 3, name,
    settings: { tileFill: settings.tileFill, nativeSize: !!settings.nativeSize, extraK: settings.extraK || 1 },
    cells: cells.map(c => {
      const out = { q:c.q, a:c.a };
      if(c.base) out.base = objOut(c.base);
      if(c.lines && c.lines.length) out.lines = c.lines.map(objOut);
      if(c.features && c.features.length) out.features = c.features.map(objOut);
      return out;
    }),
    art: art || {},
    thumb: thumb || '',
  };
}
// Small, stable id for an embedded image (FNV-1a over the data URL).
function artId(dataUrl){
  let h = 0x811c9dc5;
  for(let i = 0; i < dataUrl.length; i++){ h ^= dataUrl.charCodeAt(i); h = Math.imul(h, 0x01000193); }
  return (h >>> 0).toString(16).padStart(8, '0') + '-' + dataUrl.length.toString(36);
}

/* Turn a read piece (from readPiece) by `steps` × 60° clockwise, after mirroring it left-right if `mirror`.
   The shape and every object's position turn with it. What an object itself does:
     - rivers / paths (lines) turn with the piece, so they still meet the hex edges they flowed through;
     - your own images trimmed to the piece's outline turn too, so they still fit it;
     - terrain, features and untrimmed images stay upright (a town is never drawn on its side).
   Mirroring flips every object, so it applies to all of them. */
function transformPiece(P, steps, mirror){
  steps = ((steps % 6) + 6) % 6;
  if(!steps && !mirror) return P;
  const th = steps * Math.PI / 3, cs = Math.cos(th), sn = Math.sin(th), sx = mirror ? -1 : 1;
  const turn = (x, y) => { x *= sx; return [x * cs - y * sn, x * sn + y * cs]; };   // hex-width units, y down
  const obj = (o, line) => {
    const n = Object.assign({}, o);
    [n.dx, n.dy] = turn(o.dx || 0, o.dy || 0);
    let rot = o.rot || 0;
    if(mirror){ rot = -rot; n.flip = !o.flip; }
    if(line || (o.a !== undefined && o.trim)) rot += th;
    n.rot = Math.atan2(Math.sin(rot), Math.cos(rot));
    if(Math.abs(n.dx) < 1e-9) n.dx = 0; if(Math.abs(n.dy) < 1e-9) n.dy = 0;
    return n;
  };
  const cells = P.cells.map(c => {
    const [x, y] = turn(0.75 * c.q, HEXAR * (c.a + c.q / 2));       // hex centre relative to the anchor
    const q = Math.round(x / 0.75), a = Math.round(y / HEXAR - q / 2);
    return { q, a, base: c.base ? obj(c.base, false) : null,
             lines: c.lines.map(o => obj(o, true)), features: c.features.map(o => obj(o, false)) };
  });
  return Object.assign({}, P, { cells });
}

G.FalldinPieces = { HEXAR, TR_DEF, toAxial, toOffset, objIn, objOut, trOut, readPiece, writePiece, artId, transformPiece };

/* =====================================================================================
   PIECE LIBRARY — a folder on disk (Chrome / Edge), or the browser's own storage as a fallback.
   In folder mode every piece is one '<name>.stamp.json' file, so pieces can be copied between
   computers, kept in Dropbox / git, or sorted into subfolders. Both tools read the same folder.
   The chosen folder is remembered (IndexedDB); the browser may ask once per visit to allow access again.
   Pieces returned by list() carry a hidden ._file (path inside the folder), never written to disk.
   ===================================================================================== */
const LS_LIB = 'falldin_stamp_lib_v3', DB = 'falldin-hexmapper', STORE = 'handles', KEY = 'pieceFolder';
let dir = null, pending = null;
function idb(mode, fn){
  return new Promise((res, rej) => {
    const rq = indexedDB.open(DB, 1);
    rq.onupgradeneeded = () => rq.result.createObjectStore(STORE);
    rq.onerror = () => rej(rq.error);
    rq.onsuccess = () => { const db = rq.result, tx = db.transaction(STORE, mode), r = fn(tx.objectStore(STORE));
      tx.oncomplete = () => { db.close(); res(r && r.result); }; tx.onerror = () => { db.close(); rej(tx.error); }; };
  });
}
const lsGet = () => { try{ return JSON.parse(localStorage.getItem(LS_LIB)) || []; }catch(e){ return []; } };
const lsSet = a => { try{ localStorage.setItem(LS_LIB, JSON.stringify(a)); return true; }catch(e){ return false; } };
const slug = s => ((s || 'piece').trim().replace(/[^\w\- ]+/g, '').replace(/\s+/g, '-').toLowerCase() || 'piece');
const tagFile = (st, f) => Object.defineProperty(st, '_file', { value:f, enumerable:false, configurable:true, writable:true });
async function resolve(path, create){            // 'cities/walled-city.stamp.json' -> [folder handle, file name]
  const parts = path.split('/'); let d = dir;
  for(const p of parts.slice(0, -1)) d = await d.getDirectoryHandle(p, { create:!!create });
  return [d, parts[parts.length - 1]];
}
async function walk(d, prefix, out, depth){
  for await (const [name, h] of d.entries()){
    if(h.kind === 'directory'){ if(depth < 4 && !name.startsWith('.')) await walk(h, prefix + name + '/', out, depth + 1); continue; }
    if(!/\.json$/i.test(name)) continue;
    try{
      const data = JSON.parse(await (await h.getFile()).text());
      if(data && data.format === 'falldin-stamp') out.push(tagFile(data, prefix + name));
      else if(data && data.format === 'falldin-stamp-pack')        // a pack file: its pieces show up, read-only
        (data.stamps || []).forEach((st, i) => { if(st && st.format === 'falldin-stamp') out.push(tagFile(st, prefix + name + '#' + i)); });
    }catch(e){ /* not a piece file: ignore */ }
  }
}
const Library = {
  supported: typeof G.showDirectoryPicker === 'function',
  state(){ return { mode: dir ? 'folder' : 'browser', name: (dir || pending || {}).name || '', needsPermission: !!pending && !dir }; },
  async init(){                                   // reconnect to the remembered folder if the browser still allows it
    if(!this.supported) return this.state();
    try{ const h = await idb('readonly', s => s.get(KEY));
      if(h){ if(await h.queryPermission({ mode:'readwrite' }) === 'granted') dir = h; else pending = h; } }catch(e){}
    return this.state();
  },
  async choose(){                                 // must run from a click
    const h = await G.showDirectoryPicker({ id:'falldin-pieces', mode:'readwrite' });
    dir = h; pending = null; try{ await idb('readwrite', s => s.put(h, KEY)); }catch(e){}
    return this.state();
  },
  async reconnect(){                              // must run from a click
    if(!pending) return this.state();
    if(await pending.requestPermission({ mode:'readwrite' }) === 'granted'){ dir = pending; pending = null; }
    return this.state();
  },
  async disconnect(){ dir = null; pending = null; try{ await idb('readwrite', s => s.delete(KEY)); }catch(e){} return this.state(); },
  async list(){
    if(!dir) return lsGet().map((st, i) => tagFile(st, '#' + i));
    const out = []; await walk(dir, '', out, 0);
    return out.sort((a, b) => String(a.name).localeCompare(String(b.name)));
  },
  fileFor(st){ return slug(st.name) + '.stamp.json'; },
  // Save a piece. `old` = the piece it replaces (keeps its file / subfolder), or null for a new one.
  async save(st, old){
    if(!dir){
      const lib = lsGet(), at = lib.findIndex(x => x.name === (old ? old.name : st.name));
      if(at >= 0) lib[at] = st; else lib.push(st);
      if(!lsSet(lib)) throw new Error('Browser storage is full. Choose a library folder, or use Export File to keep this piece.');
      return '';
    }
    let path = (old && old._file && !old._file.includes('#')) ? old._file : this.fileFor(st);
    if(old && old._file && old.name !== st.name){                 // renamed: new file next to the old one
      const sub = old._file.includes('/') ? old._file.slice(0, old._file.lastIndexOf('/') + 1) : '';
      path = (old._file.includes('#') ? '' : sub) + this.fileFor(st);
    }
    const [d, f] = await resolve(path, true), w = await (await d.getFileHandle(f, { create:true })).createWritable();
    await w.write(JSON.stringify(st, null, 1)); await w.close();
    tagFile(st, path); return path;
  },
  async remove(st){
    if(!dir){ const lib = lsGet(), at = lib.findIndex(x => x.name === st.name); if(at >= 0){ lib.splice(at, 1); lsSet(lib); } return; }
    if(!st._file || st._file.includes('#')) throw new Error('This piece is inside a pack file; delete or edit the pack file itself.');
    const [d, f] = await resolve(st._file); await d.removeEntry(f);
  },
  async fileExists(path){ if(!dir) return false; try{ const [d, f] = await resolve(path); await d.getFileHandle(f); return true; }catch(e){ return false; } },
  browserPieces(){ return lsGet(); },
  // Copy the pieces kept in browser storage into the folder (skips ones whose file already exists).
  async copyBrowserPieces(){
    if(!dir) return { copied:0, skipped:0 };
    let copied = 0, skipped = 0;
    for(const st of lsGet()){ if(await this.fileExists(this.fileFor(st))){ skipped++; continue; } await this.save(st, null); copied++; }
    return { copied, skipped };
  },
};
G.FalldinLibrary = Library;
})(window);
