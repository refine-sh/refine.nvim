local root = vim.fn.getcwd()
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  root .. "/tests/?.lua",
  package.path,
}, ";")

local harness = require("support.harness")

local function present_navigation_preview(host, presentation_revision)
  host:present({
    documentRevision = host.source:snapshot().revision,
    presentationRevision = presentation_revision,
    checkGeneration = 1,
    state = { type = "complete", coverage = "full" },
    appearance = {
      highlight = { style = "underline", grammarColor = "#FF2D55", fluencyColor = "#007AFF" },
      diff = { additionColor = "#34C759", deletionColor = "#FF3B30", showHiddenWhitespace = true },
    },
    interaction = {
      automaticChecksEnabled = true,
      quickApply = {
        enabled = false,
        applyKey = "tab",
        dismissKey = "escape",
        activationStyle = "highlightChanges",
      },
    },
    suggestions = {
      {
        id = "grammar-preview",
        sourceId = "document",
        kind = "grammar",
        attribution = { languageDisplayName = "English", textDirection = "ltr", checkModelDisplayName = "Local" },
        activationRange = { location = 5, length = 3 },
        highlightRanges = { { location = 5, length = 3 } },
        diff = { { kind = "delete", text = "are" }, { kind = "insert", text = "is" } },
        availableActions = { "apply" },
      },
    },
  }, {})
end

harness.test("reports initial active-window attention in UTF-16 source coordinates", function()
  vim.cmd.only()
  vim.cmd.enew({ bang = true })
  local bufnr = vim.api.nvim_get_current_buf()
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "A😀 tail", "Second" })
  vim.api.nvim_win_set_cursor(winid, { 1, 5 })

  local host = require("refine.nvim.host").new({
    bufnr = bufnr,
    winid = winid,
    source_syntax = "plainText",
    run_id = "host-attention",
  })
  local observations = {}
  local detach = host:observe(function(observation)
    observations[#observations + 1] = observation
  end, function() end)

  harness.equal("snapshot", observations[1].type)
  harness.equal({
    type = "attentionChanged",
    revision = "host-attention:1",
    attention = {
      sourceId = "document",
      caretOffset = 3,
      visibleRanges = { { location = 0, length = 15 } },
    },
  }, observations[2])
  detach()
end)

harness.test("reports disjoint visible source ranges around closed folds", function()
  vim.cmd.only()
  vim.cmd.enew({ bang = true })
  local bufnr = vim.api.nvim_get_current_buf()
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "one", "two", "three", "four", "five", "six" })
  vim.wo[winid].foldmethod = "manual"
  vim.api.nvim_win_set_cursor(winid, { 2, 0 })
  vim.cmd("2,4fold")

  local host = require("refine.nvim.host").new({
    bufnr = bufnr,
    winid = winid,
    source_syntax = "plainText",
    run_id = "host-fold",
  })
  local observations = {}
  local detach = host:observe(function(observation)
    observations[#observations + 1] = observation
  end, function() end)

  harness.equal({
    { location = 0, length = 8 },
    { location = 19, length = 8 },
  }, observations[2].attention.visibleRanges)

  vim.cmd("normal! zo")
  host:refresh_view()
  harness.equal(
    true,
    vim.wait(1000, function()
      return #observations >= 3
    end)
  )
  harness.equal("host-fold:1", observations[3].revision)
  harness.equal({ { location = 0, length = 27 } }, observations[3].attention.visibleRanges)
  detach()
end)

harness.test("omits the caret for a noncollapsed native selection", function()
  vim.cmd.only()
  vim.cmd.enew({ bang = true })
  local bufnr = vim.api.nvim_get_current_buf()
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "selection" })
  vim.api.nvim_win_set_cursor(winid, { 1, 0 })

  local host = require("refine.nvim.host").new({
    bufnr = bufnr,
    winid = winid,
    source_syntax = "plainText",
    run_id = "host-selection",
  })
  local observations = {}
  local detach = host:observe(function(observation)
    observations[#observations + 1] = observation
  end, function() end)

  vim.cmd("normal! vl")
  harness.equal(
    true,
    vim.wait(1000, function()
      return #observations >= 3
    end)
  )
  harness.equal(nil, observations[3].attention.caretOffset)

  vim.api.nvim_feedkeys("\27", "x", false)
  harness.equal(
    true,
    vim.wait(1000, function()
      return #observations >= 4
    end)
  )
  harness.equal(1, observations[4].attention.caretOffset)
  detach()
end)

