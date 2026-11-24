-- cc-mesh-bridge Static App: Network & Peripheral Diagnostics (/lua/apps/net_diag.lua)
-- Usage:
--   net_diag [--json] [--timeout <sec>]

local std = require("lib.std")

local cli_args = { ... }

local function parse_args(args)
  local opts = {
    as_json = false,
    timeout = 0.5,
  }
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--json" then
      opts.as_json = true
      i = i + 1
    elseif a == "--timeout" and args[i + 1] then
      opts.timeout = tonumber(args[i + 1]) or 0.5
      i = i + 2
    else
      i = i + 1
    end
  end
  return opts
end

local function count_keys(tbl)
  local n = 0
  if type(tbl) == "table" then
    for _ in pairs(tbl) do
      n = n + 1
    end
  end
  return n
end

local function main()
  local opts = parse_args(cli_args)
  local topo = std.probe_network(opts.timeout)

  local apis = {}
  for i = 1, #topo.peripherals do
    local p = topo.peripherals[i]
    apis[#apis + 1] = std.get_api(p.name)
  end

  local report = {
    computer_id = topo.computer_id,
    label = topo.label,
    is_turtle = topo.is_turtle,
    peripherals = apis,
    runners = topo.runners,
    entity_count = #topo.entities,
  }

  if opts.as_json then
    print(std.serialize_json(report))
    return report
  end

  print("=== CC Mesh Network Diagnostics ===")
  print(string.format("Host: %s (ID %s, turtle=%s)", tostring(report.label), tostring(report.computer_id), tostring(report.is_turtle)))
  print(string.format("Peripherals (%d):", #apis))
  for i = 1, #apis do
    local api = apis[i]
    print(string.format(
      "  - %s [%s] (%d methods, %d probe fields)",
      api.name,
      table.concat(api.types, ", "),
      #api.methods,
      count_keys(api.metadata)
    ))
  end

  print(string.format("Rednet Peers (%d):", #report.runners))
  for i = 1, #report.runners do
    local r = report.runners[i]
    print(string.format("  - %s (ID %s, turtle=%s)", tostring(r.label), tostring(r.id), tostring(r.is_turtle)))
  end

  return report
end

return main()
