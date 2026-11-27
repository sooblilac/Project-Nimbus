/* =====================================================================
 * NIMBUS LGU dashboard v2 (public/dashboard.js). Plain browser JS, no build
 * step; Leaflet 1.9.4 is the only library. DOM is built with h() and
 * textContent: user or server strings never go through innerHTML.
 *
 * Facts this file depends on (checked against the code):
 * - POST /api/towns/{code}/updates REPLACES the stored object
 *   ({...body, townCode, updatedAt}). The old dashboard dropped signal, rain,
 *   gusts, pagasa* and issuedAt. When `signal` is missing, reciever.py
 *   build_reply Q falls back to `classes` as the wind signal, so a class
 *   suspension of 2 was texted as "Signal 2". publish() therefore re-reads
 *   the live row and merges (mergeBody): only LGU_KEYS, lguMeta and lguLog
 *   come from this page; every other key passes through untouched.
 * - nimbus_sync.py copies forward every key it does not own, so lguMeta and
 *   lguLog survive syncs. The app and the relay ignore unknown keys.
 * - lgu_api.dart LguUpdate.fromJson throws for the WHOLE update when one row
 *   is invalid (residents then see an error). validate() mirrors its rules.
 * - The relay sends items by position (A1.., S1.., R1..). Q carries only
 *   evacuationCenters[0]. pagasaActive===false makes Q send the fixed "no
 *   storm" text instead of the advisory. The advisory is sent raw (no
 *   clean_notice), so non-ASCII turns a reply into a 70-char Unicode SMS.
 *   encode_pins raises if a label cleans to empty, killing the P reply.
 * - Four towns have a legacy SMS code (0412/1374/0517/0837); both rows are
 *   separate and both are written.
 * - updatedAt is bumped by every POST, including sync runs.
 *
 * Manual test list:
 * - Run the codec port check below in the console.
 * - Publish, then GET /api/towns/{code}/updates: signal/rain/gusts/pagasa* unchanged.
 * - Refresh mid-edit keeps the session and offers "Continue draft".
 * - An admin can find "las pinas" and open Las Pinas City.
 * - Batangas City writes 0401005000 and SMS code 0412.
 * - percentFull 140 and 68.5 are blocked.
 * - 360px wide: no horizontal scroll. Keyboard-only edit -> review -> publish works.
 * - Dark mode contrast holds.
 *
 * Codec: encode()/encodePins() mirror nimbus-v3/nimbus-codec.js for previews only;
 * the K signature is shown as XXXXXXXX because the relay signs with a secret key.
 *  .forEach(([t,c,f,tm,n,want]) => console.assert(NIMBUS.encode(t,c,f,tm,n) === want, want));
 * ===================================================================== */
'use strict';

// ===== §2 CONSTANTS AND STATUS TABLES (single source of wording) =====
const API = /^https?:$/.test(location.protocol) ? location.origin + '/api' : 'https://nimbus-worker.gozocharlyz.workers.dev/api';
const LGU_KEYS = ['classes', 'notice', 'floodAreas', 'evacuationCenters', 'roadStatuses', 'mapPins'];
const LGU_DEFAULTS = { classes: 0, notice: '', floodAreas: [], evacuationCenters: [], roadStatuses: [], mapPins: [] };
const PAGASA_KEYS = ['signal', 'rain', 'gusts', 'pagasaActive', 'pagasaNotice', 'pagasaName', 'pagasaBulletin', 'issuedAt', 'pagasaTitle', 'pagasaAdvice'];
const SEV = { danger: { icon: 'i-error', word: 'Danger' }, warning: { icon: 'i-warn', word: 'Caution' }, ok: { icon: 'i-check', word: 'No alerts' }, neutral: { icon: 'i-dash', word: 'No details' } };
const FLOOD_STATUS = { F: { word: 'Flooding now', sev: 'danger', icon: 'i-waves', detail: '' }, W: { word: 'On watch', sev: 'warning', icon: 'i-warn', detail: 'Water rising nearby' }, C: { word: 'No flooding', sev: 'ok', icon: 'i-check', detail: '' } };
const FLOOD_LEVEL = { H: 'High', M: 'Medium', L: 'Low' };
const EVAC_STATUS = { O: { word: 'Open', sev: 'ok', icon: 'i-home', detail: '' }, F: { word: 'Full', sev: 'danger', icon: 'i-home-full', detail: 'Go to another center' }, X: { word: 'Closed', sev: 'danger', icon: 'i-block', detail: 'Not taking evacuees' } };
const ROAD_STATUS = { O: { word: 'Open', sev: 'ok', icon: 'i-check', detail: 'Open to all vehicles' }, L: { word: 'Light vehicles only', sev: 'warning', icon: 'i-warn', detail: 'Trucks and buses turned back' }, X: { word: 'Closed', sev: 'danger', icon: 'i-block', detail: 'Not passable, use another route' } };
const CLASSES = ['No suspension', 'All levels', 'Preschool to SHS', 'Preschool to grade 10', 'Preschool to grade 6', 'Preschool only'];
const RAIN = ['No rain', 'Light rain', 'Moderate rain', 'Heavy rain', 'Intense rain'];
const PIN_CATS = { flood: { word: 'Flood', glyph: 'i-waves', statuses: ['F', 'W', 'C'], def: 'W' }, evacuation: { word: 'Evacuation center', glyph: 'i-home', statuses: ['O', 'F', 'X'], def: 'O' }, road: { word: 'Road', glyph: 'i-road', statuses: ['O', 'L', 'X'], def: 'X' } };
// Flood pins store flood height in tenths of a metre in "intensity" (0-100 = 0-10 m),
// so the SMS format and validation stay unchanged. Evacuation: % full. Roads: %.
const floodM = (n) => (Number(n) || 0) / 10;
const ftOf = (m) => (m * 3.281).toFixed(1);
const pinAmount = (p) => p.category === 'flood' ? `${floodM(p.intensity).toFixed(1)} m (${ftOf(floodM(p.intensity))} ft)` : p.category === 'evacuation' ? `${p.intensity}% full` : `${p.intensity}%`;
const PIN_WORD = { flood: { F: 'Flooding', W: 'On watch', C: 'Clear' }, road: { X: 'Closed', L: 'Light vehicles only', O: 'Open' }, evacuation: { F: 'Full', X: 'Closed', O: 'Open' } };
const TEMPLATES = ['Pre-emptive evacuation in effect for low-lying barangays.', 'Classes suspended. Stay indoors.', 'Avoid the riverside. Water is rising.', 'Roads reopened. All clear.', 'Lumikas na sa mataas na lugar.', 'Walang pasok ngayong araw.'];
const DEPED_HINT = (s) => (s >= 3 ? 1 : s === 2 ? 2 : s === 1 ? 5 : 0);
const DEPED_WORD = { 1: 'all', 2: 'preschool to senior high school', 5: 'preschool' };
const STALE_MS = 12 * 3600e3, FAR_DEG = 0.3;
const ALIAS_CODES = new Set(['0412', '0517', '0837', '1374', '0401005000', '0501724000', '0831600000', '1380700000']);
const WEATHER = ' Local weather: 28C, rain 0.0mm, wind 12/gust 25 km/h.';
const WEATHER_NOTE = 'Weather text is an example; the relay adds live values.';
const LISTS = {
  floods: { key: 'floodAreas', title: 'Flood areas', noun: 'Area', icon: 'i-waves', table: FLOOD_STATUS, order: ['F', 'W', 'C'], clear: 'C', clearWord: 'No flooding', add: 'Add flood area', ph: 'e.g. Barangay Wawa riverbank', empty: 'No flood areas listed', emptyBody: 'Residents see no flood areas for {town}. Add barangays or streets your LGU monitors.', make: () => ({ name: '', level: 'M', status: 'C' }) },
  evac: { key: 'evacuationCenters', title: 'Evacuation centers', noun: 'Center', icon: 'i-home', table: EVAC_STATUS, order: ['O', 'F', 'X'], clear: 'O', clearWord: 'Open', add: 'Add evacuation center', ph: 'e.g. Central School gym', empty: 'No evacuation centers listed', emptyBody: 'Residents see no evacuation centers for {town}. Add the centers your LGU opens.', make: () => ({ name: '', status: 'O', percentFull: 0 }) },
  roads: { key: 'roadStatuses', title: 'Roads', noun: 'Road', icon: 'i-road', table: ROAD_STATUS, order: ['O', 'L', 'X'], clear: 'O', clearWord: 'Open', add: 'Add road', ph: 'e.g. Riverside road', empty: 'No roads listed', emptyBody: 'Residents see no road status for {town}. Add roads your LGU monitors.', make: () => ({ name: '', status: 'O' }) },
};
const KINDS = ['floods', 'evac', 'roads'];
const SECTIONS = [['overview', 'Overview', 'i-info'], ['pagasa', 'PAGASA', 'i-cloud'], ['classes', 'Classes & advisory', 'i-school'], ['map', 'Map pins', 'i-pin'], ['floods', 'Flood areas', 'i-waves'], ['evac', 'Evacuation', 'i-home'], ['roads', 'Roads', 'i-road'], ['activity', 'Activity', 'i-clock']];

// ===== §3 PURE LOGIC (no DOM) =====
const isObj = (v) => !!v && typeof v === 'object' && !Array.isArray(v);
const clone = (v) => JSON.parse(JSON.stringify(v));
// Copies values as they are (no coercion) so invalid server data stays visible to validate().
function normalize(u) {
  u = isObj(u) ? u : {};
  const L = (k) => (Array.isArray(u[k]) ? u[k] : []), o = (x) => (isObj(x) ? x : {});
  return {
    classes: u.classes === undefined ? 0 : u.classes,
    notice: u.notice === undefined ? '' : u.notice,
    floodAreas: L('floodAreas').map((x) => (x = o(x), { name: x.name, level: x.level, status: x.status })),
    evacuationCenters: L('evacuationCenters').map((x) => (x = o(x), { name: x.name, status: x.status, percentFull: x.percentFull })),
    roadStatuses: L('roadStatuses').map((x) => (x = o(x), { name: x.name, status: x.status })),
    mapPins: L('mapPins').map((x) => (x = o(x), { category: x.category, label: x.label, latitude: x.latitude, longitude: x.longitude, status: x.status, intensity: x.intensity })),
  };
}
const lguEqual = (a, b) => JSON.stringify(normalize(a)) === JSON.stringify(normalize(b));
const hasLgu = (u) => !!u && !lguEqual(u, LGU_DEFAULTS);

let uidN = 0;
const uidBase = Date.now().toString(36);
const uid = () => `r${uidBase}${(++uidN).toString(36)}`;
const strip = (r) => Object.fromEntries(Object.entries(r).filter(([k]) => k[0] !== '_'));
const mkRow = (r, i) => ({ ...r, ...('name' in r ? { name: r.name == null ? '' : String(r.name) } : {}), ...('label' in r ? { label: r.label == null ? '' : String(r.label) } : {}), _id: uid(), _orig: i, _removed: false });
function draftFromLgu(l) {
  return { classes: l.classes, notice: typeof l.notice === 'string' ? l.notice : '', floodAreas: l.floodAreas.map(mkRow), evacuationCenters: l.evacuationCenters.map(mkRow), roadStatuses: l.roadStatuses.map(mkRow), mapPins: l.mapPins.map(mkRow) };
}
// Draft rows mapped onto base positions: rows past the target length become removed rows.
function draftOnto(base, target) {
  const d = { classes: target.classes, notice: typeof target.notice === 'string' ? target.notice : '' };
  for (const k of ['floodAreas', 'evacuationCenters', 'roadStatuses', 'mapPins']) {
    const t = target[k], b = base[k], out = [];
    for (let i = 0; i < Math.max(t.length, b.length); i++) {
      if (i < t.length) out.push({ ...mkRow(t[i], i < b.length ? i : null) });
      else out.push({ ...mkRow(b[i], i), _removed: true });
    }
    d[k] = out;
  }
  return d;
}
const intStr = (v) => (typeof v === 'string' && /^\d{1,3}$/.test(v.trim()) ? Number(v.trim()) : v);
const int0100 = (v) => Number.isInteger(v) && v >= 0 && v <= 100;
function lguFromDraft(d) {
  const keep = (k) => d[k].filter((r) => !r._removed).map(strip);
  const nm = (r) => ({ ...r, name: String(r.name ?? '').trim() });
  return normalize({
    classes: d.classes, notice: d.notice,
    floodAreas: keep('floodAreas').map(nm),
    evacuationCenters: keep('evacuationCenters').map((r) => ({ ...nm(r), percentFull: intStr(r.percentFull) })),
    roadStatuses: keep('roadStatuses').map(nm),
    mapPins: keep('mapPins').map((r) => ({ ...r, label: String(r.label ?? '').trim(), intensity: intStr(r.intensity) })),
  });
}
const evacWord = (e) => (e.status === 'F' ? 'Full' : e.status === 'X' ? 'Closed' : Number(e.percentFull) >= 85 ? 'Almost full' : 'Open');
const evacSev = (e) => (e.status === 'F' || e.status === 'X' ? 'danger' : Number(e.percentFull) >= 85 ? 'warning' : 'ok');
const pinSev = (p) => ((p.category === 'flood' && p.status === 'F') || (p.category === 'road' && p.status === 'X') || (p.category === 'evacuation' && (p.status === 'F' || p.status === 'X')) ? 'danger'
  : (p.category === 'flood' && p.status === 'W') || (p.category === 'road' && p.status === 'L') || (p.category === 'evacuation' && Number(p.intensity) >= 85) ? 'warning' : 'ok');
const pinWord = (p) => PIN_WORD[p.category]?.[p.status] ?? String(p.status);
function rowWord(kind, r) { return kind === 'evac' ? evacWord({ ...r, percentFull: intStr(r.percentFull) }) : LISTS[kind].table[r.status]?.word ?? 'No status'; }
function rowSev(kind, r) { return kind === 'evac' ? evacSev({ ...r, percentFull: intStr(r.percentFull) }) : LISTS[kind].table[r.status]?.sev ?? 'neutral'; }