harness.test("coalesces raw caret movement without crossing an explicit-check barrier", function()
  vim.cmd.only()
  vim.cmd.enew({ bang = true })
  local bufnr = vim.api.nvim_get_current_buf()
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "movement" })

  local host = require("refine.nvim.host").new({
    bufnr = bufnr,
    winid = winid,
    source_syntax = "plainText",
    run_id = "host-movement",
  })
  local snapshot_calls = 0
  local snapshot = host.source.snapshot
  host.source.snapshot = function(source)
    snapshot_calls = snapshot_calls + 1
    return snapshot(source)
  end
  local observations = {}
  local detach = host:observe(function(observation)
    observations[#observations + 1] = observation
  end, function() end)
  harness.equal(1, snapshot_calls)

  vim.api.nvim_win_set_cursor(winid, { 1, 1 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr, modeline = false })
  vim.api.nvim_win_set_cursor(winid, { 1, 2 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr, modeline = false })
  harness.equal(2, #observations)
  harness.equal(
    true,
    vim.wait(1000, function()
      return #observations >= 3
    end)
  )
  harness.equal(2, observations[3].attention.caretOffset)
  harness.equal(1, snapshot_calls)

  vim.api.nvim_win_set_cursor(winid, { 1, 3 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr, modeline = false })
  harness.equal(true, host:request_check({}))
  harness.equal("attentionChanged", observations[4].type)
  harness.equal(3, observations[4].attention.caretOffset)
  harness.equal("checkRequested", observations[5].type)
  harness.equal(2, snapshot_calls)
  vim.wait(20)
  harness.equal(5, #observations)
  detach()
end)

harness.test("retains attention while suspended and refreshes from a new active window", function()
  vim.cmd.only()
  vim.cmd.enew({ bang = true })
  local bufnr = vim.api.nvim_get_current_buf()
  local first_win = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "attention" })
  vim.api.nvim_win_set_cursor(first_win, { 1, 1 })

  local host = require("refine.nvim.host").new({
    bufnr = bufnr,
    winid = first_win,
    source_syntax = "plainText",
    run_id = "host-focus",
  })
  local observations = {}
  local detach = host:observe(function(observation)
    observations[#observations + 1] = observation
  end, function() end)

  host:suspend_view()
  vim.api.nvim_win_set_cursor(first_win, { 1, 2 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr, modeline = false })
  vim.wait(20)
  harness.equal(2, #observations)

  vim.cmd("belowright split")
  local second_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_cursor(second_win, { 1, 4 })
  host:reconcile_view(second_win)
  harness.equal(
    true,
    vim.wait(1000, function()
      return #observations >= 3
    end)
  )
  harness.equal(4, observations[3].attention.caretOffset)
  detach()
end)

harness.test("restarts every observation cycle with a snapshot and matching attention", function()
  vim.cmd.only()
  vim.cmd.enew({ bang = true })
  local bufnr = vim.api.nvim_get_current_buf()
  local host = require("refine.nvim.host").new({
    bufnr = bufnr,
    winid = vim.api.nvim_get_current_win(),
    source_syntax = "plainText",
    run_id = "host-reobserve",
  })

  local first = {}
  host:observe(function(observation)
    first[#first + 1] = observation
  end, function() end)()
  local second = {}
  local detach = host:observe(function(observation)
    second[#second + 1] = observation
  end, function() end)

  harness.equal(
    { "snapshot", "attentionChanged" },
    vim.tbl_map(function(observation)
      return observation.type
    end, first)
  )
  harness.equal(
    { "snapshot", "attentionChanged" },
    vim.tbl_map(function(observation)
      return observation.type
    end, second)
  )
  harness.equal(second[1].snapshot.revision, second[2].revision)
  detach()
end)

harness.test("observes complete snapshots before explicit checks", function()
  vim.cmd.enew({ bang = true })
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "First" })

  local host = require("refine.nvim.host").new({
    bufnr = bufnr,
    source_syntax = "plainText",
    run_id = "host",
  })
  local observations = {}
  local ended = false
  local detach = host:observe(function(observation)
    observations[#observations + 1] = observation
  end, function()
    ended = true
  end)

  harness.equal("snapshot", observations[1].type)
  harness.equal("host:1", observations[1].snapshot.revision)
  harness.equal("First", observations[1].snapshot.sources[1].text)
  harness.equal("attentionChanged", observations[2].type)
  harness.equal("host:1", observations[2].revision)

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "Second" })
  harness.equal(
    true,
    vim.wait(1000, function()
      return #observations >= 4
    end)
  )
  harness.equal("snapshot", observations[3].type)
  harness.equal("host:2", observations[3].snapshot.revision)
  harness.equal("attentionChanged", observations[4].type)
  harness.equal("host:2", observations[4].revision)

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "Third" })
  host:request_check({ selection = { sourceId = "document", range = { location = 0, length = 5 } } })
  harness.equal("snapshot", observations[5].type)
  harness.equal("host:3", observations[5].snapshot.revision)
  harness.equal("attentionChanged", observations[6].type)
  harness.equal("host:3", observations[6].revision)
  harness.equal("checkRequested", observations[7].type)
  harness.equal("host:3", observations[7].revision)

  detach()
  harness.equal(false, ended)
