local APPEARANCE = {
  highlight = { style = "underline", grammarColor = "#FF2D55", fluencyColor = "#007AFF" },
  diff = { additionColor = "#34C759", deletionColor = "#FF3B30", showHiddenWhitespace = true },
}
local INTERACTION = {
  automaticChecksEnabled = true,
  quickApply = { enabled = true, applyKey = "tab", dismissKey = "escape", activationStyle = "showTipAndHighlight" },
}

local function snapshot(revision, text)
  return {
    revision = revision,
    sources = { { sourceId = "document", text = text, sourceSyntax = "plainText" } },
  }
end

local function presentation()
  return {
    documentRevision = "doc:0",
    status = "complete",
    coverage = "full",
    appearance = APPEARANCE,
    interaction = INTERACTION,
    suggestions = {
      {
        id = "suggestion",
        sourceId = "document",
        kind = "grammar",
        attribution = { languageDisplayName = "English", textDirection = "ltr", checkModelDisplayName = "Model" },
        activationRange = { location = 0, length = 14 },
        highlightRanges = { { location = 7, length = 2 } },
        diff = { { kind = "delete", text = "an" }, { kind = "insert", text = "a" } },
        availableActions = { "apply", "dismiss" },
      },
    },
  }
end

describe("integration reconnect and Apply receipts", function()
  it("restores a proven Apply receipt before reopening a retained run", function()
    local sessions = {}
    local connect_options = {}
    local reconnect
    local observe
    local presentations = {}
    local apply_count = 0

    local function make_session(resumed)
      local session = {
        server_epoch = "epoch",
        run_resumed = resumed,
        commands = {},
      }
      function session:events(on_event, on_end)
        self.on_event = on_event
        self.on_end = on_end
      end
      function session:send(command, id, done)
        self.commands[#self.commands + 1] = { command = vim.deepcopy(command), id = id }
        if not resumed and command.type == "completeApply" then
          done({ kind = "EngineConnectionError", message = "lost", recoverability = "recoverable" })
        else
          done(nil, { sequence = #self.commands, id = id })
        end
      end
      function session:close()
        self.closed = true
      end
      sessions[#sessions + 1] = session
      return session
    end

    local first = make_session(false)
    local second = make_session(true)
    local next_session = 1
    local engine = {}
    function engine:connect(options, done)
      connect_options[#connect_options + 1] = vim.deepcopy(options)
      local value = next_session == 1 and first or second
      next_session = next_session + 1
      done(nil, value)
    end
    local host = {}
    function host:observe(emit)
      observe = emit
      emit({ type = "snapshot", snapshot = snapshot("doc:0", "create an link.") })
      return function() end
    end
    function host:validate_revision(_, done)
      done(nil, { status = "current" })
    end
    function host:apply(_, done)
      apply_count = apply_count + 1
      local changed = snapshot("doc:1", "create a link.")
      observe({ type = "snapshot", snapshot = changed })
      done(nil, { status = "applied", snapshot = changed })
    end
    function host:present(value, actions, done)
      presentations[#presentations + 1] = { snapshot = value, actions = actions }
      done(nil)
    end

    local integration = require("refine.integration").new({
      engine_port = engine,
      uuid = (function()
        local value = 0
        return function()
          value = value + 1
          return "id-" .. value
        end
      end)(),
      delay = function(_, callback)
        reconnect = callback
        return function()
          reconnect = nil
        end
      end,
    })
    integration:run({ host = host })
    first.on_event({
      type = "event",
      sequence = 1,
      epoch = "epoch",
      event = { type = "presentationContentReplaced", checkId = "check", content = presentation() },
    })
    local outcomes = {}
    presentations[#presentations].actions.apply("suggestion", function(outcome)
      outcomes[#outcomes + 1] = outcome
    end)
    local action = first.commands[2].command
    first.on_event({
      type = "event",
      sequence = 2,
      epoch = "epoch",
      causeCommandId = first.commands[2].id,
      event = {
        type = "applyRequested",
        actionId = action.actionId,
        transactionId = "transaction",
        request = {
          expectedRevision = "doc:0",
          sourceId = "document",
          edits = { { range = { location = 7, length = 2 }, expectedText = "an", replacement = "a" } },
        },
      },
    })

    assert_equal(1, apply_count)
    assert_truthy(reconnect)
    assert_equal("unavailable", presentations[#presentations].snapshot.state.type)
    observe({
      type = "attentionChanged",
      revision = "doc:1",
      attention = {
        sourceId = "document",
        caretOffset = 13,
        visibleRanges = { { location = 0, length = 14 } },
      },
    })
    observe({ type = "checkRequested", revision = "doc:1" })
    reconnect()
    assert_equal(connect_options[1].run_id, connect_options[2].run_id)
    assert_equal(
      { "completeApply", "openDocument", "updateAttention", "requestCheck" },
      vim.tbl_map(function(item)
        return item.command.type
      end, second.commands)
    )
    assert_equal("doc:1", second.commands[2].command.snapshot.revision)
    assert_equal(13, second.commands[3].command.attention.caretOffset)

    second.on_event({
      type = "event",
      sequence = 1,
      epoch = "epoch",
      event = { type = "actionCompleted", actionId = action.actionId },
    })
    assert_equal({ { status = "completed" } }, outcomes)
    assert_equal(1, apply_count)
  end)

  it("allocates a new run and discards a proven Apply receipt when required", function()
    local reconnect
    local observe
    local presentations = {}
    local apply_count = 0
    local connect_options = {}

    local function make_session(fail_receipt)
      local session = {
        server_epoch = "epoch",
        run_resumed = false,
        commands = {},
      }
      function session:events(on_event, on_end)
        self.on_event = on_event
        self.on_end = on_end
      end
      function session:send(command, id, done)
        self.commands[#self.commands + 1] = { command = vim.deepcopy(command), id = id }
        if fail_receipt and command.type == "completeApply" then
          done({ kind = "EngineConnectionError", message = "lost", recoverability = "recoverable" })
        else
          done(nil, { sequence = #self.commands, id = id })
        end
      end
      function session:close()
        self.closed = true
      end
      return session
    end

    local first = make_session(true)
    local second = make_session(false)
    local connect_count = 0
    local engine = {}
    function engine:connect(options, done)
      connect_options[#connect_options + 1] = vim.deepcopy(options)
      connect_count = connect_count + 1
      if connect_count == 1 then
        done(nil, first)
      elseif connect_count == 2 then
        done({
          kind = "HandshakeRejectedError",
          message = "new run required",
          recoverability = "recoverable",
          reason = "runUnavailable",
          recovery = "newRun",
          protocol = { major = 1, minor = 0 },
        })
      else
        done(nil, second)
      end
    end
    local host = {}
    function host:observe(emit)
      observe = emit
      emit({ type = "snapshot", snapshot = snapshot("doc:0", "create an link.") })
      return function() end
    end
    function host:validate_revision(_, done)
      done(nil, { status = "current" })
    end
    function host:apply(_, done)
      apply_count = apply_count + 1
      local changed = snapshot("doc:1", "create a link.")
      observe({ type = "snapshot", snapshot = changed })
      done(nil, { status = "applied", snapshot = changed })
    end
    function host:present(value, actions, done)
      presentations[#presentations + 1] = { snapshot = value, actions = actions }
      done(nil)
    end

    local integration = require("refine.integration").new({
      engine_port = engine,
      uuid = (function()
        local value = 0
        return function()
          value = value + 1
          return "id-" .. value
        end
      end)(),
      delay = function(_, callback)
        reconnect = callback
        return function()
          reconnect = nil
        end
      end,
    })
    integration:run({ host = host })
    first.on_event({
      type = "event",
      sequence = 1,
      epoch = "epoch",
      event = { type = "presentationContentReplaced", checkId = "check", content = presentation() },
    })
    local outcomes = {}
    presentations[#presentations].actions.apply("suggestion", function(outcome)
      outcomes[#outcomes + 1] = outcome
    end)
    local action = first.commands[2].command
    first.on_event({
      type = "event",
      sequence = 2,
      epoch = "epoch",
      causeCommandId = first.commands[2].id,
      event = {
        type = "applyRequested",
        actionId = action.actionId,
        transactionId = "transaction",
        request = {
          expectedRevision = "doc:0",
          sourceId = "document",
          edits = { { range = { location = 7, length = 2 }, expectedText = "an", replacement = "a" } },
        },
      },
    })

    assert_equal(1, apply_count)
    assert_truthy(reconnect)
    observe({
      type = "attentionChanged",
      revision = "doc:1",
      attention = {
        sourceId = "document",
        caretOffset = 13,
        visibleRanges = { { location = 0, length = 14 } },
      },
    })
    observe({ type = "checkRequested", revision = "doc:1" })
    reconnect()
    assert_truthy(reconnect)
    reconnect()

    assert_equal(
      { "openDocument", "updateAttention", "requestCheck" },
      vim.tbl_map(function(item)
        return item.command.type
      end, second.commands)
    )
    assert_equal(connect_options[1].run_id, connect_options[2].run_id)
    assert_equal(false, connect_options[2].run_id == connect_options[3].run_id)
    assert_equal("doc:1", second.commands[1].command.snapshot.revision)
    assert_equal({ { status = "unavailable", reason = "disconnected" } }, outcomes)
    assert_equal(1, apply_count)
  end)

  it("replays a pending manual check after a recoverable disconnect", function()
    local sessions = {}
    local reconnect
    local emit_observation

    local function make_session(resumed)
      local session = {
        server_epoch = "epoch",
        run_resumed = resumed,
        commands = {},
      }
      function session:events(on_event, on_end)
        self.on_event = on_event
        self.on_end = on_end
      end
      function session:send(command, id, done)
        self.commands[#self.commands + 1] = { command = vim.deepcopy(command), id = id }
        done(nil, { sequence = #self.commands, id = id })
      end
      function session:close()
        self.closed = true
      end
      sessions[#sessions + 1] = session
      return session
    end

    local first = make_session(false)
    local second = make_session(true)
    local connect_count = 0
    local engine = {}
    function engine:connect(_, done)
      connect_count = connect_count + 1
      done(nil, connect_count == 1 and first or second)
    end
    local host = {}
    function host:observe(emit)
      emit_observation = emit
      emit({ type = "snapshot", snapshot = snapshot("doc:0", "check this") })
      return function() end
    end
    function host:validate_revision(_, done)
      done(nil, { status = "current" })
    end
    function host:apply() end
    function host:present(_, _, done)
      done(nil)
    end

    local integration = require("refine.integration").new({
      engine_port = engine,
      uuid = (function()
        local value = 0
        return function()
          value = value + 1
          return "id-" .. value
        end
      end)(),
      delay = function(_, callback)
        reconnect = callback
        return function()
          reconnect = nil
        end
      end,
    })
    integration:run({ host = host })
    emit_observation({ type = "checkRequested", revision = "doc:0" })
    assert_equal(
      { "openDocument", "requestCheck" },
      vim.tbl_map(function(item)
        return item.command.type
      end, first.commands)
    )

    first.on_end({ kind = "EngineConnectionError", message = "lost", recoverability = "recoverable" })
    assert_truthy(reconnect)
    reconnect()

    assert_equal(
      { "openDocument", "requestCheck" },
      vim.tbl_map(function(item)
        return item.command.type
      end, second.commands)
    )
  end)

  it("retries each retry rejection with the same run ID", function()
    for _, reason in ipairs({ "runUnavailable", "serverBusy", "engineUnavailable" }) do
      local connect_options = {}
      local reconnect
      local connect_count = 0
      local session = { server_epoch = "epoch", run_resumed = false, commands = {} }
      function session:events() end
      function session:send(command, id, done)
        self.commands[#self.commands + 1] = { command = vim.deepcopy(command), id = id }
        done(nil, { sequence = #self.commands, id = id })
      end
      function session:close() end
      local engine = {}
      function engine:connect(options, done)
        connect_options[#connect_options + 1] = vim.deepcopy(options)
        connect_count = connect_count + 1
        if connect_count == 1 then
          done({
            kind = "HandshakeRejectedError",
            message = "retry",
            recoverability = "recoverable",
            reason = reason,
            recovery = "retry",
            protocol = { major = 1, minor = 0 },
          })
        else
          done(nil, session)
        end
      end
      local host = {}
      function host:observe(emit)
        emit({ type = "snapshot", snapshot = snapshot("doc:0", "retry me") })
        return function() end
      end
      function host:validate_revision(_, done)
        done(nil, { status = "current" })
      end
      function host:apply() end
      function host:present(_, _, done)
        done(nil)
      end
      local integration = require("refine.integration").new({
        engine_port = engine,
        uuid = (function()
          local value = 0
          return function()
            value = value + 1
            return "id-" .. value
          end
        end)(),
        delay = function(_, callback)
          reconnect = callback
          return function()
            reconnect = nil
          end
        end,
      })

      integration:run({ host = host })
      assert_truthy(reconnect)
      reconnect()

      assert_equal(connect_options[1].run_id, connect_options[2].run_id)
      assert_equal(
        { "openDocument" },
        vim.tbl_map(function(item)
          return item.command.type
        end, session.commands)
      )
    end
  end)

  it("stops for every none rejection without scheduling a retry", function()
    for _, case in ipairs({
      {
        kind = "IncompatibleProtocolError",
        reason = "incompatibleProtocol",
        received_protocol = { major = 2, minor = 5 },
        supported_protocol = { major = 1, minor = 0 },
      },
      { kind = "HandshakeRejectedError", reason = "invalidClient" },
    }) do
      local reconnect
      local reported = {}
      local engine = {}
      function engine:connect(_, done)
        done(vim.tbl_extend("force", {
          message = "fatal rejection",
          recoverability = "fatal",
          recovery = "none",
          protocol = { major = 1, minor = 0 },
        }, case))
      end
      local host = {}
      function host:observe(emit)
        emit({ type = "snapshot", snapshot = snapshot("doc:0", "stop here") })
        return function() end
      end
      function host:validate_revision(_, done)
        done(nil, { status = "current" })
      end
      function host:apply() end
      function host:present(_, _, done)
        done(nil)
      end
      local integration = require("refine.integration").new({
        engine_port = engine,
        uuid = function()
          return "run-id"
        end,
        delay = function(_, callback)
          reconnect = callback
          return function()
            reconnect = nil
          end
        end,
      })

      local handle = integration:run({
        host = host,
        on_error = function(err)
          reported[#reported + 1] = err
        end,
      })

      assert_equal(false, handle.is_running())
      assert_equal(nil, reconnect)
      assert_equal(1, #reported)
      assert_equal(case.reason, reported[1].reason)
      assert_equal("none", reported[1].recovery)
      assert_equal({ major = 1, minor = 0 }, reported[1].protocol)
      if case.received_protocol then
        assert_equal(case.received_protocol, reported[1].received_protocol)
        assert_equal(case.supported_protocol, reported[1].supported_protocol)
      end
    end
  end)
end)
