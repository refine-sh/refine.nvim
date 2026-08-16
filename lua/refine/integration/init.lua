-- Host-neutral integration runtime.
--
-- Async callbacks are error-first unless noted otherwise:
--   engine_port:connect({ run_id }, done(err, session))
--   host:observe(emit(observation), finish(err)) -> detach()
--   host:validate_revision(revision, done(err, validation))
--   host:apply(request, done(err, outcome))
--   host:present(snapshot, actions, done(err))
--
-- Suggestion actions report domain outcomes directly:
--   actions.apply/dismiss/report(suggestion_id, done(outcome))
--   actions.explain(suggestion_id, on_update, on_end) -> cancel()

local errors = require("refine.transport.errors")
local validation = require("refine.integration.validation")
local uuid = require("refine.transport.uuid")
local wire = require("refine.transport.wire")

local M = {}

M.DEFAULT_PRESENTATION_APPEARANCE = {
  highlight = {
    style = "underline",
    grammarColor = "#FF2D55",
    fluencyColor = "#007AFF",
  },
  diff = {
    additionColor = "#34C759",
    deletionColor = "#FF3B30",
    showHiddenWhitespace = true,
  },
}

M.DEFAULT_PRESENTATION_INTERACTION = {
  automaticChecksEnabled = true,
  quickApply = {
    enabled = true,
    applyKey = "tab",
    dismissKey = "escape",
    activationStyle = "showTipAndHighlight",
  },
}

local Run = {}
Run.__index = Run

local function host_error(message, cause)
  return errors.new("FatalHostError", message, "fatal", { cause = cause })
end

local function engine_error(message, cause)
  return errors.new("FatalEngineError", message, "fatal", { cause = cause })
end

local function same_sources(left, right)
  return vim.deep_equal(left, right)
end

local function state_from_content(content)
  if content.status == "complete" then
    return { type = "complete", coverage = content.coverage }
  end
  if content.status == "unavailable" then
    return { type = "unavailable", reason = content.unavailableReason }
  end
  if content.status == "checking" and content.progress ~= nil then
    return { type = "checking", progress = vim.deepcopy(content.progress) }
  end
  return { type = content.status }
end

local function default_delay(milliseconds, callback)
  if milliseconds <= 0 then
    vim.schedule(callback)
    return function() end
  end
  local timer = vim.uv.new_timer()
  timer:start(
    milliseconds,
    0,
    vim.schedule_wrap(function()
      if not timer:is_closing() then
        timer:close()
      end
      callback()
    end)
  )
  return function()
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end
end

function Run.new(options, input)
  return setmetatable({
    engine_port = options.engine_port,
    reconnect_delay_ms = options.reconnect_delay_ms or 1000,
    delay = options.delay or default_delay,
    schedule = options.schedule or vim.schedule,
    id_generator = options.uuid or uuid.v4,
    host = input.host,
    on_error = input.on_error or function() end,
    on_state = input.on_state or function() end,
    run_id = (options.uuid or uuid.v4)(),
    running = true,
    connecting = false,
    server_epoch = nil,
    session = nil,
    document_opened = false,
    opening_document = false,
    replace_in_flight = false,
    pending_replace = nil,
    detach_observer = nil,
    latest_snapshot = nil,
    latest_attention = nil,
    pending_attention = nil,
    attention_flush_scheduled = false,
    last_sent_attention = nil,
    retired_revisions = {},
    pending_check = nil,
    current_check_id = nil,
    current_check_lineage_id = nil,
    retired_check_ids = {},
    retired_check_command_ids = {},
    check_lifecycles = {},
    check_lineages = {},
    open_command_id = nil,
    presentation_revision = 0,
    check_generation = 0,
    appearance = vim.deepcopy(M.DEFAULT_PRESENTATION_APPEARANCE),
    interaction = vim.deepcopy(M.DEFAULT_PRESENTATION_INTERACTION),
    current_presentation = nil,
    presenting = false,
    queued_presentation = nil,
    reconnect_cancel = nil,
    pending_actions = {},
    action_by_key = {},
    action_by_command_id = {},
    resumable_check = nil,
    transaction_receipts = {},
    transaction_by_action = {},
    apply_lease_action_id = nil,
    queued_snapshot_during_apply = nil,
    stopped_state_emitted = false,
    reporting_state_error = false,
  }, Run)
end

function Run:_emit_state(state)
  if state.error ~= nil then
    state = vim.tbl_extend("force", state, { error = errors.redact(state.error) })
  end
  local ok, callback_error = pcall(self.on_state, state)
  if ok or self.reporting_state_error then
    return
  end
  self.reporting_state_error = true
  local failure = host_error("integration lifecycle observer failed", callback_error)
  pcall(self.on_error, errors.redact(failure, "Integration lifecycle observer failed"))
  self:stop(failure)
  self.reporting_state_error = false
end

function Run:_next_presentation_revision()
  self.presentation_revision = self.presentation_revision + 1
  return self.presentation_revision
end

function Run:_actions_for(snapshot)
  return {
    apply = function(suggestion_id, callback)
      self:_perform_action(snapshot, suggestion_id, "apply", callback)
    end,
    dismiss = function(suggestion_id, callback)
      self:_perform_action(snapshot, suggestion_id, "dismiss", callback)
    end,
    report = function(suggestion_id, callback)
      self:_perform_action(snapshot, suggestion_id, "report", callback)
    end,
    explain = function(suggestion_id, on_update, on_end)
      return self:_explain(snapshot, suggestion_id, on_update, on_end)
    end,
  }
end

