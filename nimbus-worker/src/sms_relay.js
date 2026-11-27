// SMS relay: sms-gate.app webhook -> NB1 replies, running inside the Worker
// (replaces SMS_SendAndRecieve/reciever.py + the cloudflared tunnel).
//
// Secrets (wrangler secret put):
//   SMS_WEBHOOK_SIGNING_KEY  SMS Gateway app -> Settings -> Webhooks -> Signing Key
//   NIMBUS_SMS_SIGNING_KEY   signs replies; the app is built with the same key
//   SMS_USERNAME / SMS_PASSWORD  sms-gate.app cloud credentials of the gateway phone
import "./nimbus-codec.js";

const Codec = globalThis.NimbusCodec;
const SMS_API = "https://api.sms-gate.app/3rdparty/v1";
const WEBHOOK_ID = "my-incoming-sms";
const MAX_BODY_BYTES = 64 * 1024;
const TIMESTAMP_TOLERANCE_SECONDS = 300;
const LIMITS = { per10min: 5, perDay: 30, globalHour: 300, globalDay: 2000 };
const REQUEST = /^NB1 ASK ([QFERPA]) (\d{4}|\d{10})$/;

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
export function buildReply(type, town, update, time) {
	const u = update || { classes: 0, notice: "No LGU update is currently available.", floodAreas: [], evacuationCenters: [], roadStatuses: [], mapPins: [] };
	const notice = Codec.cleanNotice(u.notice || "");
	const classes = `C${parseInt(u.classes, 10) || 0}`;
	if (type === "Q") {
		if (u.pagasaActive === false) {
			const pagasa = "No current storm update administered by PAGASA.";
			const text = notice ? `${notice}${notice.endsWith(".") ? "" : "."} ${pagasa}` : pagasa;
			return Codec.encode("Q", town, ["W0", "R0", "G0", classes], time, text);
		}
		const fields = [`W${parseInt(u.signal ?? u.classes, 10) || 0}`, `R${parseInt(u.rain, 10) || 0}`, `G${parseInt(u.gusts, 10) || 0}`];
		const evac = (u.evacuationCenters || [])[0];
		if (evac) fields.push(`E1${evac.status || "O"}`);
		fields.push(classes);
		return Codec.encode("Q", town, fields, time, notice || Codec.cleanNotice(u.pagasaNotice || "") || "PAGASA weather update");
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
	if (await count("number = ? AND at >= ?", n, now - 600e3) >= LIMITS.per10min) return "per-number 10-minute limit";
	if (await count("number = ? AND at >= ?", n, now - 86400e3) >= LIMITS.perDay) return "per-number daily limit";
	if (await count("at >= ?", now - 3600e3) >= LIMITS.globalHour) return "global hourly limit";
	if (await count("at >= ?", now - 86400e3) >= LIMITS.globalDay) return "global daily limit";
	await db.prepare("INSERT INTO relay_sends (number, at) VALUES (?, ?)").bind(n, now).run();
	return null;
}

async function sendSms(env, number, text) {
	const auth = btoa(`${env.SMS_USERNAME}:${env.SMS_PASSWORD}`);
	for (let attempt = 1; attempt <= 3; attempt++) {
		const res = await fetch(`${SMS_API}/message`, {
			method: "POST",
			headers: { Authorization: `Basic ${auth}`, "Content-Type": "application/json" },
			body: JSON.stringify({ textMessage: { text }, phoneNumbers: [number] }),
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
	if (!m) return; // not a NIMBUS request (ordinary text to the gateway SIM)

	const db = env.nimbus_db;
	await ensureTables(db);
	const env_ = payload.payload || {};
	const key = payload.id ? `id:${payload.deviceId || ""}:${payload.id}` : `msg:${sender}:${text}:${env_.receivedAt || ""}`;
	if (!await claim(db, key)) return console.log("duplicate webhook delivery; skipped");

	const [, type, town] = m;
	const row = await db.prepare("SELECT update_json FROM towns WHERE town_code = ?").bind(town).first();
	const update = row ? JSON.parse(row.update_json) : null;
	const time = manilaHHMM();
	const replies = [];
	for (const t of type === "A" ? ["Q", "P", "F", "E", "R"] : [type]) {
		try { replies.push(buildReply(t, town, update, time)); } catch (e) { console.log(`build ${t} failed: ${e.message}`); }
	}
	if (!replies.length) replies.push(`NIMBUS: Could not retrieve ${town}. Try again later.`);

	const limited = await allow(db, sender); // one request = one count, however many replies
	if (limited) return console.log(`rate limit (${limited}) for ${mask(sender)}`);
	for (const reply of replies) {
		const ok = await sendSms(env, sender, reply);
		console.log(`reply ${reply.slice(0, 8)} to ${mask(sender)}: ${ok}`);
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
