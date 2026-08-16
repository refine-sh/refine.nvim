local harness = require("support.harness")

local function capture_health(body, modules)
  local calls = {}
  local original_health = vim.health
  local original_version = vim.version
  local original_uname = vim.uv.os_uname
  local original_modules = {}
  local module_names = {}
  local missing = {}

  vim.health = {}
  for _, level in ipairs({ "start", "ok", "info", "warn", "error" }) do
    vim.health[level] = function(message, advice)
      calls[#calls + 1] = { level = level, message = message, advice = advice }
    end
  end
  vim.version = function()
    return { major = 0, minor = 11, patch = 0 }
  end
  vim.uv.os_uname = function()
    return { sysname = "Darwin" }
  end

  for name, value in pairs(modules or {}) do
    module_names[#module_names + 1] = name
    original_modules[name] = package.loaded[name] == nil and missing or package.loaded[name]
    package.loaded[name] = value
  end
  package.loaded["refine.health"] = nil
  local ok, failure = xpcall(body, debug.traceback)
  package.loaded["refine.health"] = nil
  for _, name in ipairs(module_names) do
    package.loaded[name] = original_modules[name] == missing and nil or original_modules[name]
  end
  vim.health = original_health
  vim.version = original_version
  vim.uv.os_uname = original_uname
  if not ok then
    error(failure, 0)
  end
  return calls
end

local function messages(calls)
  local values = {}
  for _, call in ipairs(calls) do
    values[#values + 1] = call.message
  end
  return table.concat(values, "\n")
end

local function has_call(calls, level, pattern)
  for _, call in ipairs(calls) do
    if call.level == level and call.message:match(pattern) then
      return true
    end
  end
  return false
end

local function has_advice(calls, pattern)
  for _, call in ipairs(calls) do
    if type(call.advice) == "string" and call.advice:match(pattern) then
      return true
    end
  end
  return false
end

harness.test("reports the supported Neovim and macOS environment", function()
  local calls = capture_health(function()
    require("refine.health").check()
  end)

  harness.equal(true, has_call(calls, "start", "refine%.nvim"))
  harness.equal(true, has_call(calls, "ok", "Neovim 0%.11"))
  harness.equal(true, has_call(calls, "ok", "macOS"))
end)

harness.test("reports redacted configuration and semantic state", function()
  local requested_bufnr
  local calls = capture_health(function()
    require("refine.health").check()
  end, {
    ["refine.config"] = {
      get = function()
        return {
          debug_log = true,
          filetypes = { tex = "latexDocument", markdown = "markdownDocument" },
          frontend = "auto",
          max_source_bytes = 1024 * 1024,
        }
      end,
    },
    ["refine.log"] = {
      path = function()
        return "/tmp/refine.nvim.log"
      end,
    },
    ["refine"] = {
      status = function(bufnr)
        requested_bufnr = bufnr
        return {
          state = "complete",
          bufnr = 7,
          suggestion_count = 2,
          coverage = "full",
          frontend = "ghostty",
          warnings = {},
        }
      end,
    },
    ["refine.runtime"] = {
      controller = function()
        return {
          owner_bufnr = function()
            return 7
          end,
        }
      end,
    },
  })

  harness.equal(7, requested_bufnr)
  harness.equal(true, has_call(calls, "ok", "Configuration is valid"))
  harness.equal(true, has_call(calls, "info", "Source limit: 1048576 bytes"))
  harness.equal(true, has_call(calls, "info", "Filetypes: markdown=markdownDocument, tex=latexDocument"))
  harness.equal(true, has_call(calls, "info", "Frontend: ghostty"))
  harness.equal(true, has_call(calls, "info", "State: complete; 2 suggestions; full coverage"))
  harness.equal(true, has_call(calls, "ok", "action keys are compatible"))
  harness.equal(true, has_call(calls, "info", "extended key encoding"))
  harness.equal(true, has_call(calls, "warn", "Persistent debug logging is enabled: /tmp/refine%.nvim%.log"))
  harness.equal(true, has_advice(calls, "256 KiB current file plus one rotated file"))
end)

harness.test("verifies the private endpoint without exposing credentials", function()
  local calls = capture_health(function()
    require("refine.health").check()
  end, {
    ["refine.transport.endpoint"] = {
      locator = function()
        return {
          locate = function(_, callback)
            callback(nil, {
              launchToken = "secret-token",
              protocolMajor = 2,
              protocolMinor = 5,
            })
          end,
        }
      end,
    },
    ["refine.transport.wire"] = { PROTOCOL_MAJOR = 2, PROTOCOL_MINOR = 5 },
  })

  harness.equal(true, has_call(calls, "ok", "endpoint is secure and uses protocol 2%.5"))
  harness.equal(false, messages(calls):find("secret%-token") ~= nil)
end)

harness.test("turns endpoint inspection failures into actionable health output", function()
  local calls = capture_health(function()
    require("refine.health").check()
  end, {
    ["refine.transport.endpoint"] = {
      locator = function()
        error("endpoint exploded")
      end,
    },
  })

  harness.equal(true, has_call(calls, "error", "Unable to inspect the Refine endpoint"))
end)
