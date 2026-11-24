# `cc-mesh-bridge` (`cc-mcp`)

A single-repository **Cloudflare Workers + Durable Objects (WebSocket Hibernation + SQLite) + D1 + R2** platform and **CC: Tweaked Lua** client suite that bridges Minecraft ComputerCraft networks with MCP-compatible AI agents.

---

## Architecture

1. **Hibernation-First Durable Object (`CcMeshBridge`)**
   - Uses `this.ctx.acceptWebSocket()`, `ws.serializeAttachment()`, and `this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"))` with **zero `setInterval` loops**.
   - Stores live network topology (`network_entities`), cross-network KV state (`kv_store`), self-learning Lua tools (`learned_tools`), a redstone-clock-paced `task_queue` with lease expiration (`lease_expires_at`), and TTL `task_outputs` pruned via `alarm()` in DO SQLite (`this.ctx.storage.sql`).
   - Supports cross-network WebSocket Pub/Sub (`SUB` / `UNSUB` / `PUB` → `EVENT`).
2. **Interrupt-Driven Wakeups & Redstone Clock Pacing**
   - Enqueuing a task immediately sends a `WAKE` frame to the target gateway over WebSocket.
   - In-game `gateway.lua` stays completely silent while idle and only sends `POLL_QUEUE` on a rising `redstone` clock pulse when `has_pending_work == true` (with a 300s fallback timer) to stay well within Cloudflare Workers Free Tier limits.
3. **Dual App Store**
   - **Static Domain App Store (`src/lua/apps/*.lua`):** Bundled directly into the Worker as text modules (`spider`, `inv_mon`, `net_diag`) and served via `/api/store/static` (with SHA-256 digests) and `/lua/apps/:slug.lua` with zero D1/R2 overhead.
   - **Dynamic App Store, Schematics & Recipe Spider (D1 + R2):** Stores user-published `.lua` packages, Create `.nbt` / Lua schematics, and deduplicated modpack item/recipe graphs in D1 (`CATALOG_DB`) and R2 (`ARTIFACT_BUCKET`).
4. **Premade Standard Library (`src/lua/lib/std.lua`)**
   - Auto-synced to `/lib/std.lua` on all nodes by `bootstrap.lua` and preloaded in sandboxed task execution.
   - Exports `std.serialize_json`, `std.deserialize_json`, `std.filters` (`by_mod`, `by_name`, `by_tag`, `min_count`, `all`, `any`), `std.list_attachment`, `std.list_inventory`, `std.get_api`, and `std.probe_network`.
5. **Dynamic Device API Spec Discovery & Synthesis**
   - When an unknown peripheral is attached (`PERIPHERAL_ATTACHED`) or reported (`SYNC_TOPOLOGY`), `gateway.lua` probes safe read-only metadata with `std.get_api(name)` (never invoking mutating methods).
   - If `type_name` is absent from D1 `device_api_specs`, the DO marks the entity `pending`, exposes it via `cc://specs/pending`, and supports automated synthesis via **MCP `sampling/createMessage`** (primary) or the **`synthesize_device_spec` + `save_device_api_spec`** agent fallback workflow.
6. **Edge Security (Cloudflare Access)**
   - `GET /lua/bootstrap.lua` is publicly fetchable for in-game `wget`.
   - All other `/lua/*`, `/api/*`, `/ws`, and `/mcp` routes require `Cf-Access-Jwt-Assertion` or `Cf-Access-Authenticated-User-Email` (injected by Cloudflare Access for OIDC users or Service Tokens), bypassable only when `REQUIRE_CF_ACCESS="false"` in local tests.

---

## Repository Layout

```text
├── migrations/
│   └── 0001_catalog.sql             # D1 schema: packages, schematics, items, recipes, device_api_specs
├── src/
│   ├── index.ts                     # Edge router, CF Access auth, static & D1/R2 stores, recipe & spec APIs
│   ├── bridge_do.ts                 # CcMeshBridge DO (WS Hibernation, SQLite queue, MCP server + Sampling)
│   ├── protocol.ts                  # Shared TypeScript interfaces for WS frames, API specs, & MCP payloads
│   ├── static_store.ts              # Bundled Lua manifest & Static App Store SHA-256 registry
│   └── lua/
│       ├── bootstrap.lua            # Self-updating startup.lua (SHA-256 manifest sync)
│       ├── gateway.lua              # Hub daemon: WS client, hot-plug probe, Rednet router, redstone poller
│       ├── runner.lua               # Worker daemon: Rednet RPC, sandboxed xpcall executor w/ stdout capture
│       ├── pkg.lua                  # Unified CLI for Static Store, D1/R2 Store, & Schematics
│       ├── lib/
│       │   └── std.lua              # Premade CC: Tweaked standard library
│       └── apps/
│           ├── spider.lua           # Static app: inventory/AE2 item & pattern crawler w/ local hash dedup
│           ├── inv_mon.lua          # Static app: live inventory monitor using lib.std
│           └── net_diag.lua         # Static app: network & peripheral API inspector using lib.std
└── tests/
    ├── worker/
    │   ├── edge_and_store.test.ts   # Auth, static store, D1/R2 store, recipe spider, device_api_specs
    │   └── do_hibernation.test.ts   # WS Hibernation, leases, alarm TTL, MCP Sampling & spec auto-save
    ├── lua/
    │   ├── mock_cc.lua              # Headless CC: Tweaked runtime emulator
    │   ├── run_lua_tests.lua        # Automated Lua test suite
    │   └── run_wasmoon.mjs          # Node + wasmoon Lua test runner
    └── e2e/
        └── live_wrangler_e2e.mjs    # Live `wrangler dev --local` + real WebSocket + wasmoon Lua E2E harness
```

