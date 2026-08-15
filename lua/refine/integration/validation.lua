local utf16 = require("refine.integration.utf16")

local M = {}

local function source_map(snapshot)
  local result = {}
  for _, source in ipairs(snapshot.sources) do
    result[source.sourceId] = source.text
  end
  return result
end

function M.check_intent(intent, snapshot)
  if not intent then
    return true
  end
  local sources = source_map(snapshot)
  if intent.sourceIds then
    for _, source_id in ipairs(intent.sourceIds) do
      if sources[source_id] == nil then
        return false, "check intent names an unknown source"
      end
    end
  end
  if intent.selection then
    local text = sources[intent.selection.sourceId]
    if text == nil then
      return false, "selection names an unknown source"
    end
    if not utf16.valid_range(text, intent.selection.range, true) then
      return false, "selection must be in bounds at composed-character UTF-16 boundaries"
    end
  end
  return true
end

function M.presentation(content, snapshot)
  local sources = source_map(snapshot)
  local source_boundaries = {}
  for source_id, text in pairs(sources) do
    local boundaries, length = utf16.boundaries(text)
    source_boundaries[source_id] = { boundaries = boundaries, length = length }
  end
  local suggestion_ids = {}
  for _, suggestion in ipairs(content.suggestions) do
    if suggestion_ids[suggestion.id] then
      return false, "presentation suggestion IDs must be unique"
    end
    suggestion_ids[suggestion.id] = true
    local text = sources[suggestion.sourceId]
    if text == nil then
      return false, "presentation suggestion names an unknown source"
    end
    local indexed = source_boundaries[suggestion.sourceId]
    if not utf16.range_at_boundaries(suggestion.activationRange, indexed.boundaries, indexed.length, false) then
      return false, "suggestion activation range is out of bounds or splits a composed character"
    end
    local previous_end = -1
    local zero_anchors = {}
    for _, highlight in ipairs(suggestion.highlightRanges) do
      if not utf16.range_at_boundaries(highlight, indexed.boundaries, indexed.length, false) then
        return false, "suggestion highlight range is out of bounds or splits a composed character"
      end
      if highlight.location < previous_end then
        return false, "suggestion highlight ranges must be sorted and non-overlapping"
      end
      if highlight.length == 0 then
        if zero_anchors[highlight.location] then
          return false, "duplicate insertion highlight anchors are forbidden"
        end
        zero_anchors[highlight.location] = true
      end
      previous_end = math.max(previous_end, highlight.location + highlight.length)
    end
  end
  return true
end

return M
