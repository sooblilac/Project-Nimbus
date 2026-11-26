"use strict";

const http = require("node:http");
const {
  randomBytes,
  randomUUID,
  scrypt,
  scryptSync,
  timingSafeEqual,
} = require("node:crypto");
const fs = require("node:fs/promises");
const path = require("node:path");
const { promisify } = require("node:util");

const PORT = Number(process.env.PORT || 8080);
const DATA_FILE = process.env.NIMBUS_DATA_FILE || path.join(__dirname, "data", "updates.json");
const SESSION_TTL_MS = 8 * 60 * 60 * 1000;
const MAX_BODY_BYTES = 32 * 1024;
const scryptAsync = promisify(scrypt);
const CLASSES = new Set([0, 1, 2, 3, 4, 5]);
const FLOOD_LEVELS = new Set(["H", "M", "L"]);
const FLOOD_STATUSES = new Set(["F", "W", "C"]);
const EVAC_STATUSES = new Set(["O", "F", "X"]);
const ROAD_STATUSES = new Set(["O", "L", "X"]);
const MAP_PIN_CATEGORIES = new Set(["flood", "evacuation", "road"]);

function readTokens(raw) {
  if (!raw) return {};
  const parsed = JSON.parse(raw);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("LGU_TOKENS must be a JSON object keyed by town code.");
  }
  for (const [townCode, token] of Object.entries(parsed)) {
    if (!/^(?:\d{4}|\d{10})$/.test(townCode) || typeof token !== "string" || token.length < 32) {
      throw new Error("Each LGU_TOKENS entry must use a four- or ten-digit town code and a token of at least 32 characters.");
    }
  }
  return parsed;
}

function readUsers(raw = process.env.NIMBUS_LGU_USERS) {
  if (!raw) {
    if (process.env.NODE_ENV === "production") return {};
    return {
      demo: {
        password: "nimbusdemo26",
        townCodes: ["*"],
      },
    };
  }
  const parsed = JSON.parse(raw);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("NIMBUS_LGU_USERS must be a JSON object keyed by username.");
  }
  for (const [username, user] of Object.entries(parsed)) {
    if (!username.trim() || username.length > 64 ||
        !user || typeof user !== "object" || Array.isArray(user) ||
        typeof user.password !== "string" || user.password.length < 12 ||
        !Array.isArray(user.townCodes) || user.townCodes.length === 0 ||
        user.townCodes.some((code) =>
          typeof code !== "string" ||
          (code !== "*" && !/^(?:\d{4}|\d{10})$/.test(code)))) {
      throw new Error("Each LGU user needs a password of at least 12 characters and one or more valid townCodes.");
    }
  }
  return parsed;
}

function validText(value, maxLength) {
  return typeof value === "string" && value.trim().length > 0 && value.trim().length <= maxLength;
}

