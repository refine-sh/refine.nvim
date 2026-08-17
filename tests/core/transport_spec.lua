local function fake_transport_fixture(options)
  options = options or {}
  local sent = {}
  local receiver
  local ended
  local closed = false
  local connection = {}

  function connection:receive(on_frame, on_end)
    receiver = on_frame
    ended = on_end
  end

  function connection:send(value, callback)
    sent[#sent + 1] = value
    callback(nil)
    if value.type == "hello" then
      receiver(options.handshake or {
        type = "welcome",
        protocol = { major = 1, minor = 0 },
        serverEpoch = "epoch-1",
        runResumed = false,
        limits = { maxFrameBytes = 8388608, maxSources = 2, maxSourceBytes = 1048576 },
        capabilities = {},
      })
    end
  end

  function connection:close()
    closed = true
  end

  local connector = {
    connect = function(_, path, callback)
      assert_equal("/private/tmp/refine/server.sock", path)
      callback(nil, connection)
    end,
  }
  local locator = {
    locate = function(_, callback)
      local descriptor = {
        version = 1,
        socketPath = "/private/tmp/refine/server.sock",
        launchToken = "secret-1",
        serverEpoch = "epoch-1",
        protocolMajor = 1,
        pid = 123,
      }
      descriptor.protocolMinor = 0
      callback(nil, descriptor)
    end,
  }
  return {
    connector = connector,
    locator = locator,
    sent = sent,
    push = function(value)
      receiver(value)
    end,
    finish = function(err)
      ended(err)
    end,
    is_closed = function()
      return closed
    end,
  }
end

describe("Refine Protocol 1.0 transport", function()
  it("presents frontend and host capabilities then sequences commands and events", function()
    local transport = require("refine.transport")
    local fixture = fake_transport_fixture()
    local client = transport.new({
      client = { id = "refine-neovim", version = "0.1.0", host = "neovim" },
      frontend = { id = "ghostty" },
      host_capabilities = { interceptableSuggestionActionKeys = { "tab", "escape" } },
      endpoint_locator = fixture.locator,
      connector = fixture.connector,
      uuid = function()
        return "generated-id"
      end,
    })

    local session
    client:connect({ run_id = "run-1" }, function(err, value)
      assert_equal(nil, err)
      session = value
    end)
    assert_truthy(session)
    assert_equal({
      type = "hello",
      protocol = { major = 1, minor = 0 },
      client = { id = "refine-neovim", version = "0.1.0", host = "neovim" },
      frontend = { id = "ghostty" },
      hostCapabilities = { interceptableSuggestionActionKeys = { "tab", "escape" } },
      runId = "run-1",
      launchToken = "secret-1",
      capabilities = {},
    }, fixture.sent[1])

    local receipt
    session:send(
      {
        type = "openDocument",
        snapshot = {
          revision = "doc:0",
          sources = { { sourceId = "document", text = "create an link", sourceSyntax = "plainText" } },
        },
      },
      nil,
      function(err, value)
        assert_equal(nil, err)
        receipt = value
      end
    )
    assert_equal({ sequence = 1, id = "generated-id" }, receipt)
    assert_equal(1, fixture.sent[2].sequence)

    local events = {}
    session:events(function(event)
      events[#events + 1] = event
    end, function(err)
      error(err or "event stream ended")
    end)
    fixture.push({
      type = "event",
      sequence = 1,
      epoch = "epoch-1",
      event = { type = "documentAccepted", revision = "doc:0" },
    })
    assert_equal("documentAccepted", events[1].event.type)
  end)

  it("rejects check intents scoped to more than two sources before sending", function()
    local fixture = fake_transport_fixture()
    local client = require("refine.transport").new({
      client = { id = "refine-neovim", version = "0.1.0", host = "neovim" },
      endpoint_locator = fixture.locator,
      connector = fixture.connector,
    })
    local session
    client:connect({ run_id = "run-1" }, function(err, value)
      assert_equal(nil, err)
      session = value
    end)

    local send_error
    session:send(
      {
        type = "requestCheck",
        revision = "revision-1",
        intent = { sourceIds = { "body", "title", "footnote" } },
      },
      "check-1",
      function(err)
        send_error = err
      end
    )

    assert_equal("TransportProtocolError", send_error.kind)
    assert_matches("at most 2", send_error.message)
    assert_equal(1, #fixture.sent)
  end)

  it("closes recoverably as soon as either sequence sends UInt32.max", function()
    local transport = require("refine.transport")

    local command_fixture = fake_transport_fixture()
    local command_client = transport.new({
      client = { id = "refine-neovim", version = "0.1.0", host = "neovim" },
      endpoint_locator = command_fixture.locator,
      connector = command_fixture.connector,
      uuid = function()
        return "sequence-id"
      end,
    })
    local command_session
    command_client:connect({ run_id = "run-command-max" }, function(err, value)
      assert_equal(nil, err)
      command_session = value
    end)
    local command_end
    command_session:events(function() end, function(err)
      command_end = err
    end)
    command_session.command_sequence = 0xfffffffe
    local receipt
    command_session:send({ type = "closeDocument" }, "last-command", function(err, value)
      assert_equal(nil, err)
      receipt = value
    end)
    assert_equal({ sequence = 0xffffffff, id = "last-command" }, receipt)
    assert_equal(true, command_fixture.is_closed())
    assert_equal("recoverable", command_end.recoverability)

    local event_fixture = fake_transport_fixture()
    local event_client = transport.new({
      client = { id = "refine-neovim", version = "0.1.0", host = "neovim" },
      endpoint_locator = event_fixture.locator,
      connector = event_fixture.connector,
      uuid = function()
        return "sequence-id"
      end,
    })
    local event_session
    event_client:connect({ run_id = "run-event-max" }, function(err, value)
      assert_equal(nil, err)
      event_session = value
    end)
    event_session.expected_event_sequence = 0xffffffff
    local received
    local event_end
    event_session:events(function(value)
      received = value
    end, function(err)
      event_end = err
    end)
    event_fixture.push({
      type = "event",
      sequence = 0xffffffff,
      epoch = "epoch-1",
      event = { type = "documentAccepted", revision = "revision-max" },
    })
    assert_equal(0xffffffff, received.sequence)
    assert_equal(true, event_fixture.is_closed())
    assert_equal("recoverable", event_end.recoverability)
  end)

  it("offers recognized capabilities and exposes the activated subset", function()
    local capability = "com.example.refine.optional-metadata.v1"
    local fixture = fake_transport_fixture({
      handshake = {
        type = "welcome",
        protocol = { major = 1, minor = 0 },
        serverEpoch = "epoch-1",
        runResumed = false,
        limits = { maxFrameBytes = 8388608, maxSources = 2, maxSourceBytes = 1048576 },
        capabilities = { capability },
      },
    })
    local client = require("refine.transport").new({
      client = { id = "refine-neovim", version = "0.1.0", host = "neovim" },
      host_capabilities = { interceptableSuggestionActionKeys = {} },
      known_capabilities = { capability },
      capabilities = { capability, "com.example.refine.unknown.v1" },
      endpoint_locator = fixture.locator,
      connector = fixture.connector,
    })
    local session

    client:connect({ run_id = "run-1" }, function(err, value)
      assert_equal(nil, err)
      session = value
    end)

    assert_equal({ capability }, fixture.sent[1].capabilities)
    assert_equal({ capability }, session.capabilities)
  end)

  it("rejects invalid capability offers before endpoint discovery", function()
    local capability = "com.example.refine.optional-metadata.v1"
    local too_many = {}
    for index = 1, 65 do
      too_many[index] = ("com.example.refine.feature-%d.v1"):format(index)
    end
    for _, case in ipairs({
      { offers = { capability, capability }, pattern = "duplicates" },
      { offers = too_many, pattern = "at most 64" },
      { offers = { "com.example.refine.invalid capability.v1" }, pattern = "visible ASCII" },
    }) do
      local fixture = fake_transport_fixture()
      assert_raises(case.pattern, function()
        require("refine.transport").new({
          client = { id = "refine-neovim", version = "0.1.0", host = "neovim" },
          host_capabilities = { interceptableSuggestionActionKeys = {} },
          known_capabilities = {},
          capabilities = case.offers,
          endpoint_locator = fixture.locator,
          connector = fixture.connector,
        })
      end)
      assert_equal(0, #fixture.sent)
    end
  end)

  it("rejects every invalid client-originated identifier before socket send", function()
    local base_options = {
      client = { id = "refine-neovim", version = "0.1.0", host = "neovim" },
      frontend = { id = "ghostty" },
      host_capabilities = { interceptableSuggestionActionKeys = {} },
    }
    for _, case in ipairs({
      { path = { "client", "id" }, value = "client id" },
      { path = { "client", "version" }, value = "v\195\169rsion" },
      { path = { "client", "host" }, value = string.rep("h", 129) },
      { path = { "frontend", "id" }, value = "front\nend" },
    }) do
      local fixture = fake_transport_fixture()
      local options = vim.deepcopy(base_options)
      options.endpoint_locator = fixture.locator
      options.connector = fixture.connector
      options[case.path[1]][case.path[2]] = case.value

      assert_raises("1%-to%-128%-byte visible ASCII identifier", function()
        require("refine.transport").new(options)
      end)
      assert_equal(0, #fixture.sent)
    end

    local fixture = fake_transport_fixture()
    local client = require("refine.transport").new(vim.tbl_extend("force", vim.deepcopy(base_options), {
      endpoint_locator = fixture.locator,
      connector = fixture.connector,
    }))
    assert_raises("1%-to%-128%-byte visible ASCII identifier", function()
      client:connect({ run_id = "run id" }, function() end)
    end)
    assert_equal(0, #fixture.sent)

    local session
    client:connect({ run_id = "run-id" }, function(err, value)
      assert_equal(nil, err)
      session = value
    end)
    local snapshot = {
      revision = "revision",
      sources = { { sourceId = "document", text = "text", sourceSyntax = "plainText" } },
    }
    local commands = {
      {
        command = {
          type = "openDocument",
          snapshot = vim.tbl_extend("force", vim.deepcopy(snapshot), {
            revision = "bad revision",
          }),
        },
      },
      {
        command = {
          type = "openDocument",
          snapshot = {
            revision = "revision",
            sources = { { sourceId = "d\195\182cument", text = "text", sourceSyntax = "plainText" } },
          },
        },
      },
      { command = { type = "requestCheck", revision = "revision" }, id = string.rep("c", 129) },
      {
        command = {
          type = "performAction",
          actionId = "action id",
          kind = "dismiss",
          suggestion = { id = "suggestion", documentRevision = "revision" },
        },
      },
      {
        command = {
          type = "performAction",
          actionId = "action",
          kind = "dismiss",
          suggestion = { id = "suggestion\nid", documentRevision = "revision" },
        },
      },
      {
        command = { type = "completeApply", transactionId = "transacti\195\182n", outcome = { status = "unavailable" } },
      },
      {
        command = {
          type = "requestCheck",
          revision = "revision",
          intent = { forcedLanguageTag = "en US" },
        },
      },
    }
    for index, case in ipairs(commands) do
      local send_error
      session:send(case.command, case.id or ("command-%d"):format(index), function(err)
        send_error = err
      end)
      assert_equal("TransportProtocolError", send_error.kind)
      assert_matches("1%-to%-128%-byte visible ASCII identifier", send_error.message)
      assert_equal(1, #fixture.sent)
    end
  end)

  it("rejects unknown, unoffered, duplicate, and oversized activations", function()
    local known = "com.example.refine.optional-metadata.v1"
    local unknown = "com.example.refine.unknown.v1"
    local too_many = {}
    for index = 1, 65 do
      too_many[index] = ("com.example.refine.feature-%d.v1"):format(index)
    end
    for _, case in ipairs({
      { known = { known }, offers = { known }, activated = { unknown }, pattern = "unknown activation" },
      { known = { known }, offers = {}, activated = { known }, pattern = "unoffered activation" },
      { known = { known }, offers = { known }, activated = { known, known }, pattern = "duplicates" },
      { known = {}, offers = {}, activated = too_many, pattern = "at most 64" },
    }) do
      local fixture = fake_transport_fixture({
        handshake = {
          type = "welcome",
          protocol = { major = 1, minor = 0 },
          serverEpoch = "epoch-1",
          runResumed = false,
          limits = { maxFrameBytes = 8388608, maxSources = 2, maxSourceBytes = 1048576 },
          capabilities = case.activated,
        },
      })
      local client = require("refine.transport").new({
        client = { id = "refine-neovim", version = "0.1.0", host = "neovim" },
        host_capabilities = { interceptableSuggestionActionKeys = {} },
        known_capabilities = case.known,
        capabilities = case.offers,
        endpoint_locator = fixture.locator,
        connector = fixture.connector,
      })
      local connect_error

      client:connect({ run_id = "run-1" }, function(err)
        connect_error = err
      end)

      assert_equal("TransportProtocolError", connect_error.kind)
      assert_matches(case.pattern, connect_error.message)
      assert_equal(true, fixture.is_closed())
    end
  end)

  it("bounds queued commands while reserving an ordered closeDocument", function()
    local receive_frame
    local pending_writes = {}
    local transmitted = {}
    local connection = { closed = false }

    function connection:receive(on_frame)
      receive_frame = on_frame
    end

    function connection:send(value, done)
      if value.type == "hello" then
        done(nil)
        local wire = require("refine.transport.wire")
        receive_frame({
          type = "welcome",
          protocol = { major = 1, minor = 0 },
          serverEpoch = "epoch-1",
          runResumed = false,
          limits = {
            maxFrameBytes = wire.MAX_FRAME_BYTES,
            maxSources = wire.MAX_SOURCES,
            maxSourceBytes = wire.MAX_SOURCE_BYTES,
          },
          capabilities = {},
        })
        return
      end
      transmitted[#transmitted + 1] = vim.deepcopy(value)
      pending_writes[#pending_writes + 1] = done
    end

    function connection:close()
      self.closed = true
    end

    local transport = require("refine.transport").new({
      client = { id = "refine-neovim", version = "0.1.0", host = "neovim" },
      host_capabilities = { interceptableSuggestionActionKeys = {} },
      endpoint_locator = {
        locate = function(_, done)
          done(nil, {
            socketPath = "/private/tmp/refine/server.sock",
            launchToken = "secret-1",
            serverEpoch = "epoch-1",
          })
        end,
      },
      connector = {
        connect = function(_, _, done)
          done(nil, connection)
        end,
      },
      uuid = function()
        return "generated-id"
      end,
    })
    local session
    transport:connect({ run_id = "run-1" }, function(err, value)
      assert_equal(nil, err)
      session = value
    end)

    local completions = {}
    session:send(
      {
        type = "openDocument",
        snapshot = {
          revision = "doc:0",
          sources = { { sourceId = "document", text = "private source contents", sourceSyntax = "plainText" } },
        },
      },
      "open",
      function(err, receipt)
        completions.open = { err = err, receipt = receipt }
      end
    )
    for index = 1, 128 do
      session:send({ type = "requestCheck", revision = "doc:0" }, ("check-%03d"):format(index), function(err)
        assert_equal(nil, err)
        completions[#completions + 1] = index
      end)
    end

    local overflow_count = 0
    local overflow_error
    session:send(
      {
        type = "openDocument",
        snapshot = {
          revision = "private-overflow-revision",
          sources = { { sourceId = "document", text = "private overflow contents", sourceSyntax = "plainText" } },
        },
      },
      "overflow",
      function(err)
        overflow_count = overflow_count + 1
        overflow_error = err
      end
    )

    local close_count = 0
    local close_receipt
    session:send({ type = "closeDocument" }, "close", function(err, receipt)
      assert_equal(nil, err)
      close_count = close_count + 1
      close_receipt = receipt
    end)

    assert_equal(1, #transmitted)
    assert_equal(1, overflow_count)
    assert_equal("EngineConnectionError", overflow_error.kind)
    assert_equal("recoverable", overflow_error.recoverability)
    assert_equal(nil, overflow_error.message:find("private", 1, true))

    while #pending_writes > 0 do
      local finish = table.remove(pending_writes, 1)
      finish(nil)
    end

    assert_equal(130, #transmitted)
    assert_equal("open", transmitted[1].id)
    for index = 1, 128 do
      assert_equal(("check-%03d"):format(index), transmitted[index + 1].id)
    end
    assert_equal("closeDocument", transmitted[130].command.type)
    assert_equal("close", transmitted[130].id)
    assert_equal(1, overflow_count)
    assert_equal(1, close_count)
    assert_equal({ sequence = 130, id = "close" }, close_receipt)
    assert_equal(128, #completions)
    assert_equal({ sequence = 1, id = "open" }, completions.open.receipt)
  end)

  it("rejects an oversized decoded source before socket send", function()
    local fixture = fake_transport_fixture()
    local client = require("refine.transport").new({
      client = { id = "refine-neovim", version = "0.1.0", host = "neovim" },
      host_capabilities = { interceptableSuggestionActionKeys = {} },
      endpoint_locator = fixture.locator,
      connector = fixture.connector,
    })
    local session
    client:connect({ run_id = "run-1" }, function(err, value)
      assert_equal(nil, err)
      session = value
    end)
    local send_error

    session:send(
      {
        type = "openDocument",
        snapshot = {
          revision = "revision-1",
          sources = {
            {
              sourceId = "document",
              sourceSyntax = "plainText",
              text = string.rep("a", 1024 * 1024 + 1),
            },
          },
        },
      },
      "oversized",
      function(err)
        send_error = err
      end
    )

    assert_equal("TransportProtocolError", send_error.kind)
    assert_equal(1, #fixture.sent)
  end)

  it("rejects a duplicate or unsupported interceptable key before opening the endpoint", function()
    local transport = require("refine.transport")
    local fixture = fake_transport_fixture()
    assert_raises("duplicates", function()
      transport.new({
        client = { id = "refine-neovim", version = "0.1.0", host = "neovim" },
        host_capabilities = { interceptableSuggestionActionKeys = { "tab", "tab" } },
        endpoint_locator = fixture.locator,
        connector = fixture.connector,
      })
    end)
    assert_equal(0, #fixture.sent)
  end)

  it("ends a session fatally on an invalid event sequence", function()
    local transport = require("refine.transport")
    local fixture = fake_transport_fixture()
    local client = transport.new({
      client = { id = "refine-neovim", version = "0.1.0", host = "neovim" },
      host_capabilities = { interceptableSuggestionActionKeys = {} },
      endpoint_locator = fixture.locator,
      connector = fixture.connector,
    })
    local session
    client:connect({ run_id = "run-1" }, function(_, value)
      session = value
    end)
    local ended_with
    session:events(function() end, function(err)
      ended_with = err
    end)
    fixture.push({
      type = "event",
      sequence = 2,
      epoch = "epoch-1",
      event = { type = "documentAccepted", revision = "doc:0" },
    })
    assert_equal("TransportProtocolError", ended_with.kind)
    assert_equal(true, fixture.is_closed())
  end)

  it("reports a replaced endpoint epoch as recoverable", function()
    local transport = require("refine.transport")
    local fixture = fake_transport_fixture({
      handshake = {
        type = "welcome",
        protocol = { major = 1, minor = 0 },
        serverEpoch = "epoch-2",
        runResumed = false,
        limits = { maxFrameBytes = 8388608, maxSources = 2, maxSourceBytes = 1048576 },
        capabilities = {},
      },
    })
    local client = transport.new({
      client = { id = "refine-neovim", version = "0.1.0", host = "neovim" },
      host_capabilities = { interceptableSuggestionActionKeys = {} },
      endpoint_locator = fixture.locator,
      connector = fixture.connector,
    })
    local connect_error
    client:connect({ run_id = "run-1" }, function(err)
      connect_error = err
    end)
    assert_equal("EndpointReplacedError", connect_error.kind)
    assert_equal("recoverable", connect_error.recoverability)
  end)

  it("keeps a malformed handshake response fatal", function()
    local transport = require("refine.transport")
    local fixture = fake_transport_fixture({
      handshake = {
        type = "welcome",
        protocol = { major = 1, minor = 0 },
        serverEpoch = "",
        runResumed = false,
        limits = { maxFrameBytes = 8388608, maxSources = 2, maxSourceBytes = 1048576 },
        capabilities = {},
      },
    })
    local client = transport.new({
      client = { id = "refine-neovim", version = "0.1.0", host = "neovim" },
      host_capabilities = { interceptableSuggestionActionKeys = {} },
      endpoint_locator = fixture.locator,
      connector = fixture.connector,
    })
    local connect_error

    client:connect({ run_id = "run-1" }, function(err)
      connect_error = err
    end)

    assert_equal("TransportProtocolError", connect_error.kind)
    assert_equal("fatal", connect_error.recoverability)
    assert_equal(true, fixture.is_closed())
  end)

  it("requires the welcome to confirm the exact Protocol 1.0 source limit", function()
    local transport = require("refine.transport")
    for _, max_source_bytes in ipairs({ 0, 1048575, 1048577 }) do
      local limits = { maxFrameBytes = 8388608, maxSources = 2 }
      if max_source_bytes ~= 0 then
        limits.maxSourceBytes = max_source_bytes
      end
      local fixture = fake_transport_fixture({
        handshake = {
          type = "welcome",
          protocol = { major = 1, minor = 0 },
          serverEpoch = "epoch-1",
          runResumed = false,
          limits = limits,
          capabilities = {},
        },
      })
      local client = transport.new({
        client = { id = "refine-neovim", version = "0.1.0", host = "neovim" },
        host_capabilities = { interceptableSuggestionActionKeys = {} },
        endpoint_locator = fixture.locator,
        connector = fixture.connector,
      })
      local connect_error

      client:connect({ run_id = "run-1" }, function(err)
        connect_error = err
      end)

      assert_equal("TransportProtocolError", connect_error.kind)
      assert_equal(true, fixture.is_closed())
    end
  end)

  it("requires the welcome capability activation array", function()
    local fixture = fake_transport_fixture({
      handshake = {
        type = "welcome",
        protocol = { major = 1, minor = 0 },
        serverEpoch = "epoch-1",
        runResumed = false,
        limits = { maxFrameBytes = 8388608, maxSources = 2, maxSourceBytes = 1048576 },
      },
    })
    local client = require("refine.transport").new({
      client = { id = "refine-neovim", version = "0.1.0", host = "neovim" },
      host_capabilities = { interceptableSuggestionActionKeys = {} },
      endpoint_locator = fixture.locator,
      connector = fixture.connector,
    })
    local connect_error

    client:connect({ run_id = "run-1" }, function(err)
      connect_error = err
    end)

    assert_equal("TransportProtocolError", connect_error.kind)
    assert_equal(true, fixture.is_closed())
  end)

  it("reports exact handshake versions without inferring which side must update", function()
    local transport = require("refine.transport")
    for _, case in ipairs({
      { protocol = { major = 0, minor = 9 } },
      { protocol = { major = 2, minor = 5 } },
    }) do
      local fixture = fake_transport_fixture({
        handshake = {
          type = "welcome",
          protocol = case.protocol,
          serverEpoch = "epoch-1",
          runResumed = false,
          limits = { maxFrameBytes = 8388608, maxSources = 2, maxSourceBytes = 1048576 },
          capabilities = {},
        },
      })
      local client = transport.new({
        client = { id = "refine-neovim", version = "0.1.0", host = "neovim" },
        host_capabilities = { interceptableSuggestionActionKeys = {} },
        endpoint_locator = fixture.locator,
        connector = fixture.connector,
      })
      local connect_error
      client:connect({ run_id = "run-1" }, function(err)
        connect_error = err
      end)
      assert_equal("IncompatibleProtocolError", connect_error.kind)
      assert_equal(case.protocol, connect_error.received_protocol)
      assert_equal({ major = 1, minor = 0 }, connect_error.supported_protocol)
      assert_equal(nil, connect_error.required_update)
    end
  end)

  it("maps every typed handshake rejection to its declared recovery", function()
    local cases = {
      {
        reason = "incompatibleProtocol",
        recovery = "none",
        receivedProtocol = { major = 2, minor = 5 },
        kind = "IncompatibleProtocolError",
        recoverability = "fatal",
      },
      { reason = "invalidClient", recovery = "none", kind = "HandshakeRejectedError", recoverability = "fatal" },
      {
        reason = "runUnavailable",
        recovery = "newRun",
        kind = "HandshakeRejectedError",
        recoverability = "recoverable",
      },
      {
        reason = "runUnavailable",
        recovery = "retry",
        kind = "HandshakeRejectedError",
        recoverability = "recoverable",
      },
      {
        reason = "serverBusy",
        recovery = "retry",
        kind = "HandshakeRejectedError",
        recoverability = "recoverable",
      },
      {
        reason = "engineUnavailable",
        recovery = "retry",
        kind = "HandshakeRejectedError",
        recoverability = "recoverable",
      },
    }

    for _, case in ipairs(cases) do
      local fixture = fake_transport_fixture({
        handshake = {
          type = "rejected",
          reason = case.reason,
          recovery = case.recovery,
          protocol = { major = 1, minor = 0 },
          receivedProtocol = case.receivedProtocol,
        },
      })
      local client = require("refine.transport").new({
        client = { id = "refine-neovim", version = "0.1.0", host = "neovim" },
        host_capabilities = { interceptableSuggestionActionKeys = {} },
        endpoint_locator = fixture.locator,
        connector = fixture.connector,
      })
      local connect_error

      client:connect({ run_id = "run-1" }, function(err)
        connect_error = err
      end)

      assert_equal(case.kind, connect_error.kind)
      assert_equal(case.recoverability, connect_error.recoverability)
      assert_equal(case.reason, connect_error.reason)
      assert_equal(case.recovery, connect_error.recovery)
      assert_equal({ major = 1, minor = 0 }, connect_error.protocol)
      assert_equal(true, fixture.is_closed())
      assert_equal(nil, connect_error.message:match("[Uu]pdate"))
      assert_equal(nil, connect_error.message:match("[Nn]ewer"))
      assert_equal(nil, connect_error.message:match("[Oo]lder"))
      if case.reason == "incompatibleProtocol" then
        assert_equal({ major = 2, minor = 5 }, connect_error.received_protocol)
        assert_equal({ major = 1, minor = 0 }, connect_error.supported_protocol)
        assert_matches("2%.5", connect_error.message)
        assert_matches("1%.0", connect_error.message)
      end
    end
  end)

  it("treats a pre-welcome close as a recoverable connection failure", function()
    local transport = require("refine.transport")
    local on_end
    local connection = {
      receive = function(_, _, finish)
        on_end = finish
      end,
      send = function(_, _, done)
        done(nil)
        on_end(nil)
      end,
      close = function() end,
    }
    local client = transport.new({
      client = { id = "refine-neovim", version = "0.1.0", host = "neovim" },
      host_capabilities = { interceptableSuggestionActionKeys = {} },
      endpoint_locator = {
        locate = function(_, done)
          done(nil, {
            socketPath = "/private/tmp/refine/server.sock",
            launchToken = "secret-1",
            serverEpoch = "epoch-1",
          })
        end,
      },
      connector = {
        connect = function(_, _, done)
          done(nil, connection)
        end,
      },
    })
    local connect_error
    client:connect({ run_id = "run-1" }, function(err)
      connect_error = err
    end)
    assert_equal("EngineConnectionError", connect_error.kind)
    assert_equal("recoverable", connect_error.recoverability)
  end)

  it("times out a silent pre-welcome connection once and closes it", function()
    local transport = require("refine.transport")
    local on_end
    local scheduled_delay_ms
    local fire_timeout
    local finish_send
    local close_count = 0
    local connection = {
      receive = function(_, _, finish)
        on_end = finish
      end,
      send = function(_, _, done)
        finish_send = done
      end,
      close = function()
        close_count = close_count + 1
      end,
    }
    local client = transport.new({
      client = { id = "refine-neovim", version = "0.1.0", host = "neovim" },
      host_capabilities = { interceptableSuggestionActionKeys = {} },
      endpoint_locator = {
        locate = function(_, done)
          done(nil, {
            socketPath = "/private/tmp/refine/server.sock",
            launchToken = "secret-1",
            serverEpoch = "epoch-1",
          })
        end,
      },
      connector = {
        connect = function(_, _, done)
          done(nil, connection)
        end,
      },
      delay = function(milliseconds, callback)
        scheduled_delay_ms = milliseconds
        fire_timeout = callback
        return function() end
      end,
    })
    local callback_count = 0
    local close_count_when_callback_ran
    local connect_error
    client:connect({ run_id = "run-1" }, function(err)
      callback_count = callback_count + 1
      close_count_when_callback_ran = close_count
      connect_error = err
    end)

    assert_equal(5000, scheduled_delay_ms)
    fire_timeout()
    assert_equal("EngineConnectionError", connect_error.kind)
    assert_equal("recoverable", connect_error.recoverability)
    assert_equal("Timed out waiting for Refine welcome", connect_error.message)
    assert_equal(1, callback_count)
    assert_equal(1, close_count)
    assert_equal(1, close_count_when_callback_ran)

    on_end(nil)
    finish_send({ message = "late send failure" })
    assert_equal(1, callback_count)
    assert_equal(1, close_count)
  end)

  it("does not start handshake I/O after a synchronous deadline", function()
    local transport = require("refine.transport")
    local receive_count = 0
    local send_count = 0
    local close_count = 0
    local connection = {
      receive = function()
        receive_count = receive_count + 1
      end,
      send = function()
        send_count = send_count + 1
      end,
      close = function()
        close_count = close_count + 1
      end,
    }
    local client = transport.new({
      client = { id = "refine-neovim", version = "0.1.0", host = "neovim" },
      host_capabilities = { interceptableSuggestionActionKeys = {} },
      endpoint_locator = {
        locate = function(_, done)
          done(nil, {
            socketPath = "/private/tmp/refine/server.sock",
            launchToken = "secret-1",
            serverEpoch = "epoch-1",
          })
        end,
      },
      connector = {
        connect = function(_, _, done)
          done(nil, connection)
        end,
      },
      delay = function(_, callback)
        callback()
        return function() end
      end,
    })
    local callback_count = 0
    local connect_error

    client:connect({ run_id = "run-1" }, function(err)
      callback_count = callback_count + 1
      connect_error = err
    end)

    assert_equal("EngineConnectionError", connect_error.kind)
    assert_equal("recoverable", connect_error.recoverability)
    assert_equal(1, callback_count)
    assert_equal(1, close_count)
    assert_equal(0, receive_count)
    assert_equal(0, send_count)
  end)
end)
