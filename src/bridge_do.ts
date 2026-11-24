import { DurableObject } from "cloudflare:workers";
import type {
  ClientWsMessage,
  DeviceApiSpec,
  DispatchedTask,
  EnrichedNetworkEntity,
  Env,
  JsonRpcId,
  JsonRpcRequest,
  JsonRpcResponse,
  McpClientCapabilities,
  McpResourceDefinition,
  McpSamplingCreateMessageResult,
  McpToolCallResult,
  McpToolDefinition,
  NetworkEntityInput,
  ServerWsMessage,
  SpecStatus,
  WsAttachment,
  WsRole,
} from "./protocol";

const DEFAULT_LEASE_MS = 30_000;
const DEFAULT_OUTPUT_TTL_MS = 3_600_000; // 1 hour
const SAMPLING_TIMEOUT_MS = 15_000;
const TOOL_NAME_RE = /^[a-zA-Z0-9_-]+$/;
const MCP_PROTOCOL_VERSION = "2024-11-05";

const NON_PERIPHERAL_TYPES = new Set([
  "computer",
  "turtle",
  "gateway",
  "runner",
  "unknown",
  "",
]);

const textDecoder = new TextDecoder();

// ---------------------------------------------------------------------------
// SQLite & D1 Row Types (compatible with SqlStorageValue)
// ---------------------------------------------------------------------------

type NetworkEntitySqlRow = {
  entity_key: string;
  net_id: string;
  kind: string;
  name: string;
  type_name: string;
  methods_json: string;
  probe_json: string | null;
  spec_status: string;
  last_seen: number;
};

type LearnedToolSqlRow = {
  name: string;
  description: string;
  input_schema_json: string;
  lua_template: string;
  builtin: number;
  created_at: number;
  updated_at: number;
};

type TaskQueueSqlRow = {
  task_id: string;
  net_id: string;
  target_node: string;
  tool_name: string | null;
  lua_code: string;
  args_json: string;
  priority: number;
  status: string;
  lease_ms: number;
  lease_expires_at: number | null;
  created_at: number;
  updated_at: number;
};

type TaskOutputSqlRow = {
  task_id: string;
  ok: number;
  stdout: string;
  result_json: string | null;
  error: string | null;
  created_at: number;
  expires_at: number;
};

type KvStoreSqlRow = {
  key: string;
  value_json: string;
  updated_at: number;
};

type CountSqlRow = {
  cnt: number;
};

type MinExpirySqlRow = {
  min_exp: number | null;
};

type RawD1DeviceSpecRow = {
  type_name: string;
  methods_json: string;
  spec_json: string;
  spec_markdown: string;
  generated_by: string;
  updated_at: number;
};

interface PendingSamplingRequest {
  ws: WebSocket;
  resolve: (result: McpSamplingCreateMessageResult) => void;
  reject: (err: Error) => void;
  timer: ReturnType<typeof setTimeout>;
}

// ---------------------------------------------------------------------------
// Seeded Built-in Learned Tools (delegating to require("lib.std"))
// ---------------------------------------------------------------------------

interface SeededToolSpec {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
  luaTemplate: string;
}

const SEEDED_LEARNED_TOOLS: SeededToolSpec[] = [
  {
    name: "list_attachment",
    description:
      "List attached wired and local peripherals with their types and methods via lib.std.",
    inputSchema: {
      type: "object",
      properties: {
        filter_type: {
          type: "string",
          description:
            "Optional peripheral type filter (e.g. 'inventory', 'modem', 'me_bridge').",
        },
        net_id: {
          type: "string",
          description: "Target gateway network ID (default: 'main').",
        },
        target_node: {
          type: "string",
          description: "Target node name (default: 'gateway').",
        },
      },
    },
    luaTemplate: [
      'local std = require("lib.std")',
      "return std.list_attachment(args.filter_type)",
    ].join("\n"),
  },
  {
    name: "list_inventory",
    description:
      "Aggregate and filter item stacks across attached inventories via lib.std.",
    inputSchema: {
      type: "object",
      properties: {
        mod: {
          type: "string",
          description: "Filter by mod namespace (e.g. 'mekanism').",
        },
        name: {
          type: "string",
          description: "Filter by Lua pattern against item name.",
        },
        tag: {
          type: "string",
          description: "Filter by item tag.",
        },
        min_count: {
          type: "number",
          description: "Minimum aggregated item count.",
        },
        peripheral: {
          type: "string",
          description: "Optional specific inventory peripheral name.",
        },
        net_id: {
          type: "string",
          description: "Target gateway network ID (default: 'main').",
        },
        target_node: {
          type: "string",
          description: "Target node name (default: 'gateway').",
        },
      },
    },
    luaTemplate: [
      'local std = require("lib.std")',
      "return std.list_inventory(args)",
    ].join("\n"),
  },
  {
    name: "get_api",
    description:
      "Probe a peripheral's types, methods, and safe read-only metadata via lib.std.",
    inputSchema: {
      type: "object",
      properties: {
        name: {
          type: "string",
          description: "Peripheral name to introspect (e.g. 'meBridge_0').",
        },
        net_id: {
          type: "string",
          description: "Target gateway network ID (default: 'main').",
        },
        target_node: {
          type: "string",
          description: "Target node name (default: 'gateway').",
        },
      },
      required: ["name"],
    },
    luaTemplate: [
      'local std = require("lib.std")',
      "return std.get_api(args.name)",
    ].join("\n"),
  },
  {
    name: "probe_network",
    description:
      "Probe attached peripherals and run a Rednet discovery sweep via lib.std.",
    inputSchema: {
      type: "object",
      properties: {
        timeout: {
          type: "number",
          description: "Optional Rednet discovery timeout in seconds.",
        },
        net_id: {
          type: "string",
          description: "Target gateway network ID (default: 'main').",
        },
        target_node: {
          type: "string",
          description: "Target node name (default: 'gateway').",
        },
      },
    },
    luaTemplate: [
      'local std = require("lib.std")',
      "return std.probe_network(args.timeout)",
    ].join("\n"),
  },
  {
    name: "run_script_test",
    description:
      "Execute an ad-hoc Lua snippet with lib.std preloaded and capture stdout and return value.",
    inputSchema: {
      type: "object",
      properties: {
        code: {
          type: "string",
          description: "Lua source snippet to execute.",
        },
        params: {
          type: "object",
          description: "Optional arguments table exposed as `params` inside the snippet.",
        },
        net_id: {
          type: "string",
          description: "Target gateway network ID (default: 'main').",
        },
        target_node: {
          type: "string",
          description: "Target node name (default: 'gateway').",
        },
      },
      required: ["code"],
    },
    luaTemplate: [
      'local std = require("lib.std")',
      "local env = setmetatable({ std = std, params = args.params or {} }, { __index = _ENV })",
      'local fn, err = load(args.code or "", "run_script_test", "t", env)',
      'if not fn then error("compile error: " .. tostring(err)) end',
      "return fn()",
    ].join("\n"),
  },
  {
    name: "install_script",
    description:
      "Install a Lua script to args.path from raw args.code or by downloading args.slug from the Static or D1/R2 App Store.",
    inputSchema: {
      type: "object",
      properties: {
        path: {
          type: "string",
          description: "Destination file path on the target node (e.g. '/apps/custom.lua').",
        },
        code: {
          type: "string",
          description: "Raw Lua code to write directly.",
        },
        slug: {
          type: "string",
          description: "App slug to download when code is omitted.",
        },
        source: {
          type: "string",
          enum: ["static", "store"],
          description:
            "App store source: 'static' (/lua/apps/<slug>.lua) or 'store' (/api/store/download/<slug>).",
        },
        net_id: {
          type: "string",
          description: "Target gateway network ID (default: 'main').",
        },
        target_node: {
          type: "string",
          description: "Target node name (default: 'gateway').",
        },
      },
      required: ["path"],
    },
    luaTemplate: [
      'local std = require("lib.std")',
      "local content = args.code",
      "if not content and args.slug then",
      '  local base = settings.get("cc_mesh.url") or ""',
      "  local headers = {}",
      '  local cid = settings.get("cc_mesh.cf_id")',
      '  local csec = settings.get("cc_mesh.cf_secret")',
      "  if cid and csec then",
      '    headers["CF-Access-Client-Id"] = cid',
      '    headers["CF-Access-Client-Secret"] = csec',
      "  end",
      '  local endpoint = (args.source == "store")',
      '    and (base .. "/api/store/download/" .. args.slug)',
      '    or (base .. "/lua/apps/" .. args.slug .. ".lua")',
      "  local resp, err = http.get(endpoint, headers)",
      '  if not resp then error("download failed: " .. tostring(err)) end',
      "  content = resp.readAll()",
      "  resp.close()",
      "end",
      'if type(content) ~= "string" then error("Provide args.code or args.slug") end',
      "local dir = fs.getDir(args.path)",
      'if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end',
      'local f = fs.open(args.path, "w")',
      'if not f then error("Unable to open path: " .. tostring(args.path)) end',
      "f.write(content)",
      "f.close()",
      "return { installed = true, path = args.path, bytes = #content }",
    ].join("\n"),
  },
];

// ---------------------------------------------------------------------------
// Built-in MCP Server Tools & Resources
// ---------------------------------------------------------------------------

