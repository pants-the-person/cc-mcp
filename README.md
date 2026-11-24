# cc-mcp

Cloudflare Workers project using Wrangler and SQLite-backed Durable Objects (available on the Cloudflare Workers Free plan via `new_sqlite_classes`).

## Scripts

- `npm run dev` — Start local Wrangler dev server
- `npm run cf-typegen` — Regenerate `worker-configuration.d.ts` from `wrangler.jsonc`
- `npm run typecheck` — Run TypeScript type checking
- `npm run deploy` — Deploy to Cloudflare Workers
