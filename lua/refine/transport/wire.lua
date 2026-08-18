local errors = require("refine.transport.errors")

local M = {
  PROTOCOL_MAJOR = 1,
  PROTOCOL_MINOR = 0,
  MAX_FRAME_BYTES = 8 * 1024 * 1024,
  MAX_SOURCES = 2,
  MAX_SOURCE_BYTES = 1024 * 1024,
  MAX_CAPABILITIES = 64,
  KNOWN_CAPABILITIES = {},
}

local MAX_SAFE_INTEGER = 9007199254740991

M.SUGGESTION_ACTION_KEYS = {
  "tab",
  "escape",
  "return",
  "space",
  "delete",
  "leftArrow",
  "rightArrow",
  "upArrow",
  "downArrow",
  "leftShift",
  "rightShift",
  "leftOption",
  "rightOption",
  "leftControl",
  "rightControl",
}

local suggestion_action_keys = {}
for _, value in ipairs(M.SUGGESTION_ACTION_KEYS) do
  suggestion_action_keys[value] = true
end

local action_kinds = { apply = true, dismiss = true, explain = true, report = true }
local action_rejections = {
  stale = true,
  disconnected = true,
  engineUnavailable = true,
  validationUnavailable = true,
  readOnly = true,
  nonAtomic = true,
  mutationUnavailable = true,
  mutationIndeterminate = true,
  applyNotProven = true,
  reportingUnavailable = true,
  unsupportedAction = true,
}
local unavailable_reasons = {
  disconnected = true,
  engineUnavailable = true,
  checkFailed = true,
  invalidDocument = true,
  unsupportedSource = true,
  resourceLimit = true,
  writingCheckEntitlementRequired = true,
}
local source_syntaxes = {
  plainText = true,
  markdownDocument = true,
  latexDocument = true,
  markdownDocumentHardLineBreaks = true,
}
local action_unavailable_reasons = {
  disconnected = true,
  engineUnavailable = true,
  validationUnavailable = true,
  readOnly = true,
  nonAtomic = true,
  mutationUnavailable = true,
  mutationIndeterminate = true,
  applyNotProven = true,
  reportingUnavailable = true,
}
local fault_severities = {
  invalidSequence = { [true] = true },
  malformedMessage = { [false] = true, [true] = true },
  resourceLimit = { [false] = true, [true] = true },
  internalError = { [false] = true, [true] = true },
  invalidDocument = { [false] = true },
  unsupportedSource = { [false] = true },
  engineUnavailable = { [false] = true },
}

local function fail(message)
  errors.raise("TransportProtocolError", message, "fatal", nil, 3)
end

local function is_integer(value)
  return type(value) == "number" and value == math.floor(value)
end

local function is_uint16(value)
  return is_integer(value) and value >= 0 and value <= 0xffff
end

local function is_uint32(value)
  return is_integer(value) and value >= 0 and value <= 0xffffffff
end

local function record(value, label)
  if type(value) ~= "table" or vim.islist(value) then
    fail(label .. " must be an object")
  end
  return value
end

local function list(value, label)
  if type(value) ~= "table" or not vim.islist(value) then
    fail(label .. " must be an array")
  end
  return value
end

local function nonempty_string(value, label)
  if type(value) ~= "string" or value == "" then
    fail(label .. " must be a nonempty string")
  end
  return value
end

local function identifier(value, label)
  if type(value) ~= "string" or #value == 0 or #value > 128 or value:find("[^!-~]") then
    fail(label .. " must be a 1-to-128-byte visible ASCII identifier")
  end
  return value
end

function M.validate_identifier(value, label)
  return identifier(value, label or "identifier")
end

local function required_keys(value, expected, label)
  for _, key in ipairs(expected) do
    if value[key] == nil then
      fail(label .. " is missing " .. key)
    end
  end
end

