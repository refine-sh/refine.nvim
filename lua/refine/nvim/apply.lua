local coordinates = require("refine.nvim.coordinates")

local M = {}

local function resume_insert_before_typeahead(command)
  vim.api.nvim_feedkeys(vim.keycode(command .. "<C-G>u"), "ni", false)
end

local function byte_range(text, range)
  return vim.str_byteindex(text, "utf-16", range.location, true),
    vim.str_byteindex(text, "utf-16", range.location + range.length, true)
end

local function replacement_lines(value)
  if value == "" then
    return {}
  end
  return vim.split(value, "\n", { plain = true })
end

local function visible_cursors(bufnr, index)
  local cursors = {}
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
      local cursor = vim.api.nvim_win_get_cursor(winid)
      local ok, offset = pcall(index.utf16_offset, index, cursor[1] - 1, cursor[2])
      if ok then
        cursors[#cursors + 1] = { winid = winid, offset = offset }
      end
    end
  end
  return cursors
end

local function mapped_offset(offset, edits)
  local delta = 0
  for index = #edits, 1, -1 do
    local edit = edits[index].edit
    local start = edit.range.location
    local finish = start + edit.range.length
    local replacement_length = vim.str_utfindex(edit.replacement, "utf-16", #edit.replacement, true)

    if offset < start then
      break
    elseif offset == finish then
      return start + delta + replacement_length
    elseif offset < finish then
      return start + delta + math.min(offset - start, replacement_length)
    else
      delta = delta + replacement_length - edit.range.length
    end
  end
  return offset + delta
end

local function restore_cursors(bufnr, cursors, prepared)
  local new_index = coordinates.new(vim.api.nvim_buf_get_lines(bufnr, 0, -1, true))
  local resume_command = "i"
  local current_win = vim.api.nvim_get_current_win()
  for _, cursor in ipairs(cursors) do
    if vim.api.nvim_win_is_valid(cursor.winid) and vim.api.nvim_win_get_buf(cursor.winid) == bufnr then
      local ok, position = pcall(new_index.position, new_index, mapped_offset(cursor.offset, prepared))
      if ok then
        pcall(vim.api.nvim_win_set_cursor, cursor.winid, {
          position.row + 1,
          position.byte_col,
        })
        if cursor.winid == current_win then
          local line = vim.api.nvim_buf_get_lines(bufnr, position.row, position.row + 1, true)[1] or ""
          if position.byte_col == #line and #line > 0 then
            resume_command = "a"
          end
        end
      end
    end
  end
  return resume_command
end

function M.apply(source, request)
  local bufnr = source.bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return { status = "unavailable" }
  end
  local before = source:snapshot()

  if before.revision ~= request.expectedRevision then
    return { status = "rejected", reason = "staleRevision", snapshot = before }
  end
  if request.sourceId ~= "document" or type(request.edits) ~= "table" or #request.edits == 0 then
    return { status = "unavailable", snapshot = before }
  end
  if vim.bo[bufnr].buftype ~= "" or vim.bo[bufnr].binary then
    return { status = "unavailable", snapshot = before }
  end
  if not vim.bo[bufnr].modifiable or vim.bo[bufnr].readonly then
    return { status = "unsupported", reason = "readOnly", snapshot = before }
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
  local index = coordinates.new(lines)
  local text = before.sources[1].text
  local previous_location = math.huge
  local envelope_start = math.huge
  local envelope_finish = -1
  local prepared = {}

  for _, edit in ipairs(request.edits) do
    if type(edit) ~= "table" or type(edit.range) ~= "table" then
      return { status = "unavailable", snapshot = before }
    end
    local location = edit.range.location
    local length = edit.range.length
    if
      type(location) ~= "number"
      or type(length) ~= "number"
      or type(edit.expectedText) ~= "string"
      or type(edit.replacement) ~= "string"
      or location < 0
      or length < 0
      or location >= previous_location
      or location + length > previous_location
      or edit.expectedText == edit.replacement
    then
      return { status = "unavailable", snapshot = before }
    end

    local ok, positions = pcall(index.range, index, edit.range)
    if not ok then
      return { status = "unavailable", snapshot = before }
    end
    local start_byte, finish_byte = byte_range(text, edit.range)
    if text:sub(start_byte + 1, finish_byte) ~= edit.expectedText then
      return { status = "rejected", reason = "textMismatch", snapshot = before }
    end

    prepared[#prepared + 1] = {
      edit = edit,
      positions = positions,
      start_byte = start_byte,
      finish_byte = finish_byte,
    }
    previous_location = location
    envelope_start = math.min(envelope_start, location)
    envelope_finish = math.max(envelope_finish, location + length)
  end

  local envelope_range = {
    location = envelope_start,
    length = envelope_finish - envelope_start,
  }
  local envelope_positions = index:range(envelope_range)
  local envelope_start_byte, envelope_finish_byte = byte_range(text, envelope_range)
  local replacement = text:sub(envelope_start_byte + 1, envelope_finish_byte)
  local expected_text = text
  local cursors = visible_cursors(bufnr, index)
  local insert_mode = vim.api.nvim_get_mode().mode:sub(1, 1) == "i"

  for _, item in ipairs(prepared) do
    local relative_start = item.start_byte - envelope_start_byte
    local relative_finish = item.finish_byte - envelope_start_byte
    replacement = replacement:sub(1, relative_start) .. item.edit.replacement .. replacement:sub(relative_finish + 1)
    expected_text = expected_text:sub(1, item.start_byte)
      .. item.edit.replacement
      .. expected_text:sub(item.finish_byte + 1)
  end

  local dispatched = false
  if insert_mode then
    vim.cmd.stopinsert()
  end
  local ok = pcall(function()
    dispatched = true
    vim.api.nvim_buf_set_text(
      bufnr,
      envelope_positions.start.row,
      envelope_positions.start.byte_col,
      envelope_positions.finish.row,
      envelope_positions.finish.byte_col,
      replacement_lines(replacement)
    )
  end)
  if not ok then
    if insert_mode then
      resume_insert_before_typeahead("i")
    end
    return dispatched and { status = "indeterminate", snapshot = source:snapshot() }
      or { status = "unavailable", snapshot = before }
  end

  local resume_command = restore_cursors(bufnr, cursors, prepared)
  if insert_mode then
    resume_insert_before_typeahead(resume_command)
  end

  local after = source:snapshot()
  if after.sources[1].text ~= expected_text then
    return { status = "indeterminate", snapshot = after }
  end

  return { status = "applied", snapshot = after }
end

return M