end)

harness.test("never reuses a revision after coalesced ABA native edits", function()
  vim.cmd.enew({ bang = true })
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "Alpha" })

  local host = require("refine.nvim.host").new({
    bufnr = bufnr,
    source_syntax = "plainText",
    run_id = "host-aba",
  })
  local observations = {}
  local detach = host:observe(function(observation)
    observations[#observations + 1] = observation
  end, function() end)

  local original_revision = observations[1].snapshot.revision
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "Alpha" })
  harness.equal(original_revision, host.source:snapshot().revision)

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "Beta" })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "Alpha" })

  harness.equal(
    true,
    vim.wait(1000, function()
      return #observations >= 4
    end)
  )
  harness.equal("snapshot", observations[3].type)
  harness.equal("Alpha", observations[3].snapshot.sources[1].text)
  harness.equal(false, original_revision == observations[3].snapshot.revision)
  harness.equal("attentionChanged", observations[4].type)
  harness.equal(observations[3].snapshot.revision, observations[4].revision)
  detach()
end)

harness.test("implements the integration host callback contract", function()
  vim.cmd.enew({ bang = true })
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "Current text" })
  local statuses = {}
  local host = require("refine.nvim.host").new({
    bufnr = bufnr,
    source_syntax = "plainText",
    run_id = "callbacks",
    on_presentation = function(snapshot)
      statuses[#statuses + 1] = snapshot.state.type
    end,
  })
  local revision = host.source:snapshot().revision
  local detach = host:observe(function() end, function() end)

  local validation_error, validation
  host:validate_revision(revision, function(err, value)
    validation_error = err
    validation = value
  end)
  harness.equal(nil, validation_error)
  harness.equal({ status = "current" }, validation)

  local apply_error, outcome
  host:apply({
    sourceId = "other",
    expectedRevision = revision,
    edits = {},
  }, function(err, value)
    apply_error = err
    outcome = value
  end)
  harness.equal(nil, apply_error)
  harness.equal("unavailable", outcome.status)

  local presented_error = "not-called"
  host:present({
    documentRevision = revision,
    state = { type = "pending" },
  }, {}, function(err)
    presented_error = err
  end)
  harness.equal(nil, presented_error)
  harness.equal({ "pending" }, statuses)

  vim.api.nvim_buf_set_text(bufnr, 0, 0, 0, 0, { "New " })
  harness.equal({ "pending", "pending" }, statuses)
  detach()
end)

