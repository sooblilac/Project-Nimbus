import { smsWebhook } from "./sms_relay.js";
/**
 * Welcome to Cloudflare Workers! This is your first worker.
 *
 * - Run `npm run dev` in your terminal to start a development server
 * - Open a browser tab at http://localhost:8787/ to see your worker in action
 * - Run `npm run deploy` to publish your worker
 *
 * Learn more at https://developers.cloudflare.com/workers/
 */

const CORS_HEADERS = {
	"access-control-allow-origin": "*",
	"access-control-allow-methods": "GET, POST, DELETE, OPTIONS",
	"access-control-allow-headers": "Content-Type, Authorization",
};

function json(value, status = 200) {
	return new Response(JSON.stringify(value), {
		status,
		headers: { "content-type": "application/json; charset=utf-8", ...CORS_HEADERS, "cache-control": "no-store" },
	});
}

function townCodeValid(value) {
	return typeof value === "string" && /^(?:\d{4}|\d{10})$/.test(value);
}

async function readJson(request) {
	try {
		return await request.json();
	} catch {
		return null;
	}
}

async function bearerToken(request) {
	const match = /^Bearer (.+)$/i.exec(request.headers.get("authorization") || "");
	return match?.[1] || null;
}

async function session(env, request) {
	const token = await bearerToken(request);
	if (!token) return null;
	const row = await env.nimbus_db.prepare(
		"SELECT username, expires_at FROM sessions WHERE access_token = ?",
	).bind(token).first();
	if (!row || new Date(row.expires_at).getTime() <= Date.now()) {
		if (row) await env.nimbus_db.prepare("DELETE FROM sessions WHERE access_token = ?").bind(token).run();
		return null;
	}
	return { token, username: row.username };
}

async function authorizedForTown(env, username, townCode) {
	const row = await env.nimbus_db.prepare(
		"SELECT town_codes FROM lgu_users WHERE username = ?",
	).bind(username).first();
	if (!row) return false;
	const towns = JSON.parse(row.town_codes);
	return towns.includes("*") || towns.includes(townCode);
}

