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

local function present(options)
  options = options or {}
  vim.cmd.only()
  vim.cmd.enew({ bang = true })
  local bufnr = vim.api.nvim_get_current_buf()
  local owner_win = vim.api.nvim_get_current_win()
  local source = options.source or "bad text"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { source })
  vim.api.nvim_win_set_cursor(owner_win, options.initial_cursor or { 1, 0 })

  local host = require("refine.nvim.host").new({
    bufnr = bufnr,
    source_syntax = "plainText",
    run_id = options.run_id or "presentation-contract",
  })
  local suggestion = {
    id = "suggestion",
    sourceId = "document",
    kind = "grammar",
    attribution = {
      languageDisplayName = "English (American)",
      textDirection = "ltr",
      checkModelDisplayName = "On-Device",
    },
    activationRange = options.activation_range or { location = 0, length = #source },
    highlightRanges = { { location = 0, length = math.min(3, #source) } },
    diff = options.diff or {
      { kind = "delete", text = "bad" },
      { kind = "insert", text = "good" },
    },
    availableActions = options.available_actions or { "apply", "dismiss", "explain", "report" },
  }
  local snapshot = {
    documentRevision = host.source:snapshot().revision,
    presentationRevision = 1,
    checkGeneration = 1,
    state = { type = "complete", coverage = "full" },
    appearance = vim.deepcopy(options.appearance or appearance),
    interaction = options.interaction or {
      automaticChecksEnabled = true,
      quickApply = {
        enabled = false,
        applyKey = "tab",
        dismissKey = "escape",
        activationStyle = "highlightChanges",
      },
    },
    suggestions = { suggestion },
  }
  if options.before_present then
    options.before_present(bufnr, owner_win, snapshot, suggestion)
  end
  host:present(snapshot, options.actions or {})
  if options.open_card ~= false then
    harness.equal(true, host:show())
  end
  return host, suggestion, snapshot, owner_win
end

local function card_buffer(host)
  return vim.api.nvim_win_get_buf(host.presentation:card_window())
end

local function buffer_mapping(bufnr, lhs)
  return vim.api.nvim_buf_call(bufnr, function()
    return vim.fn.maparg(lhs, "n", false, true)
  end)
end

harness.test("renders diff runs inline with Refine colors and visible whitespace", function()
  local diff = {
    { kind = "unchanged", text = "The " },
    { kind = "delete", text = "old " },
    { kind = "insert", text = "new " },
    { kind = "unchanged", text = "line\nkeeps " },
    { kind = "delete", text = "second\t" },
    { kind = "insert", text = "next " },
    { kind = "unchanged", text = "line" },
  }
  local protocol_diff = vim.deepcopy(diff)
  local host, suggestion = present({
    diff = diff,
    available_actions = { "apply" },
  })
  local card_buf = card_buffer(host)

  harness.equal({
    "English (American) · On-Device",
    "",
    "The old·new·line",
    "keeps second→next·line",
    "",
    "[a] Apply  [q] Close",
  }, vim.api.nvim_buf_get_lines(card_buf, 0, -1, true))
  harness.equal(protocol_diff, suggestion.diff)

  local highlights = {}
  local groups = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(card_buf, -1, 0, -1, { details = true })) do
    local group = mark[4].hl_group
    if group then
      groups[group] = (groups[group] or 0) + 1
      highlights[#highlights + 1] = {
        row = mark[2],
        start_col = mark[3],
        end_col = mark[4].end_col,
        group = group,
      }
    end
  end
  harness.equal({
    { row = 0, start_col = 0, end_col = 31, group = "RefineCardHint" },
    { row = 2, start_col = 4, end_col = 9, group = "RefineDeletion" },
    { row = 2, start_col = 9, end_col = 14, group = "RefineAddition" },
    { row = 3, start_col = 6, end_col = 15, group = "RefineDeletion" },
    { row = 3, start_col = 15, end_col = 21, group = "RefineAddition" },
    { row = 5, start_col = 0, end_col = 3, group = "RefineCardKey" },
    { row = 5, start_col = 11, end_col = 14, group = "RefineCardKey" },
  }, highlights)
  harness.equal(2, groups.RefineAddition)
  harness.equal(2, groups.RefineDeletion)
  harness.equal(0x34C759, vim.api.nvim_get_hl(0, { name = "RefineAddition", link = false }).fg)
  harness.equal(0xFF3B30, vim.api.nvim_get_hl(0, { name = "RefineDeletion", link = false }).fg)
  harness.equal(true, vim.api.nvim_get_hl(0, { name = "RefineAddition", link = false }).bold)
  harness.equal(true, vim.api.nvim_get_hl(0, { name = "RefineDeletion", link = false }).strikethrough)

  vim.api.nvim_set_hl(0, "RefineAddition", {})
  vim.api.nvim_set_hl(0, "RefineDeletion", {})
  host:refresh_highlights()
  harness.equal(0x34C759, vim.api.nvim_get_hl(0, { name = "RefineAddition", link = false }).fg)
  harness.equal(0xFF3B30, vim.api.nvim_get_hl(0, { name = "RefineDeletion", link = false }).fg)
  host:deactivate()
end)

harness.test("draws a combining-glyph midline over deleted text", function()
  local host = present({
    diff = {
      { kind = "unchanged", text = "She " },
      { kind = "delete", text = "go" },
      { kind = "insert", text = "went" },
      { kind = "unchanged", text = " home." },
    },
    available_actions = { "apply" },
  })
  local card_buf = card_buffer(host)

  harness.equal("She gowent home.", vim.api.nvim_buf_get_lines(card_buf, 2, 3, true)[1])

  local midlines = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(card_buf, -1, 0, -1, { details = true })) do
    local virtual_text = mark[4].virt_text
    if virtual_text then
      midlines[#midlines + 1] = {
        row = mark[2],
        col = mark[3],
        text = virtual_text[1][1],
        group = virtual_text[1][2],
        position = mark[4].virt_text_pos,
      }
    end
  end
  harness.equal({
    { row = 2, col = 4, text = "g̶", group = "RefineDeletion", position = "overlay" },
    { row = 2, col = 5, text = "o̶", group = "RefineDeletion", position = "overlay" },
  }, midlines)
  host:deactivate()
end)

harness.test("bounds combining-glyph midlines for large deletions", function()
  local deletion = string.rep("x", 4097)
  local host = present({
    diff = { { kind = "delete", text = deletion } },
    available_actions = { "apply" },
  })
  local card_buf = card_buffer(host)
  local midline_count = 0
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(card_buf, -1, 0, -1, { details = true })) do
    if mark[4].virt_text then
      midline_count = midline_count + 1
    end
  end

  harness.equal(deletion, vim.api.nvim_buf_get_lines(card_buf, 2, 3, true)[1])
  harness.equal(4096, midline_count)
  host:deactivate()
end)

harness.test("marks changed newlines while keeping their line break", function()
  local host = present({
    diff = {
      { kind = "unchanged", text = "first" },
      { kind = "delete", text = "\n" },
      { kind = "insert", text = " " },
      { kind = "unchanged", text = "second" },
    },
    available_actions = { "apply" },
  })
  local card_buf = card_buffer(host)

  harness.equal({
    "English (American) · On-Device",
    "",
    "first↵",
    "·second",
    "",
    "[a] Apply  [q] Close",
  }, vim.api.nvim_buf_get_lines(card_buf, 0, -1, true))

  local highlights = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(card_buf, -1, 0, -1, { details = true })) do
    if mark[4].hl_group then
      highlights[#highlights + 1] = {
        row = mark[2],
        start_col = mark[3],
        end_col = mark[4].end_col,
        group = mark[4].hl_group,
      }
    end
  end
  harness.equal({
    { row = 0, start_col = 0, end_col = 31, group = "RefineCardHint" },
    { row = 2, start_col = 5, end_col = 8, group = "RefineDeletion" },
    { row = 3, start_col = 0, end_col = 2, group = "RefineAddition" },
    { row = 5, start_col = 0, end_col = 3, group = "RefineCardKey" },
    { row = 5, start_col = 11, end_col = 14, group = "RefineCardKey" },
  }, highlights)
  host:deactivate()
end)

