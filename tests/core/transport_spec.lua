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
        protocol = { major = 2, minor = 4 },
        serverEpoch = "epoch-1",
        runResumed = false,
        limits = { maxFrameBytes = 8388608, maxSources = 2 },
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
        protocolMajor = 2,
        pid = 123,
      }
      if not options.legacy_descriptor then
        descriptor.protocolMinor = 4
      end
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

describe("Refine Protocol 2.4 transport", function()
  it("authenticates with frontend and host capabilities then sequences commands and events", function()
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
      protocol = { major = 2, minor = 4 },
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
          sources = { { sourceId = "document", text = "create an link", sourceSyntax = "mixed" } },
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
          protocol = { major = 2, minor = 4 },
          serverEpoch = "epoch-1",
          runResumed = false,
          limits = { maxFrameBytes = wire.MAX_FRAME_BYTES, maxSources = wire.MAX_SOURCES },
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
          sources = { { sourceId = "document", text = "private source contents", sourceSyntax = "mixed" } },
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
          sources = { { sourceId = "document", text = "private overflow contents", sourceSyntax = "mixed" } },
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
        protocol = { major = 2, minor = 4 },
        serverEpoch = "epoch-2",
        runResumed = false,
        limits = { maxFrameBytes = 8388608, maxSources = 2 },
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
        protocol = { major = 2, minor = 4 },
        serverEpoch = "",
        runResumed = false,
        limits = { maxFrameBytes = 8388608, maxSources = 2 },
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

  it("reports the required update for exact-minor handshake mismatches", function()
    local transport = require("refine.transport")
    for _, case in ipairs({
      { protocol = { major = 2, minor = 3 }, update = "server" },
      { protocol = { major = 2, minor = 5 }, update = "client" },
    }) do
      local fixture = fake_transport_fixture({
        handshake = {
          type = "welcome",
          protocol = case.protocol,
          serverEpoch = "epoch-1",
          runResumed = false,
          limits = { maxFrameBytes = 8388608, maxSources = 2 },
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
      assert_equal(case.update, connect_error.required_update)
    end
  end)

  it("defers a legacy descriptor's exact minor check until the handshake", function()
    local transport = require("refine.transport")
    local fixture = fake_transport_fixture({
      legacy_descriptor = true,
      handshake = {
        type = "welcome",
        protocol = { major = 2, minor = 3 },
        serverEpoch = "epoch-1",
        runResumed = false,
        limits = { maxFrameBytes = 8388608, maxSources = 2 },
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

    client:connect({ run_id = "run-legacy-descriptor" }, function(err)
      connect_error = err
    end)

    assert_equal(1, #fixture.sent)
    assert_equal("hello", fixture.sent[1].type)
    assert_equal("IncompatibleProtocolError", connect_error.kind)
    assert_equal("server", connect_error.required_update)
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
    local connect_error
    client:connect({ run_id = "run-1" }, function(err)
      callback_count = callback_count + 1
      connect_error = err
    end)

    assert_equal(5000, scheduled_delay_ms)
    fire_timeout()
    assert_equal("EngineConnectionError", connect_error.kind)
    assert_equal("recoverable", connect_error.recoverability)
    assert_equal("Timed out waiting for Refine welcome", connect_error.message)
    assert_equal(1, callback_count)
    assert_equal(1, close_count)

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
