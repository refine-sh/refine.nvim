local errors = require("refine.transport.errors")
local wire = require("refine.transport.wire")

local M = {}
local unpack_values = table.unpack or unpack

local function call_on_main(callback, ...)
  if not vim.in_fast_event() then
    callback(...)
    return
  end
  local argument_count = select("#", ...)
  local arguments = { ... }
  vim.schedule(function()
    callback(unpack_values(arguments, 1, argument_count))
  end)
end

local function descriptor_error(message, data)
  errors.raise("EndpointDescriptorError", message, "fatal", data, 3)
end

local function is_integer(value)
  return type(value) == "number" and value == math.floor(value)
end

local function protocol_component(value, field)
  if not is_integer(value) or value < 0 or value > 0xffff then
    descriptor_error("Endpoint " .. field .. " must be an unsigned 16-bit integer")
  end
  return value
end

local function required_update(protocol)
  if
    protocol.major > wire.PROTOCOL_MAJOR
    or (protocol.major == wire.PROTOCOL_MAJOR and protocol.minor ~= nil and protocol.minor > wire.PROTOCOL_MINOR)
  then
    return "client"
  end
  return "server"
end

function M.default_path(home_directory)
  local base = home_directory or vim.uv.os_homedir()
  return table.concat({
    base,
    "Library",
    "Application Support",
    "com.runjuu.refine",
    "Integrations",
    "endpoint.json",
  }, "/")
end

function M.parse(text)
  local ok, value = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if not ok then
    descriptor_error("Endpoint descriptor is not valid JSON")
  end
  if type(value) ~= "table" or vim.islist(value) then
    descriptor_error("Endpoint descriptor must be a JSON object")
  end
  if value.version ~= 1 then
    descriptor_error("Endpoint descriptor version must be 1")
  end
  if type(value.socketPath) ~= "string" or value.socketPath:sub(1, 1) ~= "/" then
    descriptor_error("Endpoint socketPath must be an absolute path")
  end
  if type(value.launchToken) ~= "string" or value.launchToken == "" then
    descriptor_error("Endpoint launchToken must be a nonempty string")
  end
  if type(value.serverEpoch) ~= "string" or value.serverEpoch == "" then
    descriptor_error("Endpoint serverEpoch must be a nonempty string")
  end

  local protocol_major = protocol_component(value.protocolMajor, "protocolMajor")
  local protocol_minor = value.protocolMinor ~= nil and protocol_component(value.protocolMinor, "protocolMinor") or nil
  if protocol_major ~= wire.PROTOCOL_MAJOR or (protocol_minor ~= nil and protocol_minor ~= wire.PROTOCOL_MINOR) then
    local received = { major = protocol_major, minor = protocol_minor }
    local received_version = protocol_minor ~= nil and ("%d.%d"):format(protocol_major, protocol_minor)
      or tostring(protocol_major)
    errors.raise(
      "EndpointProtocolVersionError",
      ("Refine protocol %s is incompatible with protocol %d.%d"):format(
        received_version,
        wire.PROTOCOL_MAJOR,
        wire.PROTOCOL_MINOR
      ),
      "fatal",
      { received_protocol = received, required_update = required_update(received) },
      2
    )
  end
  if not is_integer(value.pid) or value.pid <= 0 then
    descriptor_error("Endpoint pid must be a positive integer")
  end

  return {
    version = 1,
    socketPath = value.socketPath,
    launchToken = value.launchToken,
    serverEpoch = value.serverEpoch,
    protocolMajor = wire.PROTOCOL_MAJOR,
    protocolMinor = protocol_minor,
    pid = value.pid,
  }
end

local default_fs = {}

function default_fs.stat(path, callback)
  vim.uv.fs_lstat(path, function(err, stat)
    if err then
      callback(err)
      return
    end
    callback(nil, {
      uid = stat.uid,
      mode = bit.band(stat.mode, 0x1ff),
      kind = stat.type,
    })
  end)
end

function default_fs.read_text(path, callback)
  vim.uv.fs_open(path, "r", 0, function(open_error, descriptor)
    if open_error then
      callback(open_error)
      return
    end
    vim.uv.fs_fstat(descriptor, function(stat_error, stat)
      if stat_error then
        vim.uv.fs_close(descriptor, function()
          callback(stat_error)
        end)
        return
      end
      vim.uv.fs_read(descriptor, stat.size, 0, function(read_error, text)
        vim.uv.fs_close(descriptor, function(close_error)
          callback(read_error or close_error, text)
        end)
      end)
    end)
  end)
end

local function security_error(label, kind, mode)
  return errors.new(
    "EndpointSecurityError",
    ("%s must be a same-user %s with mode %o"):format(label, kind, mode),
    "fatal"
  )
end

local function private_entry(actual, current_uid, kind, mode, label)
  if
    type(actual) ~= "table"
    or actual.kind ~= kind
    or actual.uid ~= current_uid
    or bit.band(actual.mode or -1, 0x1ff) ~= mode
  then
    return security_error(label, kind, mode)
  end
end

function M.locator(options)
  options = options or {}
  local locator = {
    path = options.path or M.default_path(),
    current_uid = options.current_uid or vim.uv.getuid() or -1,
    fs = options.fs or default_fs,
  }

  function locator:locate(callback)
    local completed = false
    local function finish(...)
      if completed then
        return
      end
      completed = true
      call_on_main(callback, ...)
    end

    self.fs.stat(self.path, function(descriptor_stat_error, descriptor_stat)
      if descriptor_stat_error then
        finish(descriptor_stat_error)
        return
      end
      local invalid = private_entry(descriptor_stat, self.current_uid, "file", 0x180, "endpoint descriptor")
      if invalid then
        finish(invalid)
        return
      end
      self.fs.read_text(self.path, function(read_error, text)
        if read_error then
          finish(read_error)
          return
        end
        local parsed, descriptor = pcall(M.parse, text)
        if not parsed then
          finish(descriptor)
          return
        end
        local directory = vim.fs.dirname(descriptor.socketPath)
        self.fs.stat(directory, function(directory_error, directory_stat)
          if directory_error then
            finish(directory_error)
            return
          end
          local bad_directory = private_entry(directory_stat, self.current_uid, "directory", 0x1c0, "socket directory")
          if bad_directory then
            finish(bad_directory)
            return
          end
          self.fs.stat(descriptor.socketPath, function(socket_error, socket_stat)
            if socket_error then
              finish(socket_error)
              return
            end
            local bad_socket = private_entry(socket_stat, self.current_uid, "socket", 0x180, "integration socket")
            if bad_socket then
              finish(bad_socket)
              return
            end
            finish(nil, descriptor)
          end)
        end)
      end)
    end)
  end

  return locator
end

return M
