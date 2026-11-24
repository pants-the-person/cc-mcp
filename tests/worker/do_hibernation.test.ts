import {
  applyD1Migrations,
  runDurableObjectAlarm,
  runInDurableObject,
} from "cloudflare:test";
import { env, exports } from "cloudflare:workers";
import { afterEach, beforeAll, describe, expect, it } from "vitest";
import type { CcMeshBridge } from "../../src/bridge_do";
import type {
  DeviceApiSpec,
  DispatchedTask,
  EnrichedNetworkEntity,
  JsonRpcRequest,
  JsonRpcResponse,
  McpToolDefinition,
} from "../../src/protocol";

const AUTH_HEADERS = {
  "Cf-Access-Jwt-Assertion": "test-cf-access-jwt-token",
};

interface ManagedWs {
  ws: WebSocket;
  nextRaw: (timeoutMs?: number) => Promise<string>;
  nextJson: <T = Record<string, unknown>>(timeoutMs?: number) => Promise<T>;
  expectNoMessage: (waitMs?: number) => Promise<void>;
  sendJson: (payload: unknown) => void;
  close: () => Promise<void>;
}

const activeSockets: ManagedWs[] = [];

async function connectWs(pathWithQuery: string): Promise<ManagedWs> {
  const res = await exports.default.fetch(`https://cc-mcp.test${pathWithQuery}`, {
    headers: {
      ...AUTH_HEADERS,
      Upgrade: "websocket",
    },
  });
  expect(res.status).toBe(101);
  const ws = res.webSocket;
  expect(ws).toBeDefined();
  ws!.accept();

  const queue: string[] = [];
  const waiters: Array<{
    resolve: (msg: string) => void;
    reject: (err: Error) => void;
    timer: ReturnType<typeof setTimeout>;
  }> = [];

  let closed = false;
  let closeResolve: (() => void) | null = null;
  const closePromise = new Promise<void>((resolve) => {
    closeResolve = resolve;
  });

  ws!.addEventListener("message", (event) => {
    const text =
      typeof event.data === "string"
        ? event.data
        : new TextDecoder().decode(event.data as ArrayBuffer);
    const waiter = waiters.shift();
    if (waiter) {
      clearTimeout(waiter.timer);
      waiter.resolve(text);
    } else {
      queue.push(text);
    }
  });

  ws!.addEventListener("close", () => {
    closed = true;
    while (waiters.length > 0) {
      const w = waiters.shift()!;
      clearTimeout(w.timer);
      w.reject(new Error("WebSocket closed before expected message arrived"));
    }
    closeResolve?.();
  });

  const nextRaw = (timeoutMs = 2000): Promise<string> => {
    if (queue.length > 0) {
      return Promise.resolve(queue.shift()!);
    }
    if (closed) {
      return Promise.reject(new Error("WebSocket is already closed"));
    }
    return new Promise<string>((resolve, reject) => {
      const timer = setTimeout(() => {
        const idx = waiters.findIndex((w) => w.resolve === resolve);
        if (idx >= 0) waiters.splice(idx, 1);
        reject(new Error(`Timed out after ${timeoutMs}ms waiting for WS message`));
      }, timeoutMs);
      waiters.push({ resolve, reject, timer });
    });
  };

  const nextJson = async <T = Record<string, unknown>>(
    timeoutMs = 2000,
  ): Promise<T> => {
    const raw = await nextRaw(timeoutMs);
    return JSON.parse(raw) as T;
  };

  const expectNoMessage = async (waitMs = 120): Promise<void> => {
    if (queue.length > 0) {
      throw new Error(`Expected no WS message, but queue already had: ${queue[0]}`);
    }
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => {
        const idx = waiters.findIndex((w) => w.resolve === onMsg);
        if (idx >= 0) waiters.splice(idx, 1);
        resolve();
      }, waitMs);
      const onMsg = (msg: string) => {
        clearTimeout(timer);
        reject(new Error(`Expected no WS message, but received: ${msg}`));
      };
      waiters.push({ resolve: onMsg, reject, timer });
    });
  };

  const sendJson = (payload: unknown): void => {
    ws!.send(JSON.stringify(payload));
  };

  const close = async (): Promise<void> => {
    if (!closed) {
      try {
        ws!.close(1000, "test cleanup");
      } catch {
        // Already closing/closed
      }
      await Promise.race([
        closePromise,
        new Promise<void>((r) => setTimeout(r, 150)),
      ]);
      closed = true;
    }
  };

  const managed: ManagedWs = {
    ws: ws!,
    nextRaw,
    nextJson,
    expectNoMessage,
    sendJson,
    close,
  };
  activeSockets.push(managed);
  return managed;
}

