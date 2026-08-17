local root = vim.fn.getcwd()
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  root .. "/tests/?.lua",
  package.path,
}, ";")

local harness = require("support.harness")

local public_status_states = {
  inactive = true,
  connecting = true,
  pending = true,
  checking = true,
  complete = true,
  unavailable = true,
}

local function assert_public_status_states(states)
  for _, state in ipairs(states) do
    harness.equal(true, public_status_states[state] == true)
  end
end

local function eligible_buffer(text)
  vim.cmd.enew({ bang = true })
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "markdown"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { text })
  return bufnr
end

local function fixture(options)
  options = options or {}
  local runs = {}
  local launches = 0
  local status_events = {}
  local notifications = {}
  local compatibility_notifications = {}
  local source_syntax = "markdownDocument"
  local integration_factory = function(options)
    return {
      run = function(_, input)
        local observations = {}
        local detach = input.host:observe(function(value)
          observations[#observations + 1] = value
        end, function() end)
        input.on_state({ state = "connecting" })
        local revision = input.host.source:snapshot().revision
        input.host:present({
          documentRevision = revision,
          presentationRevision = 1,
          checkGeneration = 0,
          state = { type = "pending" },
          suggestions = {},
        }, {}, function(err)
          assert(err == nil)
        end)
        local run = {
          input = input,
          host = input.host,
          observations = observations,
          stopped = false,
          transport_options = options.engine_port.options,
        }
        runs[#runs + 1] = run
        local handle = {
          stop = function()
            run.stopped = true
            detach()
          end,
          is_running = function()
            return not run.stopped
          end,
        }
        run.handle = handle
        return handle
      end,
    }
  end

  local controller = require("refine.controller").new({
    has_ui = options.has_ui or function()
      return true
    end,
    is_macos = function()
      return true
    end,
    resolve_buffer = function(bufnr)
      if vim.bo[bufnr].filetype == "markdown" then
        return source_syntax
      end
      return nil, "unsupported_filetype"
    end,
    transport_factory = function(options)
      return { options = options }
    end,
    integration_factory = integration_factory,
    frontend = options.frontend,
    uuid = function()
      return "controller-run"
    end,
    emit_status = function(bufnr)
      status_events[#status_events + 1] = bufnr
    end,
    launch = function(callback)
      launches = launches + 1
      callback(nil)
    end,
    notify = function(message, level)
      notifications[#notifications + 1] = { message = message, level = level }
    end,
    notify_once = function(message, level)
      compatibility_notifications[#compatibility_notifications + 1] = { message = message, level = level }
    end,
  })
  return controller,
    runs,
    function()
      return launches
    end,
    status_events,
    function(value)
      source_syntax = value
    end,
    notifications,
    compatibility_notifications
end

harness.test("owns one eligible buffer and publishes copied semantic status", function()
  local controller, runs, _, status_events = fixture()
  local first = eligible_buffer("One")
  controller:reconcile(first, vim.api.nvim_get_current_win())
  harness.equal(1, #runs)
  harness.equal("refine-neovim", runs[1].transport_options.client.id)
  harness.equal("pending", controller:status(first).state)
  harness.equal(0, controller:status(first).suggestion_count)

  runs[1].input.on_state({ state = "connected" })
  runs[1].host.on_presentation({
    state = {
      type = "checking",
      progress = { completedUnitCount = 1, totalUnitCount = 3 },
    },
    suggestions = {},
  })
  harness.equal({ completed = 1, total = 3 }, controller:status(first).progress)
  runs[1].host.on_presentation({
    state = { type = "complete", coverage = "full" },
    interaction = {
      automaticChecksEnabled = false,
      quickApply = { enabled = true, applyKey = "leftShift", dismissKey = "escape" },
    },
    suggestions = { { id = "one" }, { id = "two" } },
  })
  local status = controller:status(first)
  harness.equal("complete", status.state)
  harness.equal("full", status.coverage)
  harness.equal(false, status.automatic_checks_enabled)
  harness.equal(2, status.suggestion_count)
  harness.equal({ "unsupported_apply_key" }, status.warnings)
  status.state = "tampered"
  harness.equal("complete", controller:status(first).state)

  controller:reconcile(first, vim.api.nvim_get_current_win())
  harness.equal(1, #runs)

  local second = eligible_buffer("Two")
  controller:reconcile(second, vim.api.nvim_get_current_win())
  harness.equal(true, runs[1].stopped)
  harness.equal(2, #runs)
  harness.equal("not_active_buffer", controller:status(first).reason)
  harness.equal(true, #status_events > 0)
end)

harness.test("reports card action key incompatibility when cursor Quick Apply is disabled", function()
  local controller, runs = fixture()
  local bufnr = eligible_buffer("Card keys")
  controller:reconcile(bufnr, vim.api.nvim_get_current_win())

  runs[1].host.on_presentation({
    state = { type = "complete", coverage = "full" },
    interaction = {
      automaticChecksEnabled = false,
      quickApply = { enabled = false, applyKey = "leftShift", dismissKey = "rightShift" },
    },
    suggestions = {
      { id = "one", availableActions = { "apply", "dismiss" } },
    },
  })

  harness.equal({ "unsupported_apply_key", "unsupported_dismiss_key" }, controller:status(bufnr).warnings)
end)

harness.test(
  "uses a one-time notification to configure an explicit mapping for an unsupported Apply shortcut",
  function()
    local controller, runs, _, _, _, _, compatibility_notifications = fixture()
    local bufnr = eligible_buffer("Apply shortcut")
    controller:reconcile(bufnr, vim.api.nvim_get_current_win())

    runs[1].host.on_presentation({
      state = { type = "complete", coverage = "full" },
      interaction = {
        automaticChecksEnabled = false,
        quickApply = { enabled = true, applyKey = "rightShift", dismissKey = "escape" },
      },
      suggestions = { { id = "one", availableActions = { "apply" } } },
    })

    harness.equal({
      {
        message = "Right Shift cannot be intercepted by Neovim. Configure another Apply key in Refine, or add a Neovim mapping:\n"
          .. 'vim.keymap.set("n", "<leader>ra", "<Plug>(RefineApply)")',
        level = vim.log.levels.WARN,
      },
    }, compatibility_notifications)
  end
)

harness.test("updates source syntax in the existing buffer session", function()
  local controller, runs, _, _, set_syntax = fixture()
  local bufnr = eligible_buffer("Syntax")
  controller:reconcile(bufnr, vim.api.nvim_get_current_win())
  local first_revision = runs[1].host.source:snapshot().revision

  set_syntax("latexDocument")
  controller:reconcile(bufnr, vim.api.nvim_get_current_win())
  harness.equal(1, #runs)
  local snapshot = runs[1].observations[#runs[1].observations - 1]
  local attention = runs[1].observations[#runs[1].observations]
  harness.equal("snapshot", snapshot.type)
  harness.equal("latexDocument", snapshot.snapshot.sources[1].sourceSyntax)
  harness.equal(false, first_revision == snapshot.snapshot.revision)
  harness.equal("attentionChanged", attention.type)
  harness.equal(snapshot.snapshot.revision, attention.revision)
end)

harness.test("launches Refine only for an explicit disconnected check", function()
  local controller, runs, launch_count, _, _, notifications = fixture()
  local bufnr = eligible_buffer("Check me")
  controller:reconcile(bufnr, vim.api.nvim_get_current_win())
  harness.equal(0, launch_count())

  local ok = controller:check(nil)
  harness.equal(true, ok)
  harness.equal(1, launch_count())
  harness.equal("checkRequested", runs[1].observations[#runs[1].observations].type)

  runs[1].input.on_state({ state = "connected" })
  controller:check(nil)
  harness.equal(1, launch_count())

  local revision = runs[1].host.source:snapshot().revision
  runs[1].host.on_presentation({
    documentRevision = revision,
    checkGeneration = 0,
    state = { type = "unavailable", reason = "writingCheckEntitlementRequired" },
    suggestions = {},
  })
  harness.equal(0, #notifications)
  runs[1].host.on_presentation({
    documentRevision = revision,
    checkGeneration = 1,
    state = { type = "unavailable", reason = "writingCheckEntitlementRequired" },
    suggestions = {},
  })
  harness.equal(1, #notifications)
  harness.matches("trial or license", notifications[1].message)
end)

harness.test("abandons explicit-check notification ownership after a native change", function()
  local controller, runs, _, _, _, notifications = fixture()
  local bufnr = eligible_buffer("Original")
  controller:reconcile(bufnr, vim.api.nvim_get_current_win())
  harness.equal(true, controller:check(nil))
  harness.equal(true, type(controller.run.manual_check_pending) == "table")

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "Changed" })
  harness.equal(
    true,
    vim.wait(1000, function()
      return controller.run.manual_check_pending == nil
    end)
  )
  runs[1].host.on_presentation({
    documentRevision = runs[1].host.source:snapshot().revision,
    checkGeneration = 1,
    state = { type = "unavailable", reason = "checkFailed" },
    suggestions = {},
  })
  harness.equal(0, #notifications)
end)

harness.test("retries a terminal integration only from explicit work", function()
  local controller, runs = fixture()
  local bufnr = eligible_buffer("Retry me")
  controller:reconcile(bufnr, vim.api.nvim_get_current_win())
  runs[1].handle.stop()
  runs[1].input.on_state({
    state = "stopped",
    error = {
      kind = "IncompatibleProtocolError",
      received_protocol = { major = 2, minor = 5 },
      supported_protocol = { major = 1, minor = 0 },
    },
  })

  controller:reconcile(bufnr, vim.api.nvim_get_current_win())
  harness.equal(1, #runs)
  harness.equal("unavailable", controller:status(bufnr).state)

  harness.equal(true, controller:check(nil))
  harness.equal(2, #runs)
  harness.equal("checkRequested", runs[2].observations[#runs[2].observations].type)
end)

harness.test("stays inactive without a UI or on unsupported platforms", function()
  local Controller = require("refine.controller")
  local bufnr = eligible_buffer("Quiet")
  local no_ui = Controller.new({
    has_ui = function()
      return false
    end,
    is_macos = function()
      return true
    end,
    resolve_buffer = function()
      return "markdownDocument"
    end,
  })
  no_ui:reconcile(bufnr, vim.api.nvim_get_current_win())
  harness.equal("no_ui", no_ui:status(bufnr).reason)

  local non_macos = Controller.new({
    has_ui = function()
      return true
    end,
    is_macos = function()
      return false
    end,
    resolve_buffer = function()
      return "markdownDocument"
    end,
  })
  non_macos:reconcile(bufnr, vim.api.nvim_get_current_win())
  harness.equal("unsupported_platform", non_macos:status(bufnr).reason)
end)

harness.test("stops the owner-card exception when the last UI detaches", function()
  local ui_attached = true
  local controller, runs = fixture({
    has_ui = function()
      return ui_attached
    end,
  })
  local bufnr = eligible_buffer("Headless")
  local winid = vim.api.nvim_get_current_win()
  controller:reconcile(bufnr, winid)
  runs[1].host.owns_window = function()
    return true
  end

  ui_attached = false
  harness.equal(false, controller:reconcile(bufnr, winid))
  harness.equal(true, runs[1].stopped)
  harness.equal("no_ui", controller:status(bufnr).reason)
end)

harness.test("stops a card-owned run when its source becomes ineligible", function()
  local controller, runs = fixture()
  local bufnr = eligible_buffer("Read only")
  local winid = vim.api.nvim_get_current_win()
  controller:reconcile(bufnr, winid)
  runs[1].host.owns_window = function()
    return true
  end

  vim.bo[bufnr].filetype = "lua"
  harness.equal(false, controller:reconcile(bufnr, winid))
  harness.equal(true, runs[1].stopped)
  harness.equal("unsupported_filetype", controller:status(bufnr).reason)
end)

harness.test("restarts the run when frontend identity changes", function()
  local frontend = { id = "terminal" }
  local controller, runs = fixture({
    frontend = function()
      return frontend and vim.deepcopy(frontend) or nil
    end,
  })
  local bufnr = eligible_buffer("Frontend")
  local winid = vim.api.nvim_get_current_win()
  controller:reconcile(bufnr, winid)
  harness.equal({ id = "terminal" }, runs[1].transport_options.frontend)
  runs[1].host.owns_window = function()
    return true
  end

  frontend = nil
  controller:reconcile(bufnr, winid)
  harness.equal(true, runs[1].stopped)
  harness.equal(2, #runs)
  harness.equal(nil, runs[2].transport_options.frontend)
end)

harness.test("keeps fatal protocol incompatibility in the public unavailable state", function()
  local bufnr = eligible_buffer("Compatibility")
  local observed_states = {}
  local controller
  controller = require("refine.controller").new({
    emit_status = function(owner_bufnr)
      if controller then
        observed_states[#observed_states + 1] = controller:status(owner_bufnr).state
      end
    end,
    has_ui = function()
      return true
    end,
    is_macos = function()
      return true
    end,
    resolve_buffer = function()
      return "markdownDocument"
    end,
    frontend = function()
      return nil
    end,
    transport_factory = function()
      return {
        connect = function(_, _, callback)
          callback({
            kind = "IncompatibleProtocolError",
            message = "incompatible protocol",
            recoverability = "fatal",
            received_protocol = { major = 2, minor = 5 },
            supported_protocol = { major = 1, minor = 0 },
          })
        end,
      }
    end,
    notify_once = function() end,
  })

  controller:reconcile(bufnr, vim.api.nvim_get_current_win())
  local status = controller:status(bufnr)
  harness.equal("unavailable", status.state)
  harness.equal("incompatible_protocol", status.reason)
  harness.equal(nil, status.required_update)
  harness.equal({ major = 2, minor = 5 }, status.received_protocol)
  harness.equal({ major = 1, minor = 0 }, status.supported_protocol)
  assert_public_status_states(observed_states)
end)

harness.test("keeps clean integration completion inside the public status states", function()
  local bufnr = eligible_buffer("Clean completion")
  local observed_states = {}
  local end_observation
  local controller
  controller = require("refine.controller").new({
    emit_status = function(owner_bufnr)
      if controller then
        observed_states[#observed_states + 1] = controller:status(owner_bufnr).state
      end
    end,
    has_ui = function()
      return true
    end,
    is_macos = function()
      return true
    end,
    resolve_buffer = function()
      return "markdownDocument"
    end,
    frontend = function()
      return nil
    end,
    host_factory = function(options)
      local host = require("refine.nvim.host").new(options)
      local observe = host.observe
      host.observe = function(self, emit, on_end)
        end_observation = on_end
        return observe(self, emit, on_end)
      end
      return host
    end,
    transport_factory = function()
      return {
        connect = function() end,
      }
    end,
  })

  controller:reconcile(bufnr, vim.api.nvim_get_current_win())
  harness.equal("function", type(end_observation))
  end_observation()

  local status = controller:status(bufnr)
  harness.equal("unavailable", status.state)
  harness.equal("disconnected", status.reason)
  assert_public_status_states(observed_states)
end)

harness.test("forwards view and highlight lifecycle refreshes to the active host", function()
  local controller, runs = fixture()
  local bufnr = eligible_buffer("Lifecycle")
  controller:reconcile(bufnr, vim.api.nvim_get_current_win())
  local view_refreshes = 0
  local highlight_refreshes = 0
  runs[1].host.refresh_view = function()
    view_refreshes = view_refreshes + 1
    return true
  end
  runs[1].host.refresh_highlights = function()
    highlight_refreshes = highlight_refreshes + 1
  end

  harness.equal(true, controller:refresh_view())
  controller:refresh_highlights()
  harness.equal(1, view_refreshes)
  harness.equal(1, highlight_refreshes)
end)

harness.test("reconciles the caret view in the same buffer and a new owner window", function()
  local controller, runs = fixture()
  local bufnr = eligible_buffer("Lifecycle")
  local first_win = vim.api.nvim_get_current_win()
  controller:reconcile(bufnr, first_win)
  local reconciliations = 0
  local reconciled_windows = {}
  local suspensions = 0
  runs[1].host.reconcile_view = function(_, winid)
    reconciliations = reconciliations + 1
    reconciled_windows[#reconciled_windows + 1] = winid
  end
  runs[1].host.suspend_view = function()
    suspensions = suspensions + 1
  end

  harness.equal(true, controller:reconcile(bufnr, first_win))
  harness.equal(1, reconciliations)
  harness.equal(0, suspensions)

  vim.cmd("belowright split")
  local second_win = vim.api.nvim_get_current_win()
  harness.equal(bufnr, vim.api.nvim_win_get_buf(second_win))
  harness.equal(true, controller:reconcile(bufnr, second_win))
  harness.equal(2, reconciliations)
  harness.equal({ first_win, second_win }, reconciled_windows)
  harness.equal(1, suspensions)
  harness.equal(1, #runs)
end)

harness.test("binds a new host to the reconciled editor window", function()
  local controller, runs = fixture()
  local bufnr = eligible_buffer("Lifecycle")
  local editor_win = vim.api.nvim_get_current_win()
  vim.cmd("belowright split")
  harness.equal(false, editor_win == vim.api.nvim_get_current_win())

  harness.equal(true, controller:reconcile(bufnr, editor_win))
  harness.equal(editor_win, runs[1].host.winid)
end)

harness.test("keeps ordinary reconciliation suspended until an explicit view resume", function()
  local controller, runs = fixture()
  local bufnr = eligible_buffer("Lifecycle")
  local winid = vim.api.nvim_get_current_win()
  controller:reconcile(bufnr, winid)
  local reconciliations = 0
  local suspensions = 0
  runs[1].host.reconcile_view = function()
    reconciliations = reconciliations + 1
  end
  runs[1].host.suspend_view = function()
    suspensions = suspensions + 1
  end

  controller:suspend_view()
  harness.equal(1, suspensions)
  harness.equal(true, controller:reconcile(bufnr, winid))
  harness.equal(0, reconciliations)
  harness.equal(true, controller:resume_view(bufnr, winid))
  harness.equal(1, reconciliations)
end)

harness.test("reports the owner source status through RefineStatus while its card is focused", function()
  local controller, runs = fixture()
  local bufnr = eligible_buffer("bad text")
  controller:reconcile(bufnr, vim.api.nvim_get_current_win())
  local revision = runs[1].host.source:snapshot().revision
  runs[1].host:present({
    documentRevision = revision,
    presentationRevision = 2,
    checkGeneration = 1,
    state = { type = "complete", coverage = "full" },
    appearance = {
      highlight = { style = "underline", grammarColor = "#FF2D55", fluencyColor = "#007AFF" },
      diff = { additionColor = "#34C759", deletionColor = "#FF3B30", showHiddenWhitespace = true },
    },
    interaction = {
      automaticChecksEnabled = true,
      quickApply = { enabled = false, applyKey = "tab", dismissKey = "escape", activationStyle = "highlightChanges" },
    },
    suggestions = {
      {
        id = "status-card",
        sourceId = "document",
        kind = "grammar",
        attribution = { languageDisplayName = "English", textDirection = "ltr", checkModelDisplayName = "Local" },
        activationRange = { location = 0, length = 3 },
        highlightRanges = { { location = 0, length = 3 } },
        diff = { { kind = "delete", text = "bad" }, { kind = "insert", text = "good" } },
        availableActions = { "apply" },
      },
    },
  }, {})
  harness.equal(true, runs[1].host:show())

  local notifications = {}
  local original_notify = vim.notify
  vim.notify = function(message)
    notifications[#notifications + 1] = message
  end
  require("refine.commands").register({ controller = controller, lifecycle = false })
  vim.cmd.RefineStatus()
  vim.notify = original_notify

  harness.equal("complete", controller:status().state)
  harness.equal(bufnr, controller:status().bufnr)
  harness.equal(1, #notifications)
  harness.matches('state = "complete"', notifications[1])
  runs[1].host:close()
end)

harness.run()
