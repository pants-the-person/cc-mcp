-- cc-mesh-bridge Encrypted Multi-Subnet Peripheral Mesh (/lib/mesh.lua)
-- Enables transparent remote peripheral wrapping across Wired + Ender/Wireless subnets:
--   local mesh = require("lib.mesh")
--   local net = mesh.connect()
--   local items = net.main_nether.storage_0.list()
--
-- Features:
--   - Authenticated encryption (SHA256-CTR + HMAC-SHA256 via lib.crypto)
--   - Collision-checked randomized private modem channels (10000..65000)
--   - Dual-homed wired <-> ender/wireless relay with loop deduplication
--   - Automatic local peripheral discovery & hot-plug announcements

local std = require("lib.std")
local crypto = require("lib.crypto")

local mesh = {}
mesh.VERSION = "1.0.0"
mesh.CONFIG_PATH = "/.mesh_net.json"

local unpack_fn = table.unpack or unpack

local function now_ms()
  if type(os) == "table" and type(os.epoch) == "function" then
    return os.epoch("utc")
  end
  return 0
end

local function computer_id()
  if type(os) == "table" and type(os.getComputerID) == "function" then
    return os.getComputerID()
  end
  return 0
end

local function is_modem(name)
  if type(peripheral) ~= "table" or type(peripheral.getType) ~= "function" then
    return false
  end
  local types = { peripheral.getType(name) }
  for i = 1, #types do
    if types[i] == "modem" then
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Config Persistence (/.mesh_net.json)
-- ---------------------------------------------------------------------------

function mesh.load_config(path)
  path = path or mesh.CONFIG_PATH
  if type(fs) == "table" and fs.exists(path) then
    local f = fs.open(path, "r")
    if f then
      local raw = f.readAll()
      f.close()
      local parsed = std.deserialize_json(raw)
      if type(parsed) == "table" then
        return parsed
      end
    end
  end
  return nil
end

function mesh.save_config(cfg, path)
  path = path or mesh.CONFIG_PATH
  if type(fs) ~= "table" then
    return false, "fs unavailable"
  end
  local dir = fs.getDir(path)
  if dir and dir ~= "" and not fs.exists(dir) then
    fs.makeDir(dir)
  end
  local f = fs.open(path, "w")
  if not f then
    return false, "failed to open " .. tostring(path)
  end
  f.write(std.serialize_json(cfg))
  f.close()
  return true, nil
end

function mesh.ensure_initialized(opts)
  opts = type(opts) == "table" and opts or {}
  local existing = mesh.load_config(opts.config_path)
  if existing and existing.channel and existing.key and existing.key ~= "" then
    return existing, false
  end
  local mesh_name = opts.mesh_name or "main"
  local subnet = opts.subnet or mesh_name
  local role = opts.role or "gateway"
  local channel = tonumber(opts.channel)
  if not channel then
    channel = mesh.scan_quiet_channel({ listen_s = tonumber(opts.listen_s) or 0.5 })
  end
  local key = (type(opts.key) == "string" and opts.key ~= "") and opts.key or crypto.random_hex(32, opts.entropy)
  local cfg = {
    mesh_name = mesh_name,
    subnet = subnet,
    role = role,
    channel = channel,
    key = key,
    ttl = tonumber(opts.ttl) or 4,
  }
  mesh.save_config(cfg, opts.config_path)
  return cfg, true
end

-- ---------------------------------------------------------------------------
-- Modem Discovery & Quiet Channel Scanner
-- ---------------------------------------------------------------------------

