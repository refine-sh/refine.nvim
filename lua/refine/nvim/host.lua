local apply = require("refine.nvim.apply")
local coordinates_module = require("refine.nvim.coordinates")
local presentation_module = require("refine.nvim.presentation")
local source_module = require("refine.nvim.source")

local Host = {}
Host.__index = Host

local next_attention_group = 0

local selection_modes = {
  v = true,
  V = true,
  s = true,
  S = true,
  [string.char(22)] = true,
  [string.char(19)] = true,
}

local function source_range(first, last, lines, coordinates)
  local start_offset = coordinates:utf16_offset(first - 1, 0)
  local end_offset
  if last < #lines then
    end_offset = coordinates:utf16_offset(last, 0)
  else
    end_offset = coordinates:utf16_offset(last - 1, #lines[last])
  end
  if end_offset == start_offset then
    return nil
  end
  return { location = start_offset, length = end_offset - start_offset }
end

local function active_window_ranges(winid, lines, coordinates)
  return vim.api.nvim_win_call(winid, function()
    local first = vim.fn.line("w0")
    local last = vim.fn.line("w$")
    local ranges = {}
    local run_first
    local run_last
    local function append_visible_line(line)
      if run_last == nil or line == run_last + 1 then
        run_first = run_first or line
        run_last = line
        return
      end
      local range = source_range(run_first, run_last, lines, coordinates)
      if range then
        ranges[#ranges + 1] = range
      end
      run_first = line
      run_last = line
    end
    local line = first
    while line <= last do
      local fold_start = vim.fn.foldclosed(line)
      if fold_start == -1 then
        append_visible_line(line)
        line = line + 1
      else
        if fold_start == line then
          append_visible_line(line)
        end
        line = math.max(line + 1, vim.fn.foldclosedend(line) + 1)
      end
    end
    if run_first then
      local range = source_range(run_first, run_last, lines, coordinates)
      if range then
        ranges[#ranges + 1] = range
      end
    end
    return ranges
  end)
end

local function has_single_collapsed_caret(winid)
  return vim.api.nvim_win_call(winid, function()
    return not selection_modes[vim.fn.mode(1):sub(1, 1)]
  end)
end

function Host:_attention_source()
  local cached = self.attention_source
  if cached and cached.revision == self.last_emitted_revision then
    return cached.lines, cached.coordinates
  end
  local lines = vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, true)
  local coordinates = coordinates_module.new(lines)
  self.attention_source = {
    revision = self.last_emitted_revision,
    lines = lines,
    coordinates = coordinates,
  }
  return lines, coordinates
end

function Host:_current_attention()
  if
    self.attention_suspended
    or not self.winid
    or not vim.api.nvim_win_is_valid(self.winid)
    or vim.api.nvim_win_get_buf(self.winid) ~= self.bufnr
  then
    return nil
  end
  local lines, coordinates = self:_attention_source()
  local cursor = vim.api.nvim_win_get_cursor(self.winid)
  local attention = {
    sourceId = "document",
    visibleRanges = active_window_ranges(self.winid, lines, coordinates),
  }
  if has_single_collapsed_caret(self.winid) then
    attention.caretOffset = coordinates:utf16_offset(cursor[1] - 1, cursor[2])
  end
  return attention
end

function Host:_emit_attention_if_changed()
  if not self.active or not self.last_emitted_revision then
    return
  end
  local attention = self:_current_attention()
  if not attention then
    return
  end
  local observation = {
    type = "attentionChanged",
    revision = self.last_emitted_revision,
    attention = attention,
  }
  if vim.deep_equal(observation, self.last_emitted_attention) then
    return
  end
  self.last_emitted_attention = vim.deepcopy(observation)
  self.emit(observation)
end

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

function Host:_emit_current_observation()
  self.refresh_needs_snapshot = false
  self:_emit_snapshot_if_changed()
  self:_emit_attention_if_changed()
end

function Host:_schedule_refresh(source_may_have_changed)
  if source_may_have_changed then
    self.refresh_needs_snapshot = true
  end
  if self.refresh_scheduled then
    return
  end
  self.refresh_scheduled = true
  vim.schedule(function()
    self.refresh_scheduled = false
    if self.refresh_needs_snapshot then
      self:_emit_current_observation()
    else
      self:_emit_attention_if_changed()
    end
  end)
end

function Host:_clear_attention_events()
  if not self.attention_group then
    return
  end
  pcall(vim.api.nvim_del_augroup_by_id, self.attention_group)
  self.attention_group = nil
end

function Host:_observe_attention_events()
  next_attention_group = next_attention_group + 1
  self.attention_group =
    vim.api.nvim_create_augroup("RefineNvimHostAttention" .. next_attention_group, { clear = true })
  local function changed()
    if
      self.active
      and not self.attention_suspended
      and vim.api.nvim_get_current_win() == self.winid
      and vim.api.nvim_get_current_buf() == self.bufnr
    then
      self:_schedule_refresh()
    end
  end
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = self.attention_group,
    buffer = self.bufnr,
    callback = changed,
  })
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = self.attention_group,
    callback = changed,
  })
end

function Host:observe(emit, on_end)
  if self.active then
    error("refine.nvim: host observation already active", 2)
  end
  self.active = true
  self.emit = emit
  self.on_end = on_end
  self.last_emitted_revision = nil
  self.last_emitted_attention = nil

  local attached = vim.api.nvim_buf_attach(self.bufnr, false, {
    on_lines = function()
      self.source:invalidate()
      self.presentation:clear()
      self.on_presentation({ state = { type = "pending" }, suggestions = {} })
      self.on_native_change()
      self:_schedule_refresh(true)
    end,
    on_reload = function()
      self.source:invalidate()
      self.presentation:clear()
      self.on_presentation({ state = { type = "pending" }, suggestions = {} })
      self.on_native_change()
      self:_schedule_refresh(true)
    end,
    on_detach = function()
      if not self.active then
        return
      end
      self.active = false
      self:_clear_attention_events()
      self.on_end()
    end,
  })
  if not attached then
    self.active = false
    error("refine.nvim: unable to observe buffer", 2)
  end

  self:_observe_attention_events()
  self:_emit_current_observation()

  return function()
    if not self.active then
      return
    end
    self.active = false
    self:_clear_attention_events()
    pcall(vim.api.nvim_buf_detach, self.bufnr)
  end
end

function Host:request_check(intent)
  if not self.active then
    return false
  end
  self:_emit_current_observation()
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
  self:_emit_current_observation()
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
  self.attention_suspended = true
  self.presentation:suspend_view()
end

function Host:reconcile_view(winid)
  self.winid = winid or self.winid
  self.attention_suspended = false
  local reconciled = self.presentation:reconcile_view()
  self:_schedule_refresh()
  return reconciled
end

function Host:refresh_view()
  local refreshed = self.presentation:refresh_view()
  self:_schedule_refresh()
  return refreshed
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
    attention_suspended = false,
    bufnr = options.bufnr,
    refresh_needs_snapshot = false,
    winid = options.winid or vim.api.nvim_get_current_win(),
    refresh_scheduled = false,
    presentation = presentation_module.new(options.bufnr),
    on_presentation = options.on_presentation or function() end,
    on_native_change = options.on_native_change or function() end,
    source = source,
  }, Host)
end

return M
