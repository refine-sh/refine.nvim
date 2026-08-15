describe("Refine Unix transport", function()
  local function fake_pipe()
    local pipe = {
      closed = false,
      read_stop_count = 0,
    }

    function pipe:connect(_, done)
      done(nil)
    end

    function pipe:read_start(callback)
      self.read_callback = callback
    end

    function pipe:read_stop()
      self.read_stop_count = self.read_stop_count + 1
    end

    function pipe:is_closing()
      return self.closed
    end

    function pipe:close()
      self.closed = true
    end

    return pipe
  end

  local function emit_from_fast_event(body)
    local callback_was_fast
    local producer
    producer = assert(vim.uv.new_async(function()
      callback_was_fast = vim.in_fast_event()
      body()
      if not producer:is_closing() then
        producer:close()
      end
    end))
    producer:send()
    return function()
      return callback_was_fast
    end
  end

  it("bounds and drains scheduled reads in FIFO order before ending once", function()
    local frame = require("refine.transport.frame")
    local unix = require("refine.transport.unix")
    local pipe = fake_pipe()
    local connection
    unix
      .connector({
        new_pipe = function()
          return pipe
        end,
      })
      :connect("/private/tmp/refine.sock", function(err, value)
        assert_equal(nil, err)
        connection = value
      end)

    local received = {}
    local end_count = 0
    local ended_with
    connection:receive(function(value)
      received[#received + 1] = value.ordinal
    end, function(err)
      end_count = end_count + 1
      ended_with = err
    end)

    local callback_was_fast = emit_from_fast_event(function()
      for ordinal = 1, 140 do
        pipe.read_callback(nil, frame.encode({ ordinal = ordinal }))
      end
    end)
    local completed = vim.wait(2000, function()
      return end_count == 1
    end, 10)
    vim.wait(20, function()
      return false
    end, 5)

    assert_truthy(completed, "timed out waiting for scheduled reads")
    assert_equal(true, callback_was_fast())
    assert_equal(128, #received)
    for ordinal = 1, 128 do
      assert_equal(ordinal, received[ordinal])
    end
    assert_equal(1, end_count)
    assert_equal("EngineConnectionError", ended_with.kind)
    assert_equal("recoverable", ended_with.recoverability)
    assert_equal(true, pipe.closed)
    assert_truthy(pipe.read_stop_count >= 1)
  end)

  it("bounds scheduled read bytes without exposing their contents", function()
    local frame = require("refine.transport.frame")
    local unix = require("refine.transport.unix")
    local pipe = fake_pipe()
    local connection
    unix
      .connector({
        new_pipe = function()
          return pipe
        end,
      })
      :connect("/private/tmp/refine.sock", function(err, value)
        assert_equal(nil, err)
        connection = value
      end)

    local frame_count = 0
    local end_count = 0
    local ended_with
    connection:receive(function()
      frame_count = frame_count + 1
    end, function(err)
      end_count = end_count + 1
      ended_with = err
    end)

    local private_chunk = string.rep("private source contents;", math.ceil((frame.MAX_FRAME_BYTES + 5) / 24))
    private_chunk = private_chunk:sub(1, frame.MAX_FRAME_BYTES + 5)
    local callback_was_fast = emit_from_fast_event(function()
      pipe.read_callback(nil, private_chunk)
    end)
    local completed = vim.wait(2000, function()
      return end_count == 1
    end, 10)

    assert_truthy(completed, "timed out waiting for scheduled read byte limit")
    assert_equal(true, callback_was_fast())
    assert_equal(0, frame_count)
    assert_equal(1, end_count)
    assert_equal("EngineConnectionError", ended_with.kind)
    assert_equal("recoverable", ended_with.recoverability)
    assert_equal(nil, ended_with.message:find("private source contents", 1, true))
    assert_equal(true, pipe.closed)
  end)

  it("preserves an earlier frame callback error when the scheduled queue also overflows", function()
    local frame = require("refine.transport.frame")
    local unix = require("refine.transport.unix")
    local pipe = fake_pipe()
    local connection
    unix
      .connector({
        new_pipe = function()
          return pipe
        end,
      })
      :connect("/private/tmp/refine.sock", function(err, value)
        assert_equal(nil, err)
        connection = value
      end)

    local expected_error = {
      kind = "TransportProtocolError",
      message = "private frame callback failure",
      recoverability = "fatal",
    }
    local received = {}
    local end_count = 0
    local ended_with
    connection:receive(function(value)
      received[#received + 1] = value.ordinal
      if value.ordinal == 2 then
        error(expected_error, 0)
      end
    end, function(err)
      end_count = end_count + 1
      ended_with = err
    end)

    emit_from_fast_event(function()
      for ordinal = 1, 140 do
        pipe.read_callback(nil, frame.encode({ ordinal = ordinal }))
      end
    end)
    local completed = vim.wait(2000, function()
      return end_count == 1
    end, 10)
    vim.wait(20, function()
      return false
    end, 5)

    assert_truthy(completed, "timed out waiting for the earlier frame callback error")
    assert_equal({ 1, 2 }, received)
    assert_equal(1, end_count)
    assert_truthy(ended_with == expected_error, "the queue limit masked the earlier frame callback error")
  end)

  it("delivers real uv callbacks and ordered frame errors on the Neovim main loop", function()
    local frame = require("refine.transport.frame")
    local unix = require("refine.transport.unix")
    local directory = vim.fn.tempname()
    local socket_path = directory .. "/refine.sock"
    vim.fn.mkdir(directory, "p")

    local server = assert(vim.uv.new_pipe(false))
    assert(server:bind(socket_path))
    local peer
    local connection
    local server_error
    local callback_fast_events = {}
    local received_ordinals = {}
    local connect_count = 0
    local send_count = 0
    local end_count = 0
    local expected_frame_error = { kind = "TransportProtocolError", message = "frame callback rejected the stream" }
    local ended_with
    local response = frame.encode({ ordinal = 1 }) .. frame.encode({ ordinal = 2 })

    assert(server:listen(1, function(listen_error)
      if listen_error then
        server_error = listen_error
        return
      end
      peer = assert(vim.uv.new_pipe(false))
      local accepted, accept_error = server:accept(peer)
      if not accepted then
        server_error = accept_error
        return
      end
      if not server:is_closing() then
        server:close()
      end
      peer:read_start(function(read_error, chunk)
        if read_error then
          server_error = read_error
          return
        end
        if chunk == nil then
          return
        end
        peer:read_stop()
        peer:write(response, function(write_error)
          if write_error then
            server_error = write_error
            return
          end
          peer:shutdown(function(shutdown_error)
            server_error = shutdown_error
            if not peer:is_closing() then
              peer:close()
            end
          end)
        end)
      end)
    end))

    unix.connector():connect(socket_path, function(connect_error, value)
      callback_fast_events.connect = vim.in_fast_event()
      connect_count = connect_count + 1
      if connect_error then
        return
      end
      connection = value
      connection:receive(function(received)
        callback_fast_events.frames = callback_fast_events.frames or {}
        callback_fast_events.frames[#callback_fast_events.frames + 1] = vim.in_fast_event()
        received_ordinals[#received_ordinals + 1] = received.ordinal
        if received.ordinal == 2 then
          error(expected_frame_error, 0)
        end
      end, function(err)
        callback_fast_events.ended = vim.in_fast_event()
        ended_with = err
        end_count = end_count + 1
      end)
      connection:send({ probe = "client-write" }, function()
        callback_fast_events.sent = vim.in_fast_event()
        send_count = send_count + 1
      end)
    end)

    local completed = vim.wait(2000, function()
      return server_error ~= nil
        or (connect_count == 1 and send_count == 1 and #received_ordinals == 2 and end_count == 1)
    end, 10)
    vim.wait(20, function()
      return false
    end, 5)

    if connection then
      connection:close()
    end
    if peer and not peer:is_closing() then
      peer:close()
    end
    if not server:is_closing() then
      server:close()
    end
    vim.fn.delete(directory, "rf")

    assert_truthy(completed, "timed out waiting for the Unix transport")
    assert_equal(nil, server_error)
    assert_equal(1, connect_count)
    assert_equal(1, send_count)
    assert_equal(1, end_count)
    assert_equal({ 1, 2 }, received_ordinals)
    assert_truthy(ended_with == expected_frame_error, "frame callback error was masked")
    assert_equal(false, callback_fast_events.connect)
    assert_equal(false, callback_fast_events.sent)
    assert_equal({ false, false }, callback_fast_events.frames)
    assert_equal(false, callback_fast_events.ended)
  end)
end)
