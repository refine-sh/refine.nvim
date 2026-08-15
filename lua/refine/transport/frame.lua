local errors = require("refine.transport.errors")
local utf8 = require("refine.utf8")

local M = {}

M.MAX_FRAME_BYTES = 8 * 1024 * 1024

local HEADER_BYTES = 4

local function protocol_error(message)
  errors.raise("TransportProtocolError", "Refine frame protocol error: " .. message, "fatal", nil, 3)
end

local function encode_length(length)
  return string.char(
    math.floor(length / 0x1000000) % 0x100,
    math.floor(length / 0x10000) % 0x100,
    math.floor(length / 0x100) % 0x100,
    length % 0x100
  )
end

local function decode_length(header)
  local first, second, third, fourth = header:byte(1, HEADER_BYTES)
  return (((first * 0x100) + second) * 0x100 + third) * 0x100 + fourth
end

function M.encode(value)
  local ok, body = pcall(vim.json.encode, value)
  if not ok then
    protocol_error("frame value is not JSON serializable")
  end
  if not utf8.valid(body) then
    protocol_error("frame body is not valid UTF-8")
  end
  if #body == 0 or #body > M.MAX_FRAME_BYTES then
    protocol_error(("frame body must be between 1 and %d bytes"):format(M.MAX_FRAME_BYTES))
  end
  return encode_length(#body) .. body
end

function M.decoder()
  local decoder = {
    buffered = "",
    failed = false,
  }

  function decoder:push(chunk)
    if self.failed then
      protocol_error("frame decoder cannot continue after a protocol error")
    end
    if type(chunk) ~= "string" then
      protocol_error("socket chunk must be a string")
    end
    if #chunk == 0 then
      return {}
    end

    self.buffered = self.buffered .. chunk
    local decoded = {}
    local ok, failure = pcall(function()
      while #self.buffered >= HEADER_BYTES do
        local length = decode_length(self.buffered)
        if length == 0 or length > M.MAX_FRAME_BYTES then
          protocol_error(("declared frame length must be between 1 and %d bytes"):format(M.MAX_FRAME_BYTES))
        end
        if #self.buffered < HEADER_BYTES + length then
          return
        end

        local body = self.buffered:sub(HEADER_BYTES + 1, HEADER_BYTES + length)
        if not utf8.valid(body) then
          protocol_error("frame body is not valid UTF-8")
        end
        local parsed, value = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
        if not parsed then
          protocol_error("frame body is not valid JSON")
        end
        decoded[#decoded + 1] = value
        self.buffered = self.buffered:sub(HEADER_BYTES + length + 1)
      end
    end)
    if not ok then
      self.failed = true
      self.buffered = ""
      error(failure, 0)
    end
    return decoded
  end

  function decoder:finish()
    if #self.buffered ~= 0 then
      self.failed = true
      self.buffered = ""
      protocol_error("socket ended in the middle of a frame")
    end
  end

  return decoder
end

return M