harness.test("does not add a body row for an empty diff", function()
  local host = present({
    diff = {},
    available_actions = { "apply" },
  })

  harness.equal({
    "English (American) · On-Device",
    "",
    "",
    "[a] Apply  [q] Close",
  }, vim.api.nvim_buf_get_lines(card_buffer(host), 0, -1, true))
  host:deactivate()
end)

harness.test("identifies an unsupported Apply shortcut without hiding Apply availability", function()
  local host = present({
    open_card = false,
    available_actions = { "apply" },
    interaction = {
      automaticChecksEnabled = true,
      quickApply = {
        enabled = true,
        applyKey = "rightShift",
        dismissKey = "escape",
        activationStyle = "showTipAndHighlight",
      },
    },
  })

  local tips = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(host.bufnr, -1, 0, -1, { details = true })) do
    if mark[4].virt_text then
      local chunks = {}
      for _, chunk in ipairs(mark[4].virt_text) do
        chunks[#chunks + 1] = chunk[1]
      end
      tips[#tips + 1] = table.concat(chunks)
    end
  end

  harness.equal({ " Apply shortcut unavailable · [Esc] Cancel" }, tips)
  host:deactivate()
end)

harness.test("shows how to configure an explicit mapping when the Apply shortcut is unsupported", function()
  local host = present({
    available_actions = { "apply" },
    interaction = {
      automaticChecksEnabled = true,
      quickApply = {
        enabled = true,
        applyKey = "rightShift",
        dismissKey = "escape",
        activationStyle = "showTipAndHighlight",
      },
    },
  })

  local card_lines = vim.api.nvim_buf_get_lines(card_buffer(host), 0, -1, true)
  harness.equal({
    "Right Shift cannot be intercepted by Neovim.",
    "Configure another Apply key in Refine, or add a Neovim mapping:",
    'vim.keymap.set("n", "<leader>ra", "<Plug>(RefineApply)")',
    "",
    "[a] Apply  [q] Close",
  }, vim.list_slice(card_lines, #card_lines - 4))
  host:deactivate()
end)

harness.test("activates quick actions at either activation range endpoint", function()
  local host = present({
    open_card = false,
    initial_cursor = { 1, 3 },
    activation_range = { location = 0, length = 3 },
    available_actions = { "apply" },
    interaction = {
      automaticChecksEnabled = true,
      quickApply = {
        enabled = true,
        applyKey = "tab",
        dismissKey = "escape",
        activationStyle = "highlightChanges",
      },
    },
  })
  local bufnr = host.bufnr

  harness.equal("Refine Apply suggestion", buffer_mapping(bufnr, "<Tab>").desc)
  vim.api.nvim_win_set_cursor(0, { 1, 4 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr })
  harness.equal({}, buffer_mapping(bufnr, "<Tab>"))
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr })
  harness.equal("Refine Apply suggestion", buffer_mapping(bufnr, "<Tab>").desc)
  host:deactivate()
end)

harness.test("keeps a zero-length activation range exact", function()
  local host = present({
    open_card = false,
    initial_cursor = { 1, 3 },
    activation_range = { location = 3, length = 0 },
    available_actions = { "apply" },
    interaction = {
      automaticChecksEnabled = true,
      quickApply = {
        enabled = true,
        applyKey = "tab",
        dismissKey = "escape",
        activationStyle = "highlightChanges",
      },
    },
  })
  local bufnr = host.bufnr
  harness.equal("Refine Apply suggestion", buffer_mapping(bufnr, "<Tab>").desc)
  vim.api.nvim_win_set_cursor(0, { 1, 2 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr })
  harness.equal({}, buffer_mapping(bufnr, "<Tab>"))
  vim.api.nvim_win_set_cursor(0, { 1, 3 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr })
  harness.equal("Refine Apply suggestion", buffer_mapping(bufnr, "<Tab>").desc)
  host:deactivate()
end)

harness.test("retains active quick ownership across same-generation replacements", function()
  local host, _, snapshot = present({
    open_card = false,
    available_actions = { "apply" },
    interaction = {
      automaticChecksEnabled = true,
      quickApply = {
        enabled = true,
        applyKey = "tab",
        dismissKey = "escape",
        activationStyle = "highlightChanges",
      },
    },
  })
  local bufnr = host.bufnr
  harness.equal("Refine Apply suggestion", buffer_mapping(bufnr, "<Tab>").desc)

  local replacement = vim.deepcopy(snapshot)
  replacement.presentationRevision = 2
  replacement.interaction.quickApply.applyKey = "rightArrow"
  host:present(replacement, {})
  harness.equal({}, buffer_mapping(bufnr, "<Tab>"))
  harness.equal("Refine Apply suggestion", buffer_mapping(bufnr, "<Right>").desc)
  host:deactivate()
end)

harness.test("keeps a disabled generation disarmed until an explicit cursor move", function()
  local host, _, snapshot = present({
    open_card = false,
    available_actions = { "apply" },
  })
  local bufnr = host.bufnr
  harness.equal({}, buffer_mapping(bufnr, "<Tab>"))

  local enabled = vim.deepcopy(snapshot)
  enabled.presentationRevision = 2
  enabled.interaction.quickApply.enabled = true
  host:present(enabled, {})
  harness.equal({}, buffer_mapping(bufnr, "<Tab>"))

  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr })
  harness.equal("Refine Apply suggestion", buffer_mapping(bufnr, "<Tab>").desc)
  host:deactivate()
