-- cc-mesh-bridge Hub Daemon (/gateway.lua)
-- Maintains a hibernating WebSocket connection to the Cloudflare Durable Object,
-- handles interrupt-driven redstone-clock queue polling, hot-plug peripheral probing,
-- local sandboxed execution, and Rednet RPC / PubSub bridging.

local std = require("lib.std")

local RPC_PROTOCOL = "mcp_rpc"
local PUBSUB_PROTOCOL = "mcp_pubsub"

local function read_setting(primary, fallback, default_val)
  if type(settings) == "table" and type(settings.get) == "function" then
    local v = settings.get(primary)
    if v ~= nil then
      return v
    end
    if fallback then
      v = settings.get(fallback)
      if v ~= nil then
        return v
      end
    end
  end
  return default_val
end

local function now_ms()
  if type(os) == "table" and type(os.epoch) == "function" then
    return os.epoch("utc")
  end
  return 0
end

local function url_encode(str)
  local s = tostring(str or "")
  if type(textutils) == "table" and type(textutils.urlEncode) == "function" then
    return textutils.urlEncode(s)
  end
  return (s:gsub("([^%w%-_%.~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

local function http_to_ws_url(base_url)
  if base_url:sub(1, 8) == "https://" then
    return "wss://" .. base_url:sub(9)
  elseif base_url:sub(1, 7) == "http://" then
    return "ws://" .. base_url:sub(8)
  elseif base_url:sub(1, 6) == "wss://" or base_url:sub(1, 5) == "ws://" then
    return base_url
  end
  return "wss://" .. base_url
end

local function is_modem(name)
  if type(peripheral) ~= "table" or type(peripheral.getType) ~= "function" then
    return false
  end
  local types = { peripheral.getType(name) }
  for i = 1, #types do
    if types[i] == "modem" then
      return true
    end
  end
  return false
end

local RUNNER_DISK_LABEL = "CC-Mesh Runner Installer"

local DISK_INSTALLER_STARTUP = [[-- CC-Mesh Auto-Runner Installer Floppy
-- Safety guard: NEVER hijack a gateway/bridge computer!
local role = (type(settings) == "table" and (settings.get("mcp.role") or settings.get("cc_mesh.role"))) or ""
if role == "gateway" then
  if fs.exists("/startup.lua") then
    return shell.run("/startup.lua")
  end
  return
end

local running = (type(shell) == "table" and type(shell.getRunningProgram) == "function")
  and shell.getRunningProgram()
  or "disk/startup.lua"
local disk_dir = "/" .. fs.getDir(running)

local function copy_file(src, dst)
  if not fs.exists(src) then return false end
  local d = fs.getDir(dst)
  if d ~= "" and not fs.exists(d) then fs.makeDir(d) end
  if fs.exists(dst) then fs.delete(dst) end
  fs.copy(src, dst)
  return true
end

print("[cc-mesh] Installing runner from " .. disk_dir .. "...")
copy_file(fs.combine(disk_dir, "payload/lib/std.lua"), "/lib/std.lua")
copy_file(fs.combine(disk_dir, "payload/runner.lua"), "/runner.lua")
copy_file(fs.combine(disk_dir, "payload/pkg.lua"), "/pkg.lua")
copy_file(fs.combine(disk_dir, "payload/bootstrap.lua"), "/startup.lua")

local cfg_path = fs.combine(disk_dir, "mesh_config.json")
if fs.exists(cfg_path) then
  local f = fs.open(cfg_path, "r")
  if f then
    local cfg = textutils.unserialiseJSON(f.readAll() or "")
    f.close()
    if type(cfg) == "table" and type(settings) == "table" then
      if type(cfg.url) == "string" and cfg.url ~= "" then settings.set("mcp.url", cfg.url) end
      if type(cfg.cf_id) == "string" and cfg.cf_id ~= "" then settings.set("mcp.cf_id", cfg.cf_id) end
      if type(cfg.cf_secret) == "string" and cfg.cf_secret ~= "" then settings.set("mcp.cf_secret", cfg.cf_secret) end
      if type(cfg.world) == "string" and cfg.world ~= "" then settings.set("mcp.world", cfg.world) end
      if type(cfg.net) == "string" and cfg.net ~= "" then settings.set("mcp.net", cfg.net) end
    end
  end
end

if type(settings) == "table" then
  settings.set("mcp.role", "runner")
  settings.save()
end

if type(os.getComputerLabel) == "function" and not os.getComputerLabel() and type(os.setComputerLabel) == "function" then
  local prefix = (turtle ~= nil) and "turtle_" or "runner_"
  os.setComputerLabel(prefix .. tostring(os.getComputerID()))
end

print("[cc-mesh] Runner installed! Starting /runner.lua...")
if fs.exists("/runner.lua") then
  shell.run("/runner.lua")
elseif fs.exists("/startup.lua") then
  shell.run("/startup.lua")
end
]]

local function copy_to_disk(src, dst)
  if type(fs) ~= "table" or not fs.exists(src) then
    return false
  end
  local dir = fs.getDir(dst)
  if dir and dir ~= "" and not fs.exists(dir) then
    fs.makeDir(dir)
  end
  local rf = fs.open(src, "r")
  if not rf then return false end
  local data = rf.readAll()
  rf.close()
  local wf = fs.open(dst, "w")
  if not wf then return false end
  wf.write(data or "")
  wf.close()
  return true
end

local function provision_runner_disk(drive_name, cfg)
  if type(peripheral) ~= "table" or type(fs) ~= "table" then
    return false
  end
  if peripheral.getType(drive_name) ~= "drive" then
    return false
  end
  local ok_pres, present = pcall(peripheral.call, drive_name, "isDiskPresent")
  local ok_data, has_data = pcall(peripheral.call, drive_name, "hasData")
  if not (ok_pres and present and ok_data and has_data) then
    return false
  end
  local ok_mp, mount_path = pcall(peripheral.call, drive_name, "getMountPath")
  if not (ok_mp and type(mount_path) == "string" and mount_path ~= "") then
    return false
  end
  local ok_lbl, disk_label = pcall(peripheral.call, drive_name, "getDiskLabel")
  local root = "/" .. mount_path:gsub("^/+", "")
  local existing = fs.exists(root) and fs.list(root) or {}

  -- Safety: only write to empty disks or disks already labeled as our Runner Installer
  if #existing > 0 and (not ok_lbl or disk_label ~= RUNNER_DISK_LABEL) then
    return false
  end

  -- Need runner payload present on gateway
  if not fs.exists("/runner.lua") or not fs.exists("/lib/std.lua") then
    return false
  end

  copy_to_disk("/lib/std.lua", fs.combine(root, "payload/lib/std.lua"))
  copy_to_disk("/runner.lua", fs.combine(root, "payload/runner.lua"))
  copy_to_disk("/pkg.lua", fs.combine(root, "payload/pkg.lua"))
  copy_to_disk("/startup.lua", fs.combine(root, "payload/bootstrap.lua"))

  local wf = fs.open(fs.combine(root, "startup.lua"), "w")
  if wf then
    wf.write(DISK_INSTALLER_STARTUP)
    wf.close()
  end

  local cfg_payload = std.serialize_json({
    url = cfg.url or "",
    cf_id = cfg.cf_id or "",
    cf_secret = cfg.cf_secret or "",
    world = cfg.world or "overworld",
    net = cfg.net_id or "main",
  })
  local cf = fs.open(fs.combine(root, "mesh_config.json"), "w")
  if cf then
    cf.write(cfg_payload)
    cf.close()
  end

  pcall(peripheral.call, drive_name, "setDiskLabel", RUNNER_DISK_LABEL)
  print("[gateway] Provisioned runner installer floppy on " .. drive_name .. " (" .. root .. ")")
  return true
end

local function provision_all_runner_disks(cfg)
  if read_setting("mcp.auto_provision_disk", "cc_mesh.auto_provision_disk", true) == false then
    return 0
  end
  if type(peripheral) ~= "table" or type(peripheral.getNames) ~= "function" then
    return 0
  end
  local count = 0
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "drive" then
      if provision_runner_disk(name, cfg) then
        count = count + 1
      end
    end
  end
  return count
end

local function format_print_args(...)
  local n = select("#", ...)
  local parts = {}
  for i = 1, n do
    parts[i] = tostring(select(i, ...))
  end
  return table.concat(parts, "\t")
end

local function execute_local_task(lua_code, task_args, extra_globals)
  local stdout_lines = {}
  local function captured_print(...)
    stdout_lines[#stdout_lines + 1] = format_print_args(...)
  end

  local env = {
    std = std,
    args = type(task_args) == "table" and task_args or {},
    print = captured_print,
    require = require,
  }
  if type(extra_globals) == "table" then
    for k, v in pairs(extra_globals) do
      env[k] = v
    end
  end
  setmetatable(env, { __index = _G })

  local fn, compile_err = load(tostring(lua_code or ""), "gateway_task", "t", env)
  if not fn then
    return false, table.concat(stdout_lines, "\n"), nil, "Compile error: " .. tostring(compile_err)
  end

  local err_handler = function(err)
    if type(debug) == "table" and type(debug.traceback) == "function" then
      return debug.traceback(tostring(err), 2)
    end
    return tostring(err)
  end

  local ok, res = xpcall(fn, err_handler)
  local stdout = table.concat(stdout_lines, "\n")
  if ok then
    return true, stdout, std.sanitize_for_json(res), nil
  else
    return false, stdout, nil, tostring(res)
  end
end

local function send_ws(ws, payload)
  local encoded = std.serialize_json(payload)
  local ok, err = pcall(ws.send, encoded)
  if not ok then
    print("[gateway] ws.send failed: " .. tostring(err))
    return false
  end
  return true
end

local function run_session(ws, ws_url, cfg, computer_id, label)
  local net_id = cfg.net_id or "main"
  local world = cfg.world or "default"
  local clock_side = cfg.clock_side or "back"
  local max_concurrency = tonumber(read_setting("mcp.max_concurrency", "cc_mesh.max_concurrency", 4)) or 4
  local fallback_interval = tonumber(read_setting("mcp.fallback_poll_interval", "cc_mesh.fallback_poll_interval", 300)) or 300
  local probe_timeout = tonumber(read_setting("mcp.probe_timeout", "cc_mesh.probe_timeout", 0.5)) or 0.5

  local runner_by_name = {}
  local known_runners = {}
  local runner_load = {}
  local pending_rpc = {}
  local active_tasks = 0
  local has_pending_work = false
  local poll_in_flight = false
  local wake_during_poll = false

  local function register_runner(id, r_label, is_turtle, announce, pool_name)
    if not id then
      return
    end
    local is_new = known_runners[id] == nil
    local pool = (type(pool_name) == "string" and pool_name ~= "")
      and pool_name
      or ((is_turtle == true) and "turtle" or "compute")
    known_runners[id] = {
      id = id,
      label = r_label or tostring(id),
      is_turtle = is_turtle == true,
      pool = pool,
    }
    runner_load[id] = runner_load[id] or 0
    runner_by_name[tostring(id)] = id
    if type(r_label) == "string" and r_label ~= "" then
      runner_by_name[r_label] = id
    end
    if announce and is_new then
      local r_name = (type(r_label) == "string" and r_label ~= "") and r_label or tostring(id)
      send_ws(ws, {
        type = "PERIPHERAL_ATTACHED",
        net_id = net_id,
        name = r_name,
        kind = (is_turtle == true) and "turtle" or "runner",
        type_name = (is_turtle == true) and "turtle" or "computer",
        methods = { "run_lua", "fs_read", "fs_write" },
        timestamp = now_ms(),
      })
      print("[gateway] Runner joined: " .. r_name .. " (#" .. tostring(id) .. ", pool=" .. pool .. ")")
    end
  end

  local function pick_pool_runner(pool_name)
    local best_id = nil
    local best_load = math.huge
    for id, info in pairs(known_runners) do
      if info.pool == pool_name or pool_name == "any" then
        local ld = runner_load[id] or 0
        if ld < best_load or (ld == best_load and (best_id == nil or id < best_id)) then
          best_load = ld
          best_id = id
        end
      end
    end
    return best_id
  end

  local function resolve_target_runner(target_key)
    if target_key == "compute" or target_key == "pool:compute" then
      return pick_pool_runner("compute")
    elseif target_key == "turtle" or target_key == "pool:turtle" then
      return pick_pool_runner("turtle")
    elseif target_key:sub(1, 5) == "pool:" then
      return pick_pool_runner(target_key:sub(6))
    end
    return runner_by_name[target_key] or tonumber(target_key)
  end

  -- Optional embedded encrypted multi-subnet mesh router (activates when /.mesh_net.json exists)
  local mesh_mod = nil
  local mesh_bridge = nil
  if type(fs) == "table" and fs.exists("/.mesh_net.json") then
    local ok_m, loaded_m = pcall(require, "lib.mesh")
    if ok_m and type(loaded_m) == "table" then
      mesh_mod = loaded_m
      local mcfg = mesh_mod.load_config()
      if mcfg and mcfg.channel and mcfg.key then
        local ok_b, handler = pcall(mesh_mod.create_bridge_handler, {
          mesh_name = mcfg.mesh_name,
          subnet = mcfg.subnet or net_id,
          role = "gateway",
          channel = mcfg.channel,
          key = mcfg.key,
          ttl = mcfg.ttl,
          on_event = function(kind, info)
            if kind == "announce" and type(info) == "table" and type(info.subnet) == "string" then
              for pname, pinfo in pairs(info.peripherals or {}) do
                local ptype = (type(pinfo) == "table" and pinfo.type) or "unknown"
                local pmethods = (type(pinfo) == "table" and pinfo.methods) or {}
                send_ws(ws, {
                  type = "PERIPHERAL_ATTACHED",
                  net_id = net_id,
                  name = info.subnet .. "." .. pname,
                  kind = (ptype == "drive") and "drive" or "peripheral",
                  type_name = ptype,
                  methods = pmethods,
                  probe = {
                    name = info.subnet .. "." .. pname,
                    subnet = info.subnet,
                    remote_name = pname,
                    type = ptype,
                    type_name = ptype,
                    types = (type(pinfo) == "table" and pinfo.types) or { ptype },
                    methods = pmethods,
                    present = true,
                    metadata = { bridged_via = info.subnet, bridge_id = info.bridge_id },
                  },
                  timestamp = now_ms(),
                })
              end
            end
          end,
        })
        if ok_b and handler then
          mesh_bridge = handler
        end
      end
    end
  end

  local cached_net = nil
  local function get_mesh_net()
    if not cached_net and mesh_mod and mesh_bridge then
      cached_net = mesh_mod.connect({
        mesh_name = mesh_bridge.config.mesh_name,
        subnet = mesh_bridge.subnet,
        channel = mesh_bridge.channel,
        key = mesh_bridge.config.key,
        ttl = mesh_bridge.config.ttl,
      })
    end
    return cached_net
  end

  local local_task_globals = {
    mesh = mesh_mod,
    net = setmetatable({}, {
      __index = function(_, k)
        local n = get_mesh_net()
        if not n then error("Encrypted mesh not configured on gateway", 2) end
        return n[k]
      end,
    }),
    cluster = function()
      local compute_list = {}
      for id, info in pairs(known_runners) do
        compute_list[#compute_list + 1] = {
          id = id,
          label = info.label,
          pool = info.pool,
          is_turtle = info.is_turtle,
          active_tasks = runner_load[id] or 0,
        }
      end
      return {
        orchestrator = { id = computer_id, label = label, world = world, net_id = net_id },
        mesh = mesh_bridge and {
          mesh_name = mesh_bridge.config.mesh_name,
          subnet = mesh_bridge.subnet,
          channel = mesh_bridge.channel,
          modems = mesh_bridge.modems,
        } or nil,
        remote_subnets = mesh_bridge and mesh_bridge.get_remote_subnets() or {},
        compute_pool = compute_list,
        storage_pool = mesh_bridge and mesh_bridge.get_storage_pool() or { drives = {}, inventories = {} },
      }
    end,
  }

  local function is_local_target(target_node)
    if target_node == nil or target_node == "" or target_node == "gateway" then
      return true
    end
    if target_node == label or target_node == tostring(computer_id) then
      return true
    end
    return false
  end

  -- Auto-provision any empty / CC-Mesh floppy disk on attached drives
  provision_all_runner_disks(cfg)

  -- Initial topology probe & sync
  local topo = std.probe_network(probe_timeout)
  for i = 1, #topo.runners do
    local r = topo.runners[i]
    register_runner(r.id, r.label, r.is_turtle, false)
  end

  send_ws(ws, {
    type = "SYNC_TOPOLOGY",
    net_id = net_id,
    world = world,
    label = label,
    entities = topo.entities,
    timestamp = now_ms(),
  })

  if mesh_bridge then
    mesh_bridge.announce()
    mesh_bridge.discover()
  end

  local prev_clock_high = (type(rs) == "table" and type(rs.getInput) == "function" and rs.getInput(clock_side)) and true or false
  local fallback_timer = os.startTimer(fallback_interval)

  local function trigger_poll()
    if active_tasks >= max_concurrency or poll_in_flight then
      return
    end
    poll_in_flight = true
    wake_during_poll = false
    send_ws(ws, {
      type = "POLL_QUEUE",
      net_id = net_id,
      capacity = max_concurrency - active_tasks,
    })
  end

  while true do
    local ev, p1, p2, p3, p4 = os.pullEvent()

    if ev == "modem_message" and mesh_bridge and p2 == mesh_bridge.channel then
      mesh_bridge.handle_event(ev, p1, p2, p3, p4)

    elseif ev == "redstone" then
      local high = (type(rs) == "table" and type(rs.getInput) == "function" and rs.getInput(clock_side)) and true or false
      local rising = high and (not prev_clock_high)
      prev_clock_high = high
      if rising and has_pending_work and active_tasks < max_concurrency then
        trigger_poll()
      end

    elseif ev == "timer" and p1 == fallback_timer then
      fallback_timer = os.startTimer(fallback_interval)
      poll_in_flight = false
      if active_tasks < max_concurrency then
        trigger_poll()
      end

    elseif ev == "disk" and type(p1) == "string" then
      provision_runner_disk(p1, cfg)

    elseif ev == "peripheral" and type(p1) == "string" then
      if mesh_bridge then
        mesh_bridge.handle_event(ev, p1)
      end
      if is_modem(p1) then
        pcall(rednet.open, p1)
      else
        if peripheral.getType(p1) == "drive" then
          provision_runner_disk(p1, cfg)
        end
        local api = std.get_api(p1)
        send_ws(ws, {
          type = "PERIPHERAL_ATTACHED",
          net_id = net_id,
          name = p1,
          kind = (api.type_name == "drive") and "drive" or "peripheral",
          type_name = api.type_name,
          methods = api.methods,
          probe = api,
          timestamp = now_ms(),
        })
      end

    elseif ev == "peripheral_detach" and type(p1) == "string" then
      if mesh_bridge then
        mesh_bridge.handle_event(ev, p1)
      end
      send_ws(ws, {
        type = "PERIPHERAL_DETACHED",
        net_id = net_id,
        name = p1,
        timestamp = now_ms(),
      })

    elseif ev == "websocket_message" and (p1 == ws_url or p1 == nil) then
      local msg = std.deserialize_json(p2)
      if type(msg) == "table" then
        if msg.type == "WAKE" then
          has_pending_work = true
          if poll_in_flight then
            wake_during_poll = true
          end

        elseif msg.type == "DISPATCH_BATCH" then
          poll_in_flight = false
          has_pending_work = (msg.has_more == true) or wake_during_poll
          wake_during_poll = false

          local tasks = type(msg.tasks) == "table" and msg.tasks or {}
          for i = 1, #tasks do
            local task = tasks[i]
            if type(task) == "table" and task.task_id then
              if is_local_target(task.target_node) then
                local started = now_ms()
                local ok, stdout, result, err = execute_local_task(task.lua_code, task.args, local_task_globals)
                send_ws(ws, {
                  type = "TASK_RESULT",
                  task_id = task.task_id,
                  net_id = net_id,
                  ok = ok,
                  stdout = stdout,
                  result = result,
                  error = err,
                  duration_ms = now_ms() - started,
                })
              else
                local target_key = tostring(task.target_node)
                local runner_id = resolve_target_runner(target_key)
                if runner_id and type(rednet) == "table" then
                  active_tasks = active_tasks + 1
                  runner_load[runner_id] = (runner_load[runner_id] or 0) + 1
                  pending_rpc[task.task_id] = {
                    runner_id = runner_id,
                    target_node = target_key,
                    started_at = now_ms(),
                  }
                  rednet.send(runner_id, {
                    type = "EXEC_TASK",
                    task_id = task.task_id,
                    lua_code = task.lua_code,
                    args = task.args or {},
                  }, RPC_PROTOCOL)
                else
                  send_ws(ws, {
                    type = "TASK_RESULT",
                    task_id = task.task_id,
                    net_id = net_id,
                    ok = false,
                    stdout = "",
                    error = "Target runner not found: " .. target_key,
                  })
                end
              end
            end
          end

        elseif msg.type == "EVENT" then
          if type(rednet) == "table" and type(rednet.broadcast) == "function" then
            pcall(rednet.broadcast, msg, PUBSUB_PROTOCOL)
          end

        elseif msg.type == "ERROR" then
          poll_in_flight = false
          print("[gateway] Server error: " .. tostring(msg.message or msg.code or "unknown"))
        end
      end

    elseif ev == "rednet_message" then
      local sender_id = p1
      local msg = p2
      local protocol = p3
      if type(msg) == "table" then
        if protocol == RPC_PROTOCOL then
          if msg.type == "TASK_RESULT" and msg.task_id then
            local info = pending_rpc[msg.task_id]
            local duration_ms = nil
            if info then
              pending_rpc[msg.task_id] = nil
              active_tasks = math.max(0, active_tasks - 1)
              if info.runner_id and runner_load[info.runner_id] then
                runner_load[info.runner_id] = math.max(0, runner_load[info.runner_id] - 1)
              end
              duration_ms = now_ms() - info.started_at
            end
            send_ws(ws, {
              type = "TASK_RESULT",
              task_id = msg.task_id,
              net_id = net_id,
              ok = msg.ok == true,
              stdout = msg.stdout or "",
              result = msg.result,
              error = msg.error,
              duration_ms = duration_ms,
            })
          elseif msg.type == "HERE" then
            register_runner(tonumber(msg.id) or sender_id, msg.label, msg.is_turtle == true, true, msg.pool)
          end
        elseif protocol == PUBSUB_PROTOCOL then
          if msg.type == "PUB" or msg.type == "SUB" or msg.type == "UNSUB" or msg.type == "KV_SET" or msg.type == "KV_GET" then
            send_ws(ws, msg)
          end
        end
      end

    elseif ev == "websocket_closed" and (p1 == ws_url or p1 == nil) then
      print("[gateway] WebSocket closed")
      pcall(ws.close)
      return
    end
  end
end

local function main()
  local cfg = std.get_config()
  if type(cfg.url) ~= "string" or cfg.url == "" then
    error("[gateway] Missing mcp.url (or cc_mesh.url) setting")
  end

  local computer_id = type(os.getComputerID) == "function" and os.getComputerID() or 0
  local label = (type(os.getComputerLabel) == "function" and os.getComputerLabel())
    or ("gateway_" .. tostring(computer_id))
  local client_id = tostring(read_setting("mcp.client_id", "cc_mesh.client_id", label .. "_" .. tostring(computer_id)))
  local max_reconnects = read_setting("mcp.max_reconnects", "cc_mesh.max_reconnects", nil)

  local ws_base = http_to_ws_url(cfg.url)
  local ws_url = ws_base
    .. "/ws?role=gateway"
    .. "&world=" .. url_encode(cfg.world or "default")
    .. "&net=" .. url_encode(cfg.net_id or "main")
    .. "&client_id=" .. url_encode(client_id)
    .. "&label=" .. url_encode(label)

  std.open_all_modems()

  local backoff = 2
  local attempts = 0

  while true do
    print("[gateway] Connecting to " .. ws_url)
    local ws, err = http.websocket(ws_url, cfg.headers)
    if ws then
      backoff = 2
      print("[gateway] Connected")
      run_session(ws, ws_url, cfg, computer_id, label)
    else
      print("[gateway] Connection failed: " .. tostring(err))
    end

    if max_reconnects ~= nil and attempts >= max_reconnects then
      return
    end
    attempts = attempts + 1
    print("[gateway] Reconnecting in " .. tostring(backoff) .. "s...")
    if type(sleep) == "function" then
      sleep(backoff)
    end
    backoff = math.min(backoff * 2, 30)
  end
end

main()
