# Optional server add-ons

Small Docker services that run **next to Immich** (same Docker network `immich_default`). The app works without them; with them, search, memories, people and editing get better.

| Service | Port | What the app uses it for |
|---|---|---|
| `relevanz` (`relevanz.py`) | 2284 | keeps only clear hits of smart search; face suggestions ("Is this X?"); sensitive-photo check for memory covers (computes missing CLIP embeddings on demand, read-only) |
| `kategorien` (`kategorien.py`) | – | tags photos as `Kategorie/<name>` (receipts, documents, handwriting, QR codes …) every 15 min |
| `bereinigen` (`bereinigen/`) | 2285 | Clean Up in the editor and background fill of the spatial scene (LaMa, CPU) |

## Setup

```bash
cd server
cp .env.example .env               # fill in DB_URL (read-only DB user recommended)
cp keys.json.example keys.json     # one Immich API key per user for the categories service
docker compose up -d --build       # relevanz + kategorien
cd bereinigen && docker compose up -d --build
```

The services read the database **read-only**. They act on the user's behalf with the token the app sends (relevanz, bereinigen), or with the API keys from `keys.json` (kategorien).

## How the app reaches them

- If the app talks to Immich directly on port **2283**, it calls `http://<server>:2284/relevanz` and `http://<server>:2285/bereinigen`.
- Otherwise (e.g. `https://photos.example.com` behind a reverse proxy) it calls `https://photos.example.com/fotos-dienst/<name>`. Example for nginx / Nginx Proxy Manager ("advanced"):

```nginx
location /fotos-dienst/relevanz   { proxy_pass http://<immich-host>:2284/relevanz; }
location /fotos-dienst/bereinigen { proxy_pass http://<immich-host>:2285/bereinigen; client_max_body_size 50m; proxy_read_timeout 300s; }
```

**Never expose these services or Immich to the internet without authentication.** The recommended setup is home network or VPN (e.g. WireGuard) only.
