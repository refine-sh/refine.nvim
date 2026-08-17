local sha256 = require("support.sha256")

local function read_bytes(path)
  local descriptor = assert(vim.uv.fs_open(path, "r", 438))
  local stat = assert(vim.uv.fs_fstat(descriptor))
  local data = assert(vim.uv.fs_read(descriptor, stat.size, 0))
  assert(vim.uv.fs_close(descriptor))
  return data
end

local function decode_json(path)
  return vim.json.decode(read_bytes(path))
end

local function sorted(values)
  local result = vim.deepcopy(values)
  table.sort(result)
  return result
end

local function unique_count(values)
  local seen = {}
  for _, value in ipairs(values) do
    seen[value] = true
  end
  return vim.tbl_count(seen)
end

local function list_files(root, prefix, result)
  prefix = prefix or ""
  result = result or {}
  local directory = prefix == "" and root or root .. "/" .. prefix
  local scanner = assert(vim.uv.fs_scandir(directory))
  while true do
    local name, kind = vim.uv.fs_scandir_next(scanner)
    if name == nil then
      break
    end
    local relative = prefix == "" and name or prefix .. "/" .. name
    if kind == "directory" then
      list_files(root, relative, result)
    else
      result[#result + 1] = relative
    end
  end
  table.sort(result)
  return result
end

local function contains(values, expected)
  for _, value in ipairs(values) do
    if value == expected then
      return true
    end
  end
  return false
end

local function is_vendored_artifact(artifact, pin)
  return contains(pin.vendoredSubset.includedKinds, artifact.kind)
    or contains(pin.vendoredSubset.includedPaths, artifact.path)
end

local fixture_bundle

local function load_fixture_bundle()
  if fixture_bundle ~= nil then
    return fixture_bundle
  end
  local test_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
  local root = test_root .. "/fixtures/refine-protocol"
  local pin = decode_json(root .. "/pin.json")
  assert_equal(1, pin.formatVersion)
  assert_equal({ major = 1, minor = 0 }, pin.protocol)
  assert_truthy(
    type(pin.protocolCommit) == "string" and pin.protocolCommit:match("^[0-9a-f]+$") and #pin.protocolCommit == 40
  )
  assert_equal(pin.upstreamArtifactDigest, pin.artifactDirectory)
  assert_equal("manifest order: UTF-8 path, NUL, lowercase SHA-256, LF", pin.vendoredSubset.canonicalization)

  local artifact_root = root .. "/" .. pin.artifactDirectory
  local manifest_data = read_bytes(artifact_root .. "/manifest.json")
  assert_equal(pin.manifestDigest, sha256.hex(manifest_data))
  local manifest = vim.json.decode(manifest_data, { luanil = { object = true, array = true } })
  assert_equal(1, manifest.formatVersion)
  assert_equal(pin.releaseCandidate, manifest.releaseCandidate)
  assert_equal(pin.protocol, manifest.protocol)
  assert_equal(pin.upstreamArtifactDigest, manifest.artifactDigest)
  assert_equal(pin.baseArtifactDigest, manifest.baseArtifactDigest)
  assert_equal(pin.capabilityRegistryDigest, manifest.capabilityRegistryDigest)

  local canonical_artifacts = {}
  local expected_files = { "manifest.json" }
  local artifacts = {}
  for _, artifact in ipairs(manifest.artifacts) do
    if is_vendored_artifact(artifact, pin) then
      local data = read_bytes(artifact_root .. "/" .. artifact.path)
      assert_equal(artifact.sha256, sha256.hex(data))
      canonical_artifacts[#canonical_artifacts + 1] = artifact.path .. "\0" .. artifact.sha256 .. "\n"
      expected_files[#expected_files + 1] = artifact.path
      artifacts[#artifacts + 1] = artifact
    end
  end
  assert_equal(pin.vendoredSubset.artifactCount, #artifacts)
  assert_equal(sorted(expected_files), list_files(artifact_root))
  assert_equal(pin.vendoredSubset.digest, sha256.hex(table.concat(canonical_artifacts)))

  local registry_data = read_bytes(artifact_root .. "/registry/capabilities.json")
  assert_equal(pin.capabilityRegistryDigest, sha256.hex(registry_data))
  local registry = vim.json.decode(registry_data, { luanil = { object = true, array = true } })
  assert_equal(1, registry.schemaVersion)
  assert_equal(pin.protocol, registry.protocol)
  assert_equal({}, registry.capabilities)

  local state_ids = {}
  local states = {}
  local json_positive_ids = {}
  local json_negative_ids = {}
  local frame_ids = {}
  for _, artifact in ipairs(artifacts) do
    if artifact.path:match("^vectors/state/[^/]+%.json$") then
      local vector = decode_json(artifact_root .. "/" .. artifact.path)
      local file_id = assert(artifact.path:match("/([^/]+)%.json$"))
      assert_equal(1, vector.formatVersion)
      assert_equal(file_id, vector.id)
      assert_equal("boolean", type(vector.socketRunnable))
      assert_truthy(type(vector.connections) == "table" and vim.islist(vector.connections))
      for _, connection in ipairs(vector.connections) do
        assert_truthy(type(connection) == "table" and not vim.islist(connection))
        assert_truthy(type(connection.steps) == "table" and vim.islist(connection.steps))
      end
      state_ids[#state_ids + 1] = vector.id
      states[vector.id] = vector
    elseif artifact.path:match("^vectors/") then
      local collection = decode_json(artifact_root .. "/" .. artifact.path)
      assert_equal(1, collection.formatVersion)
      assert_truthy(type(collection.cases) == "table" and vim.islist(collection.cases))
      local case_ids
      if artifact.path:match("^vectors/json/positive/") then
        case_ids = json_positive_ids
      elseif artifact.path:match("^vectors/json/negative/") then
        case_ids = json_negative_ids
      elseif artifact.path:match("^vectors/frames/") then
        case_ids = frame_ids
      end
      assert_truthy(case_ids ~= nil, "unclassified vector collection " .. artifact.path)
      for _, case in ipairs(collection.cases) do
        assert_truthy(type(case.id) == "string" and case.id ~= "")
        case_ids[#case_ids + 1] = case.id
      end
    elseif artifact.kind == "schema" then
      local schema = decode_json(artifact_root .. "/" .. artifact.path)
      assert_truthy(type(schema) == "table" and not vim.islist(schema))
    end
  end
  assert_equal(139, #manifest.jsonPositiveCaseIds)
  assert_equal(60, #manifest.jsonNegativeCaseIds)
  assert_equal(13, #manifest.frameCaseIds)
  assert_equal(9, #manifest.stateScenarioIds)
  assert_equal(manifest.jsonPositiveCaseIds, json_positive_ids)
  assert_equal(manifest.jsonNegativeCaseIds, json_negative_ids)
  assert_equal(manifest.frameCaseIds, frame_ids)
  assert_equal(manifest.stateScenarioIds, state_ids)
  assert_equal(#json_positive_ids, unique_count(json_positive_ids))
  assert_equal(#json_negative_ids, unique_count(json_negative_ids))
  assert_equal(#frame_ids, unique_count(frame_ids))
  assert_equal(#state_ids, vim.tbl_count(states))

  local golden_data = read_bytes(artifact_root .. "/vectors/state/golden-writing-session.json")
  assert_equal(pin.goldenVectorDigest, sha256.hex(golden_data))
  local golden = states["golden-writing-session"]
  assert_equal(1, golden.formatVersion)
  assert_equal("golden-writing-session", golden.id)
  fixture_bundle = {
    artifact_root = artifact_root,
    artifacts = artifacts,
    frame_ids = frame_ids,
    json_negative_ids = json_negative_ids,
    json_positive_ids = json_positive_ids,
    manifest = manifest,
    messages = golden.messages,
    pin = pin,
    states = states,
  }
  return fixture_bundle
end

local function load_fixture()
  return load_fixture_bundle().messages
end

local function encode_length(length)
  return string.char(
    math.floor(length / 0x1000000) % 0x100,
    math.floor(length / 0x10000) % 0x100,
    math.floor(length / 0x100) % 0x100,
    length % 0x100
  )
end

local function decode_hex(value)
  assert_equal(0, #value % 2)
  return (value:gsub("..", function(byte)
    return string.char(assert(tonumber(byte, 16)))
  end))
end

local function base_appearance()
  return {
    highlight = { style = "underline", grammarColor = "#FF2D55", fluencyColor = "#007AFF" },
    diff = { additionColor = "#34C759", deletionColor = "#FF3B30", showHiddenWhitespace = true },
  }
end

local function base_interaction()
  return {
    automaticChecksEnabled = true,
    quickApply = {
      enabled = true,
      applyKey = "tab",
      dismissKey = "escape",
      activationStyle = "showTipAndHighlight",
    },
  }
end

local function base_suggestion()
  return {
    id = "suggestion",
    sourceId = "document",
    kind = "grammar",
    attribution = {
      languageDisplayName = "English",
      textDirection = "ltr",
      checkModelDisplayName = "Fixture",
    },
    activationRange = { location = 0, length = 1 },
    highlightRanges = { { location = 0, length = 1 } },
    diff = { { kind = "unchanged", text = "a" } },
    availableActions = { "apply" },
  }
end

local function presentation_content(status)
  local content = {
    documentRevision = "revision",
    status = status,
    suggestions = {},
    appearance = base_appearance(),
    interaction = base_interaction(),
  }
  if status == "checking" then
    content.progress = { completedUnitCount = 0, totalUnitCount = 1 }
  elseif status == "complete" then
    content.coverage = "full"
  elseif status == "unavailable" then
    content.unavailableReason = "disconnected"
  end
  return content
end

local function event_envelope(event, sequence)
  return {
    type = "event",
    sequence = sequence or 1,
    epoch = "epoch",
    event = event,
  }
end

local function presentation_envelope(content)
  return event_envelope({
    type = "presentationContentReplaced",
    checkId = "check",
    content = content,
  })
end

local function generated_value(generator)
  if generator.kind == "helloCapabilities" then
    local capabilities = {}
    for index = 0, generator.count - 1 do
      capabilities[#capabilities + 1] = ("com.example.feature-%d.v1"):format(index)
    end
    return {
      type = "hello",
      protocol = { major = 1, minor = 0 },
      client = { id = "com.example.writer", version = "1", host = "host" },
      hostCapabilities = { interceptableSuggestionActionKeys = {} },
      runId = "run",
      launchToken = string.rep("A", 64),
      capabilities = capabilities,
    }
  elseif generator.kind == "sourceBytes" then
    return {
      type = "command",
      sequence = 1,
      id = "command-source-limit",
      command = {
        type = "openDocument",
        snapshot = {
          revision = "revision",
          sources = {
            {
              sourceId = "document",
              text = string.rep("a", generator.bytes),
              sourceSyntax = "plainText",
            },
          },
        },
      },
    }
  elseif generator.kind == "capabilityRegistry" then
    local capabilities = {}
    for index = 0, generator.count - 1 do
      capabilities[#capabilities + 1] = {
        id = ("%s.feature-%d.v1"):format(generator.publisher, index),
        specification = ("capabilities/feature-%d.md"):format(index),
        digest = ("%064x"):format(index),
      }
    end
    return {
      registrySchema = "../schema/capability-registry.schema.json",
      schemaVersion = 1,
      protocol = { major = 1, minor = 0 },
      capabilities = capabilities,
    }
  elseif generator.kind == "invalidProgress" then
    local content = presentation_content("checking")
    content.progress = { completedUnitCount = 2, totalUnitCount = 1 }
    return presentation_envelope(content)
  elseif generator.kind == "invalidPresentation" then
    local content = presentation_content(generator.status)
    if generator.defect == "missingCoverage" then
      content.coverage = nil
    elseif generator.defect == "missingReason" then
      content.unavailableReason = nil
    elseif generator.defect == "progress" then
      content.progress = { completedUnitCount = 0, totalUnitCount = 1 }
    elseif generator.defect == "suggestion" then
      content.suggestions = { {} }
    elseif generator.defect == "closedMembers" then
      content.coverage = "full"
    elseif generator.defect == "duplicateActions" then
      local suggestion = base_suggestion()
      suggestion.availableActions = { "apply", "apply" }
      content.suggestions = { suggestion }
    else
      error("unknown invalid presentation generator defect: " .. tostring(generator.defect))
    end
    return presentation_envelope(content)
  end
  error("unknown protocol vector generator: " .. tostring(generator.kind))
end

local function capture_hello(hello)
  local sent
  local connection = {}
  function connection:receive() end
  function connection:send(value, done)
    sent = vim.deepcopy(value)
    done(nil)
  end
  function connection:close() end

  local client = require("refine.transport").new({
    client = hello.client,
    frontend = hello.frontend,
    host_capabilities = hello.hostCapabilities,
    known_capabilities = hello.capabilities,
    capabilities = hello.capabilities,
    endpoint_locator = {
      locate = function(_, done)
        done(nil, {
          version = 1,
          socketPath = "/private/tmp/refine-fixture/socket",
          launchToken = hello.launchToken,
          serverEpoch = "epoch",
          protocolMajor = 1,
          protocolMinor = 0,
          pid = 1,
        })
      end,
    },
    connector = {
      connect = function(_, _, done)
        done(nil, connection)
      end,
    },
    delay = function()
      return function() end
    end,
  })
  client:connect({ run_id = hello.runId }, function() end)
  assert_equal(hello, sent)
end

local function exercise_positive_fragment(case)
  local wire = require("refine.transport.wire")
  local schema = case.schema
  local value = case.value
  if schema:match("/%$defs/safeInteger$") then
    local json = require("refine.transport.json")
    assert_equal(value, json.decode_object(([[{"value":%.0f}]]):format(value)).value)
  elseif schema:match("/%$defs/uint16$") then
    return "schema-only uint16 fragment"
  elseif schema:match("/%$defs/sequence$") then
    wire.decode_event(event_envelope({ type = "documentAccepted", revision = "revision" }, value))
  elseif schema:match("/%$defs/identifier$") then
    wire.validate_identifier(value)
  elseif schema:match("/sourceSyntax$") then
    wire.validate_snapshot({
      revision = "revision",
      sources = { { sourceId = "document", text = "text", sourceSyntax = value } },
    }, "snapshot")
  elseif schema:match("/presentedSuggestion/properties/kind$") then
    local content = presentation_content("complete")
    local suggestion = base_suggestion()
    suggestion.kind = value
    content.suggestions = { suggestion }
    wire.decode_event(presentation_envelope(content))
  elseif schema:match("/diffRun/properties/kind$") then
    local content = presentation_content("complete")
    local suggestion = base_suggestion()
    suggestion.diff = { { kind = value, text = "text" } }
    content.suggestions = { suggestion }
    wire.decode_event(presentation_envelope(content))
  elseif schema:match("/attribution/properties/textDirection$") then
    local content = presentation_content("complete")
    local suggestion = base_suggestion()
    suggestion.attribution.textDirection = value
    content.suggestions = { suggestion }
    wire.decode_event(presentation_envelope(content))
  elseif schema:match("/highlight/properties/style$") then
    local content = presentation_content("complete")
    content.appearance.highlight.style = value
    wire.decode_event(presentation_envelope(content))
  elseif schema:match("/quickApply/properties/activationStyle$") then
    local content = presentation_content("complete")
    content.interaction.quickApply.activationStyle = value
    wire.decode_event(presentation_envelope(content))
  elseif schema:match("/presentationContent/properties/status$") then
    wire.decode_event(presentation_envelope(presentation_content(value)))
  elseif schema:match("/presentationContent/properties/coverage$") then
    local content = presentation_content("complete")
    content.coverage = value
    wire.decode_event(presentation_envelope(content))
  elseif schema:match("/resyncRequired/properties/reason$") then
    wire.decode_event(event_envelope({ type = "resyncRequired", reason = value }))
  elseif schema:match("/applyOutcome/oneOf/1/properties/reason$") then
    wire.validate_command({
      type = "completeApply",
      transactionId = "transaction",
      outcome = {
        status = "rejected",
        reason = value,
        snapshot = {
          revision = "revision",
          sources = { { sourceId = "document", text = "text", sourceSyntax = "plainText" } },
        },
      },
    })
  elseif schema:match("/applyOutcome/oneOf/2/properties/reason$") then
    wire.validate_command({
      type = "completeApply",
      transactionId = "transaction",
      outcome = { status = "unsupported", reason = value },
    })
  elseif schema:match("/%$defs/actionKey$") then
    wire.validate_host_capabilities({ interceptableSuggestionActionKeys = { value } })
  elseif schema:match("/presentationContent/properties/unavailableReason$") then
    local content = presentation_content("unavailable")
    content.unavailableReason = value
    wire.decode_event(presentation_envelope(content))
  elseif schema:match("/explanationUpdate/oneOf/3/properties/reason$") then
    wire.decode_event(event_envelope({
      type = "explanationReplaced",
      actionId = "action",
      update = { status = "unavailable", reason = value },
    }))
  elseif schema:match("/actionRejected/properties/reason$") then
    wire.decode_event(event_envelope({ type = "actionRejected", actionId = "action", reason = value }))
  else
    error(("unclassified positive fragment %s (%s)"):format(case.id, schema))
  end
  return "runtime"
end

local function exercise_positive_case(case)
  local endpoint = require("refine.transport.endpoint")
  local wire = require("refine.transport.wire")
  local value = case.generate and generated_value(case.generate) or case.value
  if case.generate and case.generate.kind == "capabilityRegistry" then
    assert_equal(case.generate.count, #value.capabilities)
    return "schema-only capability registry generator"
  elseif case.generate and case.generate.kind == "helloCapabilities" then
    capture_hello(value)
  elseif case.generate and case.generate.kind == "sourceBytes" then
    wire.validate_command(value.command)
  elseif type(value) == "table" and value.type == "command" then
    wire.validate_identifier(value.id, "command id")
    wire.validate_command(value.command)
  elseif type(value) == "table" and value.type == "event" then
    wire.decode_event(value)
  elseif type(value) == "table" and value.type == "hello" then
    capture_hello(value)
  elseif type(value) == "table" and (value.type == "welcome" or value.type == "rejected") then
    wire.decode_handshake(value, value.capabilities or {}, value.capabilities or {})
  elseif type(value) == "table" and value.version == 1 and value.socketPath ~= nil then
    assert_equal(value, endpoint.parse(vim.json.encode(value)))
  elseif type(value) == "table" and value.type == "fault" then
    wire.decode_event(event_envelope(value))
  elseif type(value) == "table" and value.schemaVersion == 1 and value.capabilities ~= nil then
    return "schema-only capability registry"
  else
    return exercise_positive_fragment(case)
  end
  return "runtime"
end

local schema_only_negative = {
  ["capability-id-requires-reverse-domain-publisher"] = true,
  ["command-sequence-over-uint32"] = true,
  ["command-sequence-zero"] = true,
  ["hello-capabilities-are-required"] = true,
  ["hello-requires-exact-protocol-1.0"] = true,
  ["negative-integer-is-outside-sequence-range"] = true,
  ["registry-ids-must-be-unique"] = true,
}

local function exercise_negative_case(case)
  if schema_only_negative[case.id] then
    return "schema-only producer shape or capability registry"
  end
  local endpoint = require("refine.transport.endpoint")
  local wire = require("refine.transport.wire")
  local value = case.generate and generated_value(case.generate) or case.value
  local ok
  if case.generate and case.generate.kind == "helloCapabilities" then
    ok = pcall(wire.capability_offers, value.capabilities, value.capabilities)
  elseif type(value) == "table" and value.type == "command" then
    ok = pcall(function()
      wire.validate_identifier(value.id, "command id")
      wire.validate_command(value.command)
    end)
  elseif type(value) == "table" and value.type == "event" then
    ok = pcall(wire.decode_event, value)
  elseif type(value) == "table" and (value.type == "welcome" or value.type == "rejected") then
    ok = pcall(wire.decode_handshake, value, {}, {})
  elseif type(value) == "table" and value.type == "hello" then
    ok = pcall(capture_hello, value)
  elseif type(value) == "table" and value.version ~= nil and value.socketPath ~= nil then
    ok = pcall(endpoint.parse, vim.json.encode(value))
  elseif case.schema:match("/%$defs/identifier$") then
    ok = pcall(wire.validate_identifier, value)
  elseif case.schema:match("/%$defs/utf16Range$") then
    ok = pcall(
      wire.decode_event,
      event_envelope({
        type = "applyRequested",
        actionId = "action",
        transactionId = "transaction",
        request = {
          expectedRevision = "revision",
          sourceId = "document",
          edits = { { range = value, expectedText = "a", replacement = "b" } },
        },
      })
    )
  elseif case.schema:match("/%$defs/attribution$") then
    local content = presentation_content("complete")
    local suggestion = base_suggestion()
    suggestion.attribution = value
    content.suggestions = { suggestion }
    ok = pcall(wire.decode_event, presentation_envelope(content))
  elseif case.schema:match("/%$defs/explanationAttribution$") then
    ok = pcall(
      wire.decode_event,
      event_envelope({
        type = "explanationReplaced",
        actionId = "action",
        update = { status = "started", attribution = value },
      })
    )
  else
    error(("unclassified negative vector %s (%s)"):format(case.id, case.schema))
  end
  if ok then
    error("negative protocol vector unexpectedly passed the production seam: " .. case.id)
  end
  return "runtime rejection"
end

describe("integration protocol 1.0 golden transcript", function()
  it("pins every schema, vector, registry byte, and advertised state scenario", function()
    local bundle = load_fixture_bundle()
    assert_equal(bundle.pin.upstreamArtifactDigest, bundle.manifest.artifactDigest)
    assert_equal(bundle.manifest.stateScenarioIds, sorted(vim.tbl_keys(bundle.states)))
  end)

  it("runs every applicable positive JSON vector through a production seam", function()
    local bundle = load_fixture_bundle()
    local classifications = {}
    local count = 0
    for _, artifact in ipairs(bundle.artifacts) do
      if artifact.path:match("^vectors/json/positive/[^/]+%.json$") then
        local collection = decode_json(bundle.artifact_root .. "/" .. artifact.path)
        for _, case in ipairs(collection.cases) do
          classifications[case.id] = exercise_positive_case(case)
          count = count + 1
        end
      end
    end
    assert_truthy(count > 0)
    assert_equal("schema-only uint16 fragment", classifications["uint16-minimum"])
    assert_equal("schema-only uint16 fragment", classifications["uint16-maximum"])
    if classifications["future-registry-can-exceed-negotiation-limit"] ~= nil then
      assert_equal(
        "schema-only capability registry generator",
        classifications["future-registry-can-exceed-negotiation-limit"]
      )
    end
    assert_equal(count, vim.tbl_count(classifications))
  end)

  it("rejects every portable JSON lexical vector at the production object decoder", function()
    local bundle = load_fixture_bundle()
    local json = require("refine.transport.json")
    local count = 0
    for _, artifact in ipairs(bundle.artifacts) do
      if artifact.path == "vectors/json/negative/portable-json.json" then
        local collection = decode_json(bundle.artifact_root .. "/" .. artifact.path)
        for _, case in ipairs(collection.cases) do
          local document = case.documentText or vim.json.encode(case.value)
          local ok = pcall(json.decode_object, document)
          assert_equal(false, ok)
          count = count + 1
        end
      end
    end
    assert_truthy(count > 0)
  end)

  it("rejects every applicable negative shape and semantic vector", function()
    local bundle = load_fixture_bundle()
    local classifications = {}
    local count = 0
    for _, artifact in ipairs(bundle.artifacts) do
      if
        artifact.path:match("^vectors/json/negative/[^/]+%.json$") and not artifact.path:match("/portable%-json%.json$")
      then
        local collection = decode_json(bundle.artifact_root .. "/" .. artifact.path)
        for _, case in ipairs(collection.cases) do
          classifications[case.id] = exercise_negative_case(case)
          count = count + 1
        end
      end
    end
    assert_truthy(count > 0)
    for id in pairs(schema_only_negative) do
      if classifications[id] ~= nil then
        assert_equal("schema-only producer shape or capability registry", classifications[id])
      end
    end
    assert_equal(count, vim.tbl_count(classifications))
  end)

  it("runs every shared frame case through the production streaming decoder", function()
    local bundle = load_fixture_bundle()
    local frame = require("refine.transport.frame")
    local count = 0
    for _, artifact in ipairs(bundle.artifacts) do
      if artifact.path:match("^vectors/frames/[^/]+%.json$") then
        local collection = decode_json(bundle.artifact_root .. "/" .. artifact.path)
        for _, case in ipairs(collection.cases) do
          local bytes
          if case.generate ~= nil then
            assert_equal("paddedObject", case.generate.kind)
            local payload = [[{"pad":"]] .. string.rep("a", case.generate.payloadBytes - 10) .. [["}]]
            assert_equal(case.generate.payloadBytes, #payload)
            bytes = encode_length(#payload) .. payload
          else
            bytes = decode_hex(case.hex)
          end
          local ok, result = pcall(function()
            local decoder = frame.decoder()
            local values = decoder:push(bytes)
            decoder:finish()
            return values
          end)
          if case.expected == "invalid" then
            assert_equal(false, ok)
            assert_equal("TransportProtocolError", result.kind)
          else
            assert_equal(true, ok)
            assert_equal(1, #result)
            if case.schema ~= nil then
              exercise_positive_case({ id = case.id, schema = case.schema, value = result[1] })
            end
          end
          count = count + 1
        end
      end
    end
    assert_truthy(count > 0)
  end)

  it("loads every state vector and exercises its portable coordinate cases", function()
    local bundle = load_fixture_bundle()
    local utf16 = require("refine.integration.utf16")
    local wire = require("refine.transport.wire")
    local exercised = {}
    for id, vector in pairs(bundle.states) do
      exercised[#exercised + 1] = id
      for _, case in ipairs(vector.coordinateCases or {}) do
        assert_equal(case.valid, utf16.valid_range(case.text, case.range, false))
      end
      for _, case in ipairs(vector.applyEditCases or {}) do
        local ranges = vim.deepcopy(case.ranges)
        table.sort(ranges, function(left, right)
          return left.location > right.location
        end)
        local edits = {}
        for _, range in ipairs(ranges) do
          edits[#edits + 1] = {
            range = range,
            expectedText = range.length == 0 and "" or "expected",
            replacement = "replacement",
          }
        end
        local ok = pcall(
          wire.decode_event,
          event_envelope({
            type = "applyRequested",
            actionId = "action",
            transactionId = "transaction",
            request = {
              expectedRevision = "revision",
              sourceId = "document",
              edits = edits,
            },
          })
        )
        assert_equal(case.valid, ok)
      end
    end
    assert_equal(bundle.manifest.stateScenarioIds, sorted(exercised))
  end)

  it("is consumed without translation by the Lua wire decoder", function()
    local wire = require("refine.transport.wire")
    local fixture = load_fixture()

    assert_equal({ major = 1, minor = 0 }, fixture.hello.protocol)
    assert_equal(15, #fixture.hello.hostCapabilities.interceptableSuggestionActionKeys)
    assert_equal({}, fixture.hello.capabilities)
    assert_equal({
      type = "rejected",
      reason = "incompatibleProtocol",
      recovery = "none",
      protocol = { major = 1, minor = 0 },
      receivedProtocol = { major = 2, minor = 5 },
    }, fixture.rejection)
    assert_equal({ maxFrameBytes = 8388608, maxSources = 2, maxSourceBytes = 1048576 }, fixture.welcome.limits)
    assert_equal(
      { sourceId = "document", range = { location = 8, length = 2 } },
      fixture.selectionCheck.command.intent.selection
    )
    assert_equal({
      type = "updateAttention",
      revision = "fixture:0",
      attention = {
        sourceId = "document",
        caretOffset = 21,
        visibleRanges = { { location = 0, length = 23 } },
      },
    }, fixture.updateAttention.command)
    assert_equal(fixture.welcome, wire.decode_handshake(fixture.welcome))
    assert_equal(fixture.rejection, wire.decode_handshake(fixture.rejection))
    assert_equal(fixture.presentation, wire.decode_event(fixture.presentation))
    assert_equal(fixture.applyRequested, wire.decode_event(fixture.applyRequested))
  end)

  it("canonicalizes inbound events before they cross the host privacy boundary", function()
    local wire = require("refine.transport.wire")
    local fixture = load_fixture()

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

    local expected_explanation = vim.deepcopy(fixture.explanationStarted)
    local explanation = vim.deepcopy(expected_explanation)
    explanation.providerCredential = "envelope secret"
    explanation.event.providerCredential = "event secret"
    explanation.event.update.providerCredential = "explanation secret"
    assert_equal(expected_explanation, wire.decode_event(explanation))
  end)

  it("drives the exact shared transcript through the production transport", function()
    local transport = require("refine.transport")
    local fixture = load_fixture()
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
            version = 1,
            socketPath = "/private/tmp/refine-fixture/s",
            launchToken = fixture.hello.launchToken,
            serverEpoch = fixture.welcome.serverEpoch,
            protocolMajor = 1,
            protocolMinor = 0,
            pid = 123,
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

    local events = {}
    session:events(function(value)
      events[#events + 1] = value
    end, function(err)
      error(err or "unexpected end")
    end)
    local function send(message)
      session:send(message.command, message.id, function(err)
        assert_equal(nil, err)
      end)
      assert_equal(message, sent[#sent])
    end

    send(fixture.openDocument)
    receive(fixture.documentAccepted)
    send(fixture.updateAttention)
    send(fixture.selectionCheck)
    receive(fixture.checkingPresentation)
    receive(fixture.presentation)
    send(fixture.performExplain)
    receive(fixture.explanationStarted)
    send(fixture.performReport)
    receive(fixture.reportCompleted)
    send(fixture.performApply)
    receive(fixture.applyRequested)
    send(fixture.completeApply)
    receive(fixture.applyCompleted)
    send(fixture.closeDocument)
    assert_equal({
      fixture.documentAccepted,
      fixture.checkingPresentation,
      fixture.presentation,
      fixture.explanationStarted,
      fixture.reportCompleted,
      fixture.applyRequested,
      fixture.applyCompleted,
    }, events)
    session:close()
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
