describe("integration protocol 2.5 golden transcript", function()
  it("is consumed without translation by the Lua wire decoder", function()
    local wire = require("refine.transport.wire")
    local path = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
      .. "/fixtures/integration-protocol-v2.json"
    local fixture =
      vim.json.decode(table.concat(vim.fn.readfile(path), "\n"), { luanil = { object = true, array = true } })

    assert_equal({ major = 2, minor = 5 }, fixture.hello.protocol)
    assert_equal(15, #fixture.hello.hostCapabilities.interceptableSuggestionActionKeys)
    assert_equal(
      { sourceId = "document", range = { location = 8, length = 2 } },
      fixture.selectionCheck.command.intent.selection
    )
    assert_equal(fixture.welcome, wire.decode_handshake(fixture.welcome))
    assert_equal(fixture.presentation, wire.decode_event(fixture.presentation))
    assert_equal(fixture.applyRequested, wire.decode_event(fixture.applyRequested))
  end)

  it("canonicalizes inbound events before they cross the host privacy boundary", function()
    local wire = require("refine.transport.wire")
    local path = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
      .. "/fixtures/integration-protocol-v2.json"
    local fixture =
      vim.json.decode(table.concat(vim.fn.readfile(path), "\n"), { luanil = { object = true, array = true } })

    local expected_presentation = vim.deepcopy(fixture.presentation)
    local presentation = vim.deepcopy(expected_presentation)
    presentation.providerCredential = "envelope secret"
    presentation.event.providerCredential = "event secret"
    presentation.event.content.providerCredential = "content secret"
    presentation.event.content.suggestions[1].providerCredential = "suggestion secret"
    presentation.event.content.suggestions[1].highlightRanges[1].providerCredential = "range secret"
    presentation.event.content.suggestions[1].diff[1].providerCredential = "diff secret"
    assert_equal(expected_presentation, wire.decode_event(presentation))

    local expected_apply = vim.deepcopy(fixture.applyRequested)
    local apply = vim.deepcopy(expected_apply)
    apply.providerCredential = "envelope secret"
    apply.event.providerCredential = "event secret"
    apply.event.request.providerCredential = "request secret"
    apply.event.request.edits[1].providerCredential = "edit secret"
    apply.event.request.edits[1].range.providerCredential = "range secret"
    assert_equal(expected_apply, wire.decode_event(apply))

    local expected_explanation = {
      type = "event",
      sequence = 4,
      epoch = "epoch-fixture",
      event = {
        type = "explanationReplaced",
        actionId = "action-explanation",
        update = { status = "streaming", text = "Safe explanation" },
      },
    }
    local explanation = vim.deepcopy(expected_explanation)
    explanation.providerCredential = "envelope secret"
    explanation.event.providerCredential = "event secret"
    explanation.event.update.providerCredential = "explanation secret"
    assert_equal(expected_explanation, wire.decode_event(explanation))
  end)

  it("drives the exact shared transcript through the production transport", function()
    local transport = require("refine.transport")
    local path = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
      .. "/fixtures/integration-protocol-v2.json"
    local fixture =
      vim.json.decode(table.concat(vim.fn.readfile(path), "\n"), { luanil = { object = true, array = true } })
    local sent = {}
    local receive
    local connection = {}
    function connection:receive(on_frame)
      receive = on_frame
    end
    function connection:send(value, done)
      sent[#sent + 1] = vim.deepcopy(value)
      done(nil)
      if value.type == "hello" then
        receive(fixture.welcome)
      end
    end
    function connection:close() end
    local client = transport.new({
      client = fixture.hello.client,
      host_capabilities = fixture.hello.hostCapabilities,
      endpoint_locator = {
        locate = function(_, done)
          done(nil, {
            socketPath = "/private/tmp/refine-fixture/s",
            launchToken = fixture.hello.launchToken,
            serverEpoch = fixture.welcome.serverEpoch,
          })
        end,
      },
      connector = {
        connect = function(_, _, done)
          done(nil, connection)
        end,
      },
      uuid = function()
        return "generated"
      end,
    })
    local session
    client:connect({ run_id = fixture.hello.runId }, function(err, value)
      assert_equal(nil, err)
      session = value
    end)
    assert_equal(fixture.hello, sent[1])
    session:send(fixture.openDocument.command, fixture.openDocument.id, function(err)
      assert_equal(nil, err)
    end)
    session:send(fixture.selectionCheck.command, fixture.selectionCheck.id, function(err)
      assert_equal(nil, err)
    end)
    assert_equal(fixture.openDocument, sent[2])
    assert_equal(fixture.selectionCheck, sent[3])

    local events = {}
    session:events(function(value)
      events[#events + 1] = value
    end, function(err)
      error(err or "unexpected end")
    end)
    receive(fixture.checkingPresentation)
    receive(fixture.presentation)
    receive(fixture.applyRequested)
    assert_equal({ fixture.checkingPresentation, fixture.presentation, fixture.applyRequested }, events)

    session:send(fixture.completeApply.command, fixture.completeApply.id, function(err)
      assert_equal(nil, err)
    end)
    assert_equal(fixture.completeApply, sent[4])
  end)

  it("accepts writing-check entitlement as an unavailable presentation reason", function()
    local wire = require("refine.transport.wire")
    local content = {
      documentRevision = "fixture:0",
      status = "unavailable",
      unavailableReason = "writingCheckEntitlementRequired",
      appearance = {
        highlight = { style = "underline", grammarColor = "#FF2D55", fluencyColor = "#007AFF" },
        diff = { additionColor = "#34C759", deletionColor = "#FF3B30", showHiddenWhitespace = true },
      },
      interaction = {
        automaticChecksEnabled = false,
        quickApply = {
          enabled = true,
          applyKey = "tab",
          dismissKey = "escape",
          activationStyle = "showTipAndHighlight",
        },
      },
      suggestions = {},
    }
    local envelope = {
      type = "event",
      sequence = 1,
      epoch = "epoch-fixture",
      event = { type = "presentationContentReplaced", checkId = "check-entitlement", content = content },
    }
    assert_equal(envelope, wire.decode_event(envelope))
  end)
end)
