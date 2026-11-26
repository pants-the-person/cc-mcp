-- cc-mesh-bridge Pure-Lua Authenticated Cryptography Library (/lib/crypto.lua)
-- Compatible with CC: Tweaked (Lua 5.2 + bit32), Lua 5.3/5.4 (wasmoon), and LuaJIT.
-- Provides:
--   crypto.sha256(msg) / crypto.sha256_hex(msg)
--   crypto.hmac_sha256(key, msg) / crypto.hmac_sha256_hex(key, msg)
--   crypto.random_bytes(n) / crypto.random_hex(n)
--   crypto.constant_time_eq(a, b)
--   crypto.seal(key, plaintext, aad)  -- Encrypt-then-MAC (SHA256-CTR + HMAC-SHA256)
--   crypto.open(key, envelope, aad)   -- Verified decryption

local crypto = {}

-- ---------------------------------------------------------------------------
-- 32-bit Bitwise Abstraction (bit32 in CC: Tweaked; Lua 5.3/5.4 fallback)
-- ---------------------------------------------------------------------------

local band, bxor, bnot, rshift, lshift, rrotate

if type(bit32) == "table" then
  band = bit32.band
  bxor = bit32.bxor
  bnot = bit32.bnot
  rshift = bit32.rshift
  lshift = bit32.lshift
  rrotate = bit32.rrotate
else
  local loader = load([[
    return {
      band = function(a, b) return (a & b) & 0xffffffff end,
      bxor = function(a, b) return (a ~ b) & 0xffffffff end,
      bnot = function(a) return (~a) & 0xffffffff end,
      rshift = function(a, n) return ((a & 0xffffffff) >> n) & 0xffffffff end,
      lshift = function(a, n) return ((a & 0xffffffff) << n) & 0xffffffff end,
      rrotate = function(a, n)
        a = a & 0xffffffff
        n = n % 32
        return ((a >> n) | (a << (32 - n))) & 0xffffffff
      end,
    }
  ]])
  if loader then
    local b = loader()
    band, bxor, bnot, rshift, lshift, rrotate =
      b.band, b.bxor, b.bnot, b.rshift, b.lshift, b.rrotate
  else
    -- Pure arithmetic fallback (Lua 5.1)
    local MOD = 4294967296
    band = function(a, b)
      a, b = a % MOD, b % MOD
      local res, bit = 0, 1
      while a > 0 and b > 0 do
        local aa, bb = a % 2, b % 2
        if aa == 1 and bb == 1 then res = res + bit end
        a, b, bit = (a - aa) / 2, (b - bb) / 2, bit * 2
      end
      return res
    end
    bxor = function(a, b)
      a, b = a % MOD, b % MOD
      local res, bit = 0, 1
      while a > 0 or b > 0 do
        local aa, bb = a % 2, b % 2
        if aa ~= bb then res = res + bit end
        a, b, bit = (a - aa) / 2, (b - bb) / 2, bit * 2
      end
      return res
    end
    bnot = function(a) return (MOD - 1) - (a % MOD) end
    rshift = function(a, n) return math.floor((a % MOD) / (2 ^ n)) end
    lshift = function(a, n) return ((a % MOD) * (2 ^ n)) % MOD end
    rrotate = function(a, n)
      n = n % 32
      a = a % MOD
      return (math.floor(a / (2 ^ n)) + ((a * (2 ^ (32 - n))) % MOD)) % MOD
    end
  end
end

-- ---------------------------------------------------------------------------
-- Hex Encoding / Decoding
-- ---------------------------------------------------------------------------

function crypto.to_hex(bytes)
  return (tostring(bytes or ""):gsub(".", function(c)
    return string.format("%02x", string.byte(c))
  end))
end

