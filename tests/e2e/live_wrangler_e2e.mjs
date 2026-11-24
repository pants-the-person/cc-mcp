import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync, rmSync } from "node:fs";
import { resolve } from "node:path";
import { LuaFactory } from "wasmoon";
import WebSocket from "ws";

const ROOT = resolve(process.cwd());
const PORT = Number(process.env.E2E_PORT || 8787);
const HOST = "127.0.0.1";
const BASE_URL = `http://${HOST}:${PORT}`;
const PERSIST_DIR = resolve(ROOT, ".wrangler/e2e-state");
const AUTH_EMAIL = "e2e@cc-mesh.local";
const AUTH_HEADERS = {
  "Cf-Access-Authenticated-User-Email": AUTH_EMAIL,
};

const LUA_FILES_TO_MOUNT = [
  "src/lua/lib/std.lua",
  "src/lua/gateway.lua",
  "src/lua/runner.lua",
  "tests/lua/mock_cc.lua",
];

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function sha256Hex(content) {
  return createHash("sha256").update(content, "utf8").digest("hex");
}

function cleanupStateDir() {
  rmSync(PERSIST_DIR, { recursive: true, force: true });
}

function applyD1Migrations() {
  const res = spawnSync(
    "npx",
    [
      "wrangler",
      "d1",
      "migrations",
      "apply",
      "CATALOG_DB",
      "--local",
      "--persist-to",
      PERSIST_DIR,
      "-y",
    ],
    {
      cwd: ROOT,
      encoding: "utf8",
      env: { ...process.env, CI: "true" },
    },
  );
  if (res.status !== 0) {
    throw new Error(
      `Failed to apply D1 migrations (exit ${res.status}):\n${res.stdout}\n${res.stderr}`,
    );
  }
}

async function startWranglerDev() {
  const logs = [];
  const child = spawn(
    "npx",
    [
      "wrangler",
      "dev",
      "--local",
      "--port",
      String(PORT),
      "--ip",
      HOST,
      "--persist-to",
      PERSIST_DIR,
      "--show-interactive-dev-session=false",
    ],
    {
      cwd: ROOT,
      stdio: ["ignore", "pipe", "pipe"],
      detached: process.platform !== "win32",
      env: { ...process.env, CI: "true" },
    },
  );

  const onData = (chunk) => {
    const text = chunk.toString("utf8");
    logs.push(text);
    if (logs.length > 200) {
      logs.shift();
    }
  };
  child.stdout.on("data", onData);
  child.stderr.on("data", onData);

  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) {
      throw new Error(
        `wrangler dev exited prematurely (code ${child.exitCode}):\n${logs.join("")}`,
      );
    }
    try {
      const resp = await fetch(`${BASE_URL}/`);
      if (resp.ok) {
        const body = await resp.json();
        if (body && body.service === "cc-mesh-bridge" && body.status === "ok") {
          return { child, getLogs: () => logs.join("") };
        }
      }
    } catch {
      // Server not ready yet
    }
    await sleep(200);
  }

  throw new Error(
    `Timed out waiting for wrangler dev at ${BASE_URL}:\n${logs.join("")}`,
  );
}

function killProcessTree(child, signal) {
  if (!child || child.exitCode !== null) {
    return;
  }
  try {
    if (process.platform !== "win32" && typeof child.pid === "number") {
      process.kill(-child.pid, signal);
      return;
    }
  } catch {
    // Fall back to direct child kill
  }
  try {
    child.kill(signal);
  } catch {
    // Process already exited
  }
}

async function stopWranglerDev(child) {
  if (!child || child.exitCode !== null) {
    return;
  }
  await new Promise((resolveStop) => {
    let settled = false;
    const done = () => {
      if (!settled) {
        settled = true;
        resolveStop();
      }
    };
    child.once("exit", done);
    killProcessTree(child, "SIGTERM");
    setTimeout(() => {
      if (!settled && child.exitCode === null) {
        killProcessTree(child, "SIGKILL");
      }
      done();
    }, 4000);
  });
}

