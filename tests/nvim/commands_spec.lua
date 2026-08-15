local root = vim.fn.getcwd()
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  root .. "/tests/?.lua",
  package.path,
}, ";")

local harness = require("support.harness")

harness.test("registers commands and defaultless Plug targets", function()
  vim.cmd.enew({ bang = true })
  vim.api.nvim_buf_set_lines(0, 0, -1, true, { "one", "two", "three" })
  local checks = {}
  local actions = {}
  local reconciliations = 0
  local view_refreshes = 0
  local highlight_refreshes = 0
  local controller = {
    check = function(_, value)
      checks[#checks + 1] = value == nil and "full" or value
      return true
    end,
    show = function()
      return true
    end,
    next = function()
      return true
    end,
    previous = function()
      return true
    end,
    action = function(_, kind)
      actions[#actions + 1] = kind
      return true
    end,
    close = function()
      return true
    end,
    status = function()
      return { state = "complete", bufnr = 1, suggestion_count = 2, warnings = {} }
    end,
    reconcile = function()
      reconciliations = reconciliations + 1
    end,
    suspend_view = function() end,
    refresh_view = function()
      view_refreshes = view_refreshes + 1
    end,
    refresh_highlights = function()
      highlight_refreshes = highlight_refreshes + 1
    end,
  }
  require("refine.commands").register({ controller = controller, lifecycle = true })

  vim.cmd.RefineCheck()
  vim.cmd("2,2RefineCheck")
  harness.equal("full", checks[1])
  harness.equal({
    selection = { sourceId = "document", range = { location = 4, length = 4 } },
  }, checks[2])

  vim.cmd.RefineDismiss()
  vim.cmd.RefineExplain()
  harness.equal({ "dismiss", "explain" }, actions)

  for _, name in ipairs({
    "RefineCheck",
    "RefineShow",
    "RefineNext",
    "RefinePrevious",
    "RefineApply",
    "RefineDismiss",
    "RefineExplain",
    "RefineReport",
    "RefineClose",
  }) do
    harness.equal(2, vim.fn.exists(":" .. name))
    harness.equal(true, vim.fn.maparg("<Plug>(" .. name .. ")", "n") ~= "")
  end
  harness.equal(true, vim.fn.maparg("<Plug>(RefineCheck)", "x") ~= "")

  harness.equal(true, #vim.api.nvim_get_autocmds({ group = "RefineNvim", event = "WinScrolled" }) > 0)
  harness.equal(true, #vim.api.nvim_get_autocmds({ group = "RefineNvim", event = "VimResized" }) > 0)
  harness.equal(true, #vim.api.nvim_get_autocmds({ group = "RefineNvim", event = "WinClosed" }) > 0)
  harness.equal(true, #vim.api.nvim_get_autocmds({ group = "RefineNvim", event = "UILeave" }) > 0)
  local option_autocmds = vim.api.nvim_get_autocmds({ group = "RefineNvim", event = "OptionSet" })
  harness.equal(true, #option_autocmds > 0)
  local option_patterns = {}
  for _, autocmd in ipairs(option_autocmds) do
    option_patterns[#option_patterns + 1] = autocmd.pattern
  end
  table.sort(option_patterns)
  harness.equal({ "binary", "buftype", "modifiable", "readonly" }, option_patterns)
  harness.equal(true, #vim.api.nvim_get_autocmds({ group = "RefineNvim", event = "BufUnload" }) > 0)
  vim.api.nvim_exec_autocmds("VimResized", { modeline = false })
  vim.api.nvim_exec_autocmds("ColorScheme", { modeline = false })
  harness.equal(true, view_refreshes > 0)
  harness.equal(true, highlight_refreshes > 0)
  harness.equal(
    true,
    vim.wait(1000, function()
      return reconciliations > 0
    end)
  )
end)

harness.run()
