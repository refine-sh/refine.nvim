local M = {}

local function continuation(value)
  return value ~= nil and value >= 0x80 and value <= 0xbf
end

function M.valid(value)
  if type(value) ~= "string" then
    return false
  end

  local index = 1
  while index <= #value do
    local first = value:byte(index)
    if first <= 0x7f then
      index = index + 1
    elseif first >= 0xc2 and first <= 0xdf then
      if not continuation(value:byte(index + 1)) then
        return false
      end
      index = index + 2
    elseif first >= 0xe0 and first <= 0xef then
      local second, third = value:byte(index + 1, index + 2)
      if
        not continuation(third)
        or (first == 0xe0 and (second == nil or second < 0xa0 or second > 0xbf))
        or (first == 0xed and (second == nil or second < 0x80 or second > 0x9f))
        or (first ~= 0xe0 and first ~= 0xed and not continuation(second))
      then
        return false
      end
      index = index + 3
    elseif first >= 0xf0 and first <= 0xf4 then
      local second, third, fourth = value:byte(index + 1, index + 3)
      if
        not continuation(third)
        or not continuation(fourth)
        or (first == 0xf0 and (second == nil or second < 0x90 or second > 0xbf))
        or (first == 0xf4 and (second == nil or second < 0x80 or second > 0x8f))
        or (first ~= 0xf0 and first ~= 0xf4 and not continuation(second))
      then
        return false
      end
      index = index + 4
    else
      return false
    end
  end
  return true
end

return M
