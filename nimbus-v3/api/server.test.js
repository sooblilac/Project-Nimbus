"use strict";

const assert = require("node:assert/strict");
const { after, before, test } = require("node:test");
const fs = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");
const { createServer } = require("./server");

const token = "test-token-for-batangas-city-lgu-123456";
const psgcToken = "test-token-for-psgc-batangas-city-123456";
let directory;
let dataFile;
let server;
let baseUrl;

before(async () => {
  directory = await fs.mkdtemp(path.join(os.tmpdir(), "nimbus-api-"));
  dataFile = path.join(directory, "updates.json");
  server = createServer({
    tokens: { "0412": token, "0401005000": psgcToken },
    users: {
      "lgu-demo": { password: "NimbusDemo2026!", townCodes: ["*"] },
      "batangas-staff": { password: "BatangasDemo2026!", townCodes: ["0412"] },
    },
    dataFile,
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});

after(async () => {
  await new Promise((resolve) => server.close(resolve));
  await fs.rm(directory, { recursive: true, force: true });
});

test("residents can read the latest town update without authentication", async () => {
  const response = await fetch(`${baseUrl}/api/towns/0412/updates`);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { update: null });
});

test("LGU demo login issues a session that can publish town updates", async () => {
  const login = await fetch(`${baseUrl}/api/auth/login`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      username: "lgu-demo",
      password: "NimbusDemo2026!",
    }),
  });
  assert.equal(login.status, 200);
  const { accessToken, townCodes } = await login.json();
  assert.equal(typeof accessToken, "string");
  assert.deepEqual(townCodes, ["*"]);

  const published = await fetch(`${baseUrl}/api/towns/0517/updates`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${accessToken}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      classes: 0,
      notice: "Demo advisory",
      floodAreas: [],
      evacuationCenters: [],
    }),
  });
  assert.equal(published.status, 201);
  assert.equal((await published.json()).update.notice, "Demo advisory");
});

test("LGU login rejects an incorrect password", async () => {
  const response = await fetch(`${baseUrl}/api/auth/login`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      username: "lgu-demo",
      password: "wrong-password",
    }),
  });
  assert.equal(response.status, 401);
});

test("LGU sessions are restricted to assigned towns and can log out", async () => {
  const login = await fetch(`${baseUrl}/api/auth/login`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      username: "batangas-staff",
      password: "BatangasDemo2026!",
    }),
  });
  assert.equal(login.status, 200);
  const { accessToken } = await login.json();

  const forbidden = await fetch(`${baseUrl}/api/towns/0517/updates`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${accessToken}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      classes: 0,
      notice: "",
      floodAreas: [],
      evacuationCenters: [],
    }),
  });
  assert.equal(forbidden.status, 403);

  const logout = await fetch(`${baseUrl}/api/auth/logout`, {
    method: "POST",
    headers: { authorization: `Bearer ${accessToken}` },
  });
  assert.equal(logout.status, 200);
});

