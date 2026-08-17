describe("Refine endpoint discovery", function()
  local launch_token = string.rep("A", 64)

  it("parses an exact Protocol 1.0 endpoint descriptor", function()
    local endpoint = require("refine.transport.endpoint")
    local descriptor = endpoint.parse(vim.json.encode({
      version = 1,
      socketPath = "/private/tmp/refine/server.sock",
      launchToken = launch_token,
      serverEpoch = "epoch-1",
      protocolMajor = 1,
      protocolMinor = 0,
      pid = 123,
    }))

    assert_equal(0, descriptor.protocolMinor)
    assert_equal("/private/tmp/refine/server.sock", descriptor.socketPath)
  end)

  it("reports exact versions without inferring which side must update", function()
    local endpoint = require("refine.transport.endpoint")
    for _, case in ipairs({
      { major = 0, minor = 9 },
      { major = 2, minor = 5 },
    }) do
      local ok, err = pcall(
        endpoint.parse,
        vim.json.encode({
          version = 1,
          socketPath = "/private/tmp/refine/server.sock",
          launchToken = launch_token,
          serverEpoch = "epoch-1",
          protocolMajor = case.major,
          protocolMinor = case.minor,
          pid = 123,
        })
      )

      assert_equal(false, ok)
      assert_equal("EndpointProtocolVersionError", err.kind)
      assert_equal({ major = case.major, minor = case.minor }, err.received_protocol)
      assert_equal({ major = 1, minor = 0 }, err.supported_protocol)
      assert_equal(nil, err.required_update)
    end
  end)

  it("rejects an endpoint descriptor that omits protocolMinor", function()
    local endpoint = require("refine.transport.endpoint")
    assert_raises("protocolMinor must be an unsigned 16%-bit integer", function()
      endpoint.parse(vim.json.encode({
        version = 1,
        socketPath = "/private/tmp/refine/server.sock",
        launchToken = launch_token,
        serverEpoch = "epoch-1",
        protocolMajor = 1,
        pid = 123,
      }))
    end)
  end)

  it("requires serverEpoch to be a protocol identifier", function()
    local endpoint = require("refine.transport.endpoint")
    for _, epoch in ipairs({ "epoch one", "\195\169poch", string.rep("e", 129) }) do
      assert_raises("serverEpoch must be a 1%-to%-128%-byte visible ASCII identifier", function()
        endpoint.parse(vim.json.encode({
          version = 1,
          socketPath = "/private/tmp/refine/server.sock",
          launchToken = launch_token,
          serverEpoch = epoch,
          protocolMajor = 1,
          protocolMinor = 0,
          pid = 123,
        }))
      end)
    end
  end)

  it("requires the canonical per-launch token", function()
    local endpoint = require("refine.transport.endpoint")
    for _, token in ipairs({ "secret", string.rep("a", 64), string.rep("A", 63), string.rep("G", 64) }) do
      assert_raises("launchToken must be 64 uppercase hexadecimal characters", function()
        endpoint.parse(vim.json.encode({
          version = 1,
          socketPath = "/private/tmp/refine/server.sock",
          launchToken = token,
          serverEpoch = "epoch-1",
          protocolMajor = 1,
          protocolMinor = 0,
          pid = 123,
        }))
      end)
    end
  end)

  it("rejects a pid outside the signed 32-bit descriptor range", function()
    local endpoint = require("refine.transport.endpoint")
    assert_raises("pid must be a positive 32%-bit integer", function()
      endpoint.parse(vim.json.encode({
        version = 1,
        socketPath = "/private/tmp/refine/server.sock",
        launchToken = launch_token,
        serverEpoch = "epoch-1",
        protocolMajor = 1,
        protocolMinor = 0,
        pid = 0x80000000,
      }))
    end)
  end)

  it("rejects duplicate endpoint descriptor members", function()
    local endpoint = require("refine.transport.endpoint")
    local descriptor = [[{
      "version":1,
      "socketPath":"/private/tmp/refine/server.sock",
      "launchToken":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
      "launch\u0054oken":"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
      "serverEpoch":"epoch-1",
      "protocolMajor":1,
      "protocolMinor":0,
      "pid":123
    }]]

    assert_raises("duplicate object member", function()
      endpoint.parse(descriptor)
    end)
  end)

  it("applies portable JSON number and Unicode rules to endpoint descriptors", function()
    local endpoint = require("refine.transport.endpoint")
    for _, descriptor in ipairs({
      [[{"version":1e0,"socketPath":"/tmp/refine.sock","launchToken":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","serverEpoch":"epoch","protocolMajor":1,"protocolMinor":0,"pid":1}]],
      [[{"version":1,"socketPath":"/tmp/refine.sock","launchToken":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","serverEpoch":"epoch","protocolMajor":1,"protocolMinor":0,"pid":9007199254740992}]],
      [[{"version":1,"socketPath":"/tmp/refine.sock","launchToken":"\uD800","serverEpoch":"epoch","protocolMajor":1,"protocolMinor":0,"pid":1}]],
    }) do
      assert_raises("Endpoint descriptor is not valid JSON", function()
        endpoint.parse(descriptor)
      end)
    end
  end)

  it("requires same-user private endpoint entries before returning credentials", function()
    local endpoint = require("refine.transport.endpoint")
    local stats = {
      ["/"] = { uid = 501, mode = 448, kind = "directory" },
      ["/owner.lock"] = { uid = 501, mode = 384, kind = "file" },
      ["/descriptor.json"] = { uid = 501, mode = 384, kind = "file" },
      ["/private/tmp/refine"] = { uid = 501, mode = 448, kind = "directory" },
      ["/private/tmp/refine/server.sock"] = { uid = 501, mode = 384, kind = "socket" },
    }
    local fs = {
      stat = function(path, callback)
        callback(nil, stats[path])
      end,
      read_text = function(_, callback)
        callback(
          nil,
          vim.json.encode({
            version = 1,
            socketPath = "/private/tmp/refine/server.sock",
            launchToken = launch_token,
            serverEpoch = "epoch-1",
            protocolMajor = 1,
            protocolMinor = 0,
            pid = 123,
          })
        )
      end,
    }
    local locator = endpoint.locator({ path = "/descriptor.json", current_uid = 501, fs = fs })
    local located
    locator:locate(function(err, value)
      assert_equal(nil, err)
      located = value
    end)
    assert_equal(launch_token, located.launchToken)

    stats["/descriptor.json"] = { uid = 501, mode = 420, kind = "file" }
    local security_error
    locator:locate(function(err)
      security_error = err
    end)
    assert_equal("EndpointSecurityError", security_error.kind)

    stats["/descriptor.json"] = { uid = 501, mode = 896, kind = "file" }
    local special_mode_error
    locator:locate(function(err)
      special_mode_error = err
    end)
    assert_equal("EndpointSecurityError", special_mode_error.kind)

    stats["/descriptor.json"] = { uid = 501, mode = 384, kind = "file" }
    stats["/owner.lock"] = nil
    local missing_lock
    locator:locate(function(err)
      missing_lock = err
    end)
    assert_truthy(missing_lock)
  end)

  it("delivers a real uv endpoint error once on the Neovim main loop", function()
    local endpoint = require("refine.transport.endpoint")
    local callback_count = 0
    local callback_was_fast
    local located_error
    local locator = endpoint.locator({ path = vim.fn.tempname() .. "/missing-endpoint.json" })

    locator:locate(function(err)
      callback_count = callback_count + 1
      callback_was_fast = vim.in_fast_event()
      located_error = err
    end)

    assert_truthy(vim.wait(1000, function()
      return callback_count > 0
    end, 10))
    assert_equal(1, callback_count)
    assert_equal(false, callback_was_fast)
    assert_truthy(located_error)
  end)
end)
