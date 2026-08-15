if vim.fn.has("nvim-0.11") ~= 1 then
  vim.notify_once("refine.nvim requires Neovim 0.11 or later", vim.log.levels.ERROR)
  return
end

require("refine.commands").register()