test("LGU updates require a town-scoped token and persist for residents", async () => {
  const body = {
    classes: 1,
    notice: "Avoid the riverside",
    floodAreas: [{ name: "Riverbank zone", level: "H", status: "F" }],
    evacuationCenters: [{ name: "Central School", status: "O", percentFull: 45 }],
    roadStatuses: [{ name: "Riverside road", status: "L" }],
    mapPins: [{
      category: "flood",
      label: "Market crossing",
      latitude: 13.7563,
      longitude: 121.0583,
      status: "F",
      intensity: 95,
    }],
  };
  const denied = await fetch(`${baseUrl}/api/towns/0412/updates`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  assert.equal(denied.status, 401);

  const published = await fetch(`${baseUrl}/api/towns/0412/updates`, {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  assert.equal(published.status, 201);
  const saved = (await published.json()).update;
  assert.equal(saved.townCode, "0412");
  assert.equal(saved.floodAreas[0].status, "F");
  assert.deepEqual(saved.roadStatuses, [
    { name: "Riverside road", status: "L" },
  ]);
  assert.deepEqual(saved.mapPins, [{
    category: "flood",
    label: "Market crossing",
    latitude: 13.7563,
    longitude: 121.0583,
    status: "F",
    intensity: 95,
  }]);
  assert.ok(saved.updatedAt);

  const resident = await fetch(`${baseUrl}/api/towns/0412/updates`);
  assert.deepEqual((await resident.json()).update, saved);
  assert.deepEqual(JSON.parse(await fs.readFile(dataFile, "utf8"))["0412"], saved);
});

test("LGU sessions can reset only updates for their assigned town", async () => {
  const login = await fetch(`${baseUrl}/api/auth/login`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      username: "batangas-staff",
      password: "BatangasDemo2026!",
    }),
  });
  const { accessToken } = await login.json();

  const unauthorized = await fetch(`${baseUrl}/api/towns/0412/updates`, {
    method: "DELETE",
  });
  assert.equal(unauthorized.status, 401);

  const wrongTown = await fetch(`${baseUrl}/api/towns/0517/updates`, {
    method: "DELETE",
    headers: { authorization: `Bearer ${accessToken}` },
  });
  assert.equal(wrongTown.status, 403);

  const reset = await fetch(`${baseUrl}/api/towns/0412/updates`, {
    method: "DELETE",
    headers: { authorization: `Bearer ${accessToken}` },
  });
  assert.equal(reset.status, 200);
  assert.deepEqual(await reset.json(), { ok: true });

  const resident = await fetch(`${baseUrl}/api/towns/0412/updates`);
  assert.deepEqual((await resident.json()).update, null);
  const otherTown = await fetch(`${baseUrl}/api/towns/0517/updates`);
  assert.equal((await otherTown.json()).update.notice, "Demo advisory");
});

test("rejects malformed or out-of-range update data", async () => {
  const response = await fetch(`${baseUrl}/api/towns/0412/updates`, {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({ classes: 8, notice: "", floodAreas: [], evacuationCenters: [] }),
  });
  assert.equal(response.status, 400);
});

test("rejects null entries in flood and evacuation lists", async () => {
  const response = await fetch(`${baseUrl}/api/towns/0412/updates`, {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({
      classes: 0,
      notice: "",
      floodAreas: [null],
      evacuationCenters: [],
    }),
  });
  assert.equal(response.status, 400);
});

test("rejects an invalid road status", async () => {
  const response = await fetch(`${baseUrl}/api/towns/0412/updates`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      classes: 0,
      notice: "",
      floodAreas: [],
      evacuationCenters: [],
      roadStatuses: [{ name: "Riverside road", status: "UNKNOWN" }],
    }),
  });
  assert.equal(response.status, 400);
});

test("rejects map pins with invalid coordinates or status", async () => {
  const response = await fetch(`${baseUrl}/api/towns/0412/updates`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      classes: 0,
      notice: "",
      floodAreas: [],
      evacuationCenters: [],
      mapPins: [{
        category: "road",
        label: "Bridge",
        latitude: 13.5,
        longitude: 181,
        status: "X",
        intensity: 100,
      }],
    }),
  });
  assert.equal(response.status, 400);
});

test("a token cannot publish to an unconfigured town", async () => {
  const response = await fetch(`${baseUrl}/api/towns/0517/updates`, {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({ classes: 0, notice: "", floodAreas: [], evacuationCenters: [] }),
  });
  assert.equal(response.status, 403);
});

test("supports ten-digit PSGC codes for new locations", async () => {
  const response = await fetch(`${baseUrl}/api/towns/0401005000/updates`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${psgcToken}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      classes: 0,
      notice: "",
      floodAreas: [],
      evacuationCenters: [],
    }),
  });
  assert.equal(response.status, 201);
  assert.equal((await response.json()).update.townCode, "0401005000");
});

test("accepts custom advisory text up to 500 characters", async () => {
  const notice = "A".repeat(500);
  const response = await fetch(`${baseUrl}/api/towns/0412/updates`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      classes: 0,
      notice,
      floodAreas: [],
      evacuationCenters: [],
    }),
  });
  assert.equal(response.status, 201);
  assert.equal((await response.json()).update.notice, notice);
});

test("rejects custom advisory text above 500 characters", async () => {
  const response = await fetch(`${baseUrl}/api/towns/0412/updates`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      classes: 0,
      notice: "A".repeat(501),
      floodAreas: [],
      evacuationCenters: [],
    }),
  });
  assert.equal(response.status, 400);
});
