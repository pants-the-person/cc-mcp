-- cc-mesh-bridge Unified Dual App Store & Schematics CLI (/pkg.lua)
-- Usage:
--   pkg list
--   pkg install <slug> [--static|--store] [dest]
--   pkg publish <slug> <title> <file> [description]
--   pkg schematics list
--   pkg schematics install <slug> [dest]
--   pkg schematics publish <slug> <title> <file> [format]

local std = require("lib.std")

local cli_args = { ... }

local function clone_headers(base_headers, extra)
  local out = {}
  for k, v in pairs(base_headers or {}) do
    out[k] = v
  end
  if type(extra) == "table" then
    for k, v in pairs(extra) do
      out[k] = v
    end
  end
  return out
end

local function http_get(url, headers)
  local resp, err = http.get(url, headers)
  if not resp then
    return nil, 0, tostring(err or "HTTP GET failed")
  end
  local code = type(resp.getResponseCode) == "function" and resp.getResponseCode() or 200
  local body = resp.readAll()
  resp.close()
  if code and (code < 200 or code >= 300) then
    return nil, code, "HTTP " .. tostring(code)
  end
  return body, code, nil
end

local function http_post_json(url, payload, headers)
  local post_headers = clone_headers(headers, {
    ["Content-Type"] = "application/json",
  })
  local body_str = std.serialize_json(payload)
  local resp, err = http.post(url, body_str, post_headers)
  if not resp then
    return nil, 0, tostring(err or "HTTP POST failed")
  end
  local code = type(resp.getResponseCode) == "function" and resp.getResponseCode() or 200
  local body = resp.readAll()
  resp.close()
  if code and (code < 200 or code >= 300) then
    return nil, code, "HTTP " .. tostring(code) .. ": " .. tostring(body)
  end
  return body, code, nil
end

local function write_file(path, content)
  local dir = fs.getDir(path)
  if dir and dir ~= "" and not fs.exists(dir) then
    fs.makeDir(dir)
  end
  local h = fs.open(path, "w")
  if not h then
    error("Cannot write to " .. tostring(path))
  end
  h.write(content)
  h.close()
end

local function read_file(path)
  if not fs.exists(path) then
    return nil, "File not found: " .. tostring(path)
  end
  local h = fs.open(path, "r")
  if not h then
    return nil, "Cannot open file: " .. tostring(path)
  end
  local content = h.readAll()
  h.close()
  return content, nil
end

local function print_usage()
  print("Usage:")
  print("  pkg list")
  print("  pkg install <slug> [--static|--store] [dest]")
  print("  pkg publish <slug> <title> <file> [description]")
  print("  pkg schematics list|install|publish ...")
end

local function cmd_list(cfg)
  local static_body, _, static_err = http_get(cfg.url .. "/api/store/static", cfg.headers)
  if static_body then
    local parsed = std.deserialize_json(static_body)
    local apps = (type(parsed) == "table" and type(parsed.apps) == "table") and parsed.apps or {}
    for i = 1, #apps do
      local app = apps[i]
      print(string.format("[static] %s - %s", tostring(app.slug), tostring(app.title or "")))
    end
  else
    print("[pkg] Warning: failed to list static apps: " .. tostring(static_err))
  end

  local store_body, _, store_err = http_get(cfg.url .. "/api/store/packages", cfg.headers)
  if store_body then
    local parsed = std.deserialize_json(store_body)
    local pkgs = (type(parsed) == "table" and type(parsed.packages) == "table") and parsed.packages or {}
    for i = 1, #pkgs do
      local p = pkgs[i]
      print(string.format("[store] %s (v%s) - %s", tostring(p.slug), tostring(p.version or "1.0.0"), tostring(p.title or "")))
    end
  else
    print("[pkg] Warning: failed to list store packages: " .. tostring(store_err))
  end
  return true
end