end)

harness.test("exposes only available actions through the footer and card keys", function()
  local native_tabs = 0
  vim.keymap.set("n", "<Tab>", function()
    native_tabs = native_tabs + 1
  end, { desc = "Native Tab" })
  local dismissed = 0
  local host = present({
    available_actions = { "dismiss" },
    interaction = {
      automaticChecksEnabled = true,
      quickApply = {
        enabled = false,
        applyKey = "tab",
        dismissKey = "escape",
        activationStyle = "highlightChanges",
      },
    },
    actions = {
      dismiss = function(_, callback)
        dismissed = dismissed + 1
        callback({ status = "completed" })
      end,
    },
  })
  local card_buf = card_buffer(host)
  local card_lines = vim.api.nvim_buf_get_lines(card_buf, 0, -1, true)
  harness.equal("[d] Dismiss  [q] Close", card_lines[#card_lines])
  harness.equal({}, buffer_mapping(card_buf, "a"))
  harness.equal(1, buffer_mapping(card_buf, "d").buffer)
  harness.equal({}, buffer_mapping(card_buf, "e"))
  harness.equal({}, buffer_mapping(card_buf, "r"))
  harness.equal(1, buffer_mapping(card_buf, "n").buffer)
  harness.equal(1, buffer_mapping(card_buf, "p").buffer)
  harness.equal(1, buffer_mapping(card_buf, "q").buffer)
  harness.equal(0, buffer_mapping(card_buf, "<Tab>").buffer)

  vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "x", false)
  harness.equal(
    true,
    vim.wait(1000, function()
      return native_tabs == 1
    end)
  )
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "x", false)
  harness.equal(
    true,
    vim.wait(1000, function()
      return dismissed == 1 and host.presentation:card_window() == nil
    end)
  )

  vim.keymap.del("n", "<Tab>")
  host:deactivate()
end)