// Shape rules of LguUpdate.fromJson that the row validator cannot see (wrong types, missing lists).
function shapeProblems(u) {
  if (!isObj(u)) return [];
  const p = [], arr = (k, req) => (req ? Array.isArray(u[k]) : u[k] == null || Array.isArray(u[k]));
  if (!arr('floodAreas', true) || !arr('evacuationCenters', true) || !arr('roadStatuses') || !arr('mapPins')) p.push('A status list is missing.');
  if (typeof u.notice !== 'string') p.push('The advisory is not text.');
  if (!Number.isInteger(u.classes)) p.push('Class status is not a whole number.');
  for (const k of ['floodAreas', 'evacuationCenters', 'roadStatuses']) for (const r of Array.isArray(u[k]) ? u[k] : []) if (!isObj(r) || typeof r.name !== 'string') p.push('A row has no text name.');
  for (const r of Array.isArray(u.mapPins) ? u.mapPins : []) if (!isObj(r) || typeof r.label !== 'string' || typeof r.latitude !== 'number' || typeof r.longitude !== 'number') p.push('A pin has an invalid label or location.');
  return p;
}
function km(a, b, c, d) { const R = 6371, r = Math.PI / 180, x = Math.sin(((c - a) * r) / 2) ** 2 + Math.cos(a * r) * Math.cos(c * r) * Math.sin(((d - b) * r) / 2) ** 2; return 2 * R * Math.asin(Math.sqrt(x)); }
function pinErrors(p) {
  const e = [], lab = String(p.label ?? '').trim();
  if (!lab) e.push('Label needed.');
  else if (!cleanNotice(lab).replace(/\|/g, ' ').trim()) e.push('Use plain letters or numbers so SMS can carry this label.');
  if (!PIN_CATS[p.category] || !PIN_CATS[p.category].statuses.includes(p.status)) e.push('Choose a status for this pin type.');
  if (!int0100(intStr(p.intensity))) e.push(p.category === 'flood' ? 'Use a flood height from 0 to 10 m.' : 'Use a whole number from 0 to 100.');
  const okc = (v, m) => typeof v === 'number' && Number.isFinite(v) && Math.abs(v) <= m;
  if (!okc(p.latitude, 90) || !okc(p.longitude, 180)) e.push('Pick a spot on the map.');
  return e;
}
// Mirrors lgu_api.dart LguUpdate.fromJson. ctx: {town, loc, u (merged update), code (SMS code)}.
function validate(d, ctx) {
  const errors = [], warnings = [];
  const E = (fieldId, section, msg, rowId, always) => errors.push({ fieldId, section, msg, rowId, always });
  if (!Number.isInteger(d.classes) || d.classes < 0 || d.classes > 5) E('cls-0', 'classes', 'Choose a class status.', null, true);
  for (const kind of KINDS) {
    const M = LISTS[kind], rows = d[M.key];
    rows.forEach((r, i) => {
      if (r._removed) return;
      if (!String(r.name ?? '').trim()) E(`f-${r._id}-name`, kind, 'Name needed, or remove this row.', r._id);
      if (kind === 'floods' && !FLOOD_LEVEL[r.level]) E(`f-${r._id}-level-L`, kind, 'Choose a status.', r._id, true);
      if (!M.table[r.status]) E(`f-${r._id}-status-${M.order[0]}`, kind, 'Choose a status.', r._id, true);
      if (kind === 'evac') {
        const v = intStr(r.percentFull);
        if (!int0100(v)) E(`f-${r._id}-pct`, kind, 'Use a whole number from 0 to 100.', r._id, typeof r.percentFull === 'number');
        else if (r.status === 'O' && v === 100) warnings.push({ section: kind, rowId: r._id, msg: `${r.name.trim() || 'A center'} is at 100% but marked Open.`, actions: [{ label: 'Mark Full', run: () => { r.status = 'F'; } }] });
      }
      if (r._orig != null || r._ack) return;
    });
    rows.forEach((r, i) => {
      if (!r._removed || r._orig == null || r._ack) return;
      const k = rows.slice(i + 1).filter((x) => !x._removed).length;
      if (k > 0) warnings.push({ section: kind, rowId: r._id, msg: `Removing "${r.name}" (#${r._orig + 1}) renumbers ${k} item(s) after it. SMS-only residents may see the wrong name.`, actions: [{ label: `Mark ${M.clearWord} instead`, run: () => { r._removed = false; r.status = M.clear; } }, { label: 'Keep removal', run: () => { r._ack = true; } }] });
    });
    const seen = new Set(), dup = new Set();
    for (const r of rows) { if (r._removed) continue; const k = String(r.name ?? '').trim().toLowerCase(); if (!k) continue; if (seen.has(k) && !dup.has(k)) { dup.add(k); warnings.push({ section: kind, msg: `Two rows are named "${r.name.trim()}".` }); } seen.add(k); }
  }
  for (const p of d.mapPins) {
    if (p._removed) continue;
    for (const m of pinErrors(p)) E(`pin-${p._id}`, 'map', m, p._id);
    const lat = ctx.loc?.latitude, lon = ctx.loc?.longitude;
    if (typeof p.latitude === 'number' && lat != null && (Math.abs(p.latitude - lat) > FAR_DEG || Math.abs(p.longitude - lon) > FAR_DEG)) warnings.push({ section: 'map', rowId: p._id, msg: `This pin is about ${Math.round(km(lat, lon, p.latitude, p.longitude))} km from ${ctx.town}. Check the location.` });
  }
  if (/[^\x20-\x7E]/.test(d.notice.replace(/\n/g, ' '))) warnings.push({ section: 'classes', notice: true, msg: 'Some characters (ñ, curly quotes, emoji) make SMS replies Unicode, which fits only 70 characters per text.', actions: [{ label: 'Replace with plain text', run: () => { d.notice = cleanNotice(d.notice.replace(/\s+/g, ' ')); } }] });
  if (d.notice.trim() && ctx.u) {
    const over = buildReplies(ctx.u, ctx.code).filter((r) => r.type !== 'P' && r.len > r.limit).sort((a, b) => b.len - b.limit - (a.len - a.limit))[0];
    if (over) warnings.push({ section: 'classes', notice: true, msg: `Your advisory makes the ${over.label} SMS reply ${over.len - over.limit} characters too long. Phones may split or cut it.` });
  }
  if (ctx.u?.pagasaActive === false && d.notice.trim()) warnings.push({ section: 'classes', notice: true, info: true, msg: 'PAGASA has no active storm, so the SMS overview (Q) sends the PAGASA "no storm" line, not your advisory. Flood, evacuation and road replies still carry it.' });
  const centers = d.evacuationCenters.filter((r) => !r._removed);
  if (centers.length >= 2) warnings.push({ section: 'evac', info: true, msg: `SMS overview reports only the first center (${centers[0].name.trim() || '#1'}).` });
  return { errors, warnings };
}
const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;
function tally(l) {
  const c = (xs, f) => xs.filter(f).length;
  return { flooding: c(l.floodAreas, (a) => a.status === 'F'), watch: c(l.floodAreas, (a) => a.status === 'W'), roadsClosed: c(l.roadStatuses, (r) => r.status === 'X'), roadsLight: c(l.roadStatuses, (r) => r.status === 'L'), evacFull: c(l.evacuationCenters, (e) => e.status === 'F'), evacClosed: c(l.evacuationCenters, (e) => e.status === 'X'), evacAlmost: c(l.evacuationCenters, (e) => e.status !== 'F' && e.status !== 'X' && Number(e.percentFull) >= 85) };
}
// Exact port of home_screen.dart _digest.
function digest(l, town) {
  if (!l) return { sev: 'neutral', headline: `No LGU report for ${town} yet`, counts: [] };
  if (!l.floodAreas.length && !l.evacuationCenters.length && !l.roadStatuses.length && l.classes === 0) return { sev: 'neutral', headline: `${town} LGU report has no area details`, counts: [] };
  const k = tally(l), ec = ['evacuation center', 'evacuation centers'];
  const danger = [k.flooding && `Flooding in ${plural(k.flooding, 'area', 'areas')}`, k.roadsClosed && `${plural(k.roadsClosed, 'road', 'roads')} closed`, k.evacFull && `${plural(k.evacFull, ...ec)} full`, k.evacClosed && `${plural(k.evacClosed, ...ec)} closed`].filter(Boolean);
  const warning = [l.classes > 0 && 'Classes suspended', k.watch && `${plural(k.watch, 'area', 'areas')} on flood watch`, k.roadsLight && `${plural(k.roadsLight, 'road', 'roads')} for light vehicles only`, k.evacAlmost && `${plural(k.evacAlmost, ...ec)} almost full`].filter(Boolean);
  const issues = [...danger, ...warning];
  if (!issues.length) return { sev: 'ok', headline: `No alerts from ${town} LGU`, counts: [] };
  const out = k.evacFull + k.evacClosed;
  const counts = [[k.flooding, 'i-waves', 'danger', `${k.flooding} flooding`, 'floods'], [k.roadsClosed, 'i-block', 'danger', `${plural(k.roadsClosed, 'road', 'roads')} closed`, 'roads'], [out, 'i-home', 'danger', `${plural(out, 'evacuation center', 'evacuation centers')} full or closed`, 'evac'], [k.watch, 'i-waves', 'warning', `${k.watch} on flood watch`, 'floods'], [k.roadsLight, 'i-road', 'warning', `${plural(k.roadsLight, 'road', 'roads')} light vehicles only`, 'roads'], [k.evacAlmost, 'i-home', 'warning', `${plural(k.evacAlmost, 'evacuation center', 'evacuation centers')} almost full`, 'evac'], [l.classes > 0 ? 1 : 0, 'i-school', 'warning', 'classes suspended', 'classes']]
    .filter((c) => c[0] > 0).map(([n, icon, sev, label, sec]) => ({ icon, count: sec === 'classes' ? '' : String(n), sev, label, sec }));
  return { sev: danger.length ? 'danger' : 'warning', headline: issues.slice(0, 2).join(' · '), counts };
}
function sectionSummary(kind, rows) {
  if (!rows.length) return 'None listed';
  const n = (f) => rows.filter(f).length, join = (a) => a.filter(([c]) => c).map(([c, w]) => `${c} ${w}`).join(' · ');
  if (kind === 'floods') { const f = n((r) => r.status === 'F'), w = n((r) => r.status === 'W'); return f || w ? join([[f, 'flooding'], [w, 'on watch'], [rows.length - f - w, 'clear']]) : 'All clear'; }
  if (kind === 'roads') { const x = n((r) => r.status === 'X'), l = n((r) => r.status === 'L'); return x || l ? join([[x, 'closed'], [l, 'light vehicles only'], [rows.length - x - l, 'open']]) : 'All open'; }
  const f = n((r) => r.status === 'F'), x = n((r) => r.status === 'X'), a = n((r) => r.status !== 'F' && r.status !== 'X' && Number(r.percentFull) >= 85);
  return f || x || a ? join([[f, 'full'], [x, 'closed'], [a, 'almost full'], [rows.length - f - x - a, 'open']]) : 'All open';
}
const RANK = { floods: (r) => ({ F: 0, W: 1 })[r.status] ?? 2, roads: (r) => ({ X: 0, L: 1 })[r.status] ?? 2, evac: (r) => (r.status === 'F' || r.status === 'X' ? 0 : Number(r.percentFull) >= 85 ? 1 : 2) };
const previewSort = (kind, rows) => rows.map((r, i) => [r, i]).sort((a, b) => RANK[kind](a[0]) - RANK[kind](b[0]) || a[1] - b[1]).map((x) => x[0]);

// Codec: line-for-line port of nimbus_codec.py / nimbus-codec.js.
// The relay signs replies with HMAC-SHA256 (8 hex digits) using a key this page never sees,
// so previews show a same-length placeholder; lengths and part counts stay exact.
function signature() { return 'XXXXXXXX'; }
function cleanNotice(t) { return String(t ?? '').replace(/[‘’]/g, "'").replace(/[“”]/g, '"').replace(/[–—]/g, '-').replace(/[^\x20-\x7E]/g, '').replace(/\s+/g, ' ').trim(); }
function encode(type, code, fields, time, notice) { let b = ['NB1', type, code, ...fields, 'T' + time].join(' '); if (notice) b += ' /' + notice; return b + ' K' + signature(b); }
const coord = (v) => Math.sign(v) * Math.round(Math.abs(v) * 1e5);
function encodePins(code, pins, time) {
  const f = pins.map((p) => { const label = cleanNotice(p.label).replace(/\|/g, ' ').replace(/\s+/g, '_'); if (!label) throw new Error('Map pin labels cannot be empty'); return [{ flood: 'F', evacuation: 'E', road: 'R' }[p.category], p.status, p.intensity, coord(p.latitude), coord(p.longitude), label].join('|'); });
  const b = ['NB1', 'P', code, ...f, 'T' + time].join('~');
  return b + '~K' + signature(b);
}
const hhmm = () => { const d = new Date(); return String(d.getHours()).padStart(2, '0') + String(d.getMinutes()).padStart(2, '0'); };
const toInt = (v) => Math.trunc(Number(v) || 0);
// Mirrors reciever.py build_reply for the merged update u.
function buildReplies(u, code) {
  const t = hhmm(), alias = ALIAS_CODES.has(code), out = [], ev = Array.isArray(u.evacuationCenters) ? u.evacuationCenters : [];
  const notice = typeof u.notice === 'string' ? u.notice : String(u.notice ?? '');
  const add = (type, label, sms, decoded, notes = []) => { const uni = /[^\x20-\x7E]/.test(sms), limit = uni ? 70 : 160, len = sms.length; out.push({ type, label, sms, decoded, notes, len, limit, unicode: uni, parts: len <= limit ? 1 : Math.ceil(len / (uni ? 67 : 153)) }); };
  if (u.pagasaActive === false) add('Q', 'Overview', encode('Q', code, ['W0', 'R0', 'G0', 'C0'], t, 'No current storm update administered by PAGASA.' + (alias ? WEATHER : '')), 'No active PAGASA storm. Your advisory is not sent here.', alias ? [WEATHER_NOTE] : []);
  else {
    const sig = u.signal !== undefined ? u.signal : u.classes, f = [`W${toInt(sig)}`, `R${toInt(u.rain)}`, `G${toInt(u.gusts)}`];
    if (ev.length) f.push(`E1${ev[0].status || 'O'}`);
    f.push(`C${toInt(u.classes)}`);
    add('Q', 'Overview', encode('Q', code, f, t, String(notice || u.pagasaNotice || 'PAGASA weather update') + (alias ? WEATHER : '')),
      [toInt(sig) ? `Signal ${toInt(sig)}` : 'No signal', RAIN[Math.max(0, Math.min(4, toInt(u.rain)))], `Gusts ${toInt(u.gusts)} km/h`, ev.length && `Center 1 ${evacWord(ev[0])}`, `Classes: ${CLASSES[toInt(u.classes)] ?? u.classes}`].filter(Boolean).join(' · '), alias ? [WEATHER_NOTE] : []);
  }
  const L = (k) => (Array.isArray(u[k]) ? u[k] : []);
  const fa = L('floodAreas'), rs = L('roadStatuses');
  add('F', 'Floods', encode('F', code, fa.length ? fa.map((a, i) => `A${i + 1}${a.level || 'L'}${a.status || 'C'}`) : ['A1LC'], t, notice), fa.length ? fa.map((a, i) => `#${i + 1} ${FLOOD_STATUS[a.status]?.word ?? a.status} (${FLOOD_LEVEL[a.level] ?? a.level})`).join(' · ') : 'None listed (placeholder A1LC)');
  add('E', 'Evacuation', encode('E', code, ev.length ? ev.map((e, i) => `S${i + 1}${e.status || 'O'}${toInt(e.percentFull)}`) : ['S1O0'], t, notice), ev.length ? ev.map((e, i) => `#${i + 1} ${evacWord(e)} ${toInt(e.percentFull)}%`).join(' · ') : 'None listed (placeholder S1O0)');
  add('R', 'Roads', encode('R', code, rs.length ? rs.map((r, i) => `R${i + 1}${r.status || 'O'}`) : ['R1O'], t, notice), rs.length ? rs.map((r, i) => `#${i + 1} ${ROAD_STATUS[r.status]?.word ?? r.status}`).join(' · ') : 'None listed (placeholder R1O)');
  const pins = L('mapPins');
  try { add('P', 'Map pins', encodePins(code, pins, t), pins.length ? pins.map((p) => `${p.label} (${pinWord(p)}${p.category === 'evacuation' ? '' : ' ' + pinAmount(p)})`).join(' · ') : 'No pins', ['Pin replies use ~ separators so phones can rejoin split texts.']); }
  catch { add('P', 'Map pins', '(nothing: a pin label has no plain letters)', 'The relay cannot build this reply. Fix the pin label.'); }
  return out;
}
function wordDiff(a, b) {
  const A = a.split(/(\s+)/).filter(Boolean), B = b.split(/(\s+)/).filter(Boolean);
  if (A.length > 400 || B.length > 400) return null;
  const m = A.length, n = B.length, T = Array.from({ length: m + 1 }, () => new Uint16Array(n + 1));
  for (let i = m - 1; i >= 0; i--) for (let j = n - 1; j >= 0; j--) T[i][j] = A[i] === B[j] ? T[i + 1][j + 1] + 1 : Math.max(T[i + 1][j], T[i][j + 1]);
  const out = []; let i = 0, j = 0;
  while (i < m && j < n) { if (A[i] === B[j]) { out.push(['=', A[i]]); i++; j++; } else if (T[i + 1][j] >= T[i][j + 1]) out.push(['-', A[i++]]); else out.push(['+', B[j++]]); }
  while (i < m) out.push(['-', A[i++]]); while (j < n) out.push(['+', B[j++]]);
  return out;
}
// Field changes for one row against its base row: [{text, was, from, to}].
function rowChanges(kind, o, r) {
  const out = [], nm = String(r.name ?? '').trim() || o.name;
  if (String(o.name ?? '') !== String(r.name ?? '').trim()) out.push({ text: `Name: "${o.name}" → "${String(r.name).trim()}" (SMS-only phones keep the old name)`, was: `"${o.name}"` });
  const ow = rowWord(kind, o), nw = rowWord(kind, r);
  if (o.status !== r.status) out.push({ text: `${nm}: ${ow} → ${nw}`, was: ow, name: nm, from: [ow, rowSev(kind, o)], to: [nw, rowSev(kind, r)] });
  if (kind === 'floods' && o.level !== r.level) out.push({ text: `${nm}: risk ${FLOOD_LEVEL[o.level] ?? o.level} → ${FLOOD_LEVEL[r.level] ?? r.level}`, was: `risk ${FLOOD_LEVEL[o.level] ?? o.level}` });
  if (kind === 'evac' && intStr(o.percentFull) !== intStr(r.percentFull)) out.push({ text: `${nm}: ${o.percentFull}% → ${r.percentFull}%${o.status === r.status && ow !== nw ? ` (${nw})` : ''}`, was: `${o.percentFull}%` });
  return out;
}
function pinChanges(o, p) {
  const out = [], lab = String(p.label).trim() || o.label;
  if (String(o.label) !== String(p.label).trim()) out.push({ text: `Pin label: "${o.label}" → "${String(p.label).trim()}"`, was: `"${o.label}"` });
  if (o.category !== p.category || o.status !== p.status) out.push({ text: `Pin ${lab}: ${pinWord(o)} → ${pinWord(p)}`, was: pinWord(o), name: `Pin ${lab}`, from: [pinWord(o), pinSev(o)], to: [pinWord(p), pinSev(p)] });
  if (intStr(o.intensity) !== intStr(p.intensity)) out.push({ text: `Pin ${lab}: ${pinAmount(o)} → ${pinAmount(p)}`, was: pinAmount(o) });
  if (Math.abs(o.latitude - p.latitude) > 1e-6 || Math.abs(o.longitude - p.longitude) > 1e-6) out.push({ text: `Pin ${lab}: moved`, was: 'old spot' });
  return out;
}
function diff(base, d, town) {
  const lines = [], L = (section, kind, text, extra) => lines.push({ section, kind, text, ...extra });
  if (base.classes !== d.classes) L('classes', 'changed', `Classes: ${CLASSES[base.classes] ?? base.classes} → ${CLASSES[d.classes] ?? d.classes}`);
  if (base.notice !== d.notice) L('classes', 'changed', 'Advisory edited', { words: wordDiff(String(base.notice ?? ''), d.notice), old: String(base.notice ?? ''), now: d.notice });
  for (const kind of [...KINDS, 'map']) {
    const key = kind === 'map' ? 'mapPins' : LISTS[kind].key, b = base[key], seen = new Set();
    const name = (r) => (kind === 'map' ? `pin ${String(r.label ?? '').trim()}` : String(r.name ?? '').trim() || '(no name)');
    for (const r of d[key]) {
      if (r._orig == null) { if (!r._removed) L(kind, 'added', kind === 'map' ? `Added: pin ${String(r.label).trim()} (${pinWord(r)})` : `Added: ${name(r)} (${rowWord(kind, r)}${kind === 'floods' ? ', ' + (FLOOD_LEVEL[r.level] ?? r.level) : ''})`); continue; }
      const o = b[r._orig]; if (!o) continue; seen.add(r._orig);
      if (r._removed) { L(kind, 'removed', `Removed: ${kind === 'map' ? 'pin ' + o.label : o.name} (#${r._orig + 1})`); continue; }
      for (const c of kind === 'map' ? pinChanges(o, r) : rowChanges(kind, o, r)) L(kind, 'changed', c.text, c);
    }
    b.forEach((o, i) => { if (!seen.has(i)) L(kind, 'removed', `Removed: ${kind === 'map' ? 'pin ' + o.label : o.name} (#${i + 1})`); });
  }
  const h0 = digest(normalize(base), town).headline, h1 = digest(lguFromDraft(d), town).headline;
  if (lines.length && h0 !== h1) L('overview', 'info', `Headline: "${h0}" → "${h1}"`);
  return { lines, count: lines.filter((l) => l.kind !== 'info').length };
}
function mergeBody(fresh, lgu, meta) {
  const prev = isObj(fresh?.update) ? fresh.update : {}, rest = { ...prev };
  delete rest.townCode; delete rest.updatedAt;
  return { ...LGU_DEFAULTS, ...rest, ...lgu, lguMeta: meta, lguLog: [meta, ...(Array.isArray(prev.lguLog) ? prev.lguLog : [])].slice(0, 10) };
}

// ===== §4 STORAGE (every access wrapped; null on failure) =====
const area = (a) => (a === 'session' ? sessionStorage : localStorage);
const store = {
  get(k, a) { try { const v = area(a).getItem(k); return v == null ? null : JSON.parse(v); } catch { return null; } },
  set(k, v, a) { try { area(a).setItem(k, JSON.stringify(v)); return true; } catch { return false; } },
  del(k, a) { try { area(a).removeItem(k); } catch { /* ignore */ } },
  keys(prefix, a) { try { return Object.keys(area(a)).filter((k) => k.startsWith(prefix)); } catch { return []; } },
};
const uiPrefs = () => store.get('nimbus.ui') || {};
const setPref = (k, v) => store.set('nimbus.ui', { ...uiPrefs(), [k]: v });
const draftKey = (code) => `nimbus.draft.${S.session.username}.${code}`;
const historyOf = (code) => store.get(`nimbus.history.${code}`) || [];
const addHistory = (code, entry) => store.set(`nimbus.history.${code}`, [entry, ...historyOf(code)].slice(0, 30));
function pushRecent(code) { const k = `nimbus.recent.${S.session.username}`; store.set(k, [code, ...(store.get(k) || []).filter((c) => c !== code)].slice(0, 5)); }