async function pbkdf2(password, saltHex, iterations = 100_000) {
	const encoder = new TextEncoder();
	const key = await crypto.subtle.importKey("raw", encoder.encode(password), "PBKDF2", false, ["deriveBits"]);
	const salt = Uint8Array.from(saltHex.match(/.{2}/g).map((byte) => parseInt(byte, 16)));
	const bits = await crypto.subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt, iterations }, key, 256);
	return [...new Uint8Array(bits)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export default {
	async fetch(request, env, ctx) {
		const url = new URL(request.url);
		const path = url.pathname.replace(/\/+$/, "") || "/";

		if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS_HEADERS });

		if (path === "/health") {
			if (!env.nimbus_db) return json({ ok: false, error: "D1 binding nimbus_db is not configured." }, 503);
			try {
				await env.nimbus_db.prepare("SELECT 1 AS ok").first();
				return json({ ok: true, service: "nimbus-api" });
			} catch (error) {
				return json({ ok: false, error: error.message }, 503);
			}
		}

		if (!env.nimbus_db) return json({ error: "D1 binding nimbus_db is not configured." }, 503);

		if (path === "/sms" && request.method === "POST") return smsWebhook(request, env, ctx);

		if (path === "/api/pagasa" && request.method === "GET") {
			const row = await env.nimbus_db.prepare(
				"SELECT state_json, updated_at FROM pagasa_state WHERE id = 1",
			).first();
			if (!row) return json({ active: false, message: "No storm updates yet", updatedAt: null });
			return json({ ...JSON.parse(row.state_json), updatedAt: row.updated_at });
		}

		if (path === "/api/pagasa" && request.method === "POST") {
			const secret = env.PAGASA_INGEST_SECRET;
			if (!secret || await bearerToken(request) !== secret) return json({ error: "Unauthorized." }, 401);
			const body = await readJson(request);
			if (!body || typeof body !== "object") return json({ error: "Request body must be an object." }, 400);
			const now = new Date().toISOString();
			await env.nimbus_db.prepare(
				"INSERT INTO pagasa_state (id, state_json, updated_at) VALUES (1, ?, ?) ON CONFLICT(id) DO UPDATE SET state_json = excluded.state_json, updated_at = excluded.updated_at",
			).bind(JSON.stringify(body), now).run();
			return json({ ok: true, updatedAt: now });
		}

		if (path === "/api/towns" && request.method === "GET") {
			const { results } = await env.nimbus_db.prepare(
				"SELECT town_code, update_json, updated_at FROM towns ORDER BY town_code",
			).all();
			return json({ towns: results.map((row) => ({ townCode: row.town_code, update: row.update_json ? JSON.parse(row.update_json) : null, updatedAt: row.updated_at })) });
		}

		const townMatch = /^\/api\/towns\/([^/]+)(?:\/updates)?$/.exec(path);
		if (townMatch) {
			const townCode = decodeURIComponent(townMatch[1]);
			if (!townCodeValid(townCode)) return json({ error: "Invalid town code." }, 400);

			if (request.method === "GET") {
				const row = await env.nimbus_db.prepare(
					"SELECT update_json, updated_at FROM towns WHERE town_code = ?",
				).bind(townCode).first();
				if (!row) return json({ update: null });
				return json({ update: JSON.parse(row.update_json), updatedAt: row.updated_at });
			}

			if (request.method === "POST") {
				const auth = await session(env, request);
				if (!auth) return json({ error: "Unauthorized." }, 401);
				if (!await authorizedForTown(env, auth.username, townCode)) return json({ error: "Forbidden for this town." }, 403);
				const body = await readJson(request);
				if (!body || typeof body !== "object" || Array.isArray(body)) return json({ error: "Request body must be an update object." }, 400);
				const update = { ...body, townCode, updatedAt: new Date().toISOString() };
				await env.nimbus_db.prepare(
					"INSERT INTO towns (town_code, update_json, updated_at) VALUES (?, ?, ?) ON CONFLICT(town_code) DO UPDATE SET update_json = excluded.update_json, updated_at = excluded.updated_at",
				).bind(townCode, JSON.stringify(update), update.updatedAt).run();
				return json({ update });
			}

			if (request.method === "DELETE") {
				const auth = await session(env, request);
				if (!auth) return json({ error: "Unauthorized." }, 401);
				if (!await authorizedForTown(env, auth.username, townCode)) return json({ error: "Forbidden for this town." }, 403);
				await env.nimbus_db.prepare("DELETE FROM towns WHERE town_code = ?").bind(townCode).run();
				return json({ ok: true });
			}
		}

		if (path === "/api/auth/login" && request.method === "POST") {
			const body = await readJson(request);
			if (!body || typeof body.username !== "string" || typeof body.password !== "string") return json({ error: "Username and password are required." }, 400);
			const row = await env.nimbus_db.prepare(
				"SELECT password_hash, town_codes FROM lgu_users WHERE username = ?",
			).bind(body.username).first();
			if (!row) return json({ error: "Invalid username or password." }, 401);
			let record;
			try { record = JSON.parse(row.password_hash); } catch { return json({ error: "Invalid user configuration." }, 500); }
			const derived = await pbkdf2(body.password, record.salt, record.iterations || 100_000);
			if (derived !== record.hash) return json({ error: "Invalid username or password." }, 401);
			const random = crypto.getRandomValues(new Uint8Array(32));
			const accessToken = [...random].map((byte) => byte.toString(16).padStart(2, "0")).join("");
			const expiresAt = new Date(Date.now() + 8 * 60 * 60 * 1000).toISOString();
			await env.nimbus_db.prepare(
				"INSERT INTO sessions (access_token, username, expires_at) VALUES (?, ?, ?)",
			).bind(accessToken, body.username, expiresAt).run();
			return json({ accessToken, username: body.username, townCodes: JSON.parse(row.town_codes), expiresAt });
		}

		if (path === "/api/auth/logout" && request.method === "POST") {
			const token = await bearerToken(request);
			if (token) await env.nimbus_db.prepare("DELETE FROM sessions WHERE access_token = ?").bind(token).run();
			return json({ ok: true });
		}

		if (path === "/api/admin/users" && request.method === "POST") {
			const secret = env.ADMIN_SETUP_SECRET;
			if (!secret || await bearerToken(request) !== secret) return json({ error: "Unauthorized." }, 401);
			const body = await readJson(request);
			if (!body || typeof body.username !== "string" || !body.username.trim() ||
				typeof body.password !== "string" || body.password.length < 6 ||
				!Array.isArray(body.townCodes) || body.townCodes.length === 0) {
				return json({ error: "Username, password of 6+ characters, and townCodes are required." }, 400);
			}
			if (body.townCodes.some((code) => code !== "*" && !townCodeValid(code))) {
				return json({ error: "townCodes must contain valid town codes or *." }, 400);
			}
			const saltBytes = crypto.getRandomValues(new Uint8Array(16));
			const salt = [...saltBytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
			const iterations = 100_000;
			const hash = await pbkdf2(body.password, salt, iterations);
			await env.nimbus_db.prepare(
				"INSERT INTO lgu_users (username, password_hash, town_codes) VALUES (?, ?, ?) ON CONFLICT(username) DO UPDATE SET password_hash = excluded.password_hash, town_codes = excluded.town_codes",
			).bind(body.username.trim(), JSON.stringify({ salt, iterations, hash }), JSON.stringify(body.townCodes)).run();
			return json({ ok: true, username: body.username.trim(), townCodes: body.townCodes });
		}

		return json({ error: "Not found." }, 404);
	},
};
