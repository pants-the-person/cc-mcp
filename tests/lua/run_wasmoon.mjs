import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { LuaFactory } from "wasmoon";

const ROOT = resolve(process.cwd());

const FILES_TO_MOUNT = [
  "src/lua/lib/std.lua",
  "src/lua/lib/crypto.lua",
  "src/lua/lib/mesh.lua",
  "src/lua/bootstrap.lua",
  "src/lua/gateway.lua",
  "src/lua/runner.lua",
  "src/lua/pkg.lua",
  "src/lua/apps/spider.lua",
  "src/lua/apps/inv_mon.lua",
  "src/lua/apps/net_diag.lua",
  "src/lua/apps/mesh_setup.lua",
  "src/lua/apps/subnet_bridge.lua",
  "tests/lua/mock_cc.lua",
  "tests/lua/run_lua_tests.lua",
];

async function main() {
  const factory = new LuaFactory();

  for (const relPath of FILES_TO_MOUNT) {
    const absPath = resolve(ROOT, relPath);
    const content = readFileSync(absPath, "utf8");
    await factory.mountFile(relPath, content);
  }

  const lua = await factory.createEngine();
  try {
    await lua.doFile("tests/lua/run_lua_tests.lua");
  } finally {
    lua.global.close();
  }
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : String(err));
  process.exit(1);
});
