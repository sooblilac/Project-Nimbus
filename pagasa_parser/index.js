// Usage:
//   npm start                 -> downloads the latest bulletin from PAGASA and parses it
//   npm start -- file.pdf     -> parses a PDF you already have
const fs = require("fs");
const path = require("path");
const parseBulletin = require("./parseBulletin");

const PAGE = "https://bagong.pagasa.dost.gov.ph/tropical-cyclone/severe-weather-bulletin";
const OUTPUT_DIR = path.join(__dirname, "output");

async function getLatestBulletinUrl() {
    const res = await fetch(PAGE);
    if (!res.ok) throw new Error(`PAGASA page returned ${res.status}`);
    const html = await res.text();

    // Find every link like .../bulletin/TCB%231_samuel.pdf
    const links = [...html.matchAll(/https:\/\/pubfiles\.pagasa\.dost\.gov\.ph\/[^"'\s)]*TCB%23(\d+)[^"'\s)]*\.pdf/gi)]
        .map(m => ({ url: m[0], number: parseInt(m[1], 10) }));

    if (links.length === 0) throw new Error("No bulletin PDFs found on the page (probably no active or recent storm).");

    // Highest bulletin number = most recent
    links.sort((a, b) => b.number - a.number);
    return links[0].url;
}

async function main() {
    fs.mkdirSync(OUTPUT_DIR, { recursive: true });

    let pdfPath = process.argv[2];
    if (!pdfPath) {
        const url = await getLatestBulletinUrl();
        console.log("Downloading:", url);
        const pdf = await fetch(url);
        if (!pdf.ok) throw new Error(`PDF download returned ${pdf.status}`);
        pdfPath = path.join(OUTPUT_DIR, "bulletin.pdf");
        fs.writeFileSync(pdfPath, Buffer.from(await pdf.arrayBuffer()));
    }

    const data = await parseBulletin(pdfPath);
    const jsonPath = path.join(OUTPUT_DIR, "bulletin.json");
    fs.writeFileSync(jsonPath, JSON.stringify(data, null, 2));
    console.log("Saved:", jsonPath);
    console.log(`${data.category} ${data.name} - Bulletin ${data.bulletinNumber}, issued ${data.issued}`);
}

main().catch(err => {
    console.error("Error:", err.message);
    process.exit(1);
});