harness.test("keeps Escape as Close when Dismiss is unavailable", function()
  local dismissed = 0
  local host = present({
    available_actions = { "apply" },
    interaction = {
      automaticChecksEnabled = true,
      quickApply = {
        enabled = false,
        applyKey = "tab",
        dismissKey = "escape",
        activationStyle = "highlightChanges",
      },
    },
    actions = {
      dismiss = function()
        dismissed = dismissed + 1
      end,
    },
  })
  local card_buf = card_buffer(host)
  local card_lines = vim.api.nvim_buf_get_lines(card_buf, 0, -1, true)
  harness.equal("[a] Apply  [q] Close", card_lines[#card_lines])

  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "x", false)
  harness.equal(
    true,
    vim.wait(1000, function()
      return host.presentation:card_window() == nil
    end)
  )
  harness.equal(0, dismissed)
  harness.equal(false, vim.api.nvim_buf_is_valid(card_buf))
  host:deactivate()
end)

harness.test("lets FileType refine customize card mappings across rebinds", function()
  local group = vim.api.nvim_create_augroup("RefinePresentationContractFileType", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "refine",
    callback = function(event)
      for _, mapping in ipairs({
        { lhs = "a", desc = "Custom Apply" },
        { lhs = "q", desc = "Custom Close" },
        { lhs = "<Tab>", desc = "Custom Tab" },
        { lhs = "<CR>", desc = "Custom Return" },
      }) do
        vim.keymap.set("n", mapping.lhs, "<Nop>", { buffer = event.buf, desc = mapping.desc })
      end
    end,
  })
  local host, _, snapshot = present({ available_actions = { "apply" } })
  local card_buf = card_buffer(host)

  harness.equal("Custom Apply", buffer_mapping(card_buf, "a").desc)
  harness.equal("Custom Close", buffer_mapping(card_buf, "q").desc)
  harness.equal("Custom Tab", buffer_mapping(card_buf, "<Tab>").desc)

  local same_keys = vim.deepcopy(snapshot)
  same_keys.presentationRevision = 2
  host:present(same_keys, {})
  harness.equal("Custom Apply", buffer_mapping(card_buf, "a").desc)
  harness.equal("Custom Close", buffer_mapping(card_buf, "q").desc)
  harness.equal("Custom Tab", buffer_mapping(card_buf, "<Tab>").desc)

  local changed_key = vim.deepcopy(snapshot)
  changed_key.presentationRevision = 3
  changed_key.interaction.quickApply.applyKey = "return"
  host:present(changed_key, {})
  harness.equal("Custom Apply", buffer_mapping(card_buf, "a").desc)
  harness.equal("Custom Close", buffer_mapping(card_buf, "q").desc)
  harness.equal("Custom Tab", buffer_mapping(card_buf, "<Tab>").desc)
  harness.equal("Refine Apply open card", buffer_mapping(card_buf, "<CR>").desc)

  host:deactivate()
  vim.api.nvim_del_augroup_by_id(group)
end)

harness.test("focuses every card it opens so card keys act immediately", function()
  local applied = 0
  local host, _, _, owner_win = present({
    open_card = false,
    available_actions = { "apply", "dismiss" },
    actions = {
      apply = function(_, callback)
        applied = applied + 1
        callback({ status = "completed" })
      end,
    },
  })

  harness.equal(true, host:next())
  local card_win = host.presentation:card_window()
  harness.equal(card_win, vim.api.nvim_get_current_win())
  harness.equal(
    false,
    vim.tbl_contains(
      vim.api.nvim_buf_get_lines(card_buffer(host), 0, -1, true),
      "Preview · :RefineShow to focus for card keys"
    )
  )

  vim.api.nvim_feedkeys("a", "x", false)
  harness.equal(
    true,
    vim.wait(1000, function()
      return applied == 1 and host.presentation:card_window() == nil
    end)
  )
  harness.equal(owner_win, vim.api.nvim_get_current_win())

  harness.equal(true, host:previous())
  harness.equal(host.presentation:card_window(), vim.api.nvim_get_current_win())
  host:deactivate()
end)

harness.test("owns configured action keys while the card stays unfocused", function()
  local applied = 0
  local dismissed = 0
  local native_tabs = 0
  local native_escapes = 0
  local host, _, _, owner_win = present({
    open_card = false,
    before_present = function(bufnr)
      vim.keymap.set("n", "<Tab>", function()
        native_tabs = native_tabs + 1
      end, { buffer = bufnr, desc = "Prior Tab" })
      vim.keymap.set("n", "<Esc>", function()
        native_escapes = native_escapes + 1
      end, { buffer = bufnr, desc = "Prior Escape" })
    end,
    actions = {
      apply = function(_, callback)
        applied = applied + 1
        callback({ status = "completed" })
      end,
      dismiss = function(_, callback)
        dismissed = dismissed + 1
        callback({ status = "completed" })
      end,
    },
  })
  local bufnr = vim.api.nvim_win_get_buf(owner_win)

  harness.equal(true, host:next())
  vim.api.nvim_set_current_win(owner_win)
  harness.equal("Refine Apply open card", buffer_mapping(bufnr, "<Tab>").desc)
  harness.equal("Refine Dismiss open card", buffer_mapping(bufnr, "<Esc>").desc)
  vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "x", false)
  harness.equal(
    true,
    vim.wait(1000, function()
      return applied == 1 and host.presentation:card_window() == nil
    end)
  )
  harness.equal("Prior Tab", buffer_mapping(bufnr, "<Tab>").desc)
  harness.equal("Prior Escape", buffer_mapping(bufnr, "<Esc>").desc)

  harness.equal(true, host:next())
  vim.api.nvim_set_current_win(owner_win)
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "x", false)
  harness.equal(
    true,
    vim.wait(1000, function()
      return dismissed == 1 and host.presentation:card_window() == nil
    end)
  )
  harness.equal(0, native_tabs)
  harness.equal(0, native_escapes)
  harness.equal("Prior Tab", buffer_mapping(bufnr, "<Tab>").desc)
  harness.equal("Prior Escape", buffer_mapping(bufnr, "<Esc>").desc)

  vim.keymap.del("n", "<Tab>", { buffer = bufnr })
  vim.keymap.del("n", "<Esc>", { buffer = bufnr })
  host:deactivate()
end)

