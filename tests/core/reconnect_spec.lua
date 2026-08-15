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
    sources = { { sourceId = "document", text = text, sourceSyntax = "mixed" } },
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
    reconnect()
    assert_equal(connect_options[1].run_id, connect_options[2].run_id)
    assert_equal("completeApply", second.commands[1].command.type)
    assert_equal("openDocument", second.commands[2].command.type)
    assert_equal("doc:1", second.commands[2].command.snapshot.revision)

    second.on_event({
      type = "event",
      sequence = 1,
      epoch = "epoch",
      event = { type = "actionCompleted", actionId = action.actionId },
    })
    assert_equal({ { status = "completed" } }, outcomes)
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
end)
