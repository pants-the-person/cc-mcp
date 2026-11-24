# In-Game CC: Tweaked Testing Checklist (Deferred)

> **Status:** Pending — PC was busy during initial deployment on 2026-11-24. All automated tests (Worker Vitest 15/15, Lua `wasmoon` 9/9, live `wrangler dev` + WebSocket E2E 9/9) and live Cloudflare edge/Access deployment checks on `https://cc.pants.place` have already passed.

---

## Prerequisites Before Testing In-Game

1. **Mint the least-privilege CC: Tweaked Service Token** (keeps `CF_ACCESS_CLIENT_SECRET` out of AI transcripts and binds Access strictly to that single token ID):
   ```bash
   CF_API_TOKEN="<token-with-Access-ServiceTokens:Edit-and-Access-Apps:Edit>" \
     ./scripts/mint-access-token.sh
   ```
   This writes `.cf-access.env` (`chmod 600`, gitignored) and attaches a `non_identity` Service Auth policy on `cc.pants.place` scoped only to that token ID.

2. **Connect your MCP Client (via Managed OAuth + Authentik OIDC):**
   - `https://cc.pants.place/mcp` has Cloudflare Access **Managed OAuth** enabled.
   - Access is restricted to Authentik (`Pants' Place Auth`) users in the **`admin`** or **`computercraft`** OIDC groups.
   - Add `cc-mcp` to Antigravity CLI (no static token needed!):
     ```bash
     agy mcp add --type http cc-mcp https://cc.pants.place/mcp
     ```
   - Run `/mcp` in Antigravity CLI and complete the Authentik browser OAuth login.

---

## In-Game Setup & Test Checklist

### 1. Gateway Computer Bootstrap
Place an Advanced Computer with:
- A **Wired Modem** (connected to chests/machines/peripherals) and/or **Wireless/Ender Modem** (for Rednet runners)
- A **Redstone Clock** (repeater loop, Create Sequenced Gearshift, or Redstone Clock block) facing its `back` side (or change `mcp.clock_side`)

Run in the CC: Tweaked terminal (read `CF_ACCESS_CLIENT_ID` and `CF_ACCESS_CLIENT_SECRET` locally from `.cf-access.env`):
```lua
wget https://cc.pants.place/init.lua startup.lua
set mcp.url https://cc.pants.place
set mcp.role gateway
set mcp.world overworld
set mcp.net main
set mcp.clock_side back
set mcp.cf_id <CF_ACCESS_CLIENT_ID>
set mcp.cf_secret <CF_ACCESS_CLIENT_SECRET>
reboot
```

**Verify:**
- [ ] `wget https://cc.pants.place/init.lua startup.lua` succeeds without auth (Access Bypass).
- [ ] On boot, `startup.lua` downloads `/lib/std.lua`, `/pkg.lua`, `/gateway.lua`, and `/runner.lua` and saves `/.mesh_manifest`.
- [ ] Rebooting a second time skips re-downloading unchanged files (SHA-256 manifest cache hit).
- [ ] Gateway connects to `wss://cc.pants.place/ws?role=gateway&world=overworld&net=main` and prints `[mesh] Synced N entities`.

### 2. Runner / Turtle Node Bootstrap
On any Rednet-connected Computer or Turtle:
```lua
wget https://cc.pants.place/init.lua startup.lua
set mcp.url https://cc.pants.place
set mcp.role runner
set mcp.cf_id <CF_ACCESS_CLIENT_ID>
set mcp.cf_secret <CF_ACCESS_CLIENT_SECRET>
reboot
```

**Verify:**
- [ ] Runner prints `[runner] Online (...)` and responds to Gateway `DISCOVER` pings.
- [ ] Runner appears in MCP `list_network_topology`.

### 3. Live MCP Round-Trip & Redstone Pacing
- [ ] Call `list_network_topology` via MCP (`https://cc.pants.place/mcp`) — confirms gateway, attached peripherals, and Rednet runners.
- [ ] While idle, confirm the redstone clock ticking does **not** wake/spam the Durable Object (check `wrangler tail` — should be silent when no tasks are pending).
- [ ] Call `cc_list_inventory` via MCP → verify `WAKE` arrives, next redstone clock pulse drains the task, and `get_task_output` returns real in-game chest/ME inventory totals.
- [ ] Call `cc_probe_network` via MCP → verify peripherals + Rednet runners return cleanly.
- [ ] Call `enqueue_task` targeting a runner/turtle label with `print("hello from turtle"); return 42` → verify captured `stdout` and `result`.

### 4. Dynamic Device API Spec Discovery (Hot-Plug)
- [ ] Attach a modded peripheral block (e.g., Create Display Link, Mekanism machine, or Advanced Peripherals ME Bridge) onto the wired modem network.
- [ ] Read MCP resource `cc://specs/pending` → confirm the newly attached device appears with raw `std.get_api` methods & safe read-only metadata.
- [ ] Call `synthesize_device_spec` / `save_device_api_spec` → confirm the spec persists to D1 (`GET https://cc.pants.place/api/specs?type=...`) and enriches `list_network_topology`.

### 5. Dual App Store (`pkg.lua`) & Recipe Spider
- [ ] Run `pkg list` on a computer → confirms `[static]` apps (`spider`, `inv_mon`, `net_diag`) and `[store]` packages.
- [ ] Run `pkg install inv_mon` and `inv_mon --once` → verifies Static App Store download & `lib.std` execution.
- [ ] Run `pkg install spider` and `spider` → verifies `/api/recipes/ingest` upload + local deduplication on a second run.