harness.test("presents and replaces authoritative suggestion highlights", function()
  vim.cmd.enew({ bang = true })
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "This are text." })
  local host = require("refine.nvim.host").new({
    bufnr = bufnr,
    source_syntax = "plainText",
    run_id = "presentation",
  })
  local revision = host.source:snapshot().revision
  local detach = host:observe(function() end, function() end)
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
      enabled = true,
      applyKey = "tab",
      dismissKey = "escape",
      activationStyle = "highlightChanges",
    },
  }

  host:present({
    documentRevision = revision,
    presentationRevision = 1,
    checkGeneration = 1,
    state = { type = "complete", coverage = "full" },
    appearance = appearance,
    interaction = interaction,
    suggestions = {
      {
        id = "grammar-1",
        sourceId = "document",
        kind = "grammar",
        attribution = {
          languageDisplayName = "English (American)",
          textDirection = "ltr",
          checkModelDisplayName = "On-Device",
        },
        activationRange = { location = 5, length = 3 },
        highlightRanges = { { location = 5, length = 3 } },
        diff = {
          { kind = "delete", text = "are" },
          { kind = "insert", text = "is" },
        },
        availableActions = { "apply", "dismiss" },
      },
    },
  }, {})

  local marks = vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, { details = true })
  harness.equal(1, #marks)
  harness.equal(5, marks[1][3])
  harness.equal(8, marks[1][4].end_col)
  harness.equal("RefineGrammar", marks[1][4].hl_group)
  local highlight = vim.api.nvim_get_hl(0, { name = "RefineGrammar", link = false })
  harness.equal(0xFF2D55, highlight.sp)
  harness.equal(true, highlight.underline)

  vim.api.nvim_buf_set_text(bufnr, 0, 5, 0, 8, { "is" })
  harness.equal(
    true,
    vim.wait(1000, function()
      return #vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, {}) == 0
    end)
  )

  host:present({
    documentRevision = revision,
    presentationRevision = 2,
    checkGeneration = 1,
    state = { type = "pending" },
    appearance = appearance,
    interaction = interaction,
    suggestions = {},
  }, {})
  harness.equal({}, vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, {}))
  detach()
end)

harness.test("clears presentation before dispatch even when native mutation errors", function()
  vim.cmd.only()
  vim.cmd.enew({ bang = true })
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "bad text" })
  local host = require("refine.nvim.host").new({
    bufnr = bufnr,
    source_syntax = "plainText",
    run_id = "apply-clear",
  })
  local revision = host.source:snapshot().revision
  host:present({
    documentRevision = revision,
    presentationRevision = 1,
    checkGeneration = 1,
    state = { type = "complete", coverage = "full" },
    appearance = {
      highlight = { style = "underline", grammarColor = "#FF2D55", fluencyColor = "#007AFF" },
      diff = { additionColor = "#34C759", deletionColor = "#FF3B30", showHiddenWhitespace = true },
    },
    interaction = {
      automaticChecksEnabled = true,
      quickApply = { enabled = true, applyKey = "tab", dismissKey = "escape", activationStyle = "highlightChanges" },
    },
    suggestions = {
      {
        id = "apply-clear",
        sourceId = "document",
        kind = "grammar",
        attribution = { languageDisplayName = "English", textDirection = "ltr", checkModelDisplayName = "Local" },
        activationRange = { location = 0, length = 3 },
        highlightRanges = { { location = 0, length = 3 } },
        diff = { { kind = "delete", text = "bad" }, { kind = "insert", text = "good" } },
        availableActions = { "apply" },
      },
    },
  }, {})
  harness.equal(true, host:show())
  local card_buf = vim.api.nvim_win_get_buf(host.presentation:card_window())
  local original_set_text = vim.api.nvim_buf_set_text
  local marks_at_dispatch
  local card_at_dispatch
  vim.api.nvim_buf_set_text = function()
    marks_at_dispatch = vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, {})
    card_at_dispatch = host.presentation:card_window()
    error("forced set_text failure")
  end
  local outcome
  host:apply({
    expectedRevision = revision,
    sourceId = "document",
    edits = {
      { range = { location = 0, length = 3 }, expectedText = "bad", replacement = "good" },
    },
  }, function(_, value)
    outcome = value
  end)
  vim.api.nvim_buf_set_text = original_set_text

  harness.equal({}, marks_at_dispatch)
  harness.equal(nil, card_at_dispatch)
  harness.equal(false, vim.api.nvim_buf_is_valid(card_buf))
  harness.equal("indeterminate", outcome.status)
end)

