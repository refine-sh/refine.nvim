local config = require("refine.config")
local eligibility = require("refine.nvim.eligibility")
local runtime = require("refine.runtime")

local M = {}

function M.setup(options)
  config.replace(options)
  require("refine.log").configure(config.get().debug_log)
  runtime.controller():reconcile()
end

function M.configure_buffer(bufnr, options)
  bufnr = eligibility.configure(bufnr, options)
  runtime.controller():reconcile()
  return bufnr
end

function M.status(bufnr)
  return runtime.controller():status(bufnr)
end

function M.statusline(bufnr)
  return runtime.controller():statusline(bufnr)
end

return M
