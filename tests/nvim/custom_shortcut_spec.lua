local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. root .. "/tests/?.lua;" .. package.path
local harness = require("support.harness")
local shortcuts = require("refine.nvim.shortcuts")

harness.test("Option Right replaces only its configured action mapping", function()
  local quick = {
    applyKey = "tab",
    dismissKey = "escape",
    applyShortcut = { code = "ArrowRight", key = "ArrowRight", modifiers = { "option" }, label = "⌥→" },
  }
  harness.equal("<M-Right>", shortcuts.lhs(quick, "apply"))
  harness.equal("<Esc>", shortcuts.lhs(quick, "dismiss"))
  harness.equal("⌥→", shortcuts.label(quick, "apply"))
end)

harness.test("Unobservable modifier-only shortcuts never fall back to Tab", function()
  local quick = {
    applyKey = "tab",
    applyShortcut = { code = "AltLeft", key = "AltLeft", modifiers = {}, label = "Left Option" },
  }
  harness.equal(nil, shortcuts.lhs(quick, "apply"))
end)

harness.test("Printable shortcuts use the supplied keyboard layout", function()
  local quick = {
    applyKey = "tab",
    applyShortcut = { code = "KeyQ", key = "a", modifiers = { "control", "option" }, label = "⌃⌥A" },
  }
  harness.equal("<C-M-a>", shortcuts.lhs(quick, "apply"))
end)

harness.test("Temporary custom mapping restores the user's existing mapping", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.keymap.set("i", "<M-Right>", "original", { buffer = bufnr, desc = "original mapping" })
  local mappings = require("refine.nvim.mappings").new(bufnr)
  mappings:set("i", "<M-Right>", function() end, { desc = "Refine Apply" })
  mappings:restore()
  local restored = vim.api.nvim_buf_call(bufnr, function()
    return vim.fn.maparg("<M-Right>", "i", false, true)
  end)
  harness.equal("original", restored.rhs)
  harness.equal("original mapping", restored.desc)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

harness.test("Ambiguous Control-I does not steal the native Tab key", function()
  local quick = {
    applyKey = "tab",
    dismissKey = "escape",
    applyShortcut = {
      code = "KeyI",
      key = "i",
      modifiers = { "control" },
      label = "⌃I",
    },
  }
  harness.equal(nil, shortcuts.lhs(quick, "apply"))
end)

harness.test("Modifier prefix conflicts disable both custom actions", function()
  local quick = {
    applyKey = "tab",
    dismissKey = "leftOption",
    applyShortcut = {
      code = "ArrowRight",
      key = "ArrowRight",
      modifiers = { "option" },
      label = "⌥→",
    },
  }
  harness.equal(true, shortcuts.conflicts(quick))
  harness.equal(nil, shortcuts.lhs(quick, "apply"))
  harness.equal(nil, shortcuts.lhs(quick, "dismiss"))
end)

harness.test("V2 modifier gestures stay unavailable without falling back to Tab", function()
  local quick = {
    applyKey = "tab",
    dismissKey = "escape",
    applyShortcut = { kind = "modifierChord", keys = { "AltLeft", "AltRight" }, label = "Both Options" },
    dismissShortcut = { kind = "modifierDoubleTap", key = "AltRight", label = "Double-tap Right Option" },
  }
  harness.equal(nil, shortcuts.lhs(quick, "apply"))
  harness.equal(nil, shortcuts.lhs(quick, "dismiss"))
  harness.equal("Apply shortcut unavailable", shortcuts.tip(quick, "apply", "Apply"))
  harness.equal("Both Options", shortcuts.label(quick, "apply"))
end)

harness.run()