// ===== §5 API AND SESSION =====
const S = { session: null, loc: { byCode: new Map(), list: [] }, banners: new Map(), ui: { readOnly: false, storageFailed: false, offlineFailed: false }, board: { data: null, filter: null, sort: 'severity', at: 0 }, pagasa: null, nav: 0 };
let ed = null;
const isAdmin = () => !!S.session?.townCodes.includes('*');
const canWrite = (code) => isAdmin() || !!S.session?.townCodes.includes(code);
function myTowns() {
  const out = [], seen = new Set();
  for (const c of S.session.townCodes) { if (c === '*') continue; const e = S.loc.byCode.get(c) || { code: c, name: 'Town ' + c, province: '', region: '', legacyCode: null }; if (!seen.has(e.code)) { seen.add(e.code); out.push(e); } }
  return out;
}
async function api(method, path, body, opts = {}) {
  const ctrl = new AbortController(), timer = setTimeout(() => ctrl.abort(), 15000);
  const headers = { 'Content-Type': 'application/json' };
  const token = opts.bearer || (opts.auth && S.session?.accessToken);
  if (token) headers.Authorization = 'Bearer ' + token;
  let res;
  try { res = await fetch(API + path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body), signal: ctrl.signal, cache: 'no-store' }); }
  catch { throw { kind: 'offline' }; } finally { clearTimeout(timer); }
  let data = null; try { data = await res.json(); } catch { /* not JSON */ }
  if (res.ok) return { ok: true, status: res.status, data };
  if (res.status === 401 && opts.auth && !opts.retried) { await reauth(false); return api(method, path, body, { ...opts, retried: true }); }
  if (res.status === 403) throw { kind: 'forbidden', status: 403, msg: `This account can't publish for ${opts.town || 'this town'}. Contact your NIMBUS admin.` };
  throw { kind: 'server', status: res.status, msg: data?.error || `Server error (${res.status}).` };
}
const errText = (e) => (e?.kind === 'offline' ? "Can't reach NIMBUS. Check your connection." : e?.msg || String(e?.message || e));
async function getTown(code) { const r = await api('GET', `/towns/${encodeURIComponent(code)}/updates`); return { update: isObj(r.data?.update) ? r.data.update : null, updatedAt: r.data?.updatedAt ?? null }; }
async function signIn(username, password, persist) {
  const r = await api('POST', '/auth/login', { username, password });
  const s = { accessToken: r.data.accessToken, username: r.data.username, townCodes: r.data.townCodes || [], expiresAt: r.data.expiresAt, persist: !!persist };
  saveSession(s); return s;
}
function saveSession(s) { S.session = s; store.set('nimbus.session', s, s.persist ? 'local' : 'session'); store.del('nimbus.session', s.persist ? 'session' : 'local'); S.ui.readOnly = false; }
const readSession = () => { const s = store.get('nimbus.session', 'session') || store.get('nimbus.session', 'local'); return s && s.accessToken && Array.isArray(s.townCodes) ? s : null; };
const expMs = () => Date.parse(S.session?.expiresAt) || 0;
function defaultRoute() { const t = myTowns(); return isAdmin() || t.length !== 1 ? '#/board' : '#/town/' + t[0].code; }
function tickSession() {
  if (!S.session) return;
  const left = expMs() - Date.now();
  if (left <= 0) { S.ui.readOnly = true; setBanner('session', { sev: 'warning', text: 'Session ended. Sign in to publish. Your changes are kept on this device.', actions: [{ label: 'Sign in again', run: () => reauth(true).catch(() => {}) }] }); }
  else if (left <= 15 * 60e3) setBanner('session', { sev: 'warning', text: `Your session ends at ${clock(expMs())}.`, actions: [{ label: 'Sign in again', run: () => reauth(true).catch(() => {}) }] });
  else clearBanner('session');
  renderTopbar(); if (ed) renderBar();
}
async function signOut() {
  if (ed?.d?.dirty) {
    const c = await leaveDialog();
    if (c === 'review') return openReview('edit');
    if (c !== 'keep' && c !== 'discard') return;
    if (c === 'discard') { store.del(draftKey(ed.primary)); ed.discarded = true; }
    else saveDraftNow();
  }
  const s = S.session;
  api('POST', '/auth/logout', undefined, { bearer: s.accessToken }).catch(() => {});
  store.del('nimbus.session', 'local'); store.del('nimbus.session', 'session');
  if (!s.persist) for (const k of store.keys(`nimbus.draft.${s.username}.`)) store.del(k);
  S.session = null; ed = null; S.banners.clear(); stopBoardTimer();
  location.hash = '#/login'; showLogin({ username: s.username });
}

// ===== §6 ROUTER =====
function parseHash() { const p = location.hash.replace(/^#\/?/, '').split('/').filter(Boolean).map(decodeURIComponent); return { view: p[0] || '', code: p[1] || '', section: p[2] || '' }; }
let lastHash = '';
async function route() {
  const r = parseHash();
  if (!S.session || expMs() <= Date.now()) { if (r.view !== 'login' && S.session) return showLogin({ username: S.session.username, expired: true }); return showLogin(); }
  if (r.view === 'town' && ed && ed.code === r.code && $('sec-overview')) { lastHash = location.hash; return scrollToSec(r.section || 'overview'); }
  if (ed && ed.d?.dirty && !(r.view === 'town' && r.code === ed.code)) {
    if (S.ui.storageFailed) {
      const go = await confirmDlg({ title: 'Leave without publishing?', body: `Drafts can't be saved on this device. Your ${plural(ed.d.diff.count, 'change', 'changes')} for ${ed.loc.name} will be lost.`, ok: 'Discard and continue', cancel: 'Stay', danger: true });
      if (!go) { history.replaceState(null, '', lastHash); return; }
    } else { saveDraftNow(); toast(`Draft for ${ed.loc.name} kept on this device.`, { sev: 'info' }); }
  }
  lastHash = location.hash;
  if (r.view === 'town' && r.code) return openTown(r.code, r.section);
  if (r.view === 'board') return showBoard();
  location.replace(defaultRoute());
}

// ===== §7 RENDER HELPERS =====
const $ = (id) => document.getElementById(id);
const NS = 'http://www.w3.org/2000/svg', PROPS = new Set(['value', 'checked', 'disabled', 'selected', 'open', 'readOnly', 'required']);
// replaceChildren() would turn null/false into the text "null"/"false" and arrays into
// "[object …]". Make it accept the same children as h(): nested arrays, with empty values skipped.
{
  const native = Element.prototype.replaceChildren;
  Element.prototype.replaceChildren = function (...kids) {
    return native.apply(this, kids.flat(Infinity).filter((c) => c != null && c !== false && c !== ''));
  };
}
function h(tag, attrs, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v; else if (k === 'text') el.textContent = v;
    else if (k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2), v);
    else if (PROPS.has(k)) el[k] = v; else el.setAttribute(k, v === true ? '' : v);
  }
  for (const c of kids.flat(Infinity)) if (c != null && c !== false && c !== '') el.append(c instanceof Node ? c : String(c));
  return el;
}
function icon(name, cls = 'i') { const s = document.createElementNS(NS, 'svg'), u = document.createElementNS(NS, 'use'); s.setAttribute('class', cls); s.setAttribute('aria-hidden', 'true'); u.setAttribute('href', '#' + name); s.append(u); return s; }
const badge = (sev, text, ic) => h('span', { class: 'badge ' + sev }, icon(ic || SEV[sev]?.icon || 'i-info', 'i i-xs'), text);
const btn = (label, cls, onclick, attrs = {}) => h('button', { type: 'button', class: 'btn ' + cls, onclick, ...attrs }, attrs.ic && icon(attrs.ic), label);
const iconBtn = (ic, label, onclick, attrs = {}) => h('button', { type: 'button', class: 'icon-btn', 'aria-label': label, title: label, onclick, ...attrs }, icon(ic));
const sevIcon = (sev, cls) => icon(SEV[sev]?.icon || 'i-dash', cls);
const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const clock = (t) => new Date(t).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' });
function whenText(t) { if (!t) return 'unknown'; const d = new Date(t); if (isNaN(d)) return String(t); return d.toDateString() === new Date().toDateString() ? clock(d) : `${d.getDate()} ${MON[d.getMonth()]}, ${clock(d)}`; }
function relText(t) { const ms = Date.now() - new Date(t).getTime(); if (isNaN(ms)) return 'unknown'; if (ms < 60e3) return 'just now'; if (ms < 3600e3) return `${Math.floor(ms / 60e3)} min ago`; if (ms < 86400e3) return `${Math.floor(ms / 3600e3)}h ago`; return `${Math.floor(ms / 86400e3)}d ago`; }
const isStale = (t) => !!t && Date.now() - new Date(t).getTime() > STALE_MS;
const fold = (s) => String(s).toLowerCase().normalize('NFD').replace(/\p{M}/gu, '');
const reduced = () => matchMedia('(prefers-reduced-motion: reduce)').matches;
const debounce = (fn, ms) => { let t; return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); }; };
function seg({ name, legend, options, value, onChange, idp, cls = '', disabled }) {
  return h('fieldset', { class: 'seg ' + cls, disabled }, h('legend', { class: 'sr-only' }, legend),
    options.map((o) => [h('input', { type: 'radio', class: 'sr-only', id: `${idp}-${o.value}`, name, value: o.value, checked: o.value === value, onchange: () => onChange(o.value) }),
      h('label', { for: `${idp}-${o.value}`, 'data-sev': o.sev || 'neutral' }, icon(o.value === value ? 'i-check' : o.icon || 'i-dash', 'i i-sm'), o.word)]));
}
const empty = (ic, title, body, action) => h('div', { class: 'empty' }, h('div', { class: 'empty-ic' }, icon(ic, 'i i-lg')), h('p', { class: 'empty-title' }, title), body && h('p', { class: 'empty-body' }, body), action);
const cardHead = (ic, title, summary, actions, sumId) => h('div', { class: 'card-head' }, h('div', { class: 'card-title' }, h('span', { class: 'tile' }, icon(ic)), h('div', null, h('h2', null, title), summary != null && h('p', { class: 'summary', id: sumId }, summary))), actions && h('div', { class: 'card-actions' }, actions));
// Popover menu (role=menu): arrow keys, Home/End, Esc, Tab and outside click close it.
let menuEl = null;
function closeMenu(focusBtn) { if (!menuEl) return; const b = menuEl._btn; menuEl.remove(); menuEl = null; b?.setAttribute('aria-expanded', 'false'); if (focusBtn) b?.focus(); }
function openMenu(btnEl, items) {
  if (menuEl?._btn === btnEl) return closeMenu(true);
  closeMenu();
  const ul = h('ul', { class: 'menu', role: 'menu' }, items.map((it) => h('li', { role: 'none' }, h('button', { type: 'button', role: 'menuitem', tabindex: '-1', class: it.danger ? 'danger' : '', onclick: () => { closeMenu(true); it.run(); } }, it.label))));
  ul._btn = btnEl; menuEl = ul; document.body.append(ul); btnEl.setAttribute('aria-expanded', 'true');
  const r = btnEl.getBoundingClientRect();
  ul.style.top = r.bottom + scrollY + 4 + 'px'; ul.style.left = Math.max(8, Math.min(r.right + scrollX - ul.offsetWidth, scrollX + innerWidth - ul.offsetWidth - 8)) + 'px';
  const btns = [...ul.querySelectorAll('button')]; btns[0]?.focus();
  ul.addEventListener('keydown', (e) => {
    const i = btns.indexOf(document.activeElement);
    if (e.key === 'ArrowDown') { e.preventDefault(); btns[(i + 1) % btns.length].focus(); } else if (e.key === 'ArrowUp') { e.preventDefault(); btns[(i - 1 + btns.length) % btns.length].focus(); }
    else if (e.key === 'Home') { e.preventDefault(); btns[0].focus(); } else if (e.key === 'End') { e.preventDefault(); btns.at(-1).focus(); }
    else if (e.key === 'Escape') { e.preventDefault(); closeMenu(true); } else if (e.key === 'Tab') closeMenu();
  });
}
document.addEventListener('pointerdown', (e) => { if (menuEl && !menuEl.contains(e.target) && !menuEl._btn.contains(e.target)) closeMenu(); });
const menuBtn = (label, id, items, text) => h('button', { type: 'button', class: text ? 'btn btn-tertiary btn-sm' : 'icon-btn', id, 'aria-label': label, 'aria-haspopup': 'menu', 'aria-expanded': 'false', onclick: (e) => openMenu(e.currentTarget, items()) }, text ? [text, icon('i-chevron', 'i i-sm')] : icon('i-more'));
// Banners never auto-hide. Keys starting with 'ed:' belong to the open town.
function setBanner(key, b) { S.banners.set(key, b); renderBanners(); }
function clearBanner(key) { if (S.banners.delete(key)) renderBanners(); }
function renderBanners() {
  const host = $('banners'); if (!host) return;
  host.replaceChildren(...[...S.banners.values()].map((b) => h('div', { class: 'banner ' + b.sev, role: b.sev === 'danger' ? 'alert' : null }, icon(b.sev === 'neutral' ? 'i-info' : SEV[b.sev].icon), h('p', null, b.text), b.actions && h('div', { class: 'banner-actions' }, b.actions.map((a) => btn(a.label, 'btn-secondary btn-sm', a.run))))));
}
function toast(text, { sev = 'ok', action, ms } = {}) {
  const el = h('div', { class: 'toast ' + sev, role: sev === 'danger' ? 'alert' : null }, icon(SEV[sev]?.icon || 'i-info'), h('p', null, text),
    action && btn(action.label, 'btn-tertiary btn-sm', () => { action.run(); done(); }), iconBtn('i-close', 'Dismiss', () => done()));
  let left = ms ?? (sev === 'danger' ? 0 : action ? 30000 : sev === 'info' ? 5000 : 6000), t0 = Date.now(), timer = null;
  const done = () => { clearTimeout(timer); el.remove(); };
  const run = () => { if (left) { t0 = Date.now(); timer = setTimeout(done, left); } };
  const pause = () => { clearTimeout(timer); left = Math.max(1000, left - (Date.now() - t0)); };
  if (left) { el.addEventListener('mouseenter', pause); el.addEventListener('focusin', pause); el.addEventListener('mouseleave', run); el.addEventListener('focusout', run); }
  $('toasts').append(el); run();
  return el;
}
function setBusy(b, label) {
  if (label) { b.style.minWidth = b.offsetWidth + 'px'; b._label = [...b.childNodes]; b.replaceChildren(h('span', { class: 'spinner', 'aria-hidden': 'true' }), label); b.disabled = true; b.setAttribute('aria-busy', 'true'); }
  else { if (b._label) b.replaceChildren(...b._label); b.disabled = false; b.removeAttribute('aria-busy'); b.style.minWidth = ''; }
}
// Re-render scheduling: never swap DOM between pointerdown and click, or the click is lost.
let ptrDown = false; const pendingSecs = new Set();
addEventListener('pointerdown', () => { ptrDown = true; }, true);
for (const ev of ['pointerup', 'pointercancel']) addEventListener(ev, () => setTimeout(() => { ptrDown = false; flushSecs(); }, 0), true);
function rerenderSoon(sec) { pendingSecs.add(sec); if (!ptrDown) setTimeout(flushSecs, 0); }
function flushSecs() { if (ptrDown || !pendingSecs.size) return; const s = [...pendingSecs]; pendingSecs.clear(); update(s); }

