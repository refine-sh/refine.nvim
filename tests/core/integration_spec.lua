local APPEARANCE = {
  highlight = { style = "underline", grammarColor = "#FF2D55", fluencyColor = "#007AFF" },
  diff = { additionColor = "#34C759", deletionColor = "#FF3B30", showHiddenWhitespace = true },
}

local INTERACTION = {
  automaticChecksEnabled = true,
  quickApply = { enabled = true, applyKey = "tab", dismissKey = "escape", activationStyle = "showTipAndHighlight" },
}

local function source(revision, text)
  return {
    revision = revision,
    sources = { { sourceId = "document", text = text or "create an link.", sourceSyntax = "mixed" } },
  }
end

local function runtime_fixture()
  local commands = {}
  local event_listener
  local event_end
  local observation_listener
  local observation_end
  local presentations = {}
  local states = {}
  local scheduled_reconnect
  local validation_result = { status = "current" }
  local apply_handler
  local id = 0
  local session = {
    server_epoch = "epoch-1",
    run_resumed = false,
  }
  function session:send(command, command_id, callback)
    commands[#commands + 1] = { command = vim.deepcopy(command), id = command_id }
    callback(nil, { sequence = #commands, id = command_id })
  end
  function session:events(on_event, on_end)
    event_listener = on_event
    event_end = on_end
  end
  function session:close()
    self.closed = true
  end
  local engine = {}
  function engine:connect(_, callback)
    callback(nil, session)
  end
  local host = {}
  function host:observe(emit, finish)
    observation_listener = emit
    observation_end = finish
    emit({ type = "snapshot", snapshot = source("doc:0") })
    return function()
      self.detached = true
    end
  end
  function host:validate_revision(_, callback)
    callback(nil, vim.deepcopy(validation_result))
  end
  function host:apply(request, callback)
    if apply_handler then
      apply_handler(request, callback)
    else
      callback(nil, { status = "unavailable" })
    end
  end
  function host:present(snapshot, actions, callback)
    presentations[#presentations + 1] = { snapshot = vim.deepcopy(snapshot), actions = actions }
    callback(nil)
  end

  local integration = require("refine.integration").new({
    engine_port = engine,
    uuid = function()
      id = id + 1
      return "id-" .. id
    end,
    reconnect_delay_ms = 0,
    delay = function(_, callback)
      scheduled_reconnect = callback
      return function()
        scheduled_reconnect = nil
      end
    end,
  })
  local errors = {}
  local handle = integration:run({
    host = host,
    on_error = function(err)
      errors[#errors + 1] = err
    end,
    on_state = function(state)
      states[#states + 1] = state
    end,
  })
  return {
    commands = commands,
    session = session,
    presentations = presentations,
    host = host,
    handle = handle,
    errors = errors,
    states = states,
    reconnect = function()
      local callback = scheduled_reconnect
      scheduled_reconnect = nil
      callback()
    end,
    set_validation = function(value)
      validation_result = value
    end,
    set_apply = function(value)
      apply_handler = value
    end,
    observe = function(value)
      observation_listener(value)
    end,
    end_observations = function(err)
      observation_end(err)
    end,
    event = function(sequence, event, cause)
      event_listener({
        type = "event",
        sequence = sequence,
        epoch = "epoch-1",
        causeCommandId = cause,
        event = event,
      })
    end,
    disconnect = function(err)
      event_end(err)
    end,
  }
end

local function suggestion_content(suggestions)
  return {
    documentRevision = "doc:0",
    status = "complete",
    coverage = "full",
    appearance = APPEARANCE,
    interaction = INTERACTION,
    suggestions = suggestions or {
      {
        id = "suggestion-1",
        sourceId = "document",
        kind = "grammar",
        attribution = {
          languageDisplayName = "English (American)",
          textDirection = "ltr",
          checkModelDisplayName = "On-Device (Gemma)",
        },
        activationRange = { location = 0, length = 14 },
        highlightRanges = { { location = 7, length = 2 } },
        diff = { { kind = "delete", text = "an" }, { kind = "insert", text = "a" } },
        availableActions = { "apply", "dismiss", "explain", "report" },
      },
    },
  }
end

local function checking_content(completed)
  return {
    documentRevision = "doc:0",
    status = "checking",
    progress = { completedUnitCount = completed, totalUnitCount = 3 },
    appearance = APPEARANCE,
    interaction = INTERACTION,
    suggestions = {},
  }
end

local function unavailable_content(reason)
  return {
    documentRevision = "doc:0",
    status = "unavailable",
    unavailableReason = reason,
    appearance = APPEARANCE,
    interaction = INTERACTION,
    suggestions = {},
  }
end

describe("host-neutral Refine integration runtime", function()
  it("orders a full snapshot, selection intent, and whole presentation at the host seam", function()
    local fixture = runtime_fixture()
    assert_equal(
      { "connecting", "connected" },
      vim.tbl_map(function(state)
        return state.state
      end, fixture.states)
    )
    assert_equal("pending", fixture.presentations[1].snapshot.state.type)
    assert_equal("openDocument", fixture.commands[1].command.type)
    assert_equal(source("doc:0"), fixture.commands[1].command.snapshot)

    fixture.observe({
      type = "checkRequested",
      revision = "doc:0",
      intent = { selection = { sourceId = "document", range = { location = 7, length = 2 } } },
    })
    assert_equal({
      type = "requestCheck",
      revision = "doc:0",
      intent = { selection = { sourceId = "document", range = { location = 7, length = 2 } } },
    }, fixture.commands[2].command)

    fixture.event(1, {
      type = "presentationContentReplaced",
      checkId = "check-1",
      content = {
        documentRevision = "doc:0",
        status = "complete",
        coverage = "full",
        appearance = APPEARANCE,
        interaction = INTERACTION,
        suggestions = {},
      },
    }, fixture.commands[2].id)
    local presented = fixture.presentations[#fixture.presentations].snapshot
    local actions = fixture.presentations[#fixture.presentations].actions
    assert_equal("complete", presented.state.type)
    assert_equal("full", presented.state.coverage)
    assert_equal(1, presented.checkGeneration)
    assert_equal(2, presented.presentationRevision)
    assert_equal(nil, actions._presentation_revision)
    assert_equal({}, fixture.errors)
  end)

  it("ignores engine work for a superseded same-revision manual check", function()
    local fixture = runtime_fixture()
    fixture.observe({ type = "checkRequested", revision = "doc:0" })
    local superseded_command = fixture.commands[#fixture.commands]
    fixture.observe({
      type = "checkRequested",
      revision = "doc:0",
      intent = { selection = { sourceId = "document", range = { location = 7, length = 2 } } },
    })
    local current_command = fixture.commands[#fixture.commands]
    assert_equal("requestCheck", superseded_command.command.type)
    assert_equal("requestCheck", current_command.command.type)
    assert_equal(1, #fixture.presentations)

    fixture.event(1, {
      type = "presentationContentReplaced",
      checkId = "superseded-check",
      content = suggestion_content(),
    }, superseded_command.id)
    assert_equal(1, #fixture.presentations)

    fixture.event(2, {
      type = "presentationContentReplaced",
      checkId = "current-check",
      content = suggestion_content(),
    }, current_command.id)
    assert_equal(2, #fixture.presentations)
    assert_equal("complete", fixture.presentations[2].snapshot.state.type)
    assert_equal(1, fixture.presentations[2].snapshot.checkGeneration)
  end)

  it("reports recoverable disconnect and terminal stop without source content", function()
    local fixture = runtime_fixture()
    fixture.disconnect({
      kind = "EngineConnectionError",
      message = "socket closed",
      recoverability = "recoverable",
    })
    assert_equal("disconnected", fixture.states[#fixture.states].state)
    assert_equal("unavailable", fixture.presentations[#fixture.presentations].snapshot.state.type)
    fixture.handle.stop()
    assert_equal("stopped", fixture.states[#fixture.states].state)
    assert_equal(nil, fixture.states[#fixture.states].error)
  end)

  it("coalesces duplicate Apply calls around exactly one host mutation", function()
    local fixture = runtime_fixture()
    fixture.event(1, {
      type = "presentationContentReplaced",
      checkId = "check-1",
      content = suggestion_content(),
    }, fixture.commands[1].id)
    local actions = fixture.presentations[#fixture.presentations].actions
    local outcomes = {}
    actions.apply("suggestion-1", function(outcome)
      outcomes[#outcomes + 1] = outcome
    end)
    actions.apply("suggestion-1", function(outcome)
      outcomes[#outcomes + 1] = outcome
    end)

    assert_equal("performAction", fixture.commands[2].command.type)
    assert_equal("apply", fixture.commands[2].command.kind)
    assert_equal(2, #fixture.commands)
    assert_equal(
      false,
      vim.tbl_contains(fixture.presentations[#fixture.presentations].snapshot.suggestions[1].availableActions, "apply")
    )

    local mutation_count = 0
    fixture.set_apply(function(request, callback)
      mutation_count = mutation_count + 1
      assert_equal("doc:0", request.expectedRevision)
      local updated = source("doc:1", "create a link.")
      fixture.observe({ type = "snapshot", snapshot = updated })
      callback(nil, { status = "applied", snapshot = updated })
    end)
    local action_id = fixture.commands[2].command.actionId
    fixture.event(2, {
      type = "applyRequested",
      actionId = action_id,
      transactionId = "transaction-1",
      request = {
        expectedRevision = "doc:0",
        sourceId = "document",
        edits = {
          { range = { location = 7, length = 2 }, expectedText = "an", replacement = "a" },
        },
      },
    }, fixture.commands[2].id)

    assert_equal(1, mutation_count)
    assert_equal("completeApply", fixture.commands[3].command.type)
    assert_equal("applied", fixture.commands[3].command.outcome.status)
    assert_equal(3, #fixture.commands)

    fixture.event(3, { type = "actionCompleted", actionId = action_id }, fixture.commands[2].id)
    assert_equal({ { status = "completed" }, { status = "completed" } }, outcomes)
    assert_equal({}, fixture.errors)
  end)

  it("validates and explicitly dismisses a live suggestion", function()
    local fixture = runtime_fixture()
    fixture.event(1, {
      type = "presentationContentReplaced",
      checkId = "check-1",
      content = suggestion_content(),
    }, fixture.commands[1].id)
    local actions = fixture.presentations[#fixture.presentations].actions
    local outcome
    actions.dismiss("suggestion-1", function(value)
      outcome = value
    end)

    assert_equal("dismiss", fixture.commands[2].command.kind)
    assert_equal(
      false,
      vim.tbl_contains(
        fixture.presentations[#fixture.presentations].snapshot.suggestions[1].availableActions,
        "dismiss"
      )
    )
    fixture.event(2, {
      type = "actionCompleted",
      actionId = fixture.commands[2].command.actionId,
    }, fixture.commands[2].id)
    assert_equal({ status = "completed" }, outcome)
    assert_equal({}, fixture.presentations[#fixture.presentations].snapshot.suggestions)
  end)

  it("routes reporting without removing the reported suggestion", function()
    local fixture = runtime_fixture()
    fixture.event(1, {
      type = "presentationContentReplaced",
      checkId = "check-1",
      content = suggestion_content(),
    }, fixture.commands[1].id)
    local actions = fixture.presentations[#fixture.presentations].actions
    local outcome
    actions.report("suggestion-1", function(value)
      outcome = value
    end)
    fixture.event(2, {
      type = "actionCompleted",
      actionId = fixture.commands[2].command.actionId,
    }, fixture.commands[2].id)

    assert_equal({ status = "completed" }, outcome)
    assert_equal("suggestion-1", fixture.presentations[#fixture.presentations].snapshot.suggestions[1].id)
  end)

  it("streams cumulative explanation replacements to one terminal update", function()
    local fixture = runtime_fixture()
    fixture.event(1, {
      type = "presentationContentReplaced",
      checkId = "check-1",
      content = suggestion_content(),
    }, fixture.commands[1].id)
    local actions = fixture.presentations[#fixture.presentations].actions
    local updates = {}
    local endings = 0
    actions.explain("suggestion-1", function(update)
      updates[#updates + 1] = update
    end, function()
      endings = endings + 1
    end)
    local action_id = fixture.commands[2].command.actionId
    fixture.event(2, {
      type = "explanationReplaced",
      actionId = action_id,
      update = {
        status = "started",
        attribution = { languageDisplayName = "English", textDirection = "ltr", modelDisplayName = "GPT" },
      },
    }, fixture.commands[2].id)
    fixture.event(3, {
      type = "explanationReplaced",
      actionId = action_id,
      update = { status = "streaming", text = "Use the indefinite" },
    }, fixture.commands[2].id)
    fixture.event(4, {
      type = "explanationReplaced",
      actionId = action_id,
      update = { status = "completed", text = "Use the indefinite article ‘a’." },
    }, fixture.commands[2].id)

    assert_equal(
      { "started", "streaming", "completed" },
      vim.tbl_map(function(update)
        return update.status
      end, updates)
    )
    assert_equal(1, endings)
  end)

  it("turns a stale validation into a new authoritative snapshot without sending an action", function()
    local fixture = runtime_fixture()
    fixture.event(1, {
      type = "presentationContentReplaced",
      checkId = "check-1",
      content = suggestion_content(),
    }, fixture.commands[1].id)
    fixture.set_validation({ status = "stale", snapshot = source("doc:1", "create a link.") })
    local outcome
    fixture.presentations[#fixture.presentations].actions.dismiss("suggestion-1", function(value)
      outcome = value
    end)

    assert_equal({ status = "stale" }, outcome)
    assert_equal("replaceDocument", fixture.commands[2].command.type)
    assert_equal("doc:1", fixture.commands[2].command.snapshot.revision)
    assert_equal("pending", fixture.presentations[#fixture.presentations].snapshot.state.type)
  end)

  it("restores a disabled action after a proven engine rejection", function()
    local fixture = runtime_fixture()
    fixture.event(1, {
      type = "presentationContentReplaced",
      checkId = "check-1",
      content = suggestion_content(),
    }, fixture.commands[1].id)
    local outcome
    fixture.presentations[#fixture.presentations].actions.apply("suggestion-1", function(value)
      outcome = value
    end)
    fixture.event(2, {
      type = "actionRejected",
      actionId = fixture.commands[2].command.actionId,
      reason = "readOnly",
    }, fixture.commands[2].id)

    assert_equal({ status = "unavailable", reason = "readOnly" }, outcome)
    assert_equal(
      true,
      vim.tbl_contains(fixture.presentations[#fixture.presentations].snapshot.suggestions[1].availableActions, "apply")
    )
  end)

  it("keeps generation stable for progressive replacements and advances on a same-revision recheck", function()
    local fixture = runtime_fixture()
    fixture.event(1, {
      type = "presentationContentReplaced",
      checkId = "check-1",
      content = checking_content(1),
    }, fixture.commands[1].id)
    assert_equal(1, fixture.presentations[#fixture.presentations].snapshot.checkGeneration)
    fixture.event(2, {
      type = "presentationContentReplaced",
      checkId = "check-1",
      content = checking_content(2),
    }, fixture.commands[1].id)
    assert_equal(1, fixture.presentations[#fixture.presentations].snapshot.checkGeneration)

    fixture.observe({ type = "checkRequested", revision = "doc:0" })
    fixture.event(3, {
      type = "presentationContentReplaced",
      checkId = "check-2",
      content = checking_content(0),
    }, fixture.commands[2].id)
    assert_equal(2, fixture.presentations[#fixture.presentations].snapshot.checkGeneration)

    local count = #fixture.presentations
    fixture.event(4, {
      type = "presentationContentReplaced",
      checkId = "check-1",
      content = suggestion_content({}),
    }, fixture.commands[1].id)
    assert_equal(count, #fixture.presentations)
  end)

  it("clears live and undispatched actions when writing-check entitlement is lost", function()
    local fixture = runtime_fixture()
    fixture.event(1, {
      type = "presentationContentReplaced",
      checkId = "check-1",
      content = suggestion_content(),
    }, fixture.commands[1].id)
    local old_actions = fixture.presentations[#fixture.presentations].actions
    local outcome
    old_actions.apply("suggestion-1", function(value)
      outcome = value
    end)
    fixture.event(2, {
      type = "presentationContentReplaced",
      checkId = "check-1",
      content = unavailable_content("writingCheckEntitlementRequired"),
    }, fixture.commands[1].id)

    assert_equal({ status = "stale" }, outcome)
    local latest = fixture.presentations[#fixture.presentations].snapshot
    assert_equal({ type = "unavailable", reason = "writingCheckEntitlementRequired" }, latest.state)
    assert_equal({}, latest.suggestions)
    local later
    old_actions.apply("suggestion-1", function(value)
      later = value
    end)
    assert_equal({ status = "stale" }, later)
  end)

  it("finishes undispatched actions when the engine becomes unavailable", function()
    local fixture = runtime_fixture()
    fixture.event(1, {
      type = "presentationContentReplaced",
      checkId = "check-1",
      content = suggestion_content(),
    }, fixture.commands[1].id)
    local outcome
    fixture.presentations[#fixture.presentations].actions.report("suggestion-1", function(value)
      outcome = value
    end)

    fixture.event(2, { type = "fault", code = "engineUnavailable", fatal = false })

    assert_equal({ status = "unavailable", reason = "engineUnavailable" }, outcome)
    assert_equal(
      { type = "unavailable", reason = "engineUnavailable" },
      fixture.presentations[#fixture.presentations].snapshot.state
    )
  end)

  it("finishes proof for a host mutation dispatched before entitlement loss", function()
    local fixture = runtime_fixture()
    local finish_apply
    fixture.set_apply(function(_, done)
      finish_apply = done
    end)
    fixture.event(1, {
      type = "presentationContentReplaced",
      checkId = "check-1",
      content = suggestion_content(),
    }, fixture.commands[1].id)
    local outcome
    fixture.presentations[#fixture.presentations].actions.apply("suggestion-1", function(value)
      outcome = value
    end)
    local action = fixture.commands[2].command
    fixture.event(2, {
      type = "applyRequested",
      actionId = action.actionId,
      transactionId = "transaction-entitlement",
      request = {
        expectedRevision = "doc:0",
        sourceId = "document",
        edits = { { range = { location = 7, length = 2 }, expectedText = "an", replacement = "a" } },
      },
    }, fixture.commands[2].id)
    fixture.event(3, {
      type = "presentationContentReplaced",
      checkId = "check-1",
      content = unavailable_content("writingCheckEntitlementRequired"),
    }, fixture.commands[1].id)
    assert_equal(nil, outcome)

    local updated = source("doc:1", "create a link.")
    fixture.observe({ type = "snapshot", snapshot = updated })
    finish_apply(nil, { status = "applied", snapshot = updated })
    assert_equal("completeApply", fixture.commands[3].command.type)
    fixture.event(4, { type = "actionCompleted", actionId = action.actionId }, fixture.commands[2].id)
    assert_equal({ status = "completed" }, outcome)
  end)

  it("keeps the Apply lease when a newer check arrives during the host mutation", function()
    local fixture = runtime_fixture()
    local finish_apply
    fixture.set_apply(function(_, done)
      finish_apply = done
    end)
    fixture.event(1, {
      type = "presentationContentReplaced",
      checkId = "check-1",
      content = suggestion_content(),
    }, fixture.commands[1].id)
    local outcome
    fixture.presentations[#fixture.presentations].actions.apply("suggestion-1", function(value)
      outcome = value
    end)
    local perform = fixture.commands[2]
    fixture.event(2, {
      type = "applyRequested",
      actionId = perform.command.actionId,
      transactionId = "transaction-regrouped",
      request = {
        expectedRevision = "doc:0",
        sourceId = "document",
        edits = { { range = { location = 7, length = 2 }, expectedText = "an", replacement = "a" } },
      },
    }, perform.id)

    fixture.event(3, {
      type = "presentationContentReplaced",
      checkId = "check-2",
      content = checking_content(1),
    })
    assert_equal(nil, outcome)

    finish_apply(nil, { status = "unavailable" })
    assert_equal("completeApply", fixture.commands[3].command.type)
    fixture.event(4, { type = "actionCompleted", actionId = perform.command.actionId }, perform.id)
    assert_equal({ status = "completed" }, outcome)
  end)

  it("keeps the active check lineage when Dismiss rematerializes under a fresh check ID", function()
    local fixture = runtime_fixture()
    local active = checking_content(1)
    active.suggestions = suggestion_content().suggestions
    active.suggestions[1].availableActions = { "dismiss" }
    fixture.event(1, {
      type = "presentationContentReplaced",
      checkId = "active-check",
      content = active,
    }, fixture.commands[1].id)
    local outcome
    fixture.presentations[#fixture.presentations].actions.dismiss("suggestion-1", function(value)
      outcome = value
    end)
    local perform = fixture.commands[2]
    fixture.event(2, {
      type = "presentationContentReplaced",
      checkId = "dismiss-rematerialization",
      content = checking_content(1),
    }, perform.id)
    assert_equal(nil, outcome)
    assert_equal(1, fixture.presentations[#fixture.presentations].snapshot.checkGeneration)

    fixture.event(3, { type = "actionCompleted", actionId = perform.command.actionId }, perform.id)
    assert_equal({ status = "completed" }, outcome)
    fixture.event(4, {
      type = "presentationContentReplaced",
      checkId = "dismiss-rematerialization",
      content = checking_content(2),
    }, perform.id)
    fixture.event(5, {
      type = "presentationContentReplaced",
      checkId = "active-check",
      content = suggestion_content({}),
    })
    local latest = fixture.presentations[#fixture.presentations].snapshot
    assert_equal({ type = "complete", coverage = "full" }, latest.state)
    assert_equal(1, latest.checkGeneration)
  end)
end)