harness.test("rebinds an open busy card across same-suggestion replacements", function()
  local apply_invocations = 0
  local old_dismissals = 0
  local new_dismissals = 0
  local native_tabs = 0
  local native_returns = 0
  local finish_apply
  local host
  local snapshot
  local owner_win
  host, _, snapshot, owner_win = present({
    open_card = false,
    before_present = function(bufnr)
      vim.keymap.set("n", "<Tab>", function()
        native_tabs = native_tabs + 1
      end, { buffer = bufnr, desc = "Prior Tab" })
      vim.keymap.set("n", "<CR>", function()
        native_returns = native_returns + 1
      end, { buffer = bufnr, desc = "Prior Return" })
    end,
    available_actions = { "apply", "dismiss" },
    actions = {
      apply = function(_, callback)
        apply_invocations = apply_invocations + 1
        finish_apply = callback
        local replacement = vim.deepcopy(snapshot)
        replacement.presentationRevision = 2
        replacement.interaction.quickApply.applyKey = "return"
        replacement.interaction.quickApply.dismissKey = "rightArrow"
        replacement.appearance.diff.additionColor = "#123456"
        replacement.suggestions[1].availableActions = { "dismiss" }
        host:present(replacement, {
          dismiss = function(_, done)
            new_dismissals = new_dismissals + 1
            done({ status = "completed" })
          end,
        })
      end,
      dismiss = function(_, callback)
        old_dismissals = old_dismissals + 1
        callback({ status = "completed" })
      end,
    },
  })
  local bufnr = vim.api.nvim_win_get_buf(owner_win)
  harness.equal(true, host:next())
  local card_win = host.presentation:card_window()
  local card_buf = card_buffer(host)
  vim.api.nvim_set_current_win(owner_win)

  vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "x", false)
  harness.equal(
    true,
    vim.wait(1000, function()
      return finish_apply ~= nil
    end)
  )
  harness.equal(card_win, host.presentation:card_window())
  harness.equal(card_buf, card_buffer(host))
  harness.equal(owner_win, vim.api.nvim_get_current_win())
  harness.equal("Prior Tab", buffer_mapping(bufnr, "<Tab>").desc)
  harness.equal("Refine Apply open card", buffer_mapping(bufnr, "<CR>").desc)
  harness.equal("Refine Dismiss open card", buffer_mapping(bufnr, "<Right>").desc)
  harness.equal(0x123456, vim.api.nvim_get_hl(0, { name = "RefineAddition", link = false }).fg)
  local text = table.concat(vim.api.nvim_buf_get_lines(card_buf, 0, -1, true), "\n")
  harness.matches("Applying…", text)
  harness.matches("%[d%] Dismiss", text)
  harness.equal(false, text:match("%[a%] Apply") ~= nil)

  vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "x", false)
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  harness.equal(
    true,
    vim.wait(1000, function()
      return native_tabs == 1
    end)
  )
  harness.equal(1, apply_invocations)
  harness.equal(0, native_returns)

  finish_apply({ status = "unavailable", reason = "readOnly" })
  harness.equal("Prior Return", buffer_mapping(bufnr, "<CR>").desc)
  vim.api.nvim_feedkeys(vim.keycode("<Right>"), "x", false)
  harness.equal(
    true,
    vim.wait(1000, function()
      return new_dismissals == 1 and host.presentation:card_window() == nil
    end)
  )
  harness.equal(0, old_dismissals)

  vim.keymap.del("n", "<Tab>", { buffer = bufnr })
  vim.keymap.del("n", "<CR>", { buffer = bufnr })
  host:deactivate()
end)