---

## HTTP & WebSocket Endpoints

| Route | Method | Auth | Purpose |
| :--- | :--- | :--- | :--- |
| `/` | `GET` | Public | Health check (`{ service: "cc-mesh-bridge", status: "ok" }`) |
| `/init.lua`, `/lua/bootstrap.lua` | `GET` | Public | In-game `wget` bootstrap script (`wget https://cc.pants.place/init.lua startup.lua`) |
| `/lua/manifest.json` | `GET` | CF Access | SHA-256 manifest of all bundled Lua files |
| `/lua/:file`, `/lua/lib/std.lua` | `GET` | CF Access | Core Lua scripts & standard library |
| `/lua/apps/:slug.lua` | `GET` | CF Access | Static Domain App Store Lua source (`spider`, `inv_mon`, `net_diag`) |
| `/api/store/static` | `GET` | CF Access | Static Domain App Store catalog with SHA-256 hashes |
| `/api/store/packages` | `GET` | CF Access | List dynamic packages stored in D1 |
| `/api/store/publish` | `POST` | CF Access | Publish a dynamic `.lua` package to R2 + D1 |
| `/api/store/download/:slug` | `GET` | CF Access | Download dynamic package bytes from R2 |
| `/api/store/schematics` | `GET` / `POST` | CF Access | List or publish Create `.nbt` / Lua schematics |
| `/api/store/schematics/download/:slug` | `GET` | CF Access | Download schematic artifact from R2 |
| `/api/recipes/ingest` | `POST` | CF Access | Deduplicated batch upsert of items, recipes, and ingredients |
| `/api/recipes/lookup?item=<id>` | `GET` | CF Access | Bidirectional item recipe lookup (`produced_by` & `used_in`) |
| `/api/specs` | `GET` / `POST` | CF Access | Lookup (`?type=`) or upsert peripheral API specs in D1 |
| `/ws?role=gateway&world=<w>&net=<n>` | `GET` (WS) | CF Access | Hibernating WebSocket bridge to `CcMeshBridge` DO (`role=gateway\|mcp`) |
| `/mcp?world=<w>` | `POST` | CF Access | MCP JSON-RPC 2.0 endpoint (`initialize`, `tools/*`, `resources/*`) |

---

## MCP Tools & Resources

### Built-in MCP Tools
- `list_network_topology` — Lists live network entities enriched with synthesized D1 `device_api_specs`.
- `enqueue_task` — Enqueues arbitrary Lua code targeting a gateway or Rednet runner and sends an immediate `WAKE`.
- `get_task_output` — Retrieves task status, captured `stdout`, structured `result`, or `error`.
- `register_learned_tool` — Saves a reusable Lua template in DO SQLite, dynamically exposing it as `cc_<name>`.
- `save_device_api_spec` — Persists a synthesized peripheral spec into D1 `device_api_specs` and clears pending status.
- `synthesize_device_spec` — Triggers MCP `sampling/createMessage` (when a sampling-capable client is connected) or returns a structured synthesis prompt + raw `std.get_api` probe data.

### Seeded `cc_*` Learned Tools (delegating to `require("lib.std")`)
- `cc_list_attachment` — Lists attached peripherals with types and method tables.
- `cc_list_inventory` — Aggregates and filters inventory items (`mod`, `name`, `tag`, `min_count`, `peripheral`).
- `cc_get_api` — Runs safe read-only introspection (`std.get_api`) on a peripheral.
- `cc_probe_network` — Runs local peripheral enumeration + Rednet `DISCOVER` sweep.
- `cc_run_script_test` — Executes an ad-hoc Lua snippet with `std` and `params` preloaded.
- `cc_install_script` — Writes a script directly or downloads it from the Static or D1/R2 App Store.

### MCP Resources
- `cc://specs/pending` — Attached peripherals awaiting API spec synthesis (including raw `std.get_api` probe metadata).
- `cc://specs/all` — All synthesized peripheral API specifications stored in D1.

