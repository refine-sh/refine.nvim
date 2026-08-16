local endpoint = require("refine.transport.endpoint")
local errors = require("refine.transport.errors")
local unix = require("refine.transport.unix")
local uuid = require("refine.transport.uuid")
local wire = require("refine.transport.wire")

local M = {}

local HANDSHAKE_TIMEOUT_MS = 5000
local MAX_WAITING_COMMANDS = 128

local function default_delay(milliseconds, callback)
  local timer = vim.uv.new_timer()
  timer:start(
    milliseconds,
    0,
    vim.schedule_wrap(function()
      if not timer:is_closing() then
        timer:close()
      end
      callback()
    end)
  )
  return function()
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end
end

local function nonempty_string(value, label)
  if type(value) ~= "string" or value == "" then
    errors.raise("TransportProtocolError", label .. " must be a nonempty string", "fatal", nil, 3)
  end
end

local function validate_identity(client)
  if type(client) ~= "table" or vim.islist(client) then
    errors.raise("TransportProtocolError", "client identity must be an object", "fatal", nil, 3)
  end
  nonempty_string(client.id, "client.id")
  nonempty_string(client.version, "client.version")
  nonempty_string(client.host, "client.host")
  if #client.id > 128 or #client.version > 128 or #client.host > 128 then
    errors.raise("TransportProtocolError", "client identity fields must be at most 128 UTF-8 bytes", "fatal", nil, 3)
  end
end

local function incompatible_error(protocol)
  local server_is_newer = protocol.major > wire.PROTOCOL_MAJOR
    or (protocol.major == wire.PROTOCOL_MAJOR and protocol.minor > wire.PROTOCOL_MINOR)
  return errors.new(
    "IncompatibleProtocolError",
    ("Refine protocol %d.%d is incompatible with protocol %d.%d"):format(
      protocol.major,
      protocol.minor,
      wire.PROTOCOL_MAJOR,
      wire.PROTOCOL_MINOR
    ),
    "fatal",
    {
      required_update = server_is_newer and "client" or "server",
      received_protocol = protocol,
    }
  )
end

local Session = {}
Session.__index = Session

function Session.new(connection, welcome, id_generator)
  return setmetatable({
    connection = connection,
    server_epoch = welcome.serverEpoch,
    run_resumed = welcome.runResumed,
    id_generator = id_generator,
    command_sequence = 0,
    expected_event_sequence = 1,
    send_queue = {},
    sending = false,
    in_flight = nil,
    close_enqueued = false,
    buffered_events = {},
    events_claimed = false,
    event_listener = nil,
    end_listener = nil,
    ended = false,
    closed = false,
  }, Session)
end

function Session:_complete_send(pending, err, receipt)
  if pending.completed then
    return
  end
  pending.completed = true
  pending.callback(err, receipt)
end

function Session:_fail_sends(err)
  local in_flight = self.in_flight
  self.in_flight = nil
  self.sending = false
  if in_flight then
    self:_complete_send(in_flight, err)
  end
  local waiting = self.send_queue
  self.send_queue = {}
  for _, pending in ipairs(waiting) do
    self:_complete_send(pending, err)
  end
end

function Session:_end(err)
  if self.ended then
    return
  end
  self.ended = true
  self.closed = true
  self.connection:close()
  self:_fail_sends(err or errors.new("EngineConnectionError", "Refine transport session ended", "recoverable"))
  local listener = self.end_listener
  if listener then
    listener(err)
  else
    self.pending_end = err or false
  end
end

