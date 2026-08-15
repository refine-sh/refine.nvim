describe("Refine endpoint discovery", function()
  it("parses an exact Protocol 2.4 endpoint descriptor", function()
    local endpoint = require("refine.transport.endpoint")
    local descriptor = endpoint.parse(vim.json.encode({
      version = 1,
      socketPath = "/private/tmp/refine/server.sock",
      launchToken = "secret",
      serverEpoch = "epoch-1",
      protocolMajor = 2,
      protocolMinor = 4,
      pid = 123,
    }))

    assert_equal(4, descriptor.protocolMinor)
    assert_equal("/private/tmp/refine/server.sock", descriptor.socketPath)
  end)

  it("reports which side must update for an incompatible endpoint", function()
    local endpoint = require("refine.transport.endpoint")
    for _, case in ipairs({
      { minor = 3, required_update = "server" },
      { minor = 5, required_update = "client" },
    }) do
      local ok, err = pcall(
        endpoint.parse,
        vim.json.encode({
          version = 1,
          socketPath = "/private/tmp/refine/server.sock",
          launchToken = "secret",
          serverEpoch = "epoch-1",
          protocolMajor = 2,
          protocolMinor = case.minor,
          pid = 123,
        })
      )

      assert_equal(false, ok)
      assert_equal("EndpointProtocolVersionError", err.kind)
      assert_equal(case.required_update, err.required_update)
    end
  end)

  it("allows a same-major legacy descriptor to defer exact minor validation to the handshake", function()
    local endpoint = require("refine.transport.endpoint")
    local descriptor = endpoint.parse(vim.json.encode({
      version = 1,
      socketPath = "/private/tmp/refine/server.sock",
      launchToken = "secret",
      serverEpoch = "epoch-1",
      protocolMajor = 2,
      pid = 123,
    }))

    assert_equal(2, descriptor.protocolMajor)
    assert_equal(nil, descriptor.protocolMinor)
  end)

  it("requires same-user private endpoint entries before returning credentials", function()
    local endpoint = require("refine.transport.endpoint")
    local stats = {
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
            launchToken = "secret",
            serverEpoch = "epoch-1",
            protocolMajor = 2,
            protocolMinor = 4,
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
    assert_equal("secret", located.launchToken)

    stats["/descriptor.json"] = { uid = 501, mode = 420, kind = "file" }
    local security_error
    locator:locate(function(err)
      security_error = err
    end)
    assert_equal("EndpointSecurityError", security_error.kind)
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