harness.test("shows and focuses a suggestion card on first invocation", function()
  vim.cmd.only()
  vim.cmd.enew({ bang = true })
  local bufnr = vim.api.nvim_get_current_buf()
  local editor_win = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "This are text." })
  vim.api.nvim_win_set_cursor(editor_win, { 1, 6 })
  local host = require("refine.nvim.host").new({
    bufnr = bufnr,
    source_syntax = "plainText",
    run_id = "card",
  })
  local revision = host.source:snapshot().revision
  local dismissed = {}
  local explained = {}
  host:present({
    documentRevision = revision,
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
        dismissKey = "escape",
        activationStyle = "highlightChanges",
      },
    },
    suggestions = {
      {
        id = "grammar-card",
        sourceId = "document",
        kind = "grammar",
        attribution = {
          languageDisplayName = "English (American)",
          textDirection = "ltr",
          checkModelDisplayName = "On-Device",
        },
        activationRange = { location = 5, length = 3 },
        highlightRanges = { { location = 5, length = 3 } },
        diff = {
          { kind = "delete", text = "are" },
          { kind = "insert", text = "is" },
        },
        availableActions = { "apply", "dismiss", "explain", "report" },
      },
    },
  }, {
    dismiss = function(suggestion_id, callback)
      dismissed[#dismissed + 1] = suggestion_id
      callback({ status = "completed" })
    end,
    explain = function(suggestion_id, on_update, on_end)
      explained[#explained + 1] = suggestion_id
      on_update({ status = "started" })
      on_update({ status = "streaming", text = "Use a singular verb" })
      on_update({ status = "completed", text = "Use a singular verb with ‘This’." })
      on_end()
      return function() end
    end,
  })

  harness.equal(true, host:show())
  local card_win = host.presentation:card_window()
  harness.equal(card_win, vim.api.nvim_get_current_win())
  harness.equal(true, vim.api.nvim_win_is_valid(card_win))
  local card_buf = vim.api.nvim_win_get_buf(card_win)
  harness.equal("refine", vim.bo[card_buf].filetype)
  harness.equal({
    "English (American) · On-Device",
    "",
    "areis",
    "",
    "[a] Apply  [d] Dismiss  [e] Explain  [r] Report  [q] Close",
  }, vim.api.nvim_buf_get_lines(card_buf, 0, -1, true))

  vim.api.nvim_feedkeys("d", "x", false)
  harness.equal(
    true,
    vim.wait(1000, function()
      return dismissed[1] == "grammar-card"
    end)
  )
  harness.equal(editor_win, vim.api.nvim_get_current_win())

  harness.equal(true, host:show())
  harness.equal(true, host:action("explain"))
  harness.equal({ "grammar-card" }, explained)
  harness.equal(
    true,
    vim.tbl_contains(
      vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(host.presentation:card_window()), 0, -1, true),
      "Use a singular verb with ‘This’."
    )
  )
  harness.equal(true, host:action("dismiss"))
  harness.equal("grammar-card", dismissed[2])

  harness.equal(true, host:show())
  vim.api.nvim_set_current_win(editor_win)
  vim.api.nvim_win_set_cursor(editor_win, { 1, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr, modeline = false })
  harness.equal(nil, host.presentation:card_window())
  host:close()
  harness.equal(editor_win, vim.api.nvim_get_current_win())
end)

harness.test("renders insertion-only suggestions at a zero-length range", function()
  vim.cmd.enew({ bang = true })
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "word" })
  local host = require("refine.nvim.host").new({
    bufnr = bufnr,
    source_syntax = "plainText",
    run_id = "insertion",
  })
  host:present({
    documentRevision = host.source:snapshot().revision,
    presentationRevision = 1,
    checkGeneration = 1,
    state = { type = "complete", coverage = "full" },
    appearance = {
      highlight = { style = "underline", grammarColor = "#FF2D55", fluencyColor = "#007AFF" },
      diff = { additionColor = "#34C759", deletionColor = "#FF3B30", showHiddenWhitespace = true },
    },
    interaction = {
      automaticChecksEnabled = true,
      quickApply = { enabled = false, applyKey = "tab", dismissKey = "escape", activationStyle = "highlightChanges" },
    },
    suggestions = {
      {
        id = "insert",
        sourceId = "document",
        kind = "grammar",
        attribution = { languageDisplayName = "English", textDirection = "ltr", checkModelDisplayName = "Local" },
        activationRange = { location = 4, length = 0 },
        highlightRanges = { { location = 4, length = 0 } },
        diff = { { kind = "insert", text = "." } },
        availableActions = { "apply" },
      },
    },
  }, {})
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, { details = true })
  harness.equal(1, #marks)
  harness.equal(true, marks[1][4].virt_text ~= nil)
end)

