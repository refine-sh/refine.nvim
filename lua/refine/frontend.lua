local M = {}

local environment_frontends = {
  ["Apple_Terminal"] = "terminal",
  ["iTerm.app"] = "iterm2",
  ["ghostty"] = "ghostty",
  ["WezTerm"] = "wezterm",
  ["kitty"] = "kitty",
  ["Alacritty"] = "alacritty",
}

local function detected_id()
  if vim.env.SSH_CONNECTION or vim.env.SSH_TTY then
    return nil
  end
  if vim.g.neovide then
    return "neovide"
  end
  if vim.env.KITTY_WINDOW_ID then
    return "kitty"
  elseif vim.env.ALACRITTY_WINDOW_ID then
    return "alacritty"
  elseif vim.env.WEZTERM_PANE then
    return "wezterm"
  elseif vim.env.GHOSTTY_RESOURCES_DIR then
    return "ghostty"
  end
  return environment_frontends[vim.env.TERM_PROGRAM]
end

function M.detect(configured)
  if configured ~= "auto" then
    return { id = configured }
  end
  local uis = vim.api.nvim_list_uis()
  if #uis ~= 1 then
    return nil
  end
  local id = detected_id()
  return id and { id = id } or nil
end

return M
