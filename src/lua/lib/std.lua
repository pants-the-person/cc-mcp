-- cc-mesh-bridge Standard Library (/lib/std.lua)
-- Imported via: local std = require("lib.std")
-- Compatible with CC: Tweaked (Lua 5.2+) and standard Lua 5.2/5.3/5.4/LuaJIT.

local unpack = table.unpack or unpack

local std = {
  VERSION = "1.0.0",
}

-- ---------------------------------------------------------------------------
-- Configuration Helpers (supports mcp.* with cc_mesh.* fallback)
-- ---------------------------------------------------------------------------

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

function std.get_config()
  local url = read_setting("mcp.url", "cc_mesh.url", "")
  if type(url) == "string" then
    url = url:gsub("/+$", "")
  else
    url = ""
  end

  local cf_id = read_setting("mcp.cf_id", "cc_mesh.cf_id", nil)
  local cf_secret = read_setting("mcp.cf_secret", "cc_mesh.cf_secret", nil)
  local role = read_setting("mcp.role", "cc_mesh.role", "runner")
  local world = read_setting("mcp.world", "cc_mesh.world", "default")
  local net_id = read_setting("mcp.net", "cc_mesh.net", "main")
  local clock_side = read_setting("mcp.clock_side", "cc_mesh.clock_side", "back")

  local headers = {}
  if type(cf_id) == "string" and cf_id ~= "" and type(cf_secret) == "string" and cf_secret ~= "" then
    headers["CF-Access-Client-Id"] = cf_id
    headers["CF-Access-Client-Secret"] = cf_secret
  end

  return {
    url = url,
    cf_id = cf_id,
    cf_secret = cf_secret,
    role = role,
    world = world,
    net_id = net_id,
    clock_side = clock_side,
    headers = headers,
  }
end

-- ---------------------------------------------------------------------------
-- Safe JSON Sanitization, Serialization & Deserialization
-- ---------------------------------------------------------------------------

local function is_pure_array(tbl)
  local count = 0
  local max_idx = 0
  for k, _ in pairs(tbl) do
    if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
      return false, 0
    end
    count = count + 1
    if k > max_idx then
      max_idx = k
    end
  end
  if count == 0 then
    return false, 0
  end
  return max_idx == count, count
end

local function sanitize_value(val, seen, depth)
  local t = type(val)
  if t == "nil" or t == "boolean" or t == "string" then
    return val
  elseif t == "number" then
    if val ~= val then
      return "NaN"
    elseif val == math.huge then
      return "Infinity"
    elseif val == -math.huge then
      return "-Infinity"
    end
    return val
  elseif t == "function" or t == "userdata" or t == "thread" then
    return nil
  elseif t == "table" then
    if seen[val] then
      return "[Circular]"
    end
    if depth > 64 then
      return "[MaxDepth]"
    end
    seen[val] = true

    local arr, len = is_pure_array(val)
    local out = {}
    if arr then
      local idx = 1
      for i = 1, len do
        local sv = sanitize_value(val[i], seen, depth + 1)
        if sv ~= nil then
          out[idx] = sv
          idx = idx + 1
        end
      end
    else
      for k, v in pairs(val) do
        local kt = type(k)
        if kt == "string" or kt == "number" or kt == "boolean" then
          local sv = sanitize_value(v, seen, depth + 1)
          if sv ~= nil then
            if kt == "string" then
              out[k] = sv
            else
              out[tostring(k)] = sv
            end
          end
        end
      end
    end

    seen[val] = nil
    return out
  end
  return nil
end

function std.sanitize_for_json(val)
  return sanitize_value(val, {}, 0)
end

