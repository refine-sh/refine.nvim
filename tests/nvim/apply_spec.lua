local root = vim.fn.getcwd()
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  root .. "/tests/?.lua",
  package.path,
}, ";")

local harness = require("support.harness")

harness.test("applies disjoint edits as one mutation and one undo entry", function()
  vim.cmd.enew({ bang = true })
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "A cat and cat.", "Next" })
  vim.bo[bufnr].fileformat = "dos"
  vim.bo[bufnr].endofline = false
  local undo_levels = vim.bo[bufnr].undolevels
  vim.bo[bufnr].undolevels = -1
  vim.bo[bufnr].undolevels = undo_levels

  local source = require("refine.nvim.source").new({
    bufnr = bufnr,
    source_syntax = "plainText",
    run_id = "apply",
  })
  local before = source:snapshot()
  local line_events = 0
  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function()
      line_events = line_events + 1
    end,
  })

  local outcome = require("refine.nvim.apply").apply(source, {
    expectedRevision = before.revision,
    sourceId = "document",
    edits = {
      {
        range = { location = 10, length = 3 },
        expectedText = "cat",
        replacement = "dog",
      },
      {
        range = { location = 2, length = 3 },
        expectedText = "cat",
        replacement = "fox",
      },
    },
  })

  harness.equal("applied", outcome.status)
  harness.equal("A fox and dog.\nNext", outcome.snapshot.sources[1].text)
  harness.equal(1, line_events)
  harness.equal("dos", vim.bo[bufnr].fileformat)
  harness.equal(false, vim.bo[bufnr].endofline)

  vim.api.nvim_set_current_buf(bufnr)
  vim.cmd.undo()
  harness.equal({ "A cat and cat.", "Next" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, true))
end)

harness.test("maps visible cursors through semantic edits", function()
  vim.cmd.only()
  vim.cmd.enew({ bang = true })
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "A cat and dog." })
  local first_window = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_cursor(first_window, { 1, 6 })
  vim.cmd.split()
  local second_window = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(second_window, bufnr)
  vim.api.nvim_win_set_cursor(second_window, { 1, 13 })

  local source = require("refine.nvim.source").new({
    bufnr = bufnr,
    source_syntax = "plainText",
    run_id = "cursors",
  })
  local before = source:snapshot()
  local outcome = require("refine.nvim.apply").apply(source, {
    expectedRevision = before.revision,
    sourceId = "document",
    edits = {
      {
        range = { location = 10, length = 3 },
        expectedText = "dog",
        replacement = "wolfhound",
      },
      {
        range = { location = 2, length = 3 },
        expectedText = "cat",
        replacement = "kitten",
      },
    },
  })

  harness.equal("applied", outcome.status)
  harness.equal({ 1, 9 }, vim.api.nvim_win_get_cursor(first_window))
  harness.equal({ 1, 22 }, vim.api.nvim_win_get_cursor(second_window))
end)

harness.test("keeps an Insert-mode Apply separate from following typing", function()
  vim.cmd.only()
  vim.cmd.enew({ bang = true })
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "cat" })
  local undo_levels = vim.bo[bufnr].undolevels
  vim.bo[bufnr].undolevels = -1
  vim.bo[bufnr].undolevels = undo_levels
  local source = require("refine.nvim.source").new({
    bufnr = bufnr,
    source_syntax = "plainText",
    run_id = "insert-undo",
  })
  local before = source:snapshot()
  local outcome
  vim.keymap.set("i", "<F5>", function()
    outcome = require("refine.nvim.apply").apply(source, {
      expectedRevision = before.revision,
      sourceId = "document",
      edits = {
        {
          range = { location = 0, length = 3 },
          expectedText = "cat",
          replacement = "dog",
        },
      },
    })
  end, { buffer = bufnr })

  vim.api.nvim_feedkeys(vim.keycode("A<F5>X<Esc>"), "xt", false)
  harness.equal("applied", outcome.status)
  harness.equal({ "dogX" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, true))
  vim.cmd.undo()
  harness.equal({ "dog" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, true))
  vim.cmd.undo()
  harness.equal({ "cat" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, true))
end)

harness.test("rejects ambiguous edits at the same source location before mutation", function()
  vim.cmd.enew({ bang = true })
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "ab" })
  local source = require("refine.nvim.source").new({
    bufnr = bufnr,
    source_syntax = "plainText",
    run_id = "ambiguous",
  })
  local before = source:snapshot()
  local outcome = require("refine.nvim.apply").apply(source, {
    expectedRevision = before.revision,
    sourceId = "document",
    edits = {
      { range = { location = 1, length = 0 }, expectedText = "", replacement = "x" },
      { range = { location = 1, length = 0 }, expectedText = "", replacement = "y" },
    },
  })
  harness.equal("unavailable", outcome.status)
  harness.equal({ "ab" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, true))
end)

