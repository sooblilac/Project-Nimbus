# PAGASA Typhoon Fetcher

Downloads the latest PAGASA Tropical Cyclone Bulletin PDF and extracts the data to JSON.
No Java needed.

## Requirements
- Node.js 18 or newer (`node -v`)

## Usage
```
npm install
npm start
```
Results go in the `output/` folder (`bulletin.pdf` and `bulletin.json`).

To parse a PDF you already have:
```
npm start -- path\to\bulletin.pdf
```

## Notes
- PAGASA only lists bulletins while a storm is active (archives stay up ~1 week).
- Tested on one bulletin (Typhoon Samuel, TCB #2F). Bulletins with active wind signals
  are returned as raw text under `windSignals.rawText`; check them against the PDF.
- Don't run in a tight loop; every 30-60 minutes is plenty.
- For emergencies, use PAGASA's official channels.
