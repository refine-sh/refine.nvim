local Logger = {}
Logger.__index = Logger

local allowed_fields = {
  action = true,
  bufnr = true,
  frontend = true,
  kind = true,
  protocol = true,
  reason = true,
  recoverability = true,
  state = true,
  status = true,
}

local function sanitized(event, fields)
  local entry = {
    event = tostring(event),
    timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }
  for key, value in pairs(fields or {}) do
    if allowed_fields[key] and (type(value) == "string" or type(value) == "number" or type(value) == "boolean") then
      entry[key] = value
    end
  end
  return entry
end

function Logger:configure(enabled)
  self.enabled = enabled == true
end

function Logger:_rotate_for(bytes)
  local stat = vim.uv.fs_stat(self.log_path)
  if not stat or stat.size + bytes <= self.max_bytes then
    return
  end
  pcall(vim.uv.fs_unlink, self.log_path .. ".1")
  pcall(vim.uv.fs_rename, self.log_path, self.log_path .. ".1")
end

function Logger:_persist(entry)
  if not self.enabled then
    return
  end
  local line = vim.json.encode(entry) .. "\n"
  vim.fn.mkdir(vim.fs.dirname(self.log_path), "p")
  self:_rotate_for(#line)
  local file = io.open(self.log_path, "a")
  if not file then
    return
  end
  file:write(line)
  file:close()
end

function Logger:record(event, fields)
  local entry = sanitized(event, fields)
  self.entries[#self.entries + 1] = entry
  while #self.entries > self.max_entries do
    table.remove(self.entries, 1)
  end
  self:_persist(entry)
end

function Logger:history()
  return vim.deepcopy(self.entries)
end

function Logger:path()
  return self.log_path
end

local M = {}

function M.new(options)
  options = options or {}
  return setmetatable({
    enabled = false,
    entries = {},
    log_path = options.path or (vim.fn.stdpath("log") .. "/refine.nvim.log"),
    max_bytes = options.max_bytes or 256 * 1024,
    max_entries = options.max_entries or 200,
  }, Logger)
end

local default = M.new()

function M.configure(enabled)
  default:configure(enabled)
end

function M.record(event, fields)
  default:record(event, fields)
end

function M.history()
  return default:history()
end

function M.path()
  return default:path()
end

return M