function validateUpdate(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) return "Request body must be an object.";
  if (!Number.isInteger(body.classes) || !CLASSES.has(body.classes)) return "classes must be an integer from 0 to 5.";
  if (typeof body.notice !== "string" || body.notice.length > 500) return "notice must be a string of at most 500 characters.";
  if (!Array.isArray(body.floodAreas) || body.floodAreas.length > 30) return "floodAreas must contain at most 30 entries.";
  if (!Array.isArray(body.evacuationCenters) || body.evacuationCenters.length > 20) {
    return "evacuationCenters must contain at most 20 entries.";
  }
  if (body.roadStatuses !== undefined &&
      (!Array.isArray(body.roadStatuses) || body.roadStatuses.length > 30)) {
    return "roadStatuses must contain at most 30 entries.";
  }
  if (body.mapPins !== undefined &&
      (!Array.isArray(body.mapPins) || body.mapPins.length > 100)) {
    return "mapPins must contain at most 100 entries.";
  }
  if (body.rain !== undefined && (!Number.isInteger(body.rain) || body.rain < 0 || body.rain > 4)) {
    return "rain must be an integer from 0 to 4.";
  }
  if (body.gusts !== undefined && (!Number.isInteger(body.gusts) || body.gusts < 0 || body.gusts > 500)) {
    return "gusts must be an integer from 0 to 500.";
  }
  if (body.pagasaActive !== undefined && typeof body.pagasaActive !== "boolean") {
    return "pagasaActive must be a boolean.";
  }
  if (body.pagasaName !== undefined && typeof body.pagasaName !== "string") {
    return "pagasaName must be a string.";
  }
  if (body.pagasaBulletin !== undefined && typeof body.pagasaBulletin !== "string") {
    return "pagasaBulletin must be a string.";
  }
  for (const area of body.floodAreas) {
    if (!area || typeof area !== "object" || Array.isArray(area) ||
        !validText(area.name, 60) || !FLOOD_LEVELS.has(area.level) || !FLOOD_STATUSES.has(area.status)) {
      return "Each flood area needs a name, a valid level (H, M, L), and status (F, W, C).";
    }
  }
  for (const center of body.evacuationCenters) {
    if (!center || typeof center !== "object" || Array.isArray(center) ||
        !validText(center.name, 60) || !EVAC_STATUSES.has(center.status) ||
        !Number.isInteger(center.percentFull) || center.percentFull < 0 || center.percentFull > 100) {
      return "Each evacuation center needs a name, status (O, F, X), and percentFull from 0 to 100.";
    }
  }
  for (const road of body.roadStatuses || []) {
    if (!road || typeof road !== "object" || Array.isArray(road) ||
        !validText(road.name, 60) || !ROAD_STATUSES.has(road.status)) {
      return "Each road status needs a name and a valid status (O, L, X).";
    }
  }
  for (const pin of body.mapPins || []) {
    const validStatus =
      pin?.category === "flood" ? FLOOD_STATUSES.has(pin.status) :
      pin?.category === "evacuation" ? EVAC_STATUSES.has(pin.status) :
      pin?.category === "road" ? ROAD_STATUSES.has(pin.status) : false;
    if (!pin || typeof pin !== "object" || Array.isArray(pin) ||
        !MAP_PIN_CATEGORIES.has(pin.category) ||
        !validText(pin.label, 80) ||
        !Number.isFinite(pin.latitude) || pin.latitude < -90 || pin.latitude > 90 ||
        !Number.isFinite(pin.longitude) || pin.longitude < -180 || pin.longitude > 180 ||
        !validStatus ||
        !Number.isInteger(pin.intensity) || pin.intensity < 0 || pin.intensity > 100) {
      return "Each map pin needs a category, label, valid coordinates, status, and intensity from 0 to 100.";
    }
  }
  return null;
}

async function loadUpdates(file) {
  try {
    const parsed = JSON.parse(await fs.readFile(file, "utf8"));
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("Expected an object.");
    return parsed;
  } catch (error) {
    if (error.code === "ENOENT") return {};
    throw new Error(`Could not read saved LGU updates: ${error.message}`);
  }
}

function send(response, status, value) {
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    "access-control-allow-origin": "*",
    "access-control-allow-methods": "GET, POST, DELETE, OPTIONS",
    "access-control-allow-headers": "Content-Type, Authorization",
  });
  response.end(JSON.stringify(value));
}

async function readJson(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > MAX_BODY_BYTES) throw Object.assign(new Error("Request body is too large."), { status: 413 });
    chunks.push(chunk);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw Object.assign(new Error("Request body must be valid JSON."), { status: 400 });
  }
}

function isAuthorized(request, expected) {
  const providedToken = bearerToken(request);
  if (!providedToken) return false;
  const provided = Buffer.from(providedToken);
  const stored = Buffer.from(expected);
  return provided.length === stored.length && timingSafeEqual(provided, stored);
}

function bearerToken(request) {
  const match = /^Bearer (.+)$/.exec(request.headers.authorization || "");
  return match?.[1];
}

