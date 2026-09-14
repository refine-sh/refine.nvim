local M = {}

local legacy = {
  delete = "<BS>",
  downArrow = "<Down>",
  escape = "<Esc>",
  leftArrow = "<Left>",
  ["return"] = "<CR>",
  rightArrow = "<Right>",
  space = "<Space>",
  tab = "<Tab>",
  upArrow = "<Up>",
}
local special = {
  Backspace = "BS",
  ArrowDown = "Down",
  Escape = "Esc",
  ArrowLeft = "Left",
  Enter = "CR",
  ArrowRight = "Right",
  Space = "Space",
  Tab = "Tab",
  ArrowUp = "Up",
  Delete = "Del",
  Insert = "Insert",
  Home = "Home",
  End = "End",
  PageUp = "PageUp",
  PageDown = "PageDown",
  NumpadEnter = "kEnter",
  NumpadAdd = "kPlus",
  NumpadSubtract = "kMinus",
  NumpadMultiply = "kMultiply",
  NumpadDivide = "kDivide",
  NumpadDecimal = "kPoint",
}
local modifier_names = { control = "C", option = "M", shift = "S", command = "D" }

function M.conflicts(quick)
  local legacy_codes = {
    tab = "Tab",
    escape = "Escape",
    ["return"] = "Enter",
    space = "Space",
    delete = "Backspace",
    leftArrow = "ArrowLeft",
    rightArrow = "ArrowRight",
    upArrow = "ArrowUp",
    downArrow = "ArrowDown",
    leftShift = "ShiftLeft",
    rightShift = "ShiftRight",
    leftOption = "AltLeft",
    rightOption = "AltRight",
    leftControl = "ControlLeft",
    rightControl = "ControlRight",
  }
  local function identity(action)
    return quick[action .. "Shortcut"] or { code = legacy_codes[quick[action .. "Key"]], modifiers = {} }
  end
  local apply, dismiss = identity("apply"), identity("dismiss")
  if not apply.code or not dismiss.code then
    return false
  end
  local function prefix(one, other)
    local modifier = one.code:match("^Alt") and "option"
      or one.code:match("^Shift") and "shift"
      or one.code:match("^Control") and "control"
    return modifier and vim.tbl_contains(other.modifiers, modifier) or false
  end
  local equal = apply.code == dismiss.code
  for _, modifier in ipairs({ "control", "option", "shift", "command" }) do
    equal = equal and vim.tbl_contains(apply.modifiers, modifier) == vim.tbl_contains(dismiss.modifiers, modifier)
  end
  return equal or prefix(apply, dismiss) or prefix(dismiss, apply)
end

function M.lhs(quick, action)
  if M.conflicts(quick) then
    return nil
  end
  local shortcut = quick[action .. "Shortcut"]
  if not shortcut then
    return legacy[quick[action .. "Key"]]
  end
  if shortcut.code:match("^(Shift)") or shortcut.code:match("^(Alt)") or shortcut.code:match("^(Control)") then
    return nil
  end
  local key = special[shortcut.code]
  if shortcut.code:match("^F%d+$") then
    key = shortcut.code
  elseif shortcut.code:match("^Numpad%d$") then
    key = "k" .. shortcut.code:sub(-1)
  elseif not key then
    if vim.fn.strchars(shortcut.key) ~= 1 then
      return nil
    end
    key = shortcut.key == "<" and "lt" or shortcut.key
  end
  local parts = {}
  for _, modifier in ipairs(shortcut.modifiers) do
    -- Terminal frontends cannot promise delivery of Command combinations.
    if modifier == "command" and not vim.g.neovide then
      return nil
    end
    parts[#parts + 1] = modifier_names[modifier]
  end
  parts[#parts + 1] = key
  local lhs = "<" .. table.concat(parts, "-") .. ">"
  if #shortcut.modifiers == 0 and not special[shortcut.code] and not shortcut.code:match("^F%d+$") then
    return nil
  end
  local encoded = vim.keycode(lhs)
  if encoded == lhs then
    return nil
  end
  if #shortcut.modifiers > 0 then
    for _, native in ipairs({ "<Tab>", "<S-Tab>", "<CR>", "<Esc>", "<BS>" }) do
      if encoded == vim.keycode(native) then
        return nil
      end
    end
  end
  return lhs
end

function M.label(quick, action)
  local shortcut = quick[action .. "Shortcut"]
  if shortcut then
    return shortcut.label
  end
  local key = quick[action .. "Key"]
  local lhs = legacy[key]
  if lhs then
    return lhs:sub(2, -2)
  end
  local words = key:gsub("(%l)(%u)", "%1 %2")
  return (words:gsub("^%l", string.upper))
end

function M.tip(quick, action, title)
  if not M.lhs(quick, action) then
    return title .. " shortcut unavailable"
  end
  return "[" .. M.label(quick, action) .. "] " .. title
end

return M
