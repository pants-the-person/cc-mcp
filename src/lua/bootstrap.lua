-- cc-mesh-bridge Self-Updating Bootstrap (startup.lua)
-- Syncs /lib/std.lua, /pkg.lua, and /<role>.lua (plus /runner.lua on gateways)
-- using SHA-256 manifest verification and Cloudflare Access Service Token headers.

local MANIFEST_PATH = "/.mesh_manifest"
local DEFAULT_BASE_URL = "https://cc.pants.place"
local CLI_ARGS = { ... }

local function has_flag(flag)
  for i = 1, #CLI_ARGS do
    if CLI_ARGS[i] == flag then
      return true
    end
  end
  return false
end

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

local function set_setting(key, value)
  if type(settings) == "table" and type(settings.set) == "function" then
    settings.set(key, value)
  end
end

local function save_settings()
  if type(settings) == "table" and type(settings.save) == "function" then
    settings.save()
  end
end

local function prompt_value(label, default_val, secret)
  local suffix = (default_val and default_val ~= "" and not secret)
    and (" [" .. tostring(default_val) .. "]: ")
    or ": "
  if type(write) == "function" then
    write(label .. suffix)
  else
    print(label .. suffix)
  end
  local input = secret and read("*") or read()
  input = tostring(input or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if input == "" then
    return default_val or ""
  end
  return input
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
  local reconfigure = has_flag("--reconfigure")
  local base_url = get_setting("mcp.url", "cc_mesh.url", "")
  local cf_id = get_setting("mcp.cf_id", "cc_mesh.cf_id", "")
  local cf_secret = get_setting("mcp.cf_secret", "cc_mesh.cf_secret", "")
  local role = get_setting("mcp.role", "cc_mesh.role", "")

  local needs_setup = reconfigure
    or (type(base_url) ~= "string" or base_url == "")
    or (type(cf_id) ~= "string" or cf_id == "")
    or (type(cf_secret) ~= "string" or cf_secret == "")

  if needs_setup and type(read) == "function" then
    print("=== cc-mesh-bridge First-Time Setup ===")
    base_url = prompt_value("Server URL", (type(base_url) == "string" and base_url ~= "") and base_url or DEFAULT_BASE_URL, false)
    role = prompt_value("Role (gateway/runner)", (type(role) == "string" and role ~= "") and role or "gateway", false)
    if role == "gateway" then
      local world = prompt_value("World", get_setting("mcp.world", "cc_mesh.world", "overworld"), false)
      local net = prompt_value("Net ID", get_setting("mcp.net", "cc_mesh.net", "main"), false)
      local clock_side = prompt_value("Redstone clock side", get_setting("mcp.clock_side", "cc_mesh.clock_side", "back"), false)
      set_setting("mcp.world", world)
      set_setting("mcp.net", net)
      set_setting("mcp.clock_side", clock_side)
    end
    cf_id = prompt_value("CF-Access-Client-Id", (type(cf_id) == "string" and cf_id ~= "") and cf_id or "", false)
    local new_secret = prompt_value("CF-Access-Client-Secret (leave blank to keep)", "", true)
    if new_secret ~= "" then
      cf_secret = new_secret
    end
    set_setting("mcp.url", base_url)
    set_setting("mcp.role", role)
    set_setting("mcp.cf_id", cf_id)
    set_setting("mcp.cf_secret", cf_secret)
    save_settings()
    print("[bootstrap] Saved settings to /.settings")
  end

  if type(base_url) ~= "string" or base_url == "" then
    base_url = DEFAULT_BASE_URL
    set_setting("mcp.url", base_url)
    save_settings()
    print("[bootstrap] Defaulted mcp.url to " .. base_url)
  end
  base_url = base_url:gsub("/+$", "")

  if type(role) ~= "string" or role == "" then
    role = "runner"
  end

  -- If launched via `wget run https://cc.pants.place/init.lua`, persist /startup.lua automatically
  if not fs.exists("/startup.lua") then
    local boot_src = http_get_text(base_url .. "/init.lua", {})
    if boot_src and boot_src ~= "" then
      write_file("/startup.lua", boot_src)
      print("[bootstrap] Installed /startup.lua")
    end
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

      -- Build ordered sync list: self-updating startup, core libs, pkg CLI, role script
      local sync_targets = {
        { key = "bootstrap.lua", dest = "/startup.lua" },
        { key = "lib/std.lua", dest = "/lib/std.lua" },
        { key = "lib/crypto.lua", dest = "/lib/crypto.lua" },
        { key = "lib/mesh.lua", dest = "/lib/mesh.lua" },
        { key = "pkg.lua", dest = "/pkg.lua" },
        { key = role .. ".lua", dest = "/" .. role .. ".lua" },
      }
      if role == "gateway" then
        sync_targets[#sync_targets + 1] = { key = "runner.lua", dest = "/runner.lua" }
        sync_targets[#sync_targets + 1] = { key = "make_disk.lua", dest = "/make_disk.lua" }
        sync_targets[#sync_targets + 1] = { key = "apps/subnet_bridge.lua", dest = "/subnet_bridge.lua" }
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

  -- Auto-initialize encrypted multi-subnet mesh on the main gateway node
  if role == "gateway" and fs.exists("/lib/mesh.lua") and not fs.exists("/.mesh_net.json") then
    local ok_m, mesh_mod = pcall(require, "lib.mesh")
    if ok_m and type(mesh_mod) == "table" and type(mesh_mod.ensure_initialized) == "function" then
      local net_name = get_setting("mcp.net", "cc_mesh.net", "main")
      local ok_init, mcfg, created = pcall(mesh_mod.ensure_initialized, {
        mesh_name = net_name,
        subnet = net_name,
        role = "gateway",
        listen_s = 0.4,
      })
      if ok_init and created and type(mcfg) == "table" then
        print(("[bootstrap] Initialized encrypted mesh '%s' on ch %d (run `make_disk` to build node floppies)"):format(tostring(mcfg.mesh_name), tonumber(mcfg.channel) or 0))
      end
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
