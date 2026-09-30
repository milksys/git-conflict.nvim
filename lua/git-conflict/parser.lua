-----------------------------------------------------------------------------//
-- Conflict marker parser
-----------------------------------------------------------------------------//
local M = {}

local MARKER_SIZE = 7

---Check whether `line` is a conflict marker made of `char`.
---Git writes exactly MARKER_SIZE characters followed by either the end of the line
---or a space and a label, so e.g. `<<<<<<<<<<` or `=========` are not markers.
---@param line string
---@param char string
---@return boolean
local function is_marker(line, char)
  if line:sub(1, MARKER_SIZE) ~= char:rep(MARKER_SIZE) then return false end
  local next_char = line:sub(MARKER_SIZE + 1, MARKER_SIZE + 1)
  return next_char == '' or next_char == ' ' or next_char == '\r'
end

M.is_marker = is_marker

---Iterate through the lines checking for conflict markers and collect the position of each
---complete conflict. Positions are 0-based line numbers.
---Unterminated conflicts are discarded and markers that are out of place (e.g. a `=======`
---inside the incoming section) are treated as regular content.
---@param lines string[]
---@return ConflictPosition[]
function M.detect(lines)
  local positions = {}
  ---@type ConflictPosition?
  local position
  ---@type "'current'"|"'ancestor'"|"'incoming'"|nil
  local section

  for index, line in ipairs(lines) do
    local lnum = index - 1
    if is_marker(line, '<') then
      -- A new start marker discards any unfinished conflict
      position = {
        current = { range_start = lnum, content_start = lnum + 1 },
        middle = {},
        incoming = {},
        ancestor = {},
      }
      section = 'current'
    elseif position and section == 'current' and is_marker(line, '|') then
      position.current.range_end = lnum - 1
      position.current.content_end = lnum - 1
      position.ancestor.range_start = lnum
      position.ancestor.content_start = lnum + 1
      section = 'ancestor'
    elseif
      position
      and (section == 'current' or section == 'ancestor')
      and is_marker(line, '=')
    then
      local prev = position[section]
      prev.range_end = lnum - 1
      prev.content_end = lnum - 1
      position.middle.range_start = lnum
      position.middle.range_end = lnum + 1
      position.incoming.range_start = lnum + 1
      position.incoming.content_start = lnum + 1
      section = 'incoming'
    elseif position and section == 'incoming' and is_marker(line, '>') then
      position.incoming.range_end = lnum
      position.incoming.content_end = lnum - 1
      positions[#positions + 1] = position
      position, section = nil, nil
    end
  end
  return positions
end

return M
