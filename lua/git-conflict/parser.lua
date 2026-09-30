-----------------------------------------------------------------------------//
-- Conflict marker parser
-----------------------------------------------------------------------------//
local M = {}

-- Git's default marker size, it can be changed with the `conflict-marker-size` attribute
M.DEFAULT_MARKER_SIZE = 7

---Check whether `line` is a conflict marker made of exactly `size` times `char` followed by
---either the end of the line or a space and a label, so e.g. `<<<<<<<<<<` is not a marker
---@param line string
---@param char string
---@param size integer
---@return boolean
local function is_marker(line, char, size)
  if line:sub(1, size) ~= char:rep(size) then return false end
  local next_char = line:sub(size + 1, size + 1)
  return next_char == '' or next_char == ' ' or next_char == '\r'
end

M.is_marker = is_marker

---Iterate through the lines checking for conflict markers and collect the position of each
---complete conflict. Positions are 0-based line numbers.
---Unterminated conflicts are discarded and markers that are out of place (e.g. a `=======`
---inside the incoming section) are treated as regular content.
---@param lines string[]
---@param size integer? marker size, see the `conflict-marker-size` git attribute
---@return ConflictPosition[]
function M.detect(lines, size)
  size = size or M.DEFAULT_MARKER_SIZE
  local positions = {}
  ---@type ConflictPosition?
  local position
  ---@type "'current'"|"'ancestor'"|"'incoming'"|nil
  local section

  for index, line in ipairs(lines) do
    local lnum = index - 1
    if is_marker(line, '<', size) then
      -- A new start marker discards any unfinished conflict
      position = {
        current = { range_start = lnum, content_start = lnum + 1 },
        middle = {},
        incoming = {},
        ancestor = {},
      }
      section = 'current'
    elseif position and section == 'current' and is_marker(line, '|', size) then
      position.current.range_end = lnum - 1
      position.current.content_end = lnum - 1
      position.ancestor.range_start = lnum
      position.ancestor.content_start = lnum + 1
      section = 'ancestor'
    elseif
      position
      and (section == 'current' or section == 'ancestor')
      and is_marker(line, '=', size)
    then
      local prev = position[section]
      prev.range_end = lnum - 1
      prev.content_end = lnum - 1
      position.middle.range_start = lnum
      position.middle.range_end = lnum + 1
      position.incoming.range_start = lnum + 1
      position.incoming.content_start = lnum + 1
      section = 'incoming'
    elseif position and section == 'incoming' and is_marker(line, '>', size) then
      position.incoming.range_end = lnum
      position.incoming.content_end = lnum - 1
      positions[#positions + 1] = position
      position, section = nil, nil
    end
  end
  return positions
end

return M
