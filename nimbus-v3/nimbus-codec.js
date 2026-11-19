// Nimbus SMS format, version NB1. No DOM, no dependencies, so it ports line for line
// to codec/nimbus_codec.dart, codec/NimbusCodec.kt and codec/nimbus_codec.py.
//
//   NB1 <type> <town> <field> <field> ... T<hhmm> [/<notice>] K<signature>
//
//   type    Q storm update, F flood-prone areas, E evacuation centers, R road status
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

  // Returns null for anything that isn't an NB1 reply, so a stray text never crashes the app.
  function decode(sms) {
    var k = sms.lastIndexOf(" K");
    if (k < 0 || sms.indexOf(VERSION + " ") !== 0) return null;
    var body = sms.slice(0, k);
    var n = body.indexOf(" /");
    var parts = (n >= 0 ? body.slice(0, n) : body).split(" ");
    if (parts.length < 4) return null;
    var type = parts[1];
    var items = parts.slice(3);
    var timePart = items.pop();
    if (!/^T\d{4}$/.test(timePart)) return null;
    var reply = {
      version: parts[0], type: type, townCode: parts[2], time: timePart.slice(1),
      notice: n >= 0 ? body.slice(n + 2) : "", valid: signature(body) === sms.slice(k + 2),
      storm: null, items: []
    };
    if (type === "Q") {
      var f = {};
      items.forEach(function (p) { f[p.charAt(0)] = p.slice(1); });
      var e = /^(\d+)([OFX]?)$/.exec(f.E || "0");
      reply.storm = { warning: f.W, rain: +f.R, gusts: +f.G, evacSite: e ? +e[1] : 0, evacStatus: e ? e[2] : "", classes: +f.C };
    } else {
      for (var i = 0; i < items.length; i++) {
        var item = parseField(type, items[i]);
        if (!item) return null;
        reply.items.push(item);
      }
    }
    return reply;
  }

  var api = { VERSION: VERSION, MAX_SMS: MAX_SMS, signature: signature, cleanNotice: cleanNotice, encode: encode, decode: decode };
  if (typeof module === "object" && module.exports) module.exports = api;
  root.NimbusCodec = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
