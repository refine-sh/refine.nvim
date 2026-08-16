local root = vim.fn.getcwd()
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  root .. "/tests/?.lua",
  package.path,
}, ";")

local harness = require("support.harness")

local function buffer_mapping(bufnr, mode, lhs)
  return vim.api.nvim_buf_call(bufnr, function()
    return vim.fn.maparg(lhs, mode, false, true)
  end)
end

local function distinct_lhsraw(mode, lhs)
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.keymap.set(mode, lhs, "<Nop>", { buffer = scratch })
  local raw = vim.api.nvim_buf_call(scratch, function()
    return vim.fn.maparg(lhs, mode, false, true).lhsraw
  end)
  vim.api.nvim_buf_delete(scratch, { force = true })
  return raw
end

local function present_quick_apply(apply_key)
  vim.cmd.only()
  vim.cmd.enew({ bang = true })
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "bad text" })
  vim.api.nvim_win_set_cursor(0, { 1, 1 })

  local host = require("refine.nvim.host").new({
    bufnr = bufnr,
    source_syntax = "plainText",
    run_id = "key-capability",
  })
  local source = host.source:snapshot()
  local applied = 0
  host:present({
    documentRevision = source.revision,
    presentationRevision = 1,
    checkGeneration = 1,
    state = { type = "complete", coverage = "full" },
    appearance = {
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
    },
    interaction = {
      automaticChecksEnabled = true,
      quickApply = {
        enabled = true,
        applyKey = apply_key,
        dismissKey = "rightArrow",
        activationStyle = "highlightChanges",
      },
    },
    suggestions = {
      {
        id = "suggestion",
        sourceId = source.sources[1].sourceId,
        kind = "grammar",
        attribution = {
          languageDisplayName = "English",
          textDirection = "ltr",
          checkModelDisplayName = "On-Device",
        },
        activationRange = { location = 0, length = 3 },
        highlightRanges = { { location = 0, length = 3 } },
        diff = {
          { kind = "delete", text = "bad" },
          { kind = "insert", text = "good" },
        },
        availableActions = { "apply" },
      },
    },
  }, {
    apply = function(_, callback)
      applied = applied + 1
      callback({ status = "completed" })
    end,
  })

  return host, bufnr, function()
    return applied
  end
end

harness.test("Tab ownership preserves distinct Ctrl-I input", function()
  local host, bufnr, applied = present_quick_apply("tab")
  local ctrl_i = distinct_lhsraw("i", "<C-I>")

  vim.api.nvim_feedkeys("i" .. ctrl_i .. vim.keycode("<C-C>"), "xt", false)

  harness.equal(0, applied())
  harness.equal("b\tad text", vim.api.nvim_get_current_line())
  vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "xt", false)
  harness.equal(1, applied())
  host:deactivate()
  harness.equal({}, buffer_mapping(bufnr, "i", "<C-I>"))
end)

harness.test("Escape ownership preserves distinct Ctrl-[ input", function()
  local host, _, applied = present_quick_apply("escape")
  local ctrl_bracket = distinct_lhsraw("i", "<C-[>")

  vim.api.nvim_feedkeys("i" .. ctrl_bracket, "xt", false)

  harness.equal(0, applied())
  harness.equal("n", vim.api.nvim_get_mode().mode)
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "xt", false)
  harness.equal(1, applied())
  host:deactivate()
end)

harness.test("Return ownership preserves distinct Ctrl-M input", function()
  local host, bufnr, applied = present_quick_apply("return")
  local ctrl_m = distinct_lhsraw("i", "<C-M>")

  vim.api.nvim_feedkeys("i" .. ctrl_m .. vim.keycode("<C-C>"), "xt", false)

  harness.equal(0, applied())
  harness.equal({ "b", "ad text" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, true))
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "xt", false)
  harness.equal(1, applied())
  host:deactivate()
end)

local function focus_card(host)
  harness.equal(true, host:show())
  return host.presentation:card_window()
end