local ESCAPE_MAP = {
  ["\\"] = "\\\\",
  ['"'] = '\\"',
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

local function encode_json_string(s)
  local escaped = s:gsub('[\\"\b\f\n\r\t%z\1-\31]', function(c)
    if ESCAPE_MAP[c] then
      return ESCAPE_MAP[c]
    end
    return string.format("\\u%04x", string.byte(c))
  end)
  return '"' .. escaped .. '"'
end

local function encode_json_fallback(val)
  local t = type(val)
  if t == "nil" then
    return "null"
  elseif t == "boolean" then
    return val and "true" or "false"
  elseif t == "number" then
    if val ~= val or val == math.huge or val == -math.huge then
      return encode_json_string(tostring(val))
    end
    if math.floor(val) == val and val >= -9007199254740992 and val <= 9007199254740992 then
      return string.format("%.0f", val)
    end
    return tostring(val)
  elseif t == "string" then
    return encode_json_string(val)
  elseif t == "table" then
    local arr, len = is_pure_array(val)
    if arr then
      local parts = {}
      for i = 1, len do
        parts[i] = encode_json_fallback(val[i])
      end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local keys = {}
      for k in pairs(val) do
        keys[#keys + 1] = tostring(k)
      end
      table.sort(keys)
      local parts = {}
      for i = 1, #keys do
        local k = keys[i]
        local v = val[k]
        if v == nil then
          v = val[tonumber(k)]
        end
        parts[i] = encode_json_string(k) .. ":" .. encode_json_fallback(v)
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  return "null"
end

function std.serialize_json(tbl)
  local sanitized = std.sanitize_for_json(tbl)
  if type(textutils) == "table" and type(textutils.serialiseJSON) == "function" then
    local ok, encoded = pcall(textutils.serialiseJSON, sanitized)
    if ok and type(encoded) == "string" then
      return encoded
    end
  end
  return encode_json_fallback(sanitized)
end

-- Pure-Lua JSON parser fallback
local function decode_json_fallback(str)
  if type(str) ~= "string" then
    return nil
  end
  local pos = 1
  local len = #str

  local function skip_ws()
    while pos <= len do
      local c = str:sub(pos, pos)
      if c == " " or c == "\t" or c == "\r" or c == "\n" then
        pos = pos + 1
      else
        break
      end
    end
  end

  local parse_value

  local function parse_string()
    pos = pos + 1 -- skip opening quote
    local out = {}
    while pos <= len do
      local c = str:sub(pos, pos)
      if c == '"' then
        pos = pos + 1
        return table.concat(out)
      elseif c == "\\" then
        pos = pos + 1
        local esc = str:sub(pos, pos)
        if esc == '"' or esc == "\\" or esc == "/" then
          out[#out + 1] = esc
        elseif esc == "b" then
          out[#out + 1] = "\b"
        elseif esc == "f" then
          out[#out + 1] = "\f"
        elseif esc == "n" then
          out[#out + 1] = "\n"
        elseif esc == "r" then
          out[#out + 1] = "\r"
        elseif esc == "t" then
          out[#out + 1] = "\t"
        elseif esc == "u" then
          local hex = str:sub(pos + 1, pos + 4)
          local code = tonumber(hex, 16) or 63
          if code < 128 then
            out[#out + 1] = string.char(code)
          else
            out[#out + 1] = "?"
          end
          pos = pos + 4
        else
          out[#out + 1] = esc
        end
        pos = pos + 1
      else
        out[#out + 1] = c
        pos = pos + 1
      end
    end
    error("Unterminated JSON string")
  end

  local function parse_number()
    local start = pos
    local num_str = str:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
    if not num_str or #num_str == 0 then
      error("Invalid JSON number at " .. start)
    end
    pos = pos + #num_str
    return tonumber(num_str)
  end

  local function parse_array()
    pos = pos + 1 -- skip '['
    local arr = {}
    skip_ws()
    if str:sub(pos, pos) == "]" then
      pos = pos + 1
      return arr
    end
    while pos <= len do
      skip_ws()
      arr[#arr + 1] = parse_value()
      skip_ws()
      local c = str:sub(pos, pos)
      if c == "]" then
        pos = pos + 1
        return arr
      elseif c == "," then
        pos = pos + 1
      else
        error("Expected ',' or ']' in JSON array at " .. pos)
      end
    end
    error("Unterminated JSON array")
  end

  local function parse_object()
    pos = pos + 1 -- skip '{'
    local obj = {}
    skip_ws()
    if str:sub(pos, pos) == "}" then
      pos = pos + 1
      return obj
    end
    while pos <= len do
      skip_ws()
      if str:sub(pos, pos) ~= '"' then
        error("Expected string key in JSON object at " .. pos)
      end
      local k = parse_string()
      skip_ws()
      if str:sub(pos, pos) ~= ":" then
        error("Expected ':' in JSON object at " .. pos)
      end
      pos = pos + 1
      skip_ws()
      obj[k] = parse_value()
      skip_ws()
      local c = str:sub(pos, pos)
      if c == "}" then
        pos = pos + 1
        return obj
      elseif c == "," then
        pos = pos + 1
      else
        error("Expected ',' or '}' in JSON object at " .. pos)
      end
    end
    error("Unterminated JSON object")
  end

  parse_value = function()
    skip_ws()
    local c = str:sub(pos, pos)
    if c == '"' then
      return parse_string()
    elseif c == "{" then
      return parse_object()
    elseif c == "[" then
      return parse_array()
    elseif str:sub(pos, pos + 3) == "true" then
      pos = pos + 4
      return true
    elseif str:sub(pos, pos + 4) == "false" then
      pos = pos + 5
      return false
    elseif str:sub(pos, pos + 3) == "null" then
      pos = pos + 4
      return nil
    else
      return parse_number()
    end
  end

  local ok, result = pcall(parse_value)
  if not ok then
    return nil, result
  end
  return result
end

function std.deserialize_json(str)
  if type(str) ~= "string" then
    return nil
  end
  if type(textutils) == "table" and type(textutils.unserialiseJSON) == "function" then
    local ok, parsed = pcall(textutils.unserialiseJSON, str)
    if ok and parsed ~= nil then
      return parsed
    end
  end
  return decode_json_fallback(str)
end

-- ---------------------------------------------------------------------------
-- Composable Item Filters
-- ---------------------------------------------------------------------------

local function extract_mod_id(item)
  if type(item) ~= "table" then
    return ""
  end
  if type(item.mod) == "string" and item.mod ~= "" then
    return item.mod
  end
  if type(item.mod_id) == "string" and item.mod_id ~= "" then
    return item.mod_id
  end
  if type(item.name) == "string" then
    local prefix = item.name:match("^([^:]+):")
    if prefix then
      return prefix
    end
  end
  return "minecraft"
end

local function matches_pattern_or_plain(text, pattern)
  if type(text) ~= "string" or type(pattern) ~= "string" then
    return false
  end
  local ok, found = pcall(string.find, text, pattern)
  if ok and found then
    return true
  end
  if string.find(text, pattern, 1, true) then
    return true
  end
  return false
end

local function normalize_predicates(...)
  local count = select("#", ...)
  if count == 1 and type((...)) == "table" then
    return (...)
  end
  local preds = {}
  for i = 1, count do
    local p = select(i, ...)
    if type(p) == "function" then
      preds[#preds + 1] = p
    end
  end
  return preds
end

std.filters = {}

function std.filters.by_mod(mod)
  local target = tostring(mod or "")
  local prefix = target .. ":"
  return function(item)
    if type(item) ~= "table" then
      return false
    end
    if extract_mod_id(item) == target then
      return true
    end
    if type(item.name) == "string" and item.name:sub(1, #prefix) == prefix then
      return true
    end
    return false
  end
end

function std.filters.by_name(pattern)
  local pat = tostring(pattern or "")
  return function(item)
    if type(item) ~= "table" then
      return false
    end
    if matches_pattern_or_plain(item.name, pat) then
      return true
    end
    if matches_pattern_or_plain(item.displayName, pat) then
      return true
    end
    return false
  end
end

function std.filters.by_tag(tag)
  local target = tostring(tag or "")
  return function(item)
    if type(item) ~= "table" or type(item.tags) ~= "table" then
      return false
    end
    if item.tags[target] == true then
      return true
    end
    for _, v in ipairs(item.tags) do
      if v == target then
        return true
      end
    end
    return false
  end
end

function std.filters.min_count(n)
  local threshold = tonumber(n) or 0
  return function(item)
    if type(item) ~= "table" then
      return false
    end
    return (tonumber(item.count) or 0) >= threshold
  end
end

function std.filters.all(...)
  local preds = normalize_predicates(...)
  return function(item)
    for i = 1, #preds do
      if not preds[i](item) then
        return false
      end
    end
    return true
  end
end

function std.filters.any(...)
  local preds = normalize_predicates(...)
  return function(item)
    if #preds == 0 then
      return true
    end
    for i = 1, #preds do
      if preds[i](item) then
        return true
      end
    end
    return false
  end
end

-- ---------------------------------------------------------------------------
-- Peripheral Attachment Listing
-- ---------------------------------------------------------------------------

local function get_peripheral_types(name)
  if type(peripheral) ~= "table" or type(peripheral.getType) ~= "function" then
    return {}
  end
  local raw = { peripheral.getType(name) }
  local types = {}
  for i = 1, #raw do
    if type(raw[i]) == "string" and raw[i] ~= "" then
      types[#types + 1] = raw[i]
    end
  end
  return types
end

local function has_string(list, target)
  if type(list) ~= "table" then
    return false
  end
  for i = 1, #list do
    if list[i] == target then
      return true
    end
  end
  return false
end

function std.list_attachment(filter_type)
  if type(peripheral) ~= "table" or type(peripheral.getNames) ~= "function" then
    return {}
  end
  local names = peripheral.getNames() or {}
  local result = {}
  local has_filter = type(filter_type) == "string" and filter_type ~= ""

  for i = 1, #names do
    local name = names[i]
    local types = get_peripheral_types(name)
    local primary = types[1] or "unknown"
    local raw_methods = peripheral.getMethods(name) or {}
    local methods = {}
    for j = 1, #raw_methods do
      methods[j] = raw_methods[j]
    end

    local matched = not has_filter
    if has_filter then
      if primary == filter_type or string.find(primary, filter_type, 1, true) ~= nil then
        matched = true
      else
        for j = 1, #types do
          if types[j] == filter_type or string.find(types[j], filter_type, 1, true) ~= nil then
            matched = true
            break
          end
        end
      end
    end

    if matched then
      result[#result + 1] = {
        name = name,
        type = primary,
        types = types,
        methods = methods,
      }
    end
  end

  return result
end

-- ---------------------------------------------------------------------------
-- Inventory Aggregation & Filtering
-- ---------------------------------------------------------------------------

local function normalize_tags_into(dst, src)
  if type(src) ~= "table" then
    return
  end
  for k, v in pairs(src) do
    if type(k) == "number" and type(v) == "string" then
      dst[v] = true
    elseif type(k) == "string" and v == true then
      dst[k] = true
    end
  end
end

local function tags_map_to_list(tag_map)
  local list = {}
  for k, v in pairs(tag_map) do
    if v == true then
      list[#list + 1] = k
    end
  end
  table.sort(list)
  return list
end

function std.list_inventory(opts)
  opts = type(opts) == "table" and opts or {}

  if type(peripheral) ~= "table" or type(peripheral.getNames) ~= "function" then
    return {
      total_items = 0,
      unique_items = 0,
      inventories_scanned = 0,
      items = {},
    }
  end

  local target_periphs = {}
  if type(opts.peripheral) == "string" and opts.peripheral ~= "" then
    if type(peripheral.isPresent) ~= "function" or peripheral.isPresent(opts.peripheral) then
      target_periphs[1] = opts.peripheral
    end
  else
    local names = peripheral.getNames() or {}
    for i = 1, #names do
      local p_name = names[i]
      local types = get_peripheral_types(p_name)
      local methods = peripheral.getMethods(p_name) or {}
      if has_string(types, "inventory") or has_string(methods, "list") then
        target_periphs[#target_periphs + 1] = p_name
      end
    end
  end

  local aggregated = {}
  local inventories_scanned = 0
  local need_details = (opts.tag ~= nil) or (opts.include_details == true)

  for i = 1, #target_periphs do
    local p_name = target_periphs[i]
    local methods = peripheral.getMethods(p_name) or {}
    if has_string(methods, "list") then
      local ok, slots = pcall(peripheral.call, p_name, "list")
      if ok and type(slots) == "table" then
        inventories_scanned = inventories_scanned + 1
        local has_detail = has_string(methods, "getItemDetail")

        for slot, stack in pairs(slots) do
          if type(stack) == "table" and type(stack.name) == "string" and stack.name ~= "" then
            local detail = nil
            if need_details and has_detail and (stack.tags == nil or stack.displayName == nil) then
              local d_ok, d_val = pcall(peripheral.call, p_name, "getItemDetail", slot)
              if d_ok and type(d_val) == "table" then
                detail = d_val
              end
            end

            local item_name = stack.name
            local count = tonumber(stack.count) or 0
            local entry = aggregated[item_name]
            if not entry then
              entry = {
                name = item_name,
                mod = extract_mod_id(stack),
                count = 0,
                displayName = stack.displayName or (detail and detail.displayName) or nil,
                _tag_map = {},
                sources = {},
              }
              aggregated[item_name] = entry
            end

            entry.count = entry.count + count
            if not entry.displayName then
              entry.displayName = stack.displayName or (detail and detail.displayName) or nil
            end
            normalize_tags_into(entry._tag_map, stack.tags)
            if detail and detail.tags then
              normalize_tags_into(entry._tag_map, detail.tags)
            end

            if opts.include_slots then
              entry.sources[#entry.sources + 1] = {
                peripheral = p_name,
                slot = slot,
                count = count,
              }
            else
              local found_src = false
              for s_idx = 1, #entry.sources do
                if entry.sources[s_idx].peripheral == p_name then
                  entry.sources[s_idx].count = entry.sources[s_idx].count + count
                  found_src = true
                  break
                end
              end
              if not found_src then
                entry.sources[#entry.sources + 1] = {
                  peripheral = p_name,
                  count = count,
                }
              end
            end
          end
        end
      end
    end
  end

  local predicates = {}
  if type(opts.mod) == "string" and opts.mod ~= "" then
    predicates[#predicates + 1] = std.filters.by_mod(opts.mod)
  end
  if type(opts.name) == "string" and opts.name ~= "" then
    predicates[#predicates + 1] = std.filters.by_name(opts.name)
  end
  if type(opts.tag) == "string" and opts.tag ~= "" then
    predicates[#predicates + 1] = std.filters.by_tag(opts.tag)
  end
  if opts.min_count ~= nil then
    predicates[#predicates + 1] = std.filters.min_count(opts.min_count)
  end
  if type(opts.filter) == "function" then
    predicates[#predicates + 1] = opts.filter
  end

  local combined_filter = nil
  if #predicates > 0 then
    combined_filter = std.filters.all(unpack(predicates))
  end

  local items = {}
  local total_items = 0

  for _, entry in pairs(aggregated) do
    local tag_list = tags_map_to_list(entry._tag_map)
    local item_record = {
      name = entry.name,
      mod = entry.mod,
      count = entry.count,
      displayName = entry.displayName,
      tags = #tag_list > 0 and tag_list or nil,
      sources = entry.sources,
    }
    if not combined_filter or combined_filter(item_record) then
      items[#items + 1] = item_record
      total_items = total_items + item_record.count
    end
  end

  table.sort(items, function(a, b)
    if a.count ~= b.count then
      return a.count > b.count
    end
    return a.name < b.name
  end)

  return {
    total_items = total_items,
    unique_items = #items,
    inventories_scanned = inventories_scanned,
    items = items,
  }
end

-- ---------------------------------------------------------------------------
-- Safe Read-Only Peripheral API Introspection
-- ---------------------------------------------------------------------------

-- Strictly curated allowlist of zero-argument, non-mutating read-only methods.
-- Mutating methods (pushItems, pullItems, craftItem, exportItem, setOutput,
-- activate, scram, destroy, clear, set*, add*, remove*, drop*, dig*, place*)
-- MUST NEVER be added here.
local SAFE_PROBE_METHODS = {
  size = true,
  getEnergy = true,
  getEnergyCapacity = true,
  getMaxEnergy = true,
  getEnergyStored = true,
  getEnergyFilledPercentage = true,
  getEnergyUsage = true,
  getLastInput = true,
  getLastOutput = true,
  getTanks = true,
  tanks = true,
  getStatus = true,
  getFuelLevel = true,
  getFuelLimit = true,
  getLabel = true,
  getName = true,
  getDirection = true,
  getOrientation = true,
  getInfo = true,
  getStats = true,
  getSpeed = true,
  getStress = true,
  getStressCapacity = true,
  getRotationSpeed = true,
  getTargetSpeed = true,
  getTemperature = true,
  getBurnRate = true,
  getMaxBurnRate = true,
  getDamagePercent = true,
  getHeatingRate = true,
  getCoolantFilledPercentage = true,
  getFuelFilledPercentage = true,
  getWasteFilledPercentage = true,
  getPatterns = true,
  listItems = true,
  listFluid = true,
  listFluids = true,
  listCells = true,
  listCraftableItems = true,
  getCraftableItems = true,
  getCraftingCPUs = true,
  getTotalItemStorage = true,
  getUsedItemStorage = true,
  getAvailableItemStorage = true,
  getTotalFluidStorage = true,
  getUsedFluidStorage = true,
  getTransferLocations = true,
  isWireless = true,
  getNamesRemote = true,
  isDiskPresent = true,
  getDiskLabel = true,
  getMountPath = true,
  getSize = true,
  isColor = true,
  isColour = true,
  getTextScale = true,
  getBlockName = true,
  getConfiguration = true,
  getMode = true,
}

local function sanitize_probe_result(val)
  local sanitized = std.sanitize_for_json(val)
  if type(sanitized) == "table" then
    local arr, len = is_pure_array(sanitized)
    if arr and len > 32 then
      local sample = {}
      for i = 1, 16 do
        sample[i] = sanitized[i]
      end
      return {
        _truncated = true,
        count = len,
        sample = sample,
      }
    end
  end
  return sanitized
end

function std.get_api(periph_name)
  local now = (type(os) == "table" and type(os.epoch) == "function") and os.epoch("utc") or 0

  if type(periph_name) ~= "string" or periph_name == "" or type(peripheral) ~= "table" then
    return {
      name = tostring(periph_name or ""),
      present = false,
      type = "unknown",
      type_name = "unknown",
      types = {},
      methods = {},
      metadata = {},
      probed_at = now,
    }
  end

  if type(peripheral.isPresent) == "function" and not peripheral.isPresent(periph_name) then
    return {
      name = periph_name,
      present = false,
      type = "unknown",
      type_name = "unknown",
      types = {},
      methods = {},
      metadata = {},
      probed_at = now,
    }
  end

  local types = get_peripheral_types(periph_name)
  local primary = types[1] or "unknown"
  local raw_methods = peripheral.getMethods(periph_name) or {}
  local methods = {}
  local metadata = {}

  for i = 1, #raw_methods do
    local m = raw_methods[i]
    methods[i] = m
    if SAFE_PROBE_METHODS[m] then
      local ok, res = pcall(peripheral.call, periph_name, m)
      if ok and res ~= nil then
        metadata[m] = sanitize_probe_result(res)
      end
    end
  end

  return {
    name = periph_name,
    present = true,
    type = primary,
    type_name = primary,
    types = types,
    methods = methods,
    metadata = metadata,
    probed_at = now,
  }
end

-- ---------------------------------------------------------------------------
-- Unified Network Topology Discovery
-- ---------------------------------------------------------------------------

function std.open_all_modems()
  if type(peripheral) ~= "table" or type(rednet) ~= "table" then
    return 0
  end
  local opened = 0
  local names = peripheral.getNames() or {}
  for i = 1, #names do
    local name = names[i]
    local types = get_peripheral_types(name)
    if has_string(types, "modem") then
      local already = type(rednet.isOpen) == "function" and rednet.isOpen(name)
      if not already then
        pcall(rednet.open, name)
      end
      opened = opened + 1
    end
  end
  return opened
end

function std.probe_network(timeout)
  local wait_sec = tonumber(timeout)
  if wait_sec == nil or wait_sec < 0 then
    wait_sec = 1.0
  end

  local computer_id = (type(os) == "table" and type(os.getComputerID) == "function")
    and os.getComputerID()
    or 0
  local label = (type(os) == "table" and type(os.getComputerLabel) == "function")
    and os.getComputerLabel()
    or nil
  local is_turtle = (turtle ~= nil)

  local peripherals = std.list_attachment()
  local runners = {}
  local seen_runners = {}

  if type(rednet) == "table" and type(os) == "table" and type(os.startTimer) == "function" and type(os.pullEvent) == "function" then
    local modem_count = std.open_all_modems()
    if modem_count > 0 and wait_sec > 0 then
      pcall(rednet.broadcast, {
        type = "DISCOVER",
        from = computer_id,
        label = label,
      }, "mcp_rpc")

      local timer_id = os.startTimer(wait_sec)
      while true do
        local ev, p1, p2, p3 = os.pullEvent()
        if ev == "timer" and p1 == timer_id then
          break
        elseif ev == "rednet_message" and p3 == "mcp_rpc" and type(p2) == "table" and p2.type == "HERE" then
          local rid = tonumber(p2.id) or p1
          if rid and not seen_runners[rid] then
            seen_runners[rid] = true
            runners[#runners + 1] = {
              id = rid,
              label = p2.label or ("runner_" .. tostring(rid)),
              is_turtle = p2.is_turtle == true,
            }
          end
        end
      end
    end
  end

  local cfg = std.get_config()
  local self_kind = is_turtle and "turtle" or (cfg.role == "gateway" and "gateway" or "runner")
  local self_name = label or (self_kind .. "_" .. tostring(computer_id))

  local entities = {
    {
      name = self_name,
      kind = self_kind,
      type_name = is_turtle and "turtle" or "computer",
      type = is_turtle and "turtle" or "computer",
      methods = {},
    },
  }

  for i = 1, #peripherals do
    local p = peripherals[i]
    local probe = std.get_api(p.name)
    entities[#entities + 1] = {
      name = p.name,
      kind = (p.type == "drive") and "drive" or "peripheral",
      type_name = p.type,
      type = p.type,
      types = p.types,
      methods = p.methods,
      probe = probe,
    }
  end

  for i = 1, #runners do
    local r = runners[i]
    entities[#entities + 1] = {
      name = r.label,
      kind = r.is_turtle and "turtle" or "runner",
      type_name = r.is_turtle and "turtle" or "computer",
      type = r.is_turtle and "turtle" or "computer",
      methods = {},
      probe = {
        id = r.id,
        label = r.label,
        is_turtle = r.is_turtle,
      },
    }
  end

  return {
    computer_id = computer_id,
    label = label or self_name,
    is_turtle = is_turtle,
    peripherals = peripherals,
    runners = runners,
    entities = entities,
  }
end

return std