harness.test("keeps Report completion feedback across an availability replacement", function()
  local host
  local snapshot
  local card_win
  host, _, snapshot = present({
    available_actions = { "report" },
    actions = {
      report = function(_, callback)
        local replacement = vim.deepcopy(snapshot)
        replacement.presentationRevision = 2
        replacement.suggestions[1].availableActions = {}
        host:present(replacement, {})
        callback({ status = "completed" })
      end,
    },
  })
  card_win = host.presentation:card_window()

  harness.equal(true, host:action("report"))
  harness.equal(card_win, host.presentation:card_window())
  local lines = vim.api.nvim_buf_get_lines(card_buffer(host), 0, -1, true)
  harness.equal(true, vim.tbl_contains(lines, "Reported. Thank you."))
  harness.equal("[q] Close", lines[#lines])
  host:deactivate()
end)

harness.test("uses explanation direction until a newer check supersedes the stream", function()
  local update
  local cancelled = 0
  local host
  local snapshot
  host, _, snapshot = present({
    available_actions = { "explain" },
    actions = {
      explain = function(_, on_update, on_end)
        update = on_update
        on_update({
          status = "started",
          attribution = {
            languageDisplayName = "Arabic",
            textDirection = "rtl",
            modelDisplayName = "Remote Model",
          },
        })
        local replacement = vim.deepcopy(snapshot)
        replacement.presentationRevision = 2
        replacement.suggestions[1].availableActions = {}
        host:present(replacement, {})
        return function()
          cancelled = cancelled + 1
        end
      end,
    },
  })
  local card_win = host.presentation:card_window()

  harness.equal(false, vim.wo[card_win].rightleft)
  harness.equal(true, host:action("explain"))
  harness.equal(card_win, host.presentation:card_window())
  harness.equal(true, vim.wo[card_win].rightleft)
  update({ status = "streaming", text = "Streaming explanation" })
  harness.equal(
    true,
    vim.tbl_contains(vim.api.nvim_buf_get_lines(card_buffer(host), 0, -1, true), "Streaming explanation")
  )

  local same_lineage = vim.deepcopy(snapshot)
  same_lineage.presentationRevision = 3
  same_lineage.suggestions[1].availableActions = {}
  same_lineage.suggestions[1].attribution.textDirection = "ltr"
  host:present(same_lineage, {})
  harness.equal(card_win, host.presentation:card_window())
  harness.equal(true, vim.wo[card_win].rightleft)

  local newer_check = vim.deepcopy(snapshot)
  newer_check.presentationRevision = 4
  newer_check.checkGeneration = 2
  newer_check.suggestions[1].availableActions = {}
  host:present(newer_check, {})
  harness.equal(1, cancelled)
  harness.equal(true, host:show())
  local newer_card = host.presentation:card_window()
  harness.equal(false, vim.wo[newer_card].rightleft)
  host:deactivate()
end)

harness.test("closes and cancels a same-id card when check generation advances", function()
  local cancelled = 0
  local host, _, snapshot = present({
    available_actions = { "explain" },
    actions = {
      explain = function()
        return function()
          cancelled = cancelled + 1
        end
      end,
    },
  })
  harness.equal(true, host:action("explain"))

  local next_generation = vim.deepcopy(snapshot)
  next_generation.presentationRevision = 2
  next_generation.checkGeneration = 2
  host:present(next_generation, {})
  harness.equal(nil, host.presentation:card_window())
  harness.equal(1, cancelled)
  host:deactivate()
end)

harness.test("shows explanation attribution and clears a synchronous terminal stream", function()
  local cancelled = 0
  local host = present({
    available_actions = { "explain" },
    actions = {
      explain = function(_, on_update, on_end)
        on_update({
          status = "started",
          attribution = {
            languageDisplayName = "English (American)",
            textDirection = "ltr",
            modelDisplayName = "Remote Model",
          },
        })
        on_update({ status = "completed", text = "Use singular agreement." })
        on_end()
        return function()
          cancelled = cancelled + 1
        end
      end,
    },
  })

  harness.equal(true, host:action("explain"))
  local lines = vim.api.nvim_buf_get_lines(card_buffer(host), 0, -1, true)
  harness.equal(true, vim.tbl_contains(lines, "Explanation · English (American) · Remote Model"))
  harness.equal(true, vim.tbl_contains(lines, "Use singular agreement."))
  host:close()
  harness.equal(0, cancelled)
  host:deactivate()
end)

harness.test("warns inline and once when Apply mutation is indeterminate", function()
  local notifications = {}
  local original_notify_once = vim.notify_once
  vim.notify_once = function(message, level)
    notifications[#notifications + 1] = { message = message, level = level }
    return true
  end
  local host = present({
    available_actions = { "apply" },
    actions = {
      apply = function(_, callback)
        callback({ status = "unavailable", reason = "mutationIndeterminate" })
      end,
    },
  })

  harness.equal(true, host:action("apply"))
  vim.notify_once = original_notify_once
  local text = table.concat(vim.api.nvim_buf_get_lines(card_buffer(host), 0, -1, true), "\n")
  harness.matches("WARNING:", text)
  harness.matches("may have changed", text)
  harness.equal(1, #notifications)
  harness.matches("could not confirm", notifications[1].message)
  harness.equal(vim.log.levels.ERROR, notifications[1].level)
  host:deactivate()
end)

harness.test("notifies actionable async failures for explicit actions without a card", function()
  local notifications = {}
  local original_notify = vim.notify
  vim.notify = function(message, level)
    notifications[#notifications + 1] = { message = message, level = level }
  end
  local finish_report
  local explanation_update
  local host = present({
    open_card = false,
    available_actions = { "report", "explain" },
    actions = {
      report = function(_, callback)
        finish_report = callback
      end,
      explain = function(_, on_update)
        explanation_update = on_update
        return function() end
      end,
    },
  })

  harness.equal(true, host:action("report"))
  finish_report({ status = "unavailable", reason = "reportingUnavailable" })
  harness.equal(true, host:action("explain"))
  explanation_update({ status = "stale" })
  vim.notify = original_notify

  harness.equal(2, #notifications)
  harness.matches("Report", notifications[1].message)
  harness.matches(":checkhealth refine", notifications[1].message)
  harness.matches("Explain", notifications[2].message)
  harness.matches(":RefineCheck", notifications[2].message)
  host:deactivate()
end)

harness.test("focuses source-highlight clicks without shadowing mouse mappings", function()
  local previous_mouse = vim.o.mouse
  vim.o.mouse = "a"
  local observer_count = vim.on_key()
  local native_clicks = 0
  local dismissed = 0
  local host, _, _, owner_win = present({
    open_card = false,
    available_actions = { "dismiss" },
    before_present = function(bufnr)
      vim.keymap.set("n", "<LeftMouse>", function()
        native_clicks = native_clicks + 1
      end, { buffer = bufnr, desc = "Existing mouse mapping" })
    end,
    actions = {
      dismiss = function(_, callback)
        dismissed = dismissed + 1
        callback({ status = "completed" })
      end,
    },
  })
  local bufnr = vim.api.nvim_win_get_buf(owner_win)

  harness.equal(observer_count + 1, vim.on_key())
  harness.equal("Existing mouse mapping", buffer_mapping(bufnr, "<LeftMouse>").desc)
  local function click_highlight(expected_native_clicks)
    local highlight = vim.fn.screenpos(owner_win, 1, 1)
    vim.api.nvim_input_mouse("left", "press", "", 0, highlight.row - 1, highlight.col - 1)
    vim.api.nvim_feedkeys(vim.keycode("<LeftMouse>"), "xt", false)
    harness.equal(
      true,
      vim.wait(1000, function()
        return native_clicks == expected_native_clicks and host.presentation:card_window() ~= nil
      end)
    )
    return host.presentation:card_window()
  end

  local card_win = click_highlight(1)
  harness.equal(card_win, vim.api.nvim_get_current_win())
  local card_buf = vim.api.nvim_win_get_buf(card_win)
  harness.equal({}, buffer_mapping(card_buf, "<LeftMouse>"))
  vim.api.nvim_feedkeys("d", "x", false)
  harness.equal(
    true,
    vim.wait(1000, function()
      return dismissed == 1 and host.presentation:card_window() == nil
    end)
  )
  harness.equal(owner_win, vim.api.nvim_get_current_win())

  card_win = click_highlight(2)
  card_buf = vim.api.nvim_win_get_buf(card_win)
  local footer_line = vim.api.nvim_buf_line_count(card_buf)
  local original_getmousepos = vim.fn.getmousepos
  vim.fn.getmousepos = function()
    return { winid = card_win, line = footer_line, column = 2 }
  end
  vim.api.nvim_feedkeys(vim.keycode("<LeftMouse>"), "xt", false)
  local footer_observed = vim.wait(1000, function()
    return dismissed == 2 and host.presentation:card_window() == nil
  end)
  vim.fn.getmousepos = original_getmousepos
  harness.equal(true, footer_observed)

  host:deactivate()
  harness.equal(observer_count, vim.on_key())
  harness.equal("Existing mouse mapping", buffer_mapping(bufnr, "<LeftMouse>").desc)
  vim.keymap.del("n", "<LeftMouse>", { buffer = bufnr })
  vim.o.mouse = previous_mouse
end)

harness.test("keeps only one card open when different highlights are clicked", function()
  local previous_mouse = vim.o.mouse
  vim.o.mouse = "a"
  local host, _, _, owner_win = present({
    source = "bad text and wrong words",
    open_card = false,
    before_present = function(_, _, snapshot, first)
      first.id = "first"
      first.activationRange = { location = 0, length = 3 }
      first.highlightRanges = { vim.deepcopy(first.activationRange) }
      first.diff = {
        { kind = "delete", text = "bad" },
        { kind = "insert", text = "good" },
      }
      local second = vim.deepcopy(first)
      second.id = "second"
      second.activationRange = { location = 13, length = 5 }
      second.highlightRanges = { vim.deepcopy(second.activationRange) }
      second.diff = {
        { kind = "delete", text = "wrong" },
        { kind = "insert", text = "right" },
      }
      snapshot.suggestions = { first, second }
    end,
  })

  local function click(column)
    local position = vim.fn.screenpos(owner_win, 1, column)
    vim.api.nvim_input_mouse("left", "press", "", 0, position.row - 1, position.col - 1)
    vim.api.nvim_feedkeys(vim.keycode("<LeftMouse>"), "xt", false)
  end

  local function card_windows()
    local windows = {}
    for _, winid in ipairs(vim.api.nvim_list_wins()) do
      local bufnr = vim.api.nvim_win_get_buf(winid)
      if vim.bo[bufnr].filetype == "refine" then
        windows[#windows + 1] = winid
      end
    end
    return windows
  end

  local function card_contains(text)
    local card_win = host.presentation:card_window()
    if not card_win then
      return false
    end
    local card_buf = vim.api.nvim_win_get_buf(card_win)
    local content = table.concat(vim.api.nvim_buf_get_lines(card_buf, 0, -1, true), "\n")
    return content:find(text, 1, true) ~= nil
  end

  click(1)
  local first_opened = vim.wait(1000, function()
    return card_contains("good")
  end)
  click(14)
  local second_opened = vim.wait(1000, function()
    return card_contains("right")
  end)

  local open_cards = card_windows()
  host:deactivate()
  for _, winid in ipairs(open_cards) do
    if vim.api.nvim_win_is_valid(winid) then
      vim.api.nvim_win_close(winid, true)
    end
  end
  vim.o.mouse = previous_mouse
  harness.equal(true, first_opened)
  harness.equal(true, second_opened)
  harness.equal(1, #open_cards)
end)

harness.test("focuses cards from Insert mode for card actions", function()
  local applied = 0
  local host = present({
    open_card = false,
    available_actions = { "apply" },
    actions = {
      apply = function(_, callback)
        applied = applied + 1
        callback({ status = "completed" })
      end,
    },
  })
  local bufnr = host.bufnr
  local shown = false
  vim.keymap.set("i", "<F5>", function()
    shown = host:show()
  end, { buffer = bufnr })

  vim.v.errmsg = ""
  vim.api.nvim_feedkeys(vim.keycode("i<F5>a<Esc>"), "xt", false)
  local outcome = {
    applied = applied,
    card_open = host.presentation:card_window() ~= nil,
    errmsg = vim.v.errmsg,
    shown = shown,
  }
  vim.keymap.del("i", "<F5>", { buffer = bufnr })
  host:deactivate()

  harness.equal({ applied = 1, card_open = false, errmsg = "", shown = true }, outcome)
end)

harness.test("frames the card as chrome that separates it from the buffer", function()
  local host = present({ available_actions = { "apply" } })
  local card_win = host.presentation:card_window()
  local config = vim.api.nvim_win_get_config(card_win)

  harness.equal("╭", config.border[1])
  harness.equal({ { " Refine · Grammar ", "RefineCardTitle" } }, config.title)
  harness.equal("left", config.title_pos)
  harness.equal(
    "NormalFloat:RefineCardNormal,FloatBorder:RefineCardBorder,FloatTitle:RefineCardTitle,EndOfBuffer:RefineCardNormal",
    vim.wo[card_win].winhighlight
  )

  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local card = vim.api.nvim_get_hl(0, { name = "RefineCardNormal", link = false })
  local border = vim.api.nvim_get_hl(0, { name = "RefineCardBorder", link = false })
  harness.equal(true, card.bg ~= nil)
  harness.equal(true, card.bg ~= normal.bg)
  harness.equal(card.bg, border.bg)
  harness.equal(true, border.fg ~= nil and border.fg ~= card.bg and border.fg ~= normal.fg)
  local title = vim.api.nvim_get_hl(0, { name = "RefineCardTitle", link = false })
  harness.equal(card.bg, title.bg)
  harness.equal(true, title.bold)
  harness.equal(nil, title.fg)
  local key = vim.api.nvim_get_hl(0, { name = "RefineCardKey", link = false })
  harness.equal(true, key.bold)
  harness.equal(nil, key.fg)
  harness.equal(nil, key.bg)
  host:deactivate()
end)

harness.test("names the suggestion kind in the card title without restyling the card", function()
  local host = present({ available_actions = { "apply" } })
  local grammar = {
    title = vim.api.nvim_win_get_config(host.presentation:card_window()).title,
    border = vim.api.nvim_get_hl(0, { name = "RefineCardBorder", link = false }),
    key = vim.api.nvim_get_hl(0, { name = "RefineCardKey", link = false }),
  }
  host:deactivate()

  for kind, label in pairs({ fluency = " Refine · Fluency ", mixed = " Refine · Grammar & Fluency " }) do
    local next_host = present({
      available_actions = { "apply" },
      before_present = function(_, _, _, suggestion)
        suggestion.kind = kind
      end,
    })

    harness.equal(
      { { label, "RefineCardTitle" } },
      vim.api.nvim_win_get_config(next_host.presentation:card_window()).title
    )
    harness.equal(grammar.border, vim.api.nvim_get_hl(0, { name = "RefineCardBorder", link = false }))
    harness.equal(grammar.key, vim.api.nvim_get_hl(0, { name = "RefineCardKey", link = false }))
    next_host:deactivate()
  end

  harness.equal({ { " Refine · Grammar ", "RefineCardTitle" } }, grammar.title)
end)

harness.test("keeps buffer highlights in the color of each suggestion kind", function()
  local host = present({ available_actions = { "apply" } })
  local marks = vim.api.nvim_buf_get_extmarks(host.bufnr, -1, 0, -1, { details = true })
  harness.equal("RefineGrammar", marks[1][4].hl_group)
  host:deactivate()

  local fluency = present({
    available_actions = { "apply" },
    before_present = function(_, _, _, suggestion)
      suggestion.kind = "fluency"
    end,
  })
  marks = vim.api.nvim_buf_get_extmarks(fluency.bufnr, -1, 0, -1, { details = true })
  harness.equal("RefineFluency", marks[1][4].hl_group)
  harness.equal(0xFF2D55, vim.api.nvim_get_hl(0, { name = "RefineGrammar", link = false }).sp)
  harness.equal(0x007AFF, vim.api.nvim_get_hl(0, { name = "RefineFluency", link = false }).sp)
  fluency:deactivate()
end)

harness.test("dims card metadata and emphasizes its action keys", function()
  local host, _, _, owner_win = present({ available_actions = { "apply", "dismiss" } })
  local card_buf = card_buffer(host)

  local function chrome()
    local marks = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(card_buf, -1, 0, -1, { details = true })) do
      local group = mark[4].hl_group
      if group == "RefineCardHint" or group == "RefineCardKey" then
        marks[#marks + 1] = { row = mark[2], start_col = mark[3], end_col = mark[4].end_col, group = group }
      end
    end
    return marks
  end

  local lines = vim.api.nvim_buf_get_lines(card_buf, 0, -1, true)
  harness.equal("[a] Apply  [d] Dismiss  [q] Close", lines[#lines])
  harness.equal({
    { row = 0, start_col = 0, end_col = #lines[1], group = "RefineCardHint" },
    { row = #lines - 1, start_col = 0, end_col = 3, group = "RefineCardKey" },
    { row = #lines - 1, start_col = 11, end_col = 14, group = "RefineCardKey" },
    { row = #lines - 1, start_col = 24, end_col = 27, group = "RefineCardKey" },
  }, chrome())

  vim.api.nvim_set_current_win(owner_win)
  local hint = "Preview · :RefineShow to focus for card keys"
  harness.equal(
    true,
    vim.wait(1000, function()
      return vim.tbl_contains(vim.api.nvim_buf_get_lines(card_buf, 0, -1, true), hint)
    end)
  )
  local hint_row
  for index, line in ipairs(vim.api.nvim_buf_get_lines(card_buf, 0, -1, true)) do
    if line == hint then
      hint_row = index - 1
    end
  end
  local hint_marks = {}
  for _, mark in ipairs(chrome()) do
    if mark.row == hint_row then
      hint_marks[#hint_marks + 1] = mark
    end
  end
  harness.equal({ { row = hint_row, start_col = 0, end_col = #hint, group = "RefineCardHint" } }, hint_marks)
  host:deactivate()
end)

harness.run()
