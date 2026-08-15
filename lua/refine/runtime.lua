local instance

local M = {}

function M.controller()
  if not instance then
    instance = require("refine.controller").new()
  end
  return instance
end

return M