// ===== §8 VIEWS =====
// --- Login ---
function showLogin({ username, expired } = {}) {
  ed = null; stopBoardTimer(); $('app').hidden = true; $('login-view').hidden = false; document.title = 'Sign in · NIMBUS LGU';
  if (username) $('lg-user').value = username;
  const note = $('login-note');
  note.hidden = !expired; if (expired) note.querySelector('p').textContent = `Your session ended at ${clock(expMs())}. Sign in again; unpublished changes on this device are kept.`;
  $('login-error').hidden = true;
  (username ? $('lg-pass') : $('lg-user')).focus();
}
function wireLogin() {
  const pass = $('lg-pass'), show = $('lg-show');
  show.onclick = () => { const on = pass.type === 'password'; pass.type = on ? 'text' : 'password'; show.setAttribute('aria-pressed', String(on)); show.textContent = on ? 'Hide' : 'Show'; };
  const caps = (e) => { $('lg-caps').hidden = !(e.getModifierState && e.getModifierState('CapsLock')); };
  pass.addEventListener('keyup', caps); pass.addEventListener('keydown', caps);
  $('login-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const b = $('lg-submit'), err = $('login-error'), u = $('lg-user').value.trim();
    if (!u || !pass.value) { err.hidden = false; err.querySelector('p').textContent = 'Enter your username and password.'; return; }
    err.hidden = true; setBusy(b, 'Signing in…');
    try {
      await signIn(u, pass.value, $('lg-keep').checked); pass.value = '';
      $('login-view').hidden = true; $('app').hidden = false; clearBanner('session');
      const r = parseHash(); if (r.view === 'town' || r.view === 'board') route(); else location.hash = defaultRoute();
    } catch (x) { err.hidden = false; err.querySelector('p').textContent = x.status === 401 ? 'Username or password is incorrect.' : errText(x); }
    finally { setBusy(b); }
  });
}
// --- Top bar ---
function setMode(mode) { $('login-view').hidden = true; $('app').hidden = false; $('app').className = 'app is-' + mode; $('rail').hidden = mode !== 'editor'; $('preview-rail').hidden = mode !== 'editor'; $('publish-bar').hidden = mode !== 'editor'; }
function renderTopbar() {
  const s = S.session; if (!s) return;
  const multi = isAdmin() || myTowns().length > 1, left = expMs() - Date.now(), late = left <= 15 * 60e3;
  const sessText = left > 0 ? `Signed in as ${s.username} · until ${clock(expMs())}` : `Session ended · ${s.username}`;
  $('topbar').replaceChildren(
    h('a', { class: 'brand', href: multi ? '#/board' : defaultRoute(), 'aria-label': 'NIMBUS LGU home' }, h('span', { class: 'brand-mark' }, icon('i-cloud')), h('span', { class: 'brand-name' }, 'NIMBUS'), h('span', { class: 'pill-lgu' }, 'LGU')),
    ed && multi && h('a', { class: 'switcher', href: '#/board', title: 'Choose another town' }, icon('i-pin', 'i i-sm'), h('span', { class: 'ellipsis' }, [ed.loc.name, ed.loc.province].filter(Boolean).join(', ')), icon('i-chevron', 'i i-sm')),
    ed && multi && h('a', { class: 'btn btn-tertiary btn-sm hide-phone', href: '#/board' }, 'All towns'),
    h('div', { class: 'top-right' },
      h('span', { class: 'pill conn ' + (navigator.onLine ? 'on' : 'off'), role: 'status' }, h('span', { class: 'dot' }), navigator.onLine ? 'Online' : 'Offline · draft kept on this device'),
      h('span', { class: 'pill sess hide-phone' + (late ? ' late' : '') }, late && icon('i-clock', 'i i-sm'), sessText),
      ed && btn('Preview', 'btn-secondary btn-sm preview-btn', openPreviewSheet, { ic: 'i-info' }),
      menuBtn('Account', 'acct-btn', () => [{ label: sessText, run: () => {} }, { label: 'Sign out', run: signOut }], h('span', { class: 'ellipsis acct-name' }, s.username))));
}
// --- Board ---
let boardTimer = null;
function stopBoardTimer() { clearInterval(boardTimer); boardTimer = null; }
async function showBoard() {
  ed = null; [...S.banners.keys()].filter((k) => k.startsWith('ed:')).forEach((k) => S.banners.delete(k));
  setMode('board'); renderTopbar(); document.title = (isAdmin() ? 'All towns' : 'Your towns') + ' · NIMBUS LGU';
  const admin = isAdmin();
  $('view').replaceChildren(h('div', { class: 'board' },
    h('div', { class: 'board-head' }, h('div', null, h('h1', null, admin ? 'All towns' : 'Your towns'), h('p', { class: 'sub' }, 'What residents see right now.'), h('p', { class: 'pagasa-strip', id: 'pagasa-strip' }, icon('i-cloud', 'i i-sm'), 'PAGASA: loading…')),
      h('div', { class: 'board-tools' }, h('span', { class: 'muted', id: 'refreshed' }), iconBtn('i-undo', 'Refresh', () => refreshBoard()), btn('Export CSV', 'btn-secondary btn-sm', exportCsv, { ic: 'i-download' }))),
    admin && searchBox(), h('div', { id: 'board-body' }, skeleton(3))));
  renderBanners(); $('main').focus({ preventScroll: true });
  await refreshBoard();
  stopBoardTimer(); boardTimer = setInterval(() => { if (document.visibilityState === 'visible' && parseHash().view === 'board') refreshBoard(); }, 120000);
}
async function refreshBoard() {
  try {
    const [t, p] = await Promise.all([api('GET', '/towns'), api('GET', '/pagasa').catch(() => null)]);
    S.board.data = t.data?.towns || []; S.board.at = Date.now(); if (p) S.pagasa = p.data; clearBanner('board');
  } catch (e) { setBanner('board', { sev: 'danger', text: errText(e), actions: [{ label: 'Try again', run: refreshBoard }] }); }
  if (parseHash().view === 'board') renderBoard();
}
function boardRows() {
  const data = new Map((S.board.data || []).map((t) => [t.townCode, t])), admin = isAdmin(), user = S.session.username;
  let entries;
  if (admin) {
    const set = new Map();
    for (const t of data.values()) {
      const e = S.loc.byCode.get(t.townCode) || { code: t.townCode, name: 'Town ' + t.townCode, province: '', region: '', legacyCode: null };
      const row = data.get(e.code) || data.get(e.legacyCode);
      if (row && (hasLgu(row.update) || toInt(row.update?.signal) >= 1)) set.set(e.code, e);
    }
    entries = [...set.values()];
  } else entries = myTowns();
  return entries.map((e) => {
    const row = data.get(e.code) || (e.legacyCode && data.get(e.legacyCode)) || null, u = row?.update || null, lgu = u ? normalize(u) : null;
    const leg = e.legacyCode && data.get(e.code) && data.get(e.legacyCode);
    const pub = u?.lguMeta?.publishedAt || null;
    const dg = digest(lgu, e.name), invalid = !!u && (shapeProblems(u).length > 0 || validate(draftFromLgu(lgu), { town: e.name }).errors.length > 0);
    return { e, u, lgu, dg, invalid, k: lgu ? tally(lgu) : tally(LGU_DEFAULTS), signal: toInt(u?.signal), pub, updatedAt: row?.updatedAt || u?.updatedAt || null,
      stale: !!u && isStale(pub || row?.updatedAt), mismatch: !!leg && !lguEqual(leg.update, u), hasDraft: !!(store.get(`nimbus.draft.${user}.${e.code}`) || (e.legacyCode && store.get(`nimbus.draft.${user}.${e.legacyCode}`))) };
  });
}
const sevRank = (r) => (r.dg.sev === 'danger' ? 0 : r.invalid ? 1 : r.dg.sev === 'warning' ? 2 : r.dg.sev === 'neutral' ? 3 : 4);
const KPIS = [
  ['flood', 'Flooding', 'i-waves', 'danger', (r) => r.k.flooding > 0, (rs) => { const a = rs.reduce((s, r) => s + r.k.flooding, 0), t = rs.filter((r) => r.k.flooding).length; return `${plural(a, 'area', 'areas')} in ${plural(t, 'town', 'towns')}`; }],
  ['roads', 'Roads closed', 'i-block', 'danger', (r) => r.k.roadsClosed > 0, (rs) => String(rs.reduce((s, r) => s + r.k.roadsClosed, 0))],
  ['evac', 'Evacuation full or almost full', 'i-home', 'warning', (r) => r.k.evacFull + r.k.evacAlmost > 0, (rs) => String(rs.reduce((s, r) => s + r.k.evacFull + r.k.evacAlmost, 0))],
  ['classes', 'Classes suspended', 'i-school', 'warning', (r) => r.lgu?.classes > 0, (rs) => plural(rs.filter((r) => r.lgu?.classes > 0).length, 'town', 'towns')],
  ['signal', 'Under PAGASA signal', 'i-signal', 'warning', (r) => r.signal >= 1, (rs) => plural(rs.filter((r) => r.signal >= 1).length, 'town', 'towns')],
  ['stale', 'Not updated in 12h', 'i-clock', 'warning', (r) => r.stale, (rs) => plural(rs.filter((r) => r.stale).length, 'town', 'towns')],
];
const CHIPS = [['draft', 'Has draft on this device', (r) => r.hasDraft], ['invalid', "App can't read update", (r) => r.invalid]];
function renderBoard() {
  const host = $('board-body'); if (!host) return;
  const p = S.pagasa, strip = $('pagasa-strip');
  if (strip) strip.replaceChildren(icon('i-cloud', 'i i-sm'), p?.updatedAt ? `PAGASA: ${p.message || (p.active ? 'Active storm' : 'No active storm')} · updated ${whenText(p.updatedAt)}` : 'PAGASA: no storm updates yet');
  if (S.board.at) $('refreshed').textContent = `Refreshed ${clock(S.board.at)}`;
  if (!S.board.data) return;
  const all = boardRows(); S.board.rows = new Map(all.map((r) => [r.e.code, r]));
  const f = S.board.filter, test = [...KPIS.map((k) => [k[0], k[4]]), ...CHIPS.map((c) => [c[0], c[2]])].find((x) => x[0] === f)?.[1];
  const rows = all.filter((r) => !test || test(r));
  const by = { severity: (a, b) => sevRank(a) - sevRank(b) || (Date.parse(a.pub || a.updatedAt) || 0) - (Date.parse(b.pub || b.updatedAt) || 0), oldest: (a, b) => (Date.parse(a.pub || a.updatedAt) || 0) - (Date.parse(b.pub || b.updatedAt) || 0), name: (a, b) => a.e.name.localeCompare(b.e.name) }[S.board.sort];
  rows.sort(by); S.board.visible = rows;
  const setF = (id) => { S.board.filter = S.board.filter === id ? null : id; renderBoard(); };
  const list = !all.length ? empty('i-pin', isAdmin() ? 'No town has an active report. Search above to open any town.' : 'Your account has no towns assigned. Ask your NIMBUS admin.')
    : !rows.length ? empty('i-search', 'No towns match this filter.', null, btn('Clear filter', 'btn-secondary', () => setF(null)))
      : h('table', { class: 'board-table' }, h('thead', null, h('tr', null, ['Town', 'Status', 'Signal', 'Classes', 'Last LGU publish'].map((t) => h('th', { scope: 'col' }, t)), h('th', null, h('span', { class: 'sr-only' }, 'Actions')))),
        h('tbody', null, rows.map(boardRow)));
  host.replaceChildren(
    h('div', { class: 'kpis' }, KPIS.map(([id, label, ic, sev, , val]) => h('button', { type: 'button', class: 'kpi ' + sev, 'aria-pressed': String(f === id), onclick: () => setF(id) }, h('span', { class: 'kpi-label' }, icon(ic, 'i i-sm'), label), h('span', { class: 'kpi-value' }, val(all))))),
    h('div', { class: 'board-filters' }, CHIPS.map(([id, label]) => h('button', { type: 'button', class: 'chip', 'aria-pressed': String(f === id), onclick: () => setF(id) }, label)),
      h('label', { class: 'sort' }, 'Sort ', h('select', { class: 'input input-sm', onchange: (e) => { S.board.sort = e.target.value; renderBoard(); } }, [['severity', 'Most severe first'], ['oldest', 'Oldest update first'], ['name', 'Name A–Z']].map(([v, t]) => h('option', { value: v, selected: S.board.sort === v }, t))))),
    list);
}
function boardRow(r) {
  const href = '#/town/' + r.e.code;
  return h('tr', { class: 'brow', onclick: (e) => { if (!e.target.closest('a')) location.hash = href; } },
    h('td', { 'data-label': 'Town' }, h('span', { class: 'b-name' }, r.e.name), r.e.province && h('span', { class: 'muted' }, r.e.province)),
    h('td', { 'data-label': 'Status' }, h('div', { class: 'b-status' }, badge(r.dg.sev, SEV[r.dg.sev].word), h('span', null, r.dg.headline)),
      h('div', { class: 'tags' }, r.hasDraft && badge('info', 'Draft', 'i-info'), r.invalid && badge('danger', "App can't read this update", 'i-warn'), r.mismatch && badge('warning', 'SMS code out of sync', 'i-warn'))),
    h('td', { 'data-label': 'Signal', class: 'num' }, r.signal ? `Signal ${r.signal}` : '—'),
    h('td', { 'data-label': 'Classes' }, r.lgu ? CLASSES[r.lgu.classes] ?? String(r.lgu.classes) : '—'),
    h('td', { 'data-label': 'Last LGU publish' }, h('span', { class: 'num' }, r.pub ? `${relText(r.pub)} · ${clock(r.pub)}` : 'Unknown'), r.stale && badge('warning', 'Over 12h', 'i-clock'), r.updatedAt && h('span', { class: 'tiny muted' }, `Residents see: Updated ${whenText(r.updatedAt)}`)),
    h('td', { class: 'b-act' }, h('a', { class: 'btn btn-secondary btn-sm', href }, 'Edit', h('span', { class: 'sr-only' }, ' ' + r.e.name))));
}
function exportCsv() {
  const rows = S.board.visible || [], q = (v) => `"${String(v ?? '').replace(/"/g, '""')}"`;
  const lines = [['town', 'province', 'code', 'smsCode', 'severity', 'headline', 'signal', 'classes', 'floodingAreas', 'roadsClosed', 'evacFullOrClosed', 'lguPublishedAt', 'updatedAt'].join(',')]
    .concat(rows.map((r) => [r.e.name, r.e.province, r.e.code, r.e.legacyCode || r.e.code, r.dg.sev, r.dg.headline, r.signal, r.lgu ? CLASSES[r.lgu.classes] : '', r.k.flooding, r.k.roadsClosed, r.k.evacFull + r.k.evacClosed, r.pub || '', r.updatedAt || ''].map(q).join(',')));
  const d = new Date(), p = (n) => String(n).padStart(2, '0');
  const a = h('a', { href: URL.createObjectURL(new Blob([lines.join('\n')], { type: 'text/csv' })), download: `nimbus-situation-${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}.csv` });
  document.body.append(a); a.click(); a.remove();
}
function searchBox() {
  const input = h('input', { id: 'town-q', class: 'input input-lg', role: 'combobox', 'aria-expanded': 'false', 'aria-controls': 'town-q-list', 'aria-autocomplete': 'list', autocomplete: 'off', spellcheck: 'false', placeholder: 'Town, city or province' });
  const list = h('ul', { id: 'town-q-list', role: 'listbox', class: 'combo-list', hidden: true, 'aria-label': 'Towns' });
  let opts = [], act = -1;
  const close = () => { list.hidden = true; input.setAttribute('aria-expanded', 'false'); input.removeAttribute('aria-activedescendant'); act = -1; };
  const go = (e) => { if (!e) return; close(); pushRecent(e.code); location.hash = '#/town/' + e.code; };
  const setAct = (i) => { act = i; list.querySelectorAll('[role=option]').forEach((li, j) => li.setAttribute('aria-selected', String(j === i))); if (i >= 0) { input.setAttribute('aria-activedescendant', 'opt-' + i); $('opt-' + i)?.scrollIntoView({ block: 'nearest' }); } else input.removeAttribute('aria-activedescendant'); };
  const show = () => {
    const q = fold(input.value.trim()), rows = S.board.rows || new Map();
    let groups;
    if (q) {
      const toks = q.split(/\s+/);
      groups = [['', S.loc.list.filter((e) => toks.every((t) => e.key.includes(t))).map((e) => [fold(e.name).startsWith(q) ? 0 : fold(e.name).includes(q) ? 1 : 2, e]).sort((a, b) => a[0] - b[0] || a[1].name.localeCompare(b[1].name)).slice(0, 50).map((x) => x[1])]];
    } else groups = [['Recent', (store.get(`nimbus.recent.${S.session.username}`) || []).map((c) => S.loc.byCode.get(c)).filter(Boolean)], ['Active now', [...rows.values()].filter((r) => r.dg.sev === 'danger' || r.dg.sev === 'warning').sort((a, b) => sevRank(a) - sevRank(b)).slice(0, 20).map((r) => r.e)]];
    list.replaceChildren(); opts = [];
    for (const [g, items] of groups) {
      if (!items.length) continue;
      if (g) list.append(h('li', { role: 'presentation', class: 'combo-group' }, g));
      for (const e of items) { const i = opts.length, r = rows.get(e.code); opts.push(e); list.append(h('li', { role: 'option', id: 'opt-' + i, 'aria-selected': 'false', onmousedown: (ev) => ev.preventDefault(), onclick: () => go(e) }, h('span', { class: 'opt-text' }, h('span', { class: 'opt-name' }, e.name), h('span', { class: 'opt-meta' }, [e.province, e.region].filter(Boolean).join(' · '))), r && r.u && badge(r.dg.sev, SEV[r.dg.sev].word))); }
    }
    if (!opts.length) list.append(h('li', { role: 'presentation', class: 'combo-empty' }, q ? 'No town matches.' : 'Start typing to find a town.'));
    list.hidden = false; input.setAttribute('aria-expanded', 'true'); setAct(-1);
  };
  input.addEventListener('input', show); input.addEventListener('focus', show); input.addEventListener('blur', () => setTimeout(close, 150));
  input.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowDown') { e.preventDefault(); if (list.hidden) show(); setAct(Math.min(act + 1, opts.length - 1)); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); setAct(Math.max(act - 1, 0)); }
    else if (e.key === 'Enter') { e.preventDefault(); go(opts[Math.max(act, 0)]); } else if (e.key === 'Escape') close();
  });
  return h('div', { class: 'combo' }, h('label', { for: 'town-q', class: 'label' }, 'Find a town'), h('div', { class: 'combo-field' }, icon('i-search'), input), list);
}
const skeleton = (n) => h('div', { class: 'skel-wrap', 'aria-busy': 'true', 'aria-label': 'Loading' }, Array.from({ length: n }, () => h('div', { class: 'skel' })));

