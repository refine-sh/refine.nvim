describe("length-prefixed JSON frames", function()
  local function framed(body)
    local length = #body
    return string.char(
      math.floor(length / 0x1000000) % 0x100,
      math.floor(length / 0x10000) % 0x100,
      math.floor(length / 0x100) % 0x100,
      length % 0x100
    ) .. body
  end

  it("decodes fragmented and coalesced socket chunks", function()
    local frame = require("refine.transport.frame")
    local first = frame.encode({ type = "first", text = "grammar ✨" })
    local second = frame.encode({ type = "second", count = 2 })
    local bytes = first .. second
    local decoder = frame.decoder()

    assert_equal({}, decoder:push(bytes:sub(1, 2)))
    assert_equal({ { type = "first", text = "grammar ✨" } }, decoder:push(bytes:sub(3, #first + 3)))
    assert_equal({ { type = "second", count = 2 } }, decoder:push(bytes:sub(#first + 4)))
  end)

  it("delivers complete frames before a coalesced protocol failure", function()
    local frame = require("refine.transport.frame")
    local decoder = frame.decoder()
    local value = { type = "welcome" }
    assert_equal({ value }, decoder:push(frame.encode(value) .. string.char(0, 0, 0, 0)))
    local failure = decoder:take_error()
    assert_equal("TransportProtocolError", failure.kind)
    assert_raises("cannot continue after a protocol error", function()
      decoder:push(frame.encode(value))
    end)
  end)

  it("rejects invalid lengths and cannot continue after a protocol error", function()
    local frame = require("refine.transport.frame")
    local too_large = string.char(0, 128, 0, 1)
    local decoder = frame.decoder()

    assert_raises("declared frame length", function()
      decoder:push(too_large)
    end)
    assert_raises("cannot continue", function()
      decoder:push(frame.encode({ ignored = true }))
    end)
  end)

  it("rejects malformed JSON and truncated frames", function()
    local frame = require("refine.transport.frame")
    local malformed = string.char(0, 0, 0, 1) .. "{"
    local ok, err = pcall(function()
      frame.decoder():push(malformed)
    end)
    assert_equal(false, ok)
    assert_equal("TransportProtocolError", err.kind)
    assert_matches("valid JSON", err.message)

    local decoder = frame.decoder()
    decoder:push(string.char(0, 0, 0, 2) .. "{")
    assert_raises("middle of a frame", function()
      decoder:finish()
    end)
  end)

  it("rejects duplicate object members at every depth", function()
    local frame = require("refine.transport.frame")
    for _, body in ipairs({
      [[{"outer":{"member":1,"member":2}}]],
      [[{"member":1,"\u006Dember":2}]],
    }) do
      assert_raises("duplicate object member", function()
        frame.decoder():push(framed(body))
      end)
    end
  end)

  it("accepts only JSON objects as frame roots", function()
    local frame = require("refine.transport.frame")
    for _, body in ipairs({ "[]", [["value"]], "1" }) do
      assert_raises("root must be an object", function()
        frame.decoder():push(framed(body))
      end)
    end
    assert_raises("root must be an object", function()
      frame.encode({ "array" })
    end)
  end)

  it("accepts only portable nonnegative integer number syntax", function()
    local frame = require("refine.transport.frame")
    for _, body in ipairs({
      [[{"value":-1}]],
      [[{"value":1.0}]],
      [[{"value":1e0}]],
      [[{"value":9007199254740992}]],
    }) do
      assert_raises("nonnegative safe integers", function()
        frame.decoder():push(framed(body))
      end)
    end

    local decoded = frame.decoder():push(framed([[{"value":9007199254740991}]]))
    assert_equal(9007199254740991, decoded[1].value)
    assert_raises("nonnegative safe integers", function()
      frame.encode({ value = -1 })
    end)
  end)

  it("rejects JSON null even when it belongs to an unknown member", function()
    local frame = require("refine.transport.frame")
    assert_raises("JSON null is not part of Protocol 1%.0", function()
      frame.decoder():push(framed([[{"type":"welcome","com.example.future":null}]]))
    end)
    assert_raises("JSON null is not part of Protocol 1%.0", function()
      frame.encode({ type = "welcome", future = vim.NIL })
    end)
  end)

  it("rejects JSON containing invalid UTF-8", function()
    local frame = require("refine.transport.frame")
    local body = string.char(34, 0xc3, 0x28, 34)
    local encoded = string.char(0, 0, 0, #body) .. body
    assert_raises("valid UTF%-8", function()
      frame.decoder():push(encoded)
    end)
  end)

  it("rejects unpaired surrogate escapes and accepts a valid pair", function()
    local frame = require("refine.transport.frame")
    for _, body in ipairs({ [[{"text":"\uD800"}]], [[{"text":"\uDC00"}]] }) do
      assert_raises("not valid JSON", function()
        frame.decoder():push(framed(body))
      end)
    end

    local decoded = frame.decoder():push(framed([[{"text":"\uD83D\uDE00"}]]))
    assert_equal("😀", decoded[1].text)
  end)

  it("rejects outbound JSON containing invalid UTF-8", function()
    local frame = require("refine.transport.frame")
    local ok, failure = pcall(frame.encode, {
      type = "snapshot",
      text = "private" .. string.char(0xff),
    })

    assert_equal(false, ok)
    assert_equal("TransportProtocolError", failure.kind)
    assert_equal("fatal", failure.recoverability)
    assert_matches("frame body is not valid UTF%-8", failure.message)
    assert_equal(nil, failure.message:match("private"))
  end)

  it("encodes a worst-case one MiB valid source snapshot within the protocol limit", function()
    local frame = require("refine.transport.frame")
    local wire = require("refine.transport.wire")
    local source = string.rep(string.char(1), 1024 * 1024)
    local command = {
      type = "openDocument",
      snapshot = {
        revision = "revision-1",
        sources = {
          {
            sourceId = "document",
            sourceSyntax = "plainText",
            text = source,
          },
        },
      },
    }

    wire.validate_command(command)
    local encoded = frame.encode(command)
    local body_bytes = #encoded - 4

    assert_truthy(body_bytes > 4 * 1024 * 1024)
    assert_truthy(body_bytes <= frame.MAX_FRAME_BYTES)
  end)

  it("rejects a source larger than the Protocol 1.0 decoded-byte limit", function()
    local wire = require("refine.transport.wire")
    local command = {
      type = "openDocument",
      snapshot = {
        revision = "revision-1",
        sources = {
          {
            sourceId = "document",
            sourceSyntax = "plainText",
            text = string.rep("a", 1024 * 1024 + 1),
          },
        },
      },
    }

    assert_raises("text must be at most 1048576 UTF%-8 bytes", function()
      wire.validate_command(command)
    end)
  end)

  it("accepts only Protocol 1.0 source syntaxes", function()
    local wire = require("refine.transport.wire")
    local function command(source_syntax)
      return {
        type = "openDocument",
        snapshot = {
          revision = "revision-1",
          sources = {
            {
              sourceId = "document",
              sourceSyntax = source_syntax,
              text = "Prose",
            },
          },
        },
      }
    end

    for _, source_syntax in ipairs({
      "plainText",
      "markdownDocument",
      "latexDocument",
      "markdownDocumentHardLineBreaks",
    }) do
      wire.validate_command(command(source_syntax))
    end
    assert_raises("sourceSyntax is unsupported", function()
      wire.validate_command(command("mixed"))
    end)
  end)

  it("accepts the exact Protocol 1.0 writing-attention command", function()
    local wire = require("refine.transport.wire")
    local command = {
      type = "updateAttention",
      revision = "revision-1",
      attention = {
        sourceId = "document",
        caretOffset = 3,
        visibleRanges = {
          { location = 0, length = 5 },
          { location = 12, length = 4 },
        },
      },
    }

    wire.validate_command(command)

    local function rejects(mutator, message)
      local invalid = vim.deepcopy(command)
      mutator(invalid)
      assert_raises(message, function()
        wire.validate_command(invalid)
      end)
    end
    rejects(function(value)
      value.revision = ""
    end, "updateAttention.revision must be a 1%-to%-128%-byte visible ASCII identifier")
    rejects(function(value)
      value.attention.caretOffset = -1
    end, "caretOffset must be a nonnegative integer")
    rejects(function(value)
      value.attention.visibleRanges[1].length = 0
    end, "visibleRanges item must be nonempty")
    rejects(function(value)
      value.attention.visibleRanges[2].location = 4
    end, "visibleRanges must be ordered and non%-overlapping")
    local extended = vim.deepcopy(command)
    extended.futureCommandMetadata = { version = 1 }
    extended.attention.futureAttentionMetadata = true
    wire.validate_command(extended)

    assert_equal(1, wire.PROTOCOL_MAJOR)
    assert_equal(0, wire.PROTOCOL_MINOR)
  end)

  it("requires descending nonoverlapping non-no-op Apply edits", function()
    local wire = require("refine.transport.wire")
    local envelope = {
      type = "event",
      sequence = 1,
      epoch = "epoch-1",
      event = {
        type = "applyRequested",
        actionId = "action-1",
        transactionId = "transaction-1",
        request = {
          expectedRevision = "revision-1",
          sourceId = "document",
          edits = {
            { range = { location = 8, length = 1 }, expectedText = "x", replacement = "y" },
            { range = { location = 2, length = 2 }, expectedText = "ab", replacement = "cd" },
          },
        },
      },
    }
    wire.decode_event(envelope)

    local function rejects(mutator, message)
      local invalid = vim.deepcopy(envelope)
      mutator(invalid.event.request.edits)
      assert_raises(message, function()
        wire.decode_event(invalid)
      end)
    end
    rejects(function(edits)
      edits[1], edits[2] = edits[2], edits[1]
    end, "descending, untied, and non%-overlapping")
    rejects(function(edits)
      edits[2].range = { location = 8, length = 0 }
    end, "descending, untied, and non%-overlapping")
    rejects(function(edits)
      edits[2].range = { location = 7, length = 2 }
    end, "descending, untied, and non%-overlapping")
    rejects(function(edits)
      edits[2].expectedText = "cd"
    end, "must change text")
    rejects(function(edits)
      edits[2].range = { location = 2, length = 0 }
      edits[2].expectedText = "x"
      edits[2].replacement = "x"
    end, "must change text")
    rejects(function(edits)
      edits[1].range = { location = 9007199254740991, length = 1 }
    end, "coordinates must be nonnegative integers")
  end)

  it("enforces closed Apply outcome branches", function()
    local wire = require("refine.transport.wire")
    local snapshot = {
      revision = "revision-2",
      sources = { { sourceId = "document", text = "text", sourceSyntax = "plainText" } },
    }
    for _, outcome in ipairs({
      { status = "applied", reason = "staleRevision", snapshot = snapshot },
      { status = "unavailable", reason = "readOnly" },
      { status = "indeterminate", reason = "textMismatch" },
    }) do
      assert_raises("malformed", function()
        wire.validate_command({
          type = "completeApply",
          transactionId = "transaction-1",
          outcome = outcome,
        })
      end)
    end
  end)

  it("ignores unknown nested event members while preserving known fields", function()
    local wire = require("refine.transport.wire")
    local envelope = {
      type = "event",
      sequence = 1,
      epoch = "epoch-1",
      futureEnvelopeMetadata = true,
      event = {
        type = "presentationContentReplaced",
        checkId = "check-1",
        futureEventMetadata = true,
        content = {
          documentRevision = "revision-1",
          status = "checking",
          futureContentMetadata = true,
          progress = { completedUnitCount = 1, totalUnitCount = 2, futureProgressMetadata = true },
          appearance = {
            futureAppearanceMetadata = true,
            highlight = {
              style = "underline",
              grammarColor = "#FF2D55",
              fluencyColor = "#007AFF",
              futureHighlightMetadata = true,
            },
            diff = {
              additionColor = "#34C759",
              deletionColor = "#FF3B30",
              showHiddenWhitespace = true,
              futureDiffMetadata = true,
            },
          },
          interaction = {
            automaticChecksEnabled = true,
            futureInteractionMetadata = true,
            quickApply = {
              enabled = true,
              applyKey = "tab",
              dismissKey = "escape",
              activationStyle = "highlightChanges",
              futureQuickApplyMetadata = true,
            },
          },
          suggestions = {
            {
              id = "suggestion-1",
              sourceId = "document",
              kind = "grammar",
              futureSuggestionMetadata = true,
              attribution = {
                languageDisplayName = "English",
                textDirection = "ltr",
                checkModelDisplayName = "Model",
                futureAttributionMetadata = true,
              },
              activationRange = { location = 0, length = 4, futureRangeMetadata = true },
              highlightRanges = { { location = 0, length = 4, futureRangeMetadata = true } },
              diff = { { kind = "unchanged", text = "text", futureDiffRunMetadata = true } },
              availableActions = { "dismiss" },
            },
          },
        },
      },
    }

    local decoded = wire.decode_event(envelope)

    assert_equal("checking", decoded.event.content.status)
    assert_equal(1, decoded.event.content.progress.completedUnitCount)
    assert_equal("underline", decoded.event.content.appearance.highlight.style)
    assert_equal("tab", decoded.event.content.interaction.quickApply.applyKey)
    assert_equal("Model", decoded.event.content.suggestions[1].attribution.checkModelDisplayName)
    assert_equal({ location = 0, length = 4 }, decoded.event.content.suggestions[1].activationRange)
    assert_equal(nil, decoded.futureEnvelopeMetadata)
    assert_equal(nil, decoded.event.futureEventMetadata)
    assert_equal(nil, decoded.event.content.futureContentMetadata)
    assert_equal(nil, decoded.event.content.appearance.futureAppearanceMetadata)
    assert_equal(nil, decoded.event.content.interaction.quickApply.futureQuickApplyMetadata)
    assert_equal(nil, decoded.event.content.suggestions[1].futureSuggestionMetadata)

    for _, mutate in ipairs({
      function(content)
        content.coverage = "full"
      end,
      function(content)
        content.status = "complete"
        content.coverage = "full"
      end,
      function(content)
        content.status = "unavailable"
        content.unavailableReason = "disconnected"
        content.coverage = "full"
        content.progress = nil
        content.suggestions = {}
      end,
      function(content)
        content.status = "pending"
        content.unavailableReason = "disconnected"
        content.progress = nil
        content.suggestions = {}
      end,
      function(content)
        content.status = "closed"
        content.suggestions = {}
      end,
    }) do
      local invalid = vim.deepcopy(envelope)
      mutate(invalid.event.content)
      assert_raises("presentation", function()
        wire.decode_event(invalid)
      end)
    end
  end)

  it("ignores unknown welcome members while preserving the base handshake", function()
    local wire = require("refine.transport.wire")
    local decoded = wire.decode_handshake({
      type = "welcome",
      futureWelcomeMetadata = true,
      protocol = { major = 1, minor = 0, futureProtocolMetadata = true },
      serverEpoch = "epoch-1",
      runResumed = false,
      limits = {
        maxFrameBytes = 8388608,
        maxSources = 2,
        maxSourceBytes = 1048576,
        futureLimitMetadata = true,
      },
      capabilities = {},
    })

    assert_equal({
      type = "welcome",
      protocol = { major = 1, minor = 0 },
      serverEpoch = "epoch-1",
      runResumed = false,
      limits = { maxFrameBytes = 8388608, maxSources = 2, maxSourceBytes = 1048576 },
      capabilities = {},
    }, decoded)
  end)

  it("decodes every closed handshake rejection and recovery pair", function()
    local wire = require("refine.transport.wire")
    local cases = {
      {
        reason = "incompatibleProtocol",
        recovery = "none",
        receivedProtocol = { major = 2, minor = 5 },
      },
      { reason = "invalidClient", recovery = "none" },
      { reason = "runUnavailable", recovery = "newRun" },
      { reason = "runUnavailable", recovery = "retry" },
      { reason = "serverBusy", recovery = "retry" },
      { reason = "engineUnavailable", recovery = "retry" },
    }

    for _, case in ipairs(cases) do
      local frame = vim.tbl_extend("force", {
        type = "rejected",
        protocol = { major = 1, minor = 0, futureProtocolMetadata = true },
        futureRejectionMetadata = true,
      }, case)
      local expected = vim.tbl_extend("force", {
        type = "rejected",
        protocol = { major = 1, minor = 0 },
      }, case)

      assert_equal(expected, wire.decode_handshake(frame))
    end

    for _, frame in ipairs({
      {
        type = "rejected",
        reason = "serverBusy",
        recovery = "none",
        protocol = { major = 1, minor = 0 },
      },
      {
        type = "rejected",
        reason = "invalidClient",
        recovery = "none",
        protocol = { major = 1, minor = 0 },
        receivedProtocol = { major = 1, minor = 0 },
      },
      {
        type = "rejected",
        reason = "incompatibleProtocol",
        recovery = "none",
        protocol = { major = 1, minor = 0 },
      },
      {
        type = "rejected",
        reason = "serverBusy",
        recovery = "retry",
        protocol = { major = 1, minor = 1 },
      },
    }) do
      local ok, err = pcall(wire.decode_handshake, frame)
      assert_equal(false, ok)
      assert_equal("TransportProtocolError", err.kind)
    end
  end)

  it("enforces the closed fault code and severity matrix", function()
    local wire = require("refine.transport.wire")
    local legal = {
      { "invalidSequence", true },
      { "malformedMessage", false },
      { "malformedMessage", true },
      { "resourceLimit", false },
      { "resourceLimit", true },
      { "internalError", false },
      { "internalError", true },
      { "invalidDocument", false },
      { "unsupportedSource", false },
      { "engineUnavailable", false },
    }
    for index, pair in ipairs(legal) do
      local decoded = wire.decode_event({
        type = "event",
        sequence = index,
        epoch = "epoch",
        event = { type = "fault", code = pair[1], fatal = pair[2] },
      })
      assert_equal({ type = "fault", code = pair[1], fatal = pair[2] }, decoded.event)
    end

    for index, pair in ipairs({
      { "invalidSequence", false },
      { "invalidDocument", true },
      { "unsupportedSource", true },
      { "engineUnavailable", true },
      { "authenticationFailed", true },
      { "futureFault", false },
    }) do
      local ok, err = pcall(wire.decode_event, {
        type = "event",
        sequence = index,
        epoch = "epoch",
        event = { type = "fault", code = pair[1], fatal = pair[2] },
      })
      assert_equal(false, ok)
      assert_equal("TransportProtocolError", err.kind)
    end
  end)

  it("uses the exact visible-ASCII identifier boundary for correlations", function()
    local wire = require("refine.transport.wire")
    local longest = string.rep("!", 128)
    assert_equal(longest, wire.validate_identifier(longest))

    for _, value in ipairs({ "", string.rep("!", 129), "two words", "line\nbreak", "caf\195\169" }) do
      local ok, err = pcall(wire.validate_identifier, value)
      assert_equal(false, ok)
      assert_equal("TransportProtocolError", err.kind)
    end

    for _, envelope in ipairs({
      {
        type = "event",
        sequence = 1,
        epoch = "bad epoch",
        event = { type = "fault", code = "internalError", fatal = false },
      },
      {
        type = "event",
        sequence = 1,
        epoch = "epoch",
        causeCommandId = "correlation\n",
        event = { type = "fault", code = "internalError", fatal = false },
      },
    }) do
      local ok, err = pcall(wire.decode_event, envelope)
      assert_equal(false, ok)
      assert_equal("TransportProtocolError", err.kind)
    end
  end)
end)
