-- cc-mesh-bridge Static App: Live Inventory Monitor (/lua/apps/inv_mon.lua)
-- Usage:
--   inv_mon [--mod <mod>] [--name <pattern>] [--tag <tag>] [--min <n>]
--           [--peripheral <name>] [--interval <sec>] [--once] [--term]

local std = require("lib.std")

local cli_args = { ... }

local function parse_args(args)
  local opts = {
    interval = 5,
    once = false,
    use_term = false,
  }
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--mod" and args[i + 1] then
      opts.mod = args[i + 1]
      i = i + 2
    elseif a == "--name" and args[i + 1] then
      opts.name = args[i + 1]
      i = i + 2
    elseif a == "--tag" and args[i + 1] then
      opts.tag = args[i + 1]
      i = i + 2
    elseif a == "--min" and args[i + 1] then
      opts.min_count = tonumber(args[i + 1])
      i = i + 2
    elseif a == "--peripheral" and args[i + 1] then
      opts.peripheral = args[i + 1]
      i = i + 2
    elseif a == "--interval" and args[i + 1] then
      opts.interval = tonumber(args[i + 1]) or 5
      i = i + 2
    elseif a == "--once" then
      opts.once = true
      i = i + 1
    elseif a == "--term" then
      opts.use_term = true
      i = i + 1
    else
      i = i + 1
    end
  end
  return opts
end

local function select_display(use_term)
  if not use_term and type(peripheral) == "table" and type(peripheral.wrap) == "function" then
    local monitors = std.list_attachment("monitor")
    if #monitors > 0 then
      local mon = peripheral.wrap(monitors[1].name)
      if mon and type(mon.write) == "function" then
        return mon, monitors[1].name
      end
    end
  end
  return term, "term"
end

local function render(display, report, opts)
  local lines = {}
  local filter_parts = {}
  if opts.mod then filter_parts[#filter_parts + 1] = "mod=" .. opts.mod end
  if opts.name then filter_parts[#filter_parts + 1] = "name=" .. opts.name end
  if opts.tag then filter_parts[#filter_parts + 1] = "tag=" .. opts.tag end
  if opts.min_count then filter_parts[#filter_parts + 1] = "min=" .. tostring(opts.min_count) end

  local header = "=== Inventory Monitor"
  if #filter_parts > 0 then
    header = header .. " [" .. table.concat(filter_parts, ", ") .. "]"
  end
  header = header .. " ==="
  lines[#lines + 1] = header

  if #report.items == 0 then
    lines[#lines + 1] = "(no matching items)"
  else
    for i = 1, #report.items do
      local item = report.items[i]
      local label = item.displayName or item.name
      lines[#lines + 1] = string.format("%6dx %s (%s)", item.count, label, item.name)
    end
  end

  lines[#lines + 1] = string.format(
    "Total: %d | Unique: %d | Inventories: %d",
    report.total_items,
    report.unique_items,
    report.inventories_scanned
  )

  if type(display) == "table" and type(display.clear) == "function" and type(display.setCursorPos) == "function" and type(display.write) == "function" then
    display.clear()
    local _, height = 51, 19
    if type(display.getSize) == "function" then
      _, height = display.getSize()
    end
    for i = 1, math.min(#lines, height or #lines) do
      display.setCursorPos(1, i)
      display.write(lines[i])
    end
  end

  for i = 1, #lines do
    print(lines[i])
  end
end

local function main()
  local opts = parse_args(cli_args)
  local display = select_display(opts.use_term)

  while true do
    local report = std.list_inventory({
      mod = opts.mod,
      name = opts.name,
      tag = opts.tag,
      min_count = opts.min_count,
      peripheral = opts.peripheral,
      include_details = true,
    })
    render(display, report, opts)

    if opts.once then
      return report
    end
    if type(sleep) == "function" then
      sleep(opts.interval)
    else
      return report
    end
  end
end

return main()
