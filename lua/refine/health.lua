local M = {}

local function supported_neovim(version)
  return version.major > 0 or version.minor >= 11
end

local function configured_filetypes(filetypes)
  local entries = {}
  for filetype, syntax in pairs(filetypes) do
    entries[#entries + 1] = ("%s=%s"):format(filetype, syntax)
  end
  table.sort(entries)
  return table.concat(entries, ", ")
end

local function report_configuration()
  local ok, options = pcall(function()
    return require("refine.config").get()
  end)
  if not ok then
    vim.health.error("Configuration is invalid", tostring(options))
    return
  end

  vim.health.ok("Configuration is valid")
  vim.health.info(("Source limit: %d bytes"):format(options.max_source_bytes))
  vim.health.info("Filetypes: " .. configured_filetypes(options.filetypes))
  if options.debug_log then
    local path_ok, path = pcall(function()
      return require("refine.log").path()
    end)
    local location = path_ok and tostring(path) or "path unavailable"
    vim.health.warn(
      "Persistent debug logging is enabled: " .. location,
      "Structured entries are redacted and retained in a 256 KiB current file plus one rotated file."
    )
  end
  return options
end

local function status_summary(status)
  local details = { "State: " .. tostring(status.state) }
  if status.suggestion_count ~= nil then
    local noun = status.suggestion_count == 1 and "suggestion" or "suggestions"
    details[#details + 1] = ("%d %s"):format(status.suggestion_count, noun)
  end
  if status.coverage ~= nil then
    details[#details + 1] = status.coverage .. " coverage"
  end
  if status.reason ~= nil then
    details[#details + 1] = "reason=" .. tostring(status.reason)
  end
  return table.concat(details, "; ")
end

local function active_owner_bufnr()
  local ok, owner = pcall(function()
    local controller = require("refine.runtime").controller()
    if type(controller.owner_bufnr) == "function" then
      return controller:owner_bufnr()
    end
  end)
  return ok and owner or nil
end

local function report_status(options)
  local ok, status = pcall(function()
    return require("refine").status(active_owner_bufnr())
  end)
  if not ok then
    vim.health.error("Unable to read Refine state", tostring(status))
    return
  end

  vim.health.info("Frontend: " .. tostring(status.frontend or options.frontend))
  vim.health.info(status_summary(status))

  local warnings = status.warnings or {}
  if #warnings == 0 then
    vim.health.ok("Refine action keys are compatible")
  else
    for _, warning in ipairs(warnings) do
      vim.health.warn(
        "Refine compatibility warning: " .. tostring(warning),
        "Choose an Apply or Dismiss key that Neovim can intercept in Refine settings."
      )
    end
  end
  vim.health.info(
    "Tab, Escape, and Return require a GUI or terminal with extended key encoding to remain distinct from Ctrl-I, Ctrl-[, and Ctrl-M."
  )
end

local function endpoint_advice(failure)
  if type(failure) == "table" and failure.kind == "EndpointProtocolVersionError" then
    if failure.required_update == "client" then
      return "Update Refine for Neovim."
    end
    return "Update the Refine app."
  end
  return "Start Refine, then run :checkhealth refine again."
end

local function report_endpoint()
  local endpoint = require("refine.transport.endpoint")
  local wire = require("refine.transport.wire")
  local complete = false
  local failure
  local descriptor

  endpoint.locator():locate(function(err, value)
    failure = err
    descriptor = value
    complete = true
  end)

  if not complete then
    vim.wait(1000, function()
      return complete
    end, 10)
  end
  if not complete then
    vim.health.warn("Timed out while inspecting the Refine endpoint", endpoint_advice())
    return
  end
  if failure then
    local message = tostring(failure)
    local missing = message:match("ENOENT") or message:lower():match("no such file")
    if missing then
      vim.health.warn("Refine endpoint is unavailable", endpoint_advice(failure))
    else
      vim.health.error("Refine endpoint check failed: " .. message, endpoint_advice(failure))
    end
    return
  end
  if descriptor.protocolMinor == nil then
    vim.health.warn(
      ("Refine endpoint permissions are secure; the legacy descriptor advertises protocol %d without a minor version"):format(
        descriptor.protocolMajor
      ),
      "Connect once to verify exact Protocol 2.4 compatibility."
    )
    return
  end

  vim.health.ok(("Refine endpoint is secure and uses protocol %d.%d"):format(wire.PROTOCOL_MAJOR, wire.PROTOCOL_MINOR))
end

function M.check()
  vim.health.start("refine.nvim")

  local version = vim.version()
  if supported_neovim(version) then
    vim.health.ok(("Neovim 0.11 or newer (%d.%d.%d)"):format(version.major, version.minor, version.patch))
  else
    vim.health.error(
      ("Neovim 0.11 or newer is required (found %d.%d.%d)"):format(version.major, version.minor, version.patch),
      "Upgrade Neovim before using Refine for Neovim."
    )
  end

  local system = vim.uv.os_uname().sysname
  if system == "Darwin" then
    vim.health.ok("macOS")
  else
    vim.health.error("Refine for Neovim requires macOS", "Use Refine for Neovim in a Neovim process running on macOS.")
  end

  local options = report_configuration()
  if options then
    report_status(options)
  end
  local endpoint_ok, endpoint_failure = pcall(report_endpoint)
  if not endpoint_ok then
    vim.health.error(
      "Unable to inspect the Refine endpoint: " .. tostring(endpoint_failure),
      "Start Refine, then run :checkhealth refine again."
    )
  end
end

return M