harness.test("focused card Tab ownership preserves distinct Ctrl-I input", function()
  local host, _, applied = present_quick_apply("tab")
  local card_win = focus_card(host)
  local ctrl_i = distinct_lhsraw("n", "<C-I>")

  vim.api.nvim_feedkeys(ctrl_i, "xt", false)
  harness.equal(0, applied())
  harness.equal(card_win, host.presentation:card_window())
  vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "xt", false)
  harness.equal(1, applied())
  host:deactivate()
end)

harness.test("focused card Escape ownership preserves distinct Ctrl-[ input", function()
  local host, _, applied = present_quick_apply("escape")
  local card_win = focus_card(host)
  local ctrl_bracket = distinct_lhsraw("n", "<C-[>")

  vim.api.nvim_feedkeys(ctrl_bracket, "xt", false)
  harness.equal(0, applied())
  harness.equal(card_win, host.presentation:card_window())
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "xt", false)
  harness.equal(1, applied())
  host:deactivate()
end)

harness.test("focused card Return ownership preserves distinct Ctrl-M input", function()
  local host, _, applied = present_quick_apply("return")
  local card_win = focus_card(host)
  local ctrl_m = distinct_lhsraw("n", "<C-M>")

  vim.api.nvim_feedkeys(ctrl_m, "xt", false)
  harness.equal(0, applied())
  harness.equal(card_win, host.presentation:card_window())
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "xt", false)
  harness.equal(1, applied())
  host:deactivate()
end)

harness.test("focused card Close preserves distinct Ctrl-[ input", function()
  local host, _, applied = present_quick_apply("tab")
  local card_win = focus_card(host)
  local ctrl_bracket = distinct_lhsraw("n", "<C-[>")

  vim.api.nvim_feedkeys(ctrl_bracket, "xt", false)
  harness.equal(card_win, host.presentation:card_window())
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "xt", false)
  harness.equal(nil, host.presentation:card_window())
  harness.equal(0, applied())
  host:deactivate()
end)

harness.test("transient ownership leaves an existing control-alias mapping untouched", function()
  vim.cmd.only()
  vim.cmd.enew({ bang = true })
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "bad text" })
  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  local ctrl_i = distinct_lhsraw("n", "<C-I>")
  local control_hits = 0
  vim.keymap.set("n", "<C-I>", function()
    control_hits = control_hits + 1
  end, { buffer = bufnr, desc = "User Ctrl-I" })

  local host = require("refine.nvim.host").new({
    bufnr = bufnr,
    source_syntax = "plainText",
    run_id = "existing-control-alias",
  })
  local source = host.source:snapshot()
  host:present({
    documentRevision = source.revision,
    presentationRevision = 1,
    checkGeneration = 1,
    state = { type = "complete", coverage = "full" },
    appearance = {
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
    },
    interaction = {
      automaticChecksEnabled = true,
      quickApply = {
        enabled = true,
        applyKey = "tab",
        dismissKey = "rightArrow",
        activationStyle = "highlightChanges",
      },
    },
    suggestions = {
      {
        id = "suggestion",
        sourceId = source.sources[1].sourceId,
        kind = "grammar",
        attribution = {
          languageDisplayName = "English",
          textDirection = "ltr",
          checkModelDisplayName = "On-Device",
        },
        activationRange = { location = 0, length = 3 },
        highlightRanges = { { location = 0, length = 3 } },
        diff = {
          { kind = "delete", text = "bad" },
          { kind = "insert", text = "good" },
        },
        availableActions = { "apply" },
      },
    },
  }, {})

  vim.api.nvim_feedkeys(ctrl_i, "xt", false)
  harness.equal(1, control_hits)
  harness.equal("User Ctrl-I", buffer_mapping(bufnr, "n", "<C-I>").desc)
  host:deactivate()
  harness.equal("User Ctrl-I", buffer_mapping(bufnr, "n", "<C-I>").desc)
  vim.keymap.del("n", "<C-I>", { buffer = bufnr })
end)

harness.run()
