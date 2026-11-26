-- cc-mesh-bridge Unified Mesh Node Installer Floppy Builder (/make_disk.lua)
-- Run directly on your main orchestrator/gateway node to write a self-contained
-- CC-Mesh Node Installer onto any attached floppy disk.
--
-- Supports provisioning ALL cluster node roles from a single floppy:
--   - bridge  : Remote Peripheral Node Bridge (e.g., main_nether, main_end)
--   - compute : Compute Pool Worker (32-PC farm: Rednet runner + encrypted mesh client)
--   - storage : Storage Pool Node (networked drive/inventory array bridge)
--   - client  : Client-only PC (installs /lib/* + /.mesh_net.json without overwriting /startup.lua)
--
-- Usage:
--   make_disk
--   make_disk right
--   make_disk --drive right --mesh main --fresh --non-interactive

local std = require("lib.std")
local crypto = require("lib.crypto")
local mesh = require("lib.mesh")

local cli_args = { ... }

local function parse_args(argv)
  local opts = {}
  local i = 1
  while i <= #argv do
    local a = argv[i]
    if a == "--drive" and argv[i + 1] then
      opts.drive = argv[i + 1]; i = i + 2
    elseif a == "--mesh" and argv[i + 1] then
      opts.mesh_name = argv[i + 1]; i = i + 2
    elseif a == "--subnet" and argv[i + 1] then
      opts.subnet = argv[i + 1]; i = i + 2
    elseif a == "--channel" and argv[i + 1] then
      opts.channel = tonumber(argv[i + 1]); i = i + 2
    elseif a == "--key" and argv[i + 1] then
      opts.key = argv[i + 1]; i = i + 2
    elseif a == "--listen" and argv[i + 1] then
      opts.listen_s = tonumber(argv[i + 1]); i = i + 2
    elseif a == "--fresh" then
      opts.fresh = true; i = i + 1
    elseif a == "--non-interactive" or a == "-y" then
      opts.non_interactive = true; i = i + 1
    elseif not a:match("^%-") and not opts.drive then
      opts.drive = a; i = i + 1
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
  return (v == "") and (default_val or "") or v
end

local function copy_file(src, dst)
  if not fs.exists(src) then return false end
  local dir = fs.getDir(dst)
  if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
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
  if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
  local wf = fs.open(path, "w")
  if not wf then error("Cannot write: " .. tostring(path)) end
  wf.write(content)
  wf.close()
end

local function find_floppy_drives()
  local out = {}
  if type(peripheral) ~= "table" or type(peripheral.getNames) ~= "function" then
    return out
  end
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "drive" then
      local ok_p, pres = pcall(peripheral.call, name, "isDiskPresent")
      local ok_d, has_d = pcall(peripheral.call, name, "hasData")
      local ok_m, mp = pcall(peripheral.call, name, "getMountPath")
      if ok_p and pres and ok_d and has_d and ok_m and type(mp) == "string" and mp ~= "" then
        out[#out + 1] = { name = name, mount = "/" .. mp:gsub("^/+", "") }
      end
    end
  end
  return out
end

local UNIFIED_NODE_INSTALLER = [[-- CC-Mesh Unified Node Installer (bridge / compute / storage / client)
-- Usage:
--   install
--   install --role bridge --subnet main_nether [--no-start]
--   install --role compute [--subnet main] [--no-start]
--   install --role storage --subnet main_storage [--no-start]
--   install --role client [--subnet main]

local argv = { ... }
local opts = {}
do
  local i = 1
  while i <= #argv do
    local a = argv[i]
    if a == "--role" and argv[i + 1] then opts.role = argv[i + 1]; i = i + 2
    elseif a == "--subnet" and argv[i + 1] then opts.subnet = argv[i + 1]; i = i + 2
    elseif a == "--label" and argv[i + 1] then opts.label = argv[i + 1]; i = i + 2
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
  local data = read_text(fs.combine(disk_dir, rel_src))
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
  error("[cc-mesh] Missing mesh_join.json on floppy (" .. disk_dir .. ")")
end
local join_cfg = textutils.unserialiseJSON(join_raw)
if type(join_cfg) ~= "table" or not join_cfg.channel or not join_cfg.key then
  error("[cc-mesh] Invalid mesh_join.json")
end

print("=== CC-Mesh Unified Node Installer ===")
print("Mesh:    " .. tostring(join_cfg.mesh_name))
print("Channel: " .. tostring(join_cfg.channel) .. " (HMAC-SHA256 encrypted)")
print("Roles:   bridge | compute | storage | client")

local role = opts.role
local subnet = opts.subnet
if (not role or role == "") and type(read) == "function" then
  role = prompt("Node role (bridge/compute/storage/client)", "compute")
end
if role ~= "bridge" and role ~= "compute" and role ~= "storage" and role ~= "client" then
  role = "compute"
end

local default_subnet = (role == "bridge")
  and (tostring(join_cfg.mesh_name) .. "_nether")
  or tostring(join_cfg.mesh_name)

if (not subnet or subnet == "") and type(read) == "function" then
  subnet = prompt("Subnet name", default_subnet)
end
if not subnet or subnet == "" then
  subnet = default_subnet
end

-- Always install core libraries + pkg CLI
copy_from_disk("payload/lib/std.lua", "/lib/std.lua")
copy_from_disk("payload/lib/crypto.lua", "/lib/crypto.lua")
copy_from_disk("payload/lib/mesh.lua", "/lib/mesh.lua")
copy_from_disk("payload/pkg.lua", "/pkg.lua")

-- Save encrypted mesh config on every node (so ANY node can call net.<subnet>.<periph>.<method>())
local local_mesh_cfg = {
  mesh_name = join_cfg.mesh_name,
  subnet = subnet,
  role = role,
  channel = join_cfg.channel,
  key = join_cfg.key,
  ttl = join_cfg.ttl or 4,
}
local mf = fs.open("/.mesh_net.json", "w")
mf.write(textutils.serialiseJSON(local_mesh_cfg))
mf.close()

-- Propagate optional Cloudflare MCP settings so nodes can use `pkg` and self-update
if type(settings) == "table" then
  if type(join_cfg.mcp_url) == "string" and join_cfg.mcp_url ~= "" then settings.set("mcp.url", join_cfg.mcp_url) end
  if type(join_cfg.cf_id) == "string" and join_cfg.cf_id ~= "" then settings.set("mcp.cf_id", join_cfg.cf_id) end
  if type(join_cfg.cf_secret) == "string" and join_cfg.cf_secret ~= "" then settings.set("mcp.cf_secret", join_cfg.cf_secret) end
  if type(join_cfg.world) == "string" and join_cfg.world ~= "" then settings.set("mcp.world", join_cfg.world) end
  settings.set("mcp.net", subnet)
end

-- Role-specific installation
local launch_script = nil
if role == "bridge" or role == "storage" then
  copy_from_disk("payload/subnet_bridge.lua", "/subnet_bridge.lua")
  if type(settings) == "table" then
    settings.set("mcp.role", role)
    settings.set("mcp.pool", role)
    settings.save()
  end
  local sf = fs.open("/startup.lua", "w")
  sf.write('-- Auto-generated by CC-Mesh Node Installer (' .. role .. ')\nshell.run("/subnet_bridge.lua")\n')
  sf.close()
  launch_script = "/subnet_bridge.lua"

elseif role == "compute" then
  copy_from_disk("payload/runner.lua", "/runner.lua")
  copy_from_disk("payload/bootstrap.lua", "/startup.lua")
  if type(settings) == "table" then
    settings.set("mcp.role", "runner")
    settings.set("mcp.pool", (turtle ~= nil) and "turtle" or "compute")
    settings.save()
  end
  launch_script = "/runner.lua"

else
  if type(settings) == "table" then
    settings.set("mcp.role", "client")
    settings.set("mcp.pool", "client")
    settings.save()
  end
end

if type(os.getComputerLabel) == "function" and type(os.setComputerLabel) == "function" then
  if opts.label and opts.label ~= "" then
    os.setComputerLabel(opts.label)
  elseif not os.getComputerLabel() then
    local prefix = (turtle ~= nil) and "turtle" or role
    os.setComputerLabel(prefix .. "_" .. tostring(os.getComputerID()))
  end
end

print(("[cc-mesh] Installed '%s' node on subnet '%s'!"):format(role, subnet))
if launch_script and not opts.no_start and type(shell) == "table" and type(shell.run) == "function" then
  print("[cc-mesh] Starting " .. launch_script .. "...")
  shell.run(launch_script)
elseif role == "client" then
  print('Usage: local net = require("lib.mesh").connect(); net.main_nether.storage_0.list()')
end
]]

local UNIFIED_DISK_STARTUP = [[-- CC-Mesh Node Installer Floppy Boot Guard
-- Never hijack an already-configured gateway or existing mesh node!
local is_gw = (type(settings) == "table" and (settings.get("mcp.role") == "gateway" or settings.get("cc_mesh.role") == "gateway"))
if is_gw or fs.exists("/.mesh_net.json") then
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

local function main()
  local opts = parse_args(cli_args)
  local interactive = (not opts.non_interactive) and (type(read) == "function")
  local mcp_cfg = std.get_config()

  local existing = (not opts.fresh) and mesh.load_config() or nil
  local mesh_cfg
  if existing and existing.channel and existing.key and not opts.channel and not opts.key then
    mesh_cfg = existing
    print(("[make_disk] Using existing mesh '%s' (ch %d, encrypted)"):format(mesh_cfg.mesh_name, mesh_cfg.channel))
  else
    local mname = opts.mesh_name or mcp_cfg.net_id or "main"
    local sname = opts.subnet or mname
    if interactive then
      mname = prompt("Mesh network name", mname, false)
      sname = prompt("Main node subnet name", sname, false)
    end
    local ch = opts.channel
    if not ch then
      print("[make_disk] Scanning for unused random channel (10000..65000)...")
      ch = mesh.scan_quiet_channel({ listen_s = opts.listen_s or 0.5 })
    end
    local key = (opts.key and opts.key ~= "") and opts.key or crypto.random_hex(32, mname)
    mesh_cfg = {
      mesh_name = mname,
      subnet = sname,
      role = "gateway",
      channel = ch,
      key = key,
      ttl = 4,
    }
    mesh.save_config(mesh_cfg)
    print(("[make_disk] Initialized mesh '%s' on ch %d (saved %s)"):format(mname, ch, mesh.CONFIG_PATH))
  end

  local drives = find_floppy_drives()
  local chosen = nil
  if opts.drive then
    for i = 1, #drives do
      if drives[i].name == opts.drive then chosen = drives[i]; break end
    end
  elseif #drives == 1 then
    chosen = drives[1]
  elseif #drives > 1 then
    if interactive then
      print("Attached floppy drives:")
      for i = 1, #drives do
        print("  " .. tostring(i) .. ") " .. drives[i].name .. " (" .. drives[i].mount .. ")")
      end
      local idx = tonumber(prompt("Select drive number", "1", false)) or 1
      chosen = drives[idx] or drives[1]
    else
      chosen = drives[1]
    end
  end

  if not chosen then
    print("[make_disk] No floppy disk found! Insert a blank floppy into a disk drive and re-run `make_disk`.")
    return false, mesh_cfg
  end

  local root = chosen.mount
  copy_file("/lib/std.lua", fs.combine(root, "payload/lib/std.lua"))
  copy_file("/lib/crypto.lua", fs.combine(root, "payload/lib/crypto.lua"))
  copy_file("/lib/mesh.lua", fs.combine(root, "payload/lib/mesh.lua"))
  copy_file("/runner.lua", fs.combine(root, "payload/runner.lua"))
  copy_file("/pkg.lua", fs.combine(root, "payload/pkg.lua"))
  copy_file("/subnet_bridge.lua", fs.combine(root, "payload/subnet_bridge.lua"))
  copy_file("/startup.lua", fs.combine(root, "payload/bootstrap.lua"))

  write_text(fs.combine(root, "mesh_join.json"), std.serialize_json({
    mesh_name = mesh_cfg.mesh_name,
    channel = mesh_cfg.channel,
    key = mesh_cfg.key,
    ttl = mesh_cfg.ttl or 4,
    mcp_url = mcp_cfg.url or "",
    cf_id = mcp_cfg.cf_id or "",
    cf_secret = mcp_cfg.cf_secret or "",
    world = mcp_cfg.world or "overworld",
  }))
  write_text(fs.combine(root, "install.lua"), UNIFIED_NODE_INSTALLER)
  write_text(fs.combine(root, "startup.lua"), UNIFIED_DISK_STARTUP)

  local label = "CC-Mesh Node Installer (" .. tostring(mesh_cfg.mesh_name) .. ")"
  pcall(peripheral.call, chosen.name, "setDiskLabel", label)

  print("[make_disk] Wrote '" .. label .. "' to " .. chosen.name .. " (" .. root .. ")!")
  print("Boot any computer/turtle with this disk (or run `disk/install`) to join as:")
  print("  - bridge  (Nether/End remote peripheral bridge)")
  print("  - compute (32-PC compute pool worker)")
  print("  - storage (networked drive/inventory storage pool)")
  print("  - client  (mesh client library only)")
  return true, mesh_cfg
end

return main()
