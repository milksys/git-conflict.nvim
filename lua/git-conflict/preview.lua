-----------------------------------------------------------------------------//
-- Floating preview of the result of resolving a conflict
-----------------------------------------------------------------------------//
local M = {}

local api = vim.api
local fmt = string.format
local utils = require('git-conflict.utils')

local NAMESPACE = api.nvim_create_namespace('git-conflict-preview')
-- lines of surrounding context shown above and below the result
local CONTEXT = 3

local LABELS = {
  ours = 'ours',
  theirs = 'theirs',
  both = 'both (ours first)',
  both_reverse = 'both (theirs first)',
  base = 'base',
  none = 'none',
}

local FOOTER = ' <Tab> next  <S-Tab> prev  <CR> apply  q close '

---@param lines string[]
---@return integer
local function max_width(lines)
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  return width
end

function M.open()
  local internal = require('git-conflict')._internal
  local SIDES = internal.SIDES
  local hl = internal.HIGHLIGHTS

  local src_win, src_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
  local line = api.nvim_win_get_cursor(src_win)[1] - 1
  local position = internal.position_at(internal.get_positions(src_buf), line)
  if not position then return utils.notify('No conflict under the cursor', 'info') end

  local sides = { SIDES.OURS, SIDES.THEIRS, SIDES.BOTH, SIDES.BOTH_REVERSE }
  if internal.has_base(position) then table.insert(sides, SIDES.BASE) end
  table.insert(sides, SIDES.NONE)

  local first = position.current.range_start
  local last = position.incoming.range_end
  local before = api.nvim_buf_get_lines(src_buf, math.max(0, first - CONTEXT), first, false)
  local after = api.nvim_buf_get_lines(src_buf, last + 1, last + 1 + CONTEXT, false)
  local ours_count = #internal.side_lines(src_buf, position, SIDES.OURS)
  local theirs_count = #internal.side_lines(src_buf, position, SIDES.THEIRS)

  ---@type table<string, string[]>
  local results = {}
  local width, height = vim.fn.strdisplaywidth(FOOTER), 1
  for _, side in ipairs(sides) do
    results[side] = internal.side_lines(src_buf, position, side)
    width = math.max(width, max_width(results[side]))
    height = math.max(height, #before + #results[side] + #after)
  end
  width = math.max(width, max_width(before), max_width(after))

  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = vim.bo[src_buf].filetype
  local win = api.nvim_open_win(buf, true, {
    relative = 'cursor',
    row = 1,
    col = 0,
    width = math.max(1, math.min(width + 1, vim.o.columns - 4)),
    height = math.max(1, math.min(height, math.floor(vim.o.lines / 2))),
    style = 'minimal',
    border = 'rounded',
    title = '',
    title_pos = 'center',
    footer = FOOTER,
    footer_pos = 'center',
  })
  vim.wo[win].cursorline = false

  local index = 1

  ---The highlight of each result line, showing which side it came from
  ---@param side ConflictSide
  ---@param i integer 1-based index into the result
  ---@return string
  local function line_hl(side, i)
    if side == SIDES.OURS then return hl.current end
    if side == SIDES.THEIRS then return hl.incoming end
    if side == SIDES.BASE then return hl.ancestor end
    if side == SIDES.BOTH then return i <= ours_count and hl.current or hl.incoming end
    return i <= theirs_count and hl.incoming or hl.current
  end

  local function render()
    local side = sides[index]
    local result = results[side]
    local lines = vim.list_extend(vim.list_extend(vim.list_slice(before), result), after)
    vim.bo[buf].modifiable = true
    api.nvim_buf_set_lines(buf, 0, -1, false, #lines > 0 and lines or { '' })
    vim.bo[buf].modifiable = false
    api.nvim_buf_clear_namespace(buf, NAMESPACE, 0, -1)
    for i = 1, #result do
      api.nvim_buf_set_extmark(buf, NAMESPACE, #before + i - 1, 0, {
        line_hl_group = line_hl(side, i),
      })
    end
    if #result == 0 then
      local row = math.min(#before, math.max(#lines - 1, 0))
      api.nvim_buf_set_extmark(buf, NAMESPACE, row, 0, {
        virt_lines = { { { '(conflict removed)', 'Comment' } } },
        virt_lines_above = #before == 0 or #after > 0,
      })
    end
    api.nvim_win_set_config(win, {
      title = fmt(' %s (%d/%d) ', LABELS[side], index, #sides),
      title_pos = 'center',
    })
    api.nvim_win_set_cursor(win, { math.min(#before + 1, math.max(#lines, 1)), 0 })
  end

  local closed = false
  local function close()
    if closed then return end
    closed = true
    if api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
    if api.nvim_win_is_valid(src_win) then api.nvim_set_current_win(src_win) end
  end

  local function apply()
    local side = sides[index]
    close()
    -- look the conflict up again in case the buffer changed while the preview was open
    local current = internal.position_at(internal.get_positions(src_buf), line)
    if current then internal.resolve_all(src_buf, { current }, side) end
  end

  local function cycle(step)
    index = (index - 1 + step) % #sides + 1
    render()
  end

  local function bmap(lhs, rhs) vim.keymap.set('n', lhs, rhs, { buffer = buf, nowait = true }) end
  bmap('<Tab>', function() cycle(1) end)
  bmap('<S-Tab>', function() cycle(-1) end)
  bmap('<CR>', apply)
  bmap('q', close)
  bmap('<Esc>', close)
  api.nvim_create_autocmd('WinLeave', { buffer = buf, once = true, callback = close })

  render()
  return win
end

return M
