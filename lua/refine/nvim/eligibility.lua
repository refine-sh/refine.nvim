local config = require("refine.config")
local utf8 = require("refine.utf8")

local M = {}
local overrides = {}

local function validate_override(options)
  if type(options) ~= "table" then
    error("refine.nvim: buffer override must be a table", 3)
  end
  for key in pairs(options) do
    if key ~= "enabled" and key ~= "source_syntax" then
      error(("refine.nvim: unknown buffer override key: %s"):format(tostring(key)), 3)
    end
  end
  if options.enabled ~= nil and type(options.enabled) ~= "boolean" then
    error("refine.nvim: enabled must be a boolean", 3)
  end
  if options.source_syntax ~= nil and not config.is_source_syntax(options.source_syntax) then
    error("refine.nvim: unsupported source syntax", 3)
  end
end

function M.configure(bufnr, options)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then
    error("refine.nvim: invalid buffer", 2)
  end
  validate_override(options)
  overrides[bufnr] = next(options) and vim.deepcopy(options) or nil
  return bufnr
end

function M.clear(bufnr)
  overrides[bufnr] = nil
end

function M.resolve(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil, "invalid_buffer"
  end
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return nil, "buffer_unloaded"
  end
  if vim.bo[bufnr].buftype ~= "" then
    return nil, "non_normal_buffer"
  end
  if not vim.bo[bufnr].modifiable then
    return nil, "not_modifiable"
  end
  if vim.bo[bufnr].readonly then
    return nil, "read_only"
  end
  if vim.bo[bufnr].binary then
    return nil, "binary"
  end

  local override = overrides[bufnr]
  if override and override.enabled == false then
    return nil, "disabled"
  end
  local options = config.get()
  local syntax = override and override.source_syntax or options.filetypes[vim.bo[bufnr].filetype]
  if syntax == nil then
    return nil, "unsupported_filetype"
  end
  local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, true), "\n")
  if #text > options.max_source_bytes then
    return nil, "resource_limit"
  end
  if not utf8.valid(text) then
    return nil, "invalid_utf8"
  end
  return syntax
end

return M
