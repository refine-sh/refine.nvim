describe("length-prefixed JSON frames", function()
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

  it("rejects JSON containing invalid UTF-8", function()
    local frame = require("refine.transport.frame")
    local body = string.char(34, 0xc3, 0x28, 34)
    local encoded = string.char(0, 0, 0, #body) .. body
    assert_raises("valid UTF%-8", function()
      frame.decoder():push(encoded)
    end)
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

  it("accepts only Protocol 2.5 source syntaxes", function()
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

    for _, source_syntax in ipairs({ "plainText", "markdownDocument", "latexDocument" }) do
      wire.validate_command(command(source_syntax))
    end
    assert_raises("sourceSyntax is unsupported", function()
      wire.validate_command(command("mixed"))
    end)
  end)
end)
