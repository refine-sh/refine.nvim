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
    source_syntax = "mixed",
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
    source_syntax = "mixed",
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
    source_syntax = "mixed",
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
    source_syntax = "mixed",
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

harness.test("refuses Apply after the buffer becomes structurally ineligible", function()
  vim.cmd.enew({ bang = true })
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "cat" })
  local source = require("refine.nvim.source").new({
    bufnr = bufnr,
    source_syntax = "mixed",
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

harness.run()
