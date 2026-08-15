local MappingSet = {}
MappingSet.__index = MappingSet

local control_aliases = {
  ["<Tab>"] = "<C-I>",
  ["<Esc>"] = "<C-[>",
  ["<CR>"] = "<C-M>",
}

local function id(mode, lhs)
  return mode .. "\0" .. lhs
end

function MappingSet:set(mode, lhs, callback, options)
  local control_alias = control_aliases[lhs]
  local preserve_control_alias = control_alias
    and vim.api.nvim_buf_call(self.bufnr, function()
      return next(vim.fn.maparg(control_alias, mode, false, true)) == nil
    end)
  local key = id(mode, lhs)
  if self.saved[key] == nil then
    local existing = vim.api.nvim_buf_call(self.bufnr, function()
      return vim.fn.maparg(lhs, mode, false, true)
    end)
    self.saved[key] = next(existing) and existing.buffer == 1 and existing or false
    self.order[#self.order + 1] = { mode = mode, lhs = lhs, key = key }
  end

  vim.keymap.set(mode, lhs, callback, {
    buffer = self.bufnr,
    desc = options.desc,
    expr = options.expr,
    nowait = true,
    replace_keycodes = options.expr == true,
    silent = true,
  })

  if preserve_control_alias then
    local alias_key = id(mode, control_alias)
    self.saved[alias_key] = false
    self.order[#self.order + 1] = { mode = mode, lhs = control_alias, key = alias_key }
    vim.keymap.set(mode, control_alias, function()
      return control_alias
    end, {
      buffer = self.bufnr,
      desc = "Refine preserve " .. control_alias,
      expr = true,
      nowait = true,
      replace_keycodes = true,
      silent = true,
    })
  end
end

function MappingSet:restore()
  for index = #self.order, 1, -1 do
    local item = self.order[index]
    pcall(vim.keymap.del, item.mode, item.lhs, { buffer = self.bufnr })
    local previous = self.saved[item.key]
    if previous then
      vim.api.nvim_buf_call(self.bufnr, function()
        vim.fn.mapset(item.mode, false, previous)
      end)
    end
  end
  self.saved = {}
  self.order = {}
end

local M = {}

function M.new(bufnr)
  return setmetatable({
    bufnr = bufnr,
    order = {},
    saved = {},
  }, MappingSet)
end

return M