const BUILTIN_MCP_TOOLS: McpToolDefinition[] = [
  {
    name: "list_network_topology",
    description:
      "List live ComputerCraft network entities enriched with synthesized device API specifications from D1.",
    inputSchema: {
      type: "object",
      properties: {
        net_id: {
          type: "string",
          description: "Optional network ID filter.",
        },
      },
    },
  },
  {
    name: "enqueue_task",
    description:
      "Enqueue a Lua task for a ComputerCraft gateway/node and immediately send a WAKE interrupt over WebSocket.",
    inputSchema: {
      type: "object",
      properties: {
        net_id: {
          type: "string",
          description: "Target gateway network ID (default: 'main').",
        },
        target_node: {
          type: "string",
          description: "Target node name (default: 'gateway').",
        },
        lua_code: {
          type: "string",
          description: "Lua source code to execute.",
        },
        args: {
          type: "object",
          description: "Optional arguments table passed as `args`.",
        },
        priority: {
          type: "number",
          description: "Task priority (higher executes first; default: 0).",
        },
        lease_ms: {
          type: "number",
          description: "Lease duration in milliseconds (default: 30000).",
        },
      },
      required: ["lua_code"],
    },
  },
  {
    name: "get_task_output",
    description:
      "Fetch execution status, captured stdout, return value, or error for a previously enqueued task.",
    inputSchema: {
      type: "object",
      properties: {
        task_id: {
          type: "string",
          description: "Task ID returned by enqueue_task or a cc_* tool.",
        },
      },
      required: ["task_id"],
    },
  },
  {
    name: "register_learned_tool",
    description:
      "Register or update a reusable self-learned Lua tool in DO SQLite so it is exposed as cc_<name> in tools/list.",
    inputSchema: {
      type: "object",
      properties: {
        name: {
          type: "string",
          description: "Tool identifier (without the 'cc_' prefix).",
        },
        description: {
          type: "string",
          description: "Human-readable tool description.",
        },
        input_schema: {
          type: "object",
          description: "JSON Schema for tool input arguments.",
        },
        lua_template: {
          type: "string",
          description: "Lua source template executed with `args` available.",
        },
      },
      required: ["name", "description", "lua_template"],
    },
  },
  {
    name: "save_device_api_spec",
    description:
      "Persist a synthesized peripheral/device API specification into D1 device_api_specs and mark matching entities known.",
    inputSchema: {
      type: "object",
      properties: {
        type_name: {
          type: "string",
          description: "Minecraft/mod peripheral type name (e.g. 'advancedperipherals:me_bridge').",
        },
        methods: {
          type: "array",
          items: { type: "string" },
          description: "List of peripheral method names.",
        },
        spec_json: {
          type: "object",
          description: "Structured JSON API specification.",
        },
        spec_markdown: {
          type: "string",
          description: "Markdown API documentation for agents.",
        },
        generated_by: {
          type: "string",
          description: "Identifier of the agent/model that generated the spec.",
        },
      },
      required: ["type_name", "methods", "spec_markdown"],
    },
  },
  {
    name: "synthesize_device_spec",
    description:
      "Synthesize an API specification for an attached peripheral via MCP sampling/createMessage (if connected) or return a structured synthesis prompt and raw probe data.",
    inputSchema: {
      type: "object",
      properties: {
        type_name: {
          type: "string",
          description: "Device type_name to synthesize.",
        },
        net_id: {
          type: "string",
          description: "Optional network ID to pull probe metadata from.",
        },
        entity_name: {
          type: "string",
          description: "Optional specific entity name to pull probe metadata from.",
        },
        force: {
          type: "boolean",
          description: "Force re-synthesis even if a spec already exists in D1.",
        },
      },
      required: ["type_name"],
    },
  },
];

const MCP_RESOURCES: McpResourceDefinition[] = [
  {
    uri: "cc://specs/pending",
    name: "Pending Device API Specs",
    description: "Devices awaiting API specification synthesis",
    mimeType: "application/json",
  },
  {
    uri: "cc://specs/all",
    name: "All Device API Specs",
    description: "All synthesized device API specifications in D1",
    mimeType: "application/json",
  },
];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function safeJsonParse<T>(raw: string | null | undefined, fallback: T): T {
  if (!raw) {
    return fallback;
  }
  try {
    return JSON.parse(raw) as T;
  } catch {
    return fallback;
  }
}

function mapD1SpecRow(row: RawD1DeviceSpecRow): DeviceApiSpec {
  return {
    type_name: row.type_name,
    methods: safeJsonParse<string[]>(row.methods_json, []),
    spec_json: safeJsonParse<Record<string, unknown>>(row.spec_json, {}),
    spec_markdown: row.spec_markdown,
    generated_by: row.generated_by,
    updated_at: row.updated_at,
  };
}

function normalizeRole(raw: string | null): WsRole {
  if (raw === "mcp" || raw === "client" || raw === "gateway") {
    return raw;
  }
  return "gateway";
}

function normalizeEntityKind(raw: string | undefined, typeName: string): string {
  if (raw === "gateway" || raw === "runner" || raw === "turtle" || raw === "peripheral" || raw === "drive") {
    return raw;
  }
  if (raw === "worker") {
    return "runner";
  }
  if (raw === "computer") {
    return "runner";
  }
  if (typeName === "drive") {
    return "drive";
  }
  return "peripheral";
}

function entityNeedsSpec(kind: string, typeName: string): boolean {
  const normalizedType = typeName.trim().toLowerCase();
  if (!normalizedType) {
    return false;
  }
  if (kind === "peripheral" || kind === "drive") {
    return true;
  }
  return !NON_PERIPHERAL_TYPES.has(normalizedType);
}

function sanitizeTagPart(value: string): string {
  return value.replace(/[^a-zA-Z0-9._:-]/g, "_").slice(0, 120);
}

function makeToolResult(payload: unknown, isError = false): McpToolCallResult {
  return {
    content: [
      {
        type: "text",
        text: JSON.stringify(payload),
      },
    ],
    isError,
  };
}

function makeJsonRpcSuccess(id: JsonRpcId, result: unknown): JsonRpcResponse {
  return {
    jsonrpc: "2.0",
    id,
    result,
  };
}

function makeJsonRpcError(
  id: JsonRpcId,
  code: number,
  message: string,
  data?: unknown,
): JsonRpcResponse {
  return {
    jsonrpc: "2.0",
    id,
    error: data === undefined ? { code, message } : { code, message, data },
  };
}

function buildSynthesisPrompt(
  typeName: string,
  methods: string[],
  probe: Record<string, unknown> | null,
): string {
  return [
    `Synthesize a concise, accurate ComputerCraft (CC: Tweaked) peripheral API specification for device type "${typeName}".`,
    "",
    `Discovered methods (${methods.length}):`,
    JSON.stringify(methods, null, 2),
    "",
    "Safe read-only probe metadata (from std.get_api):",
    JSON.stringify(probe ?? {}, null, 2),
    "",
    "Return a JSON object with:",
    '- "spec_json": { "summary": string, "readonly_methods": string[], "mutating_methods": string[], "methods": Record<string, { "description": string, "readonly": boolean }> }',
    '- "spec_markdown": Markdown API documentation summarizing usage examples and safe vs mutating methods.',
  ].join("\n");
}

function parseSynthesizedSpecResponse(
  rawText: string,
  typeName: string,
  methods: string[],
): { spec_json: Record<string, unknown>; spec_markdown: string } {
  const trimmed = rawText.trim();

  // 1. Try direct JSON parse
  const tryParseObj = (candidate: string): Record<string, unknown> | null => {
    try {
      const parsed = JSON.parse(candidate) as unknown;
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
        return parsed as Record<string, unknown>;
      }
      return null;
    } catch {
      return null;
    }
  };

  let parsed = tryParseObj(trimmed);
  let extractedMarkdown = "";

  // 2. Try fenced ```json ... ``` block
  if (!parsed) {
    const fencedMatch = trimmed.match(/```(?:json)?\s*([\s\S]*?)```/i);
    if (fencedMatch && fencedMatch[1]) {
      parsed = tryParseObj(fencedMatch[1].trim());
      extractedMarkdown = trimmed.replace(fencedMatch[0], "").trim();
    }
  }

  if (parsed) {
    const nestedSpecJson =
      parsed.spec_json && typeof parsed.spec_json === "object" && !Array.isArray(parsed.spec_json)
        ? (parsed.spec_json as Record<string, unknown>)
        : parsed;

    const specMarkdown =
      typeof parsed.spec_markdown === "string" && parsed.spec_markdown.trim()
        ? parsed.spec_markdown.trim()
        : extractedMarkdown || `# ${typeName}\n\nMethods: ${methods.join(", ")}`;

    return {
      spec_json: nestedSpecJson,
      spec_markdown: specMarkdown,
    };
  }

  // 3. Fallback: treat entire LLM output as Markdown spec
  return {
    spec_json: {
      summary: `Synthesized specification for ${typeName}`,
      methods,
    },
    spec_markdown: trimmed || `# ${typeName}\n\nMethods: ${methods.join(", ")}`,
  };
}

// ---------------------------------------------------------------------------
// CcMeshBridge Durable Object (Hibernation-First, Zero setInterval)
// ---------------------------------------------------------------------------

export class CcMeshBridge extends DurableObject<Env> {
  private readonly sql: SqlStorage;
  private readonly pendingSamplingRequests = new Map<string, PendingSamplingRequest>();
  /** Diagnostic counter incremented only when webSocketMessage runs (auto-responded ping never increments this). */
  public nonAutoMessageCount = 0;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;

    // Hibernation-native auto-response: handles "ping" -> "pong" without waking the DO
    this.ctx.setWebSocketAutoResponse(
      new WebSocketRequestResponsePair("ping", "pong"),
    );

