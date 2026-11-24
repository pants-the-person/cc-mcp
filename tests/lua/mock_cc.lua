-- Headless CC: Tweaked Runtime Emulator (Pure Standard Lua 5.2/5.3/5.4/LuaJIT)
-- Emulates os, http, ws, rednet, peripheral, fs, rs/redstone, settings,
-- textutils, shell, term, colors, sleep, and multi-computer coroutine scheduling.

local unpack = table.unpack or unpack

local mock_cc = {}

-- ---------------------------------------------------------------------------
-- Pure-Lua JSON Encoder & Decoder (emulating CC: Tweaked textutils.*JSON)
-- ---------------------------------------------------------------------------

local ESCAPE_MAP = {
  ["\\"] = "\\\\",
  ['"'] = '\\"',
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

local function is_array(tbl)
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

local function encode_json_string(s)
  local escaped = s:gsub('[\\"\b\f\n\r\t%z\1-\31]', function(c)
    if ESCAPE_MAP[c] then
      return ESCAPE_MAP[c]
    end
    return string.format("\\u%04x", string.byte(c))
  end)
  return '"' .. escaped .. '"'
end

local function json_encode(val, seen)
  local t = type(val)
  if t == "nil" then
    return "null"
  elseif t == "boolean" then
    return val and "true" or "false"
  elseif t == "number" then
    if val ~= val or val == math.huge or val == -math.huge then
      error("Cannot serialise non-finite number to JSON")
    end
    if math.floor(val) == val and val >= -9007199254740992 and val <= 9007199254740992 then
      return string.format("%.0f", val)
    end
    return tostring(val)
  elseif t == "string" then
    return encode_json_string(val)
  elseif t == "table" then
    seen = seen or {}
    if seen[val] then
      error("Cannot serialise circular table")
    end
    seen[val] = true
    local arr, len = is_array(val)
    local out
    if arr then
      local parts = {}
      for i = 1, len do
        parts[i] = json_encode(val[i], seen)
      end
      out = "[" .. table.concat(parts, ",") .. "]"
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
        parts[i] = encode_json_string(k) .. ":" .. json_encode(v, seen)
      end
      out = "{" .. table.concat(parts, ",") .. "}"
    end
    seen[val] = nil
    return out
  else
    error("Cannot serialise type " .. t .. " to JSON")
  end
end

local function json_decode(str)
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
    pos = pos + 1
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
          out[#out + 1] = code < 128 and string.char(code) or "?"
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
    error("Unterminated string")
  end

  local function parse_number()
    local num_str = str:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
    if not num_str or #num_str == 0 then
      error("Invalid number at " .. pos)
    end
    pos = pos + #num_str
    return tonumber(num_str)
  end

  local function parse_array()
    pos = pos + 1
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
        error("Expected ',' or ']' at " .. pos)
      end
    end
    error("Unterminated array")
  end

  local function parse_object()
    pos = pos + 1
    local obj = {}
    skip_ws()
    if str:sub(pos, pos) == "}" then
      pos = pos + 1
      return obj
    end
    while pos <= len do
      skip_ws()
      if str:sub(pos, pos) ~= '"' then
        error("Expected key string at " .. pos)
      end
      local k = parse_string()
      skip_ws()
      if str:sub(pos, pos) ~= ":" then
        error("Expected ':' at " .. pos)
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
        error("Expected ',' or '}' at " .. pos)
      end
    end
    error("Unterminated object")
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

  local ok, val = pcall(parse_value)
  if not ok then
    return nil, val
  end
  return val
end

mock_cc.json_encode = json_encode
mock_cc.json_decode = json_decode

local function deep_copy(val, seen)
  if type(val) ~= "table" then
    return val
  end
  seen = seen or {}
  if seen[val] then
    return seen[val]
  end
  local copy = {}
  seen[val] = copy
  for k, v in pairs(val) do
    copy[deep_copy(k, seen)] = deep_copy(v, seen)
  end
  return copy
end

-- ---------------------------------------------------------------------------
-- Path Normalization for Virtual Filesystem
-- ---------------------------------------------------------------------------

local function norm_path(p)
  if type(p) ~= "string" then
    return ""
  end
  local s = p:gsub("\\", "/"):gsub("/+", "/")
  s = s:gsub("^/", ""):gsub("/$", "")
  return s
end

local function parent_dir(p)
  local n = norm_path(p)
  if n == "" then
    return ""
  end
  local dir = n:match("^(.*)/[^/]+$")
  return dir or ""
end

-- ---------------------------------------------------------------------------
-- Helper to Read Repo Source Files from Disk
-- ---------------------------------------------------------------------------

function mock_cc.read_disk_file(path)
  local f, err = io.open(path, "r")
  if not f then
    error("mock_cc.read_disk_file failed for " .. tostring(path) .. ": " .. tostring(err))
  end
  local content = f:read("*a")
  f:close()
  return content
end

-- ---------------------------------------------------------------------------
-- MockWorld (Multi-Computer Scheduler + Shared Rednet Bus + Mock HTTP/WS)
-- ---------------------------------------------------------------------------

function mock_cc.new_world()
  local world = {
    now = 0.0,
    epoch_base = 1700000000000,
    computers = {},
    computer_list = {},
    http_routes = {},
    http_requests = {},
    ws_connections = {},
  }

  function world:register_http(method, url_or_pattern, handler)
    self.http_routes[#self.http_routes + 1] = {
      method = method:upper(),
      pattern = url_or_pattern,
      handler = handler,
    }
  end

  function world:dispatch_http(method, url, body, headers)
    method = method:upper()
    local req = {
      method = method,
      url = url,
      body = body,
      headers = deep_copy(headers or {}),
    }
    self.http_requests[#self.http_requests + 1] = req

    for i = #self.http_routes, 1, -1 do
      local r = self.http_routes[i]
      if r.method == method or r.method == "*" then
        if r.pattern == url or (type(r.pattern) == "string" and url:match("^" .. r.pattern .. "$")) then
          local status, resp_body = r.handler(req)
          status = status or 200
          if status >= 200 and status < 300 then
            local closed = false
            return {
              getResponseCode = function() return status end,
              readAll = function() return resp_body or "" end,
              close = function() closed = true end,
              is_closed = function() return closed end,
            }, nil
          else
            return nil, "HTTP " .. tostring(status) .. ": " .. tostring(resp_body or "")
          end
        end
      end
    end

    return nil, "404 Not Found: " .. method .. " " .. url
  end

  function world:new_computer(opts)
    opts = opts or {}
    local id = opts.id or (#self.computer_list + 1)
    local comp = {
      id = id,
      label = opts.label or ("computer_" .. tostring(id)),
      is_turtle = opts.is_turtle == true,
      world = self,
      event_queue = {},
      timers = {},
      next_timer_id = 1,
      open_modems = {},
      peripherals = {},
      redstone_inputs = {
        top = false,
        bottom = false,
        left = false,
        right = false,
        front = false,
        back = false,
      },
      settings_store = deep_copy(opts.settings or {}),
      vfs_files = {},
      vfs_dirs = { [""] = true },
      stdout = {},
      term_lines = {},
      shell_runs = {},
      daemons = {},
      ws_handles = {},
      loaded_modules = {},
    }

    -- VFS Helpers
    function comp:write_vfs(path, content)
      local n = norm_path(path)
      local dir = parent_dir(n)
      while dir ~= "" do
        self.vfs_dirs[dir] = true
        dir = parent_dir(dir)
      end
      self.vfs_files[n] = tostring(content or "")
    end

    function comp:read_vfs(path)
      return self.vfs_files[norm_path(path)]
    end

    -- Peripheral Helpers
    function comp:attach_peripheral(name, types, methods_impl, fire_event)
      local type_list = type(types) == "table" and types or { tostring(types) }
      local method_names = {}
      local impls = {}
      for m_name, fn in pairs(methods_impl or {}) do
        method_names[#method_names + 1] = m_name
        impls[m_name] = fn
      end
      table.sort(method_names)
      self.peripherals[name] = {
        name = name,
        types = type_list,
        method_names = method_names,
        impls = impls,
      }
      if fire_event then
        self:queue_event("peripheral", name)
      end
    end

    function comp:detach_peripheral(name, fire_event)
      self.peripherals[name] = nil
      self.open_modems[name] = nil
      if fire_event then
        self:queue_event("peripheral_detach", name)
      end
    end

    function comp:queue_event(ev_name, ...)
      self.event_queue[#self.event_queue + 1] = { ev_name, ... }
    end

    function comp:has_open_modem()
      for _, is_open in pairs(self.open_modems) do
        if is_open then
          return true
        end
      end
      return false
    end

    -- Redstone Pulse Helper (emulates real CC rising + falling edge)
    function comp:pulse_redstone(side)
      side = side or "back"
      self.redstone_inputs[side] = true
      self:queue_event("redstone")
      self.world:pump()
      self.redstone_inputs[side] = false
      self:queue_event("redstone")
      self.world:pump()
    end

    -- Build CC: Tweaked Globals Table
    local cc_os = {
      getComputerID = function()
        return comp.id
      end,
      getComputerLabel = function()
        return comp.label
      end,
      setComputerLabel = function(lbl)
        comp.label = lbl
      end,
      epoch = function()
        return math.floor(world.epoch_base + world.now * 1000)
      end,
      clock = function()
        return world.now
      end,
      queueEvent = function(ev_name, ...)
        comp:queue_event(ev_name, ...)
      end,
      startTimer = function(duration)
        local tid = comp.next_timer_id
        comp.next_timer_id = tid + 1
        comp.timers[tid] = {
          id = tid,
          fire_at = world.now + (tonumber(duration) or 0),
          active = true,
        }
        return tid
      end,
      cancelTimer = function(tid)
        if comp.timers[tid] then
          comp.timers[tid].active = false
          comp.timers[tid] = nil
        end
      end,
      pullEventRaw = function(filter)
        while true do
          while #comp.event_queue > 0 do
            local ev = table.remove(comp.event_queue, 1)
            if filter == nil or ev[1] == filter then
              return unpack(ev)
            end
          end
          local ev = coroutine.yield("wait_event", filter)
          if type(ev) == "table" then
            if filter == nil or ev[1] == filter then
              return unpack(ev)
            end
          end
        end
      end,
    }
    cc_os.pullEvent = function(filter)
      local res = { cc_os.pullEventRaw(filter) }
      if res[1] == "terminate" then
        error("Terminated", 0)
      end
      return unpack(res)
    end

    local cc_peripheral = {
      getNames = function()
        local names = {}
        for name in pairs(comp.peripherals) do
          names[#names + 1] = name
        end
        table.sort(names)
        return names
      end,
      isPresent = function(name)
        return comp.peripherals[name] ~= nil
      end,
      getType = function(name)
        local p = comp.peripherals[name]
        if not p then
          return nil
        end
        return unpack(p.types)
      end,
      getMethods = function(name)
        local p = comp.peripherals[name]
        if not p then
          return nil
        end
        local copy = {}
        for i = 1, #p.method_names do
          copy[i] = p.method_names[i]
        end
        return copy
      end,
      call = function(name, method, ...)
        local p = comp.peripherals[name]
        if not p then
          error("No peripheral attached: " .. tostring(name))
        end
        local fn = p.impls[method]
        if type(fn) ~= "function" then
          error("No such method '" .. tostring(method) .. "' on " .. tostring(name))
        end
        return fn(...)
      end,
      wrap = function(name)
        local p = comp.peripherals[name]
        if not p then
          return nil
        end
        local wrapped = {}
        for m_name, fn in pairs(p.impls) do
          wrapped[m_name] = fn
        end
        return wrapped
      end,
    }

    local cc_rednet = {
      open = function(side)
        if comp.peripherals[side] then
          comp.open_modems[side] = true
        end
      end,
      close = function(side)
        if side then
          comp.open_modems[side] = nil
        else
          comp.open_modems = {}
        end
      end,
      isOpen = function(side)
        if side then
          return comp.open_modems[side] == true
        end
        return comp:has_open_modem()
      end,
      send = function(target_id, message, protocol)
        if not comp:has_open_modem() then
          return false
        end
        local dst = world.computers[target_id]
        if dst and dst:has_open_modem() then
          dst:queue_event("rednet_message", comp.id, deep_copy(message), protocol)
          return true
        end
        return false
      end,
      broadcast = function(message, protocol)
        if not comp:has_open_modem() then
          return false
        end
        for _, other in ipairs(world.computer_list) do
          if other.id ~= comp.id and other:has_open_modem() then
            other:queue_event("rednet_message", comp.id, deep_copy(message), protocol)
          end
        end
        return true
      end,
      receive = function(protocol_filter, timeout)
        local tid = nil
        if timeout then
          tid = cc_os.startTimer(timeout)
        end
        while true do
          local ev, p1, p2, p3 = cc_os.pullEvent()
          if ev == "rednet_message" then
            if protocol_filter == nil or p3 == protocol_filter then
              if tid then cc_os.cancelTimer(tid) end
              return p1, p2, p3
            end
          elseif ev == "timer" and tid and p1 == tid then
            return nil, nil, nil
          end
        end
      end,
    }

    local cc_fs = {
      exists = function(path)
        local n = norm_path(path)
        return comp.vfs_files[n] ~= nil or comp.vfs_dirs[n] == true
      end,
      isDir = function(path)
        return comp.vfs_dirs[norm_path(path)] == true
      end,
      makeDir = function(path)
        local n = norm_path(path)
        local acc = ""
        for part in n:gmatch("[^/]+") do
          acc = acc == "" and part or (acc .. "/" .. part)
          comp.vfs_dirs[acc] = true
        end
      end,
      getDir = function(path)
        return parent_dir(path)
      end,
      combine = function(a, b)
        local na = norm_path(a)
        local nb = norm_path(b)
        if na == "" then return nb end
        if nb == "" then return na end
        return na .. "/" .. nb
      end,
      delete = function(path)
        local n = norm_path(path)
        comp.vfs_files[n] = nil
        comp.vfs_dirs[n] = nil
      end,
      list = function(path)
        local n = norm_path(path)
        local prefix = n == "" and "" or (n .. "/")
        local seen = {}
        local res = {}
        for fpath in pairs(comp.vfs_files) do
          if fpath:sub(1, #prefix) == prefix then
            local rest = fpath:sub(#prefix + 1)
            local first = rest:match("^([^/]+)")
            if first and not seen[first] then
              seen[first] = true
              res[#res + 1] = first
            end
          end
        end
        table.sort(res)
        return res
      end,
      open = function(path, mode)
        local n = norm_path(path)
        if mode == "r" or mode == "rb" then
          local data = comp.vfs_files[n]
          if data == nil then
            return nil
          end
          local pos = 1
          return {
            readAll = function()
              local rest = data:sub(pos)
              pos = #data + 1
              return rest
            end,
            readLine = function()
              if pos > #data then return nil end
              local nl = data:find("\n", pos, true)
              if nl then
                local line = data:sub(pos, nl - 1)
                pos = nl + 1
                return line
              else
                local line = data:sub(pos)
                pos = #data + 1
                return line
              end
            end,
            close = function() end,
          }
        elseif mode == "w" or mode == "wb" or mode == "a" or mode == "ab" then
          local dir = parent_dir(n)
          while dir ~= "" do
            comp.vfs_dirs[dir] = true
            dir = parent_dir(dir)
          end
          local buf = (mode == "a" or mode == "ab") and { comp.vfs_files[n] or "" } or {}
          return {
            write = function(s)
              buf[#buf + 1] = tostring(s)
            end,
            writeLine = function(s)
              buf[#buf + 1] = tostring(s) .. "\n"
            end,
            flush = function()
              comp.vfs_files[n] = table.concat(buf)
            end,
            close = function()
              comp.vfs_files[n] = table.concat(buf)
            end,
          }
        end
        return nil
      end,
    }

    local cc_rs = {
      getInput = function(side)
        return comp.redstone_inputs[side] == true
      end,
      setInput = function(side, val)
        comp.redstone_inputs[side] = val == true
      end,
      getSides = function()
        return { "top", "bottom", "left", "right", "front", "back" }
      end,
    }

    local cc_settings = {
      get = function(key, default_val)
        local v = comp.settings_store[key]
        if v == nil then
          return default_val
        end
        return v
      end,
      set = function(key, val)
        comp.settings_store[key] = val
      end,
      unset = function(key)
        comp.settings_store[key] = nil
      end,
      save = function()
        return true
      end,
    }

    local cc_textutils = {
      serialiseJSON = function(val)
        return json_encode(val)
      end,
      serializeJSON = function(val)
        return json_encode(val)
      end,
      unserialiseJSON = function(str)
        return json_decode(str)
      end,
      unserializeJSON = function(str)
        return json_decode(str)
      end,
      urlEncode = function(str)
        return (tostring(str or ""):gsub("([^%w%-_%.~])", function(c)
          return string.format("%%%02X", string.byte(c))
        end))
      end,
    }

    local cc_http = {
      get = function(url, headers)
        return world:dispatch_http("GET", url, nil, headers)
      end,
      post = function(url, body, headers)
        return world:dispatch_http("POST", url, body, headers)
      end,
      websocket = function(url, headers)
        local ws_handle = {
          url = url,
          headers = deep_copy(headers or {}),
          closed = false,
          sent_messages = {},
          send_count = 0,
        }
        function ws_handle.send(msg)
          if ws_handle.closed then
            error("WebSocket is closed")
          end
          ws_handle.send_count = ws_handle.send_count + 1
          ws_handle.sent_messages[#ws_handle.sent_messages + 1] = msg
        end
        function ws_handle.close()
          ws_handle.closed = true
        end
        function ws_handle:reset_spies()
          self.sent_messages = {}
          self.send_count = 0
        end
        function ws_handle:last_decoded()
          if #self.sent_messages == 0 then
            return nil
          end
          return json_decode(self.sent_messages[#self.sent_messages])
        end
        function ws_handle:all_decoded()
          local res = {}
          for i = 1, #self.sent_messages do
            res[i] = json_decode(self.sent_messages[i])
          end
          return res
        end
        function ws_handle:inject_message(payload)
          local raw = type(payload) == "string" and payload or json_encode(payload)
          comp:queue_event("websocket_message", url, raw, false)
        end
        function ws_handle:inject_close()
          self.closed = true
          comp:queue_event("websocket_closed", url)
        end

        comp.ws_handles[#comp.ws_handles + 1] = ws_handle
        world.ws_connections[#world.ws_connections + 1] = ws_handle
        return ws_handle, nil
      end,
    }

    local cc_term = {
      clear = function()
        comp.term_lines = {}
      end,
      setCursorPos = function(x, y)
        comp._cx = x
        comp._cy = y
      end,
      write = function(text)
        local y = comp._cy or (#comp.term_lines + 1)
        comp.term_lines[y] = tostring(text)
      end,
      getSize = function()
        return 51, 19
      end,
      setTextColor = function() end,
      setBackgroundColor = function() end,
    }

    local cc_colors = {
      white = 1, orange = 2, magenta = 4, lightBlue = 8,
      yellow = 16, lime = 32, pink = 64, gray = 128,
      lightGray = 256, cyan = 512, purple = 1024, blue = 2048,
      brown = 4096, green = 8192, red = 16384, black = 32768,
    }

    local cc_shell = {
      run = function(program, ...)
        local args = { ... }
        comp.shell_runs[#comp.shell_runs + 1] = {
          program = program,
          args = args,
        }
        return true
      end,
    }

    local function cc_sleep(sec)
      local tid = cc_os.startTimer(sec or 0)
      while true do
        local ev, p1 = cc_os.pullEvent("timer")
        if p1 == tid then
          return
        end
      end
    end

    local function cc_print(...)
      local n = select("#", ...)
      local parts = {}
      for i = 1, n do
        parts[i] = tostring(select(i, ...))
      end
      comp.stdout[#comp.stdout + 1] = table.concat(parts, "\t")
    end

    -- Build per-computer _ENV
    local env = {
      os = cc_os,
      http = cc_http,
      rednet = cc_rednet,
      peripheral = cc_peripheral,
      fs = cc_fs,
      rs = cc_rs,
      redstone = cc_rs,
      settings = cc_settings,
      textutils = cc_textutils,
      shell = cc_shell,
      term = cc_term,
      colors = cc_colors,
      colours = cc_colors,
      sleep = cc_sleep,
      print = cc_print,
      turtle = comp.is_turtle and { getFuelLevel = function() return 1000 end } or nil,
      -- Standard Lua libraries
      assert = assert,
      error = error,
      ipairs = ipairs,
      pairs = pairs,
      next = next,
      pcall = pcall,
      xpcall = xpcall,
      select = select,
      tonumber = tonumber,
      tostring = tostring,
      type = type,
      setmetatable = setmetatable,
      getmetatable = getmetatable,
      rawget = rawget,
      rawset = rawset,
      rawequal = rawequal,
      string = string,
      table = table,
      math = math,
      coroutine = coroutine,
      debug = debug,
      load = load,
      unpack = unpack,
    }
    env._G = env

    -- Per-computer require() resolving VFS first, then src/lua/<mod>.lua
    env.require = function(mod_name)
      if comp.loaded_modules[mod_name] ~= nil then
        return comp.loaded_modules[mod_name]
      end
      local rel = mod_name:gsub("%.", "/") .. ".lua"
      local source = comp:read_vfs(rel)
      if not source then
        local disk_path = "src/lua/" .. rel
        local f = io.open(disk_path, "r")
        if f then
          source = f:read("*a")
          f:close()
        end
      end
      if not source then
        error("module '" .. tostring(mod_name) .. "' not found")
      end
      local fn, err = load(source, "@" .. rel, "t", env)
      if not fn then
        error("error loading module '" .. tostring(mod_name) .. "': " .. tostring(err))
      end
      local res = fn(mod_name)
      if res == nil then
        res = true
      end
      comp.loaded_modules[mod_name] = res
      return res
    end

    comp.env = env

    function comp:start_daemon(source, chunk_name, ...)
      local fn, err = load(source, chunk_name or "daemon", "t", self.env)
      if not fn then
        error("Compile error in " .. tostring(chunk_name) .. ": " .. tostring(err))
      end
      local daemon_args = { ... }
      local co = coroutine.create(function()
        return fn(unpack(daemon_args))
      end)
      local record = {
        name = chunk_name or "daemon",
        co = co,
        started = false,
        dead = false,
        err = nil,
      }
      self.daemons[#self.daemons + 1] = record
      return record
    end

    function comp:run_script(source, chunk_name, ...)
      local fn, err = load(source, chunk_name or "script", "t", self.env)
      if not fn then
        error("Compile error in " .. tostring(chunk_name) .. ": " .. tostring(err))
      end
      local script_args = { ... }
      local co = coroutine.create(function()
        return fn(unpack(script_args))
      end)

      local ok, res, extra = coroutine.resume(co)
      local guard = 0
      while ok and coroutine.status(co) ~= "dead" and guard < 200 do
        guard = guard + 1
        if res == "wait_event" then
          -- Pump any other computers (e.g. runners responding to DISCOVER)
          self.world:pump()
          if #self.event_queue > 0 then
            local ev = table.remove(self.event_queue, 1)
            ok, res, extra = coroutine.resume(co, ev)
          else
            -- Advance to next pending timer on this computer
            local earliest = nil
            for _, t in pairs(self.timers) do
              if t.active and (earliest == nil or t.fire_at < earliest.fire_at) then
                earliest = t
              end
            end
            if earliest then
              local dt = math.max(0.01, (earliest.fire_at - self.world.now) + 0.001)
              self.world:advance_time(dt)
              if #self.event_queue > 0 then
                local ev = table.remove(self.event_queue, 1)
                ok, res, extra = coroutine.resume(co, ev)
              else
                break
              end
            else
              break
            end
          end
        else
          ok, res, extra = coroutine.resume(co)
        end
      end
      if not ok then
        error("Runtime error in " .. tostring(chunk_name) .. ": " .. tostring(res))
      end
      return res, extra
    end

    self.computers[id] = comp
    self.computer_list[#self.computer_list + 1] = comp
    return comp
  end

  function world:pump(max_rounds)
    max_rounds = max_rounds or 100
    for _ = 1, max_rounds do
      local progressed = false
      for _, comp in ipairs(self.computer_list) do
        for _, d in ipairs(comp.daemons) do
          if not d.dead then
            if not d.started then
              d.started = true
              progressed = true
              local ok, res = coroutine.resume(d.co)
              if not ok then
                d.dead = true
                d.err = res
                error("Daemon '" .. d.name .. "' crashed: " .. tostring(res))
              elseif coroutine.status(d.co) == "dead" then
                d.dead = true
              end
            elseif #comp.event_queue > 0 then
              local ev = table.remove(comp.event_queue, 1)
              progressed = true
              local ok, res = coroutine.resume(d.co, ev)
              if not ok then
                d.dead = true
                d.err = res
                error("Daemon '" .. d.name .. "' crashed: " .. tostring(res))
              elseif coroutine.status(d.co) == "dead" then
                d.dead = true
              end
            end
          end
        end
      end
      if not progressed then
        break
      end
    end
  end

  function world:advance_time(dt)
    self.now = self.now + (tonumber(dt) or 0)
    for _, comp in ipairs(self.computer_list) do
      local due = {}
      for tid, t in pairs(comp.timers) do
        if t.active and t.fire_at <= self.now then
          due[#due + 1] = tid
        end
      end
      table.sort(due)
      for i = 1, #due do
        local tid = due[i]
        comp.timers[tid] = nil
        comp:queue_event("timer", tid)
      end
    end
    self:pump()
  end

  return world
end

return mock_cc
