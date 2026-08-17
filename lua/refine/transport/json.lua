local utf8 = require("refine.utf8")

local M = {}

local function invalid(message)
  error(message, 0)
end

local function scanner(text)
  local index = 1
  local length = #text
  local parse_value

  local function skip_whitespace()
    while index <= length do
      local byte = text:byte(index)
      if byte ~= 0x20 and byte ~= 0x09 and byte ~= 0x0a and byte ~= 0x0d then
        return
      end
      index = index + 1
    end
  end

  local function parse_string()
    local start = index
    index = index + 1
    while index <= length do
      local byte = text:byte(index)
      if byte == 0x22 then
        index = index + 1
        local token = text:sub(start, index - 1)
        local ok, value = pcall(vim.json.decode, token)
        if not ok or type(value) ~= "string" then
          invalid("invalid JSON string")
        end
        return value
      elseif byte == 0x5c then
        local escaped = text:byte(index + 1)
        if
          escaped == 0x22
          or escaped == 0x5c
          or escaped == 0x2f
          or escaped == 0x62
          or escaped == 0x66
          or escaped == 0x6e
          or escaped == 0x72
          or escaped == 0x74
        then
          index = index + 2
        elseif escaped == 0x75 then
          if not text:sub(index + 2, index + 5):match("^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$") then
            invalid("invalid JSON Unicode escape")
          end
          index = index + 6
        else
          invalid("invalid JSON string escape")
        end
      elseif byte < 0x20 then
        invalid("unescaped control byte in JSON string")
      else
        index = index + 1
      end
    end
    invalid("unterminated JSON string")
  end

  local function consume_digits()
    local start = index
    while index <= length and text:byte(index) >= 0x30 and text:byte(index) <= 0x39 do
      index = index + 1
    end
    return index > start
  end

  local function parse_number()
    local start = index
    if text:byte(index) == 0x2d then
      invalid("JSON numbers must be nonnegative safe integers")
    end
    if text:byte(index) == 0x30 then
      index = index + 1
      local next_byte = text:byte(index)
      if next_byte and next_byte >= 0x30 and next_byte <= 0x39 then
        invalid("invalid leading zero in JSON number")
      end
    elseif not consume_digits() then
      invalid("invalid JSON number")
    end
    local exponent = text:byte(index)
    if exponent == 0x2e or exponent == 0x65 or exponent == 0x45 then
      invalid("JSON numbers must be nonnegative safe integers")
    end
    local integer = text:sub(start, index - 1)
    if #integer > 16 or (#integer == 16 and integer > "9007199254740991") then
      invalid("JSON numbers must be nonnegative safe integers")
    end
  end

  local function parse_literal(literal)
    if text:sub(index, index + #literal - 1) ~= literal then
      invalid("invalid JSON literal")
    end
    index = index + #literal
  end

  local function parse_array()
    index = index + 1
    skip_whitespace()
    if text:byte(index) == 0x5d then
      index = index + 1
      return
    end
    while true do
      parse_value()
      skip_whitespace()
      local byte = text:byte(index)
      if byte == 0x5d then
        index = index + 1
        return
      elseif byte ~= 0x2c then
        invalid("invalid JSON array")
      end
      index = index + 1
      skip_whitespace()
    end
  end

  local function parse_object()
    index = index + 1
    skip_whitespace()
    local members = {}
    if text:byte(index) == 0x7d then
      index = index + 1
      return
    end
    while true do
      if text:byte(index) ~= 0x22 then
        invalid("JSON object member name must be a string")
      end
      local name = parse_string()
      if members[name] then
        invalid("duplicate object member")
      end
      members[name] = true
      skip_whitespace()
      if text:byte(index) ~= 0x3a then
        invalid("JSON object member must have a value")
      end
      index = index + 1
      skip_whitespace()
      parse_value()
      skip_whitespace()
      local byte = text:byte(index)
      if byte == 0x7d then
        index = index + 1
        return
      elseif byte ~= 0x2c then
        invalid("invalid JSON object")
      end
      index = index + 1
      skip_whitespace()
    end
  end

  parse_value = function()
    skip_whitespace()
    local byte = text:byte(index)
    if byte == 0x7b then
      parse_object()
    elseif byte == 0x5b then
      parse_array()
    elseif byte == 0x22 then
      parse_string()
    elseif byte == 0x74 then
      parse_literal("true")
    elseif byte == 0x66 then
      parse_literal("false")
    elseif byte == 0x6e then
      invalid("JSON null is not part of Protocol 1.0")
    elseif byte == 0x2d or (byte and byte >= 0x30 and byte <= 0x39) then
      parse_number()
    else
      invalid("invalid JSON value")
    end
  end

  skip_whitespace()
  parse_value()
  skip_whitespace()
  if index <= length then
    invalid("trailing bytes after JSON value")
  end
end

function M.decode(text)
  if type(text) ~= "string" or not utf8.valid(text) then
    invalid("JSON is not valid UTF-8")
  end
  scanner(text)
  -- Preserve JSON null as vim.NIL so validators can distinguish an omitted
  -- optional member from a present-but-forbidden null member.
  local ok, value = pcall(vim.json.decode, text)
  if not ok then
    invalid("invalid JSON value")
  end
  return value
end

function M.decode_object(text)
  local value = M.decode(text)
  if type(value) ~= "table" or vim.islist(value) then
    invalid("JSON root must be an object")
  end
  return value
end

return M