---

## Scripts

```bash
npm run dev          # Start local Wrangler dev server
npm run deploy       # Deploy Worker + Durable Object to Cloudflare
npm run cf-typegen   # Regenerate worker-configuration.d.ts from wrangler.jsonc
npm run typecheck    # Run TypeScript type checking (tsc --noEmit)
npm run test:worker  # Run Worker & Durable Object Vitest suites (Miniflare)
npm run test:lua     # Run headless CC: Tweaked Lua test suite via wasmoon
npm run test:e2e     # Run live wrangler dev + real WebSocket + wasmoon Lua E2E suite
npm run test:all     # Run test:worker + test:lua + test:e2e
```

---

## Quick Setup & Deployment Checklist

### 1. Provisioned Cloudflare Resources (`cc.pants.place`)
- **Custom Domain:** `https://cc.pants.place` (MCP endpoint: `https://cc.pants.place/mcp`)
- **D1 Database:** `cc-mesh-catalog` (`b740905c-b6da-4c6c-a361-3860f17d92a8`)
- **R2 Bucket:** `cc-mesh-artifacts`
- **Durable Object:** `CcMeshBridge` (`v1` SQLite migration)

To re-apply migrations or redeploy:
```bash
npx wrangler d1 migrations apply CATALOG_DB --remote
npm run deploy
```

### 2. Cloudflare Access Protection & Generating an Access Token
`cc.pants.place` is protected by Cloudflare Access (`pants-place.cloudflareaccess.com`):
- **`cc-mcp`** (`cc.pants.place`, covering `/mcp`, `/ws`, `/api/*`, `/lua/*`):
  - **Managed OAuth (`oauth_configuration.enabled = true`)** with Dynamic Client Registration enabled for MCP clients.
  - **Allow** (`Admin & ComputerCraft Groups (OIDC)`) — restricted strictly to Authentik (`Pants' Place Auth`) users in the **`admin`** or **`computercraft`** OIDC groups.
  - **Service Auth** — least-privilege policy bound strictly to your dedicated CC: Tweaked Service Token ID (created by `./scripts/mint-access-token.sh`).
- **`cc-mcp-bootstrap`** (`cc.pants.place/init.lua` & `cc.pants.place/lua/bootstrap.lua`):
  - **Bypass** (`everyone`) — allows fresh in-game computers to fetch `startup.lua` via `wget`.

#### Option A: Connect MCP Clients Directly via Managed OAuth + Authentik (No Static Token Needed)
```bash
agy mcp add --type http cc-mcp https://cc.pants.place/mcp
```
Then run `/mcp` in Antigravity CLI to complete the Authentik browser login.

#### Option B: Mint a Least-Privilege Service Token (Zero-Leak Local Script for CC: Tweaked)
Create a least-privilege Cloudflare API token at https://dash.cloudflare.com/profile/api-tokens with ONLY:
- **Account → Access: Service Tokens → Edit**
- **Account → Access: Apps and Policies → Edit**

Then run:
```bash
CF_API_TOKEN="<your-cf-api-token>" ./scripts/mint-access-token.sh
```
This writes `.cf-access.env` (`chmod 600`, gitignored) without ever printing `CF_ACCESS_CLIENT_SECRET`, and automatically creates a `non_identity` Service Auth policy on `cc.pants.place` scoped strictly to that single `token_id`.

#### Option C: Generate a Short-Lived User Access JWT (via `cloudflared`)
```bash
cloudflared access login https://cc.pants.place/mcp
cloudflared access token -app=https://cc.pants.place/mcp
```

### 3. Bootstrap an In-Game CC: Tweaked Computer
See [`docs/in-game-testing.md`](docs/in-game-testing.md) for the complete in-game verification checklist.

On your in-game **Gateway** computer (with a wired/ender modem and an optional redstone clock connected to the `back` side):
```lua
wget https://cc.pants.place/init.lua startup.lua
set mcp.url https://cc.pants.place
set mcp.role gateway
set mcp.world overworld
set mcp.net main
set mcp.clock_side back
set mcp.cf_id <your-cf-access-client-id>
set mcp.cf_secret <your-cf-access-client-secret>
reboot
```

On **Runner / Turtle** nodes (connected via Rednet):
```lua
wget https://cc.pants.place/init.lua startup.lua
set mcp.url https://cc.pants.place
set mcp.role runner
set mcp.cf_id <your-cf-access-client-id>
set mcp.cf_secret <your-cf-access-client-secret>
reboot
```

### 4. Using the In-Game Package Manager (`pkg.lua`)
```text
pkg list
pkg install spider
pkg install inv_mon --static /apps/inv_mon.lua
pkg publish my_farm "Tree Farm Controller" /my_farm.lua
pkg schematics list
pkg schematics install smelter_v1 /schematics/smelter_v1.nbt
```
