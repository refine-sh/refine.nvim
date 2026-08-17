-- SHA-256 over raw bytes. `vim.fn.sha256()` cannot verify the vendored protocol fixtures: a Lua
-- string holding a NUL byte reaches Vimscript as a Blob, and sha256() rejected Blobs until Neovim
-- 0.12 (E976), so the canonical manifest digest fails on the supported 0.11 floor.

local M = {}

local band = bit.band
local bnot = bit.bnot
local bor = bit.bor
local bxor = bit.bxor
local lshift = bit.lshift
local rshift = bit.rshift
local ror = bit.ror
local tobit = bit.tobit

local INITIAL_STATE = {
  0x6a09e667,
  0xbb67ae85,
  0x3c6ef372,
  0xa54ff53a,
  0x510e527f,
  0x9b05688c,
  0x1f83d9ab,
  0x5be0cd19,
}

local ROUND_CONSTANTS = {
  0x428a2f98,
  0x71374491,
  0xb5c0fbcf,
  0xe9b5dba5,
  0x3956c25b,
  0x59f111f1,
  0x923f82a4,
  0xab1c5ed5,
  0xd807aa98,
  0x12835b01,
  0x243185be,
  0x550c7dc3,
  0x72be5d74,
  0x80deb1fe,
  0x9bdc06a7,
  0xc19bf174,
  0xe49b69c1,
  0xefbe4786,
  0x0fc19dc6,
  0x240ca1cc,
  0x2de92c6f,
  0x4a7484aa,
  0x5cb0a9dc,
  0x76f988da,
  0x983e5152,
  0xa831c66d,
  0xb00327c8,
  0xbf597fc7,
  0xc6e00bf3,
  0xd5a79147,
  0x06ca6351,
  0x14292967,
  0x27b70a85,
  0x2e1b2138,
  0x4d2c6dfc,
  0x53380d13,
  0x650a7354,
  0x766a0abb,
  0x81c2c92e,
  0x92722c85,
  0xa2bfe8a1,
  0xa81a664b,
  0xc24b8b70,
  0xc76c51a3,
  0xd192e819,
  0xd6990624,
  0xf40e3585,
  0x106aa070,
  0x19a4c116,
  0x1e376c08,
  0x2748774c,
  0x34b0bcb5,
  0x391c0cb3,
  0x4ed8aa4a,
  0x5b9cca4f,
  0x682e6ff3,
  0x748f82ee,
  0x78a5636f,
  0x84c87814,
  0x8cc70208,
  0x90befffa,
  0xa4506ceb,
  0xbef9a3f7,
  0xc67178f2,
}

local function big_endian(value)
  return string.char(
    math.floor(value / 0x1000000) % 0x100,
    math.floor(value / 0x10000) % 0x100,
    math.floor(value / 0x100) % 0x100,
    value % 0x100
  )
end

local function padded(message)
  local zeros = (56 - (#message + 1) % 64) % 64
  return message
    .. "\128"
    .. string.rep("\0", zeros)
    .. big_endian(math.floor(#message / 0x20000000))
    .. big_endian((#message * 8) % 0x100000000)
end

local function schedule_at(blocks, offset)
  local schedule = {}
  for index = 1, 16 do
    local position = offset + (index - 1) * 4
    local first, second, third, fourth = blocks:byte(position, position + 3)
    schedule[index] = bor(lshift(first, 24), lshift(second, 16), lshift(third, 8), fourth)
  end
  for index = 17, 64 do
    local left = schedule[index - 15]
    local right = schedule[index - 2]
    local sigma0 = bxor(ror(left, 7), ror(left, 18), rshift(left, 3))
    local sigma1 = bxor(ror(right, 17), ror(right, 19), rshift(right, 10))
    schedule[index] = tobit(schedule[index - 16] + sigma0 + schedule[index - 7] + sigma1)
  end
  return schedule
end

function M.hex(message)
  local state = {}
  for index = 1, 8 do
    state[index] = INITIAL_STATE[index]
  end

  local blocks = padded(message)
  for offset = 1, #blocks, 64 do
    local schedule = schedule_at(blocks, offset)
    local a, b, c, d = state[1], state[2], state[3], state[4]
    local e, f, g, h = state[5], state[6], state[7], state[8]
    for index = 1, 64 do
      local sigma1 = bxor(ror(e, 6), ror(e, 11), ror(e, 25))
      local choice = bxor(band(e, f), band(bnot(e), g))
      local carried = tobit(h + sigma1 + choice + ROUND_CONSTANTS[index] + schedule[index])
      local sigma0 = bxor(ror(a, 2), ror(a, 13), ror(a, 22))
      local majority = bxor(band(a, b), band(a, c), band(b, c))
      h = g
      g = f
      f = e
      e = tobit(d + carried)
      d = c
      c = b
      b = a
      a = tobit(carried + sigma0 + majority)
    end
    local round = { a, b, c, d, e, f, g, h }
    for index = 1, 8 do
      state[index] = tobit(state[index] + round[index])
    end
  end

  local hex = {}
  for index = 1, 8 do
    hex[index] = ("%08x"):format(state[index] % 0x100000000)
  end
  return table.concat(hex)
end

return M
