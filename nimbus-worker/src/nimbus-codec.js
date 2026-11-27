// Nimbus SMS format, version NB1. No DOM, no dependencies, so it ports line for line
// to codec/nimbus_codec.dart, codec/NimbusCodec.kt and codec/nimbus_codec.py.
//
//   NB1 <type> <town> <field> <field> ... T<hhmm> [/<notice>] K<signature>
//   NB1~P~<town>~<pin>...~T<hhmm>~K<signature> for multipart-safe pin snapshots
//
//   type    Q storm update, F flood-prone areas, E evacuation centers, R road status, P map-pin snapshot
//   town    4-digit code from the app's offline town pack
//   fields  Q: W<level> R<rain 0-4> G<gusts km/h> E<site><O|F|X> or E0, C<class suspension 0-5>
//           F: A<area><H|M|L><F|W|C>[:Custom_name]
//           E: S<site><O|F|X><percent full>
//           R: R<road><O|L|X>[:Custom_name]
//   notice  optional LGU notice, plain SMS characters only (storm updates)
//   K       8 hex digits: first 4 bytes of HMAC-SHA256(key, body). The key comes from
//           setSigningKey(), process.env.NIMBUS_SMS_SIGNING_KEY (Node) or the public
//           development key (web demo only). test_vectors.json uses TEST_VECTOR_KEY.
(function (root) {
  "use strict";

  var VERSION = "NB1";
  var MAX_SMS = 160;

  var SIGNATURE_HEX = 8;
  var TEST_VECTOR_KEY = "nimbus-test-vectors-key";
  var DEV_SIGNING_KEY = "nimbus-dev-key-not-for-production";
  var signingKey =
    (typeof process === "object" && process.env && process.env.NIMBUS_SMS_SIGNING_KEY) ||
    DEV_SIGNING_KEY;
  function setSigningKey(key) { signingKey = key || DEV_SIGNING_KEY; }

  function utf8(text) {
    var out = [], s = unescape(encodeURIComponent(text));
    for (var i = 0; i < s.length; i++) out.push(s.charCodeAt(i));
    return out;
  }

  var K256 = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
  ];

  // SHA-256 over a byte array; returns 32 bytes.
  function sha256(bytes) {
    var h = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
    var msg = bytes.slice(), bitLen = bytes.length * 8;
    msg.push(0x80);
    while (msg.length % 64 !== 56) msg.push(0);
    for (var b = 7; b >= 0; b--) msg.push(b >= 4 ? 0 : (bitLen >>> (b * 8)) & 0xff);
    var w = new Array(64);
    for (var off = 0; off < msg.length; off += 64) {
      for (var t = 0; t < 16; t++) {
        w[t] = (msg[off + 4 * t] << 24) | (msg[off + 4 * t + 1] << 16) | (msg[off + 4 * t + 2] << 8) | msg[off + 4 * t + 3];
      }
      for (t = 16; t < 64; t++) {
        var x = w[t - 15], y = w[t - 2];
        var s0 = ((x >>> 7) | (x << 25)) ^ ((x >>> 18) | (x << 14)) ^ (x >>> 3);
        var s1 = ((y >>> 17) | (y << 15)) ^ ((y >>> 19) | (y << 13)) ^ (y >>> 10);
        w[t] = (w[t - 16] + s0 + w[t - 7] + s1) | 0;
      }
      var a = h[0], bb = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
      for (t = 0; t < 64; t++) {
        var S1 = ((e >>> 6) | (e << 26)) ^ ((e >>> 11) | (e << 21)) ^ ((e >>> 25) | (e << 7));
        var t1 = (hh + S1 + ((e & f) ^ (~e & g)) + K256[t] + w[t]) | 0;
        var S0 = ((a >>> 2) | (a << 30)) ^ ((a >>> 13) | (a << 19)) ^ ((a >>> 22) | (a << 10));
        var t2 = (S0 + ((a & bb) ^ (a & c) ^ (bb & c))) | 0;
        hh = g; g = f; f = e; e = (d + t1) | 0; d = c; c = bb; bb = a; a = (t1 + t2) | 0;
      }
      h[0] = (h[0] + a) | 0; h[1] = (h[1] + bb) | 0; h[2] = (h[2] + c) | 0; h[3] = (h[3] + d) | 0;
      h[4] = (h[4] + e) | 0; h[5] = (h[5] + f) | 0; h[6] = (h[6] + g) | 0; h[7] = (h[7] + hh) | 0;
    }
    var out = [];
    for (var i = 0; i < 8; i++) out.push((h[i] >>> 24) & 0xff, (h[i] >>> 16) & 0xff, (h[i] >>> 8) & 0xff, h[i] & 0xff);
    return out;
  }

  function hmacSha256(keyBytes, msgBytes) {
    if (keyBytes.length > 64) keyBytes = sha256(keyBytes);
    var ipad = [], opad = [];
    for (var i = 0; i < 64; i++) {
      var k = keyBytes[i] || 0;
      ipad.push(k ^ 0x36); opad.push(k ^ 0x5c);
    }
    return sha256(opad.concat(sha256(ipad.concat(msgBytes))));
  }

  // First 4 bytes of HMAC-SHA256(key, text) as 8 upper-case hex digits.
  function signature(text, key) {
    var mac = hmacSha256(utf8(key || signingKey), utf8(text));
    var hex = "";
    for (var i = 0; i < SIGNATURE_HEX / 2; i++) hex += (mac[i] < 16 ? "0" : "") + mac[i].toString(16);
    return hex.toUpperCase();
  }

  function signatureValid(body, given) {
    if (typeof given !== "string" || given.length !== SIGNATURE_HEX) return false;
    var expected = signature(body), up = given.toUpperCase(), diff = 0;
    for (var i = 0; i < SIGNATURE_HEX; i++) diff |= expected.charCodeAt(i) ^ up.charCodeAt(i);
    return diff === 0;
  }

  // Keeps notices inside the plain SMS character set so one reply stays one SMS.
  function cleanNotice(text) {
    return String(text)
      .replace(/[‘’]/g, "'").replace(/[“”]/g, '"').replace(/[–—]/g, "-")
      .replace(/[^\x20-\x7E]/g, "").replace(/\s+/g, " ").trim();
  }

  function encode(type, townCode, fields, time, notice) {
    var body = [VERSION, type, townCode].concat(fields, ["T" + time]).join(" ");
    if (notice) body += " /" + notice;
    return body + " K" + signature(body);
  }

  function encodePins(townCode, pins, time) {
    if (!/^(?:\d{4}|\d{10})$/.test(townCode)) throw new TypeError("Invalid town code");
    var fields = pins.map(function (pin) {
      var category = { flood: "F", evacuation: "E", road: "R" }[pin.category];
      var validStatus = category === "F" ? ["F", "W", "C"].indexOf(pin.status) >= 0
        : category === "E" ? ["O", "F", "X"].indexOf(pin.status) >= 0
          : category === "R" ? ["O", "L", "X"].indexOf(pin.status) >= 0 : false;
      if (!validStatus || pin.intensity < 0 || pin.intensity > 100 ||
          !Number.isFinite(pin.latitude) || !Number.isFinite(pin.longitude) ||
          pin.latitude < -90 || pin.latitude > 90 || pin.longitude < -180 || pin.longitude > 180) {
        throw new TypeError("Invalid map pin");
      }
      var label = cleanNotice(pin.label).replace(/\|/g, " ").replace(/\s+/g, "_");
      if (!label) throw new TypeError("Map pin labels cannot be empty");
      function coord(value) { return Math.sign(value) * Math.round(Math.abs(value) * 100000); }
      return [category, pin.status, pin.intensity, coord(pin.latitude), coord(pin.longitude), label].join("|");
    });
    var body = [VERSION, "P", townCode].concat(fields, ["T" + time]).join("~");
    return body + "~K" + signature(body);
  }

  function parseField(type, part) {
    var m;
    if (type === "F") {
      m = /^A(\d+)([HML])([FWC])(?::(\S+))?$/.exec(part);
      return m && { index: +m[1], level: m[2], now: m[3], customName: m[4] ? m[4].replace(/_/g, " ") : null };
    }
    if (type === "E") {
      m = /^S(\d+)([OFX])(\d+)$/.exec(part);
      return m && { index: +m[1], status: m[2], percentFull: +m[3] };
    }
    if (type === "R") {
      m = /^R(\d+)([OLX])(?::(\S+))?$/.exec(part);
      return m && { index: +m[1], status: m[2], customName: m[3] ? m[3].replace(/_/g, " ") : null };
    }
    if (type === "C") {
      m = /^C([0-5])$/.exec(part);
      return m && { index: 0, level: m[1] };
    }
    return null;
  }

  function parsePin(part) {
    var m = /^([FER])\|([A-Z])\|(\d{1,3})\|(-?\d{1,8})\|(-?\d{1,9})\|([A-Za-z0-9_.'-]+)$/.exec(part);
    if (!m) return null;
    var category = { F: "flood", E: "evacuation", R: "road" }[m[1]];
    var validStatus = m[1] === "F" ? ["F", "W", "C"].indexOf(m[2]) >= 0
      : m[1] === "E" ? ["O", "F", "X"].indexOf(m[2]) >= 0
        : ["O", "L", "X"].indexOf(m[2]) >= 0;
    var latitude = +m[4], longitude = +m[5], intensity = +m[3];
    if (!validStatus || intensity > 100 || Math.abs(latitude) > 9000000 || Math.abs(longitude) > 18000000) return null;
    return {
      category: category, label: m[6].replace(/_/g, " "),
      latitude: latitude / 100000, longitude: longitude / 100000,
      status: m[2], intensity: intensity
    };
  }

  // Returns null for anything that isn't an NB1 reply, so a stray text never crashes the app.
  function decode(sms) {
    var compactPins = sms.indexOf(VERSION + "~P~") === 0;
    var marker = compactPins ? "~K" : " K";
    var k = sms.lastIndexOf(marker);
    if (k < 0 || sms.indexOf(VERSION + (compactPins ? "~" : " ")) !== 0) return null;
    var body = sms.slice(0, k);
    var n = body.indexOf(" /");
    var parts = (n >= 0 ? body.slice(0, n) : body).split(compactPins ? "~" : " ");
    if (parts.length < 4) return null;
    var type = parts[1];
    if (type === "P" && !/^(?:\d{4}|\d{10})$/.test(parts[2])) return null;
    var items = parts.slice(3);
    var timePart = items.pop();
    if (!/^T\d{4}$/.test(timePart)) return null;
    var reply = {
      version: parts[0], type: type, townCode: parts[2], time: timePart.slice(1),
      notice: n >= 0 ? body.slice(n + 2) : "", valid: signatureValid(body, sms.slice(k + marker.length)),
      storm: null, items: [], pins: []
    };
    if (type === "Q") {
      var f = {};
      items.forEach(function (p) { f[p.charAt(0)] = p.slice(1); });
      var e = /^(\d+)([OFX]?)$/.exec(f.E || "0");
      reply.storm = { warning: f.W, rain: +f.R, gusts: +f.G, evacSite: e ? +e[1] : 0, evacStatus: e ? e[2] : "", classes: +f.C };
    } else if (type === "P") {
      for (var j = 0; j < items.length; j++) {
        var pin = parsePin(items[j]);
        if (!pin) return null;
        reply.pins.push(pin);
      }
    } else {
      for (var i = 0; i < items.length; i++) {
        var item = parseField(type, items[i]);
        if (!item) return null;
        reply.items.push(item);
      }
    }
    return reply;
  }

  var api = { VERSION: VERSION, MAX_SMS: MAX_SMS, TEST_VECTOR_KEY: TEST_VECTOR_KEY, setSigningKey: setSigningKey, signature: signature, cleanNotice: cleanNotice, encode: encode, encodePins: encodePins, decode: decode };
  if (typeof module === "object" && module.exports) module.exports = api;
  root.NimbusCodec = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