local function action_is_available(suggestion, kind)
  for _, available in ipairs(suggestion.availableActions) do
    if available == kind then
      return true
    end
  end
  return false
end

function Run:_live_suggestion(bound, suggestion_id, kind)
  local current = self.current_presentation
  if
    not current
    or current.presentationRevision ~= bound.presentationRevision
    or current.documentRevision ~= bound.documentRevision
  then
    return nil
  end
  for _, suggestion in ipairs(current.suggestions) do
    if suggestion.id == suggestion_id and action_is_available(suggestion, kind) then
      return suggestion
    end
  end
end

function Run:_complete_pending(pending, outcome)
  if self.pending_actions[pending.id] ~= pending then
    return
  end
  self.pending_actions[pending.id] = nil
  if self.action_by_key[pending.key] == pending then
    self.action_by_key[pending.key] = nil
  end
  if pending.command_id and self.action_by_command_id[pending.command_id] == pending.id then
    self.action_by_command_id[pending.command_id] = nil
  end
  local transaction_id = self.transaction_by_action[pending.id]
  if transaction_id then
    self.transaction_by_action[pending.id] = nil
    self.transaction_receipts[transaction_id] = nil
  end
  for _, callback in ipairs(pending.callbacks or {}) do
    callback(vim.deepcopy(outcome))
  end
  if pending.on_update then
    if outcome.status == "stale" then
      pending.on_update({ status = "stale" })
    elseif outcome.status == "unavailable" then
      pending.on_update({ status = "unavailable", reason = outcome.reason })
    end
    pending.on_end()
  end

  if outcome.status == "completed" and pending.kind == "dismiss" then
    local current = self.current_presentation
    if current and current.documentRevision == self.latest_snapshot.revision then
      local suggestions = {}
      for _, suggestion in ipairs(current.suggestions) do
        if suggestion.id ~= pending.suggestion_id then
          suggestions[#suggestions + 1] = vim.deepcopy(suggestion)
        end
      end
      local replacement = vim.deepcopy(current)
      replacement.presentationRevision = self:_next_presentation_revision()
      replacement.suggestions = suggestions
      self:_publish(replacement)
    end
  elseif
    (pending.kind == "apply" or pending.kind == "dismiss")
    and outcome.status ~= "completed"
    and outcome.status ~= "stale"
    and not (outcome.status == "unavailable" and outcome.reason == "mutationIndeterminate")
    and not (outcome.status == "unavailable" and outcome.reason == "disconnected")
  then
    local current = self.current_presentation
    if current and self.latest_snapshot and current.documentRevision == self.latest_snapshot.revision then
      local base_had_action = false
      for _, suggestion in ipairs(pending.base_presentation.suggestions) do
        if suggestion.id == pending.suggestion_id and action_is_available(suggestion, pending.kind) then
          base_had_action = true
          break
        end
      end
      if base_had_action then
        local replacement = vim.deepcopy(current)
        local restored = false
        for _, suggestion in ipairs(replacement.suggestions) do
          if suggestion.id == pending.suggestion_id and not action_is_available(suggestion, pending.kind) then
            suggestion.availableActions[#suggestion.availableActions + 1] = pending.kind
            restored = true
          end
        end
        if restored then
          replacement.presentationRevision = self:_next_presentation_revision()
          self:_publish(replacement)
        end
      end
    end
  end
end

function Run:_disable_action(pending)
  local current = self.current_presentation
  if not current or current.presentationRevision ~= pending.base_presentation.presentationRevision then
    return
  end
  local replacement = vim.deepcopy(current)
  replacement.presentationRevision = self:_next_presentation_revision()
  for _, suggestion in ipairs(replacement.suggestions) do
    if suggestion.id == pending.suggestion_id then
      local available = {}
      for _, action in ipairs(suggestion.availableActions) do
        if action ~= pending.kind then
          available[#available + 1] = action
        end
      end
      suggestion.availableActions = available
    end
  end
  self:_publish(replacement)
end

function Run:_send_action(pending)
  if not self.session then
    self:_complete_pending(pending, { status = "unavailable", reason = "disconnected" })
    return
  end
  if not self:_live_suggestion(pending.base_presentation, pending.suggestion_id, pending.kind) then
    self:_complete_pending(pending, { status = "stale" })
    return
  end
  if pending.kind == "apply" or pending.kind == "dismiss" then
    self:_disable_action(pending)
  end
  pending.command_id = self.id_generator()
  self.action_by_command_id[pending.command_id] = pending.id
  self:_send(
    {
      type = "performAction",
      actionId = pending.id,
      kind = pending.kind,
      suggestion = {
        id = pending.suggestion_id,
        documentRevision = pending.base_presentation.documentRevision,
      },
    },
    pending.command_id,
    function(err)
      if err then
        self:_complete_pending(pending, { status = "unavailable", reason = "disconnected" })
      end
    end
  )
end

function Run:_finish_explanation(pending, update)
  if self.pending_actions[pending.id] ~= pending then
    return
  end
  pending.on_update(update)
  self.pending_actions[pending.id] = nil
  if self.action_by_key[pending.key] == pending then
    self.action_by_key[pending.key] = nil
  end
  if pending.command_id and self.action_by_command_id[pending.command_id] == pending.id then
    self.action_by_command_id[pending.command_id] = nil
  end
  pending.on_end()
end

function Run:_complete_host_apply(action_id, transaction_id, request)
  local duplicate = self.transaction_receipts[transaction_id]
  if duplicate then
    self:_send({ type = "completeApply", transactionId = transaction_id, outcome = duplicate })
    return
  end

  local pending = self.pending_actions[action_id]
  if not pending or pending.kind ~= "apply" then
    if not self.latest_snapshot then
      self:_fatal(engine_error("Refine requested Apply before a document was opened"))
      return
    end
    local outcome = {
      status = "rejected",
      reason = "staleRevision",
      snapshot = vim.deepcopy(self.latest_snapshot),
    }
    self.transaction_receipts[transaction_id] = outcome
    self.transaction_by_action[action_id] = transaction_id
    self:_send({ type = "completeApply", transactionId = transaction_id, outcome = outcome })
    return
  end
  if pending.transaction_id and pending.transaction_id ~= transaction_id then
    self:_fatal(engine_error("Refine changed transaction ID for an Apply action"))
    return
  end
  pending.transaction_id = transaction_id
  self.transaction_by_action[action_id] = transaction_id
  self.apply_lease_action_id = action_id

  local callback_used = false
  local function applied(err, outcome)
    if callback_used then
      return
    end
    callback_used = true
    if err then
      self:_fatal(host_error("WritingHost.apply failed outside its outcome contract", err))
      return
    end
    local valid, invalid = pcall(wire.validate_command, {
      type = "completeApply",
      transactionId = transaction_id,
      outcome = outcome,
    })
    if not valid then
      self:_fatal(host_error("WritingHost.apply returned an invalid outcome", invalid))
      return
    end

    self.transaction_receipts[transaction_id] = vim.deepcopy(outcome)
    local outcome_snapshot = outcome.snapshot
    local queued = self.queued_snapshot_during_apply
    local queued_after_outcome = queued and outcome_snapshot and queued.revision ~= outcome_snapshot.revision
    if
      outcome_snapshot
      and not queued_after_outcome
      and (not self.latest_snapshot or self.latest_snapshot.revision ~= outcome_snapshot.revision)
    then
      self:_accept_snapshot(outcome_snapshot)
    elseif outcome.status == "indeterminate" then
      self:_publish_state({ type = "pending" })
    end

    self:_send({ type = "completeApply", transactionId = transaction_id, outcome = outcome }, nil, function()
      self.apply_lease_action_id = nil
      local latest_queued = self.queued_snapshot_during_apply
      self.queued_snapshot_during_apply = nil
      if
        latest_queued
        and self.session
        and (not outcome_snapshot or latest_queued.revision ~= outcome_snapshot.revision)
        and self.latest_snapshot
        and latest_queued.revision == self.latest_snapshot.revision
      then
        self:_queue_replace(latest_queued)
      else
        self:_flush_attention()
        self:_send_pending_check()
      end
      if outcome.status == "indeterminate" and outcome.snapshot == nil then
        self:_restart_observation()
      end
    end)
  end
  local ok, call_error = pcall(self.host.apply, self.host, request, applied)
  if not ok then
    applied(call_error)
  end
end

function Run:_restart_observation()
  if self.detach_observer then
    pcall(self.detach_observer)
    self.detach_observer = nil
  end
  if self.running then
    self:_observe_host()
  end
end

function Run:_begin_action(pending)
  if pending.kind == "apply" then
    self:_send_action(pending)
    return
  end
  local callback_used = false
  local function validated(err, validation)
    if callback_used then
      return
    end
    callback_used = true
    if self.pending_actions[pending.id] ~= pending then
      return
    end
    if err then
      self:_fatal(host_error("WritingHost.validate_revision failed", err))
      self:_complete_pending(pending, { status = "unavailable", reason = "validationUnavailable" })
    elseif not validation or validation.status == "unavailable" then
      self:_complete_pending(pending, { status = "unavailable", reason = "validationUnavailable" })
    elseif validation.status == "stale" then
      self:_accept_snapshot(validation.snapshot)
      self:_complete_pending(pending, { status = "stale" })
    elseif validation.status == "current" then
      if not self:_live_suggestion(pending.base_presentation, pending.suggestion_id, pending.kind) then
        self:_complete_pending(pending, { status = "stale" })
      else
        self:_send_action(pending)
      end
    else
      self:_fatal(host_error("WritingHost returned an invalid revision validation"))
      self:_complete_pending(pending, { status = "unavailable", reason = "validationUnavailable" })
    end
  end
  local ok, call_error =
    pcall(self.host.validate_revision, self.host, pending.base_presentation.documentRevision, validated)
  if not ok then
    validated(call_error)
  end
end

function Run:_perform_action(presentation, suggestion_id, kind, callback)
  callback = callback or function() end
  local key = table.concat({ presentation.presentationRevision, suggestion_id, kind }, ":")
  local existing = self.action_by_key[key]
  if existing then
    existing.callbacks[#existing.callbacks + 1] = callback
    return
  end
  if not self.session or not self:_live_suggestion(presentation, suggestion_id, kind) then
    callback({ status = "stale" })
    return
  end
  local pending = {
    id = self.id_generator(),
    key = key,
    kind = kind,
    suggestion_id = suggestion_id,
    base_presentation = presentation,
    callbacks = { callback },
  }
  self.pending_actions[pending.id] = pending
  self.action_by_key[key] = pending
  self:_begin_action(pending)
end

function Run:_explain(presentation, suggestion_id, on_update, on_end)
  on_update = on_update or function() end
  on_end = on_end or function() end
  local cancelled = false
  local key = table.concat({ presentation.presentationRevision, suggestion_id, "explain" }, ":")
  if not self.session or not self:_live_suggestion(presentation, suggestion_id, "explain") then
    on_update({ status = "stale" })
    on_end()
    return function() end
  end
  local pending = {
    id = self.id_generator(),
    key = key,
    kind = "explain",
    suggestion_id = suggestion_id,
    base_presentation = presentation,
    callbacks = {},
    on_update = function(update)
      if not cancelled then
        on_update(vim.deepcopy(update))
      end
    end,
    on_end = function()
      if not cancelled then
        on_end()
      end
    end,
  }
  self.pending_actions[pending.id] = pending
  self.action_by_key[key] = pending
  self:_begin_action(pending)
  return function()
    if cancelled then
      return
    end
    cancelled = true
    if self.pending_actions[pending.id] == pending then
      self.pending_actions[pending.id] = nil
      if self.action_by_key[key] == pending then
        self.action_by_key[key] = nil
      end
      if pending.command_id and self.action_by_command_id[pending.command_id] == pending.id then
        self.action_by_command_id[pending.command_id] = nil
      end
    end
  end
end

function Run:_drain_presentation()
  if self.presenting or self.queued_presentation == nil then
    return
  end
  local pending = self.queued_presentation
  self.queued_presentation = nil
  self.presenting = true
  local callback_used = false
  local function done(err)
    if callback_used then
      return
    end
    callback_used = true
    self.presenting = false
    if err then
      self:_fatal(host_error("WritingHost.present failed", err))
      return
    end
    self:_drain_presentation()
  end
  local ok, call_result = pcall(self.host.present, self.host, pending.snapshot, pending.actions, done)
  if not ok then
    done(call_result)
  elseif not callback_used then
    -- Neovim presentation is normally synchronous. Hosts may omit the
    -- completion callback; returning from present then commits the replacement.
    done(nil)
  end
end

function Run:_publish(snapshot)
  self.current_presentation = snapshot
  self.queued_presentation = { snapshot = snapshot, actions = self:_actions_for(snapshot) }
  self:_drain_presentation()
end

function Run:_publish_state(state, suggestions)
  local latest = self.latest_snapshot
  if not latest then
    return
  end
  self:_publish({
    documentRevision = latest.revision,
    presentationRevision = self:_next_presentation_revision(),
    checkGeneration = self.check_generation,
    appearance = vim.deepcopy(self.appearance),
    interaction = vim.deepcopy(self.interaction),
    state = state,
    suggestions = suggestions or {},
  })
end

function Run:_verify_snapshot(snapshot)
  local ok, validation_error = pcall(wire.validate_snapshot, snapshot, "host snapshot")
  if not ok then
    error(host_error("WritingHost emitted an invalid snapshot", validation_error), 0)
  end
  local current = self.latest_snapshot
  if current and current.revision == snapshot.revision then
    if not same_sources(current.sources, snapshot.sources) then
      error(host_error("WritingHost reused a revision for different source content"), 0)
    end
    return false
  end
  if self.retired_revisions[snapshot.revision] then
    error(host_error("WritingHost reused a retired revision"), 0)
  end
  if current then
    self.retired_revisions[current.revision] = true
  end
  return true
end

function Run:_accept_snapshot(snapshot)
  local ok, changed = pcall(self._verify_snapshot, self, snapshot)
  if not ok then
    self:_fatal(changed)
    return
  end
  if not changed then
    return
  end
  self.latest_snapshot = vim.deepcopy(snapshot)
  self.latest_attention = nil
  self.pending_attention = nil
  self.last_sent_attention = nil
  self.pending_check = nil
  self.current_check_id = nil
  self.current_check_lineage_id = nil
  self.retired_check_ids = {}
  self.retired_check_command_ids = {}
  self.check_lifecycles = {}
  self.check_lineages = {}
  self.resumable_check = nil
  self:_invalidate_actions({ status = "stale" }, self.apply_lease_action_id)
  self:_publish_state({ type = "pending" })

  if self.apply_lease_action_id then
    self.queued_snapshot_during_apply = self.latest_snapshot
  elseif self.session and self.document_opened then
    self:_queue_replace(self.latest_snapshot)
  else
    self:_connect()
  end
end

function Run:_flush_attention()
  local command = self.pending_attention
  if not command then
    return true
  end
  if not self.latest_snapshot or command.revision ~= self.latest_snapshot.revision then
    self.pending_attention = nil
    return true
  end
  if
    not self.session
    or not self.document_opened
    or self.opening_document
    or self.replace_in_flight
    or self.pending_replace ~= nil
    or self.apply_lease_action_id
  then
    return false
  end
  self.pending_attention = nil
  if vim.deep_equal(command, self.last_sent_attention) then
    return true
  end
  self.last_sent_attention = vim.deepcopy(command)
  self:_send(vim.deepcopy(command))
  return true
end

function Run:_schedule_attention_flush()
  if self.attention_flush_scheduled then
    return
  end
  self.attention_flush_scheduled = true
  self.schedule(function()
    self.attention_flush_scheduled = false
    if self.running then
      self:_flush_attention()
    end
  end)
end

function Run:_accept_attention(observation)
  if not self.latest_snapshot or observation.revision ~= self.latest_snapshot.revision then
    return
  end
  local command = {
    type = "updateAttention",
    revision = observation.revision,
    attention = vim.deepcopy(observation.attention),
  }
  local valid, validation_error = pcall(wire.validate_command, command)
  if not valid then
    self:_fatal(host_error("WritingHost emitted invalid writing attention", validation_error))
    return
  end
  self.latest_attention = command
  self.pending_attention = command
  self:_schedule_attention_flush()
end

function Run:_validate_check_observation(observation)
  if type(observation.revision) ~= "string" or observation.revision == "" then
    error(host_error("WritingHost emitted an invalid check revision"), 0)
  end
  if observation.intent ~= nil then
    local ok, validation_error = pcall(wire.validate_check_intent, observation.intent)
    if not ok then
      error(host_error("WritingHost emitted invalid check intent", validation_error), 0)
    end
    local valid_intent, reason = validation.check_intent(observation.intent, self.latest_snapshot)
    if not valid_intent then
      error(host_error("WritingHost emitted invalid check intent: " .. reason), 0)
    end
  end
end

function Run:_accept_check(observation)
  self:_flush_attention()
  local ok, validation_error = pcall(self._validate_check_observation, self, observation)
  if not ok then
    self:_fatal(validation_error)
    return
  end
  if not self.latest_snapshot or observation.revision ~= self.latest_snapshot.revision then
    return
  end
  local superseded = self.pending_check
  if superseded then
    if superseded.command_id then
      self.retired_check_command_ids[superseded.command_id] = true
    end
    if superseded.check_id then
      self.retired_check_ids[superseded.check_id] = true
    end
  end
  self.pending_check = {
    revision = observation.revision,
    intent = observation.intent and vim.deepcopy(observation.intent) or nil,
  }
  if self.session then
    self:_send_pending_check()
  end
end

function Run:_accept_observation(observation)
  if not self.running then
    return
  end
  if type(observation) ~= "table" then
    self:_fatal(host_error("WritingHost emitted a malformed observation"))
  elseif observation.type == "snapshot" then
    self:_flush_attention()
    self:_accept_snapshot(observation.snapshot)
  elseif observation.type == "attentionChanged" then
    self:_accept_attention(observation)
  elseif observation.type == "checkRequested" then
    self:_accept_check(observation)
  else
    self:_fatal(host_error("WritingHost emitted an unknown observation"))
  end
end

function Run:_observe_host()
  local waiting_for_first_snapshot = true
  local ok, detach_or_error = pcall(self.host.observe, self.host, function(observation)
    if waiting_for_first_snapshot then
      waiting_for_first_snapshot = false
      if type(observation) ~= "table" or observation.type ~= "snapshot" then
        self:_fatal(host_error("WritingHost must emit a current snapshot first"))
        return
      end
    end
    self:_accept_observation(observation)
  end, function(err)
    if not self.running then
      return
    end
    if waiting_for_first_snapshot then
      self:_fatal(host_error("WritingHost closed without emitting a current snapshot"))
    elseif err then
      self:_fatal(host_error("WritingHost observation failed", err))
    else
      self:stop()
    end
  end)
  if not ok then
    self:_fatal(host_error("WritingHost.observe failed", detach_or_error))
    return
  end
  if detach_or_error ~= nil and type(detach_or_error) ~= "function" then
    self:_fatal(host_error("WritingHost.observe must return a detach function"))
    return
  end
  local detach = detach_or_error or function() end
  if self.running then
    self.detach_observer = detach
  else
    pcall(detach)
  end
end

function Run:_schedule_reconnect()
  if not self.running or self.connecting or self.reconnect_cancel then
    return
  end
  self.reconnect_cancel = self.delay(self.reconnect_delay_ms, function()
    self.reconnect_cancel = nil
    self:_connect()
  end)
end

function Run:_connect()
  if not self.running or self.connecting or self.session or not self.latest_snapshot then
    return
  end
  self.connecting = true
  self:_emit_state({ state = "connecting" })
  if not self.running then
    self.connecting = false
    return
  end
  local callback_used = false
  local function connected(err, session)
    if callback_used then
      if session and type(session.close) == "function" then
        pcall(session.close, session)
      end
      self:_fatal(engine_error("WritingCheckEnginePort.connect completed more than once"))
      return
    end
    callback_used = true
    self.connecting = false
    if not self.running then
      if session and type(session.close) == "function" then
        pcall(session.close, session)
      end
      return
    end
    if err then
      if errors.is_fatal(err) then
        self:_fatal(err)
      else
        self:_emit_state({ state = "disconnected", error = err })
        self:_publish_unavailable("disconnected")
        self:_schedule_reconnect()
      end
      return
    end
    if
      type(session) ~= "table"
      or type(session.server_epoch) ~= "string"
      or session.server_epoch == ""
      or type(session.run_resumed) ~= "boolean"
      or type(session.send) ~= "function"
      or type(session.events) ~= "function"
      or type(session.close) ~= "function"
    then
      self:_fatal(engine_error("WritingCheckEnginePort.connect returned an invalid session"))
      return
    end
    local retained_run = self.server_epoch == nil
      or (self.server_epoch == session.server_epoch and session.run_resumed == true)
    if not retained_run then
      self:_abandon_receipts()
      self.current_check_id = nil
      self.current_check_lineage_id = nil
      self.retired_check_ids = {}
      self.retired_check_command_ids = {}
      self.check_lifecycles = {}
      self.check_lineages = {}
      self.resumable_check = nil
    end
    self.server_epoch = session.server_epoch
    self.session = session
    self.document_opened = false
    self.opening_document = false
    self.replace_in_flight = false
    self.pending_replace = nil
    self.last_sent_attention = nil
    if
      self.latest_attention
      and self.latest_snapshot
      and self.latest_attention.revision == self.latest_snapshot.revision
    then
      self.pending_attention = vim.deepcopy(self.latest_attention)
    end
    self:_emit_state({ state = "connected" })
    local observing, observe_error = pcall(session.events, session, function(envelope)
      self:_accept_engine_event(envelope)
    end, function(stream_error)
      self:_disconnected(session, stream_error)
    end)
    if not observing then
      self:_fatal(engine_error("WritingCheckEnginePort session events failed", observe_error))
      return
    end
    if not self.running or self.session ~= session then
      return
    end
    self:_restore_receipts(function()
      self:_open_latest_snapshot()
    end)
  end
  local started, connect_error = pcall(self.engine_port.connect, self.engine_port, { run_id = self.run_id }, connected)
  if not started then
    self.connecting = false
    self:_fatal(engine_error("WritingCheckEnginePort.connect failed", connect_error))
  end
end

function Run:_restore_receipts(done)
  local transaction_ids = {}
  for transaction_id in pairs(self.transaction_receipts) do
    transaction_ids[#transaction_ids + 1] = transaction_id
  end
  table.sort(transaction_ids)
  local index = 1
  local function send_next()
    local transaction_id = transaction_ids[index]
    if not transaction_id then
      done()
      return
    end
    index = index + 1
    self:_send(
      {
        type = "completeApply",
        transactionId = transaction_id,
        outcome = self.transaction_receipts[transaction_id],
      },
      nil,
      function(err)
        if not err then
          send_next()
        end
      end
    )
  end
  send_next()
end

function Run:_abandon_receipts()
  local pending = {}
  for action_id in pairs(self.transaction_by_action) do
    local action = self.pending_actions[action_id]
    if action then
      pending[#pending + 1] = action
    end
  end
  for _, action in ipairs(pending) do
    self:_complete_pending(action, { status = "unavailable", reason = "disconnected" })
  end
  self.transaction_receipts = {}
  self.transaction_by_action = {}
end

function Run:_send(command, command_id, callback)
  local session = self.session
  if not session then
    if callback then
      callback(errors.new("EngineConnectionError", "Refine is disconnected", "recoverable"))
    end
    return
  end
  local callback_used = false
  local function sent(err, receipt)
    if callback_used then
      return
    end
    callback_used = true
    if err then
      self:_disconnected(session, err)
      if callback then
        callback(err)
      end
      return
    end
    if callback then
      callback(nil, receipt)
    end
  end
  local ok, send_error = pcall(session.send, session, command, command_id, sent)
  if not ok then
    sent(engine_error("WritingCheckEnginePort session send failed", send_error))
  end
end

function Run:_open_latest_snapshot()
  if not self.session or not self.latest_snapshot or self.opening_document then
    return
  end
  self.document_opened = false
  self.opening_document = true
  local session = self.session
  local opened_snapshot = self.latest_snapshot
  local command_id = self.id_generator()
  self.open_command_id = command_id
  self:_send({ type = "openDocument", snapshot = opened_snapshot }, command_id, function(err)
    if self.session ~= session then
      return
    end
    self.opening_document = false
    if not err then
      self.document_opened = true
      if self.latest_snapshot.revision ~= opened_snapshot.revision then
        self:_queue_replace(self.latest_snapshot)
      else
        self:_flush_attention()
        self:_send_pending_check()
      end
    end
  end)
end

function Run:_queue_replace(snapshot)
  if not self.session or not self.document_opened then
    return
  end
  if self.replace_in_flight then
    self.pending_replace = snapshot
    return
  end
  self.replace_in_flight = true
  local replacing = snapshot
  self:_send({ type = "replaceDocument", snapshot = replacing }, nil, function()
    self.replace_in_flight = false
    local pending = self.pending_replace
    self.pending_replace = nil
    if pending and self.session and self.document_opened then
      self:_queue_replace(pending)
    else
      self:_flush_attention()
      self:_send_pending_check()
    end
  end)
  if self.pending_replace == nil and self.latest_snapshot.revision == replacing.revision then
    self:_send_pending_check()
  end
end

function Run:_send_pending_check()
  local pending = self.pending_check
  if
    not pending
    or pending.command_id
    or not self.session
    or not self.document_opened
    or self.apply_lease_action_id
    or self.replace_in_flight
    or self.pending_replace ~= nil
    or pending.revision ~= self.latest_snapshot.revision
  then
    return
  end
  if not self:_flush_attention() then
    return
  end
  local command_id = self.id_generator()
  pending.command_id = command_id
  local command = { type = "requestCheck", revision = pending.revision }
  if pending.intent then
    command.intent = vim.deepcopy(pending.intent)
  end
  self:_send(command, command_id, function(err)
    if err and self.pending_check == pending then
      pending.command_id = nil
    end
  end)
end

function Run:_accept_presentation(event, cause_command_id)
  local content = event.content
  if not self.latest_snapshot or content.documentRevision ~= self.latest_snapshot.revision then
    return
  end
  if self.retired_check_ids[event.checkId] then
    return
  end
  if cause_command_id and self.retired_check_command_ids[cause_command_id] then
    self.retired_check_ids[event.checkId] = true
    return
  end
  local valid_content, invalid_reason = validation.presentation(content, self.latest_snapshot)
  if not valid_content then
    self:_fatal(engine_error("Refine published invalid presentation content: " .. invalid_reason))
    return
  end
  local lifecycle = self.check_lifecycles[event.checkId]
  if lifecycle and lifecycle.document_revision ~= content.documentRevision then
    self:_fatal(engine_error("Refine reused a check ID for a different document revision"))
    return
  end
  if not lifecycle then
    lifecycle = {
      document_revision = content.documentRevision,
      checking_started = false,
      completed = false,
      closed = false,
      progress = nil,
    }
    self.check_lifecycles[event.checkId] = lifecycle
  end
  if lifecycle.closed and content.status ~= "closed" then
    self:_fatal(engine_error("Refine regressed a check after its terminal presentation"))
    return
  end
  if lifecycle.completed and content.status ~= "complete" and content.status ~= "unavailable" then
    self:_fatal(engine_error("Refine regressed a check after its terminal presentation"))
    return
  end
  if content.status == "checking" then
    lifecycle.checking_started = true
    if content.progress == nil and lifecycle.progress ~= nil then
      self:_fatal(engine_error("Refine removed determinate progress from an active check"))
      return
    elseif content.progress ~= nil and lifecycle.progress ~= nil then
      if lifecycle.progress.totalUnitCount ~= content.progress.totalUnitCount then
        self:_fatal(engine_error("Refine changed the total progress count for an active check"))
        return
      end
      if lifecycle.progress.completedUnitCount > content.progress.completedUnitCount then
        self:_fatal(engine_error("Refine decreased completed progress for an active check"))
        return
      end
    end
    lifecycle.progress = content.progress and vim.deepcopy(content.progress) or nil
  elseif content.status == "pending" and lifecycle.checking_started then
    self:_fatal(engine_error("Refine returned an active check to pending"))
    return
  elseif content.status == "complete" then
    lifecycle.completed = true
  elseif content.status == "closed" then
    lifecycle.closed = true
  end
  if content.status == "pending" or content.status == "unavailable" or content.status == "closed" then
    local invalidated = {}
    for _, action in pairs(self.pending_actions) do
      if not action.transaction_id then
        invalidated[#invalidated + 1] = action
      end
    end
    for _, action in ipairs(invalidated) do
      self:_complete_pending(action, { status = "stale" })
    end
  end

  local pending = self.pending_check
  local caused_by_pending = pending and pending.command_id == cause_command_id
  local caused_action_id = cause_command_id and self.action_by_command_id[cause_command_id] or nil
  local caused_action = caused_action_id and self.pending_actions[caused_action_id] or nil
  local dismiss_rematerialization = caused_action
    and caused_action.kind == "dismiss"
    and self.current_check_id ~= nil
    and self.current_check_id ~= event.checkId
  local returning_to_resumable = self.resumable_check
    and self.resumable_check.check_id == event.checkId
    and self.current_check_id ~= event.checkId
  local replaying_retained_check = not caused_by_pending
    and cause_command_id == self.open_command_id
    and self.current_check_id ~= nil
    and self.current_check_id ~= event.checkId
  if dismiss_rematerialization then
    local lineage = self.current_check_lineage_id or self.current_check_id
    self.resumable_check = {
      check_id = self.current_check_id,
      terminal_owner = event.checkId,
      lineage = lineage,
    }
    self.check_lineages[event.checkId] = lineage
  elseif returning_to_resumable then
    self.check_lineages[event.checkId] = self.resumable_check.lineage
  elseif replaying_retained_check then
    self.check_lineages[event.checkId] = self.current_check_lineage_id or self.current_check_id
  end
  if self.current_check_id ~= event.checkId then
    if self.current_check_id then
      if dismiss_rematerialization then
        -- The action-caused presentation temporarily owns the engine stream,
        -- while the active check remains resumable under its original ID.
      elseif returning_to_resumable then
        self.retired_check_ids[self.current_check_id] = true
        self.resumable_check = nil
      elseif replaying_retained_check then
        self.retired_check_ids[self.current_check_id] = true
        if self.resumable_check then
          self.resumable_check.terminal_owner = event.checkId
        end
      else
        self.retired_check_ids[self.current_check_id] = true
        if self.resumable_check then
          self.retired_check_ids[self.resumable_check.check_id] = true
          self.resumable_check = nil
        end
        self:_invalidate_actions({ status = "stale" }, self.apply_lease_action_id, caused_action_id)
      end
    end
    self.current_check_id = event.checkId
  end
  if caused_by_pending then
    pending.check_id = event.checkId
  end

  local lineage_id = self.check_lineages[event.checkId] or event.checkId
  if content.status ~= "pending" and content.status ~= "closed" then
    if self.current_check_lineage_id ~= lineage_id then
      self.check_generation = self.check_generation + 1
      self.current_check_lineage_id = lineage_id
    end
  end
  if
    pending
    and pending.check_id == event.checkId
    and (content.status == "complete" or content.status == "unavailable")
  then
    self.pending_check = nil
  end

  self.appearance = vim.deepcopy(content.appearance)
  self.interaction = vim.deepcopy(content.interaction)
  local suggestions = vim.deepcopy(content.suggestions)
  for _, action in pairs(self.pending_actions) do
    if action.base_presentation.documentRevision == content.documentRevision then
      for _, suggestion in ipairs(suggestions) do
        if suggestion.id == action.suggestion_id then
          local available = {}
          for _, kind in ipairs(suggestion.availableActions) do
            if kind ~= action.kind then
              available[#available + 1] = kind
            end
          end
          suggestion.availableActions = available
        end
      end
    end
  end
  self:_publish({
    documentRevision = content.documentRevision,
    presentationRevision = self:_next_presentation_revision(),
    checkGeneration = self.check_generation,
    appearance = vim.deepcopy(self.appearance),
    interaction = vim.deepcopy(self.interaction),
    state = state_from_content(content),
    suggestions = suggestions,
  })
end

function Run:_accept_engine_event(envelope)
  if not self.running or not self.session then
    return
  end
  local valid, invalid = pcall(wire.decode_event, envelope)
  if not valid then
    self:_fatal(engine_error("Refine published a malformed event", invalid))
    return
  end
  local event = envelope.event
  if event.type == "documentAccepted" then
    return
  elseif event.type == "resyncRequired" then
    if event.reason == "documentNotOpen" then
      self.document_opened = false
      self:_open_latest_snapshot()
    else
      self:_fatal(engine_error("Refine rejected the authoritative document: " .. event.reason))
    end
  elseif event.type == "presentationContentReplaced" then
    self:_accept_presentation(event, envelope.causeCommandId)
  elseif event.type == "applyRequested" then
    self:_complete_host_apply(event.actionId, event.transactionId, event.request)
  elseif event.type == "explanationReplaced" then
    local pending = self.pending_actions[event.actionId]
    if pending and pending.kind == "explain" then
      local terminal = event.update.status == "completed"
        or event.update.status == "stale"
        or event.update.status == "unavailable"
      if terminal then
        self:_finish_explanation(pending, event.update)
      else
        pending.on_update(vim.deepcopy(event.update))
      end
    end
  elseif event.type == "actionCompleted" then
    local transaction_id = self.transaction_by_action[event.actionId]
    if transaction_id then
      self.transaction_by_action[event.actionId] = nil
      self.transaction_receipts[transaction_id] = nil
    end
    local pending = self.pending_actions[event.actionId]
    if pending then
      self:_complete_pending(pending, { status = "completed" })
    end
  elseif event.type == "actionRejected" then
    local pending = self.pending_actions[event.actionId]
    if pending then
      local outcome
      if event.reason == "stale" then
        outcome = { status = "stale" }
      elseif event.reason == "unsupportedAction" then
        outcome = { status = "unavailable", reason = "engineUnavailable" }
      else
        outcome = { status = "unavailable", reason = event.reason }
      end
      self:_complete_pending(pending, outcome)
    end
  elseif event.type == "fault" and event.fatal then
    self:_fatal(engine_error("Refine engine fault: " .. event.code))
  elseif event.type == "fault" and event.code == "engineUnavailable" then
    self:_publish_unavailable("engineUnavailable")
  end
end

function Run:_invalidate_actions(outcome, ...)
  local kept = {}
  for index = 1, select("#", ...) do
    local action_id = select(index, ...)
    if action_id ~= nil then
      kept[action_id] = true
    end
  end
  local pending = {}
  for _, action in pairs(self.pending_actions) do
    pending[#pending + 1] = action
  end
  for _, action in ipairs(pending) do
    if not kept[action.id] then
      self:_complete_pending(action, outcome)
    end
  end
end

function Run:_publish_unavailable(reason)
  if self.latest_snapshot then
    local invalidated = {}
    for _, action in pairs(self.pending_actions) do
      if not action.transaction_id then
        invalidated[#invalidated + 1] = action
      end
    end
    for _, action in ipairs(invalidated) do
      self:_complete_pending(action, { status = "unavailable", reason = reason })
    end
    self:_publish_state({ type = "unavailable", reason = reason })
  end
end

function Run:_disconnected(session, err)
  if self.session ~= session or not self.running then
    return
  end
  self.session = nil
  self.document_opened = false
  self.opening_document = false
  self.replace_in_flight = false
  self.pending_replace = nil
  if self.pending_check then
    self.pending_check.command_id = nil
    self.pending_check.check_id = nil
  end
  pcall(session.close, session)
  if err and errors.is_fatal(err) then
    self:_fatal(err)
    return
  end
  local invalidated = {}
  for _, action in pairs(self.pending_actions) do
    if not action.transaction_id then
      invalidated[#invalidated + 1] = action
    end
  end
  for _, action in ipairs(invalidated) do
    self:_complete_pending(action, { status = "unavailable", reason = "disconnected" })
  end
  self:_emit_state({ state = "disconnected", error = err })
  self:_publish_unavailable("disconnected")
  self:_schedule_reconnect()
end

function Run:_fatal(err)
  if not self.running then
    return
  end
  pcall(self.on_error, errors.redact(err, "Refine integration failed"))
  self:stop(err)
end

function Run:stop(failure)
  if not self.running then
    return
  end
  self.running = false
  self:_invalidate_actions({ status = "stale" })
  self.transaction_receipts = {}
  self.transaction_by_action = {}
  if self.reconnect_cancel then
    self.reconnect_cancel()
    self.reconnect_cancel = nil
  end
  if self.detach_observer then
    pcall(self.detach_observer)
    self.detach_observer = nil
  end
  local session = self.session
  self.session = nil
  if session then
    local closed = false
    local function close_session()
      if closed then
        return
      end
      closed = true
      pcall(session.close, session)
    end
    local sent = pcall(session.send, session, { type = "closeDocument" }, nil, close_session)
    if not sent then
      close_session()
    end
  end
  if self.latest_snapshot then
    if failure then
      self:_publish_unavailable("disconnected")
    end
    self:_publish_state({ type = "closed" })
  end
  if not self.stopped_state_emitted then
    self.stopped_state_emitted = true
    local state = { state = "stopped" }
    if failure ~= nil then
      state.error = failure
    end
    self:_emit_state(state)
  end
end

function Run:is_running()
  return self.running
end

function M.new(options)
  options = options or {}
  if type(options.engine_port) ~= "table" or type(options.engine_port.connect) ~= "function" then
    error("refine.integration requires an engine_port")
  end
  local integration = { options = options }

  function integration:run(input)
    if type(input) ~= "table" or type(input.host) ~= "table" then
      error("refine.integration.run requires a host")
    end
    local run = Run.new(self.options, input)
    run:_observe_host()
    return {
      stop = function()
        run:stop()
      end,
      is_running = function()
        return run:is_running()
      end,
    }
  end

  return integration
end

return M
