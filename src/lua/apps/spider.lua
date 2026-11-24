-- cc-mesh-bridge Static App: Item & Recipe Spider (/lua/apps/spider.lua)
-- Crawls attached inventories, AE2 / ME bridges, and crafting patterns,
-- deduplicates unchanged batches via a local content hash in /.spider_cache,
-- and uploads changes to POST /api/recipes/ingest.

local std = require("lib.std")

local CACHE_PATH = "/.spider_cache"
local cli_args = { ... }

local function has_flag(args, flag)
  for i = 1, #args do
    if args[i] == flag then
      return true
    end
  end
  return false
end

-- Pure-Lua deterministic 64-bit hex content hash (Lua 5.2/5.3/5.4/LuaJIT safe)
local function compute_hash(str)
  local MOD = 4294967296 -- 2^32
  local h1 = 2166136261
  local h2 = 5381
  for i = 1, #str do
    local b = string.byte(str, i)
    h1 = ((h1 * 16777619) + b + (i % 251)) % MOD
    h2 = ((h2 * 33) + b + (h1 % 97)) % MOD
  end
  return string.format("%08x%08x", h1, h2)
end

local function read_cache()
  if not fs.exists(CACHE_PATH) then
    return nil
  end
  local h = fs.open(CACHE_PATH, "r")
  if not h then
    return nil
  end
  local val = h.readAll()
  h.close()
  if type(val) == "string" then
    return (val:gsub("%s+", ""))
  end
  return nil
end

local function write_cache(hash_str)
  local h = fs.open(CACHE_PATH, "w")
  if h then
    h.write(hash_str)
    h.close()
  end
end

local function extract_mod_id(item_id)
  if type(item_id) == "string" then
    local prefix = item_id:match("^([^:]+):")
    if prefix then
      return prefix
    end
  end
  return "minecraft"
end

