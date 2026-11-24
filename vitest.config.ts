import fs from "node:fs/promises";
import path from "node:path";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

function luaTextPlugin() {
  return {
    name: "cc-mesh-lua-text-loader",
    enforce: "pre" as const,
    async load(id: string) {
      const cleanId = id.split("?")[0];
      if (!cleanId.endsWith(".lua")) {
        return null;
      }
      const source = await fs.readFile(cleanId, "utf8");
      return `export default ${JSON.stringify(source)};`;
    },
  };
}

export default defineConfig(async () => {
  const migrationsPath = path.join(import.meta.dirname, "migrations");
  const migrations = await readD1Migrations(migrationsPath);

  return {
    plugins: [
      luaTextPlugin(),
      cloudflareTest({
        wrangler: { configPath: "./wrangler.jsonc" },
        miniflare: {
          compatibilityDate: "2026-08-22",
          bindings: {
            TEST_MIGRATIONS: migrations,
          },
        },
      }),
    ],
  };
});
