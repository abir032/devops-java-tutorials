# Order Desk – frontend

React + TypeScript + Vite single page app. Plain CSS, no UI framework.

## Prerequisites

- Node.js 20+ and npm
- The backend running on <http://localhost:8080> (see [../backend/README.md](../backend/README.md))

## Run in development

```bash
cp .env.example .env      # VITE_API_URL=http://localhost:8080
npm install
npm run dev               # http://localhost:5173
```

The backend must allow the dev origin via CORS; its default `APP_CORS_ALLOWED_ORIGINS`
is already `http://localhost:5173`.

## Build for production

```bash
npm run build             # type-checks, then writes static files to dist/
npm run preview           # optional: serve dist/ locally to check the build
```

`dist/` is just HTML, JS and CSS – any static web server (e.g. nginx) can serve it.

## Where does the app send API calls?

All requests go to `` `${import.meta.env.VITE_API_URL ?? ""}/api/v1` `` (see `src/api.ts`).

- **`VITE_API_URL` set** (e.g. `http://localhost:8080`): calls go straight to that backend.
  Needs CORS on the backend.
- **`VITE_API_URL` not set**: calls go to `/api/v1/...` on the *same host that served the page*.
  This is what you want behind a reverse proxy that serves `dist/` and forwards `/api` to the
  backend – no CORS needed.

`VITE_API_URL` is baked into the JavaScript at **build time**, not read at runtime.
Changing it means running `npm run build` again.

## What the page shows

1. **Products** – table plus a badge with the `X-Cache` header (`HIT` from Redis / `MISS` from MariaDB).
2. **Place order** – posts `{productId, quantity}`; shows the returned `PENDING` order.
3. **Orders** – polled every 2 seconds; watch `PENDING` turn `CONFIRMED` or `FAILED` after ~3 s.
4. **Footer** – `Served by:` the `X-Instance` header of the last response, i.e. which backend answered.
