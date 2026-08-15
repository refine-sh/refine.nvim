local M = {}

local tests = {}

function M.test(name, body)
  tests[#tests + 1] = { name = name, body = body }
end

function M.equal(expected, actual)
  if vim.deep_equal(expected, actual) then
    return
  end

  error(("expected %s, got %s"):format(vim.inspect(expected), vim.inspect(actual)), 2)
end

function M.matches(pattern, value)
  if type(value) == "string" and value:match(pattern) then
    return
  end

  error(("expected %s to match %s"):format(vim.inspect(value), vim.inspect(pattern)), 2)
end

function M.run()
  local failures = {}

  for _, test in ipairs(tests) do
    local ok, failure = xpcall(test.body, debug.traceback)
    if ok then
      io.stdout:write(("PASS %s\n"):format(test.name))
    else
      failures[#failures + 1] = ("FAIL %s\n%s"):format(test.name, failure)
    end
  end

  if #failures > 0 then
    error(table.concat(failures, "\n"), 0)
  end
end

return M