function createServer({
  tokens = readTokens(process.env.LGU_TOKENS),
  users = readUsers(),
  dataFile = DATA_FILE,
} = {}) {
  let updates;
  let writeQueue = Promise.resolve();
  const authSessions = new Map();
  const authUsers = new Map(
    Object.entries(users).map(([username, user]) => {
      const salt = randomBytes(16);
      return [
        username,
        {
          salt,
          passwordHash: scryptSync(user.password, salt, 64),
          townCodes: user.townCodes,
        },
      ];
    }),
  );
  const dummySalt = randomBytes(16);
  const dummyPasswordHash = scryptSync("nimbus-invalid-login", dummySalt, 64);

  const ready = loadUpdates(dataFile).then((value) => {
    updates = value;
  });

  async function persistUpdate(townCode, update) {
    let result;
    const write = writeQueue.then(async () => {
      const next = { ...updates, [townCode]: update };
      await fs.mkdir(path.dirname(dataFile), { recursive: true });
      const temporary = `${dataFile}.${randomUUID()}.tmp`;
      await fs.writeFile(temporary, JSON.stringify(next, null, 2), { mode: 0o600 });
      await fs.rename(temporary, dataFile);
      updates = next;
      result = update;
    });
    writeQueue = write.catch(() => {});
    await write;
    return result;
  }

  async function deleteUpdate(townCode) {
    const write = writeQueue.then(async () => {
      const next = { ...updates };
      delete next[townCode];
      await fs.mkdir(path.dirname(dataFile), { recursive: true });
      const temporary = `${dataFile}.${randomUUID()}.tmp`;
      await fs.writeFile(temporary, JSON.stringify(next, null, 2), { mode: 0o600 });
      await fs.rename(temporary, dataFile);
      updates = next;
    });
    writeQueue = write.catch(() => {});
    await write;
  }

  return http.createServer(async (request, response) => {
    try {
      await ready;
      const url = new URL(request.url, "http://localhost");
      if (request.method === "GET" && url.pathname === "/health") {
        return send(response, 200, { ok: true });
      }

      if (request.method === "GET" && url.pathname === "/api/towns") {
        const towns = Object.entries(updates)
          .filter(([, update]) => update && typeof update === "object")
          .map(([townCode, update]) => ({
            townCode,
            classes: update.classes,
            notice: update.notice || "",
            updatedAt: update.updatedAt || null,
          }))
          .sort((a, b) => a.townCode.localeCompare(b.townCode));
        return send(response, 200, { towns });
      }

      if (request.method === "OPTIONS") {
        response.writeHead(204, {
          "access-control-allow-origin": "*",
          "access-control-allow-methods": "GET, POST, DELETE, OPTIONS",
          "access-control-allow-headers": "Content-Type, Authorization",
        });
        return response.end();
      }

      if (request.method === "POST" && url.pathname === "/api/auth/login") {
        const body = await readJson(request);
        const username = typeof body?.username === "string" ? body.username : "";
        const password = typeof body?.password === "string" ? body.password : "";
        const user = authUsers.get(username);
        const salt = user?.salt || dummySalt;
        const expectedHash = user?.passwordHash || dummyPasswordHash;
        const passwordHash = await scryptAsync(password, salt, 64);
        if (!user || !timingSafeEqual(passwordHash, expectedHash)) {
          return send(response, 401, { error: "Invalid username or password." });
        }

        const now = Date.now();
        for (const [token, session] of authSessions) {
          if (session.expiresAt <= now) authSessions.delete(token);
        }
        const accessToken = randomBytes(32).toString("hex");
        const expiresAt = now + SESSION_TTL_MS;
        authSessions.set(accessToken, {
          username,
          townCodes: user.townCodes,
          expiresAt,
        });
        return send(response, 200, {
          accessToken,
          username,
          townCodes: user.townCodes,
          expiresAt: new Date(expiresAt).toISOString(),
        });
      }

      if (request.method === "POST" && url.pathname === "/api/auth/logout") {
        const token = bearerToken(request);
        if (token) authSessions.delete(token);
        return send(response, 200, { ok: true });
      }

      const match = /^\/api\/towns\/(\d{4}|\d{10})\/updates$/.exec(url.pathname);
      if (!match) return send(response, 404, { error: "Not found." });
      const townCode = match[1];

      if (request.method === "GET") {
        return send(response, 200, { update: updates[townCode] || null });
      }
      if (request.method === "DELETE") {
        const session = authSessions.get(bearerToken(request));
        if (!session || session.expiresAt <= Date.now()) {
          return send(response, 401, { error: "A valid LGU login is required to reset town updates." });
        }
        if (!session.townCodes.includes("*") && !session.townCodes.includes(townCode)) {
          return send(response, 403, { error: "This account cannot reset updates for this town." });
        }
        await deleteUpdate(townCode);
        return send(response, 200, { ok: true });
      }
      if (request.method !== "POST") {
        response.setHeader("allow", "GET, POST, DELETE");
        return send(response, 405, { error: "Method not allowed." });
      }

      const session = authSessions.get(bearerToken(request));
      const sessionAuthorized =
        session &&
        session.expiresAt > Date.now() &&
        (session.townCodes.includes("*") || session.townCodes.includes(townCode));
      const publisherToken = tokens[townCode];
      if (!sessionAuthorized && !publisherToken) {
        return send(response, 403, { error: "No LGU publisher is configured for this town." });
      }
      if (!sessionAuthorized && !isAuthorized(request, publisherToken)) {
        return send(response, 401, { error: "A valid LGU login or publishing token is required." });
      }

      const body = await readJson(request);
      const validationError = validateUpdate(body);
      if (validationError) return send(response, 400, { error: validationError });

      const update = {
        townCode,
        classes: body.classes,
        notice: body.notice.trim(),
        floodAreas: body.floodAreas.map((area) => ({
          name: area.name.trim(),
          level: area.level,
          status: area.status,
        })),
        evacuationCenters: body.evacuationCenters.map((center) => ({
          name: center.name.trim(),
          status: center.status,
          percentFull: center.percentFull,
        })),
        roadStatuses: (body.roadStatuses || []).map((road) => ({
          name: road.name.trim(),
          status: road.status,
        })),
        mapPins: (body.mapPins || []).map((pin) => ({
          category: pin.category,
          label: pin.label.trim(),
          latitude: pin.latitude,
          longitude: pin.longitude,
          status: pin.status,
          intensity: pin.intensity,
        })),
        ...(body.rain !== undefined ? { rain: body.rain } : {}),
        ...(body.gusts !== undefined ? { gusts: body.gusts } : {}),
        ...(typeof body.issuedAt === "string" && /^\d{2}:\d{2}$/.test(body.issuedAt)
          ? { issuedAt: body.issuedAt }
          : {}),
        ...(body.pagasaActive !== undefined ? { pagasaActive: body.pagasaActive } : {}),
        ...(typeof body.pagasaName === "string" ? { pagasaName: body.pagasaName } : {}),
        ...(typeof body.pagasaBulletin === "string" ? { pagasaBulletin: body.pagasaBulletin } : {}),
        updatedAt: new Date().toISOString(),
      };
      await persistUpdate(townCode, update);
      return send(response, 201, { update });
    } catch (error) {
      if (response.headersSent) return response.destroy();
      if (error.status) return send(response, error.status, { error: error.message });
      console.error("Nimbus API request failed:", error.message);
      return send(response, 500, { error: "The server could not process the request." });
    }
  });
}

if (require.main === module) {
  let tokens;
  let users;
  try {
    tokens = readTokens(process.env.LGU_TOKENS);
    users = readUsers();
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
  if (tokens && users) {
    const server = createServer({ tokens, users });
    server.listen(PORT, "0.0.0.0", () => console.log(`Nimbus API listening on port ${PORT}`));
  }
}

module.exports = { createServer, readTokens, readUsers, validateUpdate };
