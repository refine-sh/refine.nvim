local Coordinates = {}
Coordinates.__index = Coordinates

local function boundary_error()
  error("refine.nvim: offset is not a Unicode-scalar boundary", 3)
end

local function line_index(text, start_utf16)
  local utf16_to_byte = { [0] = 0 }
  local byte_to_utf16 = { [0] = 0 }
  local byte_col = 0

  for scalar = 0, vim.fn.strchars(text) - 1 do
    local value = vim.fn.strcharpart(text, scalar, 1)
    byte_col = byte_col + #value
    local utf16_col = vim.str_utfindex(text, "utf-16", byte_col, true)
    utf16_to_byte[utf16_col] = byte_col
    byte_to_utf16[byte_col] = utf16_col
  end

  return {
    text = text,
    start_utf16 = start_utf16,
    utf16_length = vim.str_utfindex(text, "utf-16", #text, true),
    utf16_to_byte = utf16_to_byte,
    byte_to_utf16 = byte_to_utf16,
  }
end

function Coordinates:position(offset)
  if type(offset) ~= "number" or offset < 0 or offset % 1 ~= 0 then
    boundary_error()
  end

  for row, line in ipairs(self.lines) do
    local local_offset = offset - line.start_utf16
    if local_offset >= 0 and local_offset <= line.utf16_length then
      local byte_col = line.utf16_to_byte[local_offset]
      if byte_col == nil then
        boundary_error()
      end
      return { row = row - 1, byte_col = byte_col }
    end
  end

  boundary_error()
end

function Coordinates:utf16_offset(row, byte_col)
  local line = self.lines[row + 1]
  if not line then
    boundary_error()
  end
  local local_offset = line.byte_to_utf16[byte_col]
  if local_offset == nil then
    boundary_error()
  end
  return line.start_utf16 + local_offset
end

function Coordinates:range(range)
  if
    type(range) ~= "table"
    or type(range.location) ~= "number"
    or type(range.length) ~= "number"
    or range.location < 0
    or range.length < 0
    or range.location % 1 ~= 0
    or range.length % 1 ~= 0
  then
    boundary_error()
  end

  return {
    start = self:position(range.location),
    finish = self:position(range.location + range.length),
  }
end

local M = {}

function M.new(lines)
  if type(lines) ~= "table" or #lines == 0 then
    error("refine.nvim: coordinates require at least one line", 2)
  end

  local indexed = {}
  local start_utf16 = 0
  for _, text in ipairs(lines) do
    if type(text) ~= "string" then
      error("refine.nvim: coordinate lines must be strings", 2)
    end
    local line = line_index(text, start_utf16)
    indexed[#indexed + 1] = line
    start_utf16 = start_utf16 + line.utf16_length + 1
  end

  return setmetatable({ lines = indexed }, Coordinates)
end

return M
