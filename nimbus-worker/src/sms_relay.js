// SMS relay: sms-gate.app webhook -> NB1 replies, running inside the Worker
// (replaces SMS_SendAndRecieve/reciever.py + the cloudflared tunnel).
//
// Secrets (wrangler secret put):
//   SMS_WEBHOOK_SIGNING_KEY  SMS Gateway app -> Settings -> Webhooks -> Signing Key
//   NIMBUS_SMS_SIGNING_KEY   signs replies; the app is built with the same key
//   SMS_USERNAME / SMS_PASSWORD  sms-gate.app cloud credentials of the gateway phone
import "./nimbus-codec.js";
import TOWN_COORDS from "./town_coords.js";

const Codec = globalThis.NimbusCodec;
const SMS_API = "https://api.sms-gate.app/3rdparty/v1";
const WEBHOOK_ID = "my-incoming-sms";
const MAX_BODY_BYTES = 64 * 1024;
const TIMESTAMP_TOLERANCE_SECONDS = 300;
const LIMITS = { per10min: 15, perDay: 60, globalHour: 300, globalDay: 2000 };
// Optional trailing " D" asks for the storm drill instead of live PAGASA data.
const REQUEST = /^NB1 ASK ([QFERPA]) (\d{4}|\d{10})( D)?$/;
// Alerts: "NB1 SUB <town>" subscribes, "NB1 UNSUB" (all) or "NB1 UNSUB <town>" stops.
const SUBSCRIBE = /^NB1 (SUB|UNSUB)(?: (\d{4}|\d{10}))?$/;
const MAX_ALERT_TOWNS = 3;
const MAX_ALERTS_PER_DAY = 8;
const SEND_GAP_MS = 2500;

const hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
const mask = (n) => { const d = String(n || "").replace(/\D/g, ""); return d.length >= 4 ? `***${d.slice(-4)}` : "***"; };
const last10 = (n) => String(n || "").replace(/\D/g, "").slice(-10);

async function hmacHex(key, data) {
	const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(key), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
	return hex(await crypto.subtle.sign("HMAC", k, data));
}

function safeEqual(a, b) {
	if (a.length !== b.length) return false;
	let diff = 0;
	for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
	return diff === 0;
}

// docs.sms-gate.app/features/webhooks/#payload-signing: hex HMAC-SHA256(key, raw body + X-Timestamp)
async function verifyWebhook(raw, signature, timestamp, key) {
	if (!key) return "signing key not configured";
	if (!signature || !timestamp) return "missing signature headers";
	const ts = Number(timestamp);
	if (!Number.isInteger(ts)) return "bad timestamp";
	if (Math.abs(Date.now() / 1000 - ts) > TIMESTAMP_TOLERANCE_SECONDS) return "stale timestamp";
	const data = new Uint8Array([...raw, ...new TextEncoder().encode(timestamp)]);
	return safeEqual(await hmacHex(key, data), signature.trim().toLowerCase()) ? null : "bad signature";
}

function manilaHHMM() {
	const d = new Date(Date.now() + 8 * 3600 * 1000);
	return String(d.getUTCHours()).padStart(2, "0") + String(d.getUTCMinutes()).padStart(2, "0");
}

const nameSuffix = (name) => {
	const clean = String(name || "").replace(/[^A-Za-z0-9]+/g, "_").replace(/^_+|_+$/g, "").slice(0, 24);
	return clean ? `:${clean}` : "";
};

// Same output as reciever.py build_reply (minus the Open-Meteo line on Q).
// Open-Meteo for the town: current temperature and gusts, today's rain total and chance.
async function localWeather(town) {
	const at = TOWN_COORDS[town];
	if (!at) return "";
	const url = `https://api.open-meteo.com/v1/forecast?latitude=${at[0]}&longitude=${at[1]}` +
		"&current=temperature_2m,wind_gusts_10m&daily=precipitation_sum,precipitation_probability_max&forecast_days=1&timezone=Asia%2FManila";
	try {
		const res = await fetch(url, { signal: AbortSignal.timeout(4000) });
		if (!res.ok) return "";
		const w = await res.json();
		const rain = w.daily?.precipitation_sum?.[0], chance = w.daily?.precipitation_probability_max?.[0];
		return `Wx: ${Math.round(w.current.temperature_2m)}C, gust ${Math.round(w.current.wind_gusts_10m)} km/h, rain today ${(+rain || 0).toFixed(1)}mm` +
			(chance != null ? ` (${chance}%)` : "") + ".";
	} catch {
		return ""; // weather is a bonus; never block the reply on it
	}
}

