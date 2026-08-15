local function snapshot(revision, text)
  return {
    revision = revision,
    sources = { { sourceId = "document", text = text, sourceSyntax = "mixed" } },
  }
end

describe("integration command ordering", function()
  it("flushes closeDocument behind an earlier write before closing normally", function()
    local next_id = (function()
      local value = 0
      return function()
        value = value + 1
        return "id-" .. value
      end
    end)()
    local receive_frame
    local pending_writes = {}
    local transmitted = {}
    local connection = { close_count = 0 }
    function connection:receive(on_frame)
      receive_frame = on_frame
    end
    function connection:send(value, done)
      if value.type == "hello" then
        done(nil)
        receive_frame({
          type = "welcome",
          protocol = { major = 2, minor = 4 },
          serverEpoch = "epoch",
          runResumed = false,
          limits = { maxFrameBytes = 8388608, maxSources = 2 },
          capabilities = {},
        })
        return
      end
      transmitted[#transmitted + 1] = vim.deepcopy(value)
      pending_writes[#pending_writes + 1] = done
    end
    function connection:close()
      self.close_count = self.close_count + 1
    end

    local transport = require("refine.transport").new({
      client = { id = "refine-neovim", version = "0.1.0", host = "neovim" },
      host_capabilities = { interceptableSuggestionActionKeys = {} },
      endpoint_locator = {
        locate = function(_, done)
          done(nil, {
            socketPath = "/private/tmp/refine/server.sock",
            launchToken = "secret",
            serverEpoch = "epoch",
          })
        end,
      },
      connector = {
        connect = function(_, _, done)
          done(nil, connection)
        end,
      },
      uuid = next_id,
    })
    local detached = 0
    local host = {
      observe = function(_, emit)
        emit({ type = "snapshot", snapshot = snapshot("doc:0", "zero") })
        return function()
          detached = detached + 1
        end
      end,
      validate_revision = function() end,
      apply = function() end,
      present = function(_, _, _, done)
        done(nil)
      end,
    }
    local states = {}
    local integration = require("refine.integration").new({
      engine_port = transport,
      uuid = next_id,
    })
    local handle = integration:run({
      host = host,
      on_state = function(state)
        states[#states + 1] = state
      end,
    })

    assert_equal(
      { "openDocument" },
      vim.tbl_map(function(envelope)
        return envelope.command.type
      end, transmitted)
    )

    handle.stop()
    handle.stop()

    assert_equal(0, connection.close_count)
    assert_equal(1, detached)
    assert_equal("stopped", states[#states].state)
    assert_equal(1, #vim.tbl_filter(function(state)
      return state.state == "stopped"
    end, states))

    pending_writes[1](nil)
    assert_equal(
      { "openDocument", "closeDocument" },
      vim.tbl_map(function(envelope)
        return envelope.command.type
      end, transmitted)
    )
    assert_equal(0, connection.close_count)

    pending_writes[2](nil)
    assert_equal(1, connection.close_count)
  end)

  it("finishes shutdown when closeDocument cannot be enqueued", function()
    local sent = {}
    local session = {
      server_epoch = "epoch",
      run_resumed = false,
      close_count = 0,
    }
    function session:events() end
    function session:send(command, id, done)
      sent[#sent + 1] = command.type
      if command.type == "closeDocument" then
        error("send queue rejected closeDocument")
      end
      done(nil, { sequence = #sent, id = id })
    end
    function session:close()
      self.close_count = self.close_count + 1
    end

    local detached = 0
    local host = {
      observe = function(_, emit)
        emit({ type = "snapshot", snapshot = snapshot("doc:0", "zero") })
        return function()
          detached = detached + 1
        end
      end,
      validate_revision = function() end,
      apply = function() end,
      present = function(_, _, _, done)
        done(nil)
      end,
    }
    local states = {}
    local integration = require("refine.integration").new({
      engine_port = {
        connect = function(_, _, done)
          done(nil, session)
        end,
      },
      uuid = function()
        return "id"
      end,
    })
    local handle = integration:run({
      host = host,
      on_state = function(state)
        states[#states + 1] = state
      end,
    })

    local stopped, stop_error = pcall(handle.stop)
    handle.stop()

    assert_equal(true, stopped)
    assert_equal(nil, stop_error)
    assert_equal({ "openDocument", "closeDocument" }, sent)
    assert_equal(1, session.close_count)
    assert_equal(1, detached)
    assert_equal("stopped", states[#states].state)
    assert_equal(1, #vim.tbl_filter(function(state)
      return state.state == "stopped"
    end, states))
  end)

  it("opens only the latest snapshot and never replaces before open is enqueued", function()
    local observe
    local finish_connect
    local sent = {}
    local finish_open
    local session = { server_epoch = "epoch", run_resumed = false }
    function session:events() end
    function session:send(command, id, done)
      sent[#sent + 1] = { command = vim.deepcopy(command), id = id }
      if command.type == "openDocument" then
        finish_open = function()
          done(nil, { sequence = 1, id = id })
        end
      else
        done(nil, { sequence = #sent, id = id })
      end
    end
    function session:close() end
    local host = {
      observe = function(_, emit)
        observe = emit
        emit({ type = "snapshot", snapshot = snapshot("doc:0", "zero") })
        return function() end
      end,
      validate_revision = function() end,
      apply = function() end,
      present = function() end,
    }
    local integration = require("refine.integration").new({
      engine_port = {
        connect = function(_, _, done)
          finish_connect = function()
            done(nil, session)
          end
        end,
      },
      uuid = function()
        return "id"
      end,
    })
    integration:run({ host = host })

    observe({ type = "snapshot", snapshot = snapshot("doc:1", "one") })
    finish_connect()
    assert_equal(1, #sent)
    assert_equal("openDocument", sent[1].command.type)
    assert_equal("doc:1", sent[1].command.snapshot.revision)

    observe({ type = "snapshot", snapshot = snapshot("doc:2", "two") })
    assert_equal(1, #sent)
    finish_open()
    assert_equal(2, #sent)
    assert_equal("replaceDocument", sent[2].command.type)
    assert_equal("doc:2", sent[2].command.snapshot.revision)
  end)

  it("requires the first observation in every cycle to be a snapshot", function()
    local failures = {}
    local host = {
      observe = function(_, emit)
        emit({ type = "checkRequested", revision = "doc:0" })
        return function() end
      end,
      validate_revision = function() end,
      apply = function() end,
      present = function() end,
    }
    local integration = require("refine.integration").new({
      engine_port = {
        connect = function()
          error("must not connect")
        end,
      },
      uuid = function()
        return "id"
      end,
    })
    local handle = integration:run({
      host = host,
      on_error = function(err)
        failures[#failures + 1] = err
      end,
    })
    assert_equal("FatalHostError", failures[1].kind)
    assert_equal(false, handle.is_running())
  end)

  it("classifies a synchronous engine connection failure as fatal engine state", function()
    local failures = {}
    local states = {}
    local host = {
      observe = function(_, emit)
        emit({ type = "snapshot", snapshot = snapshot("doc:0", "zero") })
        return function() end
      end,
      validate_revision = function() end,
      apply = function() end,
      present = function() end,
    }
    local integration = require("refine.integration").new({
      engine_port = {
        connect = function()
          error("adapter exploded")
        end,
      },
      uuid = function()
        return "id"
      end,
    })
    local handle = integration:run({
      host = host,
      on_error = function(err)
        failures[#failures + 1] = err
      end,
      on_state = function(state)
        states[#states + 1] = state
      end,
    })

    assert_equal("FatalEngineError", failures[1].kind)
    assert_equal("stopped", states[#states].state)
    assert_equal("FatalEngineError", states[#states].error.kind)
    assert_equal(false, handle.is_running())
  end)
end)
