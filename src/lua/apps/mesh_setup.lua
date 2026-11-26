-- cc-mesh-bridge Multi-Subnet Mesh Setup & Floppy Installer Generator
-- Run on your primary 'main' network to:
--   1. Randomize a private communication channel (scanning to ensure it is unused)
--   2. Generate a 256-bit authenticated encryption key (or reuse existing mesh key)
--   3. Save local /.mesh_net.json on this computer
--   4. Write a self-contained Subnet Join Installer onto a floppy disk
--
-- Usage:
--   mesh_setup
--   mesh_setup --mesh main --subnet main --drive right --non-interactive

local std = require("lib.std")
local crypto = require("lib.crypto")
local mesh = require("lib.mesh")

local cli_args = { ... }

local function parse_args(argv)
  local opts = {}
  local i = 1
  while i <= #argv do
    local a = argv[i]
    if a == "--mesh" and argv[i + 1] then
      opts.mesh_name = argv[i + 1]; i = i + 2
    elseif a == "--subnet" and argv[i + 1] then
      opts.subnet = argv[i + 1]; i = i + 2
    elseif a == "--drive" and argv[i + 1] then
      opts.drive = argv[i + 1]; i = i + 2
    elseif a == "--channel" and argv[i + 1] then
      opts.channel = tonumber(argv[i + 1]); i = i + 2
    elseif a == "--key" and argv[i + 1] then
      opts.key = argv[i + 1]; i = i + 2
    elseif a == "--listen" and argv[i + 1] then
      opts.listen_s = tonumber(argv[i + 1]); i = i + 2
    elseif a == "--non-interactive" or a == "-y" then
      opts.non_interactive = true; i = i + 1
    elseif a == "--fresh" then
      opts.fresh = true; i = i + 1
    else
      i = i + 1
    end
  end
  return opts
end

