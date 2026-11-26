-- Automated Pure-Lua Test Suite for Stage 3 (CC: Tweaked Standard Library, Static Apps & Fleet Suite)
-- Compatible with standard Lua 5.2/5.3/5.4, LuaJIT, and wasmoon (WASM Lua 5.4).

package.path = "./?.lua;./tests/lua/?.lua;" .. package.path

local mock_cc = require("mock_cc")

local total_tests = 0
local passed_tests = 0
local failed_tests = {}

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error(string.format("%s: expected %s (%s), got %s (%s)",
      tostring(msg or "assert_eq failed"),
      tostring(expected), type(expected),
      tostring(actual), type(actual)
    ), 2)
  end
end

local function assert_true(cond, msg)
  if not cond then
    error(tostring(msg or "assert_true failed"), 2)
  end
end

local function assert_contains(haystack, needle, msg)
  if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
    error(string.format("%s: expected %q to contain %q",
      tostring(msg or "assert_contains failed"),
      tostring(haystack), tostring(needle)
    ), 2)
  end
end

local function run_test(name, fn)
  total_tests = total_tests + 1
  local ok, err = pcall(fn)
  if ok then
    passed_tests = passed_tests + 1
    print("[PASS] " .. name)
  else
    failed_tests[#failed_tests + 1] = { name = name, err = tostring(err) }
    print("[FAIL] " .. name .. " -> " .. tostring(err))
  end
end

-- Preload source files from repo
local SRC_STD           = mock_cc.read_disk_file("src/lua/lib/std.lua")
local SRC_CRYPTO        = mock_cc.read_disk_file("src/lua/lib/crypto.lua")
local SRC_MESH          = mock_cc.read_disk_file("src/lua/lib/mesh.lua")
local SRC_BOOTSTRAP     = mock_cc.read_disk_file("src/lua/bootstrap.lua")
local SRC_GATEWAY       = mock_cc.read_disk_file("src/lua/gateway.lua")
local SRC_RUNNER        = mock_cc.read_disk_file("src/lua/runner.lua")
local SRC_PKG           = mock_cc.read_disk_file("src/lua/pkg.lua")
local SRC_SPIDER        = mock_cc.read_disk_file("src/lua/apps/spider.lua")
local SRC_INV_MON       = mock_cc.read_disk_file("src/lua/apps/inv_mon.lua")
local SRC_NET_DIAG      = mock_cc.read_disk_file("src/lua/apps/net_diag.lua")
local SRC_MESH_SETUP    = mock_cc.read_disk_file("src/lua/apps/mesh_setup.lua")
local SRC_SUBNET_BRIDGE = mock_cc.read_disk_file("src/lua/apps/subnet_bridge.lua")

-- ===========================================================================
-- Test 1: std.serialize_json (nested tables, functions, non-finite, circular)
-- ===========================================================================
run_test("std.serialize_json handles nested tables, functions, non-finite numbers, and circular refs", function()
  local world = mock_cc.new_world()
  local comp = world:new_computer({ id = 1, label = "std_test" })
  comp:write_vfs("/lib/std.lua", SRC_STD)
  local std = comp.env.require("lib.std")

  assert_eq(type(std.VERSION), "string", "std.VERSION must be string")

  local shared_leaf = { tag = "shared", value = 7 }
  local cyclic = {
    name = 'chest "alpha"\nline2',
    active = true,
    count = 42,
    arr = { 1, "two", function() return "drop me" end, true },
    nested = {
      fn = function() end,
      co = coroutine.create(function() end),
      nan_val = 0 / 0,
      inf_val = math.huge,
      neg_inf = -math.huge,
      leaf_a = shared_leaf,
      leaf_b = shared_leaf,
    },
  }
  cyclic.self_ref = cyclic
  cyclic.nested.parent_ref = cyclic

  local encoded = std.serialize_json(cyclic)
  assert_eq(type(encoded), "string", "encoded JSON must be string")
  assert_contains(encoded, '"[Circular]"', "circular references must be replaced with [Circular]")

  local decoded = mock_cc.json_decode(encoded)
  assert_eq(type(decoded), "table", "encoded JSON must parse back cleanly")
  assert_eq(decoded.name, 'chest "alpha"\nline2', "escaped string round-trip")
  assert_eq(decoded.active, true, "boolean round-trip")
  assert_eq(decoded.count, 42, "number round-trip")
  assert_eq(decoded.self_ref, "[Circular]", "direct cycle replaced")
  assert_eq(decoded.nested.parent_ref, "[Circular]", "nested cycle replaced")
  assert_eq(decoded.nested.fn, nil, "function stripped")
  assert_eq(decoded.nested.co, nil, "thread stripped")
  assert_eq(decoded.nested.nan_val, "NaN", "NaN converted safely")
  assert_eq(decoded.nested.inf_val, "Infinity", "+Inf converted safely")
  assert_eq(decoded.nested.neg_inf, "-Infinity", "-Inf converted safely")
  -- Non-cyclic shared leaf should serialize cleanly in both places
  assert_eq(decoded.nested.leaf_a.tag, "shared", "shared DAG leaf_a preserved")
  assert_eq(decoded.nested.leaf_b.value, 7, "shared DAG leaf_b preserved")
  -- Array should have function compacted cleanly (3 valid elements)
  assert_eq(#decoded.arr, 3, "array with stripped function compacted cleanly")
  assert_eq(decoded.arr[1], 1, "arr[1]")
  assert_eq(decoded.arr[2], "two", "arr[2]")
  assert_eq(decoded.arr[3], true, "arr[3]")
end)

-- ===========================================================================
-- Test 2: std.list_inventory + std.filters (by_mod, min_count, by_name, by_tag, all, any)
-- ===========================================================================
run_test("std.list_inventory with std.filters.by_mod('mekanism') and min_count(10) returns exact totals", function()
  local world = mock_cc.new_world()
  local comp = world:new_computer({ id = 1, label = "inv_test" })
  comp:write_vfs("/lib/std.lua", SRC_STD)

  comp:attach_peripheral("minecraft:chest_0", { "minecraft:chest", "inventory" }, {
    size = function() return 27 end,
    list = function()
      return {
        [1] = { name = "mekanism:ingot_steel", count = 6, displayName = "Steel Ingot", tags = { ["forge:ingots/steel"] = true } },
        [2] = { name = "mekanism:ingot_osmium", count = 5, displayName = "Osmium Ingot", tags = { "forge:ingots/osmium" } },
        [3] = { name = "minecraft:iron_ingot", count = 64, displayName = "Iron Ingot", tags = { "forge:ingots/iron" } },
      }
    end,
  })
  comp:attach_peripheral("minecraft:chest_1", { "minecraft:chest", "inventory" }, {
    size = function() return 27 end,
    list = function()
      return {
        [1] = { name = "mekanism:ingot_steel", count = 8, displayName = "Steel Ingot" },
        [2] = { name = "mekanism:alloy_infused", count = 20, displayName = "Infused Alloy", tags = { "mekanism:alloys" } },
        [3] = { name = "mekanism:ingot_osmium", count = 4, displayName = "Osmium Ingot" },
      }
    end,
  })

  local std = comp.env.require("lib.std")

  -- 1. Predicate-based filtering using std.filters.all(by_mod, min_count)
  local res_pred = std.list_inventory({
    filter = std.filters.all(
      std.filters.by_mod("mekanism"),
      std.filters.min_count(10)
    ),
  })
  assert_eq(res_pred.inventories_scanned, 2, "scanned 2 chests")
  assert_eq(res_pred.unique_items, 2, "2 mekanism items have count >= 10 (alloy_infused=20, ingot_steel=14; osmium=9 excluded)")
  assert_eq(res_pred.total_items, 34, "total matching items = 20 + 14")
  assert_eq(res_pred.items[1].name, "mekanism:alloy_infused", "highest count first")
  assert_eq(res_pred.items[1].count, 20, "alloy_infused count")
  assert_eq(res_pred.items[2].name, "mekanism:ingot_steel", "second item is ingot_steel")
  assert_eq(res_pred.items[2].count, 14, "ingot_steel aggregated across chests (6 + 8)")

  -- 2. Declarative opts matching DO cc_list_inventory args
  local res_decl = std.list_inventory({
    mod = "mekanism",
    min_count = 10,
  })
  assert_eq(res_decl.unique_items, 2, "declarative unique_items")
  assert_eq(res_decl.total_items, 34, "declarative total_items")

  -- 3. by_tag + by_name + any
  local res_any = std.list_inventory({
    filter = std.filters.any(
      std.filters.by_tag("forge:ingots/iron"),
      std.filters.by_name("alloy")
    ),
  })
  assert_eq(res_any.unique_items, 2, "iron_ingot (by_tag) + alloy_infused (by_name)")
  assert_eq(res_any.total_items, 84, "64 + 20")

  -- 4. std.list_attachment filtering on multi-return peripheral.getType
  local invs = std.list_attachment("inventory")
  assert_eq(#invs, 2, "list_attachment('inventory') matches multi-return type")
  assert_eq(invs[1].type, "minecraft:chest", "primary type preserved")
  assert_eq(#invs[1].types, 2, "all types captured")
end)

-- ===========================================================================
-- Test 3: std.get_api("meBridge_0") safe read-only probing (zero mutating calls!)
-- ===========================================================================
run_test("std.get_api('meBridge_0') returns types, methods, safe probe metadata without calling mutating methods", function()
  local world = mock_cc.new_world()
  local comp = world:new_computer({ id = 1, label = "api_test" })
  comp:write_vfs("/lib/std.lua", SRC_STD)

  local mutating_calls = {
    craftItem = 0,
    exportItem = 0,
    importItem = 0,
    pushItems = 0,
    setOutput = 0,
    scram = 0,
  }

  comp:attach_peripheral("meBridge_0", { "advancedperipherals:me_bridge", "me_bridge" }, {
    getEnergy = function() return 48000 end,
    getEnergyCapacity = function() return 100000 end,
    getTotalItemStorage = function() return 65536 end,
    listItems = function()
      return {
        { name = "minecraft:diamond", count = 128, displayName = "Diamond" },
      }
    end,
    -- Mutating methods that MUST NEVER be invoked
    craftItem = function() mutating_calls.craftItem = mutating_calls.craftItem + 1; return true end,
    exportItem = function() mutating_calls.exportItem = mutating_calls.exportItem + 1; return 64 end,
    importItem = function() mutating_calls.importItem = mutating_calls.importItem + 1; return 64 end,
    pushItems = function() mutating_calls.pushItems = mutating_calls.pushItems + 1; return 64 end,
    setOutput = function() mutating_calls.setOutput = mutating_calls.setOutput + 1 end,
    scram = function() mutating_calls.scram = mutating_calls.scram + 1 end,
  })

  local std = comp.env.require("lib.std")
  local api = std.get_api("meBridge_0")

  assert_eq(api.present, true, "device present")
  assert_eq(api.name, "meBridge_0", "device name")
  assert_eq(api.type_name, "advancedperipherals:me_bridge", "primary type_name")
  assert_eq(api.type, "advancedperipherals:me_bridge", "primary type")
  assert_eq(#api.types, 2, "captured both multi-return types")
  assert_eq(api.types[2], "me_bridge", "secondary type")
  assert_eq(#api.methods, 10, "all 10 methods captured")

  -- Safe read-only metadata populated
  assert_eq(api.metadata.getEnergy, 48000, "safe probe getEnergy")
  assert_eq(api.metadata.getEnergyCapacity, 100000, "safe probe getEnergyCapacity")
  assert_eq(api.metadata.getTotalItemStorage, 65536, "safe probe getTotalItemStorage")
  assert_eq(#api.metadata.listItems, 1, "safe probe listItems")

  -- Mutating methods MUST have 0 invocations
  for m_name, count in pairs(mutating_calls) do
    assert_eq(count, 0, "mutating method '" .. m_name .. "' MUST NOT be called")
  end
end)

-- ===========================================================================
-- Test 4: bootstrap.lua self-updating sync & hash cache deduplication
-- ===========================================================================
run_test("bootstrap.lua syncs /lib/std.lua, /pkg.lua, /gateway.lua, /runner.lua and skips unchanged on 2nd boot", function()
  local world = mock_cc.new_world()
  local BASE = "https://mesh.example.test"

  local manifest = {
    ["lib/std.lua"] = "hash_std_v1",
    ["pkg.lua"] = "hash_pkg_v1",
    ["gateway.lua"] = "hash_gw_v1",
    ["runner.lua"] = "hash_runner_v1",
  }
  local file_downloads = 0
  local auth_verified = false

  world:register_http("GET", BASE .. "/lua/manifest.json", function(req)
    assert_eq(req.headers["CF-Access-Client-Id"], "cid_123", "CF-Access-Client-Id header")
    assert_eq(req.headers["CF-Access-Client-Secret"], "csec_456", "CF-Access-Client-Secret header")
    auth_verified = true
    return 200, mock_cc.json_encode(manifest)
  end)

  local files = {
    ["lib/std.lua"] = SRC_STD,
    ["pkg.lua"] = SRC_PKG,
    ["gateway.lua"] = SRC_GATEWAY,
    ["runner.lua"] = SRC_RUNNER,
  }
  for k, content in pairs(files) do
    world:register_http("GET", BASE .. "/lua/" .. k, function()
      file_downloads = file_downloads + 1
      return 200, content
    end)
  end

  local comp = world:new_computer({
    id = 10,
    label = "gw_boot",
    settings = {
      ["mcp.url"] = BASE,
      ["mcp.cf_id"] = "cid_123",
      ["mcp.cf_secret"] = "csec_456",
      ["mcp.role"] = "gateway",
    },
  })

  -- First boot
  comp:run_script(SRC_BOOTSTRAP, "bootstrap.lua")
  assert_true(auth_verified, "CF Access headers verified")
  assert_eq(file_downloads, 4, "4 files downloaded on first boot")
  assert_eq(comp:read_vfs("/lib/std.lua"), SRC_STD, "/lib/std.lua written")
  assert_eq(comp:read_vfs("/pkg.lua"), SRC_PKG, "/pkg.lua written")
  assert_eq(comp:read_vfs("/gateway.lua"), SRC_GATEWAY, "/gateway.lua written")
  assert_eq(comp:read_vfs("/runner.lua"), SRC_RUNNER, "/runner.lua written")
  assert_true(comp:read_vfs("/.mesh_manifest") ~= nil, "/.mesh_manifest written")
  assert_eq(#comp.shell_runs, 1, "shell.run called once")
  assert_eq(comp.shell_runs[1].program, "/gateway.lua", "launched /gateway.lua")

  -- Second boot (manifest unchanged -> 0 file downloads!)
  file_downloads = 0
  comp:run_script(SRC_BOOTSTRAP, "bootstrap.lua")
  assert_eq(file_downloads, 0, "0 files re-downloaded when hashes match")
end)

-- ===========================================================================
-- Test 5, 6, 7: Gateway Idle Silence (50 pulses = 0 sends), Wakeup & Drain
--               with live mock runner.lua, Local Tool Execution, and Hot-Plug
-- ===========================================================================
run_test("gateway.lua Idle Silence (50 redstone pulses = 0 WS sends), Wakeup & Drain with runner.lua, and Hot-Plug", function()
  local world = mock_cc.new_world()
  local BASE = "https://mesh.example.test"

  -- Computer 1: Gateway
  local gw = world:new_computer({
    id = 1,
    label = "gw_main",
    settings = {
      ["mcp.url"] = BASE,
      ["mcp.cf_id"] = "cid_123",
      ["mcp.cf_secret"] = "csec_456",
      ["mcp.role"] = "gateway",
      ["mcp.world"] = "overworld",
      ["mcp.net"] = "main",
      ["mcp.clock_side"] = "back",
      ["mcp.probe_timeout"] = 0.2,
      ["mcp.max_reconnects"] = 0,
    },
  })
  gw:write_vfs("/lib/std.lua", SRC_STD)
  gw:attach_peripheral("top", { "modem" }, { isWireless = function() return true end })
  gw:attach_peripheral("minecraft:chest_0", { "minecraft:chest", "inventory" }, {
    size = function() return 27 end,
    list = function()
      return {
        [1] = { name = "mekanism:ingot_steel", count = 32, displayName = "Steel Ingot" },
      }
    end,
  })

  -- Computer 2: Live Runner Daemon
  local runner = world:new_computer({
    id = 2,
    label = "runner_alpha",
    is_turtle = false,
  })
  runner:write_vfs("/lib/std.lua", SRC_STD)
  runner:attach_peripheral("top", { "modem" }, { isWireless = function() return true end })

  -- Start runner first so it responds to gateway's DISCOVER broadcast
  runner:start_daemon(SRC_RUNNER, "runner.lua")
  world:pump()

  -- Start gateway
  gw:start_daemon(SRC_GATEWAY, "gateway.lua")
  world:pump()
  -- Advance past 0.2s probe_timeout so SYNC_TOPOLOGY completes
  world:advance_time(0.25)

  assert_eq(#gw.ws_handles, 1, "gateway opened 1 WebSocket")
  local ws = gw.ws_handles[1]
  assert_contains(ws.url, "wss://mesh.example.test/ws?role=gateway", "WS URL upgraded to wss://")
  assert_eq(ws.headers["CF-Access-Client-Id"], "cid_123", "WS CF Access ID header")

  -- Check initial SYNC_TOPOLOGY
  assert_eq(ws.send_count, 1, "exactly 1 initial SYNC_TOPOLOGY frame sent")
  local sync_msg = ws:last_decoded()
  assert_eq(sync_msg.type, "SYNC_TOPOLOGY", "first frame is SYNC_TOPOLOGY")
  assert_eq(sync_msg.net_id, "main", "net_id matches")

  local found_runner = false
  local found_chest = false
  for _, ent in ipairs(sync_msg.entities) do
    if ent.name == "runner_alpha" and ent.kind == "runner" then
      found_runner = true
    elseif ent.name == "minecraft:chest_0" and ent.kind == "peripheral" and ent.probe then
      found_chest = true
    end
  end
  assert_true(found_runner, "SYNC_TOPOLOGY discovered runner_alpha over Rednet")
  assert_true(found_chest, "SYNC_TOPOLOGY included chest with std.get_api probe")

  -- -------------------------------------------------------------------------
  -- IDLE SILENCE TEST: 50 redstone pulses while has_pending_work == false => 0 sends!
  -- -------------------------------------------------------------------------
  ws:reset_spies()
  for _ = 1, 50 do
    gw:pulse_redstone("back")
  end
  assert_eq(ws.send_count, 0, "Idle Silence: 50 redstone pulses while idle MUST produce 0 ws.send calls")

  -- -------------------------------------------------------------------------
  -- WAKEUP & DRAIN TEST (targeting live mock runner.lua)
  -- -------------------------------------------------------------------------
  ws:inject_message({
    type = "WAKE",
    net_id = "main",
    task_id = "task-runner-1",
    pending_count = 1,
  })
  world:pump()
  -- WAKE alone must NOT send POLL_QUEUE before the next redstone clock rising edge
  assert_eq(ws.send_count, 0, "WAKE sets flag without immediate POLL_QUEUE before clock pulse")

  -- Fire 1 redstone clock pulse -> POLL_QUEUE sent ONCE!
  gw:pulse_redstone("back")
  assert_eq(ws.send_count, 1, "1 redstone pulse after WAKE sends POLL_QUEUE exactly once")
  local poll_msg = ws:last_decoded()
  assert_eq(poll_msg.type, "POLL_QUEUE", "sent frame is POLL_QUEUE")
  assert_eq(poll_msg.net_id, "main", "POLL_QUEUE net_id")

  -- Inject DISPATCH_BATCH targeting runner_alpha using lib.std and print()
  ws:reset_spies()
  ws:inject_message({
    type = "DISPATCH_BATCH",
    net_id = "main",
    has_more = false,
    tasks = {
      {
        task_id = "task-runner-1",
        net_id = "main",
        target_node = "runner_alpha",
        lua_code = [[
          print("runner std=" .. std.VERSION)
          print("arg_x=" .. tostring(args.x))
          return {
            doubled = args.x * 2,
            serialized = std.serialize_json({ status = "ok", n = args.x }),
          }
        ]],
        args = { x = 21 },
      },
    },
  })
  world:pump()

  assert_eq(ws.send_count, 1, "TASK_RESULT sent back over WS after runner execution")
  local res_msg = ws:last_decoded()
  assert_eq(res_msg.type, "TASK_RESULT", "frame type is TASK_RESULT")
  assert_eq(res_msg.task_id, "task-runner-1", "task_id matches")
  assert_eq(res_msg.ok, true, "task succeeded")
  assert_eq(res_msg.stdout, "runner std=1.0.0\narg_x=21", "captured stdout matches")
  assert_eq(res_msg.result.doubled, 42, "returned result.doubled")
  assert_contains(res_msg.result.serialized, '"status":"ok"', "std.serialize_json works in runner sandbox")

  -- Queue is drained (has_more == false): 10 more redstone pulses must send 0 messages
  ws:reset_spies()
  for _ = 1, 10 do
    gw:pulse_redstone("back")
  end
  assert_eq(ws.send_count, 0, "after drain (has_more=false), redstone pulses remain silent")

  -- Also verify local gateway execution of seeded cc_list_inventory Lua template
  ws:inject_message({ type = "WAKE", net_id = "main", pending_count = 1 })
  world:pump()
  gw:pulse_redstone("back")
  ws:reset_spies()
  ws:inject_message({
    type = "DISPATCH_BATCH",
    net_id = "main",
    has_more = false,
    tasks = {
      {
        task_id = "task-local-inv",
        net_id = "main",
        target_node = "gateway",
        lua_code = 'local std = require("lib.std")\nreturn std.list_inventory(args)',
        args = { mod = "mekanism", min_count = 10 },
      },
    },
  })
  world:pump()
  assert_eq(ws.send_count, 1, "local gateway task sent TASK_RESULT")
  local local_res = ws:last_decoded()
  assert_eq(local_res.ok, true, "local cc_list_inventory succeeded")
  assert_eq(local_res.result.total_items, 32, "local cc_list_inventory returned 32 steel ingots")

  -- -------------------------------------------------------------------------
  -- HOT-PLUG PERIPHERAL ATTACH & DETACH TEST
  -- -------------------------------------------------------------------------
  ws:reset_spies()
  local display_mutated = 0
  gw:attach_peripheral("create_display_link_0", { "create:display_link" }, {
    getSize = function() return 4 end,
    getDirection = function() return "north" end,
    setCursorPos = function() display_mutated = display_mutated + 1 end,
    clear = function() display_mutated = display_mutated + 1 end,
  }, true)
  world:pump()

  assert_eq(ws.send_count, 1, "PERIPHERAL_ATTACHED sent on hot-plug")
  local attach_msg = ws:last_decoded()
  assert_eq(attach_msg.type, "PERIPHERAL_ATTACHED", "frame type PERIPHERAL_ATTACHED")
  assert_eq(attach_msg.name, "create_display_link_0", "attached peripheral name")
  assert_eq(attach_msg.type_name, "create:display_link", "attached peripheral type_name")
  assert_eq(attach_msg.probe.metadata.getSize, 4, "std.get_api read-only probe populated")
  assert_eq(attach_msg.probe.metadata.getDirection, "north", "std.get_api getDirection populated")
  assert_eq(display_mutated, 0, "hot-plug probe did not call mutating methods")

  ws:reset_spies()
  gw:detach_peripheral("create_display_link_0", true)
  world:pump()
  assert_eq(ws.send_count, 1, "PERIPHERAL_DETACHED sent on detach")
  local detach_msg = ws:last_decoded()
  assert_eq(detach_msg.type, "PERIPHERAL_DETACHED", "frame type PERIPHERAL_DETACHED")
  assert_eq(detach_msg.name, "create_display_link_0", "detached peripheral name")
end)

-- ===========================================================================
-- Test 8: Dual App Store CLI (pkg.lua: list, install static, install store, publish)
-- ===========================================================================
run_test("pkg.lua lists both [static] and [store] apps, installs spider cleanly, and publishes packages", function()
  local world = mock_cc.new_world()
  local BASE = "https://mesh.example.test"
  local published_payload = nil

  world:register_http("GET", BASE .. "/api/store/static", function()
    return 200, mock_cc.json_encode({
      apps = {
        { slug = "spider", title = "Item & Recipe Spider", sha256 = "aaa", url = "/lua/apps/spider.lua" },
        { slug = "inv_mon", title = "Live Inventory Monitor", sha256 = "bbb", url = "/lua/apps/inv_mon.lua" },
        { slug = "net_diag", title = "Network & Peripheral Diagnostics", sha256 = "ccc", url = "/lua/apps/net_diag.lua" },
      },
    })
  end)

  world:register_http("GET", BASE .. "/api/store/packages", function()
    return 200, mock_cc.json_encode({
      packages = {
        { slug = "quarry_pro", title = "Quarry Pro", version = "1.2.0" },
      },
    })
  end)

  world:register_http("GET", BASE .. "/lua/apps/spider.lua", function()
    return 200, SRC_SPIDER
  end)

  world:register_http("GET", BASE .. "/api/store/download/quarry_pro", function()
    return 200, "-- quarry_pro dynamic source\nprint('quarry!')\n"
  end)

  world:register_http("POST", BASE .. "/api/store/publish", function(req)
    published_payload = mock_cc.json_decode(req.body)
    return 201, mock_cc.json_encode({ ok = true })
  end)

  local comp = world:new_computer({
    id = 5,
    label = "pkg_client",
    settings = {
      ["mcp.url"] = BASE,
      ["mcp.cf_id"] = "cid_123",
      ["mcp.cf_secret"] = "csec_456",
    },
  })
  comp:write_vfs("/lib/std.lua", SRC_STD)

  -- 1. pkg list
  local ok_list = comp:run_script(SRC_PKG, "pkg.lua", "list")
  assert_eq(ok_list, true, "pkg list returned true")
  local list_out = table.concat(comp.stdout, "\n")
  assert_contains(list_out, "[static] spider", "pkg list shows [static] spider")
  assert_contains(list_out, "[static] inv_mon", "pkg list shows [static] inv_mon")
  assert_contains(list_out, "[static] net_diag", "pkg list shows [static] net_diag")
  assert_contains(list_out, "[store] quarry_pro", "pkg list shows [store] quarry_pro")

  -- 2. pkg install spider (auto resolves static /lua/apps/spider.lua -> /spider.lua)
  local ok_install = comp:run_script(SRC_PKG, "pkg.lua", "install", "spider")
  assert_eq(ok_install, true, "pkg install spider returned true")
  assert_eq(comp:read_vfs("/spider.lua"), SRC_SPIDER, "/spider.lua matches exact static app bytes")

  -- 3. pkg install quarry_pro --store /apps/quarry.lua
  local ok_store = comp:run_script(SRC_PKG, "pkg.lua", "install", "quarry_pro", "--store", "/apps/quarry.lua")
  assert_eq(ok_store, true, "pkg install --store returned true")
  assert_eq(comp:read_vfs("/apps/quarry.lua"), "-- quarry_pro dynamic source\nprint('quarry!')\n", "store download exact bytes")

  -- 4. pkg publish
  comp:write_vfs("/my_tool.lua", "print('hello mesh')")
  local ok_pub = comp:run_script(SRC_PKG, "pkg.lua", "publish", "my_tool", "My Tool", "/my_tool.lua", "Demo package")
  assert_eq(ok_pub, true, "pkg publish returned true")
  assert_true(published_payload ~= nil, "publish POST received")
  assert_eq(published_payload.slug, "my_tool", "published slug")
  assert_eq(published_payload.title, "My Tool", "published title")
  assert_eq(published_payload.code, "print('hello mesh')", "published code")
  assert_eq(published_payload.description, "Demo package", "published description")
end)

-- ===========================================================================
-- Test 9: Static Apps Smoke Tests (spider.lua dedup, inv_mon.lua, net_diag.lua)
-- ===========================================================================
run_test("Static apps spider.lua (with dedup), inv_mon.lua (--once), and net_diag.lua (--json) run cleanly", function()
  local world = mock_cc.new_world()
  local BASE = "https://mesh.example.test"
  local ingest_calls = 0
  local last_ingest = nil

  world:register_http("POST", BASE .. "/api/recipes/ingest", function(req)
    ingest_calls = ingest_calls + 1
    last_ingest = mock_cc.json_decode(req.body)
    return 200, mock_cc.json_encode({ ok = true, items_upserted = #last_ingest.items, recipes_upserted = #last_ingest.recipes })
  end)

  local comp = world:new_computer({
    id = 7,
    label = "apps_host",
    settings = {
      ["mcp.url"] = BASE,
      ["mcp.cf_id"] = "cid_123",
      ["mcp.cf_secret"] = "csec_456",
    },
  })
  comp:write_vfs("/lib/std.lua", SRC_STD)

  comp:attach_peripheral("minecraft:chest_0", { "minecraft:chest", "inventory" }, {
    size = function() return 27 end,
    list = function()
      return {
        [1] = { name = "mekanism:ingot_steel", count = 24, displayName = "Steel Ingot" },
        [2] = { name = "minecraft:iron_ingot", count = 16, displayName = "Iron Ingot" },
      }
    end,
  })
  comp:attach_peripheral("meBridge_0", { "advancedperipherals:me_bridge" }, {
    listItems = function()
      return {
        { name = "ae2:fluix_crystal", count = 12, displayName = "Fluix Crystal" },
      }
    end,
    getPatterns = function()
      return {
        {
          recipe_id = "ae2:steel_pattern",
          output_item_id = "mekanism:ingot_steel",
          output_count = 1,
          ingredients = {
            { ingredient_id = "minecraft:iron_ingot", count = 1, slot = "in_1" },
            { ingredient_id = "minecraft:coal", count = 2, slot = "in_2" },
          },
        },
      }
    end,
  })
  local mon_lines = {}
  comp:attach_peripheral("monitor_0", { "monitor" }, {
    clear = function() mon_lines = {} end,
    setCursorPos = function(_, y) mon_lines._y = y end,
    write = function(s) mon_lines[mon_lines._y or 1] = s end,
    getSize = function() return 50, 20 end,
  })

  -- 1. spider.lua first run uploads batch and writes /.spider_cache
  local ok_spider1 = comp:run_script(SRC_SPIDER, "spider.lua")
  assert_eq(ok_spider1, true, "spider first run ok")
  assert_eq(ingest_calls, 1, "spider uploaded once")
  assert_true(#last_ingest.items >= 4, "spider collected chest + ME + pattern items")
  assert_eq(#last_ingest.recipes, 1, "spider collected 1 pattern recipe")
  assert_true(comp:read_vfs("/.spider_cache") ~= nil, "spider saved local dedup hash")

  -- 2. spider.lua second run deduplicates and skips upload!
  local ok_spider2 = comp:run_script(SRC_SPIDER, "spider.lua")
  assert_eq(ok_spider2, true, "spider second run ok")
  assert_eq(ingest_calls, 1, "spider skipped duplicate upload on unchanged hash")

  -- 3. inv_mon.lua --mod mekanism --min 10 --once
  local inv_report = comp:run_script(SRC_INV_MON, "inv_mon.lua", "--mod", "mekanism", "--min", "10", "--once")
  assert_eq(inv_report.total_items, 24, "inv_mon filtered to 24 steel ingots")
  assert_true(#mon_lines >= 3, "inv_mon rendered lines to attached monitor")
  assert_contains(mon_lines[2], "Steel Ingot", "monitor line shows Steel Ingot")

  -- 4. net_diag.lua (human readable + --json)
  comp.stdout = {}
  local diag_report = comp:run_script(SRC_NET_DIAG, "net_diag.lua", "--timeout", "0.1")
  assert_eq(#diag_report.peripherals, 3, "net_diag inspected all 3 peripherals")
  local diag_out = table.concat(comp.stdout, "\n")
  assert_contains(diag_out, "meBridge_0", "net_diag printed meBridge_0")

  comp.stdout = {}
  comp:run_script(SRC_NET_DIAG, "net_diag.lua", "--json", "--timeout", "0.1")
  local diag_json = mock_cc.json_decode(comp.stdout[#comp.stdout])
  assert_eq(type(diag_json), "table", "net_diag --json produced valid JSON")
  assert_eq(diag_json.label, "apps_host", "net_diag JSON label matches")
end)

-- ===========================================================================
-- Test 10: Gateway 300s fallback timer, PubSub bridge, reconnect backoff,
--          and Runner xpcall error isolation
-- ===========================================================================
run_test("gateway.lua 300s fallback timer, PubSub EVENT bridge, reconnect backoff, and runner xpcall isolation", function()
  local world = mock_cc.new_world()
  local BASE = "https://mesh.example.test"

  local gw = world:new_computer({
    id = 1,
    label = "gw_resilience",
    settings = {
      ["mcp.url"] = BASE,
      ["mcp.net"] = "main",
      ["mcp.clock_side"] = "back",
      ["mcp.probe_timeout"] = 0.1,
      ["mcp.fallback_poll_interval"] = 300,
      ["mcp.max_reconnects"] = 1,
    },
  })
  gw:write_vfs("/lib/std.lua", SRC_STD)
  gw:attach_peripheral("top", { "modem" }, { isWireless = function() return true end })

  local runner = world:new_computer({ id = 2, label = "runner_err_test" })
  runner:write_vfs("/lib/std.lua", SRC_STD)
  runner:attach_peripheral("top", { "modem" }, { isWireless = function() return true end })

  local listener = world:new_computer({ id = 3, label = "pubsub_peer" })
  listener:attach_peripheral("top", { "modem" }, { isWireless = function() return true end })
  listener.env.rednet.open("top")

  runner:start_daemon(SRC_RUNNER, "runner.lua")
  gw:start_daemon(SRC_GATEWAY, "gateway.lua")
  world:pump()
  world:advance_time(0.15)

  local ws1 = gw.ws_handles[1]
  ws1:reset_spies()

  -- 1. 300s fallback timer triggers POLL_QUEUE without WAKE
  world:advance_time(300.1)
  assert_eq(ws1.send_count, 1, "300s fallback timer sent POLL_QUEUE")
  assert_eq(ws1:last_decoded().type, "POLL_QUEUE", "fallback frame is POLL_QUEUE")

  -- 2. Runner runtime error & syntax error return ok=false without crashing runner daemon
  ws1:reset_spies()
  ws1:inject_message({
    type = "DISPATCH_BATCH",
    net_id = "main",
    has_more = false,
    tasks = {
      {
        task_id = "task-err-runtime",
        target_node = "runner_err_test",
        lua_code = 'print("before boom"); error("reactor overheated")',
        args = {},
      },
      {
        task_id = "task-err-syntax",
        target_node = "runner_err_test",
        lua_code = "if then end",
        args = {},
      },
    },
  })
  world:pump()
  assert_eq(ws1.send_count, 2, "both error tasks reported TASK_RESULT")
  local err_frames = ws1:all_decoded()
  assert_eq(err_frames[1].ok, false, "runtime error ok=false")
  assert_eq(err_frames[1].stdout, "before boom", "stdout before error captured")
  assert_contains(err_frames[1].error, "reactor overheated", "error message captured")
  assert_eq(err_frames[2].ok, false, "syntax error ok=false")
  assert_contains(err_frames[2].error, "Compile error", "compile error reported")

  -- Verify runner daemon is still alive after errors!
  ws1:reset_spies()
  ws1:inject_message({
    type = "DISPATCH_BATCH",
    net_id = "main",
    has_more = false,
    tasks = {
      {
        task_id = "task-after-err",
        target_node = "runner_err_test",
        lua_code = "return 'still alive'",
        args = {},
      },
    },
  })
  world:pump()
  assert_eq(ws1:last_decoded().ok, true, "runner remained healthy after errors")
  assert_eq(ws1:last_decoded().result, "still alive", "runner returned result")

  -- 3. PubSub EVENT broadcast from WS -> Rednet "mcp_pubsub"
  ws1:inject_message({
    type = "EVENT",
    topic = "factory.alerts",
    payload = { level = "warn", msg = "low_fuel" },
    from_net = "nether",
    sender = "gw_nether",
    timestamp = 12345,
  })
  world:pump()
  local got_pubsub = false
  for _, ev in ipairs(listener.event_queue) do
    if ev[1] == "rednet_message" and ev[4] == "mcp_pubsub" and ev[3].topic == "factory.alerts" then
      got_pubsub = true
    end
  end
  assert_true(got_pubsub, "EVENT re-broadcast over Rednet mcp_pubsub")

  -- 4. Reconnect with exponential backoff after websocket_closed
  ws1:inject_close()
  world:pump()
  -- Backoff starts at 2s; before 2s, no second WS handle yet
  world:advance_time(1.0)
  assert_eq(#gw.ws_handles, 1, "does not reconnect before 2s backoff")
  -- Advance past 2s backoff (reconnects and starts 0.1s probe), then finish probe
  world:advance_time(1.1)
  assert_eq(#gw.ws_handles, 2, "reconnected after 2s backoff")
  world:advance_time(0.15)
  local ws2 = gw.ws_handles[2]
  assert_eq(ws2:last_decoded().type, "SYNC_TOPOLOGY", "fresh SYNC_TOPOLOGY sent after reconnect")
end)

-- ===========================================================================
-- Test 11: pkg.lua schematics commands & std.serialize_json fallback encoder
-- ===========================================================================
run_test("pkg.lua schematics list/install/publish and std.serialize_json pure-Lua fallback", function()
  local world = mock_cc.new_world()
  local BASE = "https://mesh.example.test"
  local pub_schem = nil

  world:register_http("GET", BASE .. "/api/store/schematics", function()
    return 200, mock_cc.json_encode({
      schematics = {
        { slug = "steam_boiler", title = "Steam Boiler", format = "lua" },
      },
    })
  end)
  world:register_http("GET", BASE .. "/api/store/schematics/download/steam_boiler", function()
    return 200, "-- boiler blueprint"
  end)
  world:register_http("POST", BASE .. "/api/store/schematics/publish", function(req)
    pub_schem = mock_cc.json_decode(req.body)
    return 201, mock_cc.json_encode({ ok = true })
  end)

  local comp = world:new_computer({
    id = 9,
    label = "schem_client",
    settings = { ["cc_mesh.url"] = BASE }, -- verify cc_mesh.* fallback setting key!
  })
  comp:write_vfs("/lib/std.lua", SRC_STD)

  assert_eq(comp:run_script(SRC_PKG, "pkg.lua", "schematics", "list"), true, "schematics list")
  assert_contains(table.concat(comp.stdout, "\n"), "[schematic] steam_boiler", "listed steam_boiler")

  assert_eq(comp:run_script(SRC_PKG, "pkg.lua", "schematics", "install", "steam_boiler"), true, "schematics install")
  assert_eq(comp:read_vfs("/schematics/steam_boiler"), "-- boiler blueprint", "schematic saved")

  comp:write_vfs("/bp.lua", "return { blocks = 12 }")
  assert_eq(comp:run_script(SRC_PKG, "pkg.lua", "schematics", "publish", "mini_farm", "Mini Farm", "/bp.lua", "lua"), true, "schematics publish")
  assert_eq(pub_schem.slug, "mini_farm", "published schematic slug")
  assert_eq(pub_schem.content, "return { blocks = 12 }", "published schematic content")

  -- Verify std.serialize_json pure-Lua fallback when textutils is temporarily absent
  local std = comp.env.require("lib.std")
  local saved_tu = comp.env.textutils
  comp.env.textutils = nil
  local raw_json = std.serialize_json({ a = 1, b = { "x", "y" }, f = function() end })
  local roundtrip = std.deserialize_json(raw_json)
  comp.env.textutils = saved_tu
  assert_eq(roundtrip.a, 1, "fallback JSON number")
  assert_eq(roundtrip.b[2], "y", "fallback JSON array")
  assert_eq(roundtrip.f, nil, "fallback JSON stripped function")
end)

-- ===========================================================================
-- Test 10: lib/crypto.lua (FIPS SHA-256, RFC HMAC-SHA256, Authenticated Seal/Open)
-- ===========================================================================
run_test("lib/crypto.lua passes FIPS SHA-256, RFC HMAC-SHA256, and rejects tampered/wrong-key frames", function()
  local world = mock_cc.new_world()
  local comp = world:new_computer({ id = 10, label = "crypto_test" })
  comp:write_vfs("/lib/crypto.lua", SRC_CRYPTO)
  local crypto = comp.env.require("lib.crypto")

  -- Standard FIPS 180-4 SHA-256 vectors
  assert_eq(
    crypto.sha256_hex(""),
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "SHA-256 empty string"
  )
  assert_eq(
    crypto.sha256_hex("abc"),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    "SHA-256 'abc'"
  )

  -- Standard RFC 2104 HMAC-SHA256 vector
  assert_eq(
    crypto.hmac_sha256_hex("key", "The quick brown fox jumps over the lazy dog"),
    "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8",
    "HMAC-SHA256 RFC vector"
  )

  -- Authenticated encryption round-trip + tamper/wrong-key/wrong-AAD rejection
  local key = crypto.random_hex(32, "test_seed")
  assert_eq(#key, 64, "256-bit hex key length")
  local env, err = crypto.seal(key, '{"hello":"nether","count":42}', "main:44123")
  assert_eq(err, nil, "seal succeeded")
  assert_eq(env.v, 1, "envelope version 1")

  local pt, oerr = crypto.open(key, env, "main:44123")
  assert_eq(oerr, nil, "open succeeded")
  assert_eq(pt, '{"hello":"nether","count":42}', "decrypted plaintext matches")

  -- Wrong key fails
  local bad_pt, bad_err = crypto.open("wrong_key_0000", env, "main:44123")
  assert_eq(bad_pt, nil, "wrong key rejected")
  assert_contains(bad_err, "authentication failed", "wrong key error message")

  -- Wrong AAD fails
  local aad_pt = crypto.open(key, env, "main:99999")
  assert_eq(aad_pt, nil, "wrong channel/mesh AAD rejected")

  -- Tampered ciphertext fails
  local tampered = { v = env.v, n = env.n, t = env.t, c = (env.c:sub(1, 2) == "00" and "ff" or "00") .. env.c:sub(3) }
  local t_pt = crypto.open(key, tampered, "main:44123")
  assert_eq(t_pt, nil, "tampered ciphertext rejected")
end)

-- ===========================================================================
-- Test 11: lib/mesh.lua Encrypted Multi-Subnet Relay (farm PC -> main bridge -> nether bridge -> storage_0)
-- ===========================================================================
run_test("lib/mesh.lua proxies net.main_nether.storage_0.list() across dual-homed wired<->ender bridges with encryption", function()
  local world = mock_cc.new_world()
  local MESH_CH = 42777
  local MESH_KEY = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

  -- 1. Compute-farm PC on 'main' (ONLY wired modem on wired_main — NO ender modem!)
  local farm_pc = world:new_computer({ id = 101, label = "farm_pc_1" })
  farm_pc:write_vfs("/lib/std.lua", SRC_STD)
  farm_pc:write_vfs("/lib/crypto.lua", SRC_CRYPTO)
  farm_pc:write_vfs("/lib/mesh.lua", SRC_MESH)
  world:attach_bus_modem(farm_pc, "left", "wired_main", false)

  -- 2. Dual-homed bridge on 'main' (wired_main + ender_global)
  local main_bridge = world:new_computer({ id = 102, label = "bridge_main" })
  main_bridge:write_vfs("/lib/std.lua", SRC_STD)
  main_bridge:write_vfs("/lib/crypto.lua", SRC_CRYPTO)
  main_bridge:write_vfs("/lib/mesh.lua", SRC_MESH)
  main_bridge:write_vfs("/.mesh_net.json", mock_cc.json_encode({
    mesh_name = "main", subnet = "main", role = "bridge", channel = MESH_CH, key = MESH_KEY, ttl = 4,
  }))
  world:attach_bus_modem(main_bridge, "left", "wired_main", false)
  world:attach_bus_modem(main_bridge, "bottom", "ender_global", true)

  -- 3. Remote Nether bridge on 'main_nether' (ender_global + local storage_0 peripheral)
  local nether_bridge = world:new_computer({ id = 103, label = "bridge_main_nether" })
  nether_bridge:write_vfs("/lib/std.lua", SRC_STD)
  nether_bridge:write_vfs("/lib/crypto.lua", SRC_CRYPTO)
  nether_bridge:write_vfs("/lib/mesh.lua", SRC_MESH)
  nether_bridge:write_vfs("/.mesh_net.json", mock_cc.json_encode({
    mesh_name = "main", subnet = "main_nether", role = "bridge", channel = MESH_CH, key = MESH_KEY, ttl = 4,
  }))
  world:attach_bus_modem(nether_bridge, "bottom", "ender_global", true)
  local storage_calls = 0
  nether_bridge:attach_peripheral("storage_0", { "minecraft:chest", "inventory" }, {
    list = function()
      storage_calls = storage_calls + 1
      return {
        [1] = { name = "minecraft:ancient_debris", count = 12 },
        [2] = { name = "minecraft:blaze_rod", count = 64 },
      }
    end,
    getDimensions = function()
      return 27, 9
    end,
  })

  -- Start both subnet bridges
  main_bridge:start_daemon(SRC_SUBNET_BRIDGE, "subnet_bridge_main.lua")
  nether_bridge:start_daemon(SRC_SUBNET_BRIDGE, "subnet_bridge_nether.lua")
  world:pump()

  -- From farm_pc_1 (wired-only!), discover mesh & invoke net.main_nether.storage_0.list()!
  local rpc_result = farm_pc:run_script([[
    local mesh = require("lib.mesh")
    local net = mesh.connect({
      mesh_name = "main",
      subnet = "main",
      channel = 42777,
      key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      timeout = 1.0,
    })
    local topo = net._discover(0.2)
    local items = net.main_nether.storage_0.list()
    local w, h = net.main_nether.storage_0.getDimensions()
    local ptype = net.main_nether.storage_0.getType()
    return { topo = topo, items = items, w = w, h = h, ptype = ptype }
  ]], "farm_client.lua")

  assert_true(rpc_result.topo.main_nether ~= nil, "discovered main_nether across dual-homed relay")
  assert_true(rpc_result.topo.main_nether.peripherals.storage_0 ~= nil, "discovered storage_0 on main_nether")
  assert_eq(rpc_result.items[1].name, "minecraft:ancient_debris", "remote list() item 1")
  assert_eq(rpc_result.items[1].count, 12, "remote list() item 1 count")
  assert_eq(rpc_result.items[2].name, "minecraft:blaze_rod", "remote list() item 2")
  assert_eq(rpc_result.w, 27, "multi-return value 1")
  assert_eq(rpc_result.h, 9, "multi-return value 2")
  assert_eq(rpc_result.ptype, "minecraft:chest", "remote getType()")
  assert_eq(storage_calls, 1, "storage_0.list() executed once")

  -- Attacker on ender_global with wrong key MUST fail and NOT execute storage_0.list()
  local attacker = world:new_computer({ id = 199, label = "attacker" })
  attacker:write_vfs("/lib/std.lua", SRC_STD)
  attacker:write_vfs("/lib/crypto.lua", SRC_CRYPTO)
  attacker:write_vfs("/lib/mesh.lua", SRC_MESH)
  world:attach_bus_modem(attacker, "bottom", "ender_global", true)

  local att_ok = pcall(function()
    attacker:run_script([[
      local mesh = require("lib.mesh")
      local net = mesh.connect({
        mesh_name = "main",
        subnet = "evil",
        channel = 42777,
        key = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        timeout = 0.15,
      })
      net.main_nether.storage_0.list()
    ]], "attacker.lua")
  end)
  assert_eq(att_ok, false, "wrong-key attacker RPC rejected/timed out")
  assert_eq(storage_calls, 1, "attacker did NOT invoke storage_0.list()")

  -- Channel scanner skips busy channel 22222 and picks quiet channel 33333
  local scanner = world:new_computer({ id = 104, label = "scanner" })
  scanner:write_vfs("/lib/std.lua", SRC_STD)
  scanner:write_vfs("/lib/crypto.lua", SRC_CRYPTO)
  scanner:write_vfs("/lib/mesh.lua", SRC_MESH)
  world:attach_bus_modem(scanner, "bottom", "scan_bus", true)
  -- Pre-queue foreign traffic on channel 22222
  scanner:queue_event("modem_message", "bottom", 22222, 22222, "foreign_noise", 10)
  local chosen_ch = scanner:run_script([[
    local mesh = require("lib.mesh")
    local ch, quiet = mesh.scan_quiet_channel({
      candidates = { 22222, 33333 },
      listen_s = 0.1,
    })
    return { ch = ch, quiet = quiet }
  ]], "scan_test.lua")
  assert_eq(chosen_ch.ch, 33333, "skipped busy channel 22222 and selected quiet 33333")
  assert_eq(chosen_ch.quiet, true, "selected channel confirmed quiet")
end)

-- ===========================================================================
-- Test 12: apps/mesh_setup.lua Floppy Disk Installer + Remote Nether Subnet Join
-- ===========================================================================
run_test("apps/mesh_setup.lua generates encrypted floppy installer and joins remote main_nether subnet", function()
  local world = mock_cc.new_world()
  local main_pc = world:new_computer({ id = 201, label = "main_admin" })
  main_pc:write_vfs("/lib/std.lua", SRC_STD)
  main_pc:write_vfs("/lib/crypto.lua", SRC_CRYPTO)
  main_pc:write_vfs("/lib/mesh.lua", SRC_MESH)
  main_pc:write_vfs("/subnet_bridge.lua", SRC_SUBNET_BRIDGE)
  world:attach_bus_modem(main_pc, "bottom", "ender_setup", true)

  local disk_label = nil
  main_pc:attach_peripheral("right", { "drive" }, {
    isDiskPresent = function() return true end,
    hasData = function() return true end,
    getMountPath = function() return "disk" end,
    getDiskLabel = function() return disk_label end,
    setDiskLabel = function(lbl) disk_label = lbl end,
  })

  -- Run mesh_setup on 'main' to generate randomized channel + 256-bit key + floppy installer
  local setup_cfg = main_pc:run_script(
    SRC_MESH_SETUP, "mesh_setup.lua",
    "--mesh", "main",
    "--subnet", "main",
    "--drive", "right",
    "--listen", "0",
    "--non-interactive"
  )

  assert_eq(setup_cfg.mesh_name, "main", "mesh_name saved")
  assert_true(setup_cfg.channel >= 10000 and setup_cfg.channel <= 65000, "randomized channel in 10000..65000")
  assert_eq(#setup_cfg.key, 64, "64-hex-char 256-bit key generated")
  assert_eq(disk_label, "CC-Mesh Join (main)", "floppy disk labeled")
  assert_true(main_pc:read_vfs("/disk/install.lua") ~= nil, "floppy install.lua created")
  assert_true(main_pc:read_vfs("/disk/startup.lua") ~= nil, "floppy startup.lua created")
  assert_true(main_pc:read_vfs("/disk/mesh_join.json") ~= nil, "floppy mesh_join.json created")
  assert_true(main_pc:read_vfs("/disk/payload/lib/crypto.lua") ~= nil, "floppy payload crypto.lua copied")
  assert_true(main_pc:read_vfs("/disk/payload/lib/mesh.lua") ~= nil, "floppy payload mesh.lua copied")
  assert_true(main_pc:read_vfs("/disk/payload/subnet_bridge.lua") ~= nil, "floppy payload subnet_bridge.lua copied")

  -- Move floppy to a brand-new Nether computer and run /disk/install.lua
  local nether_pc = world:new_computer({ id = 202, label = nil })
  for path, content in pairs(main_pc.vfs_files) do
    if path:sub(1, 5) == "disk/" then
      nether_pc:write_vfs("/" .. path, content)
    end
  end
  -- Ensure shell.getRunningProgram returns "disk/install.lua"
  nether_pc.env.shell.getRunningProgram = function() return "disk/install.lua" end

  nether_pc:run_script(
    nether_pc:read_vfs("/disk/install.lua"), "disk/install.lua",
    "--subnet", "main_nether",
    "--role", "bridge",
    "--no-start"
  )

  local nether_cfg = mock_cc.json_decode(nether_pc:read_vfs("/.mesh_net.json"))
  assert_eq(nether_cfg.mesh_name, "main", "nether joined mesh 'main'")
  assert_eq(nether_cfg.subnet, "main_nether", "nether subnet set to 'main_nether'")
  assert_eq(nether_cfg.channel, setup_cfg.channel, "nether inherited exact randomized channel")
  assert_eq(nether_cfg.key, setup_cfg.key, "nether inherited exact encryption key")
  assert_eq(nether_cfg.role, "bridge", "nether role set to bridge")
  assert_true(nether_pc:read_vfs("/lib/crypto.lua") ~= nil, "nether installed /lib/crypto.lua")
  assert_true(nether_pc:read_vfs("/lib/mesh.lua") ~= nil, "nether installed /lib/mesh.lua")
  assert_true(nether_pc:read_vfs("/subnet_bridge.lua") ~= nil, "nether installed /subnet_bridge.lua")
  assert_contains(nether_pc:read_vfs("/startup.lua"), "subnet_bridge.lua", "nether /startup.lua auto-starts bridge")
end)

-- ===========================================================================
-- Summary & Exit Code
-- ===========================================================================
print(string.format("\nLua Suite Summary: %d/%d passed, %d failed", passed_tests, total_tests, #failed_tests))
if #failed_tests > 0 then
  for i = 1, #failed_tests do
    print(string.format("  FAILURE %d: %s -> %s", i, failed_tests[i].name, failed_tests[i].err))
  end
  error("Lua test suite failed (" .. tostring(#failed_tests) .. " failures)", 0)
end
