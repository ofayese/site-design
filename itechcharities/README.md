# itechcharities.org — ITECH Development Charities Site

Static HTML site served via nginx in Docker.

## Quick start

```bash
cd site_design/itechcharities
docker compose up -d
open http://localhost:8081
```

> OlúTech runs on port 8080 — see `../olutechsys/`.

## File structure

```
itechcharities/
├── index.html
├── styles.css
├── scripts/site.js
├── assets/
│   ├── logo.svg
│   ├── favicon.svg
│   ├── og-itech.svg
│   └── hero-placeholder.svg
├── robots.txt
├── sitemap.xml
├── docker-compose.yml
├── nginx.conf
└── README.md
```

Shared cross-site assets: `../shared/` (Docker mounts parent `site_design/` for `/shared/*` routes).

## Before going live

1. **Contact form** — Replace `YOUR_FORM_ID` in `index.html` with your Formspree endpoint.

2. **Hero image** — Replace `assets/hero-placeholder.svg` with a real IDC program photo and update `index.html`.

3. **Articles** — Update article card `href`s when posts are published at `itechcharities.org/articles/`.

4. **HTTPS** — Add Certbot when deploying:
   ```bash
   certbot --nginx -d itechcharities.org -d www.itechcharities.org
   ```

## Sections

- Hero with stats
- Who We Are (3 pillars)
- Mission / Vision / Values
- Programs (6 tracks)
- Registration forms (Tech Foundation, Junior Geeks, Career Path, Volunteer)
- Donate CTA → Zeffy
- Articles teaser
- Contact form
- Footer with social links

## Reference repos

- `../../itechdc-site` — Next.js program metadata and partnership copy
- `../../_logocoder/_swarm-output/cursor` — constellation mark (green/gold variant)

## Running both sites together

```bash
cd site_design/olutechsys && docker compose up -d    # → localhost:8080
cd site_design/itechcharities && docker compose up -d  # → localhost:8081
```