local function cmd_install(cfg, args)
  local mode = "auto"
  local positional = {}
  for i = 2, #args do
    local a = args[i]
    if a == "--static" then
      mode = "static"
    elseif a == "--store" then
      mode = "store"
    else
      positional[#positional + 1] = a
    end
  end

  local slug = positional[1]
  if not slug or slug == "" then
    print("Usage: pkg install <slug> [--static|--store] [dest]")
    return false
  end

  local dest = positional[2] or ("/" .. slug .. ".lua")
  local content = nil
  local resolved_source = nil
  local last_err = nil

  if mode == "static" or mode == "auto" then
    local url = cfg.url .. "/lua/apps/" .. slug .. ".lua"
    local body, _, err = http_get(url, cfg.headers)
    if body then
      content = body
      resolved_source = "static"
    else
      last_err = err
    end
  end

  if not content and (mode == "store" or mode == "auto") then
    local url = cfg.url .. "/api/store/download/" .. slug
    local body, _, err = http_get(url, cfg.headers)
    if body then
      content = body
      resolved_source = "store"
    else
      last_err = err
    end
  end

  if not content then
    print("[pkg] Failed to install '" .. slug .. "': " .. tostring(last_err))
    return false
  end

  write_file(dest, content)
  print(string.format("[pkg] Installed %s [%s] -> %s (%d bytes)", slug, resolved_source, dest, #content))
  return true
end

local function cmd_publish(cfg, args)
  local slug = args[2]
  local title = args[3]
  local file_path = args[4]
  local description = args[5] or ""

  if not slug or not title or not file_path then
    print("Usage: pkg publish <slug> <title> <file> [description]")
    return false
  end

  local code, read_err = read_file(file_path)
  if not code then
    print("[pkg] " .. tostring(read_err))
    return false
  end

  local author = (type(os) == "table" and type(os.getComputerLabel) == "function" and os.getComputerLabel())
    or ("computer_" .. tostring(type(os) == "table" and type(os.getComputerID) == "function" and os.getComputerID() or 0))

  local resp_body, _, post_err = http_post_json(cfg.url .. "/api/store/publish", {
    slug = slug,
    title = title,
    description = description,
    code = code,
    author = author,
  }, cfg.headers)

  if not resp_body then
    print("[pkg] Publish failed: " .. tostring(post_err))
    return false
  end

  print(string.format("[pkg] Published %s (%d bytes)", slug, #code))
  return true
end

local function cmd_schematics(cfg, args)
  local sub = args[2]
  if sub == "list" then
    local body, _, err = http_get(cfg.url .. "/api/store/schematics", cfg.headers)
    if not body then
      print("[pkg] Failed to list schematics: " .. tostring(err))
      return false
    end
    local parsed = std.deserialize_json(body)
    local list = (type(parsed) == "table" and type(parsed.schematics) == "table") and parsed.schematics or {}
    for i = 1, #list do
      local s = list[i]
      print(string.format("[schematic] %s (%s) - %s", tostring(s.slug), tostring(s.format or "nbt"), tostring(s.title or "")))
    end
    return true

  elseif sub == "install" then
    local slug = args[3]
    if not slug then
      print("Usage: pkg schematics install <slug> [dest]")
      return false
    end
    local dest = args[4] or ("/schematics/" .. slug)
    local body, _, err = http_get(cfg.url .. "/api/store/schematics/download/" .. slug, cfg.headers)
    if not body then
      print("[pkg] Failed to download schematic '" .. slug .. "': " .. tostring(err))
      return false
    end
    write_file(dest, body)
    print(string.format("[pkg] Installed schematic %s -> %s (%d bytes)", slug, dest, #body))
    return true

  elseif sub == "publish" then
    local slug = args[3]
    local title = args[4]
    local file_path = args[5]
    local format = args[6] or "lua"
    if not slug or not title or not file_path then
      print("Usage: pkg schematics publish <slug> <title> <file> [format]")
      return false
    end
    local content, read_err = read_file(file_path)
    if not content then
      print("[pkg] " .. tostring(read_err))
      return false
    end
    local body, _, post_err = http_post_json(cfg.url .. "/api/store/schematics/publish", {
      slug = slug,
      title = title,
      format = format,
      content = content,
    }, cfg.headers)
    if not body then
      print("[pkg] Schematic publish failed: " .. tostring(post_err))
      return false
    end
    print(string.format("[pkg] Published schematic %s (%d bytes)", slug, #content))
    return true
  end

  print("Usage: pkg schematics list|install|publish ...")
  return false
end

local function main(args)
  local cfg = std.get_config()
  if type(cfg.url) ~= "string" or cfg.url == "" then
    print("[pkg] Error: set mcp.url (or cc_mesh.url) first")
    return false
  end

  local sub = args[1]
  if sub == "list" then
    return cmd_list(cfg)
  elseif sub == "install" then
    return cmd_install(cfg, args)
  elseif sub == "publish" then
    return cmd_publish(cfg, args)
  elseif sub == "schematics" then
    return cmd_schematics(cfg, args)
  else
    print_usage()
    return false
  end
end

return main(cli_args)
