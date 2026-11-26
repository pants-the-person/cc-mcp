-- cc-mesh-bridge Encrypted Subnet Bridge Daemon (/subnet_bridge.lua)
-- Bridges local wired peripherals onto the encrypted wireless/ender mesh
-- and relays encrypted RPC frames between wired <-> ender modems.
--
-- Usage:
--   subnet_bridge [subnet_name]

local mesh = require("lib.mesh")

local cli_args = { ... }
local cfg = mesh.load_config()
if not cfg then
  print("[subnet_bridge] Missing /.mesh_net.json! Run `mesh_setup` or boot from a CC-Mesh Join floppy.")
  return false
end

if cli_args[1] and cli_args[1] ~= "" then
  cfg.subnet = cli_args[1]
end

local all_modems, wired, wireless = mesh.get_modems()
local local_periphs = mesh.scan_local_peripherals()
local pcount = 0
for _ in pairs(local_periphs) do
  pcount = pcount + 1
end

print("========================================")
print(" CC-Mesh Encrypted Subnet Bridge v" .. mesh.VERSION)
print(" Mesh:        " .. tostring(cfg.mesh_name))
print(" Subnet:      " .. tostring(cfg.subnet))
print(" Channel:     " .. tostring(cfg.channel) .. " (HMAC-SHA256 encrypted)")
print(" Modems:      " .. tostring(#all_modems) .. " (" .. tostring(#wired) .. " wired, " .. tostring(#wireless) .. " wireless/ender)")
print(" Peripherals: " .. tostring(pcount) .. " bridged")
print("========================================")

local stats = { exec = 0, relay = 0, rejected = 0 }

mesh.run_bridge({
  mesh_name = cfg.mesh_name,
  subnet = cfg.subnet,
  channel = cfg.channel,
  key = cfg.key,
  ttl = cfg.ttl,
  on_event = function(kind, info)
    if kind == "announce" then
      local n = 0
      if type(info.peripherals) == "table" then
        for _ in pairs(info.peripherals) do n = n + 1 end
      end
      print(("[mesh] Discovered subnet '%s' (%d peripherals)"):format(tostring(info.subnet), n))
    elseif kind == "rpc_exec" then
      stats.exec = stats.exec + 1
    elseif kind == "rpc_relay" then
      stats.relay = stats.relay + 1
    elseif kind == "rejected" then
      stats.rejected = stats.rejected + 1
    end
  end,
})
