-- cc-mesh-bridge Self-Updating Bootstrap (startup.lua)
-- Syncs /lib/std.lua, /pkg.lua, and /<role>.lua (plus /runner.lua on gateways)
-- using SHA-256 manifest verification and Cloudflare Access Service Token headers.

local MANIFEST_PATH = "/.mesh_manifest"

local function get_setting(primary, fallback, default_val)
  if type(settings) == "table" and type(settings.get) == "function" then
    local val = settings.get(primary)
    if val ~= nil then
      return val
    end
    if fallback then
      val = settings.get(fallback)
      if val ~= nil then
        return val
      end
    end
  end
  return default_val
end

local function build_headers(cf_id, cf_secret)
  local headers = {}
  if type(cf_id) == "string" and cf_id ~= "" and type(cf_secret) == "string" and cf_secret ~= "" then
    headers["CF-Access-Client-Id"] = cf_id
    headers["CF-Access-Client-Secret"] = cf_secret
  end
  return headers
end

local function read_file(path)
  if not fs.exists(path) then
    return nil
  end
  local h = fs.open(path, "r")
  if not h then
    return nil
  end
  local content = h.readAll()
  h.close()
  return content
end

local function write_file(path, content)
  local dir = fs.getDir(path)
  if dir and dir ~= "" and not fs.exists(dir) then
    fs.makeDir(dir)
  end
  local h = fs.open(path, "w")
  if not h then
    error("Failed to open file for writing: " .. tostring(path))
  end
  h.write(content)
  h.close()
end

local function http_get_text(url, headers)
  local resp, err = http.get(url, headers)
  if not resp then
    return nil, tostring(err or "HTTP request failed")
  end
  local code = type(resp.getResponseCode) == "function" and resp.getResponseCode() or 200
  local body = resp.readAll()
  resp.close()
  if code and (code < 200 or code >= 300) then
    return nil, "HTTP " .. tostring(code) .. " for " .. url
  end
  return body, nil
end

local function sync_and_boot()
  local base_url = get_setting("mcp.url", "cc_mesh.url", "")
  if type(base_url) ~= "string" or base_url == "" then
    print("[bootstrap] Error: set mcp.url (or cc_mesh.url) via `set mcp.url https://...`")
    return false
  end
  base_url = base_url:gsub("/+$", "")

  local cf_id = get_setting("mcp.cf_id", "cc_mesh.cf_id", nil)
  local cf_secret = get_setting("mcp.cf_secret", "cc_mesh.cf_secret", nil)
  local role = get_setting("mcp.role", "cc_mesh.role", "runner")
  if type(role) ~= "string" or role == "" then
    role = "runner"
  end

  local headers = build_headers(cf_id, cf_secret)
  local manifest_url = base_url .. "/lua/manifest.json"
  local manifest_raw, fetch_err = http_get_text(manifest_url, headers)
  if not manifest_raw then
    print("[bootstrap] Failed to fetch manifest: " .. tostring(fetch_err))
  else
    local remote_manifest = textutils.unserialiseJSON(manifest_raw)
    if type(remote_manifest) ~= "table" then
      print("[bootstrap] Invalid manifest JSON from " .. manifest_url)
    else
      local local_manifest = {}
      local existing_raw = read_file(MANIFEST_PATH)
      if existing_raw and existing_raw ~= "" then
        local parsed = textutils.unserialiseJSON(existing_raw)
        if type(parsed) == "table" then
          local_manifest = parsed
        end
      end

      -- Build ordered sync list: core stdlib, pkg CLI, role script (+ runner on gateway)
      local sync_targets = {
        { key = "lib/std.lua", dest = "/lib/std.lua" },
        { key = "pkg.lua", dest = "/pkg.lua" },
        { key = role .. ".lua", dest = "/" .. role .. ".lua" },
      }
      if role == "gateway" then
        sync_targets[#sync_targets + 1] = { key = "runner.lua", dest = "/runner.lua" }
      end

      local updated_count = 0
      for i = 1, #sync_targets do
        local item = sync_targets[i]
        local remote_hash = remote_manifest[item.key]
        if type(remote_hash) == "string" and remote_hash ~= "" then
          local needs_update = (local_manifest[item.key] ~= remote_hash) or (not fs.exists(item.dest))
          if needs_update then
            local file_url = base_url .. "/lua/" .. item.key
            local source, dl_err = http_get_text(file_url, headers)
            if source then
              if item.dest == "/lib/std.lua" and not fs.exists("/lib") then
                fs.makeDir("/lib")
              end
              write_file(item.dest, source)
              local_manifest[item.key] = remote_hash
              updated_count = updated_count + 1
              print("[bootstrap] Synced " .. item.dest)
            else
              print("[bootstrap] Failed to download " .. item.key .. ": " .. tostring(dl_err))
            end
          end
        end
      end

      if updated_count > 0 or not fs.exists(MANIFEST_PATH) then
        write_file(MANIFEST_PATH, textutils.serialiseJSON(local_manifest))
      end
      print("[bootstrap] Sync complete (" .. tostring(updated_count) .. " updated)")
    end
  end

  local entrypoint = "/" .. role .. ".lua"
  if get_setting("mcp.no_exec", "cc_mesh.no_exec", false) == true then
    return true
  end

  if fs.exists(entrypoint) and type(shell) == "table" and type(shell.run) == "function" then
    print("[bootstrap] Launching " .. entrypoint)
    return shell.run(entrypoint)
  else
    print("[bootstrap] Entrypoint not found: " .. entrypoint)
    return false
  end
end

return sync_and_boot()
