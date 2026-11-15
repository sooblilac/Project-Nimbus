// Reads a PAGASA Tropical Cyclone Bulletin PDF and returns structured data.
// Uses plain text extraction (no Java needed) and simple pattern matching.
const fs = require("fs");
const pdf = require("pdf-parse");

const CATEGORIES = "Super Typhoon|Typhoon|Severe Tropical Storm|Tropical Storm|Tropical Depression";

const num = s => (s == null ? null : parseFloat(String(s).replace(/,/g, "")));

// Text between two headings (case-insensitive). Returns "" if start not found.
function between(text, startRe, endRe) {
    const s = text.search(startRe);
    if (s === -1) return "";
    const rest = text.slice(s).replace(startRe, "");
    const e = endRe ? rest.search(endRe) : -1;
    return (e === -1 ? rest : rest.slice(0, e)).trim();
}
const oneLine = s => s.split("\n").map(l => l.trim()).filter(Boolean).join(" ");

async function parseBulletin(pdfPath) {
    const raw = (await pdf(fs.readFileSync(pdfPath))).text;
    // Tidy: collapse runs of spaces, trim lines, drop empty lines
    const lines = raw.split("\n").map(l => l.replace(/\s+/g, " ").trim()).filter(Boolean);
    const text = lines.join("\n");

    const result = { source: "PAGASA Tropical Cyclone Bulletin" };

    // --- Header ---
    const nr = /TROPICAL CYCLONE BULLETIN NR\.?\s*(\w+)/i.exec(text);
    result.bulletinNumber = nr ? nr[1] : null;
    result.isFinal = /final bulletin/i.test(text) || (nr ? /F$/i.test(nr[1]) : false);

    const titleRe = new RegExp(`^(${CATEGORIES})\\s+(.+?)(?:\\s*\\(([^)]+)\\))?$`, "i");
    const titleLine = lines.find(l => titleRe.test(l) && !/PHILIPPINE|HAS |FORECAST/i.test(l));
    if (titleLine) {
        const [, category, name, intl] = titleRe.exec(titleLine);
        Object.assign(result, { category, name, internationalName: intl || null });
    }
    const issued = /^Issued at (.+)$/im.exec(text);
    result.issued = issued ? issued[1].trim() : null;

    // --- Headline (the line just above "Location of Center") ---
    const locIdx = lines.findIndex(l => /^Location of Center/i.test(l));
    result.headline = locIdx > 0 ? lines[locIdx - 1] : null;

    // --- Current position ---
    const locText = oneLine(between(text, /Location of Center[^\n]*\n/i, /\nIntensity\n/i));
    const pos = /([\d.]+)°\s*([NS]),\s*([\d.]+)°\s*([EW])/i.exec(locText);
    result.currentPosition = {
        description: locText || null,
        lat: pos ? num(pos[1]) * (pos[2].toUpperCase() === "S" ? -1 : 1) : null,
        lon: pos ? num(pos[3]) * (pos[4].toUpperCase() === "W" ? -1 : 1) : null,
        outsidePAR: /OUTSIDE PAR/i.test(locText),
    };

    // --- Intensity ---
    const intensityText = oneLine(between(text, /\nIntensity\n/i, /\nPresent Movement\n/i));
    result.intensity = {
        text: intensityText || null,
        maxSustainedWindsKph: num((/sustained winds of ([\d,.]+)\s*km\/h/i.exec(intensityText) || [])[1]),
        gustsKph: num((/gustiness of up to ([\d,.]+)\s*km\/h/i.exec(intensityText) || [])[1]),
        pressureHpa: num((/pressure of ([\d,.]+)\s*hPa/i.exec(intensityText) || [])[1]),
    };

    // --- Movement and wind extent ---
    const movement = oneLine(between(text, /\nPresent Movement\n/i, /\nExtent of Tropical Cyclone Winds\n/i));
    result.movement = {
        text: movement || null,
        speedKph: num((/([\d.]+)\s*km\/h/i.exec(movement) || [])[1]),
    };
    result.windExtent = oneLine(between(text, /\nExtent of Tropical Cyclone Winds\n/i, /\nTRACK AND INTENSITY FORECAST\n/i)) || null;

    // --- Forecast table ---
    result.forecast = [];
    const start = lines.findIndex(l => /^\d+-Hour Forecast$/i.test(l));
    const stop = lines.findIndex(l => /WIND SIGNALS \(TCWS\)/i.test(l));
    if (start !== -1) {
        const block = lines.slice(start, stop === -1 ? undefined : stop);
        for (let i = 0; i < block.length; i++) {
            const h = /^(\d+)-Hour Forecast$/i.exec(block[i]);
            if (!h) continue;
            const time = block[i + 1];
            const date = block[i + 2];
            const ll = /^([\d.]+)\s+([\d.]+)$/.exec(block[i + 3] || "");
            let j = i + 4;
            const loc = [];
            let tail = null;
            while (j < block.length && !/^\d+-Hour Forecast$/i.test(block[j])) {
                const t = /^([\d,.]+)\s+([A-Z]{2,3})\s+(.+)$/.exec(block[j]);
                if (t) { tail = t; break; }
                loc.push(block[j]);
                j++;
            }
            result.forecast.push({
                hours: num(h[1]),
                time, date,
                lat: ll ? num(ll[1]) : null,
                lon: ll ? num(ll[2]) : null,
                location: loc.join(" "),
                maxSustainedWindsKph: tail ? num(tail[1]) : null,
                category: tail ? tail[2] : null,
                movement: tail ? tail[3] : null,
            });
        }
    }

    // --- Wind signals ---
    const signals = between(text, /TROPICAL CYCLONE WIND SIGNALS \(TCWS\) IN EFFECT\n/i, /\nTROPICAL CYCLONE BULLETIN NR|\nOTHER HAZARDS AFFECTING/i);
    result.windSignals = {
        noneHoisted: /No Wind Signal is currently hoisted/i.test(signals),
        // Raw text, because layouts for active signals vary a lot between bulletins
        rawText: signals || null,
    };

    // --- Other sections (raw text) ---
    result.otherHazardsLand = between(text, /OTHER HAZARDS AFFECTING LAND AREAS\n/i, /\nHAZARDS AFFECTING COASTAL WATERS/i) || null;
    result.hazardsCoastalWaters = between(text, /HAZARDS AFFECTING COASTAL WATERS\n/i, /\nTROPICAL CYCLONE BULLETIN NR|\nPage \d+ of \d+|\nPrepared by/i) || null;
    result.outlook = between(text, /TRACK AND INTENSITY OUTLOOK\n/i, /\nConsidering these developments/i) || null;

    return result;
}

module.exports = parseBulletin;