let rpcSeq = 1;

async function mcpCall(method, params = {}, world = "e2e") {
  const id = rpcSeq++;
  const resp = await fetch(`${BASE_URL}/mcp?world=${encodeURIComponent(world)}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...AUTH_HEADERS,
    },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id,
      method,
      params,
    }),
  });
  assert.equal(resp.status, 200, `MCP ${method} returned HTTP ${resp.status}`);
  const body = await resp.json();
  assert.equal(body.jsonrpc, "2.0");
  assert.equal(body.id, id);
  if (body.error) {
    throw new Error(
      `MCP ${method} JSON-RPC error ${body.error.code}: ${body.error.message}`,
    );
  }
  return body.result;
}

async function mcpToolCall(name, args = {}, world = "e2e") {
  const result = await mcpCall("tools/call", { name, arguments: args }, world);
  assert.ok(Array.isArray(result.content) && result.content.length > 0);
  assert.notEqual(result.isError, true, `Tool ${name} returned isError: ${result.content[0]?.text}`);
  return JSON.parse(result.content[0].text);
}

async function mcpReadResource(uri, world = "e2e") {
  const result = await mcpCall("resources/read", { uri }, world);
  assert.ok(Array.isArray(result.contents) && result.contents.length > 0);
  return JSON.parse(result.contents[0].text);
}

async function waitForCondition(predicate, timeoutMs, tickFn, label) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (tickFn) {
      await tickFn();
    }
    const val = predicate();
    if (val) {
      return val;
    }
    await sleep(25);
  }
  throw new Error(`Timed out after ${timeoutMs}ms waiting for: ${label}`);
}

async function runTests() {
  let wranglerProc = null;
  let lua = null;
  let activeWs = null;
  let passed = 0;

  const pass = (msg) => {
    passed += 1;
    console.log(`[PASS] ${msg}`);
  };

  const handleSignal = () => {
    if (activeWs) {
      try {
        activeWs.terminate();
      } catch {
        // ignore
      }
    }
    if (wranglerProc && wranglerProc.exitCode === null) {
      killProcessTree(wranglerProc, "SIGKILL");
    }
    cleanupStateDir();
    process.exit(130);
  };
  process.on("SIGINT", handleSignal);
  process.on("SIGTERM", handleSignal);

  try {
    // -----------------------------------------------------------------------
    // 0. Isolated State + Local D1 Migrations + Live wrangler dev --local
    // -----------------------------------------------------------------------
    cleanupStateDir();
    applyD1Migrations();
    const dev = await startWranglerDev();
    wranglerProc = dev.child;
    pass(`Live wrangler dev --local started at ${BASE_URL} with D1 migrations applied`);

    // -----------------------------------------------------------------------
    // 1. Edge Auth Enforcement (REQUIRE_CF_ACCESS = "true")
    // -----------------------------------------------------------------------
    {
      const bootResp = await fetch(`${BASE_URL}/lua/bootstrap.lua`);
      assert.equal(bootResp.status, 200, "Unauthenticated /lua/bootstrap.lua must return 200");
      const bootBody = await bootResp.text();
      const diskBoot = readFileSync(resolve(ROOT, "src/lua/bootstrap.lua"), "utf8");
      assert.equal(bootBody, diskBoot, "/lua/bootstrap.lua body must match disk file");

      const unauthStore = await fetch(`${BASE_URL}/api/store/static`);
      assert.equal(unauthStore.status, 401, "Unauthenticated /api/store/static must return 401");

      const unauthMcp = await fetch(`${BASE_URL}/mcp?world=e2e`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 0, method: "tools/list", params: {} }),
      });
      assert.equal(unauthMcp.status, 401, "Unauthenticated /mcp must return 401");

      // Unauthenticated WebSocket upgrade must also be rejected with 401
      const wsStatus = await new Promise((resolveWs) => {
        const ws = new WebSocket(`ws://${HOST}:${PORT}/ws?role=gateway&world=e2e&net=main`);
        ws.once("unexpected-response", (_req, res) => {
          ws.close();
          resolveWs(res.statusCode);
        });
        ws.once("open", () => {
          ws.close();
          resolveWs(101);
        });
        ws.once("error", () => {
          // unexpected-response fires before error on HTTP rejection
        });
      });
      assert.equal(wsStatus, 401, "Unauthenticated /ws upgrade must return 401");
      pass("CF Access auth gate verified (bootstrap 200, unauthenticated API/MCP/WS 401)");
    }

    // -----------------------------------------------------------------------
    // 2. Boot Real Lua gateway.lua + runner.lua + lib/std.lua in wasmoon
    //    bridged to REAL local WebSocket ws://127.0.0.1:8787/ws
    // -----------------------------------------------------------------------
    const factory = new LuaFactory();
    for (const relPath of LUA_FILES_TO_MOUNT) {
      const content = readFileSync(resolve(ROOT, relPath), "utf8");
      await factory.mountFile(relPath, content);
    }
    lua = await factory.createEngine();

    const sentFrames = [];
    const receivedFrames = [];
    const inboundQueue = [];
    const outboundBuffer = [];
    let connectedWsUrl = null;
    let wsOpened = false;
    let wsClosed = false;
    let wsError = null;
    let luaPassedCfHeaders = null;

    lua.global.set("js_ws_open", (url, headersObj) => {
      connectedWsUrl = url;
      luaPassedCfHeaders = headersObj || {};
      const wsHeaders = {
        ...luaPassedCfHeaders,
        ...AUTH_HEADERS,
      };
      const ws = new WebSocket(url, { headers: wsHeaders });
      activeWs = ws;

      ws.on("open", () => {
        wsOpened = true;
        while (outboundBuffer.length > 0) {
          const raw = outboundBuffer.shift();
          ws.send(raw);
        }
      });

      ws.on("message", (data) => {
        const raw = typeof data === "string" ? data : data.toString("utf8");
        try {
          receivedFrames.push(JSON.parse(raw));
        } catch {
          receivedFrames.push({ _raw: raw });
        }
        inboundQueue.push(raw);
      });

      ws.on("close", () => {
        wsClosed = true;
      });

      ws.on("error", (err) => {
        wsError = err;
      });
    });

    lua.global.set("js_ws_send", (raw) => {
      try {
        sentFrames.push(JSON.parse(raw));
      } catch {
        sentFrames.push({ _raw: raw });
      }
      if (activeWs && wsOpened && activeWs.readyState === WebSocket.OPEN) {
        activeWs.send(raw);
      } else {
        outboundBuffer.push(raw);
      }
    });

    lua.global.set("js_ws_close", () => {
      if (activeWs) {
        activeWs.close();
      }
    });

    await lua.doString(`
      mock_cc = dofile("tests/lua/mock_cc.lua")
      world = mock_cc.new_world()

      -- 1. Live runner.lua node labeled "turtle_1"
      runner = world:new_computer({
        id = 2,
        label = "turtle_1",
        is_turtle = true,
        settings = {
          ["mcp.role"] = "runner",
        },
      })
      runner:attach_peripheral("left", { "modem" }, {
        isWireless = function() return false end,
      }, false)
      runner:start_daemon(mock_cc.read_disk_file("src/lua/runner.lua"), "runner.lua")

      -- 2. Live gateway.lua node with wired modem + inventory chest
      gateway = world:new_computer({
        id = 1,
        label = "gateway_1",
        settings = {
          ["mcp.url"] = "${BASE_URL}",
          ["mcp.role"] = "gateway",
          ["mcp.world"] = "e2e",
          ["mcp.net"] = "main",
          ["mcp.clock_side"] = "back",
          ["mcp.cf_id"] = "e2e-client-id",
          ["mcp.cf_secret"] = "e2e-client-secret",
          ["mcp.probe_timeout"] = 0.1,
          ["mcp.fallback_poll_interval"] = 300,
          ["mcp.max_reconnects"] = 0,
        },
      })

      gateway:attach_peripheral("left", { "modem" }, {
        isWireless = function() return false end,
      }, false)

      gateway:attach_peripheral("minecraft:chest_0", { "minecraft:chest", "inventory" }, {
        size = function() return 27 end,
        list = function()
          return {
            [1] = { name = "mekanism:ingot_osmium", count = 64, displayName = "Osmium Ingot" },
            [2] = { name = "minecraft:iron_ingot", count = 32, displayName = "Iron Ingot" },
          }
        end,
        getItemDetail = function(slot)
          if slot == 1 then
            return { name = "mekanism:ingot_osmium", count = 64, displayName = "Osmium Ingot", tags = { ["forge:ingots/osmium"] = true } }
          elseif slot == 2 then
            return { name = "minecraft:iron_ingot", count = 32, displayName = "Iron Ingot", tags = { ["forge:ingots/iron"] = true } }
          end
          return nil
        end,
      }, false)

      -- Bridge gateway.env.http.websocket to the REAL local WebSocket in Node
      gateway.env.http.websocket = function(url, headers)
        js_ws_open(url, headers or {})
        local closed = false
        return {
          send = function(msg)
            if closed then error("WebSocket is closed") end
            js_ws_send(tostring(msg))
          end,
          close = function()
            closed = true
            js_ws_close()
          end,
        }, nil
      end

      display_link_mutated = false
      function attach_display_link()
        gateway:attach_peripheral("displayLink_0", { "create:display_link" }, {
          getSize = function() return { width = 16, height = 4 } end,
          getLine = function(n) return "Line " .. tostring(n or 1) end,
          setCursorPos = function() display_link_mutated = true end,
          write = function() display_link_mutated = true end,
          update = function() display_link_mutated = true end,
        }, true)
        world:pump()
      end

      function deliver_ws_message(raw)
        gateway:queue_event("websocket_message", nil, raw, false)
        world:pump()
      end

      function pulse_gateway_redstone(times)
        for _ = 1, (times or 1) do
          gateway:pulse_redstone("back")
        end
      end

      function pump_world(advance_dt)
        if advance_dt and advance_dt > 0 then
          world:advance_time(advance_dt)
        else
          world:pump()
        end
      end

      gateway:start_daemon(mock_cc.read_disk_file("src/lua/gateway.lua"), "gateway.lua")
      -- Pump runner + gateway startup; advance mock clock past 0.1s initial probe_network timeout
      world:pump()
      world:advance_time(0.15)
    `);

    const deliverWsMsg = lua.global.get("deliver_ws_message");
    const pumpWorld = lua.global.get("pump_world");
    const pulseGatewayRedstone = lua.global.get("pulse_gateway_redstone");
    const attachDisplayLink = lua.global.get("attach_display_link");

    const pumpAll = (advanceDt = 0) => {
      if (wsError) {
        throw wsError;
      }
      while (inboundQueue.length > 0) {
        const raw = inboundQueue.shift();
        deliverWsMsg(raw);
      }
      if (advanceDt > 0) {
        pumpWorld(advanceDt);
      } else {
        pumpWorld(0);
      }
    };

    await waitForCondition(
      () =>
        wsOpened &&
        receivedFrames.some(
          (f) => f.type === "ACK" && f.ref_type === "SYNC_TOPOLOGY" && f.ok === true,
        ),
      10_000,
      () => pumpAll(0),
      "Real WebSocket open + SYNC_TOPOLOGY ACK from CcMeshBridge DO",
    );

    assert.ok(
      connectedWsUrl &&
        connectedWsUrl.startsWith(`ws://${HOST}:${PORT}/ws?role=gateway&world=e2e&net=main`),
      `Unexpected gateway WS URL: ${connectedWsUrl}`,
    );
    assert.equal(luaPassedCfHeaders["CF-Access-Client-Id"], "e2e-client-id");
    assert.equal(luaPassedCfHeaders["CF-Access-Client-Secret"], "e2e-client-secret");
    pass("Real Lua gateway.lua + runner.lua connected over live WebSocket and synced topology");

    // Initialize MCP session
    const initRes = await mcpCall("initialize", {
      protocolVersion: "2024-11-05",
      capabilities: {},
      clientInfo: { name: "e2e-harness", version: "1.0.0" },
    });
    assert.equal(initRes.serverInfo.name, "cc-mesh-bridge");

    // -----------------------------------------------------------------------
    // 3. Scenario 1: Dynamic Peripheral Attach -> cc://specs/pending ->
    //    save_device_api_spec -> D1 persistence
    // -----------------------------------------------------------------------
    {
      const ackCountBefore = receivedFrames.filter(
        (f) => f.type === "ACK" && f.ref_type === "PERIPHERAL_ATTACHED",
      ).length;

      attachDisplayLink();
      pumpAll(0);

      await waitForCondition(
        () =>
          receivedFrames.filter(
            (f) => f.type === "ACK" && f.ref_type === "PERIPHERAL_ATTACHED",
          ).length > ackCountBefore,
        10_000,
        () => pumpAll(0),
        "PERIPHERAL_ATTACHED ACK for create:display_link",
      );

      // Verify std.get_api did NOT invoke mutating methods on displayLink_0
      const mutated = lua.global.get("display_link_mutated");
      assert.equal(mutated, false, "std.get_api must never invoke mutating peripheral methods");

      // Confirm gateway.lua actually sent PERIPHERAL_ATTACHED with probe data
      const attachFrame = sentFrames.find(
        (f) => f.type === "PERIPHERAL_ATTACHED" && f.name === "displayLink_0",
      );
      assert.ok(attachFrame, "gateway.lua must send PERIPHERAL_ATTACHED for displayLink_0");
      assert.equal(attachFrame.type_name, "create:display_link");
      assert.deepEqual(
        [...attachFrame.methods].sort(),
        ["getLine", "getSize", "setCursorPos", "update", "write"],
      );

      // Read cc://specs/pending via MCP
      const pendingBefore = await mcpReadResource("cc://specs/pending");
      const pendingDisplayLink = pendingBefore.pending.find(
        (e) => e.type_name === "create:display_link",
      );
      assert.ok(
        pendingDisplayLink,
        "create:display_link must appear in cc://specs/pending",
      );
      assert.equal(pendingDisplayLink.name, "displayLink_0");
      assert.deepEqual(
        [...pendingDisplayLink.methods].sort(),
        ["getLine", "getSize", "setCursorPos", "update", "write"],
      );
      assert.ok(
        pendingDisplayLink.probe &&
          pendingDisplayLink.probe.type_name === "create:display_link" &&
          pendingDisplayLink.probe.metadata &&
          pendingDisplayLink.probe.metadata.getSize?.width === 16,
        `cc://specs/pending entry must include raw std.get_api probe data: ${JSON.stringify(pendingDisplayLink.probe)}`,
      );

      // Call save_device_api_spec via MCP
      const saveRes = await mcpToolCall("save_device_api_spec", {
        type_name: "create:display_link",
        methods: pendingDisplayLink.methods,
        spec_json: {
          summary: "Create mod Display Link peripheral for updating display boards.",
          readonly_methods: ["getSize", "getLine"],
          mutating_methods: ["setCursorPos", "write", "update"],
        },
        spec_markdown:
          "# create:display_link\n\nWrite text lines and call `update()` to refresh the Create Display Board.",
        generated_by: "e2e-agent",
      });
      assert.equal(saveRes.ok, true);
      assert.equal(saveRes.spec.type_name, "create:display_link");
      assert.ok(saveRes.entities_updated >= 1);

      // Confirm D1 persistence via GET /api/specs?type=create:display_link
      const apiSpecResp = await fetch(
        `${BASE_URL}/api/specs?type=${encodeURIComponent("create:display_link")}`,
        { headers: AUTH_HEADERS },
      );
      assert.equal(apiSpecResp.status, 200, "GET /api/specs?type=create:display_link must return 200");
      const apiSpec = await apiSpecResp.json();
      assert.equal(apiSpec.type_name, "create:display_link");
      assert.equal(apiSpec.generated_by, "e2e-agent");
      assert.deepEqual(
        [...apiSpec.methods].sort(),
        ["getLine", "getSize", "setCursorPos", "update", "write"],
      );
      assert.equal(
        apiSpec.spec_json.summary,
        "Create mod Display Link peripheral for updating display boards.",
      );

      // Confirm cc://specs/all includes create:display_link
      const allSpecs = await mcpReadResource("cc://specs/all");
      assert.ok(
        allSpecs.specs.some((s) => s.type_name === "create:display_link"),
        "cc://specs/all must contain create:display_link",
      );

      // Confirm create:display_link disappeared from cc://specs/pending
      const pendingAfter = await mcpReadResource("cc://specs/pending");
      assert.equal(
        pendingAfter.pending.some((e) => e.type_name === "create:display_link"),
        false,
        "create:display_link must no longer appear in cc://specs/pending after saving spec",
      );

      pass(
        "Scenario 1: Hot-plug create:display_link -> cc://specs/pending -> save_device_api_spec -> persisted in D1 & cleared from pending",
      );
    }

    // -----------------------------------------------------------------------
    // 4. Scenario 2: Idle Silence + cc_list_inventory + cc_probe_network +
    //    Remote Rednet Runner Task via Redstone Pulse
    // -----------------------------------------------------------------------
    {
      // 4a. Idle Silence: 10 redstone pulses while idle must send 0 POLL_QUEUE frames
      const pollsBeforeIdle = sentFrames.filter((f) => f.type === "POLL_QUEUE").length;
      assert.equal(pollsBeforeIdle, 0, "Expected 0 POLL_QUEUE frames before idle test");
      pulseGatewayRedstone(10);
      pumpAll(0);
      await sleep(100);
      pumpAll(0);
      const pollsAfterIdle = sentFrames.filter((f) => f.type === "POLL_QUEUE").length;
      assert.equal(
        pollsAfterIdle,
        0,
        "gateway.lua must remain completely silent (0 POLL_QUEUE) on redstone pulses when idle",
      );
      pass("Scenario 2a: Idle silence verified (10 redstone pulses while idle = 0 POLL_QUEUE)");

      // 4b. cc_list_inventory with { mod: "mekanism", min_count: 10 }
      const invCall = await mcpToolCall("cc_list_inventory", {
        mod: "mekanism",
        min_count: 10,
      });
      assert.ok(invCall.task_id, "cc_list_inventory must return task_id");
      assert.ok(
        invCall.woke_gateways >= 1,
        `Expected woke_gateways >= 1, got ${invCall.woke_gateways}`,
      );

      // Confirm live Lua gateway receives WAKE over real WebSocket
      await waitForCondition(
        () => receivedFrames.some((f) => f.type === "WAKE" && f.task_id === invCall.task_id),
        10_000,
        () => pumpAll(0),
        `WAKE frame for ${invCall.task_id}`,
      );
      // Still 0 POLL_QUEUE before redstone clock pulse!
      assert.equal(
        sentFrames.filter((f) => f.type === "POLL_QUEUE").length,
        0,
        "gateway.lua must wait for redstone pulse before sending POLL_QUEUE",
      );

      // Trigger simulated redstone pulse -> POLL_QUEUE -> DISPATCH_BATCH -> std.list_inventory -> TASK_RESULT
      pulseGatewayRedstone(1);

      await waitForCondition(
        () =>
          receivedFrames.some(
            (f) => f.type === "ACK" && f.ref_type === "TASK_RESULT" && f.task_id === invCall.task_id,
          ),
        10_000,
        () => pumpAll(0),
        `TASK_RESULT ACK for cc_list_inventory (${invCall.task_id})`,
      );

      const invOutput = await mcpToolCall("get_task_output", {
        task_id: invCall.task_id,
      });
      assert.equal(invOutput.ok, true, `cc_list_inventory failed: ${invOutput.error}`);
      assert.equal(invOutput.status, "completed");
      assert.ok(invOutput.result && Array.isArray(invOutput.result.items));
      assert.equal(
        invOutput.result.items.length,
        1,
        `Expected only mekanism:ingot_osmium, got ${JSON.stringify(invOutput.result.items)}`,
      );
      assert.equal(invOutput.result.items[0].name, "mekanism:ingot_osmium");
      assert.equal(invOutput.result.items[0].count, 64);
      pass(
        "Scenario 2b: cc_list_inventory round-trip via WAKE + redstone pulse returned mekanism:ingot_osmium x64 (iron filtered out)",
      );

      // 4c. cc_probe_network via MCP + redstone pulse
      const probeCall = await mcpToolCall("cc_probe_network", {
        timeout: 0.1,
      });
      assert.ok(probeCall.task_id, "cc_probe_network must return task_id");

      await waitForCondition(
        () => receivedFrames.some((f) => f.type === "WAKE" && f.task_id === probeCall.task_id),
        10_000,
        () => pumpAll(0),
        `WAKE frame for cc_probe_network (${probeCall.task_id})`,
      );

      pulseGatewayRedstone(1);

      // Advance mock clock in small steps while pumping so std.probe_network(0.1) timer fires
      await waitForCondition(
        () =>
          receivedFrames.some(
            (f) =>
              f.type === "ACK" &&
              f.ref_type === "TASK_RESULT" &&
              f.task_id === probeCall.task_id,
          ),
        10_000,
        () => pumpAll(0.05),
        `TASK_RESULT ACK for cc_probe_network (${probeCall.task_id})`,
      );

      const probeOutput = await mcpToolCall("get_task_output", {
        task_id: probeCall.task_id,
      });
      assert.equal(probeOutput.ok, true, `cc_probe_network failed: ${probeOutput.error}`);
      assert.equal(probeOutput.status, "completed");
      assert.ok(
        probeOutput.result.peripherals.some((p) => p.name === "minecraft:chest_0"),
        "cc_probe_network must include minecraft:chest_0",
      );
      assert.ok(
        probeOutput.result.peripherals.some((p) => p.name === "displayLink_0"),
        "cc_probe_network must include hot-plugged displayLink_0",
      );
      assert.ok(
        probeOutput.result.runners.some(
          (r) => r.label === "turtle_1" && r.is_turtle === true,
        ),
        `cc_probe_network must discover live Rednet runner turtle_1: ${JSON.stringify(probeOutput.result.runners)}`,
      );
      pass(
        "Scenario 2c: cc_probe_network round-trip returned gateway peripherals (chest + displayLink_0) and Rednet runner turtle_1",
      );

      // 4d. Bonus: Remote Rednet task targeting live runner.lua ("turtle_1")
      const runnerCall = await mcpToolCall("enqueue_task", {
        target_node: "turtle_1",
        lua_code:
          'print("hello from " .. os.getComputerLabel()); return { fuel = turtle.getFuelLevel(), std_ver = std.VERSION }',
        args: {},
      });
      assert.ok(runnerCall.task_id, "enqueue_task for turtle_1 must return task_id");

      await waitForCondition(
        () => receivedFrames.some((f) => f.type === "WAKE" && f.task_id === runnerCall.task_id),
        10_000,
        () => pumpAll(0),
        `WAKE frame for turtle_1 task (${runnerCall.task_id})`,
      );

      pulseGatewayRedstone(1);

      await waitForCondition(
        () =>
          receivedFrames.some(
            (f) =>
              f.type === "ACK" &&
              f.ref_type === "TASK_RESULT" &&
              f.task_id === runnerCall.task_id,
          ),
        10_000,
        () => pumpAll(0),
        `TASK_RESULT ACK for turtle_1 task (${runnerCall.task_id})`,
      );

      const runnerOutput = await mcpToolCall("get_task_output", {
        task_id: runnerCall.task_id,
      });
      assert.equal(runnerOutput.ok, true, `turtle_1 task failed: ${runnerOutput.error}`);
      assert.equal(runnerOutput.stdout, "hello from turtle_1");
      assert.equal(runnerOutput.result.fuel, 1000);
      assert.equal(runnerOutput.result.std_ver, "1.0.0");
      pass(
        "Scenario 2d (Bonus): Remote Rednet task routed gateway.lua -> runner.lua ('turtle_1') returned captured stdout & result",
      );
    }

    // -----------------------------------------------------------------------
    // 5. Scenario 3: Static App Store Live HTTP Verification
    // -----------------------------------------------------------------------
    {
      const staticResp = await fetch(`${BASE_URL}/api/store/static`, {
        headers: AUTH_HEADERS,
      });
      assert.equal(staticResp.status, 200, "GET /api/store/static must return 200");
      const staticBody = await staticResp.json();
      assert.ok(Array.isArray(staticBody.apps));

      const bySlug = new Map(staticBody.apps.map((a) => [a.slug, a]));
      for (const slug of ["spider", "inv_mon", "net_diag"]) {
        const entry = bySlug.get(slug);
        assert.ok(entry, `/api/store/static missing app '${slug}'`);
        assert.match(entry.sha256, /^[0-9a-f]{64}$/, `Invalid sha256 for ${slug}`);
        const diskSource = readFileSync(
          resolve(ROOT, `src/lua/apps/${slug}.lua`),
          "utf8",
        );
        assert.equal(
          entry.sha256,
          sha256Hex(diskSource),
          `SHA-256 mismatch for static app ${slug}`,
        );
      }

      const netDiagResp = await fetch(`${BASE_URL}/lua/apps/net_diag.lua`, {
        headers: AUTH_HEADERS,
      });
      assert.equal(netDiagResp.status, 200, "GET /lua/apps/net_diag.lua must return 200");
      const netDiagBody = await netDiagResp.text();
      const diskNetDiag = readFileSync(
        resolve(ROOT, "src/lua/apps/net_diag.lua"),
        "utf8",
      );
      assert.equal(
        netDiagBody,
        diskNetDiag,
        "GET /lua/apps/net_diag.lua body must match exact disk contents",
      );

      pass(
        "Scenario 3: Static App Store (/api/store/static & /lua/apps/net_diag.lua) verified with exact SHA-256 and source bytes",
      );
    }

    assert.equal(wsClosed, false, "Gateway WebSocket should remain open until clean teardown");
    console.log(`\nLive Wrangler E2E Summary: ${passed}/${passed} passed, 0 failed`);
  } finally {
    process.off("SIGINT", handleSignal);
    process.off("SIGTERM", handleSignal);
    if (activeWs) {
      try {
        activeWs.close();
      } catch {
        // ignore
      }
    }
    if (lua) {
      try {
        lua.global.close();
      } catch {
        // ignore
      }
    }
    await stopWranglerDev(wranglerProc);
    cleanupStateDir();
  }
}

runTests().catch((err) => {
  console.error("E2E test failed:", err);
  process.exit(1);
});