function crypto.from_hex(hex)
  if type(hex) ~= "string" or (#hex % 2) ~= 0 then
    return nil, "invalid hex length"
  end
  local ok = true
  local out = hex:gsub("..", function(cc)
    local n = tonumber(cc, 16)
    if not n then
      ok = false
      return ""
    end
    return string.char(n)
  end)
  if not ok then
    return nil, "invalid hex characters"
  end
  return out, nil
end

-- ---------------------------------------------------------------------------
-- FIPS 180-4 SHA-256
-- ---------------------------------------------------------------------------

local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function u32_to_be(n)
  return string.char(
    band(rshift(n, 24), 0xff),
    band(rshift(n, 16), 0xff),
    band(rshift(n, 8), 0xff),
    band(n, 0xff)
  )
end

function crypto.sha256(msg)
  msg = tostring(msg or "")
  local len = #msg
  local bit_len = len * 8
  local pad_len = (55 - (len % 64)) % 64
  local hi = math.floor(bit_len / 4294967296)
  local lo = bit_len % 4294967296
  local padded = msg .. "\128" .. string.rep("\0", pad_len) .. u32_to_be(hi) .. u32_to_be(lo)

  local h0 = 0x6a09e667
  local h1 = 0xbb67ae85
  local h2 = 0x3c6ef372
  local h3 = 0xa54ff53a
  local h4 = 0x510e527f
  local h5 = 0x9b05688c
  local h6 = 0x1f83d9ab
  local h7 = 0x5be0cd19

  local w = {}
  for chunk = 1, #padded, 64 do
    for i = 0, 15 do
      local o = chunk + i * 4
      local b1, b2, b3, b4 = string.byte(padded, o, o + 3)
      w[i + 1] = ((b1 * 16777216) + (b2 * 65536) + (b3 * 256) + b4) % 4294967296
    end
    for i = 17, 64 do
      local v15 = w[i - 15]
      local s0 = bxor(bxor(rrotate(v15, 7), rrotate(v15, 18)), rshift(v15, 3))
      local v2 = w[i - 2]
      local s1 = bxor(bxor(rrotate(v2, 17), rrotate(v2, 19)), rshift(v2, 10))
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % 4294967296
    end

    local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
    for i = 1, 64 do
      local S1 = bxor(bxor(rrotate(e, 6), rrotate(e, 11)), rrotate(e, 25))
      local ch = bxor(band(e, f), band(bnot(e), g))
      local temp1 = (h + S1 + ch + K[i] + w[i]) % 4294967296
      local S0 = bxor(bxor(rrotate(a, 2), rrotate(a, 13)), rrotate(a, 22))
      local maj = bxor(bxor(band(a, b), band(a, c)), band(b, c))
      local temp2 = (S0 + maj) % 4294967296

      h = g
      g = f
      f = e
      e = (d + temp1) % 4294967296
      d = c
      c = b
      b = a
      a = (temp1 + temp2) % 4294967296
    end

    h0 = (h0 + a) % 4294967296
    h1 = (h1 + b) % 4294967296
    h2 = (h2 + c) % 4294967296
    h3 = (h3 + d) % 4294967296
    h4 = (h4 + e) % 4294967296
    h5 = (h5 + f) % 4294967296
    h6 = (h6 + g) % 4294967296
    h7 = (h7 + h) % 4294967296
  end

  return u32_to_be(h0) .. u32_to_be(h1) .. u32_to_be(h2) .. u32_to_be(h3)
    .. u32_to_be(h4) .. u32_to_be(h5) .. u32_to_be(h6) .. u32_to_be(h7)
end

function crypto.sha256_hex(msg)
  return crypto.to_hex(crypto.sha256(msg))
end

-- ---------------------------------------------------------------------------
-- RFC 2104 HMAC-SHA256
-- ---------------------------------------------------------------------------

local function xor_str(a, b)
  local out = {}
  local n = math.min(#a, #b)
  for i = 1, n do
    out[i] = string.char(bxor(string.byte(a, i), string.byte(b, i)))
  end
  return table.concat(out)
end

function crypto.hmac_sha256(key, msg)
  key = tostring(key or "")
  msg = tostring(msg or "")
  if #key > 64 then
    key = crypto.sha256(key)
  end
  if #key < 64 then
    key = key .. string.rep("\0", 64 - #key)
  end
  local o_key = xor_str(key, string.rep("\92", 64))
  local i_key = xor_str(key, string.rep("\54", 64))
  return crypto.sha256(o_key .. crypto.sha256(i_key .. msg))
end

function crypto.hmac_sha256_hex(key, msg)
  return crypto.to_hex(crypto.hmac_sha256(key, msg))
end

function crypto.constant_time_eq(a, b)
  if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then
    return false
  end
  local diff = 0
  for i = 1, #a do
    diff = diff + bxor(string.byte(a, i), string.byte(b, i))
  end
  return diff == 0
end

-- ---------------------------------------------------------------------------
-- CSPRNG-style Entropy Mixer (SHA-256 Counter DRBG)
-- ---------------------------------------------------------------------------

local rng_state = ""
local rng_counter = 0

local function mix_entropy(extra)
  rng_counter = rng_counter + 1
  local t_epoch = (type(os) == "table" and type(os.epoch) == "function") and tostring(os.epoch("utc")) or "0"
  local t_clock = (type(os) == "table" and type(os.clock) == "function") and tostring(os.clock()) or "0"
  local cid = (type(os) == "table" and type(os.getComputerID) == "function") and tostring(os.getComputerID()) or "0"
  local r1 = tostring(math.random(0, 2147483647))
  local r2 = tostring(math.random(0, 2147483647))
  local seed_str = rng_state .. "|" .. tostring(rng_counter) .. "|" .. t_epoch .. "|" .. t_clock .. "|" .. cid .. "|" .. r1 .. "|" .. r2 .. "|" .. tostring(extra or "")
  rng_state = crypto.sha256(seed_str)
  return rng_state
end

function crypto.random_bytes(n, extra_entropy)
  n = tonumber(n) or 16
  local chunks = {}
  local got = 0
  while got < n do
    local blk = mix_entropy(extra_entropy)
    chunks[#chunks + 1] = blk
    got = got + #blk
  end
  return table.concat(chunks):sub(1, n)
end

function crypto.random_hex(n, extra_entropy)
  return crypto.to_hex(crypto.random_bytes(n, extra_entropy))
end

-- ---------------------------------------------------------------------------
-- Authenticated Encryption: SHA256-CTR + HMAC-SHA256 (Encrypt-then-MAC)
-- ---------------------------------------------------------------------------

local function ctr_crypt(enc_key, nonce_bytes, input)
  local out = {}
  local total = #input
  local counter = 0
  local pos = 1
  while pos <= total do
    counter = counter + 1
    local ks = crypto.sha256(enc_key .. nonce_bytes .. u32_to_be(counter))
    local chunk_end = math.min(pos + 31, total)
    local chunk = input:sub(pos, chunk_end)
    out[#out + 1] = xor_str(chunk, ks:sub(1, #chunk))
    pos = chunk_end + 1
  end
  return table.concat(out)
end

function crypto.seal(master_key, plaintext, aad)
  if type(master_key) ~= "string" or #master_key == 0 then
    return nil, "master_key required"
  end
  plaintext = tostring(plaintext or "")
  aad = tostring(aad or "")

  local nonce = crypto.random_bytes(16)
  local enc_key = crypto.hmac_sha256(master_key, "cc-mesh-enc-v1:" .. nonce)
  local mac_key = crypto.hmac_sha256(master_key, "cc-mesh-mac-v1:" .. nonce)
  local ct = ctr_crypt(enc_key, nonce, plaintext)
  local mac_input = "v1|" .. nonce .. "|" .. tostring(#aad) .. ":" .. aad .. "|" .. ct
  local tag = crypto.hmac_sha256(mac_key, mac_input)

  return {
    v = 1,
    n = crypto.to_hex(nonce),
    c = crypto.to_hex(ct),
    t = crypto.to_hex(tag),
  }, nil
end

function crypto.open(master_key, envelope, aad)
  if type(master_key) ~= "string" or #master_key == 0 then
    return nil, "master_key required"
  end
  if type(envelope) ~= "table" or envelope.v ~= 1 then
    return nil, "invalid envelope"
  end
  local nonce, err_n = crypto.from_hex(envelope.n)
  local ct, err_c = crypto.from_hex(envelope.c)
  local tag, err_t = crypto.from_hex(envelope.t)
  if not nonce or #nonce ~= 16 or not ct or not tag or #tag ~= 32 then
    return nil, err_n or err_c or err_t or "malformed envelope fields"
  end

  aad = tostring(aad or "")
  local mac_key = crypto.hmac_sha256(master_key, "cc-mesh-mac-v1:" .. nonce)
  local mac_input = "v1|" .. nonce .. "|" .. tostring(#aad) .. ":" .. aad .. "|" .. ct
  local expected_tag = crypto.hmac_sha256(mac_key, mac_input)
  if not crypto.constant_time_eq(tag, expected_tag) then
    return nil, "authentication failed"
  end

  local enc_key = crypto.hmac_sha256(master_key, "cc-mesh-enc-v1:" .. nonce)
  local pt = ctr_crypt(enc_key, nonce, ct)
  return pt, nil
end

return crypto
