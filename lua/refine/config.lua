local M = {}

local source_syntaxes = {
  plainText = true,
  markdownDocument = true,
  latexDocument = true,
}

local frontend_ids = {
  alacritty = true,
  auto = true,
  ghostty = true,
  iterm2 = true,
  kitty = true,
  neovide = true,
  terminal = true,
  wezterm = true,
}

local defaults = {
  debug_log = false,
  filetypes = {
    gitcommit = "plainText",
    mail = "plainText",
    markdown = "markdownDocument",
    plaintex = "latexDocument",
    tex = "latexDocument",
    text = "plainText",
  },
  frontend = "auto",
  max_source_bytes = 1024 * 1024,
}

local current = vim.deepcopy(defaults)

local function invalid(message)
  error("refine.nvim: " .. message, 3)
end

local function validate_filetypes(filetypes, candidate)
  if type(filetypes) ~= "table" then
    invalid("filetypes must be a table")
  end

  for filetype, syntax in pairs(filetypes) do
    if type(filetype) ~= "string" or filetype == "" then
      invalid("filetype keys must be nonempty strings")
    end
    if syntax ~= false and not source_syntaxes[syntax] then
      invalid(("unsupported source syntax for %s"):format(filetype))
    end
    if syntax == false then
      candidate.filetypes[filetype] = nil
    else
      candidate.filetypes[filetype] = syntax
    end
  end
end

function M.replace(options)
  options = options or {}
  if type(options) ~= "table" then
    invalid("setup options must be a table")
  end

  local candidate = vim.deepcopy(defaults)
  for key in pairs(options) do
    if defaults[key] == nil then
      invalid(("unknown configuration key: %s"):format(tostring(key)))
    end
  end

  if options.filetypes ~= nil then
    validate_filetypes(options.filetypes, candidate)
  end

  if options.max_source_bytes ~= nil then
    local value = options.max_source_bytes
    if type(value) ~= "number" or value < 1 or value % 1 ~= 0 then
      invalid("max_source_bytes must be a positive integer")
    end
    candidate.max_source_bytes = value
  end

  if options.frontend ~= nil then
    if type(options.frontend) ~= "string" or not frontend_ids[options.frontend] then
      invalid("frontend must be auto or a recognized frontend ID")
    end
    candidate.frontend = options.frontend
  end

  if options.debug_log ~= nil then
    if type(options.debug_log) ~= "boolean" then
      invalid("debug_log must be a boolean")
    end
    candidate.debug_log = options.debug_log
  end

  current = candidate
end

function M.get()
  return current
end

function M.is_source_syntax(value)
  return source_syntaxes[value] == true
end

return M