// GloFAS river discharge via Open-Meteo: only worth a line when a real river is rising.
async function riverOutlook(town) {
	const at = TOWN_COORDS[town];
	if (!at) return "";
	const url = `https://flood-api.open-meteo.com/v1/flood?latitude=${at[0]}&longitude=${at[1]}&daily=river_discharge&forecast_days=7`;
	try {
		const res = await fetch(url, { signal: AbortSignal.timeout(4000) });
		if (!res.ok) return "";
		const q = ((await res.json()).daily?.river_discharge || []).map(Number);
		if (q.length < 2) return "";
		const today = q[0];
		const peak = Math.max(...q);
		const day = q.indexOf(peak);
		if (peak < 5) return ""; // small streams: the 5 km model grid can't say much
		if (day > 0 && peak >= 1.5 * Math.max(today, 0.1)) {
			return `River: rising, peak ${Math.round(peak)} m3/s in ${day} day${day > 1 ? "s" : ""} (x${(peak / Math.max(today, 0.1)).toFixed(1)}).`;
		}
		return "";
	} catch {
		return "";
	}
}

const BLANK = { classes: 0, notice: "No LGU update is currently available.", floodAreas: [], evacuationCenters: [], roadStatuses: [], mapPins: [] };

/** Storm-update extras fetched live for the town (weather + river), in parallel. */
async function withLiveExtras(town, update) {
	const [weather, river] = await Promise.all([localWeather(town), riverOutlook(town)]);
	return { ...(update || BLANK), weather: [weather, river].filter(Boolean).join(" ") };
}

export function buildReply(type, town, update, time) {
	const u = update || { classes: 0, notice: "No LGU update is currently available.", floodAreas: [], evacuationCenters: [], roadStatuses: [], mapPins: [] };
	const notice = Codec.cleanNotice(u.notice || "");
	const classes = `C${parseInt(u.classes, 10) || 0}`;
	if (type === "Q") {
		if (u.pagasaActive === false) {
			const pagasa = "No current storm update administered by PAGASA.";
			const text = [notice && (notice.endsWith(".") ? notice : `${notice}.`), u.drill ? "DRILL" : "", pagasa, u.weather].filter(Boolean).join(" ");
			return Codec.encode("Q", town, ["W0", "R0", "G0", classes], time, text);
		}
		const fields = [`W${parseInt(u.signal ?? u.classes, 10) || 0}`, `R${parseInt(u.rain, 10) || 0}`, `G${parseInt(u.gusts, 10) || 0}`];
		const evac = (u.evacuationCenters || [])[0];
		if (evac) fields.push(`E1${evac.status || "O"}`);
		fields.push(classes);
		// LGU advisory first, then the storm line and what it means for this town.
		const storm = Codec.cleanNotice(u.pagasaTitle || u.pagasaNotice || "PAGASA weather update");
		const advice = Codec.cleanNotice(u.pagasaAdvice || "");
		const text = [notice && (notice.endsWith(".") ? notice : `${notice}.`), u.drill ? "DRILL" : "", `${storm}.`, advice && `Do: ${advice}`, u.weather].filter(Boolean).join(" ");
		return Codec.encode("Q", town, fields, time, text);
	}
	if (type === "F") return Codec.encode("F", town, (u.floodAreas || []).map((a, i) => `A${i + 1}${a.level || "L"}${a.status || "C"}${nameSuffix(a.name)}`), time, notice);
	if (type === "E") return Codec.encode("E", town, (u.evacuationCenters || []).map((c, i) => `S${i + 1}${c.status || "O"}${parseInt(c.percentFull, 10) || 0}${nameSuffix(c.name)}`), time, notice);
	if (type === "R") return Codec.encode("R", town, (u.roadStatuses || []).map((r, i) => `R${i + 1}${r.status || "O"}${nameSuffix(r.name)}`), time, notice);
	if (type === "P") return Codec.encodePins(town, (u.mapPins || []).map((p) => ({ ...p, latitude: +p.latitude, longitude: +p.longitude, intensity: parseInt(p.intensity, 10) || 0 })), time);
	throw new Error("unsupported request type");
}