harness.test("navigates suggestions in document order with wrapping", function()
  vim.cmd.only()
  vim.cmd.enew({ bang = true })
  local bufnr = vim.api.nvim_get_current_buf()
  local editor_win = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "One bad. Two worse." })
  vim.api.nvim_win_set_cursor(editor_win, { 1, 0 })
  local host = require("refine.nvim.host").new({
    bufnr = bufnr,
    source_syntax = "plainText",
    run_id = "navigation",
  })
  local revision = host.source:snapshot().revision
  local function suggestion(id, location, original, replacement)
    return {
      id = id,
      sourceId = "document",
      kind = "grammar",
      attribution = {
        languageDisplayName = "English",
        textDirection = "ltr",
        checkModelDisplayName = "On-Device",
      },
      activationRange = { location = location, length = #original },
      highlightRanges = { { location = location, length = #original } },
      diff = {
        { kind = "delete", text = original },
        { kind = "insert", text = replacement },
      },
      availableActions = { "apply" },
    }
  end
  host:present({
    documentRevision = revision,
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
        enabled = false,
        applyKey = "tab",
        dismissKey = "escape",
        activationStyle = "highlightChanges",
      },
    },
    suggestions = {
      suggestion("second", 13, "worse", "worst"),
      suggestion("first", 4, "bad", "poor"),
    },
  }, {})

  harness.equal(true, host:next())
  harness.equal({ 1, 4 }, vim.api.nvim_win_get_cursor(editor_win))
  local card_win = host.presentation:card_window()
  harness.equal(card_win, vim.api.nvim_get_current_win())
  local card_buf = vim.api.nvim_win_get_buf(card_win)
  local focused_lines = vim.api.nvim_buf_get_lines(card_buf, 0, -1, true)
  harness.equal(false, vim.tbl_contains(focused_lines, "Preview · :RefineShow to focus for card keys"))
  harness.equal("[a] Apply  [q] Close", focused_lines[#focused_lines])
  vim.api.nvim_set_current_win(editor_win)
  harness.equal(
    true,
    vim.wait(1000, function()
      return vim.tbl_contains(
        vim.api.nvim_buf_get_lines(card_buf, 0, -1, true),
        "Preview · :RefineShow to focus for card keys"
      )
    end)
  )
  harness.equal(true, host:show())
  harness.equal(card_win, vim.api.nvim_get_current_win())
  harness.equal(
    false,
    vim.tbl_contains(vim.api.nvim_buf_get_lines(card_buf, 0, -1, true), "Preview · :RefineShow to focus for card keys")
  )
  vim.api.nvim_set_current_win(editor_win)
  harness.equal(true, host:next())
  harness.equal({ 1, 13 }, vim.api.nvim_win_get_cursor(editor_win))
  harness.equal(true, host:next())
  harness.equal({ 1, 4 }, vim.api.nvim_win_get_cursor(editor_win))
  harness.equal(true, host:previous())
  harness.equal({ 1, 13 }, vim.api.nvim_win_get_cursor(editor_win))
  host:close()
  harness.equal(editor_win, vim.api.nvim_get_current_win())
end)

harness.test("transient quick keys cancel activation and restore prior mappings", function()
  vim.cmd.only()
  vim.cmd.enew({ bang = true })
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "This are text." })
  vim.api.nvim_win_set_cursor(0, { 1, 6 })
  local native_tabs = 0
  vim.keymap.set("n", "<Tab>", function()
    native_tabs = native_tabs + 1
  end, { buffer = bufnr, desc = "Prior Tab" })

  local host = require("refine.nvim.host").new({
    bufnr = bufnr,
    source_syntax = "plainText",
    run_id = "quick",
  })
  local revision = host.source:snapshot().revision
  local applied
  local dismissed = 0
  host:present({
    documentRevision = revision,
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
        dismissKey = "escape",
        activationStyle = "highlightChanges",
      },
    },
    suggestions = {
      {
        id = "quick-1",
        sourceId = "document",
        kind = "grammar",
        attribution = {
          languageDisplayName = "English",
          textDirection = "ltr",
          checkModelDisplayName = "On-Device",
        },
        activationRange = { location = 5, length = 3 },
        highlightRanges = { { location = 5, length = 3 } },
        diff = {
          { kind = "delete", text = "are" },
          { kind = "insert", text = "is" },
        },
        availableActions = { "apply", "dismiss" },
      },
    },
  }, {
    apply = function(suggestion_id, callback)
      applied = suggestion_id
      callback({ status = "completed" })
    end,
    dismiss = function(_, callback)
      dismissed = dismissed + 1
      callback({ status = "completed" })
    end,
  })

  harness.equal("Refine Apply suggestion", vim.fn.maparg("<Tab>", "n", false, true).desc)
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "x", false)
  harness.equal(
    true,
    vim.wait(1000, function()
      return vim.fn.maparg("<Tab>", "n", false, true).desc == "Prior Tab"
    end)
  )
  harness.equal(0, dismissed)

  vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "x", false)
  harness.equal(
    true,
    vim.wait(1000, function()
      return native_tabs == 1
    end)
  )

  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr })
  vim.api.nvim_win_set_cursor(0, { 1, 6 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr })
  vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "x", false)
  harness.equal(
    true,
    vim.wait(1000, function()
      return applied == "quick-1"
    end)
  )
