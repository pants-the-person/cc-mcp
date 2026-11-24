import type { CcMeshBridge } from "./bridge_do";

export interface Env {
  BRIDGE_DO: DurableObjectNamespace<CcMeshBridge>;
  CATALOG_DB: D1Database;
  ARTIFACT_BUCKET: R2Bucket;
  REQUIRE_CF_ACCESS?: string;
}

// ---------------------------------------------------------------------------
// Device Introspection & API Specs
// ---------------------------------------------------------------------------

export type SpecStatus = "known" | "pending" | "synthesized" | "unknown";

export interface DeviceProbeData {
  name: string;
  type: string;
  types: string[];
  methods: string[];
  metadata?: Record<string, unknown>;
  probed_at?: number;
}

export interface DeviceApiSpec {
  type_name: string;
  methods: string[];
  spec_json: Record<string, unknown>;
  spec_markdown: string;
  generated_by: string;
  updated_at: number;
}

export interface DeviceApiSpecUpsertInput {
  type_name: string;
  methods: string[];
  spec_json?: Record<string, unknown> | string;
  spec_markdown?: string;
  generated_by?: string;
}

// ---------------------------------------------------------------------------
// Network Topology, Tasks & Learned Tools (Durable Object SQLite)
// ---------------------------------------------------------------------------

export type EntityKind = "gateway" | "runner" | "turtle" | "peripheral" | "drive";

export interface NetworkEntityInput {
  entity_key?: string;
  name: string;
  kind?: EntityKind | "worker" | "computer";
  type_name?: string;
  peripheral_type?: string;
  type?: string;
  types?: string[];
  methods?: string[];
  probe?: DeviceProbeData | Record<string, unknown> | null;
}

export interface NetworkEntityRow {
  entity_key: string;
  net_id: string;
  kind: string;
  name: string;
  type_name: string;
  methods_json: string;
  probe_json: string | null;
  spec_status: SpecStatus;
  last_seen: number;
}

export interface EnrichedNetworkEntity {
  entity_key: string;
  net_id: string;
  kind: string;
  name: string;
  type_name: string;
  methods: string[];
  probe: Record<string, unknown> | null;
  spec_status: SpecStatus;
  last_seen: number;
  spec: DeviceApiSpec | null;
}

export type TaskStatus = "pending" | "leased" | "completed" | "failed";

export interface TaskQueueRow {
  task_id: string;
  net_id: string;
  target_node: string;
  tool_name: string | null;
  lua_code: string;
  args_json: string;
  priority: number;
  status: TaskStatus;
  lease_ms: number;
  lease_expires_at: number | null;
  created_at: number;
  updated_at: number;
}

export interface DispatchedTask {
  task_id: string;
  net_id: string;
  target_node: string;
  tool_name: string | null;
  lua_code: string;
  args: Record<string, unknown>;
  priority: number;
  lease_expires_at: number;
}

export interface TaskOutputRow {
  task_id: string;
  ok: number;
  stdout: string;
  result_json: string | null;
  error: string | null;
  created_at: number;
  expires_at: number;
}

export interface LearnedToolRow {
  name: string;
  description: string;
  input_schema_json: string;
  lua_template: string;
  builtin: number;
  created_at: number;
  updated_at: number;
}

export type WsRole = "gateway" | "mcp" | "client";

export interface WsAttachment {
  role: WsRole;
  world: string;
  net: string;
  clientId: string;
  subscriptions: string[];
  connectedAt: number;
  label?: string;
  supportsSampling?: boolean;
}

// ---------------------------------------------------------------------------
// WebSocket Wire Protocol (Client <-> Durable Object)
// ---------------------------------------------------------------------------

export type ClientWsMessage =
  | {
      type: "SYNC_TOPOLOGY";
      net_id?: string;
      gateway_id?: string;
      world?: string;
      label?: string;
      entities: NetworkEntityInput[];
      timestamp?: number;
    }
  | {
      type: "PERIPHERAL_ATTACHED";
      net_id?: string;
      gateway_id?: string;
      name: string;
      kind?: EntityKind;
      type_name?: string;
      peripheral_type?: string;
      methods?: string[];
      probe?: DeviceProbeData | Record<string, unknown>;
      timestamp?: number;
    }
  | {
      type: "PERIPHERAL_DETACHED";
      net_id?: string;
      gateway_id?: string;
      name: string;
      timestamp?: number;
    }
  | {
      type: "POLL_QUEUE";
      net_id?: string;
      gateway_id?: string;
      capacity?: number;
      max_batch?: number;
    }
  | {
      type: "TASK_RESULT";
      task_id: string;
      net_id?: string;
      gateway_id?: string;
      ok: boolean;
      stdout?: string;
      result?: unknown;
      error?: string;
      ttl_ms?: number;
      duration_ms?: number;
    }
  | {
      type: "PUB";
      topic: string;
      payload: unknown;
      echo?: boolean;
    }
  | {
      type: "SUB";
      topic?: string;
      topics?: string[];
    }
  | {
      type: "UNSUB";
      topic?: string;
      topics?: string[];
    }
  | {
      type: "KV_SET";
      key: string;
      value: unknown;
      request_id?: string;
    }
  | {
      type: "KV_GET";
      key: string;
      request_id?: string;
    };

