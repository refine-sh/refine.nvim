local Controller = {}
Controller.__index = Controller

local interceptable_keys = {
  "tab",
  "escape",
  "return",
  "space",
  "delete",
  "leftArrow",
  "rightArrow",
  "upArrow",
  "downArrow",
}

local function inactive(bufnr, reason)
  return { state = "inactive", bufnr = bufnr, reason = reason }
end

local function default_emit_status(bufnr)
  vim.api.nvim_exec_autocmds("User", {
    pattern = "RefineStatusChanged",
    data = { bufnr = bufnr },
    modeline = false,
  })
  vim.cmd.redrawstatus()
end

local function default_is_macos()
  return vim.uv.os_uname().sysname == "Darwin"
end

local function default_transport_factory(options)
  return require("refine.transport").new(options)
end

local function default_integration_factory(options)
  return require("refine.integration").new(options)
end

local function default_host_factory(options)
  return require("refine.nvim.host").new(options)
end

local function default_resolve_buffer(bufnr)
  return require("refine.nvim.eligibility").resolve(bufnr)
end

local function default_frontend()
  local config = require("refine.config").get()
  return require("refine.frontend").detect(config.frontend)
end

local function default_launch(callback)
  require("refine.app").launch(callback)
end

local function warning_codes(snapshot)
  local quick = snapshot.interaction and snapshot.interaction.quickApply
  if not quick then
    return {}
  end
  local supported = {}
  for _, key in ipairs(interceptable_keys) do
    supported[key] = true
  end
  local warnings = {}
  if quick.applyKey == quick.dismissKey then
    warnings[#warnings + 1] = "conflicting_action_keys"
  end
  if not supported[quick.applyKey] then
    warnings[#warnings + 1] = "unsupported_apply_key"
  end
  if not supported[quick.dismissKey] then
    warnings[#warnings + 1] = "unsupported_dismiss_key"
  end
  return warnings
end

local function semantic_status(bufnr, snapshot)
  local state = snapshot.state or { type = "pending" }
  local status = {
    state = state.type,
    bufnr = bufnr,
    suggestion_count = #(snapshot.suggestions or {}),
    warnings = warning_codes(snapshot),
  }
  if state.coverage ~= nil then
    status.coverage = state.coverage
  end
  if state.progress ~= nil then
    status.progress = {
      completed = state.progress.completedUnitCount,
      total = state.progress.totalUnitCount,
    }
  end
  if state.reason ~= nil then
    status.reason = state.reason
  end
  if snapshot.interaction and snapshot.interaction.automaticChecksEnabled ~= nil then
    status.automatic_checks_enabled = snapshot.interaction.automaticChecksEnabled
  end
  return status
end

function Controller:_set_status(status)
  if vim.deep_equal(self.current_status, status) then
    return
  end
  self.current_status = vim.deepcopy(status)
  require("refine.log").record("status", {
    bufnr = status.bufnr,
    state = status.state,
    reason = status.reason,
  })
  self.emit_status(status.bufnr)
end

function Controller:_on_presentation(run, snapshot)
  if self.run ~= run then
    return
  end
  local state = snapshot.state or {}
  if run.terminal or state.type == "closed" then
    return
  end
  if type(snapshot.checkGeneration) == "number" then
    run.check_generation = snapshot.checkGeneration
  end
  local status = semantic_status(run.bufnr, snapshot)
  status.frontend = run.frontend and run.frontend.id or "generic"
  self:_set_status(status)
  local quick = snapshot.interaction and snapshot.interaction.quickApply
  for _, warning in ipairs(status.warnings) do
    local message
    if warning == "conflicting_action_keys" then
      message = ("Refine Apply and Dismiss both use %q; use card actions until the keys differ."):format(quick.applyKey)
    elseif warning == "unsupported_apply_key" then
      message = ("Refine Apply key %q cannot be intercepted by Neovim; use :RefineApply or [a] in the card."):format(
        quick.applyKey
      )
    elseif warning == "unsupported_dismiss_key" then
      message = ("Refine Dismiss key %q cannot be intercepted by Neovim; use :RefineDismiss or [d] in the card."):format(
        quick.dismissKey
      )
    end
    if message then
      self.notify_once(message, vim.log.levels.WARN)
    end
  end
  local pending = run.manual_check_pending
  local owns_terminal = pending
    and snapshot.documentRevision == pending.revision
    and type(snapshot.checkGeneration) == "number"
    and snapshot.checkGeneration > pending.after_generation
    and (state.type == "complete" or state.type == "unavailable")
  if owns_terminal then
    run.manual_check_pending = nil
    if state.type == "unavailable" then
      local messages = {
        writingCheckEntitlementRequired = "Refine writing checks require an active trial or license. Open Refine to continue.",
        disconnected = "Refine could not be reached. Make sure the Refine app is running.",
        engineUnavailable = "Refine's writing-check engine is unavailable. Open Refine for details.",
        checkFailed = "Refine could not complete the writing check. Open Refine for details.",
      }
      self.notify(
        messages[state.reason] or ("Refine check unavailable: " .. tostring(state.reason or "unknown")),
        vim.log.levels.ERROR
      )
    end
  end
end

function Controller:_on_state(run, event)
  if self.run ~= run then
    return
  end
  run.connection_state = event.state
  require("refine.log").record("lifecycle", {
    bufnr = run.bufnr,
    state = event.state,
    kind = event.error and event.error.kind or nil,
    recoverability = event.error and event.error.recoverability or nil,
  })
  if event.state == "connecting" then
    self:_set_status({
      state = "connecting",
      bufnr = run.bufnr,
      suggestion_count = 0,
      warnings = {},
      frontend = run.frontend and run.frontend.id or "generic",
    })
  elseif event.state == "connected" then
    self:_set_status({
      state = "pending",
      bufnr = run.bufnr,
      suggestion_count = 0,
      warnings = {},
      frontend = run.frontend and run.frontend.id or "generic",
    })
  elseif event.state == "disconnected" then
    self:_set_status({
      state = "unavailable",
      bufnr = run.bufnr,
      suggestion_count = 0,
      reason = "disconnected",
      warnings = {},
      frontend = run.frontend and run.frontend.id or "generic",
    })
  elseif event.state == "stopped" and not event.error then
    run.terminal = true
    self:_set_status({
      state = "unavailable",
      bufnr = run.bufnr,
      suggestion_count = 0,
      reason = "disconnected",
      warnings = {},
      frontend = run.frontend and run.frontend.id or "generic",
    })
  elseif event.state == "stopped" and event.error then
    run.terminal = true
    local status = {
      state = "unavailable",
      bufnr = run.bufnr,
      suggestion_count = 0,
      reason = "disconnected",
      warnings = {},
      frontend = run.frontend and run.frontend.id or "generic",
    }
    if event.error.kind == "IncompatibleProtocolError" or event.error.kind == "EndpointProtocolVersionError" then
      status.reason = "incompatible_protocol"
      if event.error.required_update == "client" or event.error.required_update == "server" then
        status.required_update = event.error.required_update
      end
      if type(event.error.received_protocol) == "table" then
        status.received_protocol = {
          major = event.error.received_protocol.major,
          minor = event.error.received_protocol.minor,
        }
      end
    end
    self:_set_status(status)
    if not run.fatal_reported then
      run.fatal_reported = true
      local message
      if event.error.kind == "IncompatibleProtocolError" or event.error.kind == "EndpointProtocolVersionError" then
        message = event.error.required_update == "server"
            and "Refine for Neovim requires a newer Refine app. Update Refine, then reconnect."
          or "Refine requires a newer Refine for Neovim client. Update the plugin, then reconnect."
      else
        message = "Refine for Neovim stopped: " .. tostring(event.error)
      end
      self.notify_once(message, vim.log.levels.ERROR)
    end
  end
end

function Controller:_stop()
  local run = self.run
  if not run then
    return
  end
  self.run = nil
  if run.handle then
    run.handle.stop()
  end
  run.host:deactivate()
  self.emit_status(run.bufnr)
end

function Controller:_start(bufnr, winid, source_syntax)
  local run = {
    bufnr = bufnr,
    winid = winid,
    connection_state = "connecting",
    source_syntax = source_syntax,
    frontend = self.frontend(),
  }
  self.run = run
  self:_set_status({
    state = "connecting",
    bufnr = bufnr,
    suggestion_count = 0,
    warnings = {},
    frontend = run.frontend and run.frontend.id or "generic",
  })
  run.host = self.host_factory({
    bufnr = bufnr,
    run_id = self.uuid(),
    source_syntax = source_syntax,
    on_presentation = function(snapshot)
      self:_on_presentation(run, snapshot)
    end,
    on_native_change = function()
      run.manual_check_pending = nil
      vim.schedule(function()
        if self.run == run then
          self:reconcile(run.bufnr, run.winid)
        end
      end)
    end,
  })
  local transport = self.transport_factory({
    client = {
      id = "refine-neovim",
      version = require("refine.version").semver,
      host = "neovim",
    },
    frontend = run.frontend,
    host_capabilities = { interceptableSuggestionActionKeys = vim.deepcopy(interceptable_keys) },
  })
  local integration = self.integration_factory({ engine_port = transport })
  run.handle = integration:run({
    host = run.host,
    on_error = function(err)
      self:_on_state(run, { state = "stopped", error = err })
    end,
    on_state = function(event)
      self:_on_state(run, event)
    end,
  })
end

function Controller:reconcile(bufnr, winid)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  winid = winid or vim.api.nvim_get_current_win()
  local has_ui = self.has_ui()
  local owns_card = has_ui and self.run and self.run.host:owns_window(winid)
  local frontend_changed = self.run and has_ui and not vim.deep_equal(self.run.frontend, self.frontend())
  if owns_card then
    bufnr = self.run.bufnr
    winid = self.run.winid
  end

  local source_syntax, reason = self.resolve_buffer(bufnr)
  if not has_ui then
    reason = "no_ui"
  elseif not self.is_macos() then
    reason = "unsupported_platform"
  end
  if reason then
    self:_stop()
    self.current_status = inactive(bufnr, reason)
    return false
  end

  if owns_card and not frontend_changed then
    return true
  end

  if self.run and self.run.bufnr == bufnr then
    if frontend_changed then
      self:_stop()
      self:_start(bufnr, winid, source_syntax)
      if self.view_suspended then
        self.run.host:suspend_view()
      end
      return true
    end
    if self.run.source_syntax ~= source_syntax then
      self.run.manual_check_pending = nil
      self.run.source_syntax = source_syntax
      self.run.host:set_source_syntax(source_syntax)
    end
    if self.run.winid ~= winid then
      self.run.host:suspend_view()
      self.run.winid = winid
    end
    if not self.view_suspended then
      self.run.host:reconcile_view()
    end
    return true
  end
  self:_stop()
  self:_start(bufnr, winid, source_syntax)
  if self.view_suspended then
    self.run.host:suspend_view()
  end
  return true
end

function Controller:status(bufnr)
  if bufnr == nil then
    local winid = vim.api.nvim_get_current_win()
    if self.run and self.run.host:owns_window(winid) then
      bufnr = self.run.bufnr
    else
      bufnr = vim.api.nvim_get_current_buf()
    end
  end
  local _, reason = self.resolve_buffer(bufnr)
  if reason then
    return inactive(bufnr, reason)
  end
  if not self.has_ui() then
    return inactive(bufnr, "no_ui")
  end
  if not self.is_macos() then
    return inactive(bufnr, "unsupported_platform")
  end
  if not self.run or self.run.bufnr ~= bufnr then
    return inactive(bufnr, "not_active_buffer")
  end
  return vim.deepcopy(self.current_status or {
    state = "connecting",
    bufnr = bufnr,
    suggestion_count = 0,
    warnings = {},
  })
end

function Controller:statusline(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not self.run or self.run.bufnr ~= bufnr or not self.current_status then
    return ""
  end
  local status = self.current_status
  if status.state == "connecting" then
    return "Refine …"
  elseif status.state == "unavailable" then
    return "Refine !"
  elseif status.state == "checking" and status.progress then
    return ("Refine %d/%d"):format(status.progress.completed, status.progress.total)
  elseif status.state == "complete" then
    return ("Refine %d"):format(status.suggestion_count or 0)
  end
  return "Refine ·"
end

function Controller:owner_bufnr()
  return self.run and self.run.bufnr or nil
end

function Controller:check(intent)
  if self.run and self.run.terminal then
    self:_stop()
  end
  if not self:reconcile() or not self.run then
    return false, self:status().reason
  end
  local requested, revision = self.run.host:request_check(intent)
  if requested then
    self.run.manual_check_pending = {
      revision = revision,
      after_generation = self.run.check_generation or 0,
    }
  end
  if not requested then
    self.run.manual_check_pending = nil
  end
  if requested and self.run.connection_state ~= "connected" and not self.launch_pending then
    self.launch_pending = true
    self.launch(function(err)
      self.launch_pending = false
      require("refine.log").record("launch", {
        bufnr = self.run and self.run.bufnr or nil,
        status = err and "failed" or "completed",
      })
      if err then
        self.notify("Refine could not be launched: " .. tostring(err), vim.log.levels.ERROR)
      end
    end)
  end
  return requested
end

function Controller:show()
  return self.run ~= nil and self.run.host:show() or false
end

function Controller:next()
  return self.run ~= nil and self.run.host:next() or false
end

function Controller:previous()
  return self.run ~= nil and self.run.host:previous() or false
end

function Controller:action(kind)
  return self.run ~= nil and self.run.host:action(kind) or false
end

function Controller:close()
  if self.run then
    self.run.host:close()
    return true
  end
  return false
end

function Controller:suspend_view()
  self.view_suspended = true
  if self.run then
    self.run.host:suspend_view()
  end
end

function Controller:resume_view(bufnr, winid)
  self.view_suspended = false
  return self:reconcile(bufnr, winid)
end

function Controller:refresh_view()
  return self.run ~= nil and self.run.host:refresh_view() or false
end

function Controller:refresh_highlights()
  if self.run then
    self.run.host:refresh_highlights()
  end
end

local M = {}

function M.new(dependencies)
  dependencies = dependencies or {}
  return setmetatable({
    has_ui = dependencies.has_ui or function()
      return #vim.api.nvim_list_uis() > 0
    end,
    is_macos = dependencies.is_macos or default_is_macos,
    resolve_buffer = dependencies.resolve_buffer or default_resolve_buffer,
    transport_factory = dependencies.transport_factory or default_transport_factory,
    integration_factory = dependencies.integration_factory or default_integration_factory,
    host_factory = dependencies.host_factory or default_host_factory,
    uuid = dependencies.uuid or require("refine.transport.uuid").v4,
    frontend = dependencies.frontend or default_frontend,
    emit_status = dependencies.emit_status or default_emit_status,
    launch = dependencies.launch or default_launch,
    notify = dependencies.notify or vim.notify,
    notify_once = dependencies.notify_once or vim.notify_once,
    view_suspended = false,
  }, Controller)
end

return M
