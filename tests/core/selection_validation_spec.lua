local function has_command(commands, kind)
  for _, sent in ipairs(commands) do
    if sent.command.type == kind then
      return true
    end
  end
  return false
end

describe("selection and presentation range validation", function()
  it("rejects a selection that splits a composed character before transport", function()
    local commands = {}
    local observe
    local host = {
      observe = function(_, emit)
        observe = emit
        emit({
          type = "snapshot",
          snapshot = {
            revision = "doc:0",
            sources = { { sourceId = "document", text = "A 👩‍💻 works.", sourceSyntax = "mixed" } },
          },
        })
        return function() end
      end,
      validate_revision = function() end,
      apply = function() end,
      present = function(_, _, _, done)
        done(nil)
      end,
    }
    local session = { server_epoch = "epoch", run_resumed = false }
    function session:events() end
    function session:send(command, id, done)
      commands[#commands + 1] = { command = command, id = id }
      done(nil, { sequence = #commands, id = id })
    end
    function session:close() end
    local engine = {
      connect = function(_, _, done)
        done(nil, session)
      end,
    }
    local failures = {}
    local integration = require("refine.integration").new({
      engine_port = engine,
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

    observe({
      type = "checkRequested",
      revision = "doc:0",
      intent = { selection = { sourceId = "document", range = { location = 2, length = 1 } } },
    })
    assert_equal("FatalHostError", failures[1].kind)
    assert_equal(false, handle.is_running())
    assert_equal(false, has_command(commands, "requestCheck"))
  end)

  it("ends the run when Refine publishes an out-of-bounds suggestion", function()
    local event_listener
    local host = {
      observe = function(_, emit)
        emit({
          type = "snapshot",
          snapshot = {
            revision = "doc:0",
            sources = { { sourceId = "document", text = "Short text.", sourceSyntax = "mixed" } },
          },
        })
        return function() end
      end,
      validate_revision = function() end,
      apply = function() end,
      present = function(_, _, _, done)
        done(nil)
      end,
    }
    local session = { server_epoch = "epoch", run_resumed = false }
    function session:events(on_event)
      event_listener = on_event
    end
    function session:send(_, id, done)
      done(nil, { sequence = 1, id = id })
    end
    function session:close() end
    local failures = {}
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
      on_error = function(err)
        failures[#failures + 1] = err
      end,
    })
    event_listener({
      type = "event",
      sequence = 1,
      epoch = "epoch",
      event = {
        type = "presentationContentReplaced",
        checkId = "check",
        content = {
          documentRevision = "doc:0",
          status = "complete",
          coverage = "full",
          appearance = {
            highlight = { style = "underline", grammarColor = "#FF2D55", fluencyColor = "#007AFF" },
            diff = { additionColor = "#34C759", deletionColor = "#FF3B30", showHiddenWhitespace = true },
          },
          interaction = {
            automaticChecksEnabled = true,
            quickApply = {
              enabled = true,
              applyKey = "tab",
              dismissKey = "escape",
              activationStyle = "showTipAndHighlight",
            },
          },
          suggestions = {
            {
              id = "bad",
              sourceId = "document",
              kind = "grammar",
              attribution = { languageDisplayName = "English", textDirection = "ltr", checkModelDisplayName = "Model" },
              activationRange = { location = 100, length = 1 },
              highlightRanges = { { location = 0, length = 1 } },
              diff = {},
              availableActions = { "apply" },
            },
          },
        },
      },
    })
    assert_equal("FatalEngineError", failures[1].kind)
    assert_equal(false, handle.is_running())
  end)
end)