export type ServerWsMessage =
  | {
      type: "WAKE";
      net_id: string;
      task_id?: string;
      pending_count: number;
      reason?: string;
    }
  | {
      type: "DISPATCH_BATCH";
      net_id: string;
      tasks: DispatchedTask[];
      has_more: boolean;
    }
  | {
      type: "EVENT";
      topic: string;
      payload: unknown;
      from_net: string;
      sender: string;
      timestamp: number;
    }
  | {
      type: "SUB_ACK";
      topic?: string;
      topics: string[];
    }
  | {
      type: "KV_ACK";
      key: string;
      ok: boolean;
      request_id?: string;
    }
  | {
      type: "KV_VALUE";
      key: string;
      value: unknown;
      found: boolean;
      updated_at: number | null;
      request_id?: string;
    }
  | {
      type: "ACK";
      ref_type: string;
      ok: boolean;
      detail?: string;
      [key: string]: unknown;
    }
  | {
      type: "ERROR";
      message: string;
      code?: string;
    };

// ---------------------------------------------------------------------------
// Static & Dynamic App Store + Schematics
// ---------------------------------------------------------------------------

export interface StaticAppEntry {
  slug: string;
  title: string;
  description: string;
  sha256: string;
  url: string;
  size_bytes: number;
}

export interface StaticStoreResponse {
  apps: StaticAppEntry[];
}

export interface DynamicPackageRecord {
  slug: string;
  title: string;
  description: string;
  version: string;
  r2_key: string;
  sha256: string;
  author: string | null;
  size_bytes: number;
  created_at: number;
  updated_at: number;
}

export interface PublishPackageInput {
  slug: string;
  title: string;
  description?: string;
  version?: string;
  code: string;
  author?: string;
}

export interface SchematicRecord {
  slug: string;
  title: string;
  description: string;
  format: string;
  r2_key: string;
  sha256: string;
  size_bytes: number;
  tags: string[];
  created_at: number;
  updated_at: number;
}

export interface PublishSchematicInput {
  slug: string;
  title: string;
  description?: string;
  format?: string;
  data_base64?: string;
  content?: string;
  tags?: string[];
}

// ---------------------------------------------------------------------------
// Modpack Item & Recipe Spider Graph
// ---------------------------------------------------------------------------

export interface ItemIngestInput {
  item_id: string;
  display_name: string;
  mod_id?: string;
  tags?: string[];
  nbt_hash?: string | null;
  metadata?: Record<string, unknown>;
}

export interface ItemRecord {
  item_id: string;
  display_name: string;
  mod_id: string;
  tags: string[];
  nbt_hash: string | null;
  metadata: Record<string, unknown>;
  updated_at: number;
}

export interface RecipeIngredientInput {
  ingredient_id: string;
  count?: number;
  slot?: string;
}

export interface RecipeIngredientRecord {
  ingredient_id: string;
  count: number;
  slot: string;
}

export interface RecipeIngestInput {
  recipe_id: string;
  recipe_type: string;
  output_item_id: string;
  output_count?: number;
  machine?: string | null;
  metadata?: Record<string, unknown>;
  ingredients: RecipeIngredientInput[];
}

export interface RecipeIngestPayload {
  items?: ItemIngestInput[];
  recipes?: RecipeIngestInput[];
}

export interface RecipeWithIngredients {
  recipe_id: string;
  recipe_type: string;
  output_item_id: string;
  output_count: number;
  machine: string | null;
  metadata: Record<string, unknown>;
  updated_at: number;
  ingredients: RecipeIngredientRecord[];
}

export interface RecipeLookupResponse {
  item_id: string;
  item: ItemRecord | null;
  produced_by: RecipeWithIngredients[];
  used_in: RecipeWithIngredients[];
}

// ---------------------------------------------------------------------------
// MCP JSON-RPC 2.0 Types
// ---------------------------------------------------------------------------

export type JsonRpcId = string | number | null;

export interface JsonRpcRequest {
  jsonrpc: "2.0";
  id?: JsonRpcId;
  method: string;
  params?: Record<string, unknown>;
}

export interface JsonRpcError {
  code: number;
  message: string;
  data?: unknown;
}

export interface JsonRpcResponse {
  jsonrpc: "2.0";
  id: JsonRpcId;
  result?: unknown;
  error?: JsonRpcError;
}

export interface McpToolDefinition {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
}

export interface McpResourceDefinition {
  uri: string;
  name: string;
  description?: string;
  mimeType?: string;
}

export interface McpContentItem {
  type: "text" | "resource";
  text?: string;
  resource?: {
    uri: string;
    mimeType?: string;
    text: string;
  };
}

export interface McpToolCallResult {
  content: McpContentItem[];
  isError?: boolean;
}

export interface McpClientCapabilities {
  sampling?: Record<string, unknown>;
  roots?: Record<string, unknown>;
  experimental?: Record<string, unknown>;
}

export interface McpSamplingMessage {
  role: "user" | "assistant";
  content: {
    type: "text";
    text: string;
  };
}

export interface McpSamplingCreateMessageParams {
  messages: McpSamplingMessage[];
  systemPrompt?: string;
  maxTokens?: number;
  temperature?: number;
}

export interface McpSamplingCreateMessageResult {
  role: "assistant";
  content: {
    type: "text";
    text: string;
  };
  model?: string;
  stopReason?: string;
}
