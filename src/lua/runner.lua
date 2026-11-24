-- cc-mesh-bridge Worker Daemon (/runner.lua)
-- Listens on Rednet protocol "mcp_rpc" for DISCOVER and EXEC_TASK messages,
-- executing Lua payloads inside a sandboxed _ENV with lib.std preloaded.

local std = require("lib.std")

local RPC_PROTOCOL = "mcp_rpc"

local function format_print_args(...)
  local n = select("#", ...)
  local parts = {}
  for i = 1, n do
    parts[i] = tostring(select(i, ...))
  end
  return table.concat(parts, "\t")
end

local function execute_sandboxed(lua_code, task_args)
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

  local fn, compile_err = load(tostring(lua_code or ""), "task", "t", env)
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

local function get_node_label()
  local lbl = type(os.getComputerLabel) == "function" and os.getComputerLabel() or nil
  if type(lbl) == "string" and lbl ~= "" then
    return lbl
  end
  local prefix = (turtle ~= nil) and "turtle_" or "runner_"
  return prefix .. tostring(os.getComputerID())
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

local function main()
  std.open_all_modems()
  local label = get_node_label()
  print("[runner] Started " .. label .. " (ID " .. tostring(os.getComputerID()) .. ")")

  -- Proactively announce presence to any already-running gateway on boot
  pcall(rednet.broadcast, {
    type = "HERE",
    id = os.getComputerID(),
    label = label,
    is_turtle = (turtle ~= nil),
  }, RPC_PROTOCOL)

  while true do
    local ev, p1, p2, p3 = os.pullEvent()
    if ev == "peripheral" and type(p1) == "string" and is_modem(p1) then
      pcall(rednet.open, p1)
    elseif ev == "rednet_message" and p3 == RPC_PROTOCOL and type(p2) == "table" then
      local sender_id = p1
      local msg = p2

      if msg.type == "DISCOVER" then
        rednet.send(sender_id, {
          type = "HERE",
          id = os.getComputerID(),
          label = get_node_label(),
          is_turtle = (turtle ~= nil),
        }, RPC_PROTOCOL)
      elseif msg.type == "EXEC_TASK" and msg.task_id then
        local ok, stdout, result, err = execute_sandboxed(msg.lua_code, msg.args)
        rednet.send(sender_id, {
          type = "TASK_RESULT",
          task_id = msg.task_id,
          ok = ok,
          stdout = stdout,
          result = result,
          error = err,
        }, RPC_PROTOCOL)
      end
    end
  end
end

main()
