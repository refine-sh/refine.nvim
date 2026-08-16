local function snapshot(revision, text)
  return {
    revision = revision,
    sources = { { sourceId = "document", text = text or "One.", sourceSyntax = "plainText" } },
  }
end

local function attention(revision, caret)
  return {
    type = "attentionChanged",
    revision = revision,
    attention = {
      sourceId = "document",
      caretOffset = caret,
      visibleRanges = { { location = 0, length = 4 } },
    },
  }
end

describe("writing-attention integration runtime", function()
  it("orders initial attention between its snapshot and an explicit check", function()
    local commands = {}
    local observe
    local session = { server_epoch = "epoch", run_resumed = false }
    function session:events() end
    function session:send(command, id, done)
      commands[#commands + 1] = vim.deepcopy(command)
      done(nil, { sequence = #commands, id = id })
    end
    function session:close() end

    local host = {}
    function host:observe(emit)
      observe = emit
      emit({ type = "snapshot", snapshot = snapshot("doc:0") })
      emit(attention("doc:0", 1))
      return function() end
    end
    function host:validate_revision() end
    function host:apply() end
    function host:present(_, _, done)
      done(nil)
    end

    local integration = require("refine.integration").new({
      engine_port = {
        connect = function(_, _, done)
          done(nil, session)
        end,
      },
      uuid = function()
        return "id"
      end,
    })
    integration:run({ host = host })
    observe({ type = "checkRequested", revision = "doc:0" })

    assert_equal(
      { "openDocument", "updateAttention", "requestCheck" },
      vim.tbl_map(function(command)
        return command.type
      end, commands)
    )
    assert_equal(attention("doc:0", 1).attention, commands[2].attention)
  end)

  it("coalesces adjacent attention and flushes it at an explicit-check barrier", function()
    local commands = {}
    local scheduled = {}
    local observe
    local session = { server_epoch = "epoch", run_resumed = false }
    function session:events() end
    function session:send(command, id, done)
      commands[#commands + 1] = vim.deepcopy(command)
      done(nil, { sequence = #commands, id = id })
    end
    function session:close() end

    local host = {}
    function host:observe(emit)
      observe = emit
      emit({ type = "snapshot", snapshot = snapshot("doc:0") })
      return function() end
    end
    function host:validate_revision() end
    function host:apply() end
    function host:present(_, _, done)
      done(nil)
    end

    require("refine.integration")
      .new({
        engine_port = {
          connect = function(_, _, done)
            done(nil, session)
          end,
        },
        schedule = function(callback)
          scheduled[#scheduled + 1] = callback
        end,
        uuid = function()
          return "id"
        end,
      })
      :run({ host = host })

    observe(attention("doc:0", 1))
    observe(attention("doc:0", 2))
    assert_equal(
      { "openDocument" },
      vim.tbl_map(function(command)
        return command.type
      end, commands)
    )
    table.remove(scheduled, 1)()
    assert_equal(2, commands[2].attention.caretOffset)

    observe(attention("doc:0", 3))
    observe({ type = "checkRequested", revision = "doc:0" })
    assert_equal(
      { "openDocument", "updateAttention", "updateAttention", "requestCheck" },
      vim.tbl_map(function(command)
        return command.type
      end, commands)
    )
    assert_equal(3, commands[3].attention.caretOffset)
    table.remove(scheduled, 1)()
    assert_equal(4, #commands)
  end)

  it("does not coalesce attention across a newer snapshot barrier", function()
    local commands = {}
    local scheduled = {}
    local observe
    local session = { server_epoch = "epoch", run_resumed = false }
    function session:events() end
    function session:send(command, id, done)
      commands[#commands + 1] = vim.deepcopy(command)
      done(nil, { sequence = #commands, id = id })
    end
    function session:close() end

    local host = {}
    function host:observe(emit)
      observe = emit
      emit({ type = "snapshot", snapshot = snapshot("doc:0") })
      return function() end
    end
    function host:validate_revision() end
    function host:apply() end
    function host:present(_, _, done)
      done(nil)
    end

    require("refine.integration")
      .new({
        engine_port = {
          connect = function(_, _, done)
            done(nil, session)
          end,
        },
        schedule = function(callback)
          scheduled[#scheduled + 1] = callback
        end,
        uuid = function()
          return "id"
        end,
      })
      :run({ host = host })

    observe(attention("doc:0", 1))
    observe({ type = "snapshot", snapshot = snapshot("doc:1", "Two.") })
    observe(attention("doc:1", 2))
    assert_equal(
      { "openDocument", "updateAttention", "replaceDocument" },
      vim.tbl_map(function(command)
        return command.type
      end, commands)
    )
    assert_equal("doc:0", commands[2].revision)

    table.remove(scheduled, 1)()
    assert_equal("updateAttention", commands[4].type)
    assert_equal("doc:1", commands[4].revision)
    assert_equal(2, commands[4].attention.caretOffset)
  end)

  it("replays matching attention before a pending check after reconnect", function()
    local sessions = {}
    local reconnect
    local observe
    local function session(resumed)
      local value = { server_epoch = "epoch", run_resumed = resumed, commands = {} }
      function value:events(_, on_end)
        self.on_end = on_end
      end
      function value:send(command, id, done)
        self.commands[#self.commands + 1] = vim.deepcopy(command)
        done(nil, { sequence = #self.commands, id = id })
      end
      function value:close() end
      sessions[#sessions + 1] = value
      return value
    end
    local first = session(false)
    local second = session(true)
    local connects = 0
    local host = {}
    function host:observe(emit)
      observe = emit
      emit({ type = "snapshot", snapshot = snapshot("doc:0") })
      emit(attention("doc:0", 2))
      return function() end
    end
    function host:validate_revision() end
    function host:apply() end
    function host:present(_, _, done)
      done(nil)
    end

    require("refine.integration")
      .new({
        engine_port = {
          connect = function(_, _, done)
            connects = connects + 1
            done(nil, connects == 1 and first or second)
          end,
        },
        delay = function(_, callback)
          reconnect = callback
          return function() end
        end,
        schedule = function(callback)
          callback()
        end,
        uuid = function()
          return "id"
        end,
      })
      :run({ host = host })
    observe({ type = "checkRequested", revision = "doc:0" })
    first.on_end({ kind = "EngineConnectionError", message = "lost", recoverability = "recoverable" })
    reconnect()

    assert_equal(
      { "openDocument", "updateAttention", "requestCheck" },
      vim.tbl_map(function(command)
        return command.type
      end, second.commands)
    )
    assert_equal(2, second.commands[2].attention.caretOffset)
  end)

  it("replays matching attention after reconnect without requiring a pending check", function()
    local sessions = {}
    local reconnect
    local function session(resumed)
      local value = { server_epoch = "epoch", run_resumed = resumed, commands = {} }
      function value:events(_, on_end)
        self.on_end = on_end
      end
      function value:send(command, id, done)
        self.commands[#self.commands + 1] = vim.deepcopy(command)
        done(nil, { sequence = #self.commands, id = id })
      end
      function value:close() end
      sessions[#sessions + 1] = value
      return value
    end
    local first = session(false)
    local second = session(true)
    local connects = 0
    local host = {}
    function host:observe(emit)
      emit({ type = "snapshot", snapshot = snapshot("doc:0") })
      emit(attention("doc:0", 2))
      return function() end
    end
    function host:validate_revision() end
    function host:apply() end
    function host:present(_, _, done)
      done(nil)
    end

    require("refine.integration")
      .new({
        engine_port = {
          connect = function(_, _, done)
            connects = connects + 1
            done(nil, connects == 1 and first or second)
          end,
        },
        delay = function(_, callback)
          reconnect = callback
          return function() end
        end,
        schedule = function(callback)
          callback()
        end,
        uuid = function()
          return "id"
        end,
      })
      :run({ host = host })
    first.on_end({ kind = "EngineConnectionError", message = "lost", recoverability = "recoverable" })
    reconnect()

    assert_equal(
      { "openDocument", "updateAttention" },
      vim.tbl_map(function(command)
        return command.type
      end, second.commands)
    )
    assert_equal(2, second.commands[2].attention.caretOffset)
  end)
end)