function extract(payload) {
	const box = (payload && (payload.payload || payload.data)) || payload || {};
	let msg = box.message ?? box.text ?? box.body ?? payload.message ?? payload.text ?? "";
	if (msg && typeof msg === "object") msg = msg.text || "";
	const sender = box.phoneNumber || box.phone_number || box.from || box.sender || payload.phoneNumber || payload.from || null;
	return { text: String(msg).trim(), sender: sender ? String(sender) : null };
}

async function ensureTables(db) {
	await db.batch([
		db.prepare("CREATE TABLE IF NOT EXISTS relay_claims (key TEXT PRIMARY KEY, at INTEGER)"),
		db.prepare("CREATE TABLE IF NOT EXISTS relay_sends (number TEXT, at INTEGER)"),
		db.prepare("CREATE INDEX IF NOT EXISTS relay_sends_number_at ON relay_sends (number, at)"),
		db.prepare("CREATE TABLE IF NOT EXISTS alert_subs (number TEXT, town TEXT, at INTEGER, PRIMARY KEY (number, town))"),
		db.prepare("CREATE TABLE IF NOT EXISTS alert_sends (number TEXT, at INTEGER)"),
	]);
}

// Atomic de-duplication of sms-gate retries; false when already handled.
async function claim(db, key) {
	const now = Date.now();
	await db.prepare("DELETE FROM relay_claims WHERE at < ?").bind(now - 7 * 86400e3).run();
	const r = await db.prepare("INSERT OR IGNORE INTO relay_claims (key, at) VALUES (?, ?)").bind(key, now).run();
	return r.meta.changes === 1;
}

async function allow(db, number) {
	const now = Date.now(), n = last10(number);
	await db.prepare("DELETE FROM relay_sends WHERE at < ?").bind(now - 86400e3).run();
	const count = async (where, ...args) => (await db.prepare(`SELECT COUNT(*) AS c FROM relay_sends WHERE ${where}`).bind(...args).first()).c;
	if (await count("number = ? AND at >= ?", n, now - 600e3) >= LIMITS.per10min) {
		const oldest = (await db.prepare("SELECT MIN(at) AS t FROM relay_sends WHERE number = ? AND at >= ?").bind(n, now - 600e3).first()).t;
		const mins = Math.max(1, Math.ceil((oldest + 600e3 - now) / 60e3));
		return { reason: "per-number 10-minute limit", tell: `NIMBUS: Too many requests from this number. Try again in ${mins} min.` };
	}
	if (await count("number = ? AND at >= ?", n, now - 86400e3) >= LIMITS.perDay) return { reason: "per-number daily limit", tell: "NIMBUS: Daily request limit reached for this number. Try again tomorrow." };
	if (await count("at >= ?", now - 3600e3) >= LIMITS.globalHour) return { reason: "global hourly limit", tell: "NIMBUS: The service is busy. Try again in a few minutes." };
	if (await count("at >= ?", now - 86400e3) >= LIMITS.globalDay) return { reason: "global daily limit", tell: "NIMBUS: The service is busy. Try again later." };
	await db.prepare("INSERT INTO relay_sends (number, at) VALUES (?, ?)").bind(n, now).run();
	return null;
}

async function sendSms(env, number, text) {
	return sendSmsTo(env, [number], text);
}

