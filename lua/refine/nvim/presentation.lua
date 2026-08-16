local coordinates = require("refine.nvim.coordinates")
local mappings = require("refine.nvim.mappings")

local namespace = vim.api.nvim_create_namespace("refine.nvim")
local activation_namespace = vim.api.nvim_create_namespace("refine.nvim.activation")
local card_namespace = vim.api.nvim_create_namespace("refine.nvim.card")

local Presentation = {}
Presentation.__index = Presentation

local kind_priority = { grammar = 1, mixed = 2, fluency = 3 }
local action_keys = {
  delete = "<BS>",
  downArrow = "<Down>",
  escape = "<Esc>",
  leftArrow = "<Left>",
  ["return"] = "<CR>",
  rightArrow = "<Right>",
  space = "<Space>",
  tab = "<Tab>",
  upArrow = "<Up>",
}
local card_control_aliases = {
  ["<Tab>"] = "<C-I>",
  ["<Esc>"] = "<C-[>",
  ["<CR>"] = "<C-M>",
}
local key_labels = {
  delete = "Backspace",
  downArrow = "Down",
  escape = "Esc",
  leftArrow = "Left",
  ["return"] = "Enter",
  rightArrow = "Right",
  space = "Space",
  tab = "Tab",
  upArrow = "Up",
}

local function quick_action_tip(key, action)
  local label = key_labels[key]
  if label then
    return ("[%s] %s"):format(label, action)
  end
  return action .. " shortcut unavailable"
end

local function action_key_label(key)
  local label = key_labels[key]
  if label then
    return label
  end
  local words = key:gsub("(%l)(%u)", "%1 %2")
  return (words:gsub("^%l", string.upper))
end

local left_mouse = vim.keycode("<LeftMouse>")
local card_actions = {
  { kind = "apply", key = "a", label = "Apply" },
  { kind = "dismiss", key = "d", label = "Dismiss" },
  { kind = "explain", key = "e", label = "Explain" },
  { kind = "report", key = "r", label = "Report" },
}
local action_labels = {
  apply = "Apply",
  dismiss = "Dismiss",
  explain = "Explain",
  report = "Report",
}
local combining_long_stroke = vim.fn.nr2char(0x0336)
local maximum_midline_graphemes = 4096

local function notify_action_failure(kind, status, reason)
  local label = action_labels[kind] or "Action"
  local message
  if status == "stale" then
    message = ("Refine %s could not complete because the suggestion changed. Run :RefineCheck and try again."):format(
      label
    )
  elseif status == "unavailable" then
    message = ("Refine %s is unavailable (%s). Review :RefineStatus or :checkhealth refine, then try again."):format(
      label,
      tostring(reason or "unknown")
    )
  else
    message = ("Refine %s failed. Review :checkhealth refine and try again."):format(label)
  end
  pcall(vim.notify, message, vim.log.levels.WARN, { title = "Refine" })
end

local function color_number(value)
  return tonumber(value:sub(2), 16)
end

local function highlight_attributes(style, color)
  if style == "highlight" then
    return { bg = color_number(color) }
  elseif style == "dashedUnderline" then
    return { sp = color_number(color), underdashed = true }
  end
  return { sp = color_number(color), underline = true }
end

local function define_highlights(appearance)
  local style = appearance.highlight.style
  vim.api.nvim_set_hl(0, "RefineGrammar", highlight_attributes(style, appearance.highlight.grammarColor))
  vim.api.nvim_set_hl(0, "RefineFluency", highlight_attributes(style, appearance.highlight.fluencyColor))
  vim.api.nvim_set_hl(0, "RefineAddition", { fg = color_number(appearance.diff.additionColor), bold = true })
  vim.api.nvim_set_hl(0, "RefineDeletion", {
    fg = color_number(appearance.diff.deletionColor),
    strikethrough = true,
  })
end

local function define_active_highlight()
  vim.api.nvim_set_hl(0, "RefineActive", { bold = true, underline = true })
end

function Presentation:clear()
  self:close(false)
  self:_clear_activation()
  self:_remove_mouse_observer()
  if vim.api.nvim_buf_is_valid(self.bufnr) then
    vim.api.nvim_buf_clear_namespace(self.bufnr, namespace, 0, -1)
  end
  self.snapshot = nil
  self.actions = nil
end

local function candidate_before(left, right)
  if left.activationRange.length ~= right.activationRange.length then
    return left.activationRange.length < right.activationRange.length
  end
  if kind_priority[left.kind] ~= kind_priority[right.kind] then
    return kind_priority[left.kind] < kind_priority[right.kind]
  end
  if left.activationRange.location ~= right.activationRange.location then
    return left.activationRange.location < right.activationRange.location
  end
  return left.id < right.id
end

local function has_action(suggestion, kind)
  for _, available in ipairs(suggestion.availableActions) do
    if available == kind then
      return true
    end
  end
  return false
end

