# olutechsys.com — OlúTech Systems Site

Static HTML site served via nginx in Docker.

## Quick start

```bash
cd site_design/olutechsys
docker compose up -d
open http://localhost:8080
```

> ITECH runs on port 8081 — see `../itechcharities/`.

## File structure

```
olutechsys/
├── index.html          ← main page (links external CSS/JS)
├── styles.css          ← brand-specific styles
├── scripts/site.js     ← site hooks (forms in Phase 6)
├── assets/
│   ├── logo.svg        ← constellation mark (from _logocoder)
│   ├── favicon.svg
│   ├── og-olutech.svg  ← social share image
│   └── hero-placeholder.svg
├── robots.txt
├── sitemap.xml
├── docker-compose.yml  ← mounts ../shared for /shared/*
├── nginx.conf
└── README.md
```

Shared cross-site assets live in `../shared/` (base.css, nav.js, motion.js). Docker mounts the parent `site_design/` folder so `/shared/*` resolves correctly.

## Before going live

1. **Contact form** — Sign up at [formspree.io](https://formspree.io), create a form, and replace `YOUR_FORM_ID` in `index.html`.

2. **Hero photos** — Replace placeholder SVGs with real assets when available:
   - `assets/olutech-yoruba.jpg` (hero) — update `index.html` img `src`
   - `assets/olutech-dev-hub.png` (OTS Labs section)

3. **Domain** — Point DNS A record for `olutechsys.com` at your server IP.

4. **HTTPS** — Add Certbot when deploying to production:
   ```bash
   certbot --nginx -d olutechsys.com -d www.olutechsys.com
   ```

## Deployment options

| Option | How |
|---|---|
| Local Mac (Docker) | `docker compose up -d` → localhost:8080 |
| VPS / cloud VM | Copy `olutechsys/` + `shared/`, run compose, point DNS |
| Netlify / Vercel | Deploy folder; symlink or copy `shared/` into site root |