// --- Town editor: load ---
async function openTown(code, section) {
  const tok = ++S.nav;
  [...S.banners.keys()].filter((k) => k.startsWith('ed:')).forEach((k) => S.banners.delete(k));
  stopBoardTimer(); ed = null;
  const loc = S.loc.byCode.get(code) || (/^(?:\d{4}|\d{10})$/.test(code) && canWrite(code) ? { code, name: 'Town ' + code, province: '', region: '', legacyCode: null } : null);
  setMode('editor'); renderTopbar();
  const codes = loc ? [loc.code, loc.legacyCode].filter(Boolean).filter(canWrite) : [];
  if (!codes.length) { setMode('board'); renderBanners(); $('view').replaceChildren(empty('i-lock', `This account can't open ${code}.`, null, h('a', { class: 'btn btn-secondary', href: '#/board' }, 'Back to board'))); return; }
  if (code !== loc.code && codes.includes(loc.code)) return location.replace(`#/town/${loc.code}${section ? '/' + section : ''}`);
  const primary = codes.includes(loc.code) ? loc.code : loc.legacyCode, legacy = primary === loc.code ? loc.legacyCode : null;
  $('view').replaceChildren(skeleton(4)); $('rail').replaceChildren(); $('preview-rail').replaceChildren(); $('publish-bar').replaceChildren(); renderBanners();
  let base, legacyBase = null;
  try { [base, legacyBase] = await Promise.all([getTown(primary), legacy ? getTown(legacy).catch(() => null) : null]); if (!S.pagasa) S.pagasa = (await api('GET', '/pagasa').catch(() => null))?.data || null; }
  catch (e) { if (tok !== S.nav) return; $('view').replaceChildren(empty('i-error', `Couldn't load ${loc.name}.`, errText(e), btn('Try again', 'btn-secondary', () => openTown(code, section)))); return; }
  if (tok !== S.nav) return;
  ed = { code: loc.code, loc, primary, legacy, legacyWritable: !!legacy && canWrite(legacy), smsCode: loc.legacyCode || primary, legacyBase, mode: null, pin: { adding: null, form: null, sel: null } };
  loadBase(base);
  pushRecent(loc.code);
  const stored = store.get(draftKey(primary));
  if (stored?.draft && !lguEqual(lguFromDraft(stored.draft), base.update)) {
    ed.pendingStored = stored;
    const n = diff(stored.baseLgu || ed.baseLgu, stored.draft, loc.name).count;
    setBanner('ed:draft', { sev: 'neutral', text: `You have unpublished changes from ${whenText(stored.savedAt)} (${plural(n, 'change', 'changes')}).`, actions: [{ label: 'Continue draft', run: continueDraft }, { label: 'Discard', run: () => { store.del(draftKey(primary)); ed.pendingStored = null; clearBanner('ed:draft'); } }] });
  } else if (stored) store.del(draftKey(primary));
  renderEditor();
  if (section) requestAnimationFrame(() => scrollToSec(section, true));
}
function loadBase(base) {
  ed.base = base; ed.baseLgu = normalize(base.update); ed.draft = draftFromLgu(ed.baseLgu);
  ed.touched = new Set(); ed.acceptedLgu = null; ed.pin.form = null; ed.pin.adding = null;
  const probs = base.update ? shapeProblems(base.update).length + validate(ed.draft, { town: ed.loc.name }).errors.length : 0;
  ed.showAll = probs > 0;
  if (probs) setBanner('ed:invalid', { sev: 'danger', text: `The live update has ${plural(probs, 'problem', 'problems')} that stop the NIMBUS app from showing it to residents. Fix the highlighted fields and publish.` });
  else clearBanner('ed:invalid');
}
function continueDraft() {
  const s = ed.pendingStored; if (!s) return;
  ed.draft = s.draft; ed.baseLgu = s.baseLgu ? normalize(s.baseLgu) : ed.baseLgu; ed.pendingStored = null; ed.mode = 'draft';
  for (const k of ['floodAreas', 'evacuationCenters', 'roadStatuses', 'mapPins']) for (const r of ed.draft[k]) r._id = uid();
  clearBanner('ed:draft'); update(SECTIONS.map((s) => s[0])); toast('Draft restored. Review to publish.', { sev: 'info' });
}
// Any edit while the old-draft banner is up starts fresh; the old draft is kept in local history.
function edited() {
  if (!ed.pendingStored) return;
  const s = ed.pendingStored; ed.pendingStored = null; clearBanner('ed:draft');
  addHistory(ed.primary, { at: s.savedAt, by: S.session.username, lines: ['Discarded draft'], lgu: lguFromDraft(s.draft), codes: [], verified: false, unpublished: true });
}
// --- Town editor: derived state and rendering ---
function recompute() {
  const lgu = lguFromDraft(ed.draft), merged = { ...(isObj(ed.base.update) ? ed.base.update : {}), ...lgu };
  ed.d = { lgu, merged, dirty: !lguEqual(lgu, ed.base.update), diff: diff(ed.baseLgu, ed.draft, ed.loc.name), val: validate(ed.draft, { town: ed.loc.name, loc: ed.loc, u: merged, code: ed.smsCode }) };
}
const RENDER = { overview: secOverview, pagasa: secPagasa, classes: secClasses, floods: () => secList('floods'), evac: () => secList('evac'), roads: () => secList('roads'), activity: secActivity };
function update(secs) {
  if (!ed || !$('sec-overview')) return;
  recompute();
  for (const sec of secs) {
    const host = $('sec-' + sec); if (!host) continue;
    const a = document.activeElement, fid = a && host.contains(a) ? a.id : null;
    let sel = null; try { sel = fid && typeof a.selectionStart === 'number' ? [a.selectionStart, a.selectionEnd] : null; } catch { /* radios */ }
    if (sec === 'map') updateMap(); else host.replaceChildren(RENDER[sec]());
    if (fid) { const el = $(fid); if (el && el !== document.activeElement) { el.focus({ preventScroll: true }); if (sel) try { el.setSelectionRange(...sel); } catch { /* n/a */ } } }
  }
  renderDerived();
}
const refreshSoon = debounce(() => update([]), 150);
function renderEditor() {
  document.title = `${ed.loc.name} · NIMBUS LGU`;
  $('view').replaceChildren(h('div', { class: 'editor' }, SECTIONS.map(([id, label]) => h('section', { id: 'sec-' + id, class: 'sec', 'aria-label': label }))));
  recompute();
  for (const [id] of SECTIONS) if (id !== 'map') $('sec-' + id).replaceChildren(RENDER[id]());
  initMapSection(); renderTopbar(); renderBanners(); renderDerived(); spy();
}
function renderDerived() {
  if (!ed?.d) return;
  if (!$('sec-overview')?.contains(document.activeElement)) $('sec-overview').replaceChildren(secOverview());
  for (const k of KINDS) { const s = $('sum-' + k); if (s) s.textContent = sectionSummary(k, ed.d.lgu[LISTS[k].key]); }
  const sm = $('sum-map'); if (sm) sm.textContent = plural(ed.d.lgu.mapPins.length, 'pin', 'pins');
  renderNav(); renderBar(); renderPreviewRail(); updateNoticeExtras();
  if ($('preview-sheet').open) openPreviewSheet();
  document.title = (ed.d.dirty ? '• ' : '') + `${ed.loc.name} · NIMBUS LGU`;
  saveDraftSoon();
}
const saveDraftSoon = debounce(() => saveDraftNow(), 500);
function saveDraftNow() {
  if (!ed?.d || ed.pendingStored || ed.discarded) return;
  if (!ed.d.dirty) return store.del(draftKey(ed.primary));
  const ok = store.set(draftKey(ed.primary), { draft: ed.draft, baseUpdatedAt: ed.base.updatedAt, baseLgu: ed.baseLgu, savedAt: new Date().toISOString() });
  if (!ok && !S.ui.storageFailed) { S.ui.storageFailed = true; setBanner('storage', { sev: 'warning', text: "Drafts can't be saved on this device. Don't refresh or close this tab." }); }
}
function scrollToSec(sec, instant) { const el = $('sec-' + sec); if (el) el.scrollIntoView({ behavior: instant || reduced() ? 'auto' : 'smooth', block: 'start' }); }
let spyObs = null;
function spy() {
  spyObs?.disconnect();
  spyObs = new IntersectionObserver((ents) => {
    const vis = ents.filter((e) => e.isIntersecting).sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top)[0];
    if (!vis || !ed) return; const id = vis.target.id.slice(4);
    document.querySelectorAll('.rail a').forEach((a) => a.toggleAttribute('aria-current', a.dataset.sec === id) || a.dataset.sec !== id || a.setAttribute('aria-current', 'true'));
    const hsh = `#/town/${ed.code}/${id}`; if (location.hash !== hsh) { history.replaceState(null, '', hsh); lastHash = hsh; }
  }, { rootMargin: '-120px 0px -55% 0px' });
  document.querySelectorAll('.sec').forEach((s) => spyObs.observe(s));
}
function renderNav() {
  const d = ed.d, k = tally(d.lgu), edited = new Set(d.diff.lines.filter((l) => l.kind !== 'info').map((l) => l.section)), errs = new Set(d.val.errors.map((e) => e.section));
  const cur = document.querySelector('.rail a[aria-current]')?.dataset.sec || parseHash().section || 'overview', sig = toInt(ed.base.update?.signal);
  const b = { overview: h('span', { class: 'sev-dot ' + digest(d.lgu, '').sev, title: 'Severity' }), pagasa: sig ? badge('warning', `Signal ${sig}`) : null, classes: d.lgu.classes > 0 ? badge('warning', 'Suspended') : null,
    floods: k.flooding ? badge('danger', `${k.flooding} flooding`) : h('span', { class: 'count' }, d.lgu.floodAreas.length), evac: k.evacFull + k.evacClosed ? badge('danger', `${k.evacFull + k.evacClosed} full`) : h('span', { class: 'count' }, d.lgu.evacuationCenters.length),
    roads: k.roadsClosed ? badge('danger', `${k.roadsClosed} closed`) : h('span', { class: 'count' }, d.lgu.roadStatuses.length), map: h('span', { class: 'count' }, d.lgu.mapPins.length), activity: null };
  $('rail').replaceChildren(h('ul', null, SECTIONS.map(([id, label, ic]) => h('li', null, h('a', { href: `#/town/${ed.code}/${id}`, 'data-sec': id, 'aria-current': cur === id ? 'true' : null },
    icon(ic, 'i i-sm'), h('span', { class: 'nav-label' }, label), errs.has(id) && h('span', { class: 'nav-err', title: 'Has problems' }, '!', h('span', { class: 'sr-only' }, ' has problems')), edited.has(id) && h('span', { class: 'nav-edit', title: 'Edited' }, h('span', { class: 'sr-only' }, 'edited')), h('span', { class: 'nav-badge' }, b[id]))))));
}
function renderBar() {
  const bar = $('publish-bar'); if (!ed?.d || !bar) return;
  const d = ed.d, n = d.diff.count, k = d.val.errors.length, ro = S.ui.readOnly;
  const state = ro ? h('p', { class: 'bar-state' }, icon('i-lock', 'i i-sm'), 'Session ended. Sign in to publish.')
    : d.dirty ? h('p', { class: 'bar-state dirty' }, h('span', { class: 'dot-primary' }), `${plural(n || 1, 'unpublished change', 'unpublished changes')}`, k > 0 && h('span', { class: 'danger-ink' }, ` · ${plural(k, 'problem', 'problems')}`))
      : h('p', { class: 'bar-state muted' }, icon('i-check', 'i i-sm'), ed.publishedAt ? `All changes published · ${clock(ed.publishedAt)}` : 'No changes');
  const main = ro ? btn('Sign in to publish', 'btn-primary', () => reauth(false).catch(() => {}), { id: 'bar-publish', ic: 'i-lock' })
    : btn('Review & publish', 'btn-primary', () => { if (ed.d.dirty) openReview('edit'); }, { id: 'bar-publish', ic: 'i-send', 'aria-disabled': d.dirty ? null : 'true', title: d.dirty ? 'Ctrl/Cmd + Enter' : 'No changes to publish' });
  bar.replaceChildren(state, h('div', { class: 'bar-actions' }, d.dirty && btn('Discard', 'btn-tertiary', discardAll, { id: 'bar-discard' }), main));
}
async function discardAll() {
  if (!(await confirmDlg({ title: `Discard ${plural(ed.d.diff.count || 1, 'change', 'changes')}?`, body: "This can't be undone.", ok: 'Discard', danger: true }))) return;
  store.del(draftKey(ed.primary)); ed.draft = draftFromLgu(normalize(ed.base.update)); ed.baseLgu = normalize(ed.base.update); ed.touched = new Set(); ed.mode = null; ed.pin.form = null; ed.pin.adding = null;
  update(SECTIONS.map((s) => s[0])); toast('Changes discarded.', { sev: 'info' });
}
// --- Section 1: Overview ---
function digestBanner(dg, { draft, link } = {}) {
  return h('div', { class: `digest ${dg.sev}${draft ? ' is-draft' : ''}` }, draft && h('p', { class: 'overline' }, 'Draft: not live yet'),
    h('div', { class: 'digest-main' }, sevIcon(dg.sev, 'i i-lg'), h('p', { class: 'digest-head' }, dg.headline)),
    dg.counts.length > 0 && h('div', { class: 'chips' }, dg.counts.map((c) => (link ? h('a', { class: 'badge ' + c.sev, href: `#/town/${ed.code}/${c.sec}` }, icon(c.icon, 'i i-xs'), c.label) : badge(c.sev, c.label, c.icon)))));
}
function secOverview() {
  const d = ed.d, loc = ed.loc, u = ed.base.update, mode = d.dirty ? ed.mode || 'draft' : 'live';
  const items = () => [{ label: 'Reset to all-clear…', run: resetAllClear }, { label: 'Clear all LGU data…', run: clearAllLgu, danger: true }, d.dirty && { label: 'Discard all changes…', run: discardAll }, isAdmin() && { label: 'Delete stored record…', run: deleteDialog, danger: true }].filter(Boolean);
  const meta = u?.lguMeta;
  return h('div', { class: 'card hero' },
    h('div', { class: 'hero-head' }, h('div', null, h('h1', { class: 'town-name' }, loc.name), h('p', { class: 'muted' }, [loc.province, loc.region].filter(Boolean).join(' · ')),
      h('p', { class: 'tiny muted' }, `PSGC ${loc.code}${loc.legacyCode ? ' · SMS code ' + loc.legacyCode : ''}`)), menuBtn('More actions for ' + loc.name, 'ov-menu', items)),
    seg({ name: 'ov-mode', legend: 'Show live or draft', idp: 'ov-mode', value: mode, disabled: !d.dirty, cls: 'seg-sm', options: [{ value: 'live', word: 'Live now', icon: 'i-signal' }, { value: 'draft', word: 'Draft', icon: 'i-info' }], onChange: (v) => { ed.mode = v; update(['overview']); } }),
    !u && !d.dirty ? empty('i-campaign', `Nothing published for ${loc.name} yet`, null, btn('Start first update', 'btn-primary', () => { scrollToSec('classes'); $('cls-0')?.focus({ preventScroll: true }); }))
      : digestBanner(digest(mode === 'draft' ? d.lgu : u ? normalize(u) : null, loc.name), { draft: mode === 'draft', link: true }),
    h('ul', { class: 'meta' },
      ed.publishedAt && h('li', null, icon('i-check', 'i i-sm'), `Published just now (${clock(ed.publishedAt)})`),
      h('li', null, icon('i-clock', 'i i-sm'), meta?.publishedAt ? `LGU last published ${whenText(meta.publishedAt)} by ${meta.publishedBy || 'unknown'} (reported by the dashboard)` : 'LGU last published: unknown'),
      u && h('li', null, icon('i-clock', 'i i-sm'), `Residents see "Updated ${whenText(ed.base.updatedAt)}"`, isStale(ed.base.updatedAt) && badge('warning', 'Residents see "May be out of date"', 'i-warn')),
      u && !d.dirty && h('li', null, 'Still accurate? ', btn('Reconfirm status', 'btn-secondary btn-sm', () => openReview('reconfirm'), { id: 'ov-reconfirm' }))));
}
function resetAllClear() {
  edited();
  const d = ed.draft; d.classes = 0; d.notice = '';
  d.floodAreas.forEach((r) => { if (!r._removed) r.status = 'C'; }); d.roadStatuses.forEach((r) => { if (!r._removed) r.status = 'O'; });
  d.mapPins.forEach((p) => { if (p.category === 'flood') p.status = 'C'; else if (p.category === 'road') p.status = 'O'; });
  update(SECTIONS.map((s) => s[0])); toast('All-clear draft ready. Review to publish.', { sev: 'info' }); openReview('edit');
}
// Removes every LGU item (floods, evac, roads, pins, advisory, classes) through the
// normal review + publish flow, so PAGASA fields are kept and residents get an empty
// LGU report on their next SMS request.
function clearAllLgu() {
  edited();
  const d = ed.draft; d.classes = 0; d.notice = '';
  for (const list of [d.floodAreas, d.evacuationCenters, d.roadStatuses, d.mapPins]) {
    for (const r of [...list]) { if (r._orig == null) list.splice(list.indexOf(r), 1); else r._removed = true; }
  }
  ed.pin.form = null;
  update(SECTIONS.map((s) => s[0])); toast('Everything cleared in the draft. Review to publish.', { sev: 'info' }); openReview('edit');
}
// --- Section 2: PAGASA (read-only) ---
function secPagasa() {
  const u = ed.base.update || {}, has = PAGASA_KEYS.some((k) => u[k] !== undefined), sig = toInt(u.signal), p = S.pagasa;
  const tile = (label, value, sub) => h('div', { class: 'stat' }, h('p', { class: 'stat-label' }, label), h('div', { class: 'stat-value' }, value), sub && h('p', { class: 'tiny muted' }, sub));
  return h('div', { class: 'card' }, cardHead('i-cloud', 'From PAGASA', null, badge('info', 'Updated automatically', 'i-info')),
    !has ? empty('i-cloud', 'PAGASA data has not reached this town yet. It is added by the PAGASA sync.')
      : u.pagasaActive === false ? empty('i-check', 'No active PAGASA storm for this town.')
        : [h('div', { class: 'stats' }, tile('Wind signal', sig ? badge(sig >= 3 ? 'danger' : 'warning', `Signal No. ${sig}`, 'i-signal') : 'None'), tile('Rain', RAIN[Math.max(0, Math.min(4, toInt(u.rain)))]), tile('Gusts', `${toInt(u.gusts)} km/h`),
          tile('Bulletin', [u.pagasaName, u.pagasaBulletin && '#' + u.pagasaBulletin].filter(Boolean).join(' · ') || '—', u.issuedAt && `Issued ${u.issuedAt}`)),
          sig > 0 && h('div', { class: `box ${sig >= 3 ? 'danger' : 'warning'}`, role: 'status' }, h('h3', null, icon('i-warn', 'i i-sm'), `Signal No. ${sig} over ${ed.loc.name}${u.pagasaTitle ? ' · ' + u.pagasaTitle : ''}`),
            u.pagasaAdvice && h('p', null, h('strong', null, 'What residents are told: '), String(u.pagasaAdvice)),
            h('p', { class: 'tiny muted' }, 'Residents subscribed to SMS alerts for this town are texted automatically when PAGASA raises the signal.')),
          sig === 0 && u.pagasaAdvice && h('p', null, h('strong', null, 'What residents are told: '), String(u.pagasaAdvice)),
          u.pagasaNotice && h('blockquote', { class: 'quote' }, String(u.pagasaNotice))],
    h('p', { class: 'foot-note' }, icon('i-lock', 'i i-sm'), 'Set by the PAGASA sync. Publishing never changes these.'),
    p && h('p', { class: 'tiny muted' }, `National: ${p.message || (p.active ? 'Active storm' : 'No active storm')}${p.updatedAt ? ' · ' + whenText(p.updatedAt) : ''}`));
}
// --- Section 3: Classes & advisory ---
function secClasses() {
  const d = ed.draft, sig = toInt(ed.base.update?.signal), hint = DEPED_HINT(sig), clsErr = ed.d.val.errors.find((e) => e.fieldId === 'cls-0');
  const ta = h('textarea', { id: 'notice', class: 'input textarea', value: d.notice, 'aria-describedby': 'notice-help sms-meter', oninput: (e) => { edited(); d.notice = e.target.value; grow(e.target); refreshSoon(); }, onchange: () => rerenderSoon('classes') });
  requestAnimationFrame(() => grow(ta));
  return h('div', { class: 'card' }, cardHead('i-school', 'Classes & advisory', d.classes > 0 ? 'Classes suspended' : 'Classes as usual'),
    h('fieldset', { class: 'class-grid', 'aria-invalid': clsErr ? 'true' : null }, h('legend', { class: 'label' }, 'Class suspension'),
      CLASSES.map((w, i) => [h('input', { type: 'radio', class: 'sr-only', name: 'classes', id: 'cls-' + i, value: i, checked: d.classes === i, onchange: () => { edited(); d.classes = i; update(['classes']); } }),
        h('label', { for: 'cls-' + i, class: 'class-card' + (i > 0 ? ' warn' : '') }, icon(d.classes === i ? 'i-check' : 'i-school'), h('span', null, h('span', { class: 'cc-word' }, w), h('span', { class: 'cc-sub' }, i ? 'Classes suspended' : 'Classes as usual')))])),
    clsErr && h('p', { class: 'err' }, icon('i-error', 'i i-sm'), clsErr.msg),
    sig >= 1 && (d.classes === 0 || d.classes > hint) && h('div', { class: 'hint info' }, icon('i-info', 'i i-sm'), h('p', null, `Signal No. ${sig} is raised. DepEd guidance suspends ${DEPED_WORD[hint]} classes automatically. `, btn('Apply', 'btn-tertiary btn-sm', () => { edited(); d.classes = hint; update(['classes']); }), h('span', { class: 'tiny muted' }, ' Check current DepEd and LGU rules.'))),
    h('div', { class: 'field' }, h('label', { for: 'notice', class: 'label' }, 'Advisory to residents'), h('p', { class: 'help', id: 'notice-help' }, 'Shown in full in the app. SMS replies carry it after the status codes.'),
      h('div', { class: 'tpl-row', role: 'group', 'aria-label': 'Insert a template' }, TEMPLATES.map((t) => btn(t, 'btn-secondary btn-sm pill-btn', () => insertTemplate(t)))),
      ta, h('div', { id: 'sms-meter', class: 'sms-meter', 'aria-live': 'polite' }), h('div', { id: 'notice-warn' })));
}
function grow(t) { t.style.height = 'auto'; t.style.height = Math.min(320, Math.max(120, t.scrollHeight + 2)) + 'px'; }
function insertTemplate(t) {
  edited(); const ta = $('notice'), d = ed.draft, s = ta.selectionStart ?? d.notice.length, e = ta.selectionEnd ?? s;
  const pre = d.notice.slice(0, s), ins = (pre && !/\s$/.test(pre) ? ' ' : '') + t;
  d.notice = pre + ins + d.notice.slice(e); ta.value = d.notice; ta.focus(); ta.setSelectionRange(s + ins.length, s + ins.length); grow(ta); update([]);
}
const updateNoticeExtras = debounce(() => {
  if (!ed?.d) return; const m = $('sms-meter'), w = $('notice-warn'); if (!m || !w) return;
  const reps = buildReplies(ed.d.merged, ed.smsCode).filter((r) => r.type !== 'P').map((r) => ({ ...r, left: r.limit - r.len })).sort((a, b) => a.left - b.left);
  m.replaceChildren(h('span', { class: 'tiny muted' }, 'SMS room (estimate):'), reps.map((r, i) => h('span', { class: 'mini' + (r.left < 0 ? ' over' : '') + (i === 0 ? ' tight' : '') }, r.left < 0 ? `${r.label} ${-r.left} over ` : `${r.label} ${r.left} left`, r.left < 0 && icon('i-warn', 'i i-xs'), r.unicode && ' (Unicode: 70 per text)')));
  const ws = ed.d.val.warnings.filter((x) => x.notice);
  if (ed.draft.notice.trim() && ed.d.merged.pagasaActive !== false) ws.push({ info: true, msg: 'Your advisory replaces the PAGASA notice in the SMS overview.' });
  w.replaceChildren(...ws.map(warnLine));
}, 400);
function warnLine(x, after) {
  return h('div', { class: 'hint ' + (x.info ? 'info' : 'warning') }, icon(x.info ? 'i-info' : 'i-warn', 'i i-sm'), h('p', null, x.msg, ' ', (x.actions || []).map((a) => btn(a.label, 'btn-tertiary btn-sm', () => { edited(); a.run(); update(['classes', ...KINDS, 'map']); after?.(); }))));
}
// --- Sections 4-6: Flood areas, Evacuation centers, Roads ---
function secList(kind) {
  const M = LISTS[kind], rows = ed.draft[M.key], town = ed.loc.name;
  const add = btn(M.add, 'btn-secondary', () => { edited(); const r = { ...M.make(), _id: uid(), _orig: null, _removed: false }; rows.push(r); update([kind]); $(`f-${r._id}-name`)?.focus(); }, { ic: 'i-plus', id: 'add-' + kind });
  const bulk = kind === 'floods' ? ['Mark all No flooding', 'C', (n) => `Marked ${plural(n, 'area', 'areas')} No flooding.`] : kind === 'roads' ? ['Open all roads', 'O', (n) => `Opened ${plural(n, 'road', 'roads')}.`] : null;
  const setAll = bulk && rows.length > 0 && menuBtn('Set all', 'setall-' + kind, () => [{ label: bulk[0], run: () => {
    edited(); const snap = clone(rows), live = rows.filter((r) => !r._removed); live.forEach((r) => { r.status = bulk[1]; }); update([kind]);
    toast(bulk[2](live.length), { sev: 'ok', action: { label: 'Undo', run: () => { ed.draft[M.key] = snap; update([kind]); } } });
  } }], 'Set all…');
  const ws = ed.d.val.warnings.filter((w) => w.section === kind && !w.rowId);
  return h('div', { class: 'card' }, cardHead(M.icon, M.title, sectionSummary(kind, ed.d.lgu[M.key]), setAll, 'sum-' + kind),
    h('p', { class: 'info-line' }, icon('i-info', 'i i-sm'), 'SMS replies list these by number. Keep the order during an event. Add new ones at the end.'),
    ws.map((w) => warnLine(w)),
    rows.length ? h('ol', { class: 'list' }, rows.map((r, i) => renderItem(kind, r, i, rows))) : empty(M.icon, M.empty, M.emptyBody.replace('{town}', town)),
    h('div', { class: 'list-foot' }, add));
}
function renderItem(kind, r, i, rows) {
  const M = LISTS[kind], id = r._id, o = r._orig != null ? ed.baseLgu[M.key][r._orig] : null;
  const pos = r._removed ? null : rows.slice(0, i + 1).filter((x) => !x._removed).length;
  const changes = o && !r._removed ? rowChanges(kind, o, r) : [], state = r._removed ? 'removed' : r._orig == null ? 'new' : changes.length ? 'changed' : '';
  const errs = ed.d.val.errors.filter((e) => e.rowId === id && (e.always || ed.showAll || ed.touched.has(e.fieldId)));
  const errFor = (fid) => errs.find((e) => e.fieldId === fid), nameId = `f-${id}-name`, nErr = errFor(nameId), who = `${M.noun} ${pos ?? ''}${r.name ? ', ' + r.name : ''}`;
  const set = (patch) => { edited(); Object.assign(r, patch); update([kind]); };
  const name = h('input', { id: nameId, class: 'input' + (nErr ? ' invalid' : ''), value: r.name, placeholder: M.ph, disabled: r._removed, autocomplete: 'off', 'aria-invalid': nErr ? 'true' : null, 'aria-describedby': nErr ? nameId + '-err' : null,
    oninput: (e) => { edited(); r.name = e.target.value; refreshSoon(); }, onchange: () => rerenderSoon(kind), onblur: () => { if (!ed.touched.has(nameId)) { ed.touched.add(nameId); rerenderSoon(kind); } } });
  const ctrls = [seg({ name: `n-${id}-status`, legend: `Status for ${who}`, idp: `f-${id}-status`, value: r.status, disabled: r._removed, options: M.order.map((v) => ({ value: v, word: M.table[v].word, sev: M.table[v].sev, icon: M.table[v].icon })),
    onChange: (v) => set(kind === 'evac' && v === 'F' && !(intStr(r.percentFull) >= 100) ? { status: v, percentFull: 100 } : { status: v }) })];
  if (kind === 'floods') ctrls.push(seg({ name: `n-${id}-level`, legend: `Flood risk for ${r.name || who}`, idp: `f-${id}-level`, value: r.level, disabled: r._removed, cls: 'seg-level', options: ['L', 'M', 'H'].map((v) => ({ value: v, word: FLOOD_LEVEL[v], icon: 'i-waves' })), onChange: (v) => set({ level: v }) }));
  let hints = [];
  if (kind === 'evac') {
    const pv = intStr(r.percentFull), pn = int0100(pv) ? pv : null, off = r._removed || r.status === 'X', pctId = `f-${id}-pct`, pErr = errFor(pctId);
    const step = (dlt) => set({ percentFull: Math.max(0, Math.min(100, (pn ?? 0) + dlt)) });
    const fill = r.status === 'F' || pn === 100 ? 'danger' : pn >= 85 ? 'warning' : 'ok';
    ctrls.push(h('div', { class: 'occ' + (off ? ' off' : '') }, iconBtn('i-dash', `Decrease ${M.noun} ${pos} by 10`, () => step(-10), { id: `f-${id}-minus`, disabled: off }),
      h('span', { class: 'pct-wrap' }, h('input', { id: pctId, class: 'input pct' + (pErr ? ' invalid' : ''), value: String(r.percentFull ?? ''), inputmode: 'numeric', pattern: '[0-9]*', maxlength: '5', disabled: off, 'aria-label': `${M.noun} ${pos} percent full`, 'aria-invalid': pErr ? 'true' : null, 'aria-describedby': pErr ? pctId + '-err' : null,
        oninput: (e) => { edited(); r.percentFull = e.target.value; refreshSoon(); }, onchange: () => rerenderSoon(kind), onblur: () => { if (!ed.touched.has(pctId)) { ed.touched.add(pctId); rerenderSoon(kind); } } }), h('span', { 'aria-hidden': 'true' }, '%')),
      iconBtn('i-plus', `Increase ${M.noun} ${pos} by 10`, () => step(10), { id: `f-${id}-plus`, disabled: off }),
      h('span', { class: 'meter', 'aria-hidden': 'true' }, h('span', { class: 'meter-fill ' + fill, style: `width:${pn ?? 0}%` })), h('span', { class: 'occ-text num' }, pn != null ? `${pn}% full` : '—')));
    if (r.status === 'X' && !r._removed) hints.push(h('p', { class: 'help' }, 'Not shown to residents'));
    if (r.status === 'O' && pn === 100) hints.push(h('p', { class: 'hint-inline warning-ink' }, icon('i-warn', 'i i-sm'), 'At 100% but Open. ', btn('Mark Full', 'btn-tertiary btn-sm', () => set({ status: 'F' }), { id: `f-${id}-markfull` })));
    else if (r.status === 'O' && pn >= 85) hints.push(h('p', { class: 'hint-inline warning-ink' }, icon('i-warn', 'i i-sm'), 'Residents will see Almost full'));
  }
  const detail = [M.table[r.status]?.detail, kind === 'floods' && FLOOD_LEVEL[r.level] && `${FLOOD_LEVEL[r.level]} risk area`].filter(Boolean).join(' · ');
  const rowWarn = ed.d.val.warnings.filter((w) => w.rowId === id);
  const menu = menuBtn(`More actions for ${r.name || who}`, `f-${id}-menu`, () => [!r._removed && { label: 'Put on map', run: () => putOnMap(kind, r) },
    r._removed ? { label: 'Restore', run: () => set({ _removed: false }) } : { label: 'Remove', danger: true, run: () => { edited(); if (r._orig == null) rows.splice(rows.indexOf(r), 1); else r._removed = true; update([kind]); } }].filter(Boolean));
  return h('li', { class: 'item' + (state ? ' is-' + state : ''), id: 'row-' + id },
    h('span', { class: 'pos', 'aria-label': pos ? `SMS position ${pos}` : 'Removed' }, pos ? '#' + pos : '—'),
    h('div', { class: 'item-name' }, h('label', { for: nameId, class: i === 0 ? 'label' : 'sr-only' }, i === 0 ? M.noun : `${M.noun} ${pos ?? ''} name`), i === 0 && h('span', { class: 'sr-only' }, ` ${pos ?? ''} name`), name),
    h('div', { class: 'item-ctrls' }, ctrls), h('div', { class: 'item-menu' }, menu),
    h('div', { class: 'item-foot' },
      state === 'changed' && badge('info', 'Changed', 'i-info'), state === 'new' && badge('info', 'New', 'i-plus'),
      detail && !r._removed && h('p', { class: 'detail' }, detail), hints,
      state === 'changed' && h('p', { class: 'was' }, `was: ${changes.map((c) => c.was).join(', ')} `, btn('Undo', 'btn-tertiary btn-sm', () => set({ ...o }), { id: `f-${id}-undo`, ic: 'i-undo' })),
      r._removed && h('p', { class: 'was' }, badge('neutral', 'Removed', 'i-block'), ' ', btn('Restore', 'btn-tertiary btn-sm', () => set({ _removed: false }), { id: `f-${id}-restore`, ic: 'i-undo' })),
      rowWarn.map((w) => warnLine(w)),
      errs.map((e) => h('p', { class: 'err', id: e.fieldId + '-err' }, icon('i-error', 'i i-sm'), e.msg))));
}
function putOnMap(kind, r) {
  const cat = { floods: 'flood', evac: 'evacuation', roads: 'road' }[kind];
  ed.pin.adding = { category: cat, label: String(r.name).trim().slice(0, 40), status: PIN_CATS[cat].statuses.includes(r.status) ? r.status : PIN_CATS[cat].def, intensity: kind === 'evac' && int0100(intStr(r.percentFull)) ? intStr(r.percentFull) : 50 };
  ed.pin.form = null; update(['map']); scrollToSec('map');
  if (!ed.map) startPinForm(null);
}
// --- Section 8: Activity ---
function secActivity() {
  const u = ed.base.update, log = Array.isArray(u?.lguLog) ? u.lguLog.slice(0, 10) : [], hist = historyOf(ed.primary);
  const newest = Date.parse(log[0]?.publishedAt) || 0, upd = Date.parse(ed.base.updatedAt) || 0;
  return h('div', { class: 'card' }, cardHead('i-clock', 'Activity', null),
    ed.base.updatedAt && h('p', { class: 'muted' }, `Last server update ${whenText(ed.base.updatedAt)}`, upd > newest + 60e3 && log.length ? ' (PAGASA sync or another tool)' : ''),
    h('h3', null, 'Recent publishes for this town'),
    log.length ? h('ul', { class: 'log' }, log.map((m) => h('li', null, h('span', { class: 'num' }, whenText(m.publishedAt)), h('strong', null, m.publishedBy || 'unknown'), h('span', null, m.summary || '')))) : h('p', { class: 'muted' }, 'No publishes recorded yet.'),
    h('p', { class: 'tiny muted' }, 'Recorded by the NIMBUS dashboard. Not an official audit log.'),
    h('h3', null, 'Published from this device'),
    hist.length ? h('ul', { class: 'log' }, hist.map((x, i) => h('li', { class: 'hist' }, h('div', null, h('span', { class: 'num' }, whenText(x.at)), h('strong', null, x.by), x.unpublished ? badge('neutral', 'Not published', 'i-dash') : (x.codes || []).map((c) => h('span', { class: 'tiny' }, `${c.ok ? '✓' : '✕'} ${c.code} `)), x.verified && badge('ok', 'Verified')),
      histLines(x.lines), h('div', { class: 'hist-actions' }, btn('View', 'btn-tertiary btn-sm', () => viewHistory(i)), btn('Load into draft', 'btn-tertiary btn-sm', () => loadIntoDraft(x.lgu)))))) : h('p', { class: 'muted' }, 'Nothing published from this device yet.'));
}
function histLines(lines) {
  const ul = h('ul', { class: 'hist-lines' }, lines.slice(0, 3).map((l) => h('li', null, l)));
  if (lines.length > 3) { const more = btn(`Show all ${lines.length}`, 'btn-tertiary btn-sm', () => { ul.replaceChildren(...lines.map((l) => h('li', null, l))); more.remove(); }); return [ul, more]; }
  return ul;
}
function loadIntoDraft(lgu) { edited(); ed.draft = draftOnto(ed.baseLgu, normalize(lgu)); ed.mode = 'draft'; update(SECTIONS.map((s) => s[0])); toast('Loaded into the draft. Review to publish.', { sev: 'info' }); }
// --- Resident preview (rail, sheet and review use the same renderer) ---
function previewNode(lgu, isDraft, updatedAt) {
  const tab = uiPrefs().previewTab === 'sms' ? 'sms' : 'app', idp = 'pv' + Math.random().toString(36).slice(2, 7);
  const panel = h('div', { role: 'tabpanel', id: idp + '-panel', 'aria-labelledby': `${idp}-${tab}` });
  const tabs = h('div', { role: 'tablist', class: 'tabs', 'aria-label': 'Preview type' }, [['app', 'App'], ['sms', 'SMS']].map(([v, t]) => h('button', { type: 'button', role: 'tab', id: `${idp}-${v}`, 'aria-selected': String(tab === v), 'aria-controls': idp + '-panel', tabindex: tab === v ? '0' : '-1',
    onclick: () => { setPref('previewTab', v); const n = previewNode(lgu, isDraft, updatedAt); wrap.replaceWith(n); n.querySelector(`[role=tab][aria-selected=true]`)?.focus(); },
    onkeydown: (e) => { if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') { e.preventDefault(); e.currentTarget.parentNode.querySelector(`[role=tab]:not([aria-selected=true])`).click(); } } }, t)));
  const has = isDraft || !!ed.base.update;
  panel.append(tab === 'app' ? appPreview(has ? lgu : null, isDraft, updatedAt) : smsPreview({ ...(isObj(ed.base.update) ? ed.base.update : {}), ...lgu }));
  const wrap = h('div', { class: 'preview' }, tabs, panel);
  return wrap;
}
function appPreview(lgu, isDraft, updatedAt) {
  const town = ed.loc.name, dg = digest(lgu, town);
  const row = (ic, sev, name, word, detail, pct) => h('li', { class: 'pv-row' }, icon(ic, 'i i-sm ' + sev + '-ink'), h('div', null, h('p', null, h('span', { class: 'pv-name' }, name), ' · ', h('span', { class: sev + '-ink pv-word' }, word), pct != null && h('span', { class: 'num' }, ` · ${pct}%`)),
    pct != null && h('span', { class: 'meter meter-sm' }, h('span', { class: 'meter-fill ' + sev, style: `width:${Math.max(0, Math.min(100, pct))}%` })), detail && h('p', { class: 'pv-detail' }, detail)));
  const pins = (cat) => (lgu?.mapPins || []).filter((p) => p.category === cat).map((p) => row('i-pin', pinSev(p), p.label, pinWord(p), cat === 'evacuation' ? '' : pinAmount(p), cat === 'evacuation' ? p.intensity : null));
  const group = (title, kind, rows, cat) => (rows.length || pins(cat).length ? h('section', { class: 'pv-group' }, h('h4', null, title, h('span', { class: 'pv-sum' }, sectionSummary(kind, rows))),
    h('ul', null, previewSort(kind, rows).map((r) => kind === 'evac' ? row(EVAC_STATUS[r.status]?.icon || 'i-home', evacSev(r), r.name, evacWord(r), r.status === 'X' ? '' : EVAC_STATUS[r.status]?.detail, r.status === 'X' ? null : r.percentFull)
      : row(LISTS[kind].table[r.status]?.icon || 'i-dash', LISTS[kind].table[r.status]?.sev || 'neutral', r.name, LISTS[kind].table[r.status]?.word || String(r.status), kind === 'floods' ? [FLOOD_STATUS[r.status]?.detail, FLOOD_LEVEL[r.level] && `${FLOOD_LEVEL[r.level]} risk area`].filter(Boolean).join(' · ') : ROAD_STATUS[r.status]?.detail)), pins(cat))) : null);
  return h('div', { class: 'phone' }, h('div', { class: 'digest-sm' }, digestBanner(dg)), h('p', { class: 'tiny muted' }, isDraft ? 'Updated just now' : `Updated ${whenText(updatedAt)}`),
    lgu && [group('Flood areas', 'floods', lgu.floodAreas, 'flood'), group('Evacuation centers', 'evac', lgu.evacuationCenters, 'evacuation'), group('Roads', 'roads', lgu.roadStatuses, 'road'),
      h('section', { class: 'pv-group' }, h('h4', null, 'Classes'), h('ul', null, row('i-school', lgu.classes > 0 ? 'warning' : 'ok', CLASSES[lgu.classes] ?? String(lgu.classes), lgu.classes > 0 ? 'Classes suspended' : 'Classes as usual'))),
      lgu.notice && h('section', { class: 'pv-group' }, h('h4', null, 'Advisory'), h('p', { class: 'pv-notice' }, String(lgu.notice)))]);
}
function smsPreview(u) {
  return h('div', { class: 'sms' }, buildReplies(u, ed.smsCode).map((r) => h('div', { class: 'sms-item' }, h('p', { class: 'sms-label' }, `${r.label} (${r.type})`), h('p', { class: 'bubble' }, r.sms),
    h('p', { class: 'tiny num ' + (r.len > r.limit ? 'danger-ink' : 'muted') }, r.len > r.limit ? [icon('i-warn', 'i i-xs'), ` ${r.len}/${r.limit} · ${r.parts} texts (estimate)`] : `${r.len}/${r.limit} (estimate)`, r.unicode && ' · Unicode'),
    h('p', { class: 'tiny' }, r.decoded), r.notes.map((n) => h('p', { class: 'tiny muted' }, n)))),
  h('p', { class: 'tiny muted' }, 'SMS-only phones show names from their bundled list by number.'), ALIAS_CODES.has(ed.smsCode) && h('p', { class: 'tiny muted' }, `SMS users here text code ${ed.smsCode}. ${WEATHER_NOTE}`));
}
const renderPreviewRail = debounce(() => {
  if (!ed?.d) return; const r = $('preview-rail');
  if (getComputedStyle(r).display === 'none') return;
  r.replaceChildren(h('div', { class: 'pv-head' }, h('h2', null, 'What residents see'), ed.d.dirty && badge('info', 'Draft preview', 'i-info')), previewNode(ed.d.lgu, ed.d.dirty, ed.base.updatedAt));
}, 150);
function openPreviewSheet() {
  if (!ed?.d) return;
  dlgOpen('preview-sheet', { title: 'What residents see', sub: ed.d.dirty ? 'Draft preview: not live yet' : 'Live now', body: previewNode(ed.d.lgu, ed.d.dirty, ed.base.updatedAt), foot: btn('Close', 'btn-secondary', () => $('preview-sheet').close()), cls: 'sheet' });
}

// ===== §9 MAP =====
function initMapSection() {
  const host = $('sec-map'); ed.map = null;
  const box = h('div', { class: 'map-box' }, h('div', { id: 'map', class: 'map', role: 'region', 'aria-label': `Map of ${ed.loc.name}. The pin list below has the same pins.` }),
    h('div', { class: 'map-legend' }, Object.entries(PIN_CATS).map(([c, p]) => h('span', null, h('span', { class: `pin-mini pin--${c}` }, icon(p.glyph, 'i i-xs')), p.word))), h('div', { class: 'map-hint', id: 'map-hint', hidden: true }, 'Use Ctrl + scroll to zoom'));
  host.replaceChildren(h('div', { class: 'card' }, cardHead('i-pin', 'Map pins', '', null, 'sum-map'), h('div', { id: 'map-toolbar', class: 'map-toolbar' }),
    h('div', { class: 'map-layout' }, box, h('div', { id: 'pin-form-slot' })), h('div', { id: 'pin-list-slot' })));
  if (!window.L) { $('map').replaceChildren(h('p', { class: 'map-fail' }, 'The map could not load. Use the pin list and Edit coordinates instead.')); updateMap(); return; }
  const c = ed.loc.latitude != null ? [ed.loc.latitude, ed.loc.longitude] : [12.88, 121.77];
  const m = L.map('map', { scrollWheelZoom: false, keyboard: true }).setView(c, ed.loc.latitude != null ? 13 : 6);
  L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 19, attribution: '&copy; OpenStreetMap' }).addTo(m);
  ed.map = { m, layer: L.layerGroup().addTo(m) };
  m.on('click', (e) => { if (ed.pin.adding) startPinForm(null, e.latlng); });
  const el = $('map'); let ht;
  el.addEventListener('wheel', (e) => { if (e.ctrlKey) { e.preventDefault(); m.setZoom(m.getZoom() + (e.deltaY < 0 ? 1 : -1)); } else { $('map-hint').hidden = false; clearTimeout(ht); ht = setTimeout(() => { const x = $('map-hint'); if (x) x.hidden = true; }, 1500); } }, { passive: false });
  if (matchMedia('(pointer: coarse)').matches) {
    m.dragging.disable();
    const ov = btn('Tap to move the map', 'btn-secondary btn-sm map-move', () => { const on = !m.dragging.enabled(); on ? m.dragging.enable() : m.dragging.disable(); ov.textContent = on ? 'Done' : 'Tap to move the map'; });
    box.append(ov);
  }
  new ResizeObserver(() => m.invalidateSize()).observe(el);
  updateMap();
}
function updateMap() {
  if (!ed || !$('map-toolbar')) return;
  const P = ed.pin, adding = !!P.adding;
  $('map-toolbar').replaceChildren(h('button', { type: 'button', class: 'btn btn-secondary btn-sm', id: 'pin-add', 'aria-pressed': String(adding), onclick: () => { P.adding = adding ? null : { category: 'flood', label: '', status: 'W', intensity: 5 }; P.form = null; updateMap(); if (P.adding && !ed.map) startPinForm(null); } }, icon(adding ? 'i-close' : 'i-plus', 'i i-sm'), adding ? 'Cancel adding' : 'Add pin'),
    adding && h('span', { class: 'help', role: 'status' }, 'Click the map to place the pin · Esc to cancel'));
  $('map')?.classList.toggle('is-adding', adding && !P.form);
  $('pin-form-slot').replaceChildren(P.form ? pinForm() : '');
  $('map-box-wrap')?.remove();
  document.querySelector('.map-layout')?.classList.toggle('has-form', !!P.form);
  renderPinList(); renderMarkers();
}
function pinIconEl(p, extra = '') {
  const el = h('div', { class: `pin pin--${p.category} sev-${pinSev(p)} ${extra}` }, icon(PIN_CATS[p.category]?.glyph || 'i-pin', 'i i-sm'));
  return h('div', { class: 'pin-holder' }, el, p.category !== 'evacuation' && int0100(intStr(p.intensity)) && h('span', { class: 'pin-tag' }, p.category === 'flood' ? `${floodM(intStr(p.intensity)).toFixed(1)} m` : `${intStr(p.intensity)}%`));
}
function renderMarkers() {
  if (!ed.map) return; const { layer, m } = ed.map, P = ed.pin; layer.clearLayers();
  const mk = (p, extra, lat, lng, drag) => {
    const mark = L.marker([lat, lng], { icon: L.divIcon({ className: 'pin-wrap', html: pinIconEl(p, extra), iconSize: [32, 40], iconAnchor: [16, 40] }), title: `${p.label || 'New pin'}: ${pinWord(p)}`, keyboard: true, draggable: drag, alt: `${p.label}: ${pinWord(p)}` });
    if (drag) mark.on('dragend', () => { const ll = mark.getLatLng(); P.form.latitude = +ll.lat.toFixed(6); P.form.longitude = +ll.lng.toFixed(6); $('pin-form-slot').replaceChildren(pinForm()); });
    return mark.addTo(layer);
  };
  for (const p of ed.draft.mapPins) {
    if (p._removed || typeof p.latitude !== 'number' || typeof p.longitude !== 'number' || !Number.isFinite(p.latitude)) continue;
    const editing = P.form?.id === p._id, f = editing ? P.form : p;
    if (!Number.isFinite(f.latitude) || !Number.isFinite(f.longitude)) continue;
    mk(editing ? { ...p, ...P.form } : p, P.sel === p._id || editing ? 'is-selected' : '', f.latitude, f.longitude, editing).on('click', () => editPin(p._id));
  }
  if (P.form && !P.form.id && Number.isFinite(P.form.latitude) && Number.isFinite(P.form.longitude)) mk(P.form, 'is-draft is-selected', P.form.latitude, P.form.longitude, true);
  void m;
}
function startPinForm(id, latlng) {
  const P = ed.pin, pre = P.adding || { category: 'flood', label: '', status: 'W', intensity: 5 };
  const c = latlng || (ed.loc.latitude != null ? { lat: ed.loc.latitude, lng: ed.loc.longitude } : { lat: NaN, lng: NaN });
  P.form = { id: null, ...pre, latitude: +Number(c.lat).toFixed(6), longitude: +Number(c.lng).toFixed(6), tried: false, coords: !latlng };
  P.adding = null; updateMap(); setTimeout(() => $('pf-label')?.focus(), 0);
}
function editPin(id) {
  const p = ed.draft.mapPins.find((x) => x._id === id); if (!p) return;
  ed.pin.sel = id; ed.pin.adding = null; ed.pin.form = { id, category: p.category, label: p.label, status: p.status, intensity: p.intensity, latitude: p.latitude, longitude: p.longitude, tried: false };
  if (ed.map && Number.isFinite(p.latitude)) ed.map.m.panTo([p.latitude, p.longitude]);
  updateMap(); setTimeout(() => $('pf-label')?.focus(), 0);
}
function pinForm() {
  const f = ed.pin.form, cat = PIN_CATS[f.category] ? f.category : 'flood', errs = f.tried ? pinErrors(f) : [], names = [...new Set(KINDS.flatMap((k) => ed.draft[LISTS[k].key].map((r) => String(r.name).trim())).filter(Boolean))];
  const smsLabel = () => cleanNotice(f.label).replace(/\|/g, ' ').replace(/\s+/g, '_') || '(empty)';
  const re = () => { $('pin-form-slot').replaceChildren(pinForm()); renderMarkers(); };
  const isFlood = cat === 'flood';
  const shown = (v) => isFlood ? `${floodM(v).toFixed(1)} m · ${ftOf(floodM(v))} ft` : v + '%';
  const num = isFlood
    ? h('input', { id: 'pf-int-n', class: 'input pct', type: 'number', inputmode: 'decimal', min: '0', max: '10', step: '0.1', value: floodM(f.intensity).toFixed(1), 'aria-label': 'Flood height in metres', oninput: (e) => { const v = Math.round(Number(e.target.value) * 10); if (Number.isFinite(v) && v >= 0 && v <= 100) { f.intensity = v; $('pf-int').value = v; $('pf-out').value = shown(v); } } })
    : h('input', { id: 'pf-int-n', class: 'input pct', inputmode: 'numeric', value: String(f.intensity), 'aria-label': (cat === 'evacuation' ? 'Occupancy' : 'Severity') + ' percent', oninput: (e) => { f.intensity = e.target.value; const v = intStr(e.target.value); if (int0100(v)) { $('pf-int').value = v; $('pf-out').value = v + '%'; } } });
  const coordIn = (k, lab) => h('label', { class: 'field-inline' }, lab, h('input', { class: 'input', type: 'number', step: 'any', id: 'pf-' + k, value: Number.isFinite(f[k]) ? String(f[k]) : '', oninput: (e) => { f[k] = e.target.value === '' ? NaN : Number(e.target.value); }, onchange: re }));
  const cancel = () => { ed.pin.form = null; ed.pin.sel = null; updateMap(); $('pin-add')?.focus(); };
  const save = () => {
    f.tried = true; f.intensity = intStr(f.intensity);
    if (pinErrors(f).length) { re(); $('pf-label')?.focus(); return; }
    edited(); const vals = { category: cat, label: String(f.label).trim(), status: f.status, intensity: f.intensity, latitude: f.latitude, longitude: f.longitude };
    if (f.id) Object.assign(ed.draft.mapPins.find((x) => x._id === f.id), vals); else ed.draft.mapPins.push({ ...vals, _id: uid(), _orig: null, _removed: false });
    ed.pin.form = null; ed.pin.sel = null; update(['map']); $('pin-add')?.focus();
  };
  return h('div', { class: 'pin-form', role: 'group', 'aria-labelledby': 'pf-title', onkeydown: (e) => { if (e.key === 'Escape') { e.stopPropagation(); cancel(); } } },
    h('h3', { id: 'pf-title' }, f.id ? 'Edit pin' : 'New pin'),
    seg({ name: 'pf-cat', legend: 'Pin type', idp: 'pf-cat', value: cat, options: Object.entries(PIN_CATS).map(([v, p]) => ({ value: v, word: p.word, icon: p.glyph })), onChange: (v) => { f.category = v; f.status = PIN_CATS[v].def; re(); } }),
    h('div', { class: 'field' }, h('label', { for: 'pf-label', class: 'label' }, 'Speech bubble text'),
      h('input', { id: 'pf-label', class: 'input', value: f.label, maxlength: '40', list: 'pf-names', autocomplete: 'off', oninput: (e) => { f.label = e.target.value; $('pf-count').textContent = `${f.label.length}/40`; $('pf-sms').textContent = 'SMS: ' + smsLabel(); } }),
      h('datalist', { id: 'pf-names' }, names.map((n) => h('option', { value: n }))), h('p', { class: 'help' }, h('span', { id: 'pf-count', class: 'num' }, `${String(f.label).length}/40`), ' · ', h('code', { id: 'pf-sms' }, 'SMS: ' + smsLabel()))),
    h('div', { class: 'field' }, h('span', { class: 'label' }, 'Status'), seg({ name: 'pf-status', legend: 'Pin status', idp: 'pf-st', value: f.status, options: PIN_CATS[cat].statuses.map((v) => ({ value: v, word: PIN_WORD[cat][v], sev: pinSev({ category: cat, status: v, intensity: 0 }), icon: SEV[pinSev({ category: cat, status: v, intensity: 0 })].icon })), onChange: (v) => { f.status = v; re(); } })),
    h('div', { class: 'field' }, h('label', { for: 'pf-int', class: 'label' }, isFlood ? 'Flood height (metres)' : cat === 'evacuation' ? 'Occupancy' : 'Severity'),
      h('div', { class: 'range-row' }, h('input', { id: 'pf-int', type: 'range', min: '0', max: '100', step: isFlood ? '1' : '5', value: String(int0100(intStr(f.intensity)) ? intStr(f.intensity) : isFlood ? 5 : 50), oninput: (e) => { f.intensity = Number(e.target.value); num.value = isFlood ? floodM(e.target.value).toFixed(1) : e.target.value; $('pf-out').value = shown(e.target.value); } }), num, h('output', { id: 'pf-out', for: 'pf-int' }, shown(f.intensity))),
      isFlood && h('p', { class: 'help' }, 'Knee-high ≈ 0.5 m · waist-high ≈ 1 m · above head ≈ 2 m.')),
    h('details', { open: f.coords || !Number.isFinite(f.latitude) }, h('summary', null, 'Edit coordinates'), h('div', { class: 'coords' }, coordIn('latitude', 'Latitude'), coordIn('longitude', 'Longitude'))),
    Number.isFinite(f.latitude) && Number.isFinite(f.longitude) && h('p', { class: 'tiny muted num' }, `${Number(f.latitude).toFixed(5)}, ${Number(f.longitude).toFixed(5)}${ed.map ? ' · drag the pin to adjust' : ''}`),
    errs.map((e) => h('p', { class: 'err' }, icon('i-error', 'i i-sm'), e)),
    h('div', { class: 'form-actions' }, btn('Cancel', 'btn-secondary', cancel, { id: 'pf-cancel' }), btn(f.id ? 'Save pin' : 'Add pin', 'btn-primary', save, { id: 'pf-save' })));
}
function renderPinList() {
  const pins = ed.draft.mapPins, slot = $('pin-list-slot');
  if (!pins.length) return slot.replaceChildren(empty('i-pin', 'No pins on the map yet. Click the map to add one.'));
  slot.replaceChildren(h('ul', { class: 'pin-list' }, pins.map((p) => {
    const o = p._orig != null ? ed.baseLgu.mapPins[p._orig] : null, ch = o && !p._removed ? pinChanges(o, p) : [];
    const errs = ed.d.val.errors.filter((e) => e.rowId === p._id), ws = ed.d.val.warnings.filter((w) => w.rowId === p._id);
    const st = p._removed ? 'removed' : p._orig == null ? 'new' : ch.length ? 'changed' : '';
    const set = (patch) => { edited(); Object.assign(p, patch); update(['map']); };
    return h('li', { class: 'pin-row' + (st ? ' is-' + st : '') + (ed.pin.sel === p._id ? ' is-sel' : '') },
      h('span', { class: `pin-mini pin--${p.category}` }, icon(PIN_CATS[p.category]?.glyph || 'i-pin', 'i i-xs')),
      h('div', { class: 'pin-main' }, h('p', null, h('strong', null, p.label || '(no label)'), ' ', h('span', { class: 'muted' }, PIN_CATS[p.category]?.word || p.category)),
        h('p', null, badge(pinSev(p), pinWord(p)), ` ${pinAmount(p)}`, st === 'changed' && ' ', st === 'changed' && badge('info', 'Changed', 'i-info'), st === 'new' && ' ', st === 'new' && badge('info', 'New', 'i-plus')),
        errs.map((e) => h('p', { class: 'err' }, icon('i-error', 'i i-sm'), e.msg)), ws.map((w) => warnLine(w))),
      h('div', { class: 'pin-actions' }, !p._removed && btn('Show on map', 'btn-tertiary btn-sm', () => editPin(p._id), { id: 'pin-' + p._id }),
        p._removed ? btn('Restore', 'btn-tertiary btn-sm', () => set({ _removed: false }), { id: `pin-${p._id}-restore` })
          : btn('Remove', 'btn-tertiary btn-sm', () => { edited(); if (p._orig == null) pins.splice(pins.indexOf(p), 1); else p._removed = true; if (ed.pin.form?.id === p._id) ed.pin.form = null; update(['map']); }, { id: `pin-${p._id}-remove` })));
  })));
}

// ===== §10 DIALOGS =====
function dlgOpen(id, { title, sub, body, foot, cls = '' }) {
  const d = $(id); d.className = 'dlg ' + cls;
  d.replaceChildren(h('div', { class: 'dlg-head' }, h('div', null, h('h2', { id: id + '-t' }, title), sub && h('p', { class: 'sub' }, sub)), iconBtn('i-close', 'Close', () => { if (!d.dataset.busy) d.close('cancel'); }, { id: id + '-x' })),
    h('div', { class: 'dlg-body' }, body), h('div', { class: 'dlg-foot' }, foot));
  d.setAttribute('aria-labelledby', id + '-t'); if (!d.open) d.showModal();
  return d;
}
const onClose = (d) => new Promise((res) => d.addEventListener('close', () => res(d.returnValue), { once: true }));
function confirmDlg({ title, body, ok, cancel = 'Cancel', danger }) {
  const d = dlgOpen('confirm', { title, body: h('p', null, body), foot: [btn(cancel, 'btn-secondary', () => d.close('no'), { id: 'cf-no' }), btn(ok, danger ? 'btn-danger' : 'btn-primary', () => d.close('yes'))] });
  $('cf-no').focus(); return onClose(d).then((v) => v === 'yes');
}
// 10.1 Review & publish
async function openReview(mode = 'edit') {
  if (!ed?.d) return;
  if (S.ui.readOnly) { try { await reauth(false); } catch { return; } }
  ed.showAll = true; update(KINDS.concat('classes', 'map'));
  ed.reviewMode = mode; ed.reviewInfo = null;
  try {
    const fresh = await getTown(ed.primary);
    if (fresh.updatedAt !== ed.base.updatedAt) {
      if (lguEqual(fresh.update, ed.baseLgu) || (ed.acceptedLgu && lguEqual(fresh.update, ed.acceptedLgu))) { ed.reviewInfo = `Live data changed at ${whenText(fresh.updatedAt)} (PAGASA sync). Your changes go on top; nothing is lost.`; ed.base = fresh; update(['pagasa', 'activity']); }
      else if (!(await resolveConflict(fresh))) return;
    }
  } catch (e) { if (e.kind === 'cancelled') return; ed.reviewInfo = `Couldn't check the live copy (${errText(e)}). It is checked again when you publish.`; }
  renderReview(); $('rv-back')?.focus();
}
// Returns true to continue publishing the draft over the fresh copy.
async function resolveConflict(fresh) {
  const c = await conflictDialog(fresh);
  if (c === 'load') {
    addHistory(ed.primary, { at: new Date().toISOString(), by: S.session.username, lines: ['Discarded draft', ...ed.d.diff.lines.map((l) => l.text)], lgu: ed.d.lgu, codes: [], verified: false, unpublished: true });
    store.del(draftKey(ed.primary)); loadBase(fresh); ed.mode = null; update(SECTIONS.map((s) => s[0]));
    toast('Loaded the latest version. Your changes were discarded.', { sev: 'info' }); return false;
  }
  if (c === 'mine') { ed.acceptedLgu = normalize(fresh.update); ed.base = fresh; update(['pagasa', 'activity']); return true; }
  return false;
}
function renderReview() {
  const d = ed.d, loc = ed.loc, v = d.val, mode = ed.reviewMode, errs = v.errors;
  const ws = [...v.warnings];
  if (ed.legacy && !ed.legacyWritable) ws.push({ msg: `SMS users here text code ${ed.legacy}, which this account can't publish. Ask an admin to add it.` });
  if (ed.reviewInfo) ws.push({ info: true, msg: ed.reviewInfo });
  const groups = new Map(); for (const l of d.diff.lines) { if (!groups.has(l.section)) groups.set(l.section, []); groups.get(l.section).push(l); }
  const tag = { added: ['ok-ink', '+ Added'], changed: ['primary-ink', '~ Changed'], removed: ['danger-ink', '− Removed'], info: ['muted', 'Info'] };
  const lineEl = (l) => h('li', { class: 'diff-line' }, h('span', { class: 'diff-tag ' + tag[l.kind][0] }, tag[l.kind][1]), h('div', null,
    l.from ? h('p', null, `${l.name}: `, badge(l.from[1], l.from[0]), ' → ', badge(l.to[1], l.to[0])) : h('p', null, l.text.replace(/^(Added|Removed): /, '')),
    l.words !== undefined && (l.words ? h('p', { class: 'wdiff' }, l.words.map(([op, t]) => (op === '=' ? t : h(op === '-' ? 'del' : 'ins', null, t)))) : h('div', { class: 'wdiff' }, h('p', null, h('del', null, l.old)), h('p', null, h('ins', null, l.now))))));
  const changes = !d.diff.lines.length ? h('p', { class: 'muted' }, 'No changes. This republishes the current status so residents see a fresh "Updated" time.')
    : [...groups.entries()].map(([sec, ls]) => { const ul = h('ul', { class: 'diff' }, ls.slice(0, 8).map(lineEl)); return h('div', { class: 'diff-group' }, h('h4', null, SECTIONS.find((s) => s[0] === sec)?.[1] || sec), ul, ls.length > 8 && btn(`Show all ${ls.length}`, 'btn-tertiary btn-sm', (e) => { ul.replaceChildren(...ls.map(lineEl)); e.currentTarget.remove(); })); });
  const pub = errs.length ? btn(`Fix ${plural(errs.length, 'problem', 'problems')} first`, 'btn-primary', () => errs[0] && jumpTo(errs[0]), { id: 'rv-publish', 'aria-disabled': 'true' })
    : btn(`Publish to ${loc.name}`, 'btn-primary', () => doPublish(), { id: 'rv-publish', ic: 'i-send' });
  dlgOpen('review', {
    title: `Publish to ${loc.name}${loc.province ? ', ' + loc.province : ''}?`, sub: `Writes to ${ed.primary}${ed.legacy && ed.legacyWritable ? ' and SMS code ' + ed.legacy : ''}. Residents see it in the app and SMS replies right away.`,
    body: [errs.length > 0 && h('div', { class: 'box danger', role: 'alert' }, h('h3', null, icon('i-error', 'i i-sm'), 'Fix before publishing'), h('ul', null, errs.map((e) => h('li', null, h('button', { type: 'button', class: 'link', onclick: () => jumpTo(e) }, `${SECTIONS.find((s) => s[0] === e.section)?.[1]}: ${e.msg}`))))),
      ws.length > 0 && h('div', { class: 'box warning' }, h('h3', null, icon('i-warn', 'i i-sm'), 'Check these'), ws.map((w) => warnLine(w, renderReview))),
      h('h3', null, 'What changes'), changes,
      h('p', { class: 'kept' }, icon('i-lock', 'i i-sm'), 'Kept as-is: PAGASA signal, rain, gusts and bulletin stay unchanged.'),
      h('label', { class: 'check' }, h('input', { type: 'checkbox', id: 'rv-alert', checked: !!ed.alertSubs, onchange: (e) => { ed.alertSubs = e.target.checked; } }),
        ` Text this update now to residents subscribed to SMS alerts for ${loc.name}`),
      h('h3', null, 'Preview'), previewNode(d.lgu, true, null)],
    foot: [btn('Back to editing', 'btn-secondary', () => $('review').close(), { id: 'rv-back' }), pub],
  });
  void mode;
}
function jumpTo(e) {
  $('review').close(); ed.showAll = true; update([e.section]);
  if (e.section === 'map' && e.rowId) editPin(e.rowId);
  const el = $(e.fieldId) || $('sec-' + e.section); el?.scrollIntoView({ block: 'center', behavior: reduced() ? 'auto' : 'smooth' }); el?.focus?.({ preventScroll: true });
}
// 10.2 Conflict
function conflictDialog(fresh) {
  const their = normalize(fresh.update), lines = diff(ed.baseLgu, draftOnto(ed.baseLgu, their), ed.loc.name).lines, by = fresh.update?.lguMeta?.publishedBy || 'unknown';
  const mine = btn('Publish mine anyway', 'btn-secondary', () => { if (mine.dataset.armed) return d.close('mine'); mine.dataset.armed = '1'; mine.textContent = 'Yes, publish mine'; $('cx-warn').hidden = false; });
  const d = dlgOpen('conflict', { title: `Someone else published ${ed.loc.name} at ${whenText(fresh.updatedAt)}`, sub: `Their update: ${by}.`,
    body: [h('h3', null, 'Their changes'), lines.length ? h('ul', { class: 'diff' }, lines.map((l) => h('li', null, l.text))) : h('p', { class: 'muted' }, 'Their LGU fields differ from the version your draft started from.'),
      h('p', { class: 'box warning', id: 'cx-warn', hidden: true }, 'This replaces their flood, evacuation, road, class and advisory changes.')],
    foot: [btn('Cancel', 'btn-tertiary', () => d.close('cancel'), { id: 'cx-cancel' }), mine, btn('Load their version', 'btn-primary', () => d.close('load'))] });
  $('cx-cancel').focus(); return onClose(d);
}
// 10.3 Re-auth: resolves after a successful sign-in; rejects {kind:'cancelled'}.
let reauthP = null;
function reauth(voluntary) {
  if (reauthP) return reauthP;
  reauthP = new Promise((resolve, reject) => {
    const err = h('div', { class: 'banner danger', role: 'alert', hidden: true }, icon('i-error'), h('p'));
    const pass = h('input', { id: 'ra-pass', type: 'password', class: 'input', autocomplete: 'current-password', required: true });
    const submit = h('button', { type: 'submit', class: 'btn btn-primary', id: 'ra-go' }, 'Sign in');
    let ok = false;
    const form = h('form', { id: 'ra-form', onsubmit: async (e) => {
      e.preventDefault(); err.hidden = true; setBusy(submit, 'Signing in…');
      try { await signIn(S.session.username, pass.value, S.session.persist); ok = true; clearBanner('session'); renderTopbar(); if (ed) renderBar(); d.close('ok'); toast('Signed in again.', { sev: 'ok' }); }
      catch (x) { err.hidden = false; err.querySelector('p').textContent = x.status === 401 ? 'Username or password is incorrect.' : errText(x); setBusy(submit); }
    } }, h('div', { class: 'field' }, h('label', { for: 'ra-user', class: 'label' }, 'Username'), h('input', { id: 'ra-user', class: 'input', value: S.session.username, readOnly: true, autocomplete: 'username' })),
      h('div', { class: 'field' }, h('label', { for: 'ra-pass', class: 'label' }, 'Password'), pass), err);
    const d = dlgOpen('reauth', { title: voluntary ? 'Extend your session' : 'Sign in again to continue', sub: voluntary ? 'Your changes are still here.' : 'Your session ended. Your changes are still here.', body: form,
      foot: [btn('Cancel', 'btn-secondary', () => d.close('cancel')), submit] });
    submit.setAttribute('form', 'ra-form'); pass.focus();
    onClose(d).then(() => (ok ? resolve() : reject({ kind: 'cancelled' })));
  }).finally(() => { reauthP = null; });
  return reauthP;
}
// 10.4 Sign out with a dirty draft
function leaveDialog() {
  const d = dlgOpen('leave', { title: 'Sign out?', body: h('p', null, `You have ${plural(ed.d.diff.count || 1, 'unpublished change', 'unpublished changes')} for ${ed.loc.name}.`),
    foot: [btn('Cancel', 'btn-tertiary', () => d.close('cancel'), { id: 'lv-cancel' }), btn('Discard and sign out', 'btn-secondary', () => d.close('discard')), S.session.persist && !S.ui.storageFailed && btn('Sign out and keep draft on this device', 'btn-secondary', () => d.close('keep')), btn('Review & publish', 'btn-primary', () => d.close('review'))] });
  $('lv-cancel').focus(); return onClose(d);
}
// 10.6 Delete stored record (admins only)
function deleteDialog() {
  const name = ed.loc.name, go = btn('Delete record', 'btn-danger', async () => {
    setBusy(go, 'Deleting…'); d.dataset.busy = '1';
    try { for (const c of [ed.primary, ed.legacyWritable && ed.legacy].filter(Boolean)) await api('DELETE', `/towns/${c}/updates`, undefined, { auth: true, town: name }); delete d.dataset.busy; d.close('ok'); store.del(draftKey(ed.primary)); toast(`Deleted the stored record for ${name}.`, { sev: 'info' }); openTown(ed.code); }
    catch (e) { delete d.dataset.busy; setBusy(go); go.disabled = true; $('del-err').hidden = false; $('del-err').textContent = errText(e); }
  }, { disabled: true });
  const inp = h('input', { id: 'del-in', class: 'input', autocomplete: 'off', oninput: (e) => { go.disabled = e.target.value.trim().toLowerCase() !== name.toLowerCase(); } });
  const d = dlgOpen('delete', { title: `Delete everything stored for ${name}?`, body: [h('p', null, 'Removes LGU status AND PAGASA data for this code. Residents see "No LGU report" until the next PAGASA sync. Use Reset to all-clear instead in most cases.'),
    h('div', { class: 'field' }, h('label', { for: 'del-in', class: 'label' }, `Type ${name.toUpperCase()} to confirm`), inp), h('p', { class: 'err', id: 'del-err', hidden: true })],
  foot: [btn('Cancel', 'btn-secondary', () => d.close('cancel')), go] });
  inp.focus();
}
function viewHistory(i) {
  const hist = historyOf(ed.primary), x = hist[i], prev = hist.slice(i + 1).find((y) => !y.unpublished);
  const lgu = normalize(x.lgu), lines = prev ? diff(normalize(prev.lgu), draftOnto(normalize(prev.lgu), lgu), ed.loc.name).lines : [];
  const d = dlgOpen('history', { title: `${x.unpublished ? 'Draft' : 'Published'} ${whenText(x.at)}`, sub: `By ${x.by}`, body: [digestBanner(digest(lgu, ed.loc.name)), h('h3', null, prev ? 'Changes from the previous entry' : 'Recorded changes'),
    h('ul', { class: 'diff' }, (prev ? lines.map((l) => l.text) : x.lines).map((t) => h('li', null, t)))],
  foot: [btn('Close', 'btn-secondary', () => d.close()), btn('Load into draft', 'btn-primary', () => { d.close(); loadIntoDraft(x.lgu); })] });
}

// ===== §11 PUBLISH =====
async function doPublish() {
  const d = $('review'), b = $('rv-publish'); if (!ed?.d || ed.d.val.errors.length || d.dataset.busy) return;
  const town = ed.loc.name, primary = ed.primary, prevLgu = normalize(ed.base.update);
  d.dataset.busy = '1'; setBusy(b, 'Publishing…'); $('rv-back').disabled = true;
  const unbusy = () => { delete d.dataset.busy; if ($('rv-publish')) setBusy($('rv-publish')); if ($('rv-back')) $('rv-back').disabled = false; };
  try {
    const fresh = await getTown(primary);
    if (!lguEqual(fresh.update, ed.baseLgu) && !(ed.acceptedLgu && lguEqual(fresh.update, ed.acceptedLgu))) {
      unbusy(); d.close(); if (await resolveConflict(fresh)) openReview(ed.reviewMode); return;
    }
    const lgu = lguFromDraft(ed.draft), lines = ed.d.diff.lines.filter((l) => l.kind !== 'info').map((l) => l.text);
    const meta = { publishedAt: new Date().toISOString(), publishedBy: S.session.username, summary: lines.slice(0, 3).join('; ').slice(0, 200) || 'Reconfirmed, no changes' };
    const alertFlag = ed.alertSubs ? { alertSubscribers: true } : {};
    await api('POST', `/towns/${primary}/updates`, { ...mergeBody(fresh, lgu, meta), ...alertFlag }, { auth: true, town });
    const results = [{ code: primary, ok: true }];
    let note = '';
    if (ed.legacy && ed.legacyWritable) {
      try { const lf = await getTown(ed.legacy); await api('POST', `/towns/${ed.legacy}/updates`, { ...mergeBody(lf, lgu, meta), ...alertFlag }, { auth: true, town }); results.push({ code: ed.legacy, ok: true }); clearBanner('ed:legacy'); }
      catch (e) { results.push({ code: ed.legacy, ok: false }); legacyFailed(lgu, meta, e); }
    } else if (ed.legacy) note = ` · SMS code ${ed.legacy} not updated (no access).`;
    let after = null; try { after = await getTown(primary); } catch { /* verified stays false */ }
    const verified = !!after && lguEqual(after.update, lgu);
    addHistory(primary, { at: meta.publishedAt, by: meta.publishedBy, lines: lines.length ? lines : ['Reconfirmed, no changes'], lgu, codes: results, verified });
    store.del(draftKey(primary)); S.ui.offlineFailed = false; ed.alertSubs = false; ['ed:publish', 'ed:verify'].forEach(clearBanner);
    unbusy(); d.close();
    loadBase(after || { update: { ...mergeBody(fresh, lgu, meta), townCode: primary }, updatedAt: meta.publishedAt });
    if (ed.legacyBase !== undefined && ed.legacy) ed.legacyBase = null;
    ed.publishedAt = Date.now(); ed.mode = null; update(SECTIONS.map((s) => s[0]));
    const codes = results.map((r) => (r.code === primary ? `${r.ok ? '✓' : '✕'} App and SMS (${r.code})` : `${r.ok ? '✓' : '✕'} SMS code ${r.code}`)).join(' · ');
    toast(`${verified ? `Live and verified at ${clock(Date.now())}` : 'Published'}. ${codes}${note}`, { sev: 'ok', action: { label: 'Undo', run: () => { loadIntoDraft(prevLgu); openReview('undo'); } } });
    if (!verified) setBanner('ed:verify', { sev: 'warning', text: "Published, but the live copy doesn't match what you sent. Reload this town and check.", actions: [{ label: 'Reload', run: () => openTown(ed.code) }] });
  } catch (e) {
    unbusy();
    if (e.kind === 'cancelled') return;
    if (e.kind === 'offline') { S.ui.offlineFailed = true; setBanner('ed:publish', { sev: 'danger', text: 'Not published. No connection. Your changes are saved on this device.', actions: [{ label: 'Try again', run: () => openReview(ed.reviewMode) }] }); }
    else setBanner('ed:publish', { sev: 'danger', text: `Not published. ${errText(e)}` });
    d.close(); saveDraftNow();
  }
}
function legacyFailed(lgu, meta, e) {
  setBanner('ed:legacy', { sev: 'danger', text: `Published to ${ed.primary} but SMS code ${ed.legacy} failed: ${errText(e)}.`, actions: [{ label: 'Retry SMS code', run: async () => {
    try { const lf = await getTown(ed.legacy); await api('POST', `/towns/${ed.legacy}/updates`, mergeBody(lf, lgu, meta), { auth: true, town: ed.loc.name }); clearBanner('ed:legacy'); toast(`✓ SMS code ${ed.legacy} updated.`); }
    catch (x) { if (x.kind !== 'cancelled') legacyFailed(lgu, meta, x); }
  } }] });
}

// ===== §12 BOOT =====
async function loadLocations() {
  try {
    const list = await (await fetch('/philippine_locations.json')).json();
    for (const e of Array.isArray(list) ? list : []) { e.key = fold([e.name, e.province, e.region, e.code, e.legacyCode].filter(Boolean).join(' ')); S.loc.byCode.set(e.code, e); if (e.legacyCode) S.loc.byCode.set(e.legacyCode, e); S.loc.list.push(e); }
  } catch { /* names fall back to 'Town {code}' */ }
}
async function boot() {
  wireLogin();
  document.querySelectorAll('dialog').forEach((d) => d.addEventListener('cancel', (e) => { if (d.dataset.busy) e.preventDefault(); }));
  addEventListener('online', () => { renderTopbar(); clearBanner('offline'); if (S.ui.offlineFailed && ed) toast('Back online.', { sev: 'info', action: { label: 'Publish now', run: () => openReview(ed.reviewMode || 'edit') } }); });
  addEventListener('offline', () => { renderTopbar(); setBanner('offline', { sev: 'warning', text: "You're offline. Edits are kept on this device; publish when the connection is back." }); });
  addEventListener('beforeunload', (e) => { if (S.ui.storageFailed && ed?.d?.dirty) { e.preventDefault(); e.returnValue = ''; } });
  addEventListener('pagehide', () => { if (ed?.d?.dirty) saveDraftNow(); });
  document.addEventListener('keydown', (e) => {
    if ((e.ctrlKey || e.metaKey) && e.key === 'Enter' && ed?.d?.dirty && !document.querySelector('dialog[open]')) { e.preventDefault(); openReview('edit'); }
    if (e.key === 'Escape' && ed?.pin.adding && !document.querySelector('dialog[open]')) { ed.pin.adding = null; updateMap(); }
  });
  addEventListener('resize', debounce(() => { if (ed?.d) renderPreviewRail(); }, 200));
  setInterval(tickSession, 30000);
  await loadLocations();
  S.session = readSession();
  addEventListener('hashchange', route);
  if (S.session && expMs() > Date.now() + 60e3) { $('app').hidden = false; tickSession(); route(); }
  else if (S.session) showLogin({ username: S.session.username, expired: true });
  else showLogin();
}
window.NIMBUS = { encode, encodePins, signature, cleanNotice, normalize, validate, digest, buildReplies, mergeBody, lguFromDraft, draftFromLgu, diff };
boot();
