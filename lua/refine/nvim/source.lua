local Source = {}
Source.__index = Source

local function canonical_text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, true), "\n")
end

function Source:snapshot()
  local text = canonical_text(self.bufnr)
  if text ~= self.last_text or self.source_syntax ~= self.last_source_syntax then
    self.incarnation = self.incarnation + 1
    self.last_text = text
    self.last_source_syntax = self.source_syntax
    self.last_snapshot = {
      revision = ("%s:%d"):format(self.run_id, self.incarnation),
      sources = {
        {
          sourceId = "document",
          text = text,
          sourceSyntax = self.source_syntax,
        },
      },
    }
  end

  return vim.deepcopy(self.last_snapshot)
end

function Source:set_source_syntax(source_syntax)
  self.source_syntax = source_syntax
end

local M = {}

function M.new(options)
  vim.validate({
    bufnr = { options.bufnr, "number" },
    run_id = { options.run_id, "string" },
    source_syntax = { options.source_syntax, "string" },
  })

  return setmetatable({
    bufnr = options.bufnr,
    incarnation = 0,
    run_id = options.run_id,
    source_syntax = options.source_syntax,
  }, Source)
end

return M
