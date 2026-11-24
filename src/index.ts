import { DurableObject } from "cloudflare:workers";

export class CcMcpObject extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.ctx.blockConcurrencyWhile(async () => {
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS meta (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
      `);
    });
  }

  async ping(): Promise<{ ok: boolean; hits: number }> {
    const row = this.ctx.storage.sql
      .exec<{ value: string }>("SELECT value FROM meta WHERE key = 'hits'")
      .toArray()[0];
    const hits = (row ? Number(row.value) : 0) + 1;
    this.ctx.storage.sql.exec(
      "INSERT INTO meta (key, value) VALUES ('hits', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
      String(hits),
    );
    return { ok: true, hits };
  }
}

export default {
  async fetch(request, env, _ctx): Promise<Response> {
    const url = new URL(request.url);
    const name = url.searchParams.get("id") ?? "default";
    const stub = env.CC_MCP_DO.get(env.CC_MCP_DO.idFromName(name));
    const status = await stub.ping();
    return Response.json({
      service: "cc-mcp",
      object: name,
      ...status,
    });
  },
} satisfies ExportedHandler<Env>;
