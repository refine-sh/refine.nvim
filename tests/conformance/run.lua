local script_path = debug.getinfo(1, "S").source:sub(2)
local repository_root = vim.fn.fnamemodify(script_path, ":p:h:h:h")
vim.opt.runtimepath:prepend(repository_root)
package.path = table.concat({
  repository_root .. "/lua/?.lua",
  repository_root .. "/lua/?/init.lua",
  package.path,
}, ";")

local function argument(name)
  for index, value in ipairs(arg or {}) do
    if value == name and arg[index + 1] ~= nil then
      return arg[index + 1]
    end
  end
  error("missing " .. name)
end

local function read_json(path)
  local descriptor = assert(vim.uv.fs_open(path, "r", 438))
  local stat = assert(vim.uv.fs_fstat(descriptor))
  local bytes = assert(vim.uv.fs_read(descriptor, stat.size, 0))
  assert(vim.uv.fs_close(descriptor))
  return vim.json.decode(bytes)
end

local function await(label, predicate)
  if not vim.wait(6000, predicate, 5) then
    error(label .. " timed out")
  end
end

local function assert_equal(expected, actual, label)
  if not vim.deep_equal(expected, actual) then
    error(("%s differs\nexpected: %s\nactual: %s"):format(label, vim.inspect(expected), vim.inspect(actual)))
  end
end

local function substitute(value, launch_token, server_epoch)
  if type(value) == "string" then
    if value == "${launchToken}" then
      return launch_token
    end
    if value == "${serverEpoch}" then
      return server_epoch
    end
    return value
  end
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, child in pairs(value) do
    result[key] = substitute(child, launch_token, server_epoch)
  end
  return result
end

local function step_message(vector, step)
  if step.messageRef ~= nil then
    return assert(vector.messages[step.messageRef], "missing messageRef " .. step.messageRef)
  end
  return step.message
end

local function assert_rejection(expected, actual)
  if actual == nil then
    error("expected a typed handshake rejection")
  end
  assert_equal(expected.reason, actual.reason, "rejection reason")
  assert_equal(expected.recovery, actual.recovery, "rejection recovery")
  assert_equal(expected.protocol, actual.protocol, "rejection protocol")
  if expected.receivedProtocol ~= nil then
    assert_equal(expected.receivedProtocol, actual.received_protocol, "received protocol")
  end
end

local function run_connection(vector, descriptor_path, connection_vector)
  local steps = connection_vector.steps
  local hello = assert(step_message(vector, steps[1]), "connection must start with hello")
  local response = assert(step_message(vector, steps[2]), "connection must contain a handshake response")
  local endpoint = require("refine.transport.endpoint")
  local transport = require("refine.transport")
  local client = transport.new({
    client = hello.client,
    frontend = hello.frontend,
    host_capabilities = hello.hostCapabilities,
    capabilities = hello.capabilities,
    endpoint_locator = endpoint.locator({ path = descriptor_path }),
    uuid = function()
      return "conformance-generated-id"
    end,
  })

  local connected = false
  local connect_error
  local session
  client:connect({ run_id = hello.runId }, function(err, value)
    connect_error = err
    session = value
    connected = true
  end)
  await("handshake", function()
    return connected
  end)

  if response.type == "rejected" then
    if connection_vector.expectedOutcome == "protocolError" then
      if connect_error == nil or connect_error.recoverability ~= "fatal" then
        error("invalid handshake rejection did not produce a fatal protocol error")
      end
      return
    end
    assert_rejection(response, connect_error)
    return
  end
  if connect_error ~= nil or session == nil then
    error("welcome failed: " .. tostring(connect_error))
  end
  assert_equal(response.runResumed, session.run_resumed, "welcome runResumed")
  assert_equal(response.capabilities, session.capabilities, "welcome capabilities")

  if connection_vector.sequenceStarts and connection_vector.sequenceStarts.client then
    session.command_sequence = connection_vector.sequenceStarts.client - 1
  end

  local events = {}
  local ended = false
  local end_error
  session:events(function(event)
    events[#events + 1] = event
  end, function(err)
    end_error = err
    ended = true
  end)

  local descriptor = read_json(descriptor_path)
  for index = 3, #steps do
    local step = steps[index]
    local message = step_message(vector, step)
    if step.rawFrameHex ~= nil or step.invalid ~= nil then
      await("protocol failure", function()
        return ended
      end)
      if end_error == nil or end_error.recoverability ~= "fatal" then
        error("invalid server input did not produce a fatal protocol error")
      end
    elseif message ~= nil and step.direction == "client" then
      local completed = false
      local send_error
      local receipt
      session:send(message.command, message.id, function(err, value)
        send_error = err
        receipt = value
        completed = true
      end)
      await("command send", function()
        return completed
      end)
      if send_error ~= nil then
        error("command send failed: " .. tostring(send_error))
      end
      assert_equal({ sequence = message.sequence, id = message.id }, receipt, "command receipt")
      if step.exhaustsSequence then
        await("sequence exhaustion close", function()
          return ended
        end)
        if end_error == nil or end_error.recoverability ~= "recoverable" then
          error("sequence exhaustion must close recoverably")
        end
      end
    elseif message ~= nil and step.direction == "server" then
      await("server event", function()
        return #events > 0
      end)
      local expected = substitute(message, descriptor.launchToken, descriptor.serverEpoch)
      assert_equal(expected, table.remove(events, 1), "server event")
    elseif step.close == true and step.direction == "server" then
      await("server close", function()
        return ended
      end)
    elseif step.close == true and step.direction == "client" then
      session:close()
    end
  end
  session:close()
end

local function main()
  local descriptor_path = argument("--descriptor")
  local scenario = argument("--scenario")
  local vector = read_json(vim.fn.getcwd() .. "/vectors/state/" .. scenario .. ".json")
  if vector.socketRunnable ~= true then
    error("scenario is not socket-runnable: " .. scenario)
  end
  for _, connection in ipairs(vector.connections) do
    run_connection(vector, descriptor_path, connection)
  end
  io.write(vim.json.encode({ status = "ok", scenario = scenario }) .. "\n")
end

local ok, failure = xpcall(main, debug.traceback)
if not ok then
  io.stderr:write(failure .. "\n")
  vim.cmd("cquit 1")
end
