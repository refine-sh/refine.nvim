local M = {}

local error_mt = {
  __tostring = function(value)
    return value.message
  end,
}

function M.new(kind, message, recoverability, data)
  local value = data or {}
  value.kind = kind
  value.message = message
  value.recoverability = recoverability or "fatal"
  return setmetatable(value, error_mt)
end

function M.raise(kind, message, recoverability, data, level)
  error(M.new(kind, message, recoverability, data), level or 2)
end

function M.is_fatal(value)
  return type(value) == "table" and value.recoverability == "fatal"
end

function M.redact(value, fallback_message)
  if type(value) ~= "table" then
    return M.new("EngineConnectionError", fallback_message or "Refine connection failed", "recoverable")
  end
  local redacted = M.new(
    value.kind or "RefineError",
    type(value.message) == "string" and value.message or (fallback_message or "Refine operation failed"),
    value.recoverability or "fatal"
  )
  if type(value.received_protocol) == "table" then
    redacted.received_protocol = {
      major = value.received_protocol.major,
      minor = value.received_protocol.minor,
    }
  end
  if type(value.supported_protocol) == "table" then
    redacted.supported_protocol = {
      major = value.supported_protocol.major,
      minor = value.supported_protocol.minor,
    }
  end
  if value.kind == "HandshakeRejectedError" or value.kind == "IncompatibleProtocolError" then
    if type(value.protocol) == "table" then
      redacted.protocol = {
        major = value.protocol.major,
        minor = value.protocol.minor,
      }
    end
    if type(value.reason) == "string" then
      redacted.reason = value.reason
    end
    if type(value.recovery) == "string" then
      redacted.recovery = value.recovery
    end
  end
  return redacted
end

return M
