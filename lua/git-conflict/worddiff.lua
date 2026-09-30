-----------------------------------------------------------------------------//
-- Word level diff between the two sides of a conflict
-----------------------------------------------------------------------------//
local M = {}

-- vim.diff was renamed to vim.text.diff in 0.11
local diff = vim.text.diff or vim.diff

---@class WordDiffRange
---@field line integer 1-based index into the lines passed in
---@field col_start integer 0-based byte offset
---@field col_end integer 0-based exclusive byte offset

---@param char string
---@return "'word'"|"'space'"|"'punct'"
local function char_class(char)
  -- bytes >= 0x80 are treated as word characters so multibyte characters are never split
  if char:match('[%w_\128-\255]') then return 'word' end
  if char:match('%s') then return 'space' end
  return 'punct'
end

---Split a line into words, runs of whitespace and single punctuation characters
---@param line string
---@return string[] tokens
---@return integer[] offsets 0-based byte offset of each token
local function tokenize(line)
  local tokens, offsets = {}, {}
  local i, len = 1, #line
  while i <= len do
    local class = char_class(line:sub(i, i))
    local j = i
    if class ~= 'punct' then
      while j < len and char_class(line:sub(j + 1, j + 1)) == class do
        j = j + 1
      end
    end
    tokens[#tokens + 1] = line:sub(i, j)
    offsets[#offsets + 1] = i - 1
    i = j + 1
  end
  return tokens, offsets
end

---@param tokens string[]
---@return string
local function join(tokens) return #tokens > 0 and table.concat(tokens, '\n') .. '\n' or '' end

---Add the byte range of tokens [first, last] to `ranges`, merging it with the previous range when
---only whitespace separates them
---@param ranges WordDiffRange[]
---@param line_idx integer
---@param line string
---@param tokens string[]
---@param offsets integer[]
---@param first integer
---@param last integer
local function add_range(ranges, line_idx, line, tokens, offsets, first, last)
  local col_start = offsets[first]
  local col_end = offsets[last] + #tokens[last]
  local prev = ranges[#ranges]
  if prev and prev.line == line_idx and line:sub(prev.col_end + 1, col_start):match('^%s*$') then
    prev.col_end = col_end
    return
  end
  ranges[#ranges + 1] = { line = line_idx, col_start = col_start, col_end = col_end }
end

---Diff two lines token by token
---@return WordDiffRange[] a_ranges, WordDiffRange[] b_ranges
local function diff_line(a_idx, a, b_idx, b, a_ranges, b_ranges)
  local a_tokens, a_offsets = tokenize(a)
  local b_tokens, b_offsets = tokenize(b)
  if #a_tokens == 0 or #b_tokens == 0 then return end
  local hunks = diff(join(a_tokens), join(b_tokens), { result_type = 'indices' }) --[[@as integer[][] ]]
  -- If no words are shared then highlighting individual words adds nothing
  local changed = {}
  for _, h in ipairs(hunks) do
    for i = h[1], h[1] + h[2] - 1 do
      changed[i] = true
    end
  end
  local shares_word = false
  for i, token in ipairs(a_tokens) do
    if not changed[i] and token:match('%S') then
      shares_word = true
      break
    end
  end
  if not shares_word then return end

  for _, h in ipairs(hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    if ca > 0 then add_range(a_ranges, a_idx, a, a_tokens, a_offsets, sa, sa + ca - 1) end
    if cb > 0 then add_range(b_ranges, b_idx, b, b_tokens, b_offsets, sb, sb + cb - 1) end
  end
end

---Find the words that differ between lines `a` and `b`. Only lines that were changed (rather
---than added or removed) are compared since added lines are already obvious.
---@param a string[]
---@param b string[]
---@return WordDiffRange[] a_ranges
---@return WordDiffRange[] b_ranges
function M.compute(a, b)
  local a_ranges, b_ranges = {}, {}
  if #a == 0 or #b == 0 then return a_ranges, b_ranges end
  local hunks = diff(join(a), join(b), { result_type = 'indices', algorithm = 'histogram' }) --[[@as integer[][] ]]
  for _, h in ipairs(hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    for k = 0, math.min(ca, cb) - 1 do
      diff_line(sa + k, a[sa + k], sb + k, b[sb + k], a_ranges, b_ranges)
    end
  end
  return a_ranges, b_ranges
end

return M