harness.test("applies at scalar boundaries but rejects a split surrogate pair", function()
  vim.cmd.enew({ bang = true })
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "é" })
  local source = require("refine.nvim.source").new({
    bufnr = bufnr,
    source_syntax = "plainText",
    run_id = "scalar-boundary",
  })
  local before = source:snapshot()

  local applied = require("refine.nvim.apply").apply(source, {
    expectedRevision = before.revision,
    sourceId = "document",
    edits = {
      { range = { location = 0, length = 1 }, expectedText = "e", replacement = "a" },
    },
  })

  harness.equal("applied", applied.status)
  harness.equal({ "á" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, true))

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "😀" })
  local emoji = source:snapshot()
  local rejected = require("refine.nvim.apply").apply(source, {
    expectedRevision = emoji.revision,
    sourceId = "document",
    edits = {
      { range = { location = 0, length = 1 }, expectedText = "", replacement = "x" },
    },
  })

  harness.equal("unavailable", rejected.status)
  harness.equal({ "😀" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, true))
end)

harness.test("refuses Apply after the buffer becomes structurally ineligible", function()
  vim.cmd.enew({ bang = true })
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "cat" })
  local source = require("refine.nvim.source").new({
    bufnr = bufnr,
    source_syntax = "plainText",
    run_id = "ineligible",
  })
  local before = source:snapshot()
  local request = {
    expectedRevision = before.revision,
    sourceId = "document",
    edits = {
      { range = { location = 0, length = 3 }, expectedText = "cat", replacement = "dog" },
    },
  }

  vim.bo[bufnr].binary = true
  local binary = require("refine.nvim.apply").apply(source, request)
  harness.equal("unavailable", binary.status)
  harness.equal({ "cat" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, true))

  vim.bo[bufnr].binary = false
  vim.bo[bufnr].buftype = "nofile"
  local special = require("refine.nvim.apply").apply(source, request)
  harness.equal("unavailable", special.status)
  harness.equal({ "cat" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, true))
end)

local function apply_host_quote_result(expected, observed, fail_after_write)
  vim.cmd.enew({ bang = true })
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "Before" })
  local source = require("refine.nvim.source").new({
    bufnr = bufnr,
    source_syntax = "plainText",
    run_id = "quotes",
  })
  local before = source:snapshot()
  local original_set_text = vim.api.nvim_buf_set_text
  local dispatches = 0
  vim.api.nvim_buf_set_text = function(buffer, start_row, start_col, end_row, end_col, replacement)
    dispatches = dispatches + 1
    harness.equal(bufnr, buffer)
    harness.equal({ expected }, replacement)
    original_set_text(buffer, start_row, start_col, end_row, end_col, { observed })
    if fail_after_write then
      error("write outcome unknown")
    end
  end

  local ok, outcome = xpcall(function()
    return require("refine.nvim.apply").apply(source, {
      expectedRevision = before.revision,
      sourceId = "document",
      edits = {
        { range = { location = 0, length = 6 }, expectedText = "Before", replacement = expected },
      },
    })
  end, debug.traceback)
  vim.api.nvim_buf_set_text = original_set_text
  assert(ok, outcome)
  harness.equal(1, dispatches)
  harness.equal(observed, outcome.snapshot.sources[1].text)
  harness.equal({ observed }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, true))
  assert(before.revision ~= outcome.snapshot.revision)
  return outcome
end

for _, pair in ipairs({
  { "It's ready.", "It’s ready." },
  { "It’s ready.", "It's ready." },
  { "'Ready'", "‘Ready’" },
  { '"Ready"', "“Ready”" },
  { "“Ready”", '"Ready"' },
  { '😀 é says "it\'s ready".', "😀 é says “it’s ready”." },
}) do
  harness.test("reports actual host quote styles after successful dispatch: " .. pair[1], function()
    local outcome = apply_host_quote_result(pair[1], pair[2])
    harness.equal("applied", outcome.status)
  end)
end

for _, pair in ipairs({
  { "It's ready.", "It′s ready." },
  { "It's ready.", "Itʼs ready." },
  { "It's ready.", "It‚s ready." },
  { "'Ready'", "`Ready`" },
  { "'Ready'", "“Ready”" },
  { "It's ready.", "Its ready." },
  { "It's ready.", "It’s  ready." },
  { "It's ready.", "It’s late." },
  { "A'B", "AB’" },
  { '😀 "Ready"', "😃 “Ready”" },
}) do
  harness.test("keeps other host changes indeterminate: " .. pair[2], function()
    local outcome = apply_host_quote_result(pair[1], pair[2])
    harness.equal("indeterminate", outcome.status)
  end)
end

harness.test("a thrown write remains indeterminate even when only quote styles changed", function()
  local outcome = apply_host_quote_result("It's ready.", "It’s ready.", true)
  harness.equal("indeterminate", outcome.status)
end)

harness.run()