async function sendSmsTo(env, numbers, text) {
	const number = numbers.length === 1 ? numbers[0] : `${numbers.length} numbers`;
	const auth = btoa(`${env.SMS_USERNAME}:${env.SMS_PASSWORD}`);
	for (let attempt = 1; attempt <= 3; attempt++) {
		const res = await fetch(`${SMS_API}/message`, {
			method: "POST",
			headers: { Authorization: `Basic ${auth}`, "Content-Type": "application/json" },
			body: JSON.stringify({ textMessage: { text }, phoneNumbers: numbers }),
		});
		if (res.ok) return true;
		console.log(`send attempt ${attempt} to ${mask(number)} failed: ${res.status}`);
		if (res.status < 500 && res.status !== 429) return false;
		await new Promise((r) => setTimeout(r, 1000 * attempt));
	}
	return false;
}

async function handle(env, payload) {
	const { text, sender } = extract(payload);
	if (!sender) return console.log("no sender in payload");
	const m = REQUEST.exec(text);
	const sub = SUBSCRIBE.exec(text);
	if (!m && !sub) return; // not a NIMBUS request (ordinary text to the gateway SIM)

	const db = env.nimbus_db;
	await ensureTables(db);
	const env_ = payload.payload || {};
	const key = payload.id ? `id:${payload.deviceId || ""}:${payload.id}` : `msg:${sender}:${text}:${env_.receivedAt || ""}`;
	if (!await claim(db, key)) return console.log("duplicate webhook delivery; skipped");
	if (sub) return handleSubscription(env, sender, sub[1], sub[2]);

	const [, type, town, drillFlag] = m;
	const row = await db.prepare("SELECT update_json FROM towns WHERE town_code = ?").bind(town).first();
	let update = row ? JSON.parse(row.update_json) : null;
	if (drillFlag) {
		await db.prepare("CREATE TABLE IF NOT EXISTS drill_state (id INTEGER PRIMARY KEY, state_json TEXT, updated_at TEXT)").run();
		const drill = await db.prepare("SELECT state_json FROM drill_state WHERE id = 1").first();
		if (drill) {
			const st = JSON.parse(drill.state_json);
			// Real LGU data for the town, PAGASA fields from the replayed bulletin.
			update = { classes: 0, notice: "", floodAreas: [], evacuationCenters: [], roadStatuses: [], mapPins: [], ...(update || {}), ...(st.towns?.[town] || st.default), drill: true };
		}
	}
	const time = manilaHHMM();
	const types = type === "A" ? ["Q", "P", "F", "E", "R"] : [type];
	if (types.includes("Q")) update = await withLiveExtras(town, update);
	const replies = [];
	for (const t of types) {
		try { replies.push(buildReply(t, town, update, time)); } catch (e) { console.log(`build ${t} failed: ${e.message}`); }
	}
	if (!replies.length) replies.push(`NIMBUS: Could not retrieve ${town}. Try again later.`);

	const limited = await allow(db, sender); // one request = one count, however many replies
	if (limited) {
		console.log(`rate limit (${limited.reason}) for ${mask(sender)}`);
		// Tell them once per 10-minute window, so the notice itself can't become spam.
		if (await claim(db, `limit-notice:${last10(sender)}:${Math.floor(Date.now() / 600e3)}`)) {
			console.log(`limit notice to ${mask(sender)}: ${await sendSms(env, sender, limited.tell)}`);
		}
		return;
	}
	for (const [i, reply] of replies.entries()) {
		// The gateway phone's modem fails bursts (RESULT_MODEM_ERROR), so space the texts out.
		if (i > 0) await new Promise((r) => setTimeout(r, SEND_GAP_MS));
		const ok = await sendSms(env, sender, reply);
		console.log(`reply ${reply.slice(0, 8)} to ${mask(sender)}: ${ok}`);
	}
}

const townName = (town) => TOWN_COORDS[town]?.[2] || town;

