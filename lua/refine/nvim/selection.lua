local coordinates = require("refine.nvim.coordinates")

local M = {}

local function intent(location, length)
  if length <= 0 then
    error("refine.nvim: selection must not be empty", 3)
  end
  return {
    selection = {
      sourceId = "document",
      range = { location = location, length = length },
    },
  }
end

local function lines_and_index(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
  return lines, coordinates.new(lines)
end

function M.linewise(bufnr, first_line, last_line)
  local lines, index = lines_and_index(bufnr)
  if first_line < 1 or last_line < first_line or last_line > #lines then
    error("refine.nvim: invalid line range", 2)
  end

  local start = index:utf16_offset(first_line - 1, 0)
  local finish
  if last_line < #lines then
    finish = index:utf16_offset(last_line, 0)
  else
    finish = index:utf16_offset(last_line - 1, #lines[last_line])
  end
  return intent(start, finish - start)
end

local function next_grapheme_boundary(text, byte_col)
  local boundary = 0
  for grapheme = 0, vim.fn.strchars(text, true) - 1 do
    local value = vim.fn.strcharpart(text, grapheme, 1, true)
    if boundary == byte_col then
      return boundary + #value
    end
    boundary = boundary + #value
  end
  if boundary == byte_col then
    return boundary
  end
  error("refine.nvim: selection endpoint is not a composed-character boundary", 3)
end

function M.characterwise(bufnr, anchor, cursor, exclusive)
  local lines, index = lines_and_index(bufnr)
  local anchor_offset = index:utf16_offset(anchor[1] - 1, anchor[2])
  local cursor_offset = index:utf16_offset(cursor[1] - 1, cursor[2])
  local start_position, finish_position
  if anchor_offset <= cursor_offset then
    start_position, finish_position = anchor, cursor
  else
    start_position, finish_position = cursor, anchor
  end

  local start = index:utf16_offset(start_position[1] - 1, start_position[2])
  local finish_byte = finish_position[2]
  if not exclusive then
    local line = lines[finish_position[1]]
    if finish_byte < #line then
      finish_byte = next_grapheme_boundary(line, finish_byte)
    elseif finish_position[1] < #lines then
      return intent(start, index:utf16_offset(finish_position[1], 0) - start)
    end
  end
  local finish = index:utf16_offset(finish_position[1] - 1, finish_byte)
  return intent(start, finish - start)
end

function M.visual_kind(mode)
  if mode == "\22" then
    error("refine.nvim: blockwise selections are not supported", 2)
  elseif mode == "V" then
    return "linewise"
  elseif mode == "v" then
    return "characterwise"
  end
  error("refine.nvim: no active characterwise or linewise selection", 2)
end

function M.visual(bufnr)
  local mode = vim.fn.mode()
  local kind = M.visual_kind(mode)
  local anchor = vim.fn.getpos("v")
  local cursor = vim.fn.getpos(".")
  if kind == "linewise" then
    return M.linewise(bufnr, math.min(anchor[2], cursor[2]), math.max(anchor[2], cursor[2]))
  end
  return M.characterwise(
    bufnr,
    { anchor[2], math.max(anchor[3] - 1, 0) },
    { cursor[2], math.max(cursor[3] - 1, 0) },
    vim.o.selection == "exclusive"
  )
end

return M