end)

harness.test("clears an observed navigation preview after native editing", function()
  vim.cmd.only()
  vim.cmd.enew({ bang = true })
  vim.cmd("messages clear")
  local bufnr = vim.api.nvim_get_current_buf()
  local owner_win = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "This are text." })
  local statuses = {}
  local host = require("refine.nvim.host").new({
    bufnr = bufnr,
    winid = owner_win,
    source_syntax = "plainText",
    run_id = "native-edit-preview",
    on_presentation = function(snapshot)
      statuses[#statuses + 1] = snapshot.state.type
    end,
  })
  local detach = host:observe(function() end, function() end)
  present_navigation_preview(host, 1)

  harness.equal(true, host:next())
  harness.equal(host.presentation:card_window(), vim.api.nvim_get_current_win())
  vim.api.nvim_set_current_win(owner_win)
  vim.api.nvim_feedkeys("aX" .. vim.keycode("<Esc>"), "xt", false)
  local closed = vim.wait(1000, function()
    return host.presentation:card_window() == nil
  end)
  local messages = vim.api.nvim_exec2("messages", { output = true }).output
  local outcome = {
    buffer = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true),
    closed = closed,
    callback_error = messages:find("Lua callback", 1, true) ~= nil,
    textlock_error = messages:find("E565", 1, true) ~= nil,
    status = statuses[#statuses],
  }
  detach()
  host:deactivate()

  harness.equal({
    buffer = { "This aXre text." },
    closed = true,
    callback_error = false,
    textlock_error = false,
    status = "pending",
  }, outcome)
end)

harness.test("preserves a newer presentation across deferred native-edit cleanup", function()
  vim.cmd.only()
  vim.cmd.enew({ bang = true })
  local bufnr = vim.api.nvim_get_current_buf()
  local owner_win = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "This are text." })
  local observations = {}
  local host = require("refine.nvim.host").new({
    bufnr = bufnr,
    winid = owner_win,
    source_syntax = "plainText",
    run_id = "deferred-presentation",
  })
  local detach = host:observe(function(observation)
    observations[#observations + 1] = observation
  end, function() end)

  present_navigation_preview(host, 1)
  harness.equal(true, host:next())
  vim.api.nvim_buf_set_text(bufnr, 0, 14, 0, 14, { "!" })
  present_navigation_preview(host, 2)
  harness.equal(true, host:next())
  local new_card = host.presentation:card_window()
  harness.equal(
    true,
    vim.wait(1000, function()
      return #observations >= 4
    end)
  )
  local survived = host.presentation:card_window() == new_card and vim.api.nvim_win_is_valid(new_card)
  detach()
  host:deactivate()

  harness.equal(true, survived)
end)

harness.run()
