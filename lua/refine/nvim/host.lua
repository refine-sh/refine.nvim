local apply = require("refine.nvim.apply")
local presentation_module = require("refine.nvim.presentation")
local source_module = require("refine.nvim.source")

local Host = {}
Host.__index = Host

function Host:_emit_snapshot_if_changed()
  if not self.active then
    return
  end
  local snapshot = self.source:snapshot()
  if snapshot.revision == self.last_emitted_revision then
    return
  end
  self.last_emitted_revision = snapshot.revision
  self.emit({ type = "snapshot", snapshot = snapshot })
end

function Host:_schedule_refresh()
  if self.refresh_scheduled then
    return
  end
  self.refresh_scheduled = true
  vim.schedule(function()
    self.refresh_scheduled = false
    self:_emit_snapshot_if_changed()
  end)
end

function Host:observe(emit, on_end)
  if self.active then
    error("refine.nvim: host observation already active", 2)
  end
  self.active = true
  self.emit = emit
  self.on_end = on_end

  local attached = vim.api.nvim_buf_attach(self.bufnr, false, {
    on_lines = function()
      self.presentation:clear()
      self.on_presentation({ state = { type = "pending" }, suggestions = {} })
      self.on_native_change()
      self:_schedule_refresh()
    end,
    on_reload = function()
      self.presentation:clear()
      self.on_presentation({ state = { type = "pending" }, suggestions = {} })
      self.on_native_change()
      self:_schedule_refresh()
    end,
    on_detach = function()
      if not self.active then
        return
      end
      self.active = false
      self.on_end()
    end,
  })
  if not attached then
    self.active = false
    error("refine.nvim: unable to observe buffer", 2)
  end

  self:_emit_snapshot_if_changed()

  return function()
    if not self.active then
      return
    end
    self.active = false
    pcall(vim.api.nvim_buf_detach, self.bufnr)
  end
end

function Host:request_check(intent)
  if not self.active then
    return false
  end
  self:_emit_snapshot_if_changed()
  self.emit({
    type = "checkRequested",
    revision = self.last_emitted_revision,
    intent = intent,
  })
  return true, self.last_emitted_revision
end

function Host:set_source_syntax(source_syntax)
  self.source:set_source_syntax(source_syntax)
  self.presentation:clear()
  self.on_presentation({ state = { type = "pending" }, suggestions = {} })
  self:_emit_snapshot_if_changed()
end

function Host:validate_revision(revision, callback)
  local snapshot = self.source:snapshot()
  if snapshot.revision == revision then
    callback(nil, { status = "current" })
  else
    callback(nil, { status = "stale", snapshot = snapshot })
  end
end

function Host:apply(request, callback)
  self.presentation:clear()
  local ok, outcome = pcall(apply.apply, self.source, request)
  if not ok then
    callback(outcome)
    return
  end
  callback(nil, outcome)
end

function Host:present(snapshot, actions, callback)
  callback = callback or function() end
  if snapshot.documentRevision ~= self.source:snapshot().revision then
    self.presentation:clear()
    callback(nil)
    return
  end
  local ok, err = pcall(self.presentation.replace, self.presentation, snapshot, actions)
  if ok then
    self.on_presentation(snapshot)
  end
  callback(ok and nil or err)
end

function Host:show()
  return self.presentation:show()
end

function Host:close()
  self.presentation:close()
end

function Host:suspend_view()
  self.presentation:suspend_view()
end

function Host:reconcile_view()
  self.presentation:reconcile_view()
end

function Host:refresh_view()
  return self.presentation:refresh_view()
end

function Host:refresh_highlights()
  self.presentation:refresh_highlights()
end

function Host:deactivate()
  self.presentation:clear()
end

function Host:owns_window(winid)
  return self.presentation:card_window() == winid
end

function Host:action(kind)
  return self.presentation:action(kind)
end

function Host:next()
  return self.presentation:next()
end

function Host:previous()
  return self.presentation:previous()
end

local M = {}

function M.new(options)
  local source = source_module.new({
    bufnr = options.bufnr,
    run_id = options.run_id,
    source_syntax = options.source_syntax,
  })

  return setmetatable({
    active = false,
    bufnr = options.bufnr,
    refresh_scheduled = false,
    presentation = presentation_module.new(options.bufnr),
    on_presentation = options.on_presentation or function() end,
    on_native_change = options.on_native_change or function() end,
    source = source,
  }, Host)
end

return M