local function prompt(label, default_val, secret)
  local suffix = (default_val and default_val ~= "" and not secret)
    and (" [" .. tostring(default_val) .. "]: ")
    or ": "
  if type(write) == "function" then
    write(label .. suffix)
  else
    print(label .. suffix)
  end
  local v = secret and read("*") or read()
  v = tostring(v or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if v == "" then
    return default_val or ""
  end
  return v
end

local function copy_file(src, dst)
  if not fs.exists(src) then
    return false
  end
  local dir = fs.getDir(dst)
  if dir and dir ~= "" and not fs.exists(dir) then
    fs.makeDir(dir)
  end
  local rf = fs.open(src, "r")
  if not rf then return false end
  local data = rf.readAll() or ""
  rf.close()
  local wf = fs.open(dst, "w")
  if not wf then return false end
  wf.write(data)
  wf.close()
  return true
end

local function write_text(path, content)
  local dir = fs.getDir(path)
  if dir and dir ~= "" and not fs.exists(dir) then
    fs.makeDir(dir)
  end
  local wf = fs.open(path, "w")
  if not wf then
    error("Cannot write file: " .. tostring(path))
  end
  wf.write(content)
  wf.close()
end

local function find_floppy_drives()
  local drives = {}
  if type(peripheral) ~= "table" or type(peripheral.getNames) ~= "function" then
    return drives
  end
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "drive" then
      local ok_p, pres = pcall(peripheral.call, name, "isDiskPresent")
      local ok_d, has_d = pcall(peripheral.call, name, "hasData")
      local ok_m, mp = pcall(peripheral.call, name, "getMountPath")
      if ok_p and pres and ok_d and has_d and ok_m and type(mp) == "string" and mp ~= "" then
        drives[#drives + 1] = { name = name, mount = "/" .. mp:gsub("^/+", "") }
      end
    end
  end
  return drives
end

-- Generated installer script written to <disk>/install.lua
local SUBNET_INSTALL_SCRIPT = [[-- CC-Mesh Encrypted Subnet Join Installer
-- Run from the CC-Mesh Join floppy on any remote subnet (e.g. main_nether, main_end)
-- or compute-farm client PC.
--
-- Usage:
--   install
--   install --subnet main_nether --role bridge --no-start

local argv = { ... }
local opts = {}
do
  local i = 1
  while i <= #argv do
    local a = argv[i]
    if a == "--subnet" and argv[i + 1] then opts.subnet = argv[i + 1]; i = i + 2
    elseif a == "--role" and argv[i + 1] then opts.role = argv[i + 1]; i = i + 2
    elseif a == "--no-start" then opts.no_start = true; i = i + 1
    else i = i + 1 end
  end
end

local running = (type(shell) == "table" and type(shell.getRunningProgram) == "function")
  and shell.getRunningProgram()
  or "disk/install.lua"
local disk_dir = "/" .. fs.getDir(running)

local function read_text(p)
  if not fs.exists(p) then return nil end
  local f = fs.open(p, "r")
  if not f then return nil end
  local d = f.readAll()
  f.close()
  return d
end

local function copy_from_disk(rel_src, dst)
  local src = fs.combine(disk_dir, rel_src)
  local data = read_text(src)
  if not data then return false end
  local dir = fs.getDir(dst)
  if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
  local wf = fs.open(dst, "w")
  if not wf then return false end
  wf.write(data)
  wf.close()
  return true
end

local function prompt(label, default_val)
  local suffix = (default_val and default_val ~= "") and (" [" .. default_val .. "]: ") or ": "
  if type(write) == "function" then write(label .. suffix) else print(label .. suffix) end
  local v = tostring(read() or ""):gsub("^%s+", ""):gsub("%s+$", "")
  return (v == "") and (default_val or "") or v
end

local join_raw = read_text(fs.combine(disk_dir, "mesh_join.json"))
if not join_raw then
  error("[mesh-install] Missing mesh_join.json on floppy (" .. disk_dir .. ")")
end
local join_cfg = textutils.unserialiseJSON(join_raw)
if type(join_cfg) ~= "table" or not join_cfg.channel or not join_cfg.key then
  error("[mesh-install] Invalid mesh_join.json")
end

print("=== CC-Mesh Subnet Join Installer ===")
print("Mesh:    " .. tostring(join_cfg.mesh_name))
print("Channel: " .. tostring(join_cfg.channel) .. " (encrypted)")

local subnet = opts.subnet
local role = opts.role
if (not subnet or subnet == "") and type(read) == "function" then
  subnet = prompt("Subnet name (e.g. main_nether, main_end)", tostring(join_cfg.mesh_name) .. "_sub")
end
if not subnet or subnet == "" then
  subnet = tostring(join_cfg.mesh_name) .. "_sub"
end

if (not role or role == "") and type(read) == "function" then
  role = prompt("Role (bridge / client)", "bridge")
end
if role ~= "bridge" and role ~= "client" then
  role = "bridge"
end

-- Install libraries
copy_from_disk("payload/lib/std.lua", "/lib/std.lua")
copy_from_disk("payload/lib/crypto.lua", "/lib/crypto.lua")
copy_from_disk("payload/lib/mesh.lua", "/lib/mesh.lua")
if role == "bridge" then
  copy_from_disk("payload/subnet_bridge.lua", "/subnet_bridge.lua")
end

-- Save local encrypted mesh configuration
local local_cfg = {
  mesh_name = join_cfg.mesh_name,
  subnet = subnet,
  role = role,
  channel = join_cfg.channel,
  key = join_cfg.key,
  ttl = join_cfg.ttl or 4,
}
local cf = fs.open("/.mesh_net.json", "w")
cf.write(textutils.serialiseJSON(local_cfg))
cf.close()

if type(os.getComputerLabel) == "function" and not os.getComputerLabel() and type(os.setComputerLabel) == "function" then
  os.setComputerLabel(role .. "_" .. subnet)
end

if role == "bridge" then
  local sf = fs.open("/startup.lua", "w")
  sf.write('-- Auto-generated by CC-Mesh Subnet Join Installer\nshell.run("/subnet_bridge.lua")\n')
  sf.close()
  print("[mesh-install] Installed bridge for subnet '" .. subnet .. "' (+ /startup.lua)")
  if not opts.no_start and type(shell) == "table" and type(shell.run) == "function" then
    print("[mesh-install] Joining mesh now...")
    shell.run("/subnet_bridge.lua")
  end
else
  print("[mesh-install] Installed mesh client for subnet '" .. subnet .. "'")
  print("Example usage in Lua:")
  print('  local net = require("lib.mesh").connect()')
  print("  net.main_nether.storage_0.list()")
end
]]

local DISK_STARTUP_SCRIPT = [[-- CC-Mesh Join Floppy Boot Guard
-- Never hijack already-configured gateways or existing mesh nodes!
if fs.exists("/.mesh_net.json") or (type(settings) == "table" and (settings.get("mcp.role") == "gateway" or settings.get("cc_mesh.role") == "gateway")) then
  if fs.exists("/startup.lua") then
    return shell.run("/startup.lua")
  end
  return
end
local running = (type(shell) == "table" and type(shell.getRunningProgram) == "function")
  and shell.getRunningProgram()
  or "disk/startup.lua"
local disk_dir = "/" .. fs.getDir(running)
shell.run(fs.combine(disk_dir, "install.lua"))
]]

local function ensure_subnet_bridge_source()
  if fs.exists("/subnet_bridge.lua") then
    return "/subnet_bridge.lua"
  end
  -- Try downloading from Static Domain App Store if mcp.url is configured
  local cfg = std.get_config()
  if cfg.url and cfg.url ~= "" and type(http) == "table" and type(http.get) == "function" then
    local resp = http.get(cfg.url .. "/lua/apps/subnet_bridge.lua", cfg.headers)
    if resp then
      local code = type(resp.getResponseCode) == "function" and resp.getResponseCode() or 200
      local body = resp.readAll()
      resp.close()
      if code >= 200 and code < 300 and body and body ~= "" then
        write_text("/subnet_bridge.lua", body)
        return "/subnet_bridge.lua"
      end
    end
  end
  return nil
end

local function main()
  local opts = parse_args(cli_args)
  local interactive = (not opts.non_interactive) and (type(read) == "function")
  local existing = (not opts.fresh) and mesh.load_config() or nil

  print("=== CC-Mesh Multi-Subnet Setup & Floppy Builder ===")

  local mesh_name = opts.mesh_name or (existing and existing.mesh_name) or "main"
  local subnet = opts.subnet or (existing and existing.subnet) or mesh_name
  local channel = opts.channel or (existing and existing.channel) or nil
  local key = opts.key or (existing and existing.key) or nil

  if interactive then
    mesh_name = prompt("Mesh network name", mesh_name, false)
    subnet = prompt("This computer's subnet name", subnet, false)
    if existing and existing.channel and existing.key then
      local reuse = prompt("Reuse existing channel (" .. tostring(existing.channel) .. ") & encryption key? (y/n)", "y", false)
      if reuse:lower() ~= "y" and reuse:lower() ~= "yes" then
        channel = nil
        key = nil
      end
    end
  end

  if not channel then
    print("[mesh_setup] Scanning modems for an unused random channel (10000..65000)...")
    local quiet
    channel, quiet = mesh.scan_quiet_channel({ listen_s = opts.listen_s or 0.75 })
    print(("[mesh_setup] Selected channel %d (%s)"):format(channel, quiet and "verified quiet" or "best-effort"))
  end

  if not key or key == "" then
    local extra = interactive and prompt("Optional extra passphrase/entropy (Enter to auto-generate)", "", true) or ""
    key = crypto.random_hex(32, extra)
    print("[mesh_setup] Generated 256-bit authenticated encryption key")
  end

  local local_cfg = {
    mesh_name = mesh_name,
    subnet = subnet,
    role = "bridge",
    channel = channel,
    key = key,
    ttl = 4,
  }
  mesh.save_config(local_cfg)
  print("[mesh_setup] Saved local config to " .. mesh.CONFIG_PATH)

  -- Locate target floppy drive
  local drives = find_floppy_drives()
  local chosen = nil
  if opts.drive then
    for i = 1, #drives do
      if drives[i].name == opts.drive then
        chosen = drives[i]
        break
      end
    end
  elseif #drives == 1 then
    chosen = drives[1]
  elseif #drives > 1 then
    if interactive then
      print("Detected floppy drives:")
      for i = 1, #drives do
        print("  " .. tostring(i) .. ") " .. drives[i].name .. " (" .. drives[i].mount .. ")")
      end
      local pick = tonumber(prompt("Select drive number", "1", false)) or 1
      chosen = drives[pick] or drives[1]
    else
      chosen = drives[1]
    end
  end

  if not chosen then
    print("[mesh_setup] No floppy disk found in any drive. Local config saved; re-run with a floppy inserted to build the installer disk.")
    return local_cfg
  end

  local root = chosen.mount
  local bridge_src = ensure_subnet_bridge_source()

  copy_file("/lib/std.lua", fs.combine(root, "payload/lib/std.lua"))
  copy_file("/lib/crypto.lua", fs.combine(root, "payload/lib/crypto.lua"))
  copy_file("/lib/mesh.lua", fs.combine(root, "payload/lib/mesh.lua"))
  if bridge_src then
    copy_file(bridge_src, fs.combine(root, "payload/subnet_bridge.lua"))
  end

  write_text(fs.combine(root, "mesh_join.json"), std.serialize_json({
    mesh_name = mesh_name,
    channel = channel,
    key = key,
    ttl = 4,
  }))
  write_text(fs.combine(root, "install.lua"), SUBNET_INSTALL_SCRIPT)
  write_text(fs.combine(root, "startup.lua"), DISK_STARTUP_SCRIPT)
  pcall(peripheral.call, chosen.name, "setDiskLabel", "CC-Mesh Join (" .. mesh_name .. ")")

  print("[mesh_setup] Floppy installer written to " .. chosen.name .. " (" .. root .. ")!")
  print("Next steps:")
  print("  1. On main's Ender-equipped bridge: run `/subnet_bridge.lua`")
  print("  2. Carry floppy to Nether/End computer, boot or run `disk/install`, enter `main_nether` / `main_end`")
  print('  3. From any farm PC: `local net = require("lib.mesh").connect(); net.main_nether.storage_0.list()`')
  return local_cfg
end

return main()