local function string_list(value, label, require_unique)
  local seen = {}
  for _, item in ipairs(list(value, label)) do
    if type(item) ~= "string" then
      fail(label .. " must contain only strings")
    end
    if require_unique and seen[item] then
      fail(label .. " must not contain duplicates")
    end
    seen[item] = true
  end
  return value
end

local function capability_list(value, label, enforce_limit)
  value = string_list(value, label, true)
  if enforce_limit ~= false and #value > M.MAX_CAPABILITIES then
    fail(label .. " must contain at most 64 entries")
  end
  for _, capability in ipairs(value) do
    identifier(capability, label .. " item")
  end
  return value
end

local function value_set(values)
  local result = {}
  for _, value in ipairs(values) do
    result[value] = true
  end
  return result
end

function M.capability_offers(value, known_capabilities)
  local offers = capability_list(value, "hello.capabilities")
  local known = value_set(capability_list(known_capabilities or M.KNOWN_CAPABILITIES, "known capabilities", false))
  local result = {}
  for _, capability in ipairs(offers) do
    if known[capability] then
      result[#result + 1] = capability
    end
  end
  return result
end

local function range(value, label, require_nonempty)
  value = record(value, label)
  if
    not is_integer(value.location)
    or not is_integer(value.length)
    or value.location < 0
    or value.length < 0
    or value.location > MAX_SAFE_INTEGER
    or value.length > MAX_SAFE_INTEGER
    or value.location > MAX_SAFE_INTEGER - value.length
  then
    fail(label .. " coordinates must be nonnegative integers")
  end
  if require_nonempty and value.length == 0 then
    fail(label .. " must be nonempty")
  end
  return { location = value.location, length = value.length }
end

local function snapshot(value, label)
  value = record(value, label)
  identifier(value.revision, label .. ".revision")
  local sources = list(value.sources, label .. ".sources")
  if #sources == 0 or #sources > M.MAX_SOURCES then
    fail(label .. " must contain between one and two sources")
  end
  local ids = {}
  for _, source in ipairs(sources) do
    source = record(source, label .. ".source")
    local source_id = identifier(source.sourceId, label .. ".sourceId")
    if ids[source_id] then
      fail(label .. " source IDs must be unique")
    end
    ids[source_id] = true
    if type(source.text) ~= "string" then
      fail(label .. ".text must be a string")
    end
    if #source.text > M.MAX_SOURCE_BYTES then
      fail(label .. ".text must be at most 1048576 UTF-8 bytes")
    end
    if not source_syntaxes[source.sourceSyntax] then
      fail(label .. ".sourceSyntax is unsupported")
    end
  end
  return value
end

local function check_intent(value)
  value = record(value, "check intent")
  if value.forcedLanguageTag ~= nil then
    identifier(value.forcedLanguageTag, "intent.forcedLanguageTag")
  end
  if value.sourceIds ~= nil and value.selection ~= nil then
    fail("check intent selection and sourceIds are mutually exclusive")
  end
  if value.sourceIds ~= nil then
    local ids = string_list(value.sourceIds, "intent.sourceIds", true)
    if #ids == 0 then
      fail("intent.sourceIds must be nonempty")
    end
    if #ids > M.MAX_SOURCES then
      fail("intent.sourceIds must contain at most 2 entries")
    end
    for _, id in ipairs(ids) do
      identifier(id, "intent.sourceIds item")
    end
  end
  if value.selection ~= nil then
    local selection = record(value.selection, "intent.selection")
    identifier(selection.sourceId, "intent.selection.sourceId")
    range(selection.range, "intent.selection.range", true)
  end
  return value
end

local function writing_attention(value)
  value = record(value, "writing attention")
  identifier(value.sourceId, "writing attention.sourceId")
  if value.caretOffset ~= nil and (not is_integer(value.caretOffset) or value.caretOffset < 0) then
    fail("writing attention.caretOffset must be a nonnegative integer")
  end
  local ranges = list(value.visibleRanges, "writing attention.visibleRanges")
  local previous_end = 0
  for index, item in ipairs(ranges) do
    local visible = range(item, "writing attention.visibleRanges item", true)
    if index > 1 and visible.location < previous_end then
      fail("writing attention.visibleRanges must be ordered and non-overlapping")
    end
    previous_end = visible.location + visible.length
  end
  return value
end

local function apply_outcome(value)
  value = record(value, "Apply outcome")
  if value.status == "applied" then
    if value.reason ~= nil then
      fail("malformed applied Apply outcome")
    end
    snapshot(value.snapshot, "Apply outcome snapshot")
  elseif value.status == "rejected" then
    if value.reason ~= "staleRevision" and value.reason ~= "textMismatch" then
      fail("malformed rejected Apply outcome")
    end
    snapshot(value.snapshot, "Apply outcome snapshot")
  elseif value.status == "unsupported" then
    if value.reason ~= "readOnly" and value.reason ~= "nonAtomic" then
      fail("malformed unsupported Apply outcome")
    end
    if value.snapshot ~= nil then
      snapshot(value.snapshot, "Apply outcome snapshot")
    end
  elseif value.status == "unavailable" or value.status == "indeterminate" then
    if value.reason ~= nil then
      fail("malformed " .. value.status .. " Apply outcome")
    end
    if value.snapshot ~= nil then
      snapshot(value.snapshot, "Apply outcome snapshot")
    end
  else
    fail("malformed Apply outcome")
  end
  return value
end

function M.validate_command(value)
  value = record(value, "client command")
  if value.type == "openDocument" or value.type == "replaceDocument" then
    snapshot(value.snapshot, value.type .. ".snapshot")
  elseif value.type == "updateAttention" then
    identifier(value.revision, "updateAttention.revision")
    writing_attention(value.attention)
  elseif value.type == "requestCheck" then
    identifier(value.revision, "requestCheck.revision")
    if value.intent ~= nil then
      check_intent(value.intent)
    end
  elseif value.type == "performAction" then
    identifier(value.actionId, "performAction.actionId")
    if not action_kinds[value.kind] then
      fail("malformed performAction.kind")
    end
    local suggestion = record(value.suggestion, "performAction.suggestion")
    identifier(suggestion.id, "performAction.suggestion.id")
    identifier(suggestion.documentRevision, "performAction.suggestion.documentRevision")
  elseif value.type == "completeApply" then
    identifier(value.transactionId, "completeApply.transactionId")
    apply_outcome(value.outcome)
  elseif value.type ~= "closeDocument" then
    fail("unknown client command type")
  end
  return value
end

function M.validate_host_capabilities(value)
  value = record(value, "hostCapabilities")
  local keys = string_list(value.interceptableSuggestionActionKeys, "interceptableSuggestionActionKeys", true)
  for _, key in ipairs(keys) do
    if not suggestion_action_keys[key] then
      fail("unknown interceptable suggestion action key")
    end
  end
  return value
end

function M.decode_handshake(value, offered_capabilities, known_capabilities)
  value = record(value, "handshake response")
  if value.type == "rejected" then
    local protocol = record(value.protocol, "rejected.protocol")
    local recoveries = {
      incompatibleProtocol = { none = true },
      invalidClient = { none = true },
      runUnavailable = { newRun = true, retry = true },
      serverBusy = { retry = true },
      engineUnavailable = { retry = true },
    }
    if
      not is_uint16(protocol.major)
      or not is_uint16(protocol.minor)
      or protocol.major ~= M.PROTOCOL_MAJOR
      or protocol.minor ~= M.PROTOCOL_MINOR
      or not recoveries[value.reason]
      or not recoveries[value.reason][value.recovery]
    then
      fail("malformed handshake rejection")
    end
    local rejection = {
      type = "rejected",
      reason = value.reason,
      recovery = value.recovery,
      protocol = { major = protocol.major, minor = protocol.minor },
    }
    if value.reason == "incompatibleProtocol" then
      local received = record(value.receivedProtocol, "rejected.receivedProtocol")
      if not is_uint16(received.major) or not is_uint16(received.minor) then
        fail("malformed handshake rejection")
      end
      rejection.receivedProtocol = { major = received.major, minor = received.minor }
    elseif value.receivedProtocol ~= nil then
      fail("malformed handshake rejection")
    end
    return rejection
  end
  if value.type ~= "welcome" then
    fail("unknown handshake response")
  end
  local protocol = record(value.protocol, "welcome.protocol")
  if not is_uint16(protocol.major) or not is_uint16(protocol.minor) then
    fail("malformed welcome protocol version")
  end
  if protocol.major ~= M.PROTOCOL_MAJOR or protocol.minor ~= M.PROTOCOL_MINOR then
    errors.raise(
      "IncompatibleProtocolError",
      ("Refine protocol %d.%d is incompatible with protocol %d.%d"):format(
        protocol.major,
        protocol.minor,
        M.PROTOCOL_MAJOR,
        M.PROTOCOL_MINOR
      ),
      "fatal",
      {
        received_protocol = protocol,
        supported_protocol = { major = M.PROTOCOL_MAJOR, minor = M.PROTOCOL_MINOR },
      },
      2
    )
  end
  local limits = record(value.limits, "welcome.limits")
  identifier(value.serverEpoch, "welcome.serverEpoch")
  if
    type(value.runResumed) ~= "boolean"
    or limits.maxFrameBytes ~= M.MAX_FRAME_BYTES
    or limits.maxSources ~= M.MAX_SOURCES
    or limits.maxSourceBytes ~= M.MAX_SOURCE_BYTES
  then
    fail("malformed or incompatible welcome frame")
  end
  local activated = capability_list(value.capabilities, "welcome.capabilities")
  local offered = value_set(capability_list(offered_capabilities or {}, "offered capabilities"))
  local known = value_set(capability_list(known_capabilities or M.KNOWN_CAPABILITIES, "known capabilities", false))
  for _, capability in ipairs(activated) do
    if not known[capability] then
      fail("welcome.capabilities contains an unknown activation")
    end
    if not offered[capability] then
      fail("welcome.capabilities contains an unoffered activation")
    end
  end
  return {
    type = "welcome",
    protocol = { major = protocol.major, minor = protocol.minor },
    serverEpoch = value.serverEpoch,
    runResumed = value.runResumed,
    limits = {
      maxFrameBytes = limits.maxFrameBytes,
      maxSources = limits.maxSources,
      maxSourceBytes = limits.maxSourceBytes,
    },
    capabilities = vim.deepcopy(activated),
  }
end

local function appearance(value)
  value = record(value, "presentation.appearance")
  local highlight = record(value.highlight, "presentation.appearance.highlight")
  local diff = record(value.diff, "presentation.appearance.diff")
  required_keys(value, { "highlight", "diff" }, "presentation.appearance")
  required_keys(highlight, { "style", "grammarColor", "fluencyColor" }, "presentation.appearance.highlight")
  required_keys(diff, { "additionColor", "deletionColor", "showHiddenWhitespace" }, "presentation.appearance.diff")
  if highlight.style ~= "underline" and highlight.style ~= "dashedUnderline" and highlight.style ~= "highlight" then
    fail("malformed presentation highlight style")
  end
  for _, color in ipairs({ highlight.grammarColor, highlight.fluencyColor, diff.additionColor, diff.deletionColor }) do
    if type(color) ~= "string" or not color:match("^#[0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]$") then
      fail("presentation colors must use canonical #RRGGBB")
    end
  end
  if type(diff.showHiddenWhitespace) ~= "boolean" then
    fail("malformed presentation diff appearance")
  end
  return {
    highlight = {
      style = highlight.style,
      grammarColor = highlight.grammarColor,
      fluencyColor = highlight.fluencyColor,
    },
    diff = {
      additionColor = diff.additionColor,
      deletionColor = diff.deletionColor,
      showHiddenWhitespace = diff.showHiddenWhitespace,
    },
  }
end

local function interaction(value)
  value = record(value, "presentation.interaction")
  local quick = record(value.quickApply, "presentation.interaction.quickApply")
  required_keys(value, { "automaticChecksEnabled", "quickApply" }, "presentation.interaction")
  required_keys(
    quick,
    { "enabled", "applyKey", "dismissKey", "activationStyle" },
    "presentation.interaction.quickApply"
  )
  if type(value.automaticChecksEnabled) ~= "boolean" or type(quick.enabled) ~= "boolean" then
    fail("malformed presentation interaction")
  end
  if not suggestion_action_keys[quick.applyKey] or not suggestion_action_keys[quick.dismissKey] then
    fail("malformed presentation action key")
  end
  if quick.activationStyle ~= "highlightChanges" and quick.activationStyle ~= "showTipAndHighlight" then
    fail("malformed Quick Apply activation style")
  end
  return {
    automaticChecksEnabled = value.automaticChecksEnabled,
    quickApply = {
      enabled = quick.enabled,
      applyKey = quick.applyKey,
      dismissKey = quick.dismissKey,
      activationStyle = quick.activationStyle,
    },
  }
end

local function attribution(value, label, model_key)
  value = record(value, label)
  required_keys(value, { "languageDisplayName", "textDirection", model_key }, label)
  nonempty_string(value.languageDisplayName, label .. ".languageDisplayName")
  if value.textDirection ~= "ltr" and value.textDirection ~= "rtl" then
    fail(label .. ".textDirection must be ltr or rtl")
  end
  nonempty_string(value[model_key], label .. "." .. model_key)
  local decoded = {
    languageDisplayName = value.languageDisplayName,
    textDirection = value.textDirection,
  }
  decoded[model_key] = value[model_key]
  return decoded
end

local function suggestion(value)
  value = record(value, "presented suggestion")
  identifier(value.id, "suggestion.id")
  identifier(value.sourceId, "suggestion.sourceId")
  if value.kind ~= "grammar" and value.kind ~= "fluency" and value.kind ~= "mixed" then
    fail("malformed suggestion kind")
  end
  local decoded_attribution = attribution(value.attribution, "suggestion.attribution", "checkModelDisplayName")
  local activation_range = record(value.activationRange, "suggestion.activationRange")
  required_keys(activation_range, { "location", "length" }, "suggestion.activationRange")
  activation_range = range(activation_range, "suggestion.activationRange", false)
  local highlight_ranges = {}
  for _, item in ipairs(list(value.highlightRanges, "suggestion.highlightRanges")) do
    highlight_ranges[#highlight_ranges + 1] = range(item, "suggestion.highlightRange", false)
  end
  local diff = {}
  for _, run in ipairs(list(value.diff, "suggestion.diff")) do
    run = record(run, "diff run")
    if run.kind ~= "unchanged" and run.kind ~= "delete" and run.kind ~= "insert" then
      fail("malformed diff run kind")
    end
    if type(run.text) ~= "string" then
      fail("diff run text must be a string")
    end
    diff[#diff + 1] = { kind = run.kind, text = run.text }
  end
  local seen_actions = {}
  local available_actions = {}
  for _, action in ipairs(list(value.availableActions, "suggestion.availableActions")) do
    if not action_kinds[action] or seen_actions[action] then
      fail("malformed or duplicate suggestion action")
    end
    seen_actions[action] = true
    available_actions[#available_actions + 1] = action
  end
  return {
    id = value.id,
    sourceId = value.sourceId,
    kind = value.kind,
    attribution = decoded_attribution,
    activationRange = activation_range,
    highlightRanges = highlight_ranges,
    diff = diff,
    availableActions = available_actions,
  }
end

local function presentation_content(value)
  value = record(value, "presentation content")
  identifier(value.documentRevision, "presentation.documentRevision")
  local decoded_appearance = appearance(value.appearance)
  local decoded_interaction = interaction(value.interaction)
  local suggestions = list(value.suggestions, "presentation.suggestions")
  local decoded_suggestions = {}
  for _, item in ipairs(suggestions) do
    decoded_suggestions[#decoded_suggestions + 1] = suggestion(item)
  end
  local decoded_progress
  if value.status == "checking" then
    if value.coverage ~= nil or value.unavailableReason ~= nil then
      fail("checking presentation cannot contain coverage or unavailableReason")
    end
    if value.progress ~= nil then
      local progress = record(value.progress, "presentation.progress")
      required_keys(progress, { "completedUnitCount", "totalUnitCount" }, "presentation.progress")
      if
        not is_integer(progress.completedUnitCount)
        or not is_integer(progress.totalUnitCount)
        or progress.completedUnitCount < 0
        or progress.totalUnitCount < 0
        or progress.completedUnitCount > progress.totalUnitCount
      then
        fail("malformed presentation progress")
      end
      decoded_progress = {
        completedUnitCount = progress.completedUnitCount,
        totalUnitCount = progress.totalUnitCount,
      }
    end
  elseif value.status == "complete" then
    if value.coverage ~= "full" and value.coverage ~= "partial" then
      fail("complete presentation requires coverage")
    end
    if value.unavailableReason ~= nil or value.progress ~= nil then
      fail("complete presentation cannot contain unavailableReason or progress")
    end
  elseif value.status == "unavailable" then
    if not unavailable_reasons[value.unavailableReason] then
      fail("unavailable presentation requires unavailableReason")
    end
    if value.coverage ~= nil or value.progress ~= nil then
      fail("unavailable presentation cannot contain coverage or progress")
    end
  elseif value.status == "pending" or value.status == "closed" then
    if value.coverage ~= nil or value.unavailableReason ~= nil or value.progress ~= nil then
      fail(value.status .. " presentation cannot contain coverage, unavailableReason, or progress")
    end
  elseif value.status ~= "pending" and value.status ~= "closed" then
    fail("malformed presentation status")
  end
  if (value.status == "pending" or value.status == "unavailable" or value.status == "closed") and #suggestions ~= 0 then
    fail(value.status .. " presentation cannot contain suggestions")
  end
  local decoded = {
    documentRevision = value.documentRevision,
    status = value.status,
    appearance = decoded_appearance,
    interaction = decoded_interaction,
    suggestions = decoded_suggestions,
  }
  if decoded_progress ~= nil then
    decoded.progress = decoded_progress
  end
  if value.status == "complete" then
    decoded.coverage = value.coverage
  elseif value.status == "unavailable" then
    decoded.unavailableReason = value.unavailableReason
  end
  return decoded
end

local function apply_request(value)
  value = record(value, "apply request")
  identifier(value.expectedRevision, "apply.expectedRevision")
  identifier(value.sourceId, "apply.sourceId")
  local edits = list(value.edits, "apply.edits")
  if #edits == 0 then
    fail("Apply request requires edits")
  end
  local decoded_edits = {}
  local next_higher_start = math.huge
  for _, edit in ipairs(edits) do
    edit = record(edit, "host edit")
    local decoded_range = range(edit.range, "host edit range", false)
    if type(edit.expectedText) ~= "string" or type(edit.replacement) ~= "string" then
      fail("malformed host edit")
    end
    if decoded_range.location + decoded_range.length > next_higher_start then
      fail("Apply edits must be descending, untied, and non-overlapping")
    end
    if decoded_range.location == next_higher_start then
      fail("Apply edits must be descending, untied, and non-overlapping")
    end
    if edit.expectedText == edit.replacement then
      fail("Apply edits must change text")
    end
    next_higher_start = decoded_range.location
    decoded_edits[#decoded_edits + 1] = {
      range = decoded_range,
      expectedText = edit.expectedText,
      replacement = edit.replacement,
    }
  end
  return {
    expectedRevision = value.expectedRevision,
    sourceId = value.sourceId,
    edits = decoded_edits,
  }
end

local function explanation_update(value)
  value = record(value, "explanation update")
  if value.status == "started" then
    return {
      status = "started",
      attribution = attribution(value.attribution, "explanation attribution", "modelDisplayName"),
    }
  elseif value.status == "streaming" or value.status == "completed" then
    if type(value.text) ~= "string" then
      fail("explanation text must be a string")
    end
    return { status = value.status, text = value.text }
  elseif value.status == "unavailable" then
    if not action_unavailable_reasons[value.reason] then
      fail("malformed explanation unavailable reason")
    end
    return { status = "unavailable", reason = value.reason }
  elseif value.status ~= "stale" then
    fail("malformed explanation update")
  end
  return { status = "stale" }
end

local function server_event(value)
  value = record(value, "server event")
  if value.type == "documentAccepted" then
    identifier(value.revision, "documentAccepted.revision")
    return { type = "documentAccepted", revision = value.revision }
  elseif value.type == "resyncRequired" then
    if
      value.reason ~= "documentNotOpen"
      and value.reason ~= "conflictingRevision"
      and value.reason ~= "reusedRevision"
      and value.reason ~= "invalidDocument"
    then
      fail("malformed resyncRequired.reason")
    end
    return { type = "resyncRequired", reason = value.reason }
  elseif value.type == "presentationContentReplaced" then
    identifier(value.checkId, "presentationContentReplaced.checkId")
    return {
      type = "presentationContentReplaced",
      checkId = value.checkId,
      content = presentation_content(value.content),
    }
  elseif value.type == "applyRequested" then
    identifier(value.actionId, "applyRequested.actionId")
    identifier(value.transactionId, "applyRequested.transactionId")
    return {
      type = "applyRequested",
      actionId = value.actionId,
      transactionId = value.transactionId,
      request = apply_request(value.request),
    }
  elseif value.type == "explanationReplaced" then
    identifier(value.actionId, "explanationReplaced.actionId")
    return {
      type = "explanationReplaced",
      actionId = value.actionId,
      update = explanation_update(value.update),
    }
  elseif value.type == "actionCompleted" then
    identifier(value.actionId, "actionCompleted.actionId")
    return { type = "actionCompleted", actionId = value.actionId }
  elseif value.type == "actionRejected" then
    identifier(value.actionId, "actionRejected.actionId")
    if not action_rejections[value.reason] then
      fail("malformed actionRejected.reason")
    end
    return { type = "actionRejected", actionId = value.actionId, reason = value.reason }
  elseif value.type == "fault" then
    if
      type(value.fatal) ~= "boolean"
      or not fault_severities[value.code]
      or not fault_severities[value.code][value.fatal]
    then
      fail("malformed fault code and severity")
    end
    return { type = "fault", code = value.code, fatal = value.fatal }
  else
    fail("unknown server event type")
  end
end

function M.decode_event(value)
  value = record(value, "event envelope")
  if value.type ~= "event" or not is_uint32(value.sequence) or value.sequence == 0 then
    fail("malformed server event envelope")
  end
  identifier(value.epoch, "event.epoch")
  if value.causeCommandId ~= nil then
    identifier(value.causeCommandId, "event.causeCommandId")
  end
  local decoded = {
    type = "event",
    sequence = value.sequence,
    epoch = value.epoch,
    event = server_event(value.event),
  }
  if value.causeCommandId ~= nil then
    decoded.causeCommandId = value.causeCommandId
  end
  return decoded
end

M.validate_snapshot = snapshot
M.validate_check_intent = check_intent

return M