function Session:_accept_frame(value)
  if self.closed or self.ended then
    return
  end
  local ok, envelope = pcall(wire.decode_event, value)
  if not ok then
    self:_end(envelope)
    return
  end
  if envelope.epoch ~= self.server_epoch then
    self:_end(errors.new("TransportProtocolError", "Received an event from a different server epoch", "fatal"))
    return
  end
  if envelope.sequence ~= self.expected_event_sequence then
    self:_end(
      errors.new(
        "TransportProtocolError",
        ("Expected server event sequence %d, received %d"):format(self.expected_event_sequence, envelope.sequence),
        "fatal"
      )
    )
    return
  end
  self.expected_event_sequence = self.expected_event_sequence + 1
  if self.event_listener then
    self.event_listener(envelope)
    return
  end
  if #self.buffered_events >= 128 then
    self:_end(errors.new("TransportProtocolError", "Too many buffered Refine events", "fatal"))
    return
  end
  self.buffered_events[#self.buffered_events + 1] = envelope
end

function Session:events(on_event, on_end)
  if self.events_claimed then
    error("Refine transport events can only be observed once")
  end
  self.events_claimed = true
  self.event_listener = on_event
  self.end_listener = on_end
  for _, value in ipairs(self.buffered_events) do
    if self.ended then
      break
    end
    on_event(value)
  end
  self.buffered_events = {}
  if self.pending_end ~= nil then
    local pending = self.pending_end
    self.pending_end = nil
    on_end(pending == false and nil or pending)
  end
end

function Session:_send_next()
  if self.sending or #self.send_queue == 0 then
    return
  end
  local pending = table.remove(self.send_queue, 1)
  if self.closed or self.ended then
    self:_complete_send(
      pending,
      errors.new("EngineConnectionError", "Refine transport session is closed", "recoverable")
    )
    self:_send_next()
    return
  end
  if self.command_sequence >= 0xffffffff then
    local exhausted = errors.new("TransportProtocolError", "Client command sequence exhausted", "fatal")
    self.in_flight = pending
    self.sending = true
    self:_end(exhausted)
    return
  end

  self.sending = true
  self.in_flight = pending
  local sequence = self.command_sequence + 1
  local envelope = {
    type = "command",
    sequence = sequence,
    id = pending.id,
    command = pending.command,
  }
  local function wrote(err)
    if self.in_flight ~= pending then
      return
    end
    if err then
      self:_end(err)
      return
    end
    self.in_flight = nil
    self.sending = false
    self.command_sequence = sequence
    self:_complete_send(pending, nil, { sequence = sequence, id = pending.id })
    self:_send_next()
  end
  local sent, send_error = pcall(self.connection.send, self.connection, envelope, wrote)
  if not sent then
    wrote(
      type(send_error) == "table" and send_error
        or errors.new("EngineConnectionError", "Refine socket write failed", "recoverable")
    )
  end
end

function Session:send(command, command_id, callback)
  callback = callback or function() end
  local ok, validation_error = pcall(wire.validate_command, command)
  if not ok then
    callback(validation_error)
    return
  end
  local id = command_id or self.id_generator()
  local valid_id, id_error = pcall(nonempty_string, id, "command id")
  if not valid_id then
    callback(id_error)
    return
  end
  if self.closed or self.ended then
    callback(errors.new("EngineConnectionError", "Refine transport session is closed", "recoverable"))
    return
  end
  if self.close_enqueued then
    callback(errors.new("EngineConnectionError", "Refine transport session is closing", "recoverable"))
    return
  end
  local is_close = command.type == "closeDocument"
  if not is_close and #self.send_queue >= MAX_WAITING_COMMANDS then
    callback(errors.new("EngineConnectionError", "Refine command queue is full", "recoverable"))
    return
  end
  if is_close then
    self.close_enqueued = true
  end
  self.send_queue[#self.send_queue + 1] = {
    command = command,
    id = id,
    callback = callback,
    completed = false,
  }
  self:_send_next()
end

function Session:close()
  if self.closed then
    return
  end
  self.closed = true
  self:_fail_sends(errors.new("EngineConnectionError", "Refine transport session is closed", "recoverable"))
  self.connection:close()
end

function M.new(options)
  options = options or {}
  validate_identity(options.client)
  local host_capabilities = options.host_capabilities or { interceptableSuggestionActionKeys = {} }
  wire.validate_host_capabilities(host_capabilities)
  if options.frontend ~= nil then
    if type(options.frontend) ~= "table" or vim.islist(options.frontend) then
      errors.raise("TransportProtocolError", "frontend must be an object", "fatal", nil, 2)
    end
    nonempty_string(options.frontend.id, "frontend.id")
    if #options.frontend.id > 128 then
      errors.raise("TransportProtocolError", "frontend.id is too long", "fatal", nil, 2)
    end
  end

  local transport = {
    client = vim.deepcopy(options.client),
    frontend = options.frontend and vim.deepcopy(options.frontend) or nil,
    host_capabilities = vim.deepcopy(host_capabilities),
    endpoint_locator = options.endpoint_locator or endpoint.locator(),
    connector = options.connector or unix.connector(),
    delay = options.delay or default_delay,
    id_generator = options.uuid or uuid.v4,
  }

  function transport:connect(connect_options, callback)
    connect_options = connect_options or {}
    callback = callback or function() end
    local run_id = connect_options.run_id or self.id_generator()
    nonempty_string(run_id, "run_id")
    if #run_id > 128 then
      errors.raise("TransportProtocolError", "run_id must be at most 128 UTF-8 bytes", "fatal", nil, 2)
    end
    local callback_used = false
    local cancel_handshake_timeout = function() end
    local function finish(err, session)
      if callback_used then
        return
      end
      callback_used = true
      cancel_handshake_timeout()
      callback(err, session)
    end

    self.endpoint_locator:locate(function(locate_error, descriptor)
      if locate_error then
        finish(locate_error)
        return
      end
      self.connector:connect(descriptor.socketPath, function(connect_error, connection)
        if connect_error then
          finish(connect_error)
          return
        end

        local session
        local welcomed = false
        cancel_handshake_timeout = self.delay(HANDSHAKE_TIMEOUT_MS, function()
          if callback_used then
            return
          end
          local timeout_error =
            errors.new("EngineConnectionError", "Timed out waiting for Refine welcome", "recoverable")
          callback_used = true
          cancel_handshake_timeout()
          connection:close()
          callback(timeout_error)
        end)
        if callback_used then
          cancel_handshake_timeout()
          return
        end
        connection:receive(function(frame)
          if callback_used and not welcomed then
            return
          end
          if welcomed then
            session:_accept_frame(frame)
            return
          end
          local decoded, response = pcall(wire.decode_handshake, frame)
          if not decoded then
            connection:close()
            finish(response)
            return
          end
          if response.type == "rejected" then
            connection:close()
            finish(incompatible_error(response.protocol))
            return
          end
          if response.serverEpoch ~= descriptor.serverEpoch then
            connection:close()
            finish(errors.new("EndpointReplacedError", "Refine server epoch changed during handshake", "recoverable"))
            return
          end
          welcomed = true
          session = Session.new(connection, response, self.id_generator)
          finish(nil, session)
        end, function(stream_error)
          if callback_used and not welcomed then
            return
          end
          if welcomed then
            session:_end(
              stream_error or errors.new("EngineConnectionError", "Refine closed the connection", "recoverable")
            )
          else
            finish(
              stream_error
                or errors.new("EngineConnectionError", "Refine closed the connection before welcome", "recoverable")
            )
          end
        end)

        local hello = {
          type = "hello",
          protocol = { major = wire.PROTOCOL_MAJOR, minor = wire.PROTOCOL_MINOR },
          client = vim.deepcopy(self.client),
          hostCapabilities = vim.deepcopy(self.host_capabilities),
          runId = run_id,
          launchToken = descriptor.launchToken,
          capabilities = {},
        }
        if self.frontend then
          hello.frontend = vim.deepcopy(self.frontend)
        end
        connection:send(hello, function(send_error)
          if callback_used then
            return
          end
          if send_error then
            connection:close()
            finish(send_error)
          end
        end)
      end)
    end)
  end

  return transport
end

M.errors = errors
M.wire = wire

return M
