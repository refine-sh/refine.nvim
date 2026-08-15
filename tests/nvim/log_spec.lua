local root = vim.fn.getcwd()
package.path =
  table.concat({ root .. "/lua/?.lua", root .. "/lua/?/init.lua", root .. "/tests/?.lua", package.path }, ";")

local harness = require("support.harness")

harness.test("keeps bounded redacted history and rotates an opt-in log", function()
  local base = vim.fn.tempname()
  local log = require("refine.log").new({ path = base, max_entries = 2, max_bytes = 110 })
  log:configure(true)
  log:record("snapshot", { bufnr = 7, state = "pending", text = "private source", launchToken = "secret" })
  log:record("lifecycle", { state = "connected", reason = "ready" })
  log:record("lifecycle", { state = "disconnected", reason = "socket unavailable" })

  local history = log:history()
  harness.equal(2, #history)
  harness.equal("connected", history[1].state)
  local current = table.concat(vim.fn.readfile(base), "\n")
  local rotated = vim.uv.fs_stat(base .. ".1") and table.concat(vim.fn.readfile(base .. ".1"), "\n") or ""
  harness.equal(false, (current .. rotated):find("private source", 1, true) ~= nil)
  harness.equal(false, (current .. rotated):find("secret", 1, true) ~= nil)

  pcall(vim.uv.fs_unlink, base)
  pcall(vim.uv.fs_unlink, base .. ".1")
end)

harness.run()
