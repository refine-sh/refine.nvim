local errors = require("refine.transport.errors")
local frame = require("refine.transport.frame")

local M = {}
local unpack_values = table.unpack or unpack
local MAX_PENDING_READS = 128
local MAX_PENDING_READ_BYTES = frame.MAX_FRAME_BYTES + 4

local function call_on_main(callback, ...)
  if not vim.in_fast_event() then
    callback(...)
    return
  end
  local argument_count = select("#", ...)
  local arguments = { ... }
  vim.schedule(function()
    callback(unpack_values(arguments, 1, argument_count))
  end)
end

local function ordered_main_queue(on_overflow)
  local pending = {}
  local pending_bytes = 0
  local draining = false
  local scheduled = false
  local overflowed = false

  local function drain()
    if draining then
      return
    end
    scheduled = false
    draining = true
    while #pending > 0 do
      local item = table.remove(pending, 1)
      pending_bytes = pending_bytes - item.bytes
      item.callback()
    end
    draining = false
  end

  local function schedule_drain()
    if draining or scheduled then
      return
    end
    if vim.in_fast_event() then
      scheduled = true
      vim.schedule(drain)
    else
      drain()
    end
  end

  return function(callback, bytes)
    if overflowed then
      return false, false
    end
    bytes = bytes or 0
    if #pending >= MAX_PENDING_READS or pending_bytes + bytes > MAX_PENDING_READ_BYTES then
      overflowed = true
      pending[#pending + 1] = { callback = on_overflow, bytes = 0 }
      schedule_drain()
      return false, true
    end
    pending[#pending + 1] = { callback = callback, bytes = bytes }
    pending_bytes = pending_bytes + bytes
    schedule_drain()
    return true, false
  end
end

local function connection_for(pipe)
  local connection = {
    pipe = pipe,
    closed = false,
    receiving = false,
  }

  function connection:send(value, callback)
    callback = callback or function() end
    local completed = false
    local function finish(err)
      if completed then
        return
      end
      completed = true
      call_on_main(callback, err)
    end
    if self.closed or self.pipe:is_closing() then
      finish(errors.new("EngineConnectionError", "Refine socket is closed", "recoverable"))
      return
    end
    local ok, encoded = pcall(frame.encode, value)
    if not ok then
      finish(encoded)
      return
    end
    self.pipe:write(encoded, function(err)
      finish(err)
    end)
  end

  function connection:receive(on_frame, on_end)
    if self.receiving then
      error("Refine frame connection can only be observed once")
    end
    self.receiving = true
    local decoder = frame.decoder()
    local ended = false
    local function finish(err)
      if ended then
        return
      end
      ended = true
      on_end(err)
    end
    local function accept_read(read_error, chunk)
      if ended or self.closed then
        return
      end
      if read_error then
        finish(errors.new("EngineConnectionError", tostring(read_error), "recoverable"))
        self:close()
        return
      end
      if chunk == nil then
        local ok, decode_error = pcall(function()
          decoder:finish()
        end)
        finish(ok and nil or decode_error)
        self:close()
        return
      end
      local ok, decoded = pcall(function()
        return decoder:push(chunk)
      end)
      if not ok then
        finish(decoded)
        self:close()
        return
      end
      for _, value in ipairs(decoded) do
        local accepted, callback_error = pcall(on_frame, value)
        if not accepted then
          finish(callback_error)
          self:close()
          return
        end
      end
      local pending_decode_error = decoder:take_error()
      if pending_decode_error ~= nil then
        finish(pending_decode_error)
        self:close()
      end
    end
    local queue_error = errors.new("EngineConnectionError", "Refine socket read queue is full", "recoverable")
    local enqueue = ordered_main_queue(function()
      if ended then
        return
      end
      finish(queue_error)
      self:close()
    end)
    self.pipe:read_start(function(read_error, chunk)
      local _, overflow_started = enqueue(function()
        accept_read(read_error, chunk)
      end, type(chunk) == "string" and #chunk or 0)
      if overflow_started and not self.pipe:is_closing() then
        pcall(self.pipe.read_stop, self.pipe)
      end
    end)
  end

  function connection:close()
    if self.closed then
      return
    end
    self.closed = true
    if not self.pipe:is_closing() then
      pcall(self.pipe.read_stop, self.pipe)
      self.pipe:close()
    end
  end

  return connection
end

function M.connector(options)
  options = options or {}
  local new_pipe = options.new_pipe or function()
    return vim.uv.new_pipe(false)
  end
  local connector = {}

  function connector:connect(path, callback)
    local pipe = new_pipe()
    local settled = false
    pipe:connect(path, function(err)
      if settled then
        return
      end
      settled = true
      if err then
        if not pipe:is_closing() then
          pipe:close()
        end
        call_on_main(callback, errors.new("EngineConnectionError", tostring(err), "recoverable"))
        return
      end
      call_on_main(callback, nil, connection_for(pipe))
    end)
  end

  return connector
end

return M
