import { DurableObject } from "cloudflare:workers";
import type { Env } from "./protocol";

/**
 * Stage 1 stub for CcMeshBridge Durable Object.
 * Full WebSocket hibernation, SQLite task queue, Pub/Sub, KV, learned_tools,
 * and MCP + Sampling implementation is delivered in Stage 2.
 */
export class CcMeshBridge extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.ctx.setWebSocketAutoResponse(
      new WebSocketRequestResponsePair("ping", "pong"),
    );
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/ws") {
      if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
        return Response.json(
          { error: "Expected WebSocket upgrade" },
          { status: 426 },
        );
      }
      const pair = new WebSocketPair();
      const [client, server] = Object.values(pair);
      this.ctx.acceptWebSocket(server);
      return new Response(null, { status: 101, webSocket: client });
    }

    if (url.pathname === "/mcp") {
      return Response.json({
        jsonrpc: "2.0",
        id: null,
        result: {
          status: "stub",
          message: "CcMeshBridge DO stub active (full MCP in Stage 2)",
        },
      });
    }

    return Response.json({ error: "Not found" }, { status: 404 });
  }

  async webSocketMessage(_ws: WebSocket, _message: string | ArrayBuffer): Promise<void> {
    // Stage 2 implementation
  }

  async webSocketClose(
    _ws: WebSocket,
    _code: number,
    _reason: string,
    _wasClean: boolean,
  ): Promise<void> {
    // Stage 2 implementation
  }

  async alarm(): Promise<void> {
    // Stage 2 implementation
  }
}
