local root = vim.fn.getcwd()
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  root .. "/tests/?.lua",
  package.path,
}, ";")

local harness = require("support.harness")

local appearance = {
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

local interaction = {
  automaticChecksEnabled = true,
  quickApply = {
    enabled = false,
    applyKey = "tab",
    dismissKey = "escape",
    activationStyle = "highlightChanges",
  },
}

local function offset(lines, row, byte_col)
  local value = byte_col
  for index = 1, row do
    value = value + #lines[index] + 1
  end
  return value
end

local function suggestion(lines, options)
  local activation_start = offset(lines, options.activation_start_row, 0)
  local activation_finish = offset(lines, options.activation_finish_row, #lines[options.activation_finish_row + 1])
  local highlights = {}
  for _, row in ipairs(options.highlight_rows) do
    highlights[#highlights + 1] = {
      location = offset(lines, row, 0),
      length = math.min(4, #lines[row + 1]),
    }
  end
  return {
    id = options.id or "geometry",
    sourceId = "document",
    kind = "grammar",
    attribution = {
      languageDisplayName = "English",
      textDirection = "ltr",
      checkModelDisplayName = "On-Device",
    },
    activationRange = {
      location = activation_start,
      length = activation_finish - activation_start,
    },
    highlightRanges = highlights,
    diff = options.diff or {
      { kind = "delete", text = "text" },
      { kind = "insert", text = "copy" },
    },
    availableActions = options.available_actions or { "apply" },
  }
end

local function present(lines, suggestions, actions)
  vim.cmd.only()
  vim.cmd.enew({ bang = true })
  local bufnr = vim.api.nvim_get_current_buf()
  local owner_win = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, lines)
  local host = require("refine.nvim.host").new({
    bufnr = bufnr,
    source_syntax = "mixed",
    run_id = "presentation-lifecycle",
  })
  host:present({
    documentRevision = host.source:snapshot().revision,
    presentationRevision = 1,
    checkGeneration = 1,
    state = { type = "complete", coverage = "full" },
    appearance = appearance,
    interaction = interaction,
    suggestions = suggestions,
  }, actions or {})
  return host, bufnr, owner_win
end

harness.test("anchors below the first visible suggestion highlight", function()
  local lines = {}
  for index = 1, 40 do
    lines[index] = ("line %02d text"):format(index)
  end
  local item = suggestion(lines, {
    activation_start_row = 1,
    activation_finish_row = 19,
    highlight_rows = { 1, 19 },
  })
  local host, _, owner_win = present(lines, { item })
  vim.api.nvim_win_call(owner_win, function()
    vim.fn.winrestview({ topline = 15, lnum = 20, col = 1 })
  end)
  vim.cmd.redraw()

  harness.equal(0, vim.fn.screenpos(owner_win, 2, 1).row)
  local anchor = vim.fn.screenpos(owner_win, 20, 1)
  harness.equal(true, anchor.row > 0)
  harness.equal(true, host:show())

  local card_win = host.presentation:card_window()
  harness.equal(true, vim.api.nvim_win_is_valid(card_win))
  harness.equal(anchor.row, vim.api.nvim_win_get_position(card_win)[1])
  host:close()
end)

harness.test("anchors to the first visible row inside one multiline highlight", function()
  local lines = {}
  for index = 1, 40 do
    lines[index] = ("line %02d text"):format(index)
  end
  local item = suggestion(lines, {
    activation_start_row = 1,
    activation_finish_row = 19,
    highlight_rows = { 1 },
  })
  item.highlightRanges = { vim.deepcopy(item.activationRange) }
  local host, _, owner_win = present(lines, { item })
  vim.api.nvim_win_call(owner_win, function()
    vim.fn.winrestview({ topline = 15, lnum = 20, col = 1 })
  end)
  vim.cmd.redraw()

  harness.equal(0, vim.fn.screenpos(owner_win, 2, 1).row)
  local first_visible = vim.fn.screenpos(owner_win, 15, 1)
  harness.equal(true, first_visible.row > 0)
  harness.equal(true, host:show())
  harness.equal(first_visible.row, vim.api.nvim_win_get_position(host.presentation:card_window())[1])
  host:close()
end)

harness.test("navigation records a real jump and preserves the target byte column", function()
  local lines = { "one", "two", "é bad" }
  local item = suggestion(lines, {
    activation_start_row = 2,
    activation_finish_row = 2,
    highlight_rows = { 2 },
  })
  item.activationRange = { location = 10, length = 3 }
  item.highlightRanges = { { location = 10, length = 3 } }
  local host, bufnr, owner_win = present(lines, { item })
  vim.api.nvim_win_set_cursor(owner_win, { 1, 2 })
  vim.api.nvim_win_call(owner_win, function()
    vim.cmd.clearjumps()
  end)

  harness.equal(true, host:next())
  harness.equal({ 3, 3 }, vim.api.nvim_win_get_cursor(owner_win))
  local jumps = vim.fn.getjumplist()[1]
  local previous = jumps[#jumps]
  harness.equal(bufnr, previous.bufnr)
  harness.equal(1, previous.lnum)
  harness.equal(2, previous.col)
  vim.api.nvim_win_call(owner_win, function()
    vim.cmd.normal({ args = { vim.keycode("<C-o>") }, bang = true })
  end)
  harness.equal({ 1, 2 }, vim.api.nvim_win_get_cursor(owner_win))
  host:close()
end)

harness.test("places the card above when it does not fit below in the owner window", function()
  local lines = {}
  for index = 1, 40 do
    lines[index] = ("line %02d text"):format(index)
  end
  local item = suggestion(lines, {
    activation_start_row = 35,
    activation_finish_row = 35,
    highlight_rows = { 35 },
  })
  local host, _, owner_win = present(lines, { item })
  vim.api.nvim_set_current_win(owner_win)
  vim.cmd("belowright 8new")
  vim.api.nvim_set_current_win(owner_win)
  vim.api.nvim_win_set_cursor(owner_win, { 36, 1 })
  vim.api.nvim_win_call(owner_win, function()
    vim.cmd("normal! 36zb")
  end)
  vim.cmd.redraw()

  local anchor = vim.fn.screenpos(owner_win, 36, 1)
  harness.equal(true, anchor.row > 0)
  harness.equal(true, host:show())

  local card_win = host.presentation:card_window()
  harness.equal("SW", vim.api.nvim_win_get_config(card_win).anchor)
  harness.equal(anchor.row - 1, vim.api.nvim_win_get_config(card_win).row)
  host:close()
end)

harness.test("bounds an overflowing focused card to the owner window", function()
  local lines = { "word text" }
  local diff = {}
  for index = 1, 20 do
    diff[index] = { kind = "unchanged", text = ("long content %02d "):format(index) .. string.rep("word ", 20) }
  end
  local item = suggestion(lines, {
    activation_start_row = 0,
    activation_finish_row = 0,
    highlight_rows = { 0 },
    diff = diff,
  })
  local host, _, owner_win = present(lines, { item })
  vim.api.nvim_set_current_win(owner_win)
  vim.cmd("belowright 8new")
  vim.api.nvim_set_current_win(owner_win)
  vim.cmd("rightbelow vnew")
  vim.api.nvim_win_set_width(owner_win, 28)
  vim.api.nvim_set_current_win(owner_win)
  vim.api.nvim_win_set_cursor(owner_win, { 1, 1 })
  vim.cmd.redraw()

  harness.equal(true, host:show())
  harness.equal(true, host:show())
  local card_win = host.presentation:card_window()
  local config = vim.api.nvim_win_get_config(card_win)
  harness.equal(true, config.width <= math.max(1, math.floor(vim.api.nvim_win_get_width(owner_win) * 0.8)))
  harness.equal(true, config.height <= math.max(1, math.floor(vim.api.nvim_win_get_height(owner_win) * 0.5)))
  harness.equal(true, vim.api.nvim_win_text_height(card_win, {}).all > config.height)
  harness.equal(true, vim.wo[card_win].wrap)

  local first_topline = vim.api.nvim_win_call(card_win, function()
    return vim.fn.line("w0")
  end)
  vim.api.nvim_win_call(card_win, function()
    vim.cmd("normal! Gzb")
  end)
  local last_topline = vim.api.nvim_win_call(card_win, function()
    return vim.fn.line("w0")
  end)
  harness.equal(true, last_topline > first_topline)
  host:close()
end)

harness.test("sizes wrapped card text by occupied screen rows", function()
  local lines = { "word text" }
  local item = suggestion(lines, {
    activation_start_row = 0,
    activation_finish_row = 0,
    highlight_rows = { 0 },
    diff = { { kind = "unchanged", text = string.rep("wrapped words ", 40) } },
  })
  local host, _, owner_win = present(lines, { item })
  vim.api.nvim_set_current_win(owner_win)
  vim.cmd("belowright 8new")
  vim.api.nvim_set_current_win(owner_win)
  vim.cmd("rightbelow vnew")
  vim.api.nvim_win_set_width(owner_win, 28)
  vim.api.nvim_set_current_win(owner_win)
  vim.api.nvim_win_set_cursor(owner_win, { 1, 1 })
  vim.cmd.redraw()

  harness.equal(true, host:show())
  local card_win = host.presentation:card_window()
  harness.equal(6, vim.api.nvim_win_get_config(card_win).height)
  host:close()
end)

harness.test("repositions a card while its anchor is visible and closes it after scrolling away", function()
  local lines = {}
  for index = 1, 60 do
    lines[index] = ("line %02d text"):format(index)
  end
  local item = suggestion(lines, {
    activation_start_row = 19,
    activation_finish_row = 19,
    highlight_rows = { 19 },
  })
  local host, _, owner_win = present(lines, { item })
  vim.api.nvim_win_call(owner_win, function()
    vim.fn.winrestview({ topline = 15, lnum = 20, col = 1 })
  end)
  vim.cmd.redraw()
  harness.equal(true, host:show())
  local card_win = host.presentation:card_window()
  local first_row = vim.api.nvim_win_get_config(card_win).row

  vim.api.nvim_win_call(owner_win, function()
    vim.fn.winrestview({ topline = 17, lnum = 20, col = 1 })
  end)
  vim.cmd.redraw()
  local moved_anchor = vim.fn.screenpos(owner_win, 20, 1)
  host:refresh_view()
  harness.equal(true, vim.api.nvim_win_is_valid(card_win))
  harness.equal(moved_anchor.row, vim.api.nvim_win_get_config(card_win).row)
  harness.equal(true, vim.api.nvim_win_get_config(card_win).row ~= first_row)

  vim.api.nvim_win_call(owner_win, function()
    vim.fn.winrestview({ topline = 30, lnum = 30, col = 1 })
  end)
  vim.cmd.redraw()
  harness.equal(0, vim.fn.screenpos(owner_win, 20, 1).row)
  host:refresh_view()
  harness.equal(nil, host.presentation:card_window())
end)

harness.test("reapplies Refine-owned highlights after a color scheme reset", function()
  local lines = { "word text" }
  local item = suggestion(lines, {
    activation_start_row = 0,
    activation_finish_row = 0,
    highlight_rows = { 0 },
  })
  local host = present(lines, { item })
  vim.api.nvim_set_hl(0, "RefineGrammar", {})
  vim.api.nvim_set_hl(0, "RefineFluency", {})
  harness.equal({}, vim.api.nvim_get_hl(0, { name = "RefineGrammar", link = false }))

  host:refresh_highlights()

  local grammar = vim.api.nvim_get_hl(0, { name = "RefineGrammar", link = false })
  local fluency = vim.api.nvim_get_hl(0, { name = "RefineFluency", link = false })
  harness.equal(0xFF2D55, grammar.sp)
  harness.equal(true, grammar.underline)
  harness.equal(0x007AFF, fluency.sp)
  harness.equal(true, fluency.underline)
end)

harness.test("grows streamed feedback and follows the focused card only while it is at the bottom", function()
  local lines = { "word text" }
  local item = suggestion(lines, {
    activation_start_row = 0,
    activation_finish_row = 0,
    highlight_rows = { 0 },
    available_actions = { "explain" },
  })
  local update
  local host, _, owner_win = present(lines, { item }, {
    explain = function(_, on_update)
      update = on_update
      on_update({ status = "started" })
      return function() end
    end,
  })
  vim.api.nvim_win_set_cursor(owner_win, { 1, 1 })
  harness.equal(true, host:show())
  harness.equal(true, host:show())
  harness.equal(true, host:action("explain"))
  local card_win = host.presentation:card_window()

  local feedback = {}
  for index = 1, 20 do
    feedback[index] = ("Explanation line %02d"):format(index)
  end
  update({ status = "streaming", text = table.concat(feedback, "\n") })
  local card_buf = vim.api.nvim_win_get_buf(card_win)
  harness.equal(true, vim.api.nvim_win_get_height(card_win) <= math.floor(vim.api.nvim_win_get_height(owner_win) * 0.5))
  harness.equal(
    vim.api.nvim_buf_line_count(card_buf),
    vim.api.nvim_win_call(card_win, function()
      return vim.fn.line("w$")
    end)
  )

  vim.api.nvim_win_call(card_win, function()
    vim.cmd("normal! ggzt")
  end)
  feedback[#feedback + 1] = "One more line"
  update({ status = "streaming", text = table.concat(feedback, "\n") })
  harness.equal(1, vim.api.nvim_win_get_cursor(card_win)[1])
  harness.equal(
    1,
    vim.api.nvim_win_call(card_win, function()
      return vim.fn.line("w0")
    end)
  )
  host:close()
end)

harness.test("closes the card when its owner window disappears", function()
  local lines = { "word text" }
  local item = suggestion(lines, {
    activation_start_row = 0,
    activation_finish_row = 0,
    highlight_rows = { 0 },
  })
  local host, _, owner_win = present(lines, { item })
  vim.api.nvim_win_set_cursor(owner_win, { 1, 1 })
  harness.equal(true, host:show())
  local card_win = host.presentation:card_window()
  local controller = {
    action = function() end,
    check = function() end,
    close = function() end,
    next = function() end,
    previous = function() end,
    reconcile = function()
      host:reconcile_view()
    end,
    refresh_highlights = function()
      host:refresh_highlights()
    end,
    refresh_view = function()
      host:refresh_view()
    end,
    show = function() end,
    status = function()
      return { state = "complete" }
    end,
    suspend_view = function()
      host:suspend_view()
    end,
  }
  require("refine.commands").register({ controller = controller, lifecycle = true })
  local enabled_interaction = vim.deepcopy(interaction)
  enabled_interaction.quickApply.enabled = true
  host:present({
    documentRevision = host.source:snapshot().revision,
    presentationRevision = 2,
    checkGeneration = 2,
    state = { type = "complete", coverage = "full" },
    appearance = appearance,
    interaction = enabled_interaction,
    suggestions = { item },
  }, {})
  harness.equal("Refine Apply suggestion", vim.fn.maparg("<Tab>", "n", false, true).desc)

  vim.api.nvim_exec_autocmds("FocusLost", {})
  harness.equal({}, vim.fn.maparg("<Tab>", "n", false, true))
  host:present({
    documentRevision = host.source:snapshot().revision,
    presentationRevision = 3,
    checkGeneration = 2,
    state = { type = "complete", coverage = "full" },
    appearance = appearance,
    interaction = enabled_interaction,
    suggestions = { item },
  }, {})
  harness.equal({}, vim.fn.maparg("<Tab>", "n", false, true))
  vim.api.nvim_exec_autocmds("FocusGained", {})
  harness.equal(
    true,
    vim.wait(1000, function()
      return vim.fn.maparg("<Tab>", "n", false, true).desc == "Refine Apply suggestion"
    end)
  )

  vim.api.nvim_set_current_win(owner_win)
  vim.cmd("belowright new")
  vim.api.nvim_win_close(owner_win, true)

  harness.equal(
    true,
    vim.wait(1000, function()
      return host.presentation:card_window() == nil
    end)
  )
  harness.equal(false, vim.api.nvim_win_is_valid(card_win))
end)

harness.run()
