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
//   K       4 hex digits. Demo checksum only: a real gateway signs with HMAC-SHA256.
(function (root) {
  "use strict";

  var VERSION = "NB1";
  var MAX_SMS = 160;

  // h = h * 31 + charCode, kept to 32 bits; the signature is the low 16 bits as 4 hex digits.
  function signature(text) {
    var h = 0;
    for (var i = 0; i < text.length; i++) h = (Math.imul(h, 31) + text.charCodeAt(i)) >>> 0;
    return (h & 0xffff).toString(16).toUpperCase().padStart(4, "0");
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
      notice: n >= 0 ? body.slice(n + 2) : "", valid: signature(body) === sms.slice(k + marker.length),
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

  var api = { VERSION: VERSION, MAX_SMS: MAX_SMS, signature: signature, cleanNotice: cleanNotice, encode: encode, encodePins: encodePins, decode: decode };
  if (typeof module === "object" && module.exports) module.exports = api;
  root.NimbusCodec = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
