import bootstrapLua from "./lua/bootstrap.lua";
import gatewayLua from "./lua/gateway.lua";
import runnerLua from "./lua/runner.lua";
import pkgLua from "./lua/pkg.lua";
import stdLua from "./lua/lib/std.lua";
import cryptoLua from "./lua/lib/crypto.lua";
import meshLua from "./lua/lib/mesh.lua";
import spiderLua from "./lua/apps/spider.lua";
import invMonLua from "./lua/apps/inv_mon.lua";
import netDiagLua from "./lua/apps/net_diag.lua";
import meshSetupLua from "./lua/apps/mesh_setup.lua";
import subnetBridgeLua from "./lua/apps/subnet_bridge.lua";
import type { StaticAppEntry } from "./protocol";

const textEncoder = new TextEncoder();

export async function sha256Hex(input: string | Uint8Array): Promise<string> {
  const bytes = typeof input === "string" ? textEncoder.encode(input) : input;
  const copy = new Uint8Array(bytes.byteLength);
  copy.set(bytes);
  const digest = await crypto.subtle.digest("SHA-256", copy.buffer);
  const view = new Uint8Array(digest);
  let hex = "";
  for (let i = 0; i < view.length; i++) {
    hex += view[i].toString(16).padStart(2, "0");
  }
  return hex;
}

interface StaticAppDefinition {
  slug: string;
  title: string;
  description: string;
  source: string;
}

const STATIC_APPS: readonly StaticAppDefinition[] = [
  {
    slug: "spider",
    title: "Item & Recipe Spider",
    description:
      "Crawls attached inventories, AE2 networks, and crafting patterns with local hash deduplication and uploads to /api/recipes/ingest.",
    source: spiderLua,
  },
  {
    slug: "inv_mon",
    title: "Live Inventory Monitor",
    description:
      "Real-time inventory monitoring applet built on lib.std with filterable item aggregation.",
    source: invMonLua,
  },
  {
    slug: "net_diag",
    title: "Network & Peripheral Diagnostics",
    description:
      "Inspects attached peripherals, Rednet peers, and device API method tables using lib.std.",
    source: netDiagLua,
  },
  {
    slug: "mesh_setup",
    title: "Encrypted Multi-Subnet Mesh Setup & Floppy Builder",
    description:
      "Scans for an unused random modem channel, generates a 256-bit HMAC-SHA256 encryption key, and builds a Subnet Join Installer floppy disk.",
    source: meshSetupLua,
  },
  {
    slug: "subnet_bridge",
    title: "Encrypted Multi-Subnet Peripheral Bridge",
    description:
      "Dual-homed wired <-> ender/wireless bridge exposing local peripherals as remote proxies (e.g. net.main_nether.storage_0.list()).",
    source: subnetBridgeLua,
  },
];

const CORE_LUA_FILES: Readonly<Record<string, string>> = {
  "bootstrap.lua": bootstrapLua,
  "gateway.lua": gatewayLua,
  "runner.lua": runnerLua,
  "pkg.lua": pkgLua,
  "lib/std.lua": stdLua,
  "lib/crypto.lua": cryptoLua,
  "lib/mesh.lua": meshLua,
};

const staticAppBySlug = new Map<string, StaticAppDefinition>(
  STATIC_APPS.map((app) => [app.slug, app]),
);

const hashCache = new Map<string, string>();

async function cachedHash(key: string, content: string): Promise<string> {
  const existing = hashCache.get(key);
  if (existing !== undefined) {
    return existing;
  }
  const digest = await sha256Hex(content);
  hashCache.set(key, digest);
  return digest;
}

export async function getStaticAppCatalog(): Promise<StaticAppEntry[]> {
  const entries = await Promise.all(
    STATIC_APPS.map(async (app): Promise<StaticAppEntry> => {
      const sha256 = await cachedHash(`app:${app.slug}`, app.source);
      return {
        slug: app.slug,
        title: app.title,
        description: app.description,
        sha256,
        url: `/lua/apps/${app.slug}.lua`,
        size_bytes: textEncoder.encode(app.source).byteLength,
      };
    }),
  );
  return entries;
}

export async function getStaticApp(
  slug: string,
): Promise<(StaticAppEntry & { source: string }) | null> {
  const normalized = slug.endsWith(".lua") ? slug.slice(0, -4) : slug;
  const app = staticAppBySlug.get(normalized);
  if (!app) {
    return null;
  }
  const sha256 = await cachedHash(`app:${app.slug}`, app.source);
  return {
    slug: app.slug,
    title: app.title,
    description: app.description,
    sha256,
    url: `/lua/apps/${app.slug}.lua`,
    size_bytes: textEncoder.encode(app.source).byteLength,
    source: app.source,
  };
}

export function getCoreLuaFile(path: string): string | null {
  const normalized = path.replace(/^\/+/, "");
  if (Object.prototype.hasOwnProperty.call(CORE_LUA_FILES, normalized)) {
    return CORE_LUA_FILES[normalized];
  }
  return null;
}

export async function getCoreLuaManifest(): Promise<Record<string, string>> {
  const manifest: Record<string, string> = {};

  for (const [filename, source] of Object.entries(CORE_LUA_FILES)) {
    manifest[filename] = await cachedHash(`core:${filename}`, source);
  }

  for (const app of STATIC_APPS) {
    manifest[`apps/${app.slug}.lua`] = await cachedHash(
      `app:${app.slug}`,
      app.source,
    );
  }

  return manifest;
}