let rpcSeq = 1;

async function mcpRpc<T = Record<string, unknown>>(
  world: string,
  method: string,
  params?: Record<string, unknown>,
  sessionId?: string,
): Promise<{ status: number; body: JsonRpcResponse & { result?: T } }> {
  const headers: Record<string, string> = {
    ...AUTH_HEADERS,
    "Content-Type": "application/json",
  };
  if (sessionId) {
    headers["Mcp-Session-Id"] = sessionId;
  }
  const res = await exports.default.fetch(
    `https://cc-mcp.test/mcp?world=${encodeURIComponent(world)}`,
    {
      method: "POST",
      headers,
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: rpcSeq++,
        method,
        params,
      }),
    },
  );
  const body = (await res.json()) as JsonRpcResponse & { result?: T };
  return { status: res.status, body };
}

async function mcpCallTool<T = Record<string, unknown>>(
  world: string,
  name: string,
  args: Record<string, unknown> = {},
): Promise<T> {
  const { status, body } = await mcpRpc<{
    content: Array<{ type: string; text: string }>;
    isError?: boolean;
  }>(world, "tools/call", { name, arguments: args });
  expect(status).toBe(200);
  expect(body.error, `Unexpected MCP error for ${name}: ${JSON.stringify(body.error)}`).toBeUndefined();
  expect(body.result?.isError).not.toBe(true);
  const text = body.result?.content?.[0]?.text ?? "{}";
  return JSON.parse(text) as T;
}

