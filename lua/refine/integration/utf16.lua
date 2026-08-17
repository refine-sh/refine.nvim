local M = {}

function M.boundaries(text)
  local positions = { [0] = true }
  local offset = 0
  local count = vim.fn.strchars(text)
  for index = 0, count - 1 do
    local scalar = vim.fn.strcharpart(text, index, 1)
    offset = offset + vim.str_utfindex(scalar, "utf-16")
    positions[offset] = true
  end
  return positions, offset
end

function M.range_at_boundaries(value, boundaries, length, require_nonempty)
  if
    type(value) ~= "table"
    or type(value.location) ~= "number"
    or type(value.length) ~= "number"
    or value.location ~= math.floor(value.location)
    or value.length ~= math.floor(value.length)
    or value.location < 0
    or value.length < 0
    or (require_nonempty and value.length == 0)
  then
    return false
  end
  local finish = value.location + value.length
  return finish <= length and boundaries[value.location] == true and boundaries[finish] == true
end

function M.valid_range(text, value, require_nonempty)
  local boundaries, length = M.boundaries(text)
  return M.range_at_boundaries(value, boundaries, length, require_nonempty)
end

return M
