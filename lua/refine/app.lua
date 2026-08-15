local M = {}

function M.launch(callback)
  callback = callback or function() end
  vim.system({ "/usr/bin/open", "-g", "-b", "com.runjuu.refine" }, { text = true }, function(result)
    vim.schedule(function()
      if result.code == 0 then
        callback(nil)
      else
        callback((result.stderr or ""):gsub("%s+$", ""))
      end
    end)
  end)
end

return M
