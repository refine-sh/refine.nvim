local selection = require("refine.nvim.selection")

local M = {}
local registered = false

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "Refine" })
end

local function invoke(label, callback, empty_message)
  local ok, result, reason = pcall(callback)
  if not ok then
    notify(label .. " failed: " .. tostring(result), vim.log.levels.ERROR)
    return
  end
  if result == false then
    notify(empty_message or (label .. " is unavailable: " .. tostring(reason or "no live suggestion")))
  end
end

local function register_lifecycle(controller)
  local group = vim.api.nvim_create_augroup("RefineNvim", { clear = true })
  local function reconcile()
    vim.schedule(function()
      controller:reconcile()
    end)
  end
  local function resume()
    vim.schedule(function()
      if controller.resume_view then
        controller:resume_view()
      else
        controller:reconcile()
      end
    end)
  end
  vim.api.nvim_create_autocmd({ "VimEnter", "UIEnter", "BufEnter", "WinEnter", "TabEnter", "FileType" }, {
    group = group,
    callback = reconcile,
  })
  vim.api.nvim_create_autocmd("UILeave", {
    group = group,
    callback = reconcile,
  })
  vim.api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = "binary,buftype,modifiable,readonly",
    callback = reconcile,
  })
  vim.api.nvim_create_autocmd("FocusLost", {
    group = group,
    callback = function()
      controller:suspend_view()
    end,
  })
  vim.api.nvim_create_autocmd("FocusGained", { group = group, callback = resume })
  vim.api.nvim_create_autocmd({ "VimResized", "WinScrolled", "WinClosed" }, {
    group = group,
    callback = function(event)
      if event.event == "WinClosed" then
        vim.schedule(function()
          controller:refresh_view()
        end)
      else
        controller:refresh_view()
      end
    end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      controller:refresh_highlights()
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(event)
      require("refine.nvim.eligibility").clear(event.buf)
      reconcile()
    end,
  })
  vim.api.nvim_create_autocmd("BufUnload", {
    group = group,
    callback = reconcile,
  })
  vim.schedule(function()
    controller:reconcile()
  end)
end

local function plug(mode, name, callback)
  vim.keymap.set(mode, "<Plug>(" .. name .. ")", callback, {
    desc = name:gsub("^Refine", "Refine "),
    silent = true,
  })
end

function M.register(options)
  if registered then
    return
  end
  registered = true
  options = options or {}
  local controller = options.controller or require("refine.runtime").controller()

  local function check(command)
    invoke("Refine Check", function()
      local intent
      if command.range ~= 0 then
        intent = selection.linewise(0, command.line1, command.line2)
      end
      return controller:check(intent)
    end)
  end
  local function visual_check()
    invoke("Refine Check", function()
      return controller:check(selection.visual(0))
    end)
  end
  local function show()
    invoke("Refine Show", function()
      return controller:show()
    end, "No Refine suggestion at cursor")
  end
  local function next_suggestion()
    invoke("Refine Next", function()
      return controller:next()
    end, "No Refine suggestions")
  end
  local function previous_suggestion()
    invoke("Refine Previous", function()
      return controller:previous()
    end, "No Refine suggestions")
  end
  local action_callbacks = {}
  for _, kind in ipairs({ "apply", "dismiss", "explain", "report" }) do
    action_callbacks[kind] = function()
      invoke("Refine " .. kind:gsub("^%l", string.upper), function()
        return controller:action(kind)
      end)
    end
  end
  local function close()
    controller:close()
  end

  vim.api.nvim_create_user_command("RefineCheck", check, { range = true, desc = "Check text with Refine" })
  vim.api.nvim_create_user_command("RefineShow", show, { desc = "Show the Refine suggestion at the cursor" })
  vim.api.nvim_create_user_command("RefineNext", next_suggestion, { desc = "Go to the next Refine suggestion" })
  vim.api.nvim_create_user_command("RefinePrevious", previous_suggestion, {
    desc = "Go to the previous Refine suggestion",
  })
  for _, kind in ipairs({ "apply", "dismiss", "explain", "report" }) do
    local command_name = "Refine" .. kind:gsub("^%l", string.upper)
    vim.api.nvim_create_user_command(command_name, action_callbacks[kind], {
      desc = command_name:gsub("^Refine", "Refine ") .. " suggestion",
    })
  end
  vim.api.nvim_create_user_command("RefineClose", close, { desc = "Close the Refine suggestion card" })
  vim.api.nvim_create_user_command("RefineStatus", function()
    notify(vim.inspect(controller:status()))
  end, { desc = "Show Refine status" })

  plug("n", "RefineCheck", function()
    check({ range = 0 })
  end)
  plug("x", "RefineCheck", visual_check)
  plug("n", "RefineShow", show)
  plug("n", "RefineNext", next_suggestion)
  plug("n", "RefinePrevious", previous_suggestion)
  plug("n", "RefineApply", action_callbacks.apply)
  plug("n", "RefineDismiss", action_callbacks.dismiss)
  plug("n", "RefineExplain", action_callbacks.explain)
  plug("n", "RefineReport", action_callbacks.report)
  plug("n", "RefineClose", close)

  if options.controller == nil or options.lifecycle == true then
    register_lifecycle(controller)
  end
end

return M