async function handleSubscription(env, sender, action, town) {
	const db = env.nimbus_db, n = last10(sender);
	if (await allow(db, sender)) return console.log(`subscription rate-limited for ${mask(sender)}`);
	let reply;
	if (action === "UNSUB") {
		if (town) await db.prepare("DELETE FROM alert_subs WHERE number = ? AND town = ?").bind(n, town).run();
		else await db.prepare("DELETE FROM alert_subs WHERE number = ?").bind(n).run();
		reply = `NIMBUS: Alerts off${town ? ` for ${townName(town)}` : ""}.`;
	} else if (!town || !TOWN_COORDS[town]) {
		reply = "NIMBUS: Unknown town. Choose your town in the NIMBUS app, then turn on alerts.";
	} else {
		const count = (await db.prepare("SELECT COUNT(*) AS c FROM alert_subs WHERE number = ? AND town != ?").bind(n, town).first()).c;
		if (count >= MAX_ALERT_TOWNS) {
			reply = `NIMBUS: You can get alerts for up to ${MAX_ALERT_TOWNS} towns. Text NB1 UNSUB to reset.`;
		} else {
			await db.prepare("INSERT OR REPLACE INTO alert_subs (number, town, at) VALUES (?, ?, ?)").bind(n, town, Date.now()).run();
			reply = `NIMBUS: Alerts on for ${townName(town)}. We'll text you when PAGASA raises a signal or the LGU posts an urgent update. Text NB1 UNSUB to stop.`;
		}
	}
	console.log(`${action} ${town || "all"} for ${mask(sender)}: ${await sendSms(env, sender, reply)}`);
}

/**
 * Push the town's storm update to everyone subscribed to it (called after a publish).
 * One sms-gate message per batch of numbers; each number gets at most MAX_ALERTS_PER_DAY.
 */
export async function alertSubscribers(env, town, update, reason) {
	const db = env.nimbus_db;
	await ensureTables(db);
	const { results } = await db.prepare("SELECT number FROM alert_subs WHERE town = ?").bind(town).all();
	if (!results.length) return;
	const now = Date.now();
	await db.prepare("DELETE FROM alert_sends WHERE at < ?").bind(now - 86400e3).run();
	const numbers = [];
	for (const { number } of results) {
		const sent = (await db.prepare("SELECT COUNT(*) AS c FROM alert_sends WHERE number = ? AND at >= ?").bind(number, now - 86400e3).first()).c;
		if (sent < MAX_ALERTS_PER_DAY) numbers.push(number);
	}
	if (!numbers.length) return console.log(`alert ${town}: every subscriber hit the daily cap`);
	Codec.setSigningKey(env.NIMBUS_SMS_SIGNING_KEY);
	const reply = buildReply("Q", town, await withLiveExtras(town, update), manilaHHMM());
	for (let i = 0; i < numbers.length; i += 20) {
		if (i > 0) await new Promise((r) => setTimeout(r, SEND_GAP_MS));
		const batch = numbers.slice(i, i + 20);
		// Local 10-digit numbers -> +63 for sms-gate.
		const ok = await sendSmsTo(env, batch.map((x) => (x.length === 10 ? `+63${x}` : x)), reply);
		if (ok) await db.batch(batch.map((x) => db.prepare("INSERT INTO alert_sends (number, at) VALUES (?, ?)").bind(x, now)));
		console.log(`alert ${town} (${reason}) to ${batch.length} subscriber(s): ${ok}`);
	}
}

export async function smsWebhook(request, env, ctx) {
	const raw = new Uint8Array(await request.arrayBuffer());
	if (!raw.length || raw.length > MAX_BODY_BYTES) return new Response(null, { status: raw.length ? 413 : 400 });
	const problem = await verifyWebhook(raw, request.headers.get("X-Signature"), request.headers.get("X-Timestamp"), env.SMS_WEBHOOK_SIGNING_KEY);
	if (problem) { console.log(`rejected webhook: ${problem}`); return new Response(null, { status: 401 }); }
	let payload;
	try { payload = JSON.parse(new TextDecoder().decode(raw)); } catch { return new Response(null, { status: 400 }); }
	if (!payload || typeof payload !== "object") return new Response(null, { status: 400 });
	if (payload.webhookId != null && payload.webhookId !== WEBHOOK_ID) return new Response(null, { status: 403 });
	if (payload.event != null && payload.event !== "sms:received") return new Response(null, { status: 204 });
	Codec.setSigningKey(env.NIMBUS_SMS_SIGNING_KEY);
	// Acknowledge now; build and send the replies in the background.
	ctx.waitUntil(handle(env, payload).catch((e) => console.log(`relay error: ${e.message}`)));
	return new Response(null, { status: 200 });
}
