import { applyD1Migrations, createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env, exports } from "cloudflare:workers";
import { beforeAll, describe, expect, it } from "vitest";
import worker from "../../src/index";
import bootstrapLuaSource from "../../src/lua/bootstrap.lua";
import gatewayLuaSource from "../../src/lua/gateway.lua";
import spiderLuaSource from "../../src/lua/apps/spider.lua";
import stdLuaSource from "../../src/lua/lib/std.lua";
import type {
  DeviceApiSpec,
  ItemIngestInput,
  RecipeIngestInput,
  RecipeLookupResponse,
  StaticStoreResponse,
} from "../../src/protocol";

const AUTH_HEADERS = {
  "Cf-Access-Jwt-Assertion": "test-cf-access-jwt-token",
};

const EMAIL_AUTH_HEADERS = {
  "Cf-Access-Authenticated-User-Email": "operator@example.com",
};

const SHA256_HEX_RE = /^[0-9a-f]{64}$/;

describe("Stage 1: Edge Auth, Static App Store, D1/R2 Store, Recipes & Specs", () => {
  beforeAll(async () => {
    await applyD1Migrations(env.CATALOG_DB, env.TEST_MIGRATIONS);
  });

  describe("Cloudflare Access Edge Security", () => {
    it("blocks unauthenticated requests to protected endpoints while allowing /lua/bootstrap.lua", async () => {
      const protectedPaths = [
        "/mcp",
        "/ws",
        "/api/store/static",
        "/api/specs",
        "/lua/manifest.json",
        "/lua/lib/std.lua",
        "/lua/apps/spider.lua",
      ];

      for (const path of protectedPaths) {
        const res = await exports.default.fetch(`https://cc-mcp.test${path}`);
        expect(res.status, `Expected 401 for ${path}`).toBe(401);
      }

      for (const publicPath of ["/init.lua", "/lua/bootstrap.lua"]) {
        const bootstrapRes = await exports.default.fetch(
          `https://cc-mcp.test${publicPath}`,
        );
        expect(bootstrapRes.status, `Expected 200 for ${publicPath}`).toBe(200);
        expect(bootstrapRes.headers.get("Content-Type")).toContain("text/plain");
        expect(await bootstrapRes.text()).toBe(bootstrapLuaSource);
      }
    });

    it("accepts either Cf-Access-Jwt-Assertion or Cf-Access-Authenticated-User-Email", async () => {
      const jwtRes = await exports.default.fetch(
        "https://cc-mcp.test/api/store/static",
        { headers: AUTH_HEADERS },
      );
      expect(jwtRes.status).toBe(200);

      const emailRes = await exports.default.fetch(
        "https://cc-mcp.test/api/specs",
        { headers: EMAIL_AUTH_HEADERS },
      );
      expect(emailRes.status).toBe(200);

      // Authenticated /mcp routes to CcMeshBridge DO
      const mcpRes = await exports.default.fetch(
        "https://cc-mcp.test/mcp?world=overworld",
        {
          method: "POST",
          headers: { ...AUTH_HEADERS, "Content-Type": "application/json" },
          body: JSON.stringify({
            jsonrpc: "2.0",
            id: 1,
            method: "initialize",
            params: {
              protocolVersion: "2024-11-05",
              capabilities: {},
              clientInfo: { name: "stage1-auth-test", version: "1.0.0" },
            },
          }),
        },
      );
      expect(mcpRes.status).toBe(200);
      const mcpBody = (await mcpRes.json()) as {
        jsonrpc: string;
        result: { serverInfo: { name: string } };
      };
      expect(mcpBody.jsonrpc).toBe("2.0");
      expect(mcpBody.result.serverInfo.name).toBe("cc-mesh-bridge");

      // Authenticated non-upgrade /ws routes to CcMeshBridge DO (returns 426)
      const wsNoUpgradeRes = await exports.default.fetch(
        "https://cc-mcp.test/ws?world=overworld",
        { headers: AUTH_HEADERS },
      );
      expect(wsNoUpgradeRes.status).toBe(426);
    });

    it("bypasses auth only when REQUIRE_CF_ACCESS === 'false'", async () => {
      const ctx = createExecutionContext();
      const res = await worker.fetch(
        new Request("https://cc-mcp.test/api/store/static"),
        { ...env, REQUIRE_CF_ACCESS: "false" },
        ctx,
      );
      await waitOnExecutionContext(ctx);
      expect(res.status).toBe(200);
      const body = (await res.json()) as StaticStoreResponse;
      expect(body.apps.length).toBe(5);
    });
  });

  describe("Static Domain App Store & Lua Script Serving", () => {
    it("lists spider, inv_mon, and net_diag with valid SHA-256 hashes and serves exact Lua source", async () => {
      const storeRes = await exports.default.fetch(
        "https://cc-mcp.test/api/store/static",
        { headers: AUTH_HEADERS },
      );
      expect(storeRes.status).toBe(200);
      const data = (await storeRes.json()) as StaticStoreResponse;

      const slugs = data.apps.map((a) => a.slug).sort();
      expect(slugs).toEqual([
        "inv_mon",
        "mesh_setup",
        "net_diag",
        "spider",
        "subnet_bridge",
      ]);

      for (const app of data.apps) {
        expect(app.sha256).toMatch(SHA256_HEX_RE);
        expect(app.url).toBe(`/lua/apps/${app.slug}.lua`);
        expect(app.title.length).toBeGreaterThan(0);
        expect(app.description.length).toBeGreaterThan(0);
      }

      const spiderRes = await exports.default.fetch(
        "https://cc-mcp.test/lua/apps/spider.lua",
        { headers: AUTH_HEADERS },
      );
      expect(spiderRes.status).toBe(200);
      expect(await spiderRes.text()).toBe(spiderLuaSource);

      const stdRes = await exports.default.fetch(
        "https://cc-mcp.test/lua/lib/std.lua",
        { headers: AUTH_HEADERS },
      );
      expect(stdRes.status).toBe(200);
      expect(await stdRes.text()).toBe(stdLuaSource);

      const gatewayRes = await exports.default.fetch(
        "https://cc-mcp.test/lua/gateway.lua",
        { headers: AUTH_HEADERS },
      );
      expect(gatewayRes.status).toBe(200);
      expect(await gatewayRes.text()).toBe(gatewayLuaSource);

      const manifestRes = await exports.default.fetch(
        "https://cc-mcp.test/lua/manifest.json",
        { headers: AUTH_HEADERS },
      );
      expect(manifestRes.status).toBe(200);
      const manifest = (await manifestRes.json()) as Record<string, string>;
      for (const key of [
        "bootstrap.lua",
        "gateway.lua",
        "runner.lua",
        "pkg.lua",
        "lib/std.lua",
        "lib/crypto.lua",
        "lib/mesh.lua",
        "apps/spider.lua",
        "apps/inv_mon.lua",
        "apps/net_diag.lua",
        "apps/mesh_setup.lua",
        "apps/subnet_bridge.lua",
      ]) {
        expect(manifest[key], `Missing manifest entry ${key}`).toMatch(
          SHA256_HEX_RE,
        );
      }

      const missingRes = await exports.default.fetch(
        "https://cc-mcp.test/lua/apps/nonexistent.lua",
        { headers: AUTH_HEADERS },
      );
      expect(missingRes.status).toBe(404);
    });
  });

  describe("Dynamic D1/R2 Package Store & Schematics", () => {
    it("publishes a package to R2 and D1 and downloads exact source bytes", async () => {
      const luaCode = [
        "-- Quarry controller v1.2.0",
        "local std = require('lib.std')",
        "print('Quarry started: ' .. tostring(std.VERSION))",
      ].join("\n");

      const publishRes = await exports.default.fetch(
        "https://cc-mcp.test/api/store/publish",
        {
          method: "POST",
          headers: {
            ...AUTH_HEADERS,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            slug: "quarry_pro",
            title: "Quarry Pro Controller",
            description: "Automated mining turtle controller",
            version: "1.2.0",
            author: "steve",
            code: luaCode,
          }),
        },
      );
      expect(publishRes.status).toBe(201);
      const published = (await publishRes.json()) as {
        ok: boolean;
        package: { slug: string; sha256: string; r2_key: string; version: string };
      };
      expect(published.ok).toBe(true);
      expect(published.package.slug).toBe("quarry_pro");
      expect(published.package.r2_key).toBe("packages/quarry_pro.lua");
      expect(published.package.sha256).toMatch(SHA256_HEX_RE);

      // Verify R2 actually contains the bytes
      const r2Obj = await env.ARTIFACT_BUCKET.get("packages/quarry_pro.lua");
      expect(r2Obj).not.toBeNull();
      expect(await r2Obj!.text()).toBe(luaCode);

      // Verify package listing via API
      const listRes = await exports.default.fetch(
        "https://cc-mcp.test/api/store/packages",
        { headers: AUTH_HEADERS },
      );
      expect(listRes.status).toBe(200);
      const listBody = (await listRes.json()) as {
        packages: Array<{ slug: string }>;
      };
      expect(listBody.packages.some((p) => p.slug === "quarry_pro")).toBe(true);

      // Verify download endpoint returns exact bytes
      const dlRes = await exports.default.fetch(
        "https://cc-mcp.test/api/store/download/quarry_pro",
        { headers: AUTH_HEADERS },
      );
      expect(dlRes.status).toBe(200);
      expect(dlRes.headers.get("X-Content-Sha256")).toBe(
        published.package.sha256,
      );
      expect(await dlRes.text()).toBe(luaCode);
    });

    it("publishes and downloads binary schematics via R2 and D1", async () => {
      const rawBytes = new Uint8Array([0x1f, 0x8b, 0x08, 0x00, 0xde, 0xad, 0xbe, 0xef]);
      const base64 = btoa(String.fromCharCode(...rawBytes));

      const pubRes = await exports.default.fetch(
        "https://cc-mcp.test/api/store/schematics/publish",
        {
          method: "POST",
          headers: {
            ...AUTH_HEADERS,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            slug: "create_steam_boiler",
            title: "Level 9 Steam Boiler",
            description: "Compact Create boiler schematic",
            format: "nbt",
            tags: ["create", "power"],
            data_base64: base64,
          }),
        },
      );
      expect(pubRes.status).toBe(201);
      const pubJson = (await pubRes.json()) as {
        ok: boolean;
        schematic: { slug: string; sha256: string; size_bytes: number; tags: string[] };
      };
      expect(pubJson.ok).toBe(true);
      expect(pubJson.schematic.size_bytes).toBe(rawBytes.byteLength);
      expect(pubJson.schematic.tags).toEqual(["create", "power"]);

      const listRes = await exports.default.fetch(
        "https://cc-mcp.test/api/store/schematics",
        { headers: AUTH_HEADERS },
      );
      expect(listRes.status).toBe(200);
      const listJson = (await listRes.json()) as {
        schematics: Array<{ slug: string }>;
      };
      expect(
        listJson.schematics.some((s) => s.slug === "create_steam_boiler"),
      ).toBe(true);

      const dlRes = await exports.default.fetch(
        "https://cc-mcp.test/api/store/schematics/download/create_steam_boiler",
        { headers: AUTH_HEADERS },
      );
      expect(dlRes.status).toBe(200);
      const downloaded = new Uint8Array(await dlRes.arrayBuffer());
      expect(Array.from(downloaded)).toEqual(Array.from(rawBytes));
    });
  });

  describe("Device API Specs (/api/specs)", () => {
    it("persists and retrieves a device API spec by ?type=", async () => {
      const payload = {
        type_name: "mekanism:induction_port",
        methods: [
          "getEnergy",
          "getMaxEnergy",
          "getLastInput",
          "getLastOutput",
          "getEnergyFilledPercentage",
        ],
        spec_json: {
          summary: "Mekanism Induction Matrix energy telemetry port",
          readonly_methods: [
            "getEnergy",
            "getMaxEnergy",
            "getLastInput",
            "getLastOutput",
            "getEnergyFilledPercentage",
          ],
        },
        spec_markdown:
          "# mekanism:induction_port\n\nProvides FE/Joule telemetry for a Mekanism Induction Matrix.",
        generated_by: "mcp-sampling:claude",
      };

      const postRes = await exports.default.fetch("https://cc-mcp.test/api/specs", {
        method: "POST",
        headers: {
          ...AUTH_HEADERS,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(payload),
      });
      expect(postRes.status).toBe(200);
      const postBody = (await postRes.json()) as { ok: boolean; spec: DeviceApiSpec };
      expect(postBody.ok).toBe(true);
      expect(postBody.spec.type_name).toBe("mekanism:induction_port");

      const getRes = await exports.default.fetch(
        "https://cc-mcp.test/api/specs?type=mekanism:induction_port",
        { headers: AUTH_HEADERS },
      );
      expect(getRes.status).toBe(200);
      const spec = (await getRes.json()) as DeviceApiSpec;
      expect(spec.type_name).toBe("mekanism:induction_port");
      expect(spec.methods).toEqual(payload.methods);
      expect(spec.spec_json).toEqual(payload.spec_json);
      expect(spec.spec_markdown).toBe(payload.spec_markdown);
      expect(spec.generated_by).toBe("mcp-sampling:claude");

      const allRes = await exports.default.fetch("https://cc-mcp.test/api/specs", {
        headers: AUTH_HEADERS,
      });
      expect(allRes.status).toBe(200);
      const allJson = (await allRes.json()) as { specs: DeviceApiSpec[] };
      expect(
        allJson.specs.some((s) => s.type_name === "mekanism:induction_port"),
      ).toBe(true);

      const missingRes = await exports.default.fetch(
        "https://cc-mcp.test/api/specs?type=nonexistent:device",
        { headers: AUTH_HEADERS },
      );
      expect(missingRes.status).toBe(404);
    });
  });

  describe("Recipe & Item Spider (/api/recipes/ingest & /api/recipes/lookup)", () => {
    it("deduplicates 20 items and 5 recipes on repeat POSTs and returns accurate bidirectional graphs", async () => {
      const items: ItemIngestInput[] = [
        { item_id: "minecraft:iron_ore", display_name: "Iron Ore", mod_id: "minecraft", tags: ["forge:ores/iron"] },
        { item_id: "minecraft:iron_ingot", display_name: "Iron Ingot", mod_id: "minecraft", tags: ["forge:ingots/iron"] },
        { item_id: "minecraft:coal", display_name: "Coal", mod_id: "minecraft", tags: ["minecraft:coals"] },
        { item_id: "minecraft:redstone", display_name: "Redstone Dust", mod_id: "minecraft", tags: ["forge:dusts/redstone"] },
        { item_id: "minecraft:gold_ingot", display_name: "Gold Ingot", mod_id: "minecraft", tags: ["forge:ingots/gold"] },
        { item_id: "minecraft:diamond", display_name: "Diamond", mod_id: "minecraft", tags: ["forge:gems/diamond"] },
        { item_id: "minecraft:copper_ingot", display_name: "Copper Ingot", mod_id: "minecraft", tags: ["forge:ingots/copper"] },
        { item_id: "minecraft:glass", display_name: "Glass", mod_id: "minecraft", tags: ["forge:glass"] },
        { item_id: "mekanism:ingot_osmium", display_name: "Osmium Ingot", mod_id: "mekanism", tags: ["forge:ingots/osmium"] },
        { item_id: "mekanism:ingot_steel", display_name: "Steel Ingot", mod_id: "mekanism", tags: ["forge:ingots/steel"] },
        { item_id: "mekanism:alloy_infused", display_name: "Infused Alloy", mod_id: "mekanism", tags: ["mekanism:alloys/infused"] },
        { item_id: "mekanism:alloy_reinforced", display_name: "Reinforced Alloy", mod_id: "mekanism", tags: ["mekanism:alloys/reinforced"] },
        { item_id: "mekanism:basic_control_circuit", display_name: "Basic Control Circuit", mod_id: "mekanism" },
        { item_id: "mekanism:advanced_control_circuit", display_name: "Advanced Control Circuit", mod_id: "mekanism" },
        { item_id: "mekanism:steel_casing", display_name: "Steel Casing", mod_id: "mekanism" },
        { item_id: "mekanism:metallurgic_infuser", display_name: "Metallurgic Infuser", mod_id: "mekanism" },
        { item_id: "mekanism:enrichment_chamber", display_name: "Enrichment Chamber", mod_id: "mekanism" },
        { item_id: "ae2:certus_quartz_crystal", display_name: "Certus Quartz Crystal", mod_id: "ae2" },
        { item_id: "ae2:fluix_crystal", display_name: "Fluix Crystal", mod_id: "ae2" },
        { item_id: "ae2:me_controller", display_name: "ME Controller", mod_id: "ae2" },
      ];

      const recipes: RecipeIngestInput[] = [
        {
          recipe_id: "recipe:smelt_iron",
          recipe_type: "smelting",
          output_item_id: "minecraft:iron_ingot",
          output_count: 1,
          machine: "minecraft:furnace",
          ingredients: [
            { ingredient_id: "minecraft:iron_ore", count: 1, slot: "input" },
          ],
        },
        {
          recipe_id: "recipe:mek_steel",
          recipe_type: "metallurgic_infusing",
          output_item_id: "mekanism:ingot_steel",
          output_count: 1,
          machine: "mekanism:metallurgic_infuser",
          ingredients: [
            { ingredient_id: "minecraft:iron_ingot", count: 1, slot: "main" },
            { ingredient_id: "minecraft:coal", count: 2, slot: "infuse" },
          ],
        },
        {
          recipe_id: "recipe:mek_infused_alloy",
          recipe_type: "metallurgic_infusing",
          output_item_id: "mekanism:alloy_infused",
          output_count: 1,
          machine: "mekanism:metallurgic_infuser",
          ingredients: [
            { ingredient_id: "minecraft:iron_ingot", count: 1, slot: "main" },
            { ingredient_id: "minecraft:redstone", count: 1, slot: "infuse" },
          ],
        },
        {
          recipe_id: "recipe:mek_steel_casing",
          recipe_type: "crafting_shaped",
          output_item_id: "mekanism:steel_casing",
          output_count: 1,
          machine: "minecraft:crafting_table",
          ingredients: [
            { ingredient_id: "mekanism:ingot_steel", count: 4, slot: "corners" },
            { ingredient_id: "minecraft:glass", count: 4, slot: "edges" },
            { ingredient_id: "mekanism:ingot_osmium", count: 1, slot: "center" },
          ],
        },
        {
          recipe_id: "recipe:mek_enrichment_chamber",
          recipe_type: "crafting_shaped",
          output_item_id: "mekanism:enrichment_chamber",
          output_count: 1,
          machine: "minecraft:crafting_table",
          ingredients: [
            { ingredient_id: "mekanism:steel_casing", count: 1, slot: "center" },
            { ingredient_id: "mekanism:basic_control_circuit", count: 2, slot: "sides" },
            { ingredient_id: "minecraft:iron_ingot", count: 4, slot: "corners" },
            { ingredient_id: "minecraft:redstone", count: 2, slot: "top_bottom" },
          ],
        },
      ];

      expect(items.length).toBe(20);
      expect(recipes.length).toBe(5);
      const expectedIngredientRows = recipes.reduce(
        (sum, r) => sum + r.ingredients.length,
        0,
      ); // 1 + 2 + 2 + 3 + 4 = 12

      const postIngest = async () => {
        const res = await exports.default.fetch(
          "https://cc-mcp.test/api/recipes/ingest",
          {
            method: "POST",
            headers: {
              ...AUTH_HEADERS,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({ items, recipes }),
          },
        );
        expect(res.status).toBe(200);
        return (await res.json()) as {
          ok: boolean;
          items_upserted: number;
          recipes_upserted: number;
        };
      };

      // First ingest
      const first = await postIngest();
      expect(first).toEqual({
        ok: true,
        items_upserted: 20,
        recipes_upserted: 5,
      });

      // Second & third identical ingests — must deduplicate cleanly
      const second = await postIngest();
      expect(second).toEqual({
        ok: true,
        items_upserted: 20,
        recipes_upserted: 5,
      });
      await postIngest();

      const itemCount = await env.CATALOG_DB.prepare(
        "SELECT COUNT(*) AS cnt FROM items",
      ).first<{ cnt: number }>();
      const recipeCount = await env.CATALOG_DB.prepare(
        "SELECT COUNT(*) AS cnt FROM recipes",
      ).first<{ cnt: number }>();
      const ingCount = await env.CATALOG_DB.prepare(
        "SELECT COUNT(*) AS cnt FROM recipe_ingredients",
      ).first<{ cnt: number }>();

      expect(itemCount?.cnt).toBe(20);
      expect(recipeCount?.cnt).toBe(5);
      expect(ingCount?.cnt).toBe(expectedIngredientRows);

      // Bidirectional graph lookup on intermediate item: minecraft:iron_ingot
      const ironLookupRes = await exports.default.fetch(
        "https://cc-mcp.test/api/recipes/lookup?item=minecraft:iron_ingot",
        { headers: AUTH_HEADERS },
      );
      expect(ironLookupRes.status).toBe(200);
      const ironGraph = (await ironLookupRes.json()) as RecipeLookupResponse;

      expect(ironGraph.item?.item_id).toBe("minecraft:iron_ingot");
      expect(ironGraph.item?.display_name).toBe("Iron Ingot");
      expect(ironGraph.produced_by.map((r) => r.recipe_id)).toEqual([
        "recipe:smelt_iron",
      ]);
      expect(ironGraph.produced_by[0].ingredients).toEqual([
        { ingredient_id: "minecraft:iron_ore", count: 1, slot: "input" },
      ]);
      expect(ironGraph.used_in.map((r) => r.recipe_id)).toEqual([
        "recipe:mek_enrichment_chamber",
        "recipe:mek_infused_alloy",
        "recipe:mek_steel",
      ]);

      // Bidirectional lookup on steel_casing (produced_by steel_casing, used_in enrichment_chamber)
      const casingRes = await exports.default.fetch(
        "https://cc-mcp.test/api/recipes/lookup?item=mekanism:steel_casing",
        { headers: AUTH_HEADERS },
      );
      expect(casingRes.status).toBe(200);
      const casingGraph = (await casingRes.json()) as RecipeLookupResponse;
      expect(casingGraph.produced_by.map((r) => r.recipe_id)).toEqual([
        "recipe:mek_steel_casing",
      ]);
      expect(casingGraph.produced_by[0].ingredients.length).toBe(3);
      expect(casingGraph.used_in.map((r) => r.recipe_id)).toEqual([
        "recipe:mek_enrichment_chamber",
      ]);

      // Leaf input item: minecraft:iron_ore
      const oreRes = await exports.default.fetch(
        "https://cc-mcp.test/api/recipes/lookup?item=minecraft:iron_ore",
        { headers: AUTH_HEADERS },
      );
      const oreGraph = (await oreRes.json()) as RecipeLookupResponse;
      expect(oreGraph.produced_by).toEqual([]);
      expect(oreGraph.used_in.map((r) => r.recipe_id)).toEqual([
        "recipe:smelt_iron",
      ]);
    });
  });
});