local function normalize_tags(raw)
  local set = {}
  if type(raw) == "table" then
    for k, v in pairs(raw) do
      if type(k) == "number" and type(v) == "string" then
        set[v] = true
      elseif type(k) == "string" and v == true then
        set[k] = true
      end
    end
  end
  local list = {}
  for k in pairs(set) do
    list[#list + 1] = k
  end
  table.sort(list)
  return list
end

local function crawl_world()
  local items_map = {}
  local recipes_map = {}

  local function upsert_item(item_id, display_name, mod_id, tags)
    if type(item_id) ~= "string" or item_id == "" then
      return
    end
    local existing = items_map[item_id]
    local tag_list = normalize_tags(tags)
    if not existing then
      items_map[item_id] = {
        item_id = item_id,
        display_name = (type(display_name) == "string" and display_name ~= "") and display_name or item_id,
        mod_id = (type(mod_id) == "string" and mod_id ~= "") and mod_id or extract_mod_id(item_id),
        tags = tag_list,
      }
    else
      if existing.display_name == existing.item_id and type(display_name) == "string" and display_name ~= "" then
        existing.display_name = display_name
      end
      if #tag_list > 0 then
        local merged = {}
        for i = 1, #existing.tags do
          merged[existing.tags[i]] = true
        end
        for i = 1, #tag_list do
          merged[tag_list[i]] = true
        end
        existing.tags = normalize_tags(merged)
      end
    end
  end

  -- 1. Crawl attached inventories via lib.std
  local inv = std.list_inventory({ include_details = true })
  for i = 1, #inv.items do
    local entry = inv.items[i]
    upsert_item(entry.name, entry.displayName, entry.mod, entry.tags)
  end

  -- 2. Crawl AE2 / ME Bridge / Pattern Providers for items and crafting patterns
  local attachments = std.list_attachment()
  for i = 1, #attachments do
    local p = attachments[i]
    local method_set = {}
    for j = 1, #p.methods do
      method_set[p.methods[j]] = true
    end

    -- ME Bridge / RS Bridge item lists
    if method_set["listItems"] then
      local ok, me_items = pcall(peripheral.call, p.name, "listItems")
      if ok and type(me_items) == "table" then
        for _, it in ipairs(me_items) do
          if type(it) == "table" and type(it.name) == "string" then
            upsert_item(it.name, it.displayName, it.mod, it.tags)
          end
        end
      end
    end

    -- Pattern providers / AE2 crafting patterns
    if method_set["getPatterns"] then
      local ok, patterns = pcall(peripheral.call, p.name, "getPatterns")
      if ok and type(patterns) == "table" then
        for idx, pat in ipairs(patterns) do
          if type(pat) == "table" then
            local out_item = pat.output_item_id
              or (type(pat.output) == "table" and pat.output.name)
              or (type(pat.outputs) == "table" and type(pat.outputs[1]) == "table" and pat.outputs[1].name)
            local out_count = pat.output_count
              or (type(pat.output) == "table" and pat.output.count)
              or (type(pat.outputs) == "table" and type(pat.outputs[1]) == "table" and pat.outputs[1].count)
              or 1

            if type(out_item) == "string" and out_item ~= "" then
              upsert_item(out_item, pat.output_display_name, nil, nil)
              local raw_inputs = pat.ingredients or pat.inputs or {}
              local ingredients = {}
              for s_idx, inp in ipairs(raw_inputs) do
                if type(inp) == "table" then
                  local ing_id = inp.ingredient_id or inp.name
                  if type(ing_id) == "string" and ing_id ~= "" then
                    upsert_item(ing_id, inp.displayName, nil, nil)
                    ingredients[#ingredients + 1] = {
                      ingredient_id = ing_id,
                      count = tonumber(inp.count) or 1,
                      slot = tostring(inp.slot or ("slot_" .. tostring(s_idx))),
                    }
                  end
                end
              end

              local recipe_id = pat.recipe_id or (p.name .. ":" .. out_item .. ":" .. tostring(idx))
              recipes_map[recipe_id] = {
                recipe_id = recipe_id,
                recipe_type = pat.recipe_type or "pattern",
                output_item_id = out_item,
                output_count = tonumber(out_count) or 1,
                machine = pat.machine or p.type,
                ingredients = ingredients,
              }
            end
          end
        end
      end
    end
  end

  local items = {}
  for _, v in pairs(items_map) do
    items[#items + 1] = v
  end
  table.sort(items, function(a, b)
    return a.item_id < b.item_id
  end)

  local recipes = {}
  for _, v in pairs(recipes_map) do
    recipes[#recipes + 1] = v
  end
  table.sort(recipes, function(a, b)
    return a.recipe_id < b.recipe_id
  end)

  return items, recipes
end

local function main()
  local force = has_flag(cli_args, "--force")
  local cfg = std.get_config()
  if type(cfg.url) ~= "string" or cfg.url == "" then
    print("[spider] Error: set mcp.url (or cc_mesh.url) first")
    return false
  end

  local items, recipes = crawl_world()
  local payload = {
    items = items,
    recipes = recipes,
  }

  local canonical_json = std.serialize_json(payload)
  local digest = compute_hash(canonical_json)
  local prev_hash = read_cache()

  if (not force) and prev_hash == digest then
    print(string.format("[spider] No changes detected (hash %s), skipping upload.", digest))
    return true
  end

  local headers = {
    ["Content-Type"] = "application/json",
  }
  for k, v in pairs(cfg.headers) do
    headers[k] = v
  end

  local resp, err = http.post(cfg.url .. "/api/recipes/ingest", canonical_json, headers)
  if not resp then
    print("[spider] Upload failed: " .. tostring(err))
    return false
  end

  local code = type(resp.getResponseCode) == "function" and resp.getResponseCode() or 200
  local body = resp.readAll()
  resp.close()

  if code and (code < 200 or code >= 300) then
    print("[spider] Server rejected batch (HTTP " .. tostring(code) .. "): " .. tostring(body))
    return false
  end

  write_cache(digest)
  print(string.format("[spider] Ingested %d items, %d recipes (hash %s)", #items, #recipes, digest))
  return true
end

return main()