describe("Stage 2: Hibernation-Optimized CcMeshBridge DO, Queue Leases, Alarm TTL & Dynamic Spec Synthesis", () => {
  beforeAll(async () => {
    await applyD1Migrations(env.CATALOG_DB, env.TEST_MIGRATIONS);
  });

  afterEach(async () => {
    while (activeSockets.length > 0) {
      const sock = activeSockets.pop()!;
      await sock.close();
    }
  });

  it("auto-responds ping -> pong without waking webSocketMessage, persists serialized attachments, and supports KV_SET/KV_GET", async () => {
    const world = "hibernation-ping-world";
    const gw = await connectWs(
      `/ws?role=gateway&world=${world}&net=main&client_id=gw-ping-1`,
    );

    // 1. Auto-response: "ping" -> "pong" without running webSocketMessage
    gw.ws.send("ping");
    const pong = await gw.nextRaw();
    expect(pong).toBe("pong");

    const stub = env.BRIDGE_DO.get(env.BRIDGE_DO.idFromName(world));
    const inspection = await runInDurableObject(
      stub,
      async (instance: CcMeshBridge, state) => {
        const sockets = state.getWebSockets("role:gateway");
        const att = sockets[0]?.deserializeAttachment() as Record<string, unknown>;
        return {
          nonAutoMessageCount: instance.nonAutoMessageCount,
          socketCount: sockets.length,
          attachment: att,
        };
      },
    );

    expect(inspection.nonAutoMessageCount).toBe(0);
    expect(inspection.socketCount).toBe(1);
    expect(inspection.attachment.role).toBe("gateway");
    expect(inspection.attachment.world).toBe(world);
    expect(inspection.attachment.net).toBe("main");
    expect(inspection.attachment.clientId).toBe("gw-ping-1");

    // 2. KV_SET & KV_GET round-trip
    gw.sendJson({
      type: "KV_SET",
      key: "reactor/setpoint",
      value: { target_burn_rate: 4.5, enabled: true },
      request_id: "kv-1",
    });
    const setAck = await gw.nextJson<{ type: string; key: string; ok: boolean; request_id: string }>();
    expect(setAck).toMatchObject({
      type: "KV_ACK",
      key: "reactor/setpoint",
      ok: true,
      request_id: "kv-1",
    });

    gw.sendJson({ type: "KV_GET", key: "reactor/setpoint", request_id: "kv-2" });
    const getVal = await gw.nextJson<{
      type: string;
      key: string;
      found: boolean;
      value: { target_burn_rate: number; enabled: boolean };
      request_id: string;
    }>();
    expect(getVal.type).toBe("KV_VALUE");
    expect(getVal.found).toBe(true);
    expect(getVal.value).toEqual({ target_burn_rate: 4.5, enabled: true });
    expect(getVal.request_id).toBe("kv-2");

    gw.sendJson({ type: "KV_GET", key: "nonexistent/key", request_id: "kv-3" });
    const missingVal = await gw.nextJson<{ type: string; found: boolean; value: unknown }>();
    expect(missingVal.found).toBe(false);
    expect(missingVal.value).toBeNull();
  });

  it("delivers cross-network SUB + PUB events exclusively to subscribed peers", async () => {
    const world = "pubsub-world";
    const pubClient = await connectWs(`/ws?role=gateway&world=${world}&net=net-a&client_id=pub-a`);
    const subB = await connectWs(`/ws?role=gateway&world=${world}&net=net-b&client_id=sub-b`);
    const subC = await connectWs(`/ws?role=gateway&world=${world}&net=net-c&client_id=sub-c`);

    subB.sendJson({ type: "SUB", topic: "energy/alerts" });
    const ackB = await subB.nextJson<{ type: string; topic: string; topics: string[] }>();
    expect(ackB.type).toBe("SUB_ACK");
    expect(ackB.topics).toContain("energy/alerts");

    subC.sendJson({ type: "SUB", topic: "storage/low" });
    const ackC = await subC.nextJson<{ type: string; topics: string[] }>();
    expect(ackC.type).toBe("SUB_ACK");
    expect(ackC.topics).toEqual(["storage/low"]);

    pubClient.sendJson({
      type: "PUB",
      topic: "energy/alerts",
      payload: { pct: 12, source: "induction_matrix_0" },
    });

    const eventB = await subB.nextJson<{
      type: string;
      topic: string;
      from_net: string;
      sender: string;
      payload: { pct: number; source: string };
    }>();
    expect(eventB.type).toBe("EVENT");
    expect(eventB.topic).toBe("energy/alerts");
    expect(eventB.from_net).toBe("net-a");
    expect(eventB.sender).toBe("pub-a");
    expect(eventB.payload).toEqual({ pct: 12, source: "induction_matrix_0" });

    // Unsubscribed / differently subscribed peers must NOT receive the event
    await subC.expectNoMessage(100);
    await pubClient.expectNoMessage(100);
  });

  it("emits WAKE on enqueue, dispatches in priority order with has_more, and reclaims expired leases on POLL_QUEUE", async () => {
    const world = "queue-lease-world";
    const gw = await connectWs(`/ws?role=gateway&world=${world}&net=main&client_id=gw-q`);

    // Enqueue low-priority task first, then high-priority task
    const lowTask = await mcpCallTool<{
      task_id: string;
      status: string;
      woke_gateways: number;
    }>(world, "enqueue_task", {
      net_id: "main",
      target_node: "runner_1",
      lua_code: "return 'low'",
      priority: 1,
    });
    expect(lowTask.status).toBe("pending");
    expect(lowTask.woke_gateways).toBe(1);

    const wake1 = await gw.nextJson<{ type: string; net_id: string; task_id: string }>();
    expect(wake1.type).toBe("WAKE");
    expect(wake1.net_id).toBe("main");
    expect(wake1.task_id).toBe(lowTask.task_id);

    const highTask = await mcpCallTool<{
      task_id: string;
      status: string;
      woke_gateways: number;
    }>(world, "enqueue_task", {
      net_id: "main",
      target_node: "gateway",
      lua_code: "return 'high'",
      priority: 50,
    });
    expect(highTask.woke_gateways).toBe(1);

    const wake2 = await gw.nextJson<{ type: string; task_id: string; pending_count: number }>();
    expect(wake2.type).toBe("WAKE");
    expect(wake2.task_id).toBe(highTask.task_id);
    expect(wake2.pending_count).toBe(2);

    // First POLL_QUEUE (capacity=1) must claim high-priority task first with has_more=true
    gw.sendJson({ type: "POLL_QUEUE", net_id: "main", capacity: 1 });
    const batch1 = await gw.nextJson<{
      type: string;
      tasks: DispatchedTask[];
      has_more: boolean;
    }>();
    expect(batch1.type).toBe("DISPATCH_BATCH");
    expect(batch1.tasks).toHaveLength(1);
    expect(batch1.tasks[0].task_id).toBe(highTask.task_id);
    expect(batch1.tasks[0].lua_code).toBe("return 'high'");
    expect(batch1.has_more).toBe(true);

    // Verify SQLite status transitioned pending -> leased with valid lease_expires_at
    const stub = env.BRIDGE_DO.get(env.BRIDGE_DO.idFromName(world));
    const leasedRow = await runInDurableObject(stub, async (_inst, state) => {
      return state.storage.sql
        .exec<{ status: string; lease_expires_at: number | null }>(
          "SELECT status, lease_expires_at FROM task_queue WHERE task_id = ?",
          highTask.task_id,
        )
        .one();
    });
    expect(leasedRow.status).toBe("leased");
    expect(leasedRow.lease_expires_at).toBeGreaterThan(Date.now() - 1000);

    // Second POLL_QUEUE claims the low-priority task with has_more=false
    gw.sendJson({ type: "POLL_QUEUE", net_id: "main", capacity: 1 });
    const batch2 = await gw.nextJson<{
      type: string;
      tasks: DispatchedTask[];
      has_more: boolean;
    }>();
    expect(batch2.tasks).toHaveLength(1);
    expect(batch2.tasks[0].task_id).toBe(lowTask.task_id);
    expect(batch2.has_more).toBe(false);

    // Backdate highTask's lease_expires_at past current time and poll again -> must reclaim!
    await runInDurableObject(stub, async (_inst, state) => {
      state.storage.sql.exec(
        "UPDATE task_queue SET lease_expires_at = ? WHERE task_id = ?",
        Date.now() - 5_000,
        highTask.task_id,
      );
    });

    gw.sendJson({ type: "POLL_QUEUE", net_id: "main", capacity: 1 });
    const batchReclaimed = await gw.nextJson<{
      type: string;
      tasks: DispatchedTask[];
      has_more: boolean;
    }>();
    expect(batchReclaimed.type).toBe("DISPATCH_BATCH");
    expect(batchReclaimed.tasks).toHaveLength(1);
    expect(batchReclaimed.tasks[0].task_id).toBe(highTask.task_id);
    expect(batchReclaimed.has_more).toBe(false);
  });

  it("stores TASK_RESULT output, schedules alarm(), and purges expired task_outputs on alarm()", async () => {
    const world = "alarm-ttl-world";
    const gw = await connectWs(`/ws?role=gateway&world=${world}&net=main`);

    const enqueued = await mcpCallTool<{ task_id: string }>(
      world,
      "enqueue_task",
      { net_id: "main", lua_code: "print('hello'); return { ok = 42 }" },
    );
    await gw.nextJson(); // consume WAKE

    gw.sendJson({ type: "POLL_QUEUE", net_id: "main", capacity: 1 });
    await gw.nextJson(); // consume DISPATCH_BATCH

    gw.sendJson({
      type: "TASK_RESULT",
      task_id: enqueued.task_id,
      ok: true,
      stdout: "hello\n",
      result: { ok: 42 },
    });
    const ack = await gw.nextJson<{ type: string; ref_type: string; ok: boolean }>();
    expect(ack.type).toBe("ACK");
    expect(ack.ref_type).toBe("TASK_RESULT");

    // MCP get_task_output retrieves stored output
    const out = await mcpCallTool<{
      found: boolean;
      status: string;
      ok: boolean;
      stdout: string;
      result: { ok: number };
      expires_at: number;
    }>(world, "get_task_output", { task_id: enqueued.task_id });
    expect(out.found).toBe(true);
    expect(out.status).toBe("completed");
    expect(out.ok).toBe(true);
    expect(out.stdout).toBe("hello\n");
    expect(out.result).toEqual({ ok: 42 });

    // Alarm must be scheduled for ~1 hour TTL
    const stub = env.BRIDGE_DO.get(env.BRIDGE_DO.idFromName(world));
    const scheduledAlarm = await runInDurableObject(stub, async (_inst, state) => {
      return state.storage.getAlarm();
    });
    expect(scheduledAlarm).not.toBeNull();
    expect(scheduledAlarm!).toBeGreaterThan(Date.now());

    // Simulate TTL expiration by backdating expires_at and running alarm()
    await runInDurableObject(stub, async (_inst, state) => {
      state.storage.sql.exec(
        "UPDATE task_outputs SET expires_at = ? WHERE task_id = ?",
        Date.now() - 10_000,
        enqueued.task_id,
      );
    });

    const ran = await runDurableObjectAlarm(stub);
    expect(ran).toBe(true);

    // Output row must now be purged
    const afterPurge = await mcpCallTool<{
      found: boolean;
      output: unknown;
    }>(world, "get_task_output", { task_id: enqueued.task_id });
    expect(afterPurge.output).toBeNull();

    const remainingRows = await runInDurableObject(stub, async (_inst, state) => {
      return state.storage.sql
        .exec<{ cnt: number }>("SELECT COUNT(*) AS cnt FROM task_outputs")
        .one().cnt;
    });
    expect(remainingRows).toBe(0);
  });

  it("handles dynamic device API specs end-to-end (pending -> fallback -> save -> enriched topology + MCP sampling auto-save)", async () => {
    const world = "specs-workflow-world";
    const gw = await connectWs(`/ws?role=gateway&world=${world}&net=main`);

    // 1. Attach unknown device advancedperipherals:me_bridge with probe data
    gw.sendJson({
      type: "PERIPHERAL_ATTACHED",
      net_id: "main",
      name: "meBridge_0",
      type_name: "advancedperipherals:me_bridge",
      methods: ["listItems", "listCraftableItems", "craftItem", "getEnergyUsage"],
      probe: {
        name: "meBridge_0",
        type: "advancedperipherals:me_bridge",
        types: ["meBridge", "advancedperipherals:me_bridge"],
        methods: ["listItems", "listCraftableItems", "craftItem", "getEnergyUsage"],
        metadata: { energyUsage: 128 },
      },
    });
    const attachAck = await gw.nextJson<{
      type: string;
      spec_status: string;
      entity_key: string;
    }>();
    expect(attachAck.type).toBe("ACK");
    expect(attachAck.spec_status).toBe("pending");

    // 2. Verify resources/list exposes cc://specs/pending and cc://specs/all
    const resList = await mcpRpc<{ resources: Array<{ uri: string }> }>(
      world,
      "resources/list",
    );
    expect(resList.body.result?.resources.map((r) => r.uri)).toEqual([
      "cc://specs/pending",
      "cc://specs/all",
    ]);

    // 3. Verify cc://specs/pending contains advancedperipherals:me_bridge
    const pendingRes = await mcpRpc<{
      contents: Array<{ uri: string; text: string }>;
    }>(world, "resources/read", { uri: "cc://specs/pending" });
    const pendingPayload = JSON.parse(
      pendingRes.body.result!.contents[0].text,
    ) as {
      pending: Array<{ type_name: string; name: string; methods: string[] }>;
      count: number;
    };
    expect(pendingPayload.count).toBe(1);
    expect(pendingPayload.pending[0].type_name).toBe("advancedperipherals:me_bridge");
    expect(pendingPayload.pending[0].methods).toContain("listItems");

    // 4. Fallback path: synthesize_device_spec with no sampling client returns structured synthesis prompt
    const fallbackSynth = await mcpCallTool<{
      status: string;
      type_name: string;
      methods: string[];
      probe: Record<string, unknown>;
      synthesis_prompt: string;
      next_tool: string;
    }>(world, "synthesize_device_spec", {
      type_name: "advancedperipherals:me_bridge",
    });
    expect(fallbackSynth.status).toBe("needs_agent_synthesis");
    expect(fallbackSynth.type_name).toBe("advancedperipherals:me_bridge");
    expect(fallbackSynth.next_tool).toBe("save_device_api_spec");
    expect(fallbackSynth.synthesis_prompt).toContain("advancedperipherals:me_bridge");
    expect(fallbackSynth.methods).toContain("listItems");
    expect(fallbackSynth.probe).toBeTruthy();

    // 5. Call save_device_api_spec -> writes to D1, clears pending, enriches topology
    const saved = await mcpCallTool<{
      ok: boolean;
      spec: DeviceApiSpec;
      entities_updated: number;
    }>(world, "save_device_api_spec", {
      type_name: "advancedperipherals:me_bridge",
      methods: ["listItems", "listCraftableItems", "craftItem", "getEnergyUsage"],
      spec_json: {
        summary: "Applied Energistics 2 ME Bridge peripheral",
        readonly_methods: ["listItems", "listCraftableItems", "getEnergyUsage"],
        mutating_methods: ["craftItem"],
      },
      spec_markdown:
        "# advancedperipherals:me_bridge\n\nProvides AE2 item inspection and autocrafting.",
      generated_by: "agent-fallback",
    });
    expect(saved.ok).toBe(true);
    expect(saved.entities_updated).toBe(1);
    expect(saved.spec.type_name).toBe("advancedperipherals:me_bridge");

    // Verify removed from cc://specs/pending and present in cc://specs/all
    const pendingAfterSave = await mcpRpc<{
      contents: Array<{ text: string }>;
    }>(world, "resources/read", { uri: "cc://specs/pending" });
    const pendingAfterData = JSON.parse(
      pendingAfterSave.body.result!.contents[0].text,
    ) as { count: number };
    expect(pendingAfterData.count).toBe(0);

    const allSpecsRes = await mcpRpc<{
      contents: Array<{ text: string }>;
    }>(world, "resources/read", { uri: "cc://specs/all" });
    const allSpecsData = JSON.parse(
      allSpecsRes.body.result!.contents[0].text,
    ) as { specs: DeviceApiSpec[] };
    expect(
      allSpecsData.specs.some(
        (s) => s.type_name === "advancedperipherals:me_bridge",
      ),
    ).toBe(true);

    // Verify list_network_topology enriches the entity with its D1 spec
    const topo = await mcpCallTool<{
      entities: EnrichedNetworkEntity[];
      count: number;
    }>(world, "list_network_topology", { net_id: "main" });
    const meBridge = topo.entities.find((e) => e.name === "meBridge_0");
    expect(meBridge).toBeDefined();
    expect(meBridge!.spec_status).toBe("known");
    expect(meBridge!.spec?.type_name).toBe("advancedperipherals:me_bridge");
    expect(meBridge!.spec?.spec_markdown).toContain("AE2 item inspection");

    // 6. Auto-probe test: attach unknown device WITHOUT probe data -> enqueues get_api + WAKE
    gw.sendJson({
      type: "PERIPHERAL_ATTACHED",
      net_id: "main",
      name: "display_link_0",
      type_name: "create:display_link",
      methods: ["setCursorPos", "write", "update"],
    });
    // Expect both WAKE (for auto-probe) and ACK (for PERIPHERAL_ATTACHED)
    const msgA = await gw.nextJson<{ type: string; [k: string]: unknown }>();
    const msgB = await gw.nextJson<{ type: string; [k: string]: unknown }>();
    const frames = [msgA, msgB];
    expect(frames.some((f) => f.type === "WAKE")).toBe(true);
    const displayAck = frames.find((f) => f.type === "ACK");
    expect(displayAck?.spec_status).toBe("pending");
    expect(displayAck?.auto_probe_task_id).toBeTruthy();

    // Poll and fulfill the auto-probe task, verifying probe_json gets hydrated
    gw.sendJson({ type: "POLL_QUEUE", net_id: "main", capacity: 1 });
    const probeBatch = await gw.nextJson<{
      type: string;
      tasks: DispatchedTask[];
    }>();
    expect(probeBatch.tasks[0].tool_name).toBe("get_api");

    gw.sendJson({
      type: "TASK_RESULT",
      task_id: probeBatch.tasks[0].task_id,
      ok: true,
      result: {
        name: "display_link_0",
        type: "create:display_link",
        methods: ["setCursorPos", "write", "update", "clear"],
        metadata: { size: [16, 4] },
      },
    });
    await gw.nextJson(); // consume ACK

    // 7. Primary MCP Sampling path: connect a sampling-capable MCP WS client
    const mcpClient = await connectWs(`/ws?role=mcp&world=${world}&client_id=mcp-sampler`);
    mcpClient.sendJson({
      jsonrpc: "2.0",
      id: "init-ws-1",
      method: "initialize",
      params: {
        protocolVersion: "2024-11-05",
        capabilities: { sampling: {} },
        clientInfo: { name: "mock-sampling-client", version: "1.0.0" },
      },
    });
    const wsInitResp = await mcpClient.nextJson<JsonRpcResponse>();
    expect(wsInitResp.id).toBe("init-ws-1");
    expect(wsInitResp.error).toBeUndefined();

    // Attach another unknown device for sampling synthesis
    gw.sendJson({
      type: "PERIPHERAL_ATTACHED",
      net_id: "main",
      name: "fission_0",
      type_name: "mekanism:fission_reactor_logic_adapter",
      methods: ["getTemperature", "getStatus", "scram"],
      probe: {
        name: "fission_0",
        type: "mekanism:fission_reactor_logic_adapter",
        methods: ["getTemperature", "getStatus", "scram"],
        metadata: { temperature: 305.2, status: false },
      },
    });
    await gw.nextJson(); // consume ACK

    // Trigger synthesize_device_spec over HTTP while sampling WS responds concurrently
    const samplingPromise = mcpCallTool<{
      status: string;
      synthesized_via: string;
      spec: DeviceApiSpec;
      entities_updated: number;
    }>(world, "synthesize_device_spec", {
      type_name: "mekanism:fission_reactor_logic_adapter",
    });

    const samplingReq = await mcpClient.nextJson<
      JsonRpcRequest & {
        params: { messages: Array<{ content: { text: string } }> };
      }
    >();
    expect(samplingReq.method).toBe("sampling/createMessage");
    expect(samplingReq.params.messages[0].content.text).toContain(
      "mekanism:fission_reactor_logic_adapter",
    );
    expect(samplingReq.params.messages[0].content.text).toContain("scram");

    mcpClient.sendJson({
      jsonrpc: "2.0",
      id: samplingReq.id,
      result: {
        role: "assistant",
        model: "claude-sonnet-test",
        content: {
          type: "text",
          text: JSON.stringify({
            spec_json: {
              summary: "Mekanism Fission Reactor logic adapter for telemetry and SCRAM.",
              readonly_methods: ["getTemperature", "getStatus"],
              mutating_methods: ["scram"],
            },
            spec_markdown:
              "# mekanism:fission_reactor_logic_adapter\n\nMonitor reactor temperature and trigger emergency SCRAM.",
          }),
        },
      },
    });

    const samplingResult = await samplingPromise;
    expect(samplingResult.status).toBe("synthesized");
    expect(samplingResult.synthesized_via).toBe("mcp_sampling");
    expect(samplingResult.entities_updated).toBe(1);
    expect(samplingResult.spec.type_name).toBe(
      "mekanism:fission_reactor_logic_adapter",
    );
    expect(samplingResult.spec.generated_by).toBe(
      "mcp-sampling:claude-sonnet-test",
    );

    // Confirm persisted in D1 directly and marked known in topology
    const d1Spec = await env.CATALOG_DB.prepare(
      "SELECT * FROM device_api_specs WHERE type_name = ?",
    )
      .bind("mekanism:fission_reactor_logic_adapter")
      .first<{ type_name: string; generated_by: string }>();
    expect(d1Spec?.generated_by).toBe("mcp-sampling:claude-sonnet-test");

    // Test PERIPHERAL_DETACHED cleans up entity
    gw.sendJson({
      type: "PERIPHERAL_DETACHED",
      net_id: "main",
      name: "display_link_0",
    });
    await gw.nextJson();

    const topoAfterDetach = await mcpCallTool<{
      entities: EnrichedNetworkEntity[];
    }>(world, "list_network_topology", { net_id: "main" });
    expect(
      topoAfterDetach.entities.some((e) => e.name === "display_link_0"),
    ).toBe(false);
  });

  it("seeds all 6 built-in lib.std tools and dynamically registers & invokes new learned tools via cc_<name>", async () => {
    const world = "learned-tools-world";

    // 1. Verify tools/list contains all 6 seeded built-in tools + 6 MCP server tools
    const listBefore = await mcpRpc<{ tools: McpToolDefinition[] }>(
      world,
      "tools/list",
    );
    expect(listBefore.status).toBe(200);
    const namesBefore = listBefore.body.result!.tools.map((t) => t.name);
    for (const expected of [
      "list_network_topology",
      "enqueue_task",
      "get_task_output",
      "register_learned_tool",
      "save_device_api_spec",
      "synthesize_device_spec",
      "cc_list_attachment",
      "cc_list_inventory",
      "cc_get_api",
      "cc_probe_network",
      "cc_run_script_test",
      "cc_install_script",
    ]) {
      expect(namesBefore, `Missing tool ${expected}`).toContain(expected);
    }

    // 2. Register a new learned tool
    const reg = await mcpCallTool<{
      ok: boolean;
      name: string;
      mcp_tool_name: string;
    }>(world, "register_learned_tool", {
      name: "check_reactor",
      description: "Read reactor temperature and SCRAM if over max_temp.",
      input_schema: {
        type: "object",
        properties: {
          max_temp: { type: "number" },
        },
        required: ["max_temp"],
      },
      lua_template:
        'local r = peripheral.find("fissionReactorLogicAdapter"); return { temp = r.getTemperature(), limit = args.max_temp }',
    });
    expect(reg.ok).toBe(true);
    expect(reg.mcp_tool_name).toBe("cc_check_reactor");

    // 3. Verify cc_check_reactor immediately appears in tools/list
    const listAfter = await mcpRpc<{ tools: McpToolDefinition[] }>(
      world,
      "tools/list",
    );
    const namesAfter = listAfter.body.result!.tools.map((t) => t.name);
    expect(namesAfter).toContain("cc_check_reactor");

    // 4. Connect a gateway WS and invoke cc_check_reactor -> emits WAKE and dispatches Lua template + args
    const gw = await connectWs(`/ws?role=gateway&world=${world}&net=reactor_net`);
    const callRes = await mcpCallTool<{
      task_id: string;
      tool: string;
      net_id: string;
      status: string;
      woke_gateways: number;
    }>(world, "cc_check_reactor", {
      net_id: "reactor_net",
      max_temp: 1100,
    });
    expect(callRes.tool).toBe("cc_check_reactor");
    expect(callRes.net_id).toBe("reactor_net");
    expect(callRes.status).toBe("pending");
    expect(callRes.woke_gateways).toBe(1);

    const wake = await gw.nextJson<{ type: string; task_id: string; net_id: string }>();
    expect(wake.type).toBe("WAKE");
    expect(wake.task_id).toBe(callRes.task_id);
    expect(wake.net_id).toBe("reactor_net");

    gw.sendJson({ type: "POLL_QUEUE", net_id: "reactor_net", capacity: 1 });
    const batch = await gw.nextJson<{
      type: string;
      tasks: DispatchedTask[];
      has_more: boolean;
    }>();
    expect(batch.tasks).toHaveLength(1);
    expect(batch.tasks[0].task_id).toBe(callRes.task_id);
    expect(batch.tasks[0].tool_name).toBe("check_reactor");
    expect(batch.tasks[0].lua_code).toContain("fissionReactorLogicAdapter");
    expect(batch.tasks[0].args).toEqual({ max_temp: 1100 });
    expect(batch.has_more).toBe(false);

    // 5. Invoke seeded cc_list_inventory tool and confirm it delegates to lib.std
    const invCall = await mcpCallTool<{
      task_id: string;
      tool: string;
      woke_gateways: number;
    }>(world, "cc_list_inventory", {
      net_id: "reactor_net",
      mod: "mekanism",
      min_count: 10,
    });
    expect(invCall.tool).toBe("cc_list_inventory");
    expect(invCall.woke_gateways).toBe(1);
    await gw.nextJson(); // consume WAKE

    gw.sendJson({ type: "POLL_QUEUE", net_id: "reactor_net", capacity: 1 });
    const invBatch = await gw.nextJson<{
      type: string;
      tasks: DispatchedTask[];
    }>();
    expect(invBatch.tasks[0].tool_name).toBe("list_inventory");
    expect(invBatch.tasks[0].lua_code).toContain('require("lib.std")');
    expect(invBatch.tasks[0].lua_code).toContain("std.list_inventory");
    expect(invBatch.tasks[0].args).toEqual({ mod: "mekanism", min_count: 10 });
  });

  it("replaces stale entities on SYNC_TOPOLOGY, resolves D1 specs, and auto-enqueues get_api probes for unknown unprobed peripherals", async () => {
    const world = "sync-topology-world";

    // Pre-seed one known spec in D1
    await env.CATALOG_DB.prepare(
      `INSERT OR REPLACE INTO device_api_specs
        (type_name, methods_json, spec_json, spec_markdown, generated_by, updated_at)
       VALUES (?, ?, ?, ?, ?, ?)`,
    )
      .bind(
        "minecraft:chest",
        JSON.stringify(["size", "list", "getItemDetail"]),
        JSON.stringify({ summary: "Vanilla chest inventory" }),
        "# minecraft:chest",
        "test-seed",
        Date.now(),
      )
      .run();

    const gw = await connectWs(`/ws?role=gateway&world=${world}&net=base`);

    // Initial topology sync with 1 gateway, 1 known chest, 1 unknown unprobed peripheral
    gw.sendJson({
      type: "SYNC_TOPOLOGY",
      net_id: "base",
      entities: [
        { name: "gateway_0", kind: "gateway", type_name: "computer", methods: [] },
        { name: "chest_0", kind: "peripheral", type_name: "minecraft:chest", methods: ["size", "list"] },
        { name: "induction_0", kind: "peripheral", type_name: "mekanism:induction_port", methods: ["getEnergy"] },
      ],
    });

    // Expect WAKE (for induction_0 auto-probe) and ACK (for SYNC_TOPOLOGY)
    const f1 = await gw.nextJson<{ type: string; [k: string]: unknown }>();
    const f2 = await gw.nextJson<{ type: string; [k: string]: unknown }>();
    const syncFrames = [f1, f2];
    expect(syncFrames.some((f) => f.type === "WAKE")).toBe(true);
    const syncAck = syncFrames.find((f) => f.type === "ACK");
    expect(syncAck?.ref_type).toBe("SYNC_TOPOLOGY");
    expect(syncAck?.count).toBe(3);

    const topo1 = await mcpCallTool<{ entities: EnrichedNetworkEntity[] }>(
      world,
      "list_network_topology",
      { net_id: "base" },
    );
    expect(topo1.entities).toHaveLength(3);
    expect(topo1.entities.find((e) => e.name === "chest_0")?.spec_status).toBe("known");
    expect(topo1.entities.find((e) => e.name === "chest_0")?.spec?.type_name).toBe("minecraft:chest");
    expect(topo1.entities.find((e) => e.name === "induction_0")?.spec_status).toBe("pending");
    expect(topo1.entities.find((e) => e.name === "gateway_0")?.spec_status).toBe("unknown");

    // Second SYNC_TOPOLOGY removes chest_0 -> stale entity must be deleted
    gw.sendJson({
      type: "SYNC_TOPOLOGY",
      net_id: "base",
      entities: [
        { name: "gateway_0", kind: "gateway", type_name: "computer", methods: [] },
        { name: "induction_0", kind: "peripheral", type_name: "mekanism:induction_port", methods: ["getEnergy"] },
      ],
    });
    const syncAck2 = await gw.nextJson<{ type: string; count: number }>();
    expect(syncAck2.type).toBe("ACK");
    expect(syncAck2.count).toBe(2);

    const topo2 = await mcpCallTool<{ entities: EnrichedNetworkEntity[] }>(
      world,
      "list_network_topology",
      { net_id: "base" },
    );
    expect(topo2.entities.map((e) => e.name).sort()).toEqual(["gateway_0", "induction_0"]);
  });
});
