import { CcMeshBridge } from "./bridge_do";
import type {
  DeviceApiSpec,
  DeviceApiSpecUpsertInput,
  DynamicPackageRecord,
  Env,
  ItemRecord,
  PublishPackageInput,
  PublishSchematicInput,
  RecipeIngestPayload,
  RecipeIngredientRecord,
  RecipeLookupResponse,
  RecipeWithIngredients,
  SchematicRecord,
} from "./protocol";
import {
  getCoreLuaFile,
  getCoreLuaManifest,
  getStaticApp,
  getStaticAppCatalog,
  sha256Hex,
} from "./static_store";

export { CcMeshBridge };

const SLUG_RE = /^[a-zA-Z0-9._-]+$/;
const textEncoder = new TextEncoder();

interface RawPackageRow {
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

interface RawSchematicRow {
  slug: string;
  title: string;
  description: string;
  format: string;
  r2_key: string;
  sha256: string;
  size_bytes: number;
  tags_json: string;
  created_at: number;
  updated_at: number;
}

interface RawItemRow {
  item_id: string;
  display_name: string;
  mod_id: string;
  tags_json: string;
  nbt_hash: string | null;
  metadata_json: string;
  updated_at: number;
}

interface RawRecipeRow {
  recipe_id: string;
  recipe_type: string;
  output_item_id: string;
  output_count: number;
  machine: string | null;
  metadata_json: string;
  updated_at: number;
}

interface RawIngredientRow {
  recipe_id: string;
  ingredient_id: string;
  count: number;
  slot: string;
}

interface RawDeviceApiSpecRow {
  type_name: string;
  methods_json: string;
  spec_json: string;
  spec_markdown: string;
  generated_by: string;
  updated_at: number;
}

function safeJsonParse<T>(raw: string, fallback: T): T {
  try {
    return JSON.parse(raw) as T;
  } catch {
    return fallback;
  }
}

function decodeBase64(b64: string): Uint8Array {
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

function luaResponse(source: string, extraHeaders?: Record<string, string>): Response {
  return new Response(source, {
    status: 200,
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "no-store",
      ...extraHeaders,
    },
  });
}

function isAuthenticated(request: Request, env: Env): boolean {
  if (env.REQUIRE_CF_ACCESS === "false") {
    return true;
  }
  const jwt = request.headers.get("Cf-Access-Jwt-Assertion")?.trim();
  const email = request.headers.get("Cf-Access-Authenticated-User-Email")?.trim();
  return Boolean(jwt || email);
}

function mapSchematicRow(row: RawSchematicRow): SchematicRecord {
  return {
    slug: row.slug,
    title: row.title,
    description: row.description,
    format: row.format,
    r2_key: row.r2_key,
    sha256: row.sha256,
    size_bytes: row.size_bytes,
    tags: safeJsonParse<string[]>(row.tags_json, []),
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
}

function mapItemRow(row: RawItemRow): ItemRecord {
  return {
    item_id: row.item_id,
    display_name: row.display_name,
    mod_id: row.mod_id,
    tags: safeJsonParse<string[]>(row.tags_json, []),
    nbt_hash: row.nbt_hash,
    metadata: safeJsonParse<Record<string, unknown>>(row.metadata_json, {}),
    updated_at: row.updated_at,
  };
}

function mapSpecRow(row: RawDeviceApiSpecRow): DeviceApiSpec {
  return {
    type_name: row.type_name,
    methods: safeJsonParse<string[]>(row.methods_json, []),
    spec_json: safeJsonParse<Record<string, unknown>>(row.spec_json, {}),
    spec_markdown: row.spec_markdown,
    generated_by: row.generated_by,
    updated_at: row.updated_at,
  };
}

async function handleLuaRoutes(pathname: string): Promise<Response> {
  if (pathname === "/lua/manifest.json") {
    const manifest = await getCoreLuaManifest();
    return Response.json(manifest);
  }

  if (pathname === "/lua/lib/std.lua") {
    const source = getCoreLuaFile("lib/std.lua");
    if (source === null) {
      return Response.json({ error: "Not found" }, { status: 404 });
    }
    return luaResponse(source);
  }

  if (pathname.startsWith("/lua/apps/")) {
    const rest = pathname.slice("/lua/apps/".length);
    if (!rest || rest.includes("/")) {
      return Response.json({ error: "Not found" }, { status: 404 });
    }
    const app = await getStaticApp(rest);
    if (!app) {
      return Response.json({ error: "Static app not found" }, { status: 404 });
    }
    return luaResponse(app.source, {
      ETag: `"${app.sha256}"`,
      "X-Content-Sha256": app.sha256,
    });
  }

  const file = pathname.slice("/lua/".length);
  if (!file || file.includes("..")) {
    return Response.json({ error: "Not found" }, { status: 404 });
  }
  const source = getCoreLuaFile(file);
  if (source === null) {
    return Response.json({ error: "Lua file not found" }, { status: 404 });
  }
  return luaResponse(source);
}

async function handlePublishPackage(
  request: Request,
  env: Env,
): Promise<Response> {
  let body: PublishPackageInput;
  try {
    body = (await request.json()) as PublishPackageInput;
  } catch {
    return Response.json({ error: "Invalid JSON body" }, { status: 400 });
  }

  const slug = typeof body.slug === "string" ? body.slug.trim() : "";
  const title = typeof body.title === "string" ? body.title.trim() : "";
  const code = typeof body.code === "string" ? body.code : null;

  if (!slug || !SLUG_RE.test(slug)) {
    return Response.json(
      { error: "Invalid or missing slug (allowed: a-z, A-Z, 0-9, ., _, -)" },
      { status: 400 },
    );
  }
  if (!title) {
    return Response.json({ error: "Missing title" }, { status: 400 });
  }
  if (code === null) {
    return Response.json({ error: "Missing code string" }, { status: 400 });
  }

  const description = typeof body.description === "string" ? body.description : "";
  const version =
    typeof body.version === "string" && body.version.trim()
      ? body.version.trim()
      : "1.0.0";
  const author =
    typeof body.author === "string" && body.author.trim()
      ? body.author.trim()
      : null;

  const bytes = textEncoder.encode(code);
  const sha256 = await sha256Hex(bytes);
  const r2Key = `packages/${slug}.lua`;
  const now = Date.now();

  await env.ARTIFACT_BUCKET.put(r2Key, bytes, {
    httpMetadata: { contentType: "text/plain; charset=utf-8" },
    customMetadata: { slug, version, sha256 },
  });

  await env.CATALOG_DB.prepare(
    `INSERT INTO packages (slug, title, description, version, r2_key, sha256, author, size_bytes, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(slug) DO UPDATE SET
       title = excluded.title,
       description = excluded.description,
       version = excluded.version,
       r2_key = excluded.r2_key,
       sha256 = excluded.sha256,
       author = excluded.author,
       size_bytes = excluded.size_bytes,
       updated_at = excluded.updated_at`,
  )
    .bind(
      slug,
      title,
      description,
      version,
      r2Key,
      sha256,
      author,
      bytes.byteLength,
      now,
      now,
    )
    .run();

  const stored = await env.CATALOG_DB.prepare(
    "SELECT * FROM packages WHERE slug = ?",
  )
    .bind(slug)
    .first<RawPackageRow>();

  return Response.json(
    {
      ok: true,
      package: stored satisfies DynamicPackageRecord | null,
    },
    { status: 201 },
  );
}

async function handleDownloadPackage(
  slug: string,
  env: Env,
): Promise<Response> {
  if (!slug || !SLUG_RE.test(slug)) {
    return Response.json({ error: "Invalid slug" }, { status: 400 });
  }

  const row = await env.CATALOG_DB.prepare(
    "SELECT * FROM packages WHERE slug = ?",
  )
    .bind(slug)
    .first<RawPackageRow>();

  if (!row) {
    return Response.json({ error: "Package not found" }, { status: 404 });
  }

  const obj = await env.ARTIFACT_BUCKET.get(row.r2_key);
  if (!obj) {
    return Response.json(
      { error: "Package artifact missing in R2" },
      { status: 404 },
    );
  }

  const body = await obj.arrayBuffer();
  return new Response(body, {
    status: 200,
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
      "X-Content-Sha256": row.sha256,
      "Content-Disposition": `inline; filename="${row.slug}.lua"`,
    },
  });
}

async function handlePublishSchematic(
  request: Request,
  url: URL,
  env: Env,
): Promise<Response> {
  const contentType = request.headers.get("Content-Type") ?? "";
  let slug = "";
  let title = "";
  let description = "";
  let format = "nbt";
  let tags: string[] = [];
  let bytes: Uint8Array;

  if (contentType.includes("application/json")) {
    let body: PublishSchematicInput;
    try {
      body = (await request.json()) as PublishSchematicInput;
    } catch {
      return Response.json({ error: "Invalid JSON body" }, { status: 400 });
    }
    slug = typeof body.slug === "string" ? body.slug.trim() : "";
    title = typeof body.title === "string" ? body.title.trim() : "";
    description = typeof body.description === "string" ? body.description : "";
    tags = Array.isArray(body.tags)
      ? body.tags.filter((t): t is string => typeof t === "string")
      : [];

    if (typeof body.data_base64 === "string") {
      try {
        bytes = decodeBase64(body.data_base64);
      } catch {
        return Response.json({ error: "Invalid base64 data" }, { status: 400 });
      }
      format =
        typeof body.format === "string" && body.format.trim()
          ? body.format.trim()
          : "nbt";
    } else if (typeof body.content === "string") {
      bytes = textEncoder.encode(body.content);
      format =
        typeof body.format === "string" && body.format.trim()
          ? body.format.trim()
          : "lua";
    } else {
      return Response.json(
        { error: "Provide either data_base64 or content" },
        { status: 400 },
      );
    }
  } else {
    slug = url.searchParams.get("slug")?.trim() ?? "";
    title = url.searchParams.get("title")?.trim() ?? slug;
    description = url.searchParams.get("description") ?? "";
    format = url.searchParams.get("format")?.trim() || "nbt";
    const tagsParam = url.searchParams.get("tags");
    tags = tagsParam
      ? tagsParam
          .split(",")
          .map((t) => t.trim())
          .filter(Boolean)
      : [];
    bytes = new Uint8Array(await request.arrayBuffer());
  }

  if (!slug || !SLUG_RE.test(slug)) {
    return Response.json({ error: "Invalid or missing slug" }, { status: 400 });
  }
  if (!title) {
    return Response.json({ error: "Missing title" }, { status: 400 });
  }

  const sha256 = await sha256Hex(bytes);
  const r2Key = `schematics/${slug}`;
  const now = Date.now();

  await env.ARTIFACT_BUCKET.put(r2Key, bytes, {
    httpMetadata: {
      contentType:
        format === "lua"
          ? "text/plain; charset=utf-8"
          : "application/octet-stream",
    },
    customMetadata: { slug, format, sha256 },
  });

  await env.CATALOG_DB.prepare(
    `INSERT INTO schematics (slug, title, description, format, r2_key, sha256, size_bytes, tags_json, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(slug) DO UPDATE SET
       title = excluded.title,
       description = excluded.description,
       format = excluded.format,
       r2_key = excluded.r2_key,
       sha256 = excluded.sha256,
       size_bytes = excluded.size_bytes,
       tags_json = excluded.tags_json,
       updated_at = excluded.updated_at`,
  )
    .bind(
      slug,
      title,
      description,
      format,
      r2Key,
      sha256,
      bytes.byteLength,
      JSON.stringify(tags),
      now,
      now,
    )
    .run();

  const stored = await env.CATALOG_DB.prepare(
    "SELECT * FROM schematics WHERE slug = ?",
  )
    .bind(slug)
    .first<RawSchematicRow>();

  return Response.json(
    {
      ok: true,
      schematic: stored ? mapSchematicRow(stored) : null,
    },
    { status: 201 },
  );
}

async function handleDownloadSchematic(
  slug: string,
  env: Env,
): Promise<Response> {
  if (!slug || !SLUG_RE.test(slug)) {
    return Response.json({ error: "Invalid slug" }, { status: 400 });
  }

  const row = await env.CATALOG_DB.prepare(
    "SELECT * FROM schematics WHERE slug = ?",
  )
    .bind(slug)
    .first<RawSchematicRow>();

  if (!row) {
    return Response.json({ error: "Schematic not found" }, { status: 404 });
  }

  const obj = await env.ARTIFACT_BUCKET.get(row.r2_key);
  if (!obj) {
    return Response.json(
      { error: "Schematic artifact missing in R2" },
      { status: 404 },
    );
  }

  const body = await obj.arrayBuffer();
  return new Response(body, {
    status: 200,
    headers: {
      "Content-Type":
        row.format === "lua"
          ? "text/plain; charset=utf-8"
          : "application/octet-stream",
      "X-Content-Sha256": row.sha256,
      "X-Schematic-Format": row.format,
    },
  });
}

async function handleRecipeIngest(
  request: Request,
  env: Env,
): Promise<Response> {
  let payload: RecipeIngestPayload;
  try {
    payload = (await request.json()) as RecipeIngestPayload;
  } catch {
    return Response.json({ error: "Invalid JSON body" }, { status: 400 });
  }

  const items = Array.isArray(payload.items) ? payload.items : [];
  const recipes = Array.isArray(payload.recipes) ? payload.recipes : [];
  const now = Date.now();
  const statements: D1PreparedStatement[] = [];

  let itemsUpserted = 0;
  const seenItems = new Set<string>();
  for (const item of items) {
    if (!item || typeof item.item_id !== "string" || !item.item_id.trim()) {
      continue;
    }
    const itemId = item.item_id.trim();
    if (seenItems.has(itemId)) {
      continue;
    }
    seenItems.add(itemId);

    const displayName =
      typeof item.display_name === "string" && item.display_name.trim()
        ? item.display_name.trim()
        : itemId;
    const modId =
      typeof item.mod_id === "string" && item.mod_id.trim()
        ? item.mod_id.trim()
        : itemId.includes(":")
          ? itemId.split(":")[0]
          : "minecraft";
    const tagsJson = JSON.stringify(Array.isArray(item.tags) ? item.tags : []);
    const nbtHash = typeof item.nbt_hash === "string" ? item.nbt_hash : null;
    const metadataJson = JSON.stringify(
      item.metadata && typeof item.metadata === "object" ? item.metadata : {},
    );

    statements.push(
      env.CATALOG_DB.prepare(
        `INSERT INTO items (item_id, display_name, mod_id, tags_json, nbt_hash, metadata_json, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(item_id) DO UPDATE SET
           display_name = excluded.display_name,
           mod_id = excluded.mod_id,
           tags_json = excluded.tags_json,
           nbt_hash = excluded.nbt_hash,
           metadata_json = excluded.metadata_json,
           updated_at = excluded.updated_at`,
      ).bind(itemId, displayName, modId, tagsJson, nbtHash, metadataJson, now),
    );
    itemsUpserted++;
  }

  let recipesUpserted = 0;
  const seenRecipes = new Set<string>();
  for (const recipe of recipes) {
    if (
      !recipe ||
      typeof recipe.recipe_id !== "string" ||
      !recipe.recipe_id.trim() ||
      typeof recipe.output_item_id !== "string" ||
      !recipe.output_item_id.trim()
    ) {
      continue;
    }
    const recipeId = recipe.recipe_id.trim();
    if (seenRecipes.has(recipeId)) {
      continue;
    }
    seenRecipes.add(recipeId);

    const recipeType =
      typeof recipe.recipe_type === "string" && recipe.recipe_type.trim()
        ? recipe.recipe_type.trim()
        : "crafting";
    const outputItemId = recipe.output_item_id.trim();
    const outputCount =
      typeof recipe.output_count === "number" && recipe.output_count > 0
        ? Math.floor(recipe.output_count)
        : 1;
    const machine =
      typeof recipe.machine === "string" && recipe.machine.trim()
        ? recipe.machine.trim()
        : null;
    const metadataJson = JSON.stringify(
      recipe.metadata && typeof recipe.metadata === "object"
        ? recipe.metadata
        : {},
    );

    statements.push(
      env.CATALOG_DB.prepare(
        `INSERT INTO recipes (recipe_id, recipe_type, output_item_id, output_count, machine, metadata_json, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(recipe_id) DO UPDATE SET
           recipe_type = excluded.recipe_type,
           output_item_id = excluded.output_item_id,
           output_count = excluded.output_count,
           machine = excluded.machine,
           metadata_json = excluded.metadata_json,
           updated_at = excluded.updated_at`,
      ).bind(
        recipeId,
        recipeType,
        outputItemId,
        outputCount,
        machine,
        metadataJson,
        now,
      ),
    );

    // Replace ingredients atomically inside the same D1 batch transaction
    statements.push(
      env.CATALOG_DB.prepare(
        "DELETE FROM recipe_ingredients WHERE recipe_id = ?",
      ).bind(recipeId),
    );

    const ingredients = Array.isArray(recipe.ingredients)
      ? recipe.ingredients
      : [];
    for (const ing of ingredients) {
      if (
        !ing ||
        typeof ing.ingredient_id !== "string" ||
        !ing.ingredient_id.trim()
      ) {
        continue;
      }
      const ingredientId = ing.ingredient_id.trim();
      const count =
        typeof ing.count === "number" && ing.count > 0
          ? Math.floor(ing.count)
          : 1;
      const slot = typeof ing.slot === "string" ? ing.slot : "";

      statements.push(
        env.CATALOG_DB.prepare(
          `INSERT INTO recipe_ingredients (recipe_id, ingredient_id, count, slot)
           VALUES (?, ?, ?, ?)
           ON CONFLICT(recipe_id, ingredient_id, slot) DO UPDATE SET
             count = excluded.count`,
        ).bind(recipeId, ingredientId, count, slot),
      );
    }

    recipesUpserted++;
  }

  if (statements.length > 0) {
    await env.CATALOG_DB.batch(statements);
  }

  return Response.json({
    ok: true,
    items_upserted: itemsUpserted,
    recipes_upserted: recipesUpserted,
  });
}

async function hydrateRecipesWithIngredients(
  rows: RawRecipeRow[],
  env: Env,
): Promise<RecipeWithIngredients[]> {
  if (rows.length === 0) {
    return [];
  }

  const recipeIds = rows.map((r) => r.recipe_id);
  const placeholders = recipeIds.map(() => "?").join(", ");
  const ingResult = await env.CATALOG_DB.prepare(
    `SELECT recipe_id, ingredient_id, count, slot
     FROM recipe_ingredients
     WHERE recipe_id IN (${placeholders})
     ORDER BY slot ASC, ingredient_id ASC`,
  )
    .bind(...recipeIds)
    .all<RawIngredientRow>();

  const ingredientsByRecipe = new Map<string, RecipeIngredientRecord[]>();
  for (const row of ingResult.results) {
    let list = ingredientsByRecipe.get(row.recipe_id);
    if (!list) {
      list = [];
      ingredientsByRecipe.set(row.recipe_id, list);
    }
    list.push({
      ingredient_id: row.ingredient_id,
      count: row.count,
      slot: row.slot,
    });
  }

  return rows.map((r) => ({
    recipe_id: r.recipe_id,
    recipe_type: r.recipe_type,
    output_item_id: r.output_item_id,
    output_count: r.output_count,
    machine: r.machine,
    metadata: safeJsonParse<Record<string, unknown>>(r.metadata_json, {}),
    updated_at: r.updated_at,
    ingredients: ingredientsByRecipe.get(r.recipe_id) ?? [],
  }));
}

async function handleRecipeLookup(url: URL, env: Env): Promise<Response> {
  const itemId = url.searchParams.get("item")?.trim() ?? "";
  if (!itemId) {
    return Response.json(
      { error: "Missing required query parameter: item" },
      { status: 400 },
    );
  }

  const [itemRow, producedByResult, usedInResult] = await Promise.all([
    env.CATALOG_DB.prepare("SELECT * FROM items WHERE item_id = ?")
      .bind(itemId)
      .first<RawItemRow>(),
    env.CATALOG_DB.prepare(
      "SELECT * FROM recipes WHERE output_item_id = ? ORDER BY recipe_id ASC",
    )
      .bind(itemId)
      .all<RawRecipeRow>(),
    env.CATALOG_DB.prepare(
      `SELECT DISTINCT r.*
       FROM recipes r
       INNER JOIN recipe_ingredients ri ON ri.recipe_id = r.recipe_id
       WHERE ri.ingredient_id = ?
       ORDER BY r.recipe_id ASC`,
    )
      .bind(itemId)
      .all<RawRecipeRow>(),
  ]);

  const [producedBy, usedIn] = await Promise.all([
    hydrateRecipesWithIngredients(producedByResult.results, env),
    hydrateRecipesWithIngredients(usedInResult.results, env),
  ]);

  const response: RecipeLookupResponse = {
    item_id: itemId,
    item: itemRow ? mapItemRow(itemRow) : null,
    produced_by: producedBy,
    used_in: usedIn,
  };

  return Response.json(response);
}

async function handleGetSpecs(url: URL, env: Env): Promise<Response> {
  const typeName = url.searchParams.get("type")?.trim();
  if (typeName) {
    const row = await env.CATALOG_DB.prepare(
      "SELECT * FROM device_api_specs WHERE type_name = ?",
    )
      .bind(typeName)
      .first<RawDeviceApiSpecRow>();

    if (!row) {
      return Response.json(
        { error: "Device API spec not found", type_name: typeName },
        { status: 404 },
      );
    }
    return Response.json(mapSpecRow(row));
  }

  const all = await env.CATALOG_DB.prepare(
    "SELECT * FROM device_api_specs ORDER BY type_name ASC",
  ).all<RawDeviceApiSpecRow>();

  return Response.json({
    specs: all.results.map(mapSpecRow),
  });
}

async function handleUpsertSpec(request: Request, env: Env): Promise<Response> {
  let body: DeviceApiSpecUpsertInput;
  try {
    body = (await request.json()) as DeviceApiSpecUpsertInput;
  } catch {
    return Response.json({ error: "Invalid JSON body" }, { status: 400 });
  }

  const typeName =
    typeof body.type_name === "string" ? body.type_name.trim() : "";
  if (!typeName) {
    return Response.json({ error: "Missing type_name" }, { status: 400 });
  }

  if (!Array.isArray(body.methods)) {
    return Response.json(
      { error: "Missing or invalid methods array" },
      { status: 400 },
    );
  }
  const methods = body.methods.filter((m): m is string => typeof m === "string");

  let specJsonStr = "{}";
  if (typeof body.spec_json === "string") {
    specJsonStr = JSON.stringify(
      safeJsonParse<Record<string, unknown>>(body.spec_json, {
        raw: body.spec_json,
      }),
    );
  } else if (body.spec_json && typeof body.spec_json === "object") {
    specJsonStr = JSON.stringify(body.spec_json);
  }

  const specMarkdown =
    typeof body.spec_markdown === "string" ? body.spec_markdown : "";
  const generatedBy =
    typeof body.generated_by === "string" && body.generated_by.trim()
      ? body.generated_by.trim()
      : "agent";
  const now = Date.now();

  await env.CATALOG_DB.prepare(
    `INSERT INTO device_api_specs (type_name, methods_json, spec_json, spec_markdown, generated_by, updated_at)
     VALUES (?, ?, ?, ?, ?, ?)
     ON CONFLICT(type_name) DO UPDATE SET
       methods_json = excluded.methods_json,
       spec_json = excluded.spec_json,
       spec_markdown = excluded.spec_markdown,
       generated_by = excluded.generated_by,
       updated_at = excluded.updated_at`,
  )
    .bind(
      typeName,
      JSON.stringify(methods),
      specJsonStr,
      specMarkdown,
      generatedBy,
      now,
    )
    .run();

  const stored = await env.CATALOG_DB.prepare(
    "SELECT * FROM device_api_specs WHERE type_name = ?",
  )
    .bind(typeName)
    .first<RawDeviceApiSpecRow>();

  return Response.json({
    ok: true,
    spec: stored ? mapSpecRow(stored) : null,
  });
}

async function handleApiRoutes(
  request: Request,
  url: URL,
  env: Env,
): Promise<Response> {
  const { pathname } = url;
  const method = request.method.toUpperCase();

  // Static Domain App Store
  if (pathname === "/api/store/static" && method === "GET") {
    const apps = await getStaticAppCatalog();
    return Response.json({ apps });
  }

  // Dynamic Package Store
  if (pathname === "/api/store/packages" && method === "GET") {
    const result = await env.CATALOG_DB.prepare(
      "SELECT * FROM packages ORDER BY updated_at DESC",
    ).all<RawPackageRow>();
    return Response.json({ packages: result.results });
  }

  if (pathname === "/api/store/publish" && method === "POST") {
    return handlePublishPackage(request, env);
  }

  if (pathname.startsWith("/api/store/download/") && method === "GET") {
    const slug = decodeURIComponent(
      pathname.slice("/api/store/download/".length),
    );
    return handleDownloadPackage(slug, env);
  }

  // Schematics Registry
  if (pathname === "/api/store/schematics" && method === "GET") {
    const result = await env.CATALOG_DB.prepare(
      "SELECT * FROM schematics ORDER BY updated_at DESC",
    ).all<RawSchematicRow>();
    return Response.json({
      schematics: result.results.map(mapSchematicRow),
    });
  }

  if (
    (pathname === "/api/store/schematics" ||
      pathname === "/api/store/schematics/publish") &&
    method === "POST"
  ) {
    return handlePublishSchematic(request, url, env);
  }

  if (
    pathname.startsWith("/api/store/schematics/download/") &&
    method === "GET"
  ) {
    const slug = decodeURIComponent(
      pathname.slice("/api/store/schematics/download/".length),
    );
    return handleDownloadSchematic(slug, env);
  }

  if (pathname.startsWith("/api/store/schematics/") && method === "GET") {
    const slug = decodeURIComponent(
      pathname.slice("/api/store/schematics/".length),
    );
    if (slug && !slug.includes("/")) {
      return handleDownloadSchematic(slug, env);
    }
  }

  // Recipe & Item Spider
  if (pathname === "/api/recipes/ingest" && method === "POST") {
    return handleRecipeIngest(request, env);
  }

  if (pathname === "/api/recipes/lookup" && method === "GET") {
    return handleRecipeLookup(url, env);
  }

  // Device API Specs
  if (pathname === "/api/specs" && method === "GET") {
    return handleGetSpecs(url, env);
  }

  if (pathname === "/api/specs" && method === "POST") {
    return handleUpsertSpec(request, env);
  }

  return Response.json({ error: "API route not found" }, { status: 404 });
}

export default {
  async fetch(request: Request, env: Env, _ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    const { pathname } = url;

    // 1. Public unauthenticated bootstrap script (always accessible for CC wget)
    if (
      (pathname === "/init.lua" || pathname === "/lua/bootstrap.lua") &&
      request.method === "GET"
    ) {
      const source = getCoreLuaFile("bootstrap.lua");
      if (source === null) {
        return Response.json({ error: "Bootstrap not found" }, { status: 404 });
      }
      return luaResponse(source);
    }

    // 2. Protected routes require Cloudflare Access headers (unless REQUIRE_CF_ACCESS === "false")
    const isProtected =
      pathname.startsWith("/lua/") ||
      pathname.startsWith("/api/") ||
      pathname === "/ws" ||
      pathname === "/mcp";

    if (isProtected && !isAuthenticated(request, env)) {
      return Response.json(
        { error: "Unauthorized: Cloudflare Access authentication required" },
        { status: 401 },
      );
    }

    // 3. Lua scripts & static app store sources
    if (pathname.startsWith("/lua/")) {
      if (request.method !== "GET") {
        return Response.json({ error: "Method not allowed" }, { status: 405 });
      }
      return handleLuaRoutes(pathname);
    }

    // 4. Stateless D1/R2 & Static Store APIs
    if (pathname.startsWith("/api/")) {
      return handleApiRoutes(request, url, env);
    }

    // 5. Durable Object WebSocket & MCP endpoints
    if (pathname === "/ws" || pathname === "/mcp") {
      const world =
        url.searchParams.get("world")?.trim() ||
        request.headers.get("X-CC-World")?.trim() ||
        "default";
      const stub = env.BRIDGE_DO.get(env.BRIDGE_DO.idFromName(world));
      return stub.fetch(request);
    }

    if (pathname === "/") {
      return Response.json({
        service: "cc-mesh-bridge",
        status: "ok",
      });
    }

    return Response.json({ error: "Not found" }, { status: 404 });
  },
} satisfies ExportedHandler<Env>;