function Presentation:_suggestion_under_cursor(winid)
  if not self.snapshot or not vim.api.nvim_win_is_valid(winid) then
    return nil
  end
  local cursor = vim.api.nvim_win_get_cursor(winid)
  local index = coordinates.new(vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, true))
  local ok, offset = pcall(index.utf16_offset, index, cursor[1] - 1, cursor[2])
  if not ok then
    return nil
  end

  local candidates = {}
  for _, suggestion in ipairs(self.snapshot.suggestions) do
    local range = suggestion.activationRange
    local contains = range.length == 0 and offset == range.location
      or (offset >= range.location and offset <= range.location + range.length)
    if contains then
      candidates[#candidates + 1] = suggestion
    end
  end
  table.sort(candidates, candidate_before)
  return candidates[1]
end

local function visible_whitespace(text)
  return text:gsub("\t", "→"):gsub(" ", "·")
end

local function add_deletion_midlines(midlines, row, start_col, text, remaining)
  local byte_col = start_col
  local prefix = vim.fn.strcharpart(text, 0, remaining, true)
  for _, grapheme in ipairs(vim.fn.split(prefix, "\\zs")) do
    if grapheme ~= "\t" then
      midlines[#midlines + 1] = {
        row = row,
        col = byte_col,
        text = grapheme .. combining_long_stroke,
      }
    end
    byte_col = byte_col + #grapheme
    remaining = remaining - 1
  end
  return remaining
end

local function card_content(suggestion, feedback, interaction, appearance, focused)
  local lines = {
    ("%s · %s"):format(suggestion.attribution.languageDisplayName, suggestion.attribution.checkModelDisplayName),
    "",
  }
  local highlights = {}
  local midlines = {}
  local remaining_midlines = maximum_midline_graphemes
  local body_started = false
  for _, run in ipairs(suggestion.diff) do
    if run.text ~= "" or run.kind ~= "unchanged" then
      local group = run.kind == "delete" and "RefineDeletion" or run.kind == "insert" and "RefineAddition" or nil
      local parts = vim.split(run.text, "\n", { plain = true, trimempty = false })
      for index, part in ipairs(parts) do
        if not body_started or index > 1 then
          lines[#lines + 1] = ""
          body_started = true
        end
        if group and appearance.diff.showHiddenWhitespace then
          part = visible_whitespace(part)
          if index < #parts then
            part = part .. "↵"
          end
        end
        local start_col = #lines[#lines]
        lines[#lines] = lines[#lines] .. part
        if group and part ~= "" then
          if run.kind == "delete" then
            remaining_midlines = add_deletion_midlines(midlines, #lines - 1, start_col, part, remaining_midlines)
          end
          highlights[#highlights + 1] = {
            row = #lines - 1,
            start_col = start_col,
            end_col = #lines[#lines],
            group = group,
          }
        end
      end
    end
  end
  if feedback then
    lines[#lines + 1] = ""
    for _, line in ipairs(feedback) do
      lines[#lines + 1] = line
    end
  end
  local quick = interaction and interaction.quickApply
  if quick then
    local can_apply = has_action(suggestion, "apply")
    local can_dismiss = has_action(suggestion, "dismiss")
    if can_apply and can_dismiss and quick.applyKey == quick.dismissKey then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "Configured Apply and Dismiss keys conflict; use [a] or [d]."
    end
    if can_apply and not action_keys[quick.applyKey] then
      lines[#lines + 1] = ""
      lines[#lines + 1] = ("%s cannot be intercepted by Neovim."):format(action_key_label(quick.applyKey))
      lines[#lines + 1] = "Configure another Apply key in Refine, or add a Neovim mapping:"
      lines[#lines + 1] = 'vim.keymap.set("n", "<leader>ra", "<Plug>(RefineApply)")'
    end
    if can_dismiss and not action_keys[quick.dismissKey] then
      lines[#lines + 1] = "Configured Dismiss key is unavailable in Neovim; use [d]."
    end
  end
  lines[#lines + 1] = focused and "" or "Preview · :RefineShow to focus for card keys"
  local footer = ""
  local targets = {}
  for _, action in ipairs(card_actions) do
    if has_action(suggestion, action.kind) then
      if footer ~= "" then
        footer = footer .. "  "
      end
      local start_col = #footer
      local text = ("[%s] %s"):format(action.key, action.label)
      footer = footer .. text
      targets[#targets + 1] = {
        kind = action.kind,
        line = #lines + 1,
        start_col = start_col,
        end_col = start_col + #text,
      }
    end
  end
  if footer ~= "" then
    footer = footer .. "  "
  end
  local close_start = #footer
  local close_text = "[q] Close"
  footer = footer .. close_text
  targets[#targets + 1] = {
    kind = "close",
    line = #lines + 1,
    start_col = close_start,
    end_col = close_start + #close_text,
  }
  lines[#lines + 1] = footer
  return { lines = lines, highlights = highlights, midlines = midlines, targets = targets }
end

local function apply_card_highlights(bufnr, content)
  vim.api.nvim_buf_clear_namespace(bufnr, card_namespace, 0, -1)
  for _, highlight in ipairs(content.highlights) do
    vim.api.nvim_buf_set_extmark(bufnr, card_namespace, highlight.row, highlight.start_col, {
      end_col = highlight.end_col,
      hl_group = highlight.group,
    })
  end
  for _, midline in ipairs(content.midlines) do
    vim.api.nvim_buf_set_extmark(bufnr, card_namespace, midline.row, midline.col, {
      virt_text = { { midline.text, "RefineDeletion" } },
      virt_text_pos = "overlay",
      virt_text_hide = true,
      hl_mode = "combine",
    })
  end
end

function Presentation:_render_card()
  if not self.card_buf or not vim.api.nvim_buf_is_valid(self.card_buf) then
    return
  end
  local suggestion = self:_suggestion_by_id(self.card_suggestion_id)
  if not suggestion then
    return
  end
  local focused = self.card_win
    and vim.api.nvim_win_is_valid(self.card_win)
    and vim.api.nvim_get_current_win() == self.card_win
  if self.card_win and vim.api.nvim_win_is_valid(self.card_win) then
    local text_direction = self.explanation_text_direction or suggestion.attribution.textDirection
    vim.wo[self.card_win].rightleft = text_direction == "rtl"
  end
  local was_at_bottom = focused
    and vim.api.nvim_win_call(self.card_win, function()
      return vim.fn.line("w$") >= vim.api.nvim_buf_line_count(self.card_buf)
    end)
  vim.bo[self.card_buf].modifiable = true
  local content =
    card_content(suggestion, self.card_feedback, self.snapshot.interaction, self.snapshot.appearance, focused)
  vim.api.nvim_buf_set_lines(self.card_buf, 0, -1, true, content.lines)
  apply_card_highlights(self.card_buf, content)
  self.card_mouse_targets = content.targets
  vim.bo[self.card_buf].modifiable = false
  if not self:refresh_view() then
    return
  end
  if was_at_bottom and self.card_win and vim.api.nvim_win_is_valid(self.card_win) then
    vim.api.nvim_win_call(self.card_win, function()
      vim.cmd("normal! Gzb")
    end)
  end
end

function Presentation:_set_feedback(lines)
  self.card_feedback = lines
  self:_render_card()
end

function Presentation:_clear_explanation(cancel)
  local cancel_explanation = self.explanation_cancel
  self.explanation_cancel = nil
  self.explanation_attribution = nil
  self.explanation_text_direction = nil
  if cancel and cancel_explanation then
    pcall(cancel_explanation)
  end
end

function Presentation:_map_card(key, callback, options)
  options = options or {}
  local generation = self.card_mapping_generation
  local record = self.card_mapping_records[key]
  local current = vim.api.nvim_buf_call(self.card_buf, function()
    return vim.fn.maparg(key, "n", false, true)
  end)
  local ours = record and record.callback and current.callback == record.callback
  if not ours and next(current) ~= nil and not options.force then
    self.card_mapping_records[key] = {
      callback = nil,
      generation = generation,
    }
    return
  end
  if not record or (not ours and options.force) then
    record = {
      previous = next(current) ~= nil and current or false,
    }
  end
  vim.keymap.set("n", key, callback, {
    buffer = self.card_buf,
    desc = options.desc,
    expr = options.expr,
    nowait = true,
    replace_keycodes = options.expr == true,
    silent = true,
  })
  record.callback = callback
  record.generation = generation
  self.card_mapping_records[key] = record

  local control_alias = card_control_aliases[key]
  if control_alias then
    self:_map_card(control_alias, function()
      return control_alias
    end, {
      desc = "Refine preserve " .. control_alias,
      expr = true,
    })
  end
end

function Presentation:_release_card_mapping(key, record)
  if not self.card_buf or not vim.api.nvim_buf_is_valid(self.card_buf) then
    return
  end
  local current = vim.api.nvim_buf_call(self.card_buf, function()
    return vim.fn.maparg(key, "n", false, true)
  end)
  if not record.callback or current.callback ~= record.callback then
    return
  end
  pcall(vim.keymap.del, "n", key, { buffer = self.card_buf })
  if record.previous then
    vim.api.nvim_buf_call(self.card_buf, function()
      vim.fn.mapset("n", false, record.previous)
    end)
  end
end

function Presentation:_finish_card_mapping_refresh()
  for key, record in pairs(self.card_mapping_records) do
    if record.generation ~= self.card_mapping_generation then
      self:_release_card_mapping(key, record)
      self.card_mapping_records[key] = nil
    end
  end
end

function Presentation:_clear_card_mappings()
  for key, record in pairs(self.card_mapping_records) do
    self:_release_card_mapping(key, record)
  end
  self.card_mapping_records = {}
end

function Presentation:_install_card_mappings()
  local suggestion = self:_suggestion_by_id(self.card_suggestion_id)
  if not suggestion then
    return
  end
  for _, action in ipairs(card_actions) do
    if has_action(suggestion, action.kind) then
      local kind = action.kind
      self:_map_card(action.key, function()
        self:action(kind)
      end, { desc = "Refine " .. action.label .. " suggestion" })
    end
  end
  self:_map_card("n", function()
    self:next()
  end, { desc = "Refine next suggestion" })
  self:_map_card("p", function()
    self:previous()
  end, { desc = "Refine previous suggestion" })
  for _, key in ipairs({ "q", "<Esc>" }) do
    self:_map_card(key, function()
      self:close()
    end, { desc = "Refine close card" })
  end

  local quick_apply = self.snapshot.interaction.quickApply
  local apply_lhs = action_keys[quick_apply.applyKey]
  local dismiss_lhs = action_keys[quick_apply.dismissKey]
  if apply_lhs == dismiss_lhs then
    return
  end
  if apply_lhs and (has_action(suggestion, "apply") or self.card_busy_action == "apply") then
    self:_map_card(apply_lhs, function()
      self:action("apply")
    end, {
      desc = "Refine Apply open card",
      force = self.card_configured_key_changed.apply,
    })
  end
  if dismiss_lhs and (has_action(suggestion, "dismiss") or self.card_busy_action == "dismiss") then
    self:_map_card(dismiss_lhs, function()
      self:action("dismiss")
    end, {
      desc = "Refine Dismiss open card",
      force = self.card_configured_key_changed.dismiss,
    })
  end
end

function Presentation:_install_owner_card_mappings(suggestion)
  self.card_owner_mappings:restore()
  local quick_apply = self.snapshot.interaction.quickApply
  local apply_lhs = action_keys[quick_apply.applyKey]
  local dismiss_lhs = action_keys[quick_apply.dismissKey]
  if apply_lhs == dismiss_lhs then
    return
  end
  if apply_lhs and (has_action(suggestion, "apply") or self.card_busy_action == "apply") then
    for _, mode in ipairs({ "n", "i" }) do
      self.card_owner_mappings:set(mode, apply_lhs, function()
        self:action("apply")
      end, { desc = "Refine Apply open card" })
    end
  end
  if dismiss_lhs and (has_action(suggestion, "dismiss") or self.card_busy_action == "dismiss") then
    for _, mode in ipairs({ "n", "i" }) do
      self.card_owner_mappings:set(mode, dismiss_lhs, function()
        self:action("dismiss")
      end, { desc = "Refine Dismiss open card" })
    end
  end
end

function Presentation:_refresh_card_controls()
  self.card_owner_mappings:restore()
  local suggestion = self:_suggestion_by_id(self.card_suggestion_id)
  if not suggestion or not self.card_win or not vim.api.nvim_win_is_valid(self.card_win) then
    return
  end
  local quick_apply = self.snapshot.interaction.quickApply
  local next_configured_lhs = {
    apply = action_keys[quick_apply.applyKey],
    dismiss = action_keys[quick_apply.dismissKey],
  }
  self.card_configured_key_changed = {
    apply = self.card_last_configured_lhs.apply ~= next_configured_lhs.apply,
    dismiss = self.card_last_configured_lhs.dismiss ~= next_configured_lhs.dismiss,
  }
  self.card_last_configured_lhs = next_configured_lhs
  self.card_mapping_generation = self.card_mapping_generation + 1
  self:_install_owner_card_mappings(suggestion)
  self:_install_card_mappings()
  self:_finish_card_mapping_refresh()
end

function Presentation:_visible_anchor(winid, suggestion)
  if not vim.api.nvim_win_is_valid(winid) or vim.api.nvim_win_get_buf(winid) ~= self.bufnr then
    return nil
  end
  local index = coordinates.new(vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, true))
  local top, bottom = unpack(vim.api.nvim_win_call(winid, function()
    return { vim.fn.line("w0"), vim.fn.line("w$") }
  end))
  local best
  for _, range in ipairs(suggestion.highlightRanges) do
    local positions = index:range(range)
    local last_row = positions.finish.row
    if range.length > 0 and positions.finish.byte_col == 0 and last_row > positions.start.row then
      last_row = last_row - 1
    end
    local first_line = math.max(top, positions.start.row + 1)
    local last_line = math.min(bottom, last_row + 1)
    for line = first_line, last_line do
      local byte_col = line == positions.start.row + 1 and positions.start.byte_col or 0
      local screen = vim.fn.screenpos(winid, line, byte_col + 1)
      if screen.row > 0 and screen.col > 0 and (not best or screen.row < best.row) then
        best = screen
        break
      end
    end
  end
  return best
end

function Presentation:_card_config(winid, suggestion, lines, content_height)
  local width = 1
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  local anchor = self:_visible_anchor(winid, suggestion)
  if not anchor then
    return false
  end
  local owner_position = vim.api.nvim_win_get_position(winid)
  local owner_width = vim.api.nvim_win_get_width(winid)
  local maximum_width = math.max(1, math.floor(owner_width * 0.8))
  local minimum_width = math.min(20, maximum_width)
  width = math.min(math.max(width, minimum_width), maximum_width)
  local owner_height = vim.api.nvim_win_get_height(winid)
  local height = math.min(content_height or #lines, math.max(1, math.floor(owner_height * 0.5)))
  local owner_top = owner_position[1]
  local owner_bottom = owner_top + owner_height
  local anchor_row = anchor.row - 1
  local available_below = owner_bottom - anchor.row
  local available_above = anchor_row - owner_top
  local place_below = available_below >= height or (available_above < height and available_below >= available_above)
  local available = place_below and available_below or available_above
  if available < 1 then
    return false
  end
  height = math.min(height, available)
  local owner_left = owner_position[2]
  local owner_right = owner_left + owner_width
  local column = math.max(owner_left, math.min(anchor.col - 1, owner_right - width))

  return {
    relative = "editor",
    anchor = place_below and "NW" or "SW",
    row = place_below and anchor.row or anchor_row,
    col = column,
    width = width,
    height = height,
    style = "minimal",
    focusable = true,
    zindex = 60,
  }
end

function Presentation:_open_card(winid, suggestion)
  local content = card_content(suggestion, nil, self.snapshot.interaction, self.snapshot.appearance, false)
  local config = self:_card_config(winid, suggestion, content.lines)
  if not config then
    return false
  end

  self:close(false)
  self:_clear_activation()
  self.card_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.card_buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(self.card_buf, 0, -1, true, content.lines)
  apply_card_highlights(self.card_buf, content)
  vim.bo[self.card_buf].modifiable = false
  self.card_win = vim.api.nvim_open_win(self.card_buf, false, config)
  vim.wo[self.card_win].wrap = true
  vim.wo[self.card_win].linebreak = true
  vim.wo[self.card_win].rightleft = suggestion.attribution.textDirection == "rtl"
  self.card_suggestion_id = suggestion.id
  self.card_mouse_targets = content.targets
  self.owner_win = winid
  self:_refresh_card_controls()
  vim.bo[self.card_buf].filetype = "refine"
  self:_install_card_focus_observer()
  return self:refresh_view()
end

function Presentation:_install_card_focus_observer()
  local card_buf = self.card_buf
  if not self.presentation_group or not card_buf or not vim.api.nvim_buf_is_valid(card_buf) then
    return
  end
  vim.api.nvim_create_autocmd({ "WinEnter", "WinLeave" }, {
    buffer = card_buf,
    group = self.presentation_group,
    callback = function()
      vim.schedule(function()
        if self.card_buf == card_buf and vim.api.nvim_buf_is_valid(card_buf) then
          self:_render_card()
        end
      end)
    end,
  })
end

function Presentation:_focus_card()
  local card_win = self.card_win
  if not card_win or not vim.api.nvim_win_is_valid(card_win) then
    return false
  end
  vim.api.nvim_set_current_win(card_win)
  self:_render_card()
  return self.card_win == card_win
    and vim.api.nvim_win_is_valid(card_win)
    and vim.api.nvim_get_current_win() == card_win
end

function Presentation:show()
  if self.card_win and vim.api.nvim_win_is_valid(self.card_win) then
    return self:_focus_card()
  end

  local winid = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(winid) ~= self.bufnr then
    return false
  end
  local suggestion = self:_suggestion_under_cursor(winid)
  if not suggestion then
    return false
  end
  if not self:_open_card(winid, suggestion) then
    return false
  end
  if self:_focus_card() then
    return true
  end
  self:close(false)
  return false
end

function Presentation:close(restore_focus)
  local card_win = self.card_win
  local owner_win = self.owner_win
  local had_focus = card_win and vim.api.nvim_win_is_valid(card_win) and vim.api.nvim_get_current_win() == card_win
  self.card_owner_mappings:restore()
  self:_clear_card_mappings()
  if card_win and vim.api.nvim_win_is_valid(card_win) then
    vim.api.nvim_win_close(card_win, true)
  end
  self:_clear_explanation(true)
  self.card_feedback = nil
  self.card_busy_action = nil
  self.card_mouse_targets = nil
  self.card_win = nil
  self.card_buf = nil
  self.card_suggestion_id = nil
  self.owner_win = nil
  if restore_focus ~= false and had_focus and owner_win and vim.api.nvim_win_is_valid(owner_win) then
    vim.api.nvim_set_current_win(owner_win)
  end
end

function Presentation:suspend_view()
  if not self.view_suspended then
    if self.active_suggestion_id and self.snapshot then
      self.suspended_activation = {
        suggestion_id = self.active_suggestion_id,
        document_revision = self.snapshot.documentRevision,
        check_generation = self.snapshot.checkGeneration,
      }
    else
      self.suspended_activation = nil
    end
  end
  self.view_suspended = true
  self:close(false)
  self:_clear_activation()
  self:_remove_mouse_observer()
end

function Presentation:reconcile_view()
  local suspended_activation = self.suspended_activation
  self.suspended_activation = nil
  self.view_suspended = false
  self:_install_mouse_observer()
  if
    suspended_activation
    and self.snapshot
    and self.snapshot.documentRevision == suspended_activation.document_revision
    and self.snapshot.checkGeneration == suspended_activation.check_generation
    and self.snapshot.interaction
    and self.snapshot.interaction.quickApply.enabled
  then
    local winid = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(winid) == self.bufnr then
      local suggestion = self:_suggestion_under_cursor(winid)
      if suggestion and suggestion.id == suspended_activation.suggestion_id and has_action(suggestion, "apply") then
        self:_install_quick_mappings(suggestion)
        return
      end
    end
  end
  self:_activate_from_cursor(false)
end

function Presentation:card_window()
  return self.card_win
end

function Presentation:refresh_view()
  if not self.card_win then
    return false
  end
  if
    not vim.api.nvim_win_is_valid(self.card_win)
    or not self.card_buf
    or not vim.api.nvim_buf_is_valid(self.card_buf)
  then
    self:close(false)
    return false
  end
  local suggestion = self:_suggestion_by_id(self.card_suggestion_id)
  if not suggestion then
    self:close(false)
    return false
  end
  local lines = vim.api.nvim_buf_get_lines(self.card_buf, 0, -1, true)
  local config = self:_card_config(self.owner_win, suggestion, lines)
  if not config then
    self:close(false)
    return false
  end
  local current = vim.api.nvim_win_get_config(self.card_win)
  if current.width ~= config.width then
    vim.api.nvim_win_set_config(self.card_win, { width = config.width })
  end
  local content_height = vim.api.nvim_win_text_height(self.card_win, {}).all
  config = self:_card_config(self.owner_win, suggestion, lines, content_height)
  if not config then
    self:close(false)
    return false
  end
  current = vim.api.nvim_win_get_config(self.card_win)
  for _, key in ipairs({ "relative", "anchor", "row", "col", "width", "height" }) do
    if current[key] ~= config[key] then
      vim.api.nvim_win_set_config(self.card_win, config)
      break
    end
  end
  return true
end

function Presentation:refresh_highlights()
  if self.snapshot and self.snapshot.appearance then
    define_highlights(self.snapshot.appearance)
  end
  if self.active_suggestion_id then
    define_active_highlight()
  end
end

function Presentation:_suggestion_by_id(suggestion_id)
  if not self.snapshot then
    return nil
  end
  for _, suggestion in ipairs(self.snapshot.suggestions) do
    if suggestion.id == suggestion_id then
      return suggestion
    end
  end
end

function Presentation:_action_target()
  if self.card_suggestion_id then
    return self:_suggestion_by_id(self.card_suggestion_id)
  end
  local winid = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(winid) ~= self.bufnr then
    return nil
  end
  return self:_suggestion_under_cursor(winid)
end

function Presentation:action(kind)
  local suggestion = self:_action_target()
  return self:_invoke_action(suggestion, kind)
end

function Presentation:_invoke_action(suggestion, kind)
  local belongs_to_card = suggestion and self.card_suggestion_id == suggestion.id
  if belongs_to_card and self.card_busy_action == kind then
    return true
  end
  local invoke = self.actions and self.actions[kind]
  if not suggestion or not has_action(suggestion, kind) or type(invoke) ~= "function" then
    return false
  end

  if kind == "explain" then
    self:_clear_explanation(true)
    self:_set_feedback({ "Explaining…" })
    local ended = false
    local ok, cancel = pcall(invoke, suggestion.id, function(update)
      if update.status == "started" then
        local attribution = update.attribution or {}
        local labels = {}
        if type(attribution.languageDisplayName) == "string" and attribution.languageDisplayName ~= "" then
          labels[#labels + 1] = attribution.languageDisplayName
        end
        if type(attribution.modelDisplayName) == "string" and attribution.modelDisplayName ~= "" then
          labels[#labels + 1] = attribution.modelDisplayName
        end
        if attribution.textDirection == "ltr" or attribution.textDirection == "rtl" then
          self.explanation_text_direction = attribution.textDirection
        end
        self.explanation_attribution = "Explanation"
        if #labels > 0 then
          self.explanation_attribution = self.explanation_attribution .. " · " .. table.concat(labels, " · ")
        end
        self:_set_feedback({ self.explanation_attribution, "Explaining…" })
      elseif update.status == "streaming" or update.status == "completed" then
        local feedback = vim.split(update.text or "", "\n", { plain = true })
        if self.explanation_attribution then
          table.insert(feedback, 1, "")
          table.insert(feedback, 1, self.explanation_attribution)
        end
        self:_set_feedback(feedback)
      elseif update.status == "stale" then
        self:_clear_explanation(false)
        if belongs_to_card then
          self:_set_feedback({ "This suggestion is no longer current." })
        else
          notify_action_failure(kind, "stale")
        end
      elseif update.status == "unavailable" then
        self:_clear_explanation(false)
        if belongs_to_card then
          self:_set_feedback({ "Explanation unavailable: " .. tostring(update.reason or "unknown") })
        else
          notify_action_failure(kind, "unavailable", update.reason)
        end
      end
    end, function()
      ended = true
      self.explanation_cancel = nil
    end)
    if not ok then
      self:_clear_explanation(false)
      if belongs_to_card then
        self:_set_feedback({ "Explanation unavailable." })
      else
        notify_action_failure(kind, "failed")
      end
      return false
    end
    self.explanation_cancel = not ended and type(cancel) == "function" and cancel or nil
    return true
  end

  self:_clear_explanation(true)

  local tracks_busy = belongs_to_card and (kind == "apply" or kind == "dismiss")
  if tracks_busy then
    self.card_busy_action = kind
  end

  if kind == "apply" then
    self:_set_feedback({ "Applying…" })
  elseif kind == "dismiss" then
    self:_set_feedback({ "Dismissing…" })
  elseif kind == "report" then
    self:_set_feedback({ "Reporting…" })
  end
  local ok = pcall(invoke, suggestion.id, function(outcome)
    if (kind == "apply" or kind == "dismiss") and outcome.status == "completed" then
      self:close()
    elseif kind == "report" and outcome.status == "completed" then
      self:_set_feedback({ "Reported. Thank you." })
    elseif outcome.status == "stale" then
      if belongs_to_card then
        self:_set_feedback({ "This suggestion is no longer current." })
      else
        notify_action_failure(kind, "stale")
      end
    elseif outcome.status == "unavailable" then
      if kind == "apply" and outcome.reason == "mutationIndeterminate" then
        local message = "Refine could not confirm whether Apply changed the buffer. Review the text before continuing."
        self:_set_feedback({
          "WARNING: Apply may have changed the buffer.",
          "Review the text before continuing.",
        })
        pcall(vim.notify_once, message, vim.log.levels.ERROR, { title = "Refine" })
      else
        if belongs_to_card then
          self:_set_feedback({ "Action unavailable: " .. tostring(outcome.reason or "unknown") })
        else
          notify_action_failure(kind, "unavailable", outcome.reason)
        end
      end
    end
    if tracks_busy and self.card_busy_action == kind then
      self.card_busy_action = nil
      self:_refresh_card_controls()
    end
  end)
  if not ok then
    if belongs_to_card then
      self:_set_feedback({ "Action unavailable." })
    else
      notify_action_failure(kind, "failed")
    end
    if tracks_busy and self.card_busy_action == kind then
      self.card_busy_action = nil
      self:_refresh_card_controls()
    end
  end
  return ok
end

function Presentation:_clear_activation()
  self.active_suggestion_id = nil
  if vim.api.nvim_buf_is_valid(self.bufnr) then
    vim.api.nvim_buf_clear_namespace(self.bufnr, activation_namespace, 0, -1)
  end
  if self.quick_mappings then
    self.quick_mappings:restore()
  end
end

function Presentation:_render_activation(suggestion)
  local index = coordinates.new(vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, true))
  define_active_highlight()
  for _, range in ipairs(suggestion.highlightRanges) do
    local positions = index:range(range)
    vim.api.nvim_buf_set_extmark(self.bufnr, activation_namespace, positions.start.row, positions.start.byte_col, {
      end_row = positions.finish.row,
      end_col = positions.finish.byte_col,
      hl_group = "RefineActive",
      priority = 130,
      virt_text = range.length == 0 and { { "▏", "RefineActive" } } or nil,
      virt_text_pos = range.length == 0 and "overlay" or nil,
    })
  end
  if self.snapshot.interaction.quickApply.activationStyle == "showTipAndHighlight" then
    local range = suggestion.activationRange
    local position = index:position(range.location + range.length)
    local quick = self.snapshot.interaction.quickApply
    vim.api.nvim_buf_set_extmark(self.bufnr, activation_namespace, position.row, position.byte_col, {
      virt_text = {
        {
          (" %s · %s"):format(quick_action_tip(quick.applyKey, "Apply"), quick_action_tip(quick.dismissKey, "Cancel")),
          "Comment",
        },
      },
      virt_text_pos = "eol",
      priority = 130,
    })
  end
end

function Presentation:_install_quick_mappings(suggestion)
  self:_clear_activation()
  self.active_suggestion_id = suggestion.id
  local quick_apply = self.snapshot.interaction.quickApply
  local apply_lhs = action_keys[quick_apply.applyKey]
  local dismiss_lhs = action_keys[quick_apply.dismissKey]
  self:_render_activation(suggestion)

  if apply_lhs == dismiss_lhs then
    return
  end

  if apply_lhs and has_action(suggestion, "apply") then
    for _, mode in ipairs({ "n", "i" }) do
      self.quick_mappings:set(mode, apply_lhs, function()
        local active = self:_suggestion_by_id(self.active_suggestion_id)
        if active then
          self:_invoke_action(active, "apply")
        end
      end, { desc = "Refine Apply suggestion" })
    end
  end
  if dismiss_lhs then
    for _, mode in ipairs({ "n", "i" }) do
      self.quick_mappings:set(mode, dismiss_lhs, function()
        self:_clear_activation()
      end, { desc = "Refine Cancel suggestion activation" })
    end
  end
end

function Presentation:_suggestion_at_position(winid, line, column)
  if
    not self.snapshot
    or not vim.api.nvim_win_is_valid(winid)
    or vim.api.nvim_win_get_buf(winid) ~= self.bufnr
    or line < 1
    or column < 1
  then
    return nil
  end
  local index = coordinates.new(vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, true))
  local ok, offset = pcall(index.utf16_offset, index, line - 1, column - 1)
  if not ok then
    return nil
  end
  local candidates = {}
  for _, suggestion in ipairs(self.snapshot.suggestions) do
    for _, range in ipairs(suggestion.highlightRanges) do
      local contains = range.length == 0 and offset == range.location
        or (offset >= range.location and offset < range.location + range.length)
      if contains then
        candidates[#candidates + 1] = suggestion
        break
      end
    end
  end
  table.sort(candidates, candidate_before)
  return candidates[1]
end

function Presentation:_handle_left_mouse()
  if not self.snapshot then
    return
  end
  local mouse = vim.fn.getmousepos()
  local winid = tonumber(mouse.winid) or 0
  local line = tonumber(mouse.line) or 0
  local column = tonumber(mouse.column) or 0
  if self.card_win and vim.api.nvim_win_is_valid(self.card_win) and winid == self.card_win then
    local byte_col = column - 1
    for _, target in ipairs(self.card_mouse_targets or {}) do
      if line == target.line and byte_col >= target.start_col and byte_col < target.end_col then
        if target.kind == "close" then
          self:close()
        else
          self:action(target.kind)
        end
        return
      end
    end
    return
  end
  local suggestion = self:_suggestion_at_position(winid, line, column)
  if suggestion and self:_open_card(winid, suggestion) and not self:_focus_card() then
    self:close(false)
  end
end

function Presentation:_remove_mouse_observer()
  self.mouse_observer_generation = (self.mouse_observer_generation or 0) + 1
  if self.mouse_observer_namespace then
    vim.on_key(nil, self.mouse_observer_namespace)
    self.mouse_observer_namespace = nil
  end
  self.card_mouse_targets = nil
end

function Presentation:_install_mouse_observer()
  if self.mouse_observer_namespace or not self.snapshot or #self.snapshot.suggestions == 0 then
    return
  end
  self.mouse_observer_generation = (self.mouse_observer_generation or 0) + 1
  local generation = self.mouse_observer_generation
  self.mouse_observer_namespace = vim.on_key(function(key, typed)
    if typed ~= left_mouse and key ~= left_mouse then
      return
    end
    vim.schedule(function()
      if self.mouse_observer_namespace and self.mouse_observer_generation == generation then
        pcall(self._handle_left_mouse, self)
      end
    end)
  end)
end

function Presentation:_activate_from_cursor(is_explicit_move)
  if not self.snapshot or not self.snapshot.interaction or not self.snapshot.interaction.quickApply then
    self:_clear_activation()
    return
  end
  local generation = self.snapshot.documentRevision .. ":" .. self.snapshot.checkGeneration
  if not self.snapshot.interaction.quickApply.enabled then
    self:_clear_activation()
    self.auto_activation_consumed = generation
    return
  end
  if self.card_win then
    self:_clear_activation()
    return
  end

  local mode = vim.api.nvim_get_mode().mode:sub(1, 1)
  if mode ~= "n" and mode ~= "i" then
    self:_clear_activation()
    return
  end
  local winid = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(winid) ~= self.bufnr then
    self:_clear_activation()
    return
  end
  local suggestion = self:_suggestion_under_cursor(winid)
  if not suggestion or not has_action(suggestion, "apply") then
    self:_clear_activation()
    return
  end

  if not is_explicit_move and self.auto_activation_consumed == generation then
    return
  end
  if not is_explicit_move then
    self.auto_activation_consumed = generation
  end
  self:_install_quick_mappings(suggestion)
end

function Presentation:_install_cursor_observer()
  if self.presentation_group then
    return
  end
  self.presentation_group = vim.api.nvim_create_augroup("RefinePresentation" .. self.bufnr, {
    clear = true,
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    buffer = self.bufnr,
    group = self.presentation_group,
    callback = function()
      if self.card_win and vim.api.nvim_win_is_valid(self.card_win) then
        local winid = vim.api.nvim_get_current_win()
        local current = self:_suggestion_under_cursor(winid)
        if winid == self.owner_win and (not current or current.id ~= self.card_suggestion_id) then
          self:close(false)
        end
        return
      end
      self:_activate_from_cursor(true)
    end,
  })
end

function Presentation:next()
  return self:_navigate(1)
end

function Presentation:previous()
  return self:_navigate(-1)
end

function Presentation:_ordered_suggestions()
  local suggestions = vim.deepcopy(self.snapshot and self.snapshot.suggestions or {})
  table.sort(suggestions, function(left, right)
    local left_range = left.highlightRanges[1] or left.activationRange
    local right_range = right.highlightRanges[1] or right.activationRange
    if left_range.location ~= right_range.location then
      return left_range.location < right_range.location
    end
    return candidate_before(left, right)
  end)
  return suggestions
end

function Presentation:_navigate(direction)
  local suggestions = self:_ordered_suggestions()
  if #suggestions == 0 then
    return false
  end

  local card_focused = self.card_win
    and vim.api.nvim_win_is_valid(self.card_win)
    and vim.api.nvim_get_current_win() == self.card_win
  local owner_win = self.owner_win or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(owner_win) or vim.api.nvim_win_get_buf(owner_win) ~= self.bufnr then
    return false
  end

  local current_index
  if self.card_suggestion_id then
    for index, suggestion in ipairs(suggestions) do
      if suggestion.id == self.card_suggestion_id then
        current_index = index
        break
      end
    end
  end

  local index = coordinates.new(vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, true))
  if not current_index then
    local cursor = vim.api.nvim_win_get_cursor(owner_win)
    local ok, offset = pcall(index.utf16_offset, index, cursor[1] - 1, cursor[2])
    if ok then
      if direction > 0 then
        for suggestion_index, suggestion in ipairs(suggestions) do
          local range = suggestion.highlightRanges[1] or suggestion.activationRange
          if range.location >= offset then
            current_index = suggestion_index - 1
            break
          end
        end
        current_index = current_index or #suggestions
      else
        for suggestion_index = #suggestions, 1, -1 do
          local range = suggestions[suggestion_index].highlightRanges[1]
            or suggestions[suggestion_index].activationRange
          if range.location <= offset then
            current_index = suggestion_index + 1
            break
          end
        end
        current_index = current_index or 1
      end
    end
  end
  current_index = current_index or (direction > 0 and #suggestions or 1)

  local target_index = ((current_index - 1 + direction) % #suggestions) + 1
  local target = suggestions[target_index]
  local range = target.highlightRanges[1] or target.activationRange
  local position = index:position(range.location)

  self:close(false)
  vim.api.nvim_win_call(owner_win, function()
    local target_line = position.row + 1
    if vim.api.nvim_win_get_cursor(0)[1] ~= target_line then
      vim.cmd.normal({ args = { target_line .. "G" }, bang = true })
    else
      -- Neovim cannot record a same-line column-only jump; retain the exact
      -- previous-context mark as its one-line fallback.
      vim.cmd.normal({ args = { "m'" }, bang = true })
    end
    vim.api.nvim_win_set_cursor(0, { target_line, position.byte_col })
  end)
  if not self:_open_card(owner_win, target) then
    return false
  end
  if card_focused then
    return self:_focus_card()
  end
  return true
end

function Presentation:_card_survives(snapshot)
  if
    not self.snapshot
    or not self.card_suggestion_id
    or not self.card_win
    or not vim.api.nvim_win_is_valid(self.card_win)
    or not self.card_buf
    or not vim.api.nvim_buf_is_valid(self.card_buf)
    or not self.owner_win
    or not vim.api.nvim_win_is_valid(self.owner_win)
    or vim.api.nvim_win_get_buf(self.owner_win) ~= self.bufnr
    or self.snapshot.documentRevision ~= snapshot.documentRevision
    or self.snapshot.checkGeneration ~= snapshot.checkGeneration
    or (snapshot.state.type ~= "checking" and snapshot.state.type ~= "complete")
  then
    return false
  end
  for _, suggestion in ipairs(snapshot.suggestions) do
    if suggestion.id == self.card_suggestion_id then
      return true
    end
  end
  return false
end

function Presentation:replace(snapshot, actions)
  local preserve_card = self:_card_survives(snapshot)
  local previous_active = self.active_suggestion_id
  local preserve_activation = not preserve_card
    and not self.view_suspended
    and previous_active ~= nil
    and self.snapshot ~= nil
    and self.snapshot.documentRevision == snapshot.documentRevision
    and self.snapshot.checkGeneration == snapshot.checkGeneration
    and snapshot.interaction
    and snapshot.interaction.quickApply.enabled
  if preserve_card then
    self:_clear_activation()
    self:_remove_mouse_observer()
    if vim.api.nvim_buf_is_valid(self.bufnr) then
      vim.api.nvim_buf_clear_namespace(self.bufnr, namespace, 0, -1)
    end
  else
    self:clear()
  end
  self.snapshot = snapshot
  self.actions = actions

  if snapshot.interaction and not snapshot.interaction.quickApply.enabled then
    self.auto_activation_consumed = snapshot.documentRevision .. ":" .. snapshot.checkGeneration
  end
  if self.suspended_activation then
    local suspended = self.suspended_activation
    local live = snapshot.documentRevision == suspended.document_revision
      and snapshot.checkGeneration == suspended.check_generation
      and snapshot.interaction
      and snapshot.interaction.quickApply.enabled
    if live then
      live = false
      for _, suggestion in ipairs(snapshot.suggestions) do
        if suggestion.id == suspended.suggestion_id and has_action(suggestion, "apply") then
          live = true
          break
        end
      end
    end
    if not live then
      self.suspended_activation = nil
    end
  end

  if snapshot.state.type ~= "checking" and snapshot.state.type ~= "complete" then
    return
  end

  define_highlights(snapshot.appearance)
  local index = coordinates.new(vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, true))
  for _, suggestion in ipairs(snapshot.suggestions) do
    local group = suggestion.kind == "grammar" and "RefineGrammar" or "RefineFluency"
    for _, range in ipairs(suggestion.highlightRanges) do
      local positions = index:range(range)
      local insertion = range.length == 0
      vim.api.nvim_buf_set_extmark(self.bufnr, namespace, positions.start.row, positions.start.byte_col, {
        end_row = positions.finish.row,
        end_col = positions.finish.byte_col,
        hl_group = group,
        priority = 120,
        right_gravity = false,
        end_right_gravity = true,
        virt_text = insertion and { { "▏", group } } or nil,
        virt_text_pos = insertion and "overlay" or nil,
        strict = true,
      })
    end
  end
  self:_install_cursor_observer()
  if not self.view_suspended then
    self:_install_mouse_observer()
  end
  if self.view_suspended then
    return
  end
  if preserve_card then
    self:_render_card()
    if self.card_win and vim.api.nvim_win_is_valid(self.card_win) then
      self:_refresh_card_controls()
      return
    end
  end
  if preserve_activation then
    local winid = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(winid) == self.bufnr then
      local suggestion = self:_suggestion_under_cursor(winid)
      if suggestion and suggestion.id == previous_active and has_action(suggestion, "apply") then
        self:_install_quick_mappings(suggestion)
        return
      end
    end
  end
  self:_activate_from_cursor(false)
end

local M = {}

function M.new(bufnr)
  return setmetatable({
    bufnr = bufnr,
    quick_mappings = mappings.new(bufnr),
    card_owner_mappings = mappings.new(bufnr),
    card_configured_key_changed = {},
    card_last_configured_lhs = {},
    card_mapping_generation = 0,
    card_mapping_records = {},
    mouse_observer_generation = 0,
    view_suspended = false,
  }, Presentation)
end

return M
