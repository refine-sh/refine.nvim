local root = vim.fn.getcwd()
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  root .. "/tests/?.lua",
  package.path,
}, ";")

local harness = require("support.harness")

harness.test("rejects invalid UTF-8 before a normal non-binary buffer can connect", function()
  vim.cmd.enew({ bang = true })
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].buftype = ""
  vim.bo[bufnr].filetype = "markdown"
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].readonly = false
  vim.bo[bufnr].binary = false
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "private" .. string.char(0xff) })

  local transport_creations = 0
  local connection_attempts = 0
  local controller = require("refine.controller").new({
    has_ui = function()
      return true
    end,
    is_macos = function()
      return true
    end,
    frontend = function()
      return nil
    end,
    transport_factory = function()
      transport_creations = transport_creations + 1
      return {
        connect = function()
          connection_attempts = connection_attempts + 1
        end,
      }
    end,
  })

  harness.equal(false, controller:reconcile(bufnr, vim.api.nvim_get_current_win()))
  harness.equal(0, transport_creations)
  harness.equal(0, connection_attempts)
  harness.equal("inactive", controller:status(bufnr).state)
  harness.equal("invalid_utf8", controller:status(bufnr).reason)
end)

harness.test("maps default prose filetypes to explicit document syntaxes", function()
  local eligibility = require("refine.nvim.eligibility")
  local cases = {
    { filetype = "markdown", source_syntax = "markdownDocument" },
    { filetype = "text", source_syntax = "plainText" },
    { filetype = "gitcommit", source_syntax = "plainText" },
    { filetype = "mail", source_syntax = "plainText" },
    { filetype = "tex", source_syntax = "latexDocument" },
    { filetype = "plaintex", source_syntax = "latexDocument" },
  }

  for _, case in ipairs(cases) do
    vim.cmd.enew({ bang = true })
    local bufnr = vim.api.nvim_get_current_buf()
    vim.bo[bufnr].buftype = ""
    vim.bo[bufnr].filetype = case.filetype
    vim.bo[bufnr].modifiable = true
    vim.bo[bufnr].readonly = false
    vim.bo[bufnr].binary = false
    harness.equal(case.source_syntax, eligibility.resolve(bufnr))
  end
end)

harness.run()