function mesh.get_modems()
  local all, wired, wireless = {}, {}, {}
  if type(peripheral) ~= "table" or type(peripheral.getNames) ~= "function" then
    return all, wired, wireless
  end
  for _, name in ipairs(peripheral.getNames()) do
    if is_modem(name) then
      all[#all + 1] = name
      local ok, is_wl = pcall(peripheral.call, name, "isWireless")
      if ok and is_wl then
        wireless[#wireless + 1] = name
      else
        wired[#wired + 1] = name
      end
    end
  end
  return all, wired, wireless
end

function mesh.open_channel_on_all(channel)
  local modems = mesh.get_modems()
  local opened = {}
  for i = 1, #modems do
    local name = modems[i]
    local ok = pcall(peripheral.call, name, "open", channel)
    if ok then
      opened[#opened + 1] = name
    end
  end
  return opened
end

function mesh.scan_quiet_channel(opts)
  opts = type(opts) == "table" and opts or {}
  local min_ch = tonumber(opts.min_channel) or 10000
  local max_ch = tonumber(opts.max_channel) or 65000
  local listen_s = tonumber(opts.listen_s) or 0.75
  local max_attempts = tonumber(opts.max_attempts) or 12
  local exclude = {}
  if type(opts.exclude) == "table" then
    for _, ch in ipairs(opts.exclude) do
      exclude[ch] = true
    end
  end
  exclude[65533] = true
  exclude[65535] = true

  local all_modems, _, wireless_modems = mesh.get_modems()
  local scan_modems = (#wireless_modems > 0) and wireless_modems or all_modems

  local function pick_random_channel(attempt)
    local h = crypto.random_bytes(4, "ch:" .. tostring(attempt))
    local b1, b2, b3, b4 = string.byte(h, 1, 4)
    local n = (b1 * 16777216 + b2 * 65536 + b3 * 256 + b4)
    return min_ch + (n % (max_ch - min_ch + 1))
  end

  local tested = {}
  for attempt = 1, max_attempts do
    local candidate
    if type(opts.candidates) == "table" and opts.candidates[attempt] then
      candidate = tonumber(opts.candidates[attempt])
    else
      candidate = pick_random_channel(attempt)
    end

    if candidate and not exclude[candidate] and not tested[candidate] then
      tested[candidate] = true
      if #scan_modems == 0 or listen_s <= 0 then
        return candidate, true
      end

      -- Track which modems already had this channel open so we restore cleanly
      local opened_here = {}
      for i = 1, #scan_modems do
        local m = scan_modems[i]
        local ok_open, was_open = pcall(peripheral.call, m, "isOpen", candidate)
        if not (ok_open and was_open) then
          pcall(peripheral.call, m, "open", candidate)
          opened_here[#opened_here + 1] = m
        end
      end

      local busy = false
      local tid = os.startTimer(listen_s)
      while true do
        local ev, p1, p2 = os.pullEvent()
        if ev == "modem_message" and p2 == candidate then
          busy = true
          break
        elseif ev == "timer" and p1 == tid then
          break
        end
      end

      for i = 1, #opened_here do
        pcall(peripheral.call, opened_here[i], "close", candidate)
      end

      if not busy then
        return candidate, true
      end
    end
  end

  return pick_random_channel(max_attempts + 1), false
end

-- ---------------------------------------------------------------------------
-- Encrypted Frame Helpers
-- ---------------------------------------------------------------------------

local function make_aad(mesh_name, channel)
  return tostring(mesh_name or "main") .. ":" .. tostring(channel)
end

local function build_wire_frame(cfg, inner_payload, hops)
  local aad = make_aad(cfg.mesh_name, cfg.channel)
  local pt = std.serialize_json(inner_payload)
  local env, err = crypto.seal(cfg.key, pt, aad)
  if not env then
    return nil, err
  end
  return {
    _cc_mesh = 1,
    mesh = cfg.mesh_name,
    id = crypto.random_hex(8),
    hops = hops or 0,
    ttl = tonumber(cfg.ttl) or 4,
    env = env,
  }, nil
end

local function parse_wire_frame(cfg, raw_msg)
  if type(raw_msg) ~= "table" or raw_msg._cc_mesh ~= 1 then
    return nil, "not a mesh frame"
  end
  if raw_msg.mesh ~= cfg.mesh_name then
    return nil, "mesh mismatch"
  end
  local aad = make_aad(cfg.mesh_name, cfg.channel)
  local pt, err = crypto.open(cfg.key, raw_msg.env, aad)
  if not pt then
    return nil, err
  end
  local inner = std.deserialize_json(pt)
  if type(inner) ~= "table" or type(inner.type) ~= "string" then
    return nil, "invalid decrypted payload"
  end
  return inner, nil
end

local function transmit_on_modems(modems, channel, frame, skip_modem)
  local sent = 0
  for i = 1, #modems do
    local m = modems[i]
    if m ~= skip_modem then
      local ok = pcall(peripheral.call, m, "transmit", channel, channel, frame)
      if ok then
        sent = sent + 1
      end
    end
  end
  return sent
end

-- ---------------------------------------------------------------------------
-- Local Peripheral Enumeration (for Subnet Bridges)
-- ---------------------------------------------------------------------------

function mesh.scan_local_peripherals()
  local out = {}
  if type(peripheral) ~= "table" or type(peripheral.getNames) ~= "function" then
    return out
  end
  for _, name in ipairs(peripheral.getNames()) do
    if not is_modem(name) then
      local types = { peripheral.getType(name) }
      local methods = peripheral.getMethods(name) or {}
      out[name] = {
        name = name,
        type = types[1] or "unknown",
        types = types,
        methods = methods,
      }
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Client Proxy: net.<subnet>.<peripheral>.<method>(...)
-- ---------------------------------------------------------------------------

local function resolve_cfg(opts)
  opts = type(opts) == "table" and opts or {}
  local file_cfg = mesh.load_config(opts.config_path) or {}
  local cfg = {
    mesh_name = opts.mesh_name or file_cfg.mesh_name or "main",
    subnet = opts.subnet or file_cfg.subnet or "main",
    channel = tonumber(opts.channel or file_cfg.channel),
    key = opts.key or file_cfg.key,
    ttl = tonumber(opts.ttl or file_cfg.ttl) or 4,
    timeout = tonumber(opts.timeout or file_cfg.timeout) or 5.0,
  }
  if not cfg.channel or not cfg.key or cfg.key == "" then
    error("[mesh] Missing mesh channel/key. Run `mesh_setup` or provide config.")
  end
  return cfg
end

function mesh.connect(opts)
  local cfg = resolve_cfg(opts)
  local modems = mesh.open_channel_on_all(cfg.channel)
  if #modems == 0 then
    error("[mesh] No attached modem found for mesh client")
  end

  local cache = {} -- subnet -> { bridge_id, peripherals = { name -> info }, last_seen }

  local function send_and_wait_rpc(dst_subnet, periph_name, method_name, call_args, timeout_s)
    -- Fast path: if targeting our own subnet and peripheral is directly local
    if dst_subnet == cfg.subnet and type(peripheral) == "table" and peripheral.isPresent(periph_name) and not is_modem(periph_name) then
      if method_name == "__mesh_getMethods" then
        return true, { peripheral.getMethods(periph_name) or {} }, 1, nil
      elseif method_name == "__mesh_getType" then
        local types = { peripheral.getType(periph_name) }
        return true, types, #types, nil
      elseif method_name == "__mesh_isPresent" then
        return true, { true }, 1, nil
      end
      local packed = { pcall(peripheral.call, periph_name, method_name, unpack_fn(call_args, 1, call_args.n or #call_args)) }
      if packed[1] then
        local returns = {}
        local n = #packed - 1
        for i = 1, n do
          returns[i] = packed[i + 1]
        end
        return true, returns, n, nil
      else
        return false, nil, 0, tostring(packed[2])
      end
    end

    local req_id = crypto.random_hex(8)
    local payload = {
      type = "MESH_RPC_CALL",
      req_id = req_id,
      src_subnet = cfg.subnet,
      src_id = computer_id(),
      dst_subnet = dst_subnet,
      peripheral = periph_name,
      method = method_name,
      args = std.sanitize_for_json(call_args),
      ts = now_ms(),
    }

    local frame, err = build_wire_frame(cfg, payload, 0)
    if not frame then
      return false, nil, 0, "encrypt failed: " .. tostring(err)
    end

    local active_modems = mesh.open_channel_on_all(cfg.channel)
    transmit_on_modems(active_modems, cfg.channel, frame)

    local tid = os.startTimer(timeout_s or cfg.timeout)
    while true do
      local ev, _side, ch, _reply, raw_msg = os.pullEvent()
      if ev == "modem_message" and ch == cfg.channel then
        local inner = parse_wire_frame(cfg, raw_msg)
        if inner and inner.type == "MESH_RPC_RESP" and inner.req_id == req_id then
          if type(os.cancelTimer) == "function" then
            pcall(os.cancelTimer, tid)
          end
          if inner.ok then
            local rets = type(inner.returns) == "table" and inner.returns or {}
            local n = tonumber(inner.n) or #rets
            return true, rets, n, nil
          else
            return false, nil, 0, tostring(inner.error or "remote RPC error")
          end
        end
      elseif ev == "timer" and _side == tid then
        return false, nil, 0, "RPC timeout calling " .. dst_subnet .. "." .. periph_name .. "." .. method_name
      end
    end
  end

  local function discover(timeout_s)
    local req_id = crypto.random_hex(8)
    local frame = build_wire_frame(cfg, {
      type = "MESH_DISCOVER",
      req_id = req_id,
      src_subnet = cfg.subnet,
      src_id = computer_id(),
      ts = now_ms(),
    }, 0)

    local active_modems = mesh.open_channel_on_all(cfg.channel)
    transmit_on_modems(active_modems, cfg.channel, frame)

    local tid = os.startTimer(timeout_s or 1.0)
    while true do
      local ev, _side, ch, _reply, raw_msg = os.pullEvent()
      if ev == "modem_message" and ch == cfg.channel then
        local inner = parse_wire_frame(cfg, raw_msg)
        if inner and inner.type == "MESH_ANNOUNCE" and type(inner.subnet) == "string" then
          cache[inner.subnet] = {
            subnet = inner.subnet,
            bridge_id = inner.bridge_id,
            peripherals = type(inner.peripherals) == "table" and inner.peripherals or {},
            last_seen = now_ms(),
          }
        end
      elseif ev == "timer" and _side == tid then
        break
      end
    end
    return cache
  end

  local function make_peripheral_proxy(subnet_name, periph_name)
    local proxy = {
      _subnet = subnet_name,
      _name = periph_name,
    }
    return setmetatable(proxy, {
      __index = function(_, method_name)
        if method_name == "getMethods" then
          return function()
            local ok, rets, n, err = send_and_wait_rpc(subnet_name, periph_name, "__mesh_getMethods", {})
            if not ok then error(err, 2) end
            return unpack_fn(rets, 1, n)
          end
        elseif method_name == "getType" then
          return function()
            local ok, rets, n, err = send_and_wait_rpc(subnet_name, periph_name, "__mesh_getType", {})
            if not ok then error(err, 2) end
            return unpack_fn(rets, 1, n)
          end
        elseif method_name == "isPresent" then
          return function()
            local ok, rets, n = send_and_wait_rpc(subnet_name, periph_name, "__mesh_isPresent", {})
            if not ok then return false end
            return unpack_fn(rets, 1, n)
          end
        end
        return function(...)
          local arg_n = select("#", ...)
          local arg_tbl = { ... }
          arg_tbl.n = arg_n
          local ok, rets, n, err = send_and_wait_rpc(subnet_name, periph_name, tostring(method_name), arg_tbl)
          if not ok then
            error(err, 2)
          end
          return unpack_fn(rets, 1, n)
        end
      end,
    })
  end

  local function make_subnet_proxy(subnet_name)
    local sproxy = {
      _subnet = subnet_name,
      _peripherals = function()
        if not cache[subnet_name] then
          discover(0.5)
        end
        return (cache[subnet_name] and cache[subnet_name].peripherals) or {}
      end,
      _wrap = function(periph_name)
        return make_peripheral_proxy(subnet_name, periph_name)
      end,
    }
    return setmetatable(sproxy, {
      __index = function(_, periph_name)
        return make_peripheral_proxy(subnet_name, tostring(periph_name))
      end,
    })
  end

  local net = {
    _config = cfg,
    _cache = cache,
    _discover = discover,
    _subnets = function()
      local names = {}
      for k in pairs(cache) do
        names[#names + 1] = k
      end
      table.sort(names)
      return names
    end,
    _peripherals = function(subnet_name)
      if not cache[subnet_name] then
        discover(0.5)
      end
      return (cache[subnet_name] and cache[subnet_name].peripherals) or {}
    end,
    _storage = function(timeout_s)
      discover(timeout_s or 0.5)
      local drives = {}
      local inventories = {}
      -- Include local peripherals on our own subnet too
      local all_subnets = {}
      for sname, sinfo in pairs(cache) do
        all_subnets[sname] = sinfo.peripherals or {}
      end
      if not all_subnets[cfg.subnet] then
        all_subnets[cfg.subnet] = mesh.scan_local_peripherals()
      end
      for sname, periphs in pairs(all_subnets) do
        for pname, pinfo in pairs(periphs) do
          local ptype = pinfo.type or ""
          local types = type(pinfo.types) == "table" and pinfo.types or { ptype }
          local is_drive, is_inv = false, false
          for _, t in ipairs(types) do
            if t == "drive" then is_drive = true end
            if t == "inventory" or t:find("chest", 1, true) or t:find("barrel", 1, true) or t:find("storage", 1, true) or t:find("meBridge", 1, true) then
              is_inv = true
            end
          end
          if type(pinfo.methods) == "table" then
            for _, m in ipairs(pinfo.methods) do
              if m == "list" or m == "listItems" then is_inv = true end
            end
          end
          if is_drive then
            drives[#drives + 1] = { subnet = sname, name = pname, type = ptype, proxy = make_peripheral_proxy(sname, pname) }
          end
          if is_inv then
            inventories[#inventories + 1] = { subnet = sname, name = pname, type = ptype, proxy = make_peripheral_proxy(sname, pname) }
          end
        end
      end
      return { drives = drives, inventories = inventories }
    end,
    _wrap = function(subnet_name, periph_name)
      return make_peripheral_proxy(subnet_name, periph_name)
    end,
    _call = function(subnet_name, periph_name, method_name, ...)
      local arg_tbl = { ... }
      arg_tbl.n = select("#", ...)
      local ok, rets, n, err = send_and_wait_rpc(subnet_name, periph_name, method_name, arg_tbl)
      if not ok then error(err, 2) end
      return unpack_fn(rets, 1, n)
    end,
  }

  return setmetatable(net, {
    __index = function(_, subnet_name)
      return make_subnet_proxy(tostring(subnet_name))
    end,
  })
end

function mesh.wrap(subnet_name, periph_name, opts)
  local net = mesh.connect(opts)
  return net._wrap(subnet_name, periph_name)
end

-- ---------------------------------------------------------------------------
-- Dual-Homed Encrypted Subnet Bridge (Embeddable Handler + Standalone Daemon)
-- ---------------------------------------------------------------------------

function mesh.create_bridge_handler(opts)
  local cfg = resolve_cfg(opts)
  local my_subnet = cfg.subnet
  local my_role = (type(opts) == "table" and opts.role) or cfg.role or "bridge"
  local channel = cfg.channel
  local on_event = type(opts) == "table" and opts.on_event or nil

  local modems = mesh.open_channel_on_all(channel)
  local local_periphs = mesh.scan_local_peripherals()
  local remote_subnets = {}

  -- Bounded ring buffer of seen message IDs to prevent relay loops
  local seen_map = {}
  local seen_queue = {}
  local seen_max = 256
  local function mark_seen(msg_id)
    if not msg_id or seen_map[msg_id] then
      return false
    end
    seen_map[msg_id] = true
    seen_queue[#seen_queue + 1] = msg_id
    if #seen_queue > seen_max then
      local oldest = table.remove(seen_queue, 1)
      seen_map[oldest] = nil
    end
    return true
  end

  local function broadcast_announce(req_id, only_modem)
    local_periphs = mesh.scan_local_peripherals()
    local frame = build_wire_frame(cfg, {
      type = "MESH_ANNOUNCE",
      subnet = my_subnet,
      role = my_role,
      bridge_id = computer_id(),
      peripherals = local_periphs,
      req_id = req_id,
      ts = now_ms(),
    }, 0)
    if not frame then return end
    mark_seen(frame.id)
    if only_modem then
      transmit_on_modems({ only_modem }, channel, frame)
    else
      modems = mesh.open_channel_on_all(channel)
      transmit_on_modems(modems, channel, frame)
    end
  end

  local function broadcast_discover()
    local frame = build_wire_frame(cfg, {
      type = "MESH_DISCOVER",
      req_id = crypto.random_hex(8),
      src_subnet = my_subnet,
      src_id = computer_id(),
      ts = now_ms(),
    }, 0)
    if not frame then return end
    mark_seen(frame.id)
    modems = mesh.open_channel_on_all(channel)
    transmit_on_modems(modems, channel, frame)
  end

  local function relay_frame(raw_msg, incoming_modem)
    local hops = tonumber(raw_msg.hops) or 0
    local ttl = tonumber(raw_msg.ttl) or cfg.ttl or 4
    if hops + 1 > ttl then
      return 0
    end
    local forwarded = {
      _cc_mesh = raw_msg._cc_mesh,
      mesh = raw_msg.mesh,
      id = raw_msg.id,
      hops = hops + 1,
      ttl = ttl,
      env = raw_msg.env,
    }
    modems = mesh.open_channel_on_all(channel)
    return transmit_on_modems(modems, channel, forwarded, incoming_modem)
  end

  local function execute_rpc(inner, incoming_modem)
    local pname = tostring(inner.peripheral or "")
    local mname = tostring(inner.method or "")
    local ok, returns, n, err_msg = false, {}, 0, nil

    if not peripheral.isPresent(pname) or is_modem(pname) then
      err_msg = "Peripheral not found on subnet " .. my_subnet .. ": " .. pname
    elseif mname == "__mesh_getMethods" then
      ok, returns, n = true, { peripheral.getMethods(pname) or {} }, 1
    elseif mname == "__mesh_getType" then
      local types = { peripheral.getType(pname) }
      ok, returns, n = true, types, #types
    elseif mname == "__mesh_isPresent" then
      ok, returns, n = true, { true }, 1
    else
      local args = type(inner.args) == "table" and inner.args or {}
      local packed = { pcall(peripheral.call, pname, mname, unpack_fn(args)) }
      if packed[1] then
        ok = true
        n = #packed - 1
        for i = 1, n do
          returns[i] = std.sanitize_for_json(packed[i + 1])
        end
      else
        err_msg = tostring(packed[2])
      end
    end

    local resp_frame = build_wire_frame(cfg, {
      type = "MESH_RPC_RESP",
      req_id = inner.req_id,
      src_subnet = my_subnet,
      dst_subnet = inner.src_subnet,
      dst_id = inner.src_id,
      ok = ok,
      returns = returns,
      n = n,
      error = err_msg,
      ts = now_ms(),
    }, 0)
    if resp_frame then
      mark_seen(resp_frame.id)
      transmit_on_modems({ incoming_modem }, channel, resp_frame)
    end
  end

  local function handle_event(ev, p1, p2, _p3, p4)
    if ev == "modem_message" and p2 == channel then
      local incoming_modem = p1
      local raw_msg = p4
      if type(raw_msg) == "table" and raw_msg._cc_mesh == 1 and mark_seen(raw_msg.id) then
        local inner, dec_err = parse_wire_frame(cfg, raw_msg)
        if inner then
          if inner.type == "MESH_DISCOVER" then
            broadcast_announce(inner.req_id, incoming_modem)
            relay_frame(raw_msg, incoming_modem)

          elseif inner.type == "MESH_ANNOUNCE" then
            if type(inner.subnet) == "string" and inner.subnet ~= my_subnet then
              remote_subnets[inner.subnet] = {
                subnet = inner.subnet,
                role = inner.role or "bridge",
                bridge_id = inner.bridge_id,
                peripherals = inner.peripherals or {},
                last_seen = now_ms(),
              }
              if type(on_event) == "function" then
                pcall(on_event, "announce", inner)
              end
            end
            relay_frame(raw_msg, incoming_modem)

          elseif inner.type == "MESH_RPC_CALL" then
            if inner.dst_subnet == my_subnet then
              execute_rpc(inner, incoming_modem)
              if type(on_event) == "function" then
                pcall(on_event, "rpc_exec", inner)
              end
            else
              relay_frame(raw_msg, incoming_modem)
              if type(on_event) == "function" then
                pcall(on_event, "rpc_relay", inner)
              end
            end

          elseif inner.type == "MESH_RPC_RESP" then
            relay_frame(raw_msg, incoming_modem)
          end
        elseif type(on_event) == "function" then
          pcall(on_event, "rejected", dec_err)
        end
      end
      return true

    elseif ev == "peripheral" and type(p1) == "string" then
      if is_modem(p1) then
        pcall(peripheral.call, p1, "open", channel)
        modems = mesh.open_channel_on_all(channel)
      end
      broadcast_announce(nil, nil)
      return true

    elseif ev == "peripheral_detach" and type(p1) == "string" then
      modems = mesh.open_channel_on_all(channel)
      broadcast_announce(nil, nil)
      return true
    end
    return false
  end

  local function get_storage_pool()
    local drives = {}
    local inventories = {}
    local function collect(sname, periphs)
      for pname, pinfo in pairs(periphs or {}) do
        local ptype = pinfo.type or ""
        local types = type(pinfo.types) == "table" and pinfo.types or { ptype }
        local is_drive, is_inv = false, false
        for _, t in ipairs(types) do
          if t == "drive" then is_drive = true end
          if t == "inventory" or t:find("chest", 1, true) or t:find("barrel", 1, true) or t:find("storage", 1, true) or t:find("meBridge", 1, true) then
            is_inv = true
          end
        end
        if type(pinfo.methods) == "table" then
          for _, m in ipairs(pinfo.methods) do
            if m == "list" or m == "listItems" then is_inv = true end
          end
        end
        if is_drive then drives[#drives + 1] = { subnet = sname, name = pname, type = ptype } end
        if is_inv then inventories[#inventories + 1] = { subnet = sname, name = pname, type = ptype } end
      end
    end
    collect(my_subnet, mesh.scan_local_peripherals())
    for sname, sinfo in pairs(remote_subnets) do
      collect(sname, sinfo.peripherals)
    end
    return { drives = drives, inventories = inventories }
  end

  return {
    config = cfg,
    channel = channel,
    subnet = my_subnet,
    modems = modems,
    announce = function() broadcast_announce(nil, nil) end,
    discover = broadcast_discover,
    handle_event = handle_event,
    get_remote_subnets = function() return remote_subnets end,
    get_local_peripherals = function() return mesh.scan_local_peripherals() end,
    get_storage_pool = get_storage_pool,
  }
end

function mesh.run_bridge(opts)
  local handler = mesh.create_bridge_handler(opts)
  handler.announce()
  handler.discover()
  print(("[mesh] Subnet bridge '%s' online on ch %d (%d modems)"):format(handler.subnet, handler.channel, #handler.modems))

  while true do
    local ev, p1, p2, p3, p4 = os.pullEvent()
    handler.handle_event(ev, p1, p2, p3, p4)
  end
end

return mesh