    this.ctx.blockConcurrencyWhile(async () => {
      this.initSchemaAndSeed();
    });
  }

  private initSchemaAndSeed(): void {
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS network_entities (
        entity_key TEXT PRIMARY KEY,
        net_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        name TEXT NOT NULL,
        type_name TEXT NOT NULL,
        methods_json TEXT NOT NULL DEFAULT '[]',
        probe_json TEXT,
        spec_status TEXT NOT NULL DEFAULT 'unknown',
        last_seen INTEGER NOT NULL
      );

      CREATE INDEX IF NOT EXISTS idx_network_entities_net_id
        ON network_entities(net_id);
      CREATE INDEX IF NOT EXISTS idx_network_entities_type_name
        ON network_entities(type_name);
      CREATE INDEX IF NOT EXISTS idx_network_entities_spec_status
        ON network_entities(spec_status);

      CREATE TABLE IF NOT EXISTS kv_store (
        key TEXT PRIMARY KEY,
        value_json TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      );

      CREATE TABLE IF NOT EXISTS learned_tools (
        name TEXT PRIMARY KEY,
        description TEXT NOT NULL,
        input_schema_json TEXT NOT NULL,
        lua_template TEXT NOT NULL,
        builtin INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );

      CREATE TABLE IF NOT EXISTS task_queue (
        task_id TEXT PRIMARY KEY,
        net_id TEXT NOT NULL DEFAULT 'main',
        target_node TEXT NOT NULL DEFAULT 'gateway',
        tool_name TEXT,
        lua_code TEXT NOT NULL,
        args_json TEXT NOT NULL DEFAULT '{}',
        priority INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL DEFAULT 'pending',
        lease_ms INTEGER NOT NULL DEFAULT 30000,
        lease_expires_at INTEGER,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );

      CREATE INDEX IF NOT EXISTS idx_task_queue_dispatch
        ON task_queue(net_id, status, priority DESC, created_at ASC);
      CREATE INDEX IF NOT EXISTS idx_task_queue_lease
        ON task_queue(status, lease_expires_at);

      CREATE TABLE IF NOT EXISTS task_outputs (
        task_id TEXT PRIMARY KEY,
        ok INTEGER NOT NULL,
        stdout TEXT NOT NULL DEFAULT '',
        result_json TEXT,
        error TEXT,
        created_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL
      );

      CREATE INDEX IF NOT EXISTS idx_task_outputs_expires_at
        ON task_outputs(expires_at);

      CREATE TABLE IF NOT EXISTS mcp_sessions (
        session_id TEXT PRIMARY KEY,
        client_name TEXT,
        client_version TEXT,
        protocol_version TEXT,
        supports_sampling INTEGER NOT NULL DEFAULT 0,
        capabilities_json TEXT NOT NULL DEFAULT '{}',
        updated_at INTEGER NOT NULL
      );
    `);

    const now = Date.now();
    for (const tool of SEEDED_LEARNED_TOOLS) {
      this.sql.exec(
        `INSERT OR IGNORE INTO learned_tools
          (name, description, input_schema_json, lua_template, builtin, created_at, updated_at)
         VALUES (?, ?, ?, ?, 1, ?, ?)`,
        tool.name,
        tool.description,
        JSON.stringify(tool.inputSchema),
        tool.luaTemplate,
        now,
        now,
      );
    }
  }

  // -------------------------------------------------------------------------
  // HTTP / WebSocket Entrypoint
  // -------------------------------------------------------------------------

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/ws") {
      return this.handleWebSocketUpgrade(request, url);
    }

    if (url.pathname === "/mcp") {
      return this.handleMcpHttpRequest(request);
    }

    return Response.json({ error: "Not found" }, { status: 404 });
  }

  private handleWebSocketUpgrade(request: Request, url: URL): Response {
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return Response.json(
        { error: "Expected WebSocket upgrade" },
        { status: 426 },
      );
    }

    const role = normalizeRole(url.searchParams.get("role"));
    const world =
      url.searchParams.get("world")?.trim() ||
      request.headers.get("X-CC-World")?.trim() ||
      "default";
    const net =
      url.searchParams.get("net")?.trim() ||
      url.searchParams.get("gateway_id")?.trim() ||
      "main";
    const clientId =
      url.searchParams.get("client_id")?.trim() ||
      url.searchParams.get("clientId")?.trim() ||
      crypto.randomUUID();
    const label = url.searchParams.get("label")?.trim() || undefined;
    const samplingParam = url.searchParams.get("sampling")?.toLowerCase();
    const supportsSampling = samplingParam === "true" || samplingParam === "1";

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);

    const tags = [
      `role:${sanitizeTagPart(role)}`,
      `net:${sanitizeTagPart(net)}`,
    ];

    this.ctx.acceptWebSocket(server, tags);

    const attachment: WsAttachment = {
      role,
      world,
      net,
      clientId,
      subscriptions: [],
      connectedAt: Date.now(),
      label,
      supportsSampling,
    };
    server.serializeAttachment(attachment);

    return new Response(null, { status: 101, webSocket: client });
  }

  private getAttachment(ws: WebSocket): WsAttachment {
    const raw = ws.deserializeAttachment() as Partial<WsAttachment> | null;
    if (raw && typeof raw === "object") {
      return {
        role: normalizeRole(typeof raw.role === "string" ? raw.role : null),
        world: typeof raw.world === "string" ? raw.world : "default",
        net: typeof raw.net === "string" ? raw.net : "main",
        clientId: typeof raw.clientId === "string" ? raw.clientId : "unknown",
        subscriptions: Array.isArray(raw.subscriptions)
          ? raw.subscriptions.filter((s): s is string => typeof s === "string")
          : [],
        connectedAt: typeof raw.connectedAt === "number" ? raw.connectedAt : 0,
        label: typeof raw.label === "string" ? raw.label : undefined,
        supportsSampling: Boolean(raw.supportsSampling),
      };
    }
    return {
      role: "gateway",
      world: "default",
      net: "main",
      clientId: "unknown",
      subscriptions: [],
      connectedAt: 0,
      supportsSampling: false,
    };
  }

  private safeSend(ws: WebSocket, frame: ServerWsMessage | JsonRpcRequest | JsonRpcResponse): boolean {
    try {
      ws.send(JSON.stringify(frame));
      return true;
    } catch {
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // WebSocket Hibernation Handlers
  // -------------------------------------------------------------------------

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    this.nonAutoMessageCount += 1;

    const rawText =
      typeof message === "string" ? message : textDecoder.decode(message);

    let parsed: Record<string, unknown>;
    try {
      const value = JSON.parse(rawText) as unknown;
      if (!value || typeof value !== "object" || Array.isArray(value)) {
        this.safeSend(ws, {
          type: "ERROR",
          code: "INVALID_FRAME",
          message: "WebSocket frame must be a JSON object",
        });
        return;
      }
      parsed = value as Record<string, unknown>;
    } catch {
      this.safeSend(ws, {
        type: "ERROR",
        code: "PARSE_ERROR",
        message: "Malformed JSON WebSocket frame",
      });
      return;
    }

    // Handle MCP JSON-RPC 2.0 traffic over WebSocket (including sampling/createMessage responses)
    if (parsed.jsonrpc === "2.0") {
      await this.handleWsJsonRpc(ws, parsed);
      return;
    }

    const msg = parsed as unknown as ClientWsMessage;
    const attachment = this.getAttachment(ws);

    try {
      switch (msg.type) {
        case "SYNC_TOPOLOGY":
          await this.handleSyncTopology(ws, attachment, msg);
          break;
        case "PERIPHERAL_ATTACHED":
          await this.handlePeripheralAttached(ws, attachment, msg);
          break;
        case "PERIPHERAL_DETACHED":
          this.handlePeripheralDetached(ws, attachment, msg);
          break;
        case "POLL_QUEUE":
          this.handlePollQueue(ws, attachment, msg);
          break;
        case "TASK_RESULT":
          await this.handleTaskResult(ws, msg);
          break;
        case "SUB":
          this.handleSub(ws, attachment, msg);
          break;
        case "UNSUB":
          this.handleUnsub(ws, attachment, msg);
          break;
        case "PUB":
          this.handlePub(ws, attachment, msg);
          break;
        case "KV_SET":
          this.handleKvSet(ws, msg);
          break;
        case "KV_GET":
          this.handleKvGet(ws, msg);
          break;
        default:
          this.safeSend(ws, {
            type: "ERROR",
            code: "UNKNOWN_TYPE",
            message: `Unsupported frame type: ${String(parsed.type ?? "")}`,
          });
      }
    } catch (err) {
      this.safeSend(ws, {
        type: "ERROR",
        code: "INTERNAL_ERROR",
        message: err instanceof Error ? err.message : String(err),
      });
    }
  }

  async webSocketClose(
    ws: WebSocket,
    code: number,
    reason: string,
    _wasClean: boolean,
  ): Promise<void> {
    this.rejectPendingSamplingForSocket(ws, "MCP sampling client disconnected");
    try {
      ws.close(code, reason || "Closed");
    } catch {
      // Socket already closed
    }
  }

  async webSocketError(ws: WebSocket, _error: unknown): Promise<void> {
    this.rejectPendingSamplingForSocket(ws, "MCP sampling WebSocket error");
    try {
      ws.close(1011, "WebSocket error");
    } catch {
      // Socket already closed
    }
  }

  private rejectPendingSamplingForSocket(ws: WebSocket, reason: string): void {
    for (const [id, pending] of this.pendingSamplingRequests.entries()) {
      if (pending.ws === ws) {
        clearTimeout(pending.timer);
        this.pendingSamplingRequests.delete(id);
        pending.reject(new Error(reason));
      }
    }
  }

  // -------------------------------------------------------------------------
  // Alarm TTL Cleanup
  // -------------------------------------------------------------------------

  async alarm(): Promise<void> {
    const now = Date.now();

    // Delete expired task outputs
    this.sql.exec("DELETE FROM task_outputs WHERE expires_at <= ?", now);

    // Also prune stale completed/failed task queue rows older than 1 hour
    this.sql.exec(
      "DELETE FROM task_queue WHERE status IN ('completed', 'failed') AND updated_at <= ?",
      now - DEFAULT_OUTPUT_TTL_MS,
    );

    // Reschedule alarm if any remaining task_outputs exist
    const nextRow = this.sql
      .exec<MinExpirySqlRow>("SELECT MIN(expires_at) AS min_exp FROM task_outputs")
      .one();
    if (nextRow && typeof nextRow.min_exp === "number") {
      await this.ctx.storage.setAlarm(nextRow.min_exp);
    }
  }

  private async scheduleOutputCleanupAlarm(): Promise<void> {
    const row = this.sql
      .exec<MinExpirySqlRow>("SELECT MIN(expires_at) AS min_exp FROM task_outputs")
      .one();
    if (!row || typeof row.min_exp !== "number") {
      return;
    }
    const currentAlarm = await this.ctx.storage.getAlarm();
    if (currentAlarm === null || row.min_exp < currentAlarm) {
      await this.ctx.storage.setAlarm(row.min_exp);
    }
  }

  // -------------------------------------------------------------------------
  // WebSocket Frame Implementations
  // -------------------------------------------------------------------------

  private async lookupKnownSpecTypes(typeNames: string[]): Promise<Set<string>> {
    const unique = Array.from(
      new Set(typeNames.map((t) => t.trim()).filter(Boolean)),
    );
    if (unique.length === 0) {
      return new Set<string>();
    }
    const placeholders = unique.map(() => "?").join(", ");
    const res = await this.env.CATALOG_DB.prepare(
      `SELECT type_name FROM device_api_specs WHERE type_name IN (${placeholders})`,
    )
      .bind(...unique)
      .all<{ type_name: string }>();
    return new Set(res.results.map((r) => r.type_name));
  }

  private async fetchSpecsMap(typeNames: string[]): Promise<Map<string, DeviceApiSpec>> {
    const unique = Array.from(
      new Set(typeNames.map((t) => t.trim()).filter(Boolean)),
    );
    const map = new Map<string, DeviceApiSpec>();
    if (unique.length === 0) {
      return map;
    }
    const placeholders = unique.map(() => "?").join(", ");
    const res = await this.env.CATALOG_DB.prepare(
      `SELECT * FROM device_api_specs WHERE type_name IN (${placeholders})`,
    )
      .bind(...unique)
      .all<RawD1DeviceSpecRow>();
    for (const row of res.results) {
      map.set(row.type_name, mapD1SpecRow(row));
    }
    return map;
  }

  private maybeEnqueueAutoProbe(
    netId: string,
    entityKey: string,
    entityName: string,
    typeName: string,
  ): string | null {
    // Avoid duplicating an active pending/leased auto-probe for this entity
    const existing = this.sql
      .exec<{ task_id: string; args_json: string }>(
        `SELECT task_id, args_json FROM task_queue
         WHERE net_id = ? AND tool_name = 'get_api' AND status IN ('pending', 'leased')`,
        netId,
      )
      .toArray();

    for (const row of existing) {
      const parsed = safeJsonParse<Record<string, unknown>>(row.args_json, {});
      if (parsed.entity_key === entityKey || parsed.name === entityName) {
        return null;
      }
    }

    const { taskId } = this.insertTaskAndWake({
      netId,
      targetNode: "gateway",
      toolName: "get_api",
      luaCode: 'local std = require("lib.std")\nreturn std.get_api(args.name)',
      args: {
        name: entityName,
        entity_key: entityKey,
        type_name: typeName,
        _auto_probe: true,
      },
      priority: 10,
      leaseMs: DEFAULT_LEASE_MS,
      wakeReason: `auto_probe:${typeName}`,
    });
    return taskId;
  }

  private async handleSyncTopology(
    ws: WebSocket,
    attachment: WsAttachment,
    msg: Extract<ClientWsMessage, { type: "SYNC_TOPOLOGY" }>,
  ): Promise<void> {
    const netId = (msg.net_id || msg.gateway_id || attachment.net || "main").trim();
    const entities: NetworkEntityInput[] = Array.isArray(msg.entities)
      ? msg.entities
      : [];
    const now = Date.now();

    // Preserve existing probe_json if incoming topology omits probe metadata
    const existingRows = this.sql
      .exec<{ entity_key: string; probe_json: string | null }>(
        "SELECT entity_key, probe_json FROM network_entities WHERE net_id = ?",
        netId,
      )
      .toArray();
    const existingProbeByKey = new Map<string, string | null>();
    for (const r of existingRows) {
      existingProbeByKey.set(r.entity_key, r.probe_json);
    }

    const normalized = entities
      .filter((e): e is NetworkEntityInput => Boolean(e && typeof e.name === "string" && e.name.trim()))
      .map((e) => {
        const name = e.name.trim();
        const typeName = (
          e.type_name ||
          e.peripheral_type ||
          e.type ||
          (e.probe && typeof e.probe === "object" && "type" in e.probe && typeof e.probe.type === "string"
            ? e.probe.type
            : "") ||
          e.kind ||
          "unknown"
        ).trim();
        const kind = normalizeEntityKind(e.kind, typeName);
        const entityKey = e.entity_key?.trim() || `${netId}::${name}`;
        const methods = Array.isArray(e.methods)
          ? e.methods.filter((m): m is string => typeof m === "string")
          : e.probe && typeof e.probe === "object" && "methods" in e.probe && Array.isArray(e.probe.methods)
            ? (e.probe.methods as unknown[]).filter((m): m is string => typeof m === "string")
            : [];
        const probeJson =
          e.probe && typeof e.probe === "object"
            ? JSON.stringify(e.probe)
            : existingProbeByKey.get(entityKey) ?? null;

        return { entityKey, name, kind, typeName, methods, probeJson };
      });

    const knownSpecs = await this.lookupKnownSpecTypes(
      normalized.map((e) => e.typeName),
    );

    const incomingKeys = new Set(normalized.map((e) => e.entityKey));
    const pendingWithoutProbe: Array<{
      entityKey: string;
      name: string;
      typeName: string;
    }> = [];

    this.ctx.storage.transactionSync(() => {
      // Remove entities for this net_id that are no longer present
      for (const oldRow of existingRows) {
        if (!incomingKeys.has(oldRow.entity_key)) {
          this.sql.exec(
            "DELETE FROM network_entities WHERE entity_key = ?",
            oldRow.entity_key,
          );
        }
      }

      for (const item of normalized) {
        let specStatus: SpecStatus;
        if (knownSpecs.has(item.typeName)) {
          specStatus = "known";
        } else if (entityNeedsSpec(item.kind, item.typeName)) {
          specStatus = "pending";
        } else {
          specStatus = "unknown";
        }

        this.sql.exec(
          `INSERT INTO network_entities
            (entity_key, net_id, kind, name, type_name, methods_json, probe_json, spec_status, last_seen)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
           ON CONFLICT(entity_key) DO UPDATE SET
             net_id = excluded.net_id,
             kind = excluded.kind,
             name = excluded.name,
             type_name = excluded.type_name,
             methods_json = excluded.methods_json,
             probe_json = COALESCE(excluded.probe_json, network_entities.probe_json),
             spec_status = excluded.spec_status,
             last_seen = excluded.last_seen`,
          item.entityKey,
          netId,
          item.kind,
          item.name,
          item.typeName,
          JSON.stringify(item.methods),
          item.probeJson,
          specStatus,
          now,
        );

        if (specStatus === "pending" && !item.probeJson) {
          pendingWithoutProbe.push({
            entityKey: item.entityKey,
            name: item.name,
            typeName: item.typeName,
          });
        }
      }
    });

    const autoProbeTaskIds: string[] = [];
    for (const item of pendingWithoutProbe) {
      const taskId = this.maybeEnqueueAutoProbe(
        netId,
        item.entityKey,
        item.name,
        item.typeName,
      );
      if (taskId) {
        autoProbeTaskIds.push(taskId);
      }
    }

    this.safeSend(ws, {
      type: "ACK",
      ref_type: "SYNC_TOPOLOGY",
      ok: true,
      net_id: netId,
      count: normalized.length,
      auto_probe_tasks: autoProbeTaskIds,
    });
  }

  private async handlePeripheralAttached(
    ws: WebSocket,
    attachment: WsAttachment,
    msg: Extract<ClientWsMessage, { type: "PERIPHERAL_ATTACHED" }>,
  ): Promise<void> {
    const netId = (msg.net_id || msg.gateway_id || attachment.net || "main").trim();
    const name = typeof msg.name === "string" ? msg.name.trim() : "";
    if (!name) {
      this.safeSend(ws, {
        type: "ERROR",
        code: "INVALID_ENTITY",
        message: "PERIPHERAL_ATTACHED requires a peripheral name",
      });
      return;
    }

    const probeObj =
      msg.probe && typeof msg.probe === "object" ? msg.probe : null;
    const typeName = (
      msg.type_name ||
      msg.peripheral_type ||
      (probeObj && "type" in probeObj && typeof probeObj.type === "string"
        ? probeObj.type
        : "") ||
      "unknown"
    ).trim();
    const kind = normalizeEntityKind(msg.kind, typeName);
    const methods = Array.isArray(msg.methods)
      ? msg.methods.filter((m): m is string => typeof m === "string")
      : probeObj && "methods" in probeObj && Array.isArray(probeObj.methods)
        ? (probeObj.methods as unknown[]).filter((m): m is string => typeof m === "string")
        : [];
    const probeJson = probeObj ? JSON.stringify(probeObj) : null;
    const entityKey = `${netId}::${name}`;
    const now = Date.now();

    const knownSpecs = await this.lookupKnownSpecTypes([typeName]);
    let specStatus: SpecStatus;
    if (knownSpecs.has(typeName)) {
      specStatus = "known";
    } else if (entityNeedsSpec(kind, typeName)) {
      specStatus = "pending";
    } else {
      specStatus = "unknown";
    }

    this.sql.exec(
      `INSERT INTO network_entities
        (entity_key, net_id, kind, name, type_name, methods_json, probe_json, spec_status, last_seen)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(entity_key) DO UPDATE SET
         net_id = excluded.net_id,
         kind = excluded.kind,
         name = excluded.name,
         type_name = excluded.type_name,
         methods_json = excluded.methods_json,
         probe_json = COALESCE(excluded.probe_json, network_entities.probe_json),
         spec_status = excluded.spec_status,
         last_seen = excluded.last_seen`,
      entityKey,
      netId,
      kind,
      name,
      typeName,
      JSON.stringify(methods),
      probeJson,
      specStatus,
      now,
    );

    let autoProbeTaskId: string | null = null;
    if (specStatus === "pending" && !probeJson) {
      autoProbeTaskId = this.maybeEnqueueAutoProbe(
        netId,
        entityKey,
        name,
        typeName,
      );
    }

    this.safeSend(ws, {
      type: "ACK",
      ref_type: "PERIPHERAL_ATTACHED",
      ok: true,
      entity_key: entityKey,
      spec_status: specStatus,
      auto_probe_task_id: autoProbeTaskId,
    });
  }

  private handlePeripheralDetached(
    ws: WebSocket,
    attachment: WsAttachment,
    msg: Extract<ClientWsMessage, { type: "PERIPHERAL_DETACHED" }>,
  ): void {
    const netId = (msg.net_id || msg.gateway_id || attachment.net || "main").trim();
    const name = typeof msg.name === "string" ? msg.name.trim() : "";
    if (!name) {
      this.safeSend(ws, {
        type: "ERROR",
        code: "INVALID_ENTITY",
        message: "PERIPHERAL_DETACHED requires a peripheral name",
      });
      return;
    }

    const entityKey = `${netId}::${name}`;
    this.sql.exec(
      "DELETE FROM network_entities WHERE entity_key = ? OR (net_id = ? AND name = ?)",
      entityKey,
      netId,
      name,
    );

    this.safeSend(ws, {
      type: "ACK",
      ref_type: "PERIPHERAL_DETACHED",
      ok: true,
      entity_key: entityKey,
      name,
    });
  }

  private handlePollQueue(
    ws: WebSocket,
    attachment: WsAttachment,
    msg: Extract<ClientWsMessage, { type: "POLL_QUEUE" }>,
  ): void {
    const netId = (msg.net_id || msg.gateway_id || attachment.net || "main").trim();
    const rawCap = msg.capacity ?? msg.max_batch ?? 1;
    const capacity = Math.max(1, Math.min(10, Math.floor(Number(rawCap) || 1)));
    const now = Date.now();

    let dispatched: DispatchedTask[] = [];
    let hasMore = false;

    this.ctx.storage.transactionSync(() => {
      // 1. Reclaim expired leases
      this.sql.exec(
        `UPDATE task_queue
         SET status = 'pending', lease_expires_at = NULL, updated_at = ?
         WHERE net_id = ? AND status = 'leased' AND lease_expires_at <= ?`,
        now,
        netId,
        now,
      );

      // 2. Fetch up to capacity + 1 pending tasks by priority DESC, created_at ASC
      const rows = this.sql
        .exec<TaskQueueSqlRow>(
          `SELECT * FROM task_queue
           WHERE net_id = ? AND status = 'pending'
           ORDER BY priority DESC, created_at ASC
           LIMIT ?`,
          netId,
          capacity + 1,
        )
        .toArray();

      hasMore = rows.length > capacity;
      const toClaim = rows.slice(0, capacity);

      dispatched = toClaim.map((row) => {
        const leaseMs =
          typeof row.lease_ms === "number" && row.lease_ms > 0
            ? row.lease_ms
            : DEFAULT_LEASE_MS;
        const leaseExpiresAt = now + leaseMs;

        this.sql.exec(
          `UPDATE task_queue
           SET status = 'leased', lease_expires_at = ?, updated_at = ?
           WHERE task_id = ? AND status = 'pending'`,
          leaseExpiresAt,
          now,
          row.task_id,
        );

        return {
          task_id: row.task_id,
          net_id: row.net_id,
          target_node: row.target_node,
          tool_name: row.tool_name,
          lua_code: row.lua_code,
          args: safeJsonParse<Record<string, unknown>>(row.args_json, {}),
          priority: row.priority,
          lease_expires_at: leaseExpiresAt,
        };
      });
    });

    this.safeSend(ws, {
      type: "DISPATCH_BATCH",
      net_id: netId,
      tasks: dispatched,
      has_more: hasMore,
    });
  }

  private async handleTaskResult(
    ws: WebSocket,
    msg: Extract<ClientWsMessage, { type: "TASK_RESULT" }>,
  ): Promise<void> {
    const taskId = typeof msg.task_id === "string" ? msg.task_id.trim() : "";
    if (!taskId) {
      this.safeSend(ws, {
        type: "ERROR",
        code: "INVALID_TASK_RESULT",
        message: "TASK_RESULT requires task_id",
      });
      return;
    }

    const now = Date.now();
    const ok = Boolean(msg.ok);
    const stdout = typeof msg.stdout === "string" ? msg.stdout : "";
    const resultJson =
      msg.result !== undefined ? JSON.stringify(msg.result) : null;
    const errorText = typeof msg.error === "string" ? msg.error : null;
    const ttlMs =
      typeof msg.ttl_ms === "number" && msg.ttl_ms > 0
        ? Math.floor(msg.ttl_ms)
        : DEFAULT_OUTPUT_TTL_MS;
    const expiresAt = now + ttlMs;

    const taskRow = this.sql
      .exec<TaskQueueSqlRow>(
        "SELECT * FROM task_queue WHERE task_id = ?",
        taskId,
      )
      .toArray()[0];

    this.ctx.storage.transactionSync(() => {
      this.sql.exec(
        `UPDATE task_queue
         SET status = ?, lease_expires_at = NULL, updated_at = ?
         WHERE task_id = ?`,
        ok ? "completed" : "failed",
        now,
        taskId,
      );

      this.sql.exec(
        `INSERT OR REPLACE INTO task_outputs
          (task_id, ok, stdout, result_json, error, created_at, expires_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
        taskId,
        ok ? 1 : 0,
        stdout,
        resultJson,
        errorText,
        now,
        expiresAt,
      );

      // If this was a get_api probe task that succeeded, hydrate network_entities.probe_json
      if (
        taskRow &&
        taskRow.tool_name === "get_api" &&
        ok &&
        msg.result &&
        typeof msg.result === "object" &&
        !Array.isArray(msg.result)
      ) {
        const probeResult = msg.result as Record<string, unknown>;
        const taskArgs = safeJsonParse<Record<string, unknown>>(
          taskRow.args_json,
          {},
        );
        const entityName =
          typeof taskArgs.name === "string"
            ? taskArgs.name
            : typeof probeResult.name === "string"
              ? probeResult.name
              : "";
        const entityKey =
          typeof taskArgs.entity_key === "string"
            ? taskArgs.entity_key
            : entityName
              ? `${taskRow.net_id}::${entityName}`
              : "";

        if (entityKey) {
          const probedMethods = Array.isArray(probeResult.methods)
            ? probeResult.methods.filter((m): m is string => typeof m === "string")
            : null;
          if (probedMethods) {
            this.sql.exec(
              `UPDATE network_entities
               SET probe_json = ?, methods_json = ?, last_seen = ?
               WHERE entity_key = ?`,
              JSON.stringify(probeResult),
              JSON.stringify(probedMethods),
              now,
              entityKey,
            );
          } else {
            this.sql.exec(
              `UPDATE network_entities
               SET probe_json = ?, last_seen = ?
               WHERE entity_key = ?`,
              JSON.stringify(probeResult),
              now,
              entityKey,
            );
          }
        }
      }
    });

    await this.scheduleOutputCleanupAlarm();

    this.safeSend(ws, {
      type: "ACK",
      ref_type: "TASK_RESULT",
      ok: true,
      task_id: taskId,
    });
  }

  private handleSub(
    ws: WebSocket,
    attachment: WsAttachment,
    msg: Extract<ClientWsMessage, { type: "SUB" }>,
  ): void {
    const incoming: string[] = [];
    if (typeof msg.topic === "string" && msg.topic.trim()) {
      incoming.push(msg.topic.trim());
    }
    if (Array.isArray(msg.topics)) {
      for (const t of msg.topics) {
        if (typeof t === "string" && t.trim()) {
          incoming.push(t.trim());
        }
      }
    }

    const updatedSet = new Set(attachment.subscriptions);
    for (const t of incoming) {
      updatedSet.add(t);
    }

    const nextAttachment: WsAttachment = {
      ...attachment,
      subscriptions: Array.from(updatedSet),
    };
    ws.serializeAttachment(nextAttachment);

    this.safeSend(ws, {
      type: "SUB_ACK",
      topic: incoming[0],
      topics: nextAttachment.subscriptions,
    });
  }

  private handleUnsub(
    ws: WebSocket,
    attachment: WsAttachment,
    msg: Extract<ClientWsMessage, { type: "UNSUB" }>,
  ): void {
    const toRemove = new Set<string>();
    if (typeof msg.topic === "string" && msg.topic.trim()) {
      toRemove.add(msg.topic.trim());
    }
    if (Array.isArray(msg.topics)) {
      for (const t of msg.topics) {
        if (typeof t === "string" && t.trim()) {
          toRemove.add(t.trim());
        }
      }
    }

    const nextAttachment: WsAttachment = {
      ...attachment,
      subscriptions: attachment.subscriptions.filter((s) => !toRemove.has(s)),
    };
    ws.serializeAttachment(nextAttachment);

    this.safeSend(ws, {
      type: "SUB_ACK",
      topics: nextAttachment.subscriptions,
    });
  }

  private handlePub(
    ws: WebSocket,
    senderAttachment: WsAttachment,
    msg: Extract<ClientWsMessage, { type: "PUB" }>,
  ): void {
    const topic = typeof msg.topic === "string" ? msg.topic.trim() : "";
    if (!topic) {
      this.safeSend(ws, {
        type: "ERROR",
        code: "INVALID_PUB",
        message: "PUB requires a non-empty topic",
      });
      return;
    }

    const eventFrame: ServerWsMessage = {
      type: "EVENT",
      topic,
      payload: msg.payload,
      from_net: senderAttachment.net,
      sender: senderAttachment.clientId,
      timestamp: Date.now(),
    };

    for (const peer of this.ctx.getWebSockets()) {
      if (peer === ws && !msg.echo) {
        continue;
      }
      const peerAtt = this.getAttachment(peer);
      if (peerAtt.subscriptions.includes(topic)) {
        this.safeSend(peer, eventFrame);
      }
    }
  }

  private handleKvSet(
    ws: WebSocket,
    msg: Extract<ClientWsMessage, { type: "KV_SET" }>,
  ): void {
    const key = typeof msg.key === "string" ? msg.key.trim() : "";
    if (!key) {
      this.safeSend(ws, {
        type: "ERROR",
        code: "INVALID_KV",
        message: "KV_SET requires a non-empty key",
      });
      return;
    }

    const now = Date.now();
    this.sql.exec(
      `INSERT INTO kv_store (key, value_json, updated_at)
       VALUES (?, ?, ?)
       ON CONFLICT(key) DO UPDATE SET
         value_json = excluded.value_json,
         updated_at = excluded.updated_at`,
      key,
      JSON.stringify(msg.value === undefined ? null : msg.value),
      now,
    );

    this.safeSend(ws, {
      type: "KV_ACK",
      key,
      ok: true,
      request_id: msg.request_id,
    });
  }

  private handleKvGet(
    ws: WebSocket,
    msg: Extract<ClientWsMessage, { type: "KV_GET" }>,
  ): void {
    const key = typeof msg.key === "string" ? msg.key.trim() : "";
    if (!key) {
      this.safeSend(ws, {
        type: "ERROR",
        code: "INVALID_KV",
        message: "KV_GET requires a non-empty key",
      });
      return;
    }

    const row = this.sql
      .exec<KvStoreSqlRow>(
        "SELECT key, value_json, updated_at FROM kv_store WHERE key = ?",
        key,
      )
      .toArray()[0];

    this.safeSend(ws, {
      type: "KV_VALUE",
      key,
      value: row ? safeJsonParse(row.value_json, null) : null,
      found: Boolean(row),
      updated_at: row ? row.updated_at : null,
      request_id: msg.request_id,
    });
  }

  // -------------------------------------------------------------------------
  // Task Queue Insertion & Interrupt-Driven WAKE
  // -------------------------------------------------------------------------

  private insertTaskAndWake(opts: {
    netId: string;
    targetNode: string;
    toolName: string | null;
    luaCode: string;
    args: Record<string, unknown>;
    priority: number;
    leaseMs: number;
    wakeReason?: string;
  }): { taskId: string; pendingCount: number; wokeGateways: number } {
    const taskId = `task_${crypto.randomUUID()}`;
    const now = Date.now();

    this.sql.exec(
      `INSERT INTO task_queue
        (task_id, net_id, target_node, tool_name, lua_code, args_json, priority, status, lease_ms, lease_expires_at, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', ?, NULL, ?, ?)`,
      taskId,
      opts.netId,
      opts.targetNode,
      opts.toolName,
      opts.luaCode,
      JSON.stringify(opts.args),
      opts.priority,
      opts.leaseMs,
      now,
      now,
    );

    const countRow = this.sql
      .exec<CountSqlRow>(
        "SELECT COUNT(*) AS cnt FROM task_queue WHERE net_id = ? AND status = 'pending'",
        opts.netId,
      )
      .one();
    const pendingCount = countRow?.cnt ?? 1;

    const wakeFrame: ServerWsMessage = {
      type: "WAKE",
      net_id: opts.netId,
      task_id: taskId,
      pending_count: pendingCount,
      reason: opts.wakeReason,
    };

    let wokeGateways = 0;
    const gatewaySockets = this.ctx.getWebSockets("role:gateway");
    for (const gw of gatewaySockets) {
      const att = this.getAttachment(gw);
      if (att.net === opts.netId) {
        if (this.safeSend(gw, wakeFrame)) {
          wokeGateways += 1;
        }
      }
    }

    return { taskId, pendingCount, wokeGateways };
  }

  // -------------------------------------------------------------------------
  // MCP JSON-RPC 2.0 Server (HTTP & WebSocket) + MCP Sampling
  // -------------------------------------------------------------------------

  private async handleWsJsonRpc(
    ws: WebSocket,
    parsed: Record<string, unknown>,
  ): Promise<void> {
    // Outbound request response (e.g. client replying to sampling/createMessage)
    if (
      !("method" in parsed) &&
      ("result" in parsed || "error" in parsed) &&
      parsed.id !== undefined &&
      parsed.id !== null
    ) {
      const reqId = String(parsed.id);
      const pending = this.pendingSamplingRequests.get(reqId);
      if (pending) {
        clearTimeout(pending.timer);
        this.pendingSamplingRequests.delete(reqId);
        if (parsed.error && typeof parsed.error === "object") {
          const errObj = parsed.error as { message?: string };
          pending.reject(
            new Error(errObj.message || "MCP sampling request rejected"),
          );
        } else {
          pending.resolve(parsed.result as McpSamplingCreateMessageResult);
        }
      }
      return;
    }

    // Inbound MCP JSON-RPC request over WS
    const req = parsed as unknown as JsonRpcRequest;
    const attachment = this.getAttachment(ws);

    if (req.method === "initialize") {
      const params = (req.params ?? {}) as { capabilities?: McpClientCapabilities };
      const hasSampling = Boolean(
        params.capabilities &&
          typeof params.capabilities === "object" &&
          params.capabilities.sampling,
      );
      if (hasSampling) {
        ws.serializeAttachment({
          ...attachment,
          role: "mcp",
          supportsSampling: true,
        } satisfies WsAttachment);
      }
    }

    const response = await this.dispatchMcpJsonRpc(req, attachment.clientId);
    if (response) {
      this.safeSend(ws, response);
    }
  }

  private async handleMcpHttpRequest(request: Request): Promise<Response> {
    if (request.method.toUpperCase() !== "POST") {
      return Response.json(
        { error: "Method not allowed; use POST for MCP JSON-RPC 2.0" },
        { status: 405 },
      );
    }

    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return Response.json(
        makeJsonRpcError(null, -32700, "Parse error: invalid JSON body"),
      );
    }

    if (!body || typeof body !== "object" || Array.isArray(body)) {
      return Response.json(
        makeJsonRpcError(null, -32600, "Invalid Request: expected JSON-RPC object"),
      );
    }

    const req = body as JsonRpcRequest;
    if (req.jsonrpc !== "2.0" || typeof req.method !== "string") {
      return Response.json(
        makeJsonRpcError(
          req.id ?? null,
          -32600,
          "Invalid Request: missing jsonrpc '2.0' or method",
        ),
      );
    }

    const incomingSessionId = request.headers.get("Mcp-Session-Id")?.trim();
    const sessionId = incomingSessionId || crypto.randomUUID();

    // JSON-RPC notifications (no id) or notifications/* return 202 Accepted
    if (req.id === undefined || req.method.startsWith("notifications/")) {
      await this.dispatchMcpJsonRpc(req, sessionId);
      return new Response(null, {
        status: 202,
        headers: { "Mcp-Session-Id": sessionId },
      });
    }

    const rpcResponse = await this.dispatchMcpJsonRpc(req, sessionId);
    return Response.json(rpcResponse, {
      status: 200,
      headers: { "Mcp-Session-Id": sessionId },
    });
  }

  private async dispatchMcpJsonRpc(
    req: JsonRpcRequest,
    sessionId: string,
  ): Promise<JsonRpcResponse | null> {
    const id: JsonRpcId = req.id ?? null;

    if (req.method.startsWith("notifications/")) {
      return null;
    }

    try {
      switch (req.method) {
        case "initialize": {
          const result = this.handleMcpInitialize(req.params ?? {}, sessionId);
          return req.id === undefined ? null : makeJsonRpcSuccess(id, result);
        }
        case "ping":
          return req.id === undefined ? null : makeJsonRpcSuccess(id, {});
        case "tools/list": {
          const tools = this.listAllMcpTools();
          return req.id === undefined
            ? null
            : makeJsonRpcSuccess(id, { tools });
        }
        case "tools/call": {
          const params = (req.params ?? {}) as {
            name?: string;
            arguments?: Record<string, unknown>;
          };
          const toolName =
            typeof params.name === "string" ? params.name.trim() : "";
          if (!toolName) {
            return makeJsonRpcError(id, -32602, "Missing required parameter: name");
          }
          const toolArgs =
            params.arguments && typeof params.arguments === "object"
              ? params.arguments
              : {};
          const callResult = await this.handleMcpToolCall(toolName, toolArgs);
          return req.id === undefined
            ? null
            : makeJsonRpcSuccess(id, callResult);
        }
        case "resources/list":
          return req.id === undefined
            ? null
            : makeJsonRpcSuccess(id, { resources: MCP_RESOURCES });
        case "resources/read": {
          const params = (req.params ?? {}) as { uri?: string };
          const uri = typeof params.uri === "string" ? params.uri.trim() : "";
          if (!uri) {
            return makeJsonRpcError(id, -32602, "Missing required parameter: uri");
          }
          const readResult = await this.handleMcpResourceRead(uri);
          if (!readResult) {
            return makeJsonRpcError(id, -32002, `Resource not found: ${uri}`);
          }
          return req.id === undefined
            ? null
            : makeJsonRpcSuccess(id, readResult);
        }
        default:
          return req.id === undefined
            ? null
            : makeJsonRpcError(id, -32601, `Method not found: ${req.method}`);
      }
    } catch (err) {
      if (err instanceof McpRpcError) {
        return makeJsonRpcError(id, err.code, err.message, err.data);
      }
      return makeJsonRpcError(
        id,
        -32603,
        err instanceof Error ? err.message : String(err),
      );
    }
  }

  private handleMcpInitialize(
    params: Record<string, unknown>,
    sessionId: string,
  ): Record<string, unknown> {
    const capabilities =
      params.capabilities && typeof params.capabilities === "object"
        ? (params.capabilities as McpClientCapabilities)
        : {};
    const clientInfo =
      params.clientInfo && typeof params.clientInfo === "object"
        ? (params.clientInfo as { name?: string; version?: string })
        : {};
    const protocolVersion =
      typeof params.protocolVersion === "string" && params.protocolVersion.trim()
        ? params.protocolVersion.trim()
        : MCP_PROTOCOL_VERSION;
    const supportsSampling = Boolean(capabilities.sampling);
    const now = Date.now();
    const capsJson = JSON.stringify(capabilities);

    for (const key of [sessionId, "latest"]) {
      this.sql.exec(
        `INSERT INTO mcp_sessions
          (session_id, client_name, client_version, protocol_version, supports_sampling, capabilities_json, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(session_id) DO UPDATE SET
           client_name = excluded.client_name,
           client_version = excluded.client_version,
           protocol_version = excluded.protocol_version,
           supports_sampling = excluded.supports_sampling,
           capabilities_json = excluded.capabilities_json,
           updated_at = excluded.updated_at`,
        key,
        typeof clientInfo.name === "string" ? clientInfo.name : null,
        typeof clientInfo.version === "string" ? clientInfo.version : null,
        protocolVersion,
        supportsSampling ? 1 : 0,
        capsJson,
        now,
      );
    }

    return {
      protocolVersion: MCP_PROTOCOL_VERSION,
      capabilities: {
        tools: { listChanged: true },
        resources: { subscribe: false, listChanged: false },
      },
      serverInfo: {
        name: "cc-mesh-bridge",
        version: "1.0.0",
      },
    };
  }

  private listAllMcpTools(): McpToolDefinition[] {
    const learnedRows = this.sql
      .exec<LearnedToolSqlRow>(
        "SELECT * FROM learned_tools ORDER BY builtin DESC, name ASC",
      )
      .toArray();

    const dynamicTools: McpToolDefinition[] = learnedRows.map((row) => ({
      name: `cc_${row.name}`,
      description: row.description,
      inputSchema: safeJsonParse<Record<string, unknown>>(
        row.input_schema_json,
        { type: "object", properties: {} },
      ),
    }));

    return [...BUILTIN_MCP_TOOLS, ...dynamicTools];
  }

  private async handleMcpToolCall(
    toolName: string,
    args: Record<string, unknown>,
  ): Promise<McpToolCallResult> {
    switch (toolName) {
      case "list_network_topology":
        return this.toolListNetworkTopology(args);
      case "enqueue_task":
        return this.toolEnqueueTask(args);
      case "get_task_output":
        return this.toolGetTaskOutput(args);
      case "register_learned_tool":
        return this.toolRegisterLearnedTool(args);
      case "save_device_api_spec":
        return this.toolSaveDeviceApiSpec(args);
      case "synthesize_device_spec":
        return this.toolSynthesizeDeviceSpec(args);
      default:
        if (toolName.startsWith("cc_")) {
          return this.toolInvokeLearnedTool(toolName.slice(3), args);
        }
        throw new McpRpcError(-32602, `Unknown tool: ${toolName}`);
    }
  }

  private async toolListNetworkTopology(
    args: Record<string, unknown>,
  ): Promise<McpToolCallResult> {
    const netId =
      typeof args.net_id === "string" && args.net_id.trim()
        ? args.net_id.trim()
        : null;

    const rows = netId
      ? this.sql
          .exec<NetworkEntitySqlRow>(
            "SELECT * FROM network_entities WHERE net_id = ? ORDER BY net_id ASC, name ASC",
            netId,
          )
          .toArray()
      : this.sql
          .exec<NetworkEntitySqlRow>(
            "SELECT * FROM network_entities ORDER BY net_id ASC, name ASC",
          )
          .toArray();

    const specsMap = await this.fetchSpecsMap(rows.map((r) => r.type_name));

    const entities: EnrichedNetworkEntity[] = rows.map((row) => {
      const spec = specsMap.get(row.type_name) ?? null;
      const specStatus = (spec ? "known" : row.spec_status) as SpecStatus;
      return {
        entity_key: row.entity_key,
        net_id: row.net_id,
        kind: row.kind,
        name: row.name,
        type_name: row.type_name,
        methods: safeJsonParse<string[]>(row.methods_json, []),
        probe: safeJsonParse<Record<string, unknown> | null>(
          row.probe_json,
          null,
        ),
        spec_status: specStatus,
        last_seen: row.last_seen,
        spec,
      };
    });

    return makeToolResult({
      entities,
      count: entities.length,
    });
  }

  private toolEnqueueTask(args: Record<string, unknown>): McpToolCallResult {
    const luaCode = typeof args.lua_code === "string" ? args.lua_code : "";
    if (!luaCode.trim()) {
      throw new McpRpcError(-32602, "enqueue_task requires non-empty lua_code");
    }

    const netId =
      typeof args.net_id === "string" && args.net_id.trim()
        ? args.net_id.trim()
        : "main";
    const targetNode =
      typeof args.target_node === "string" && args.target_node.trim()
        ? args.target_node.trim()
        : "gateway";
    const taskArgs =
      args.args && typeof args.args === "object" && !Array.isArray(args.args)
        ? (args.args as Record<string, unknown>)
        : {};
    const priority =
      typeof args.priority === "number" && Number.isFinite(args.priority)
        ? Math.floor(args.priority)
        : 0;
    const leaseMs =
      typeof args.lease_ms === "number" && args.lease_ms > 0
        ? Math.floor(args.lease_ms)
        : DEFAULT_LEASE_MS;

    const { taskId, pendingCount, wokeGateways } = this.insertTaskAndWake({
      netId,
      targetNode,
      toolName: null,
      luaCode,
      args: taskArgs,
      priority,
      leaseMs,
      wakeReason: "enqueue_task",
    });

    return makeToolResult({
      task_id: taskId,
      net_id: netId,
      target_node: targetNode,
      status: "pending",
      priority,
      lease_ms: leaseMs,
      pending_count: pendingCount,
      woke_gateways: wokeGateways,
    });
  }

  private toolGetTaskOutput(args: Record<string, unknown>): McpToolCallResult {
    const taskId =
      typeof args.task_id === "string" ? args.task_id.trim() : "";
    if (!taskId) {
      throw new McpRpcError(-32602, "get_task_output requires task_id");
    }

    const taskRow = this.sql
      .exec<TaskQueueSqlRow>(
        "SELECT * FROM task_queue WHERE task_id = ?",
        taskId,
      )
      .toArray()[0];

    const outRow = this.sql
      .exec<TaskOutputSqlRow>(
        "SELECT * FROM task_outputs WHERE task_id = ?",
        taskId,
      )
      .toArray()[0];

    if (!taskRow && !outRow) {
      return makeToolResult({
        found: false,
        task_id: taskId,
        status: "not_found",
        output: null,
      });
    }

    if (!outRow) {
      return makeToolResult({
        found: true,
        task_id: taskId,
        status: taskRow.status,
        lease_expires_at: taskRow.lease_expires_at,
        output: null,
      });
    }

    return makeToolResult({
      found: true,
      task_id: taskId,
      status: taskRow?.status ?? (outRow.ok ? "completed" : "failed"),
      ok: Boolean(outRow.ok),
      stdout: outRow.stdout,
      result: safeJsonParse(outRow.result_json, null),
      error: outRow.error,
      created_at: outRow.created_at,
      expires_at: outRow.expires_at,
    });
  }

  private toolRegisterLearnedTool(
    args: Record<string, unknown>,
  ): McpToolCallResult {
    const rawName = typeof args.name === "string" ? args.name.trim() : "";
    const name = rawName.startsWith("cc_") ? rawName.slice(3) : rawName;
    if (!name || !TOOL_NAME_RE.test(name)) {
      throw new McpRpcError(
        -32602,
        "register_learned_tool requires a valid name matching ^[a-zA-Z0-9_-]+$",
      );
    }

    const description =
      typeof args.description === "string" ? args.description.trim() : "";
    if (!description) {
      throw new McpRpcError(
        -32602,
        "register_learned_tool requires a non-empty description",
      );
    }

    const luaTemplate =
      typeof args.lua_template === "string" ? args.lua_template : "";
    if (!luaTemplate.trim()) {
      throw new McpRpcError(
        -32602,
        "register_learned_tool requires a non-empty lua_template",
      );
    }

    const inputSchema =
      args.input_schema &&
      typeof args.input_schema === "object" &&
      !Array.isArray(args.input_schema)
        ? (args.input_schema as Record<string, unknown>)
        : { type: "object", properties: {} };

    const now = Date.now();
    this.sql.exec(
      `INSERT INTO learned_tools
        (name, description, input_schema_json, lua_template, builtin, created_at, updated_at)
       VALUES (?, ?, ?, ?, 0, ?, ?)
       ON CONFLICT(name) DO UPDATE SET
         description = excluded.description,
         input_schema_json = excluded.input_schema_json,
         lua_template = excluded.lua_template,
         updated_at = excluded.updated_at`,
      name,
      description,
      JSON.stringify(inputSchema),
      luaTemplate,
      now,
      now,
    );

    return makeToolResult({
      ok: true,
      name,
      mcp_tool_name: `cc_${name}`,
      description,
    });
  }

  private async upsertDeviceSpecInD1AndMarkKnown(params: {
    typeName: string;
    methods: string[];
    specJson: Record<string, unknown>;
    specMarkdown: string;
    generatedBy: string;
  }): Promise<{ spec: DeviceApiSpec; entitiesUpdated: number }> {
    const now = Date.now();
    await this.env.CATALOG_DB.prepare(
      `INSERT INTO device_api_specs
        (type_name, methods_json, spec_json, spec_markdown, generated_by, updated_at)
       VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT(type_name) DO UPDATE SET
         methods_json = excluded.methods_json,
         spec_json = excluded.spec_json,
         spec_markdown = excluded.spec_markdown,
         generated_by = excluded.generated_by,
         updated_at = excluded.updated_at`,
    )
      .bind(
        params.typeName,
        JSON.stringify(params.methods),
        JSON.stringify(params.specJson),
        params.specMarkdown,
        params.generatedBy,
        now,
      )
      .run();

    const stored = await this.env.CATALOG_DB.prepare(
      "SELECT * FROM device_api_specs WHERE type_name = ?",
    )
      .bind(params.typeName)
      .first<RawD1DeviceSpecRow>();

    this.sql.exec(
      "UPDATE network_entities SET spec_status = 'known' WHERE type_name = ?",
      params.typeName,
    );
    const changesRow = this.sql
      .exec<CountSqlRow>("SELECT changes() AS cnt")
      .one();

    const spec: DeviceApiSpec = stored
      ? mapD1SpecRow(stored)
      : {
          type_name: params.typeName,
          methods: params.methods,
          spec_json: params.specJson,
          spec_markdown: params.specMarkdown,
          generated_by: params.generatedBy,
          updated_at: now,
        };

    return {
      spec,
      entitiesUpdated: changesRow?.cnt ?? 0,
    };
  }

  private async toolSaveDeviceApiSpec(
    args: Record<string, unknown>,
  ): Promise<McpToolCallResult> {
    const typeName =
      typeof args.type_name === "string" ? args.type_name.trim() : "";
    if (!typeName) {
      throw new McpRpcError(-32602, "save_device_api_spec requires type_name");
    }

    let methods: string[];
    if (Array.isArray(args.methods)) {
      methods = args.methods.filter((m): m is string => typeof m === "string");
    } else {
      const entityRow = this.sql
        .exec<NetworkEntitySqlRow>(
          "SELECT * FROM network_entities WHERE type_name = ? ORDER BY last_seen DESC LIMIT 1",
          typeName,
        )
        .toArray()[0];
      methods = entityRow
        ? safeJsonParse<string[]>(entityRow.methods_json, [])
        : [];
    }

    const specJson =
      args.spec_json &&
      typeof args.spec_json === "object" &&
      !Array.isArray(args.spec_json)
        ? (args.spec_json as Record<string, unknown>)
        : {};
    const specMarkdown =
      typeof args.spec_markdown === "string" ? args.spec_markdown : "";
    const generatedBy =
      typeof args.generated_by === "string" && args.generated_by.trim()
        ? args.generated_by.trim()
        : "agent";

    const { spec, entitiesUpdated } = await this.upsertDeviceSpecInD1AndMarkKnown({
      typeName,
      methods,
      specJson,
      specMarkdown,
      generatedBy,
    });

    return makeToolResult({
      ok: true,
      spec,
      entities_updated: entitiesUpdated,
    });
  }

  private findSamplingCapableSocket(): WebSocket | null {
    // Prefer sockets explicitly tagged as role:mcp with supportsSampling
    for (const ws of this.ctx.getWebSockets("role:mcp")) {
      const att = this.getAttachment(ws);
      if (att.supportsSampling) {
        return ws;
      }
    }
    // Fallback: any connected WS that declared supportsSampling
    for (const ws of this.ctx.getWebSockets()) {
      const att = this.getAttachment(ws);
      if (att.supportsSampling) {
        return ws;
      }
    }
    return null;
  }

  private requestMcpSampling(
    ws: WebSocket,
    prompt: string,
  ): Promise<McpSamplingCreateMessageResult> {
    const reqId = `sample_${crypto.randomUUID()}`;

    return new Promise<McpSamplingCreateMessageResult>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pendingSamplingRequests.delete(reqId);
        reject(new Error("MCP sampling/createMessage timed out"));
      }, SAMPLING_TIMEOUT_MS);

      this.pendingSamplingRequests.set(reqId, {
        ws,
        resolve,
        reject,
        timer,
      });

      const sent = this.safeSend(ws, {
        jsonrpc: "2.0",
        id: reqId,
        method: "sampling/createMessage",
        params: {
          messages: [
            {
              role: "user",
              content: {
                type: "text",
                text: prompt,
              },
            },
          ],
          systemPrompt:
            "You are a ComputerCraft (CC: Tweaked) peripheral API specification architect. Return valid JSON with spec_json (object) and spec_markdown (string).",
          maxTokens: 2048,
        },
      });

      if (!sent) {
        clearTimeout(timer);
        this.pendingSamplingRequests.delete(reqId);
        reject(new Error("Failed to send sampling/createMessage over WebSocket"));
      }
    });
  }

  private async toolSynthesizeDeviceSpec(
    args: Record<string, unknown>,
  ): Promise<McpToolCallResult> {
    const typeName =
      typeof args.type_name === "string" ? args.type_name.trim() : "";
    if (!typeName) {
      throw new McpRpcError(-32602, "synthesize_device_spec requires type_name");
    }

    const netId =
      typeof args.net_id === "string" && args.net_id.trim()
        ? args.net_id.trim()
        : null;
    const entityName =
      typeof args.entity_name === "string" && args.entity_name.trim()
        ? args.entity_name.trim()
        : null;
    const force = Boolean(args.force);

    if (!force) {
      const existing = await this.env.CATALOG_DB.prepare(
        "SELECT * FROM device_api_specs WHERE type_name = ?",
      )
        .bind(typeName)
        .first<RawD1DeviceSpecRow>();
      if (existing) {
        return makeToolResult({
          status: "already_known",
          spec: mapD1SpecRow(existing),
        });
      }
    }

    // Gather entity methods & probe metadata from network_entities
    let entityRows: NetworkEntitySqlRow[];
    if (netId && entityName) {
      entityRows = this.sql
        .exec<NetworkEntitySqlRow>(
          "SELECT * FROM network_entities WHERE type_name = ? AND net_id = ? AND name = ? ORDER BY last_seen DESC",
          typeName,
          netId,
          entityName,
        )
        .toArray();
    } else if (netId) {
      entityRows = this.sql
        .exec<NetworkEntitySqlRow>(
          "SELECT * FROM network_entities WHERE type_name = ? AND net_id = ? ORDER BY last_seen DESC",
          typeName,
          netId,
        )
        .toArray();
    } else {
      entityRows = this.sql
        .exec<NetworkEntitySqlRow>(
          "SELECT * FROM network_entities WHERE type_name = ? ORDER BY last_seen DESC",
          typeName,
        )
        .toArray();
    }

    const methodSet = new Set<string>();
    let probe: Record<string, unknown> | null = null;
    for (const row of entityRows) {
      for (const m of safeJsonParse<string[]>(row.methods_json, [])) {
        methodSet.add(m);
      }
      if (!probe && row.probe_json) {
        probe = safeJsonParse<Record<string, unknown> | null>(
          row.probe_json,
          null,
        );
      }
    }
    const methods = Array.from(methodSet).sort();
    const synthesisPrompt = buildSynthesisPrompt(typeName, methods, probe);

    // Primary path: MCP Sampling via connected sampling-capable MCP WebSocket client
    const samplingSocket = this.findSamplingCapableSocket();
    if (samplingSocket) {
      try {
        const sampleResult = await this.requestMcpSampling(
          samplingSocket,
          synthesisPrompt,
        );
        const responseText =
          sampleResult?.content?.type === "text" &&
          typeof sampleResult.content.text === "string"
            ? sampleResult.content.text
            : "";

        const parsed = parseSynthesizedSpecResponse(
          responseText,
          typeName,
          methods,
        );
        const generatedBy =
          typeof sampleResult.model === "string" && sampleResult.model.trim()
            ? `mcp-sampling:${sampleResult.model.trim()}`
            : "mcp-sampling";

        const { spec, entitiesUpdated } =
          await this.upsertDeviceSpecInD1AndMarkKnown({
            typeName,
            methods,
            specJson: parsed.spec_json,
            specMarkdown: parsed.spec_markdown,
            generatedBy,
          });

        return makeToolResult({
          status: "synthesized",
          synthesized_via: "mcp_sampling",
          spec,
          entities_updated: entitiesUpdated,
        });
      } catch (err) {
        // Gracefully degrade to agent synthesis fallback if sampling fails
        return makeToolResult({
          status: "needs_agent_synthesis",
          type_name: typeName,
          methods,
          probe,
          synthesis_prompt: synthesisPrompt,
          next_tool: "save_device_api_spec",
          sampling_error: err instanceof Error ? err.message : String(err),
        });
      }
    }

    // Fallback path: non-sampling MCP clients synthesize with their own LLM and call save_device_api_spec
    return makeToolResult({
      status: "needs_agent_synthesis",
      type_name: typeName,
      methods,
      probe,
      synthesis_prompt: synthesisPrompt,
      next_tool: "save_device_api_spec",
    });
  }

  private toolInvokeLearnedTool(
    toolName: string,
    rawArgs: Record<string, unknown>,
  ): McpToolCallResult {
    const toolRow = this.sql
      .exec<LearnedToolSqlRow>(
        "SELECT * FROM learned_tools WHERE name = ?",
        toolName,
      )
      .toArray()[0];

    if (!toolRow) {
      throw new McpRpcError(-32602, `Unknown tool: cc_${toolName}`);
    }

    const netId =
      typeof rawArgs._net_id === "string" && rawArgs._net_id.trim()
        ? rawArgs._net_id.trim()
        : typeof rawArgs.net_id === "string" && rawArgs.net_id.trim()
          ? rawArgs.net_id.trim()
          : "main";
    const targetNode =
      typeof rawArgs._target_node === "string" && rawArgs._target_node.trim()
        ? rawArgs._target_node.trim()
        : typeof rawArgs.target_node === "string" && rawArgs.target_node.trim()
          ? rawArgs.target_node.trim()
          : "gateway";

    const forwardedArgs: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(rawArgs)) {
      if (
        k === "_net_id" ||
        k === "_target_node" ||
        k === "net_id" ||
        k === "target_node"
      ) {
        continue;
      }
      forwardedArgs[k] = v;
    }

    const { taskId, pendingCount, wokeGateways } = this.insertTaskAndWake({
      netId,
      targetNode,
      toolName: toolRow.name,
      luaCode: toolRow.lua_template,
      args: forwardedArgs,
      priority: 0,
      leaseMs: DEFAULT_LEASE_MS,
      wakeReason: `tool:cc_${toolRow.name}`,
    });

    return makeToolResult({
      task_id: taskId,
      tool: `cc_${toolRow.name}`,
      net_id: netId,
      target_node: targetNode,
      status: "pending",
      pending_count: pendingCount,
      woke_gateways: wokeGateways,
    });
  }

  private async handleMcpResourceRead(
    uri: string,
  ): Promise<{
    contents: Array<{ uri: string; mimeType: string; text: string }>;
  } | null> {
    if (uri === "cc://specs/pending") {
      const rows = this.sql
        .exec<NetworkEntitySqlRow>(
          "SELECT * FROM network_entities WHERE spec_status = 'pending' ORDER BY last_seen DESC",
        )
        .toArray();

      const pending = rows.map((r) => ({
        entity_key: r.entity_key,
        net_id: r.net_id,
        kind: r.kind,
        name: r.name,
        type_name: r.type_name,
        methods: safeJsonParse<string[]>(r.methods_json, []),
        probe: safeJsonParse<Record<string, unknown> | null>(
          r.probe_json,
          null,
        ),
        last_seen: r.last_seen,
      }));

      return {
        contents: [
          {
            uri,
            mimeType: "application/json",
            text: JSON.stringify({
              pending,
              count: pending.length,
              instructions:
                "Call synthesize_device_spec (or synthesize directly and call save_device_api_spec) for each pending type_name.",
            }),
          },
        ],
      };
    }

    if (uri === "cc://specs/all") {
      const res = await this.env.CATALOG_DB.prepare(
        "SELECT * FROM device_api_specs ORDER BY type_name ASC",
      ).all<RawD1DeviceSpecRow>();

      const specs = res.results.map(mapD1SpecRow);
      return {
        contents: [
          {
            uri,
            mimeType: "application/json",
            text: JSON.stringify({
              specs,
              count: specs.length,
            }),
          },
        ],
      };
    }

    return null;
  }
}

class McpRpcError extends Error {
  readonly code: number;
  readonly data?: unknown;

  constructor(code: number, message: string, data?: unknown) {
    super(message);
    this.code = code;
    this.data = data;
  }
}
