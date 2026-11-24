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

local function format_print_args(...)
  local n = select("#", ...)
  local parts = {}
  for i = 1, n do
    parts[i] = tostring(select(i, ...))
  end
  return table.concat(parts, "\t")
end

local function execute_local_task(lua_code, task_args)
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
  local pending_rpc = {}
  local active_tasks = 0
  local has_pending_work = false
  local poll_in_flight = false
  local wake_during_poll = false

  local function register_runner(id, r_label)
    if not id then
      return
    end
    runner_by_name[tostring(id)] = id
    if type(r_label) == "string" and r_label ~= "" then
      runner_by_name[r_label] = id
    end
  end

  local function is_local_target(target_node)
    if target_node == nil or target_node == "" or target_node == "gateway" then
      return true
    end
    if target_node == label or target_node == tostring(computer_id) then
      return true
    end
    return false
  end

  -- Initial topology probe & sync
  local topo = std.probe_network(probe_timeout)
  for i = 1, #topo.runners do
    local r = topo.runners[i]
    register_runner(r.id, r.label)
  end

  send_ws(ws, {
    type = "SYNC_TOPOLOGY",
    net_id = net_id,
    world = world,
    label = label,
    entities = topo.entities,
    timestamp = now_ms(),
  })

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
    local ev, p1, p2, p3 = os.pullEvent()

    if ev == "redstone" then
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

    elseif ev == "peripheral" and type(p1) == "string" then
      if is_modem(p1) then
        pcall(rednet.open, p1)
      else
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
                local ok, stdout, result, err = execute_local_task(task.lua_code, task.args)
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
                local runner_id = runner_by_name[target_key] or tonumber(target_key)
                if runner_id and type(rednet) == "table" then
                  active_tasks = active_tasks + 1
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
            register_runner(tonumber(msg.id) or sender_id, msg.label)
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
