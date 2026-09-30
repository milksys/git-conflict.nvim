-----------------------------------------------------------------------------//
-- Pick a conflict from every conflicted file
-----------------------------------------------------------------------------//
local M = {}

local api = vim.api
local fn = vim.fn
local fmt = string.format
local utils = require('git-conflict.utils')
local git = require('git-conflict.git')

local TITLE = 'Git Conflicts'

---@class GitConflictPickerItem
---@field filename string absolute path
---@field lnum integer 1-based line of the start of the conflict
---@field col integer
---@field text string description of the conflict

---@param path string
---@return string[]
local function file_lines(path)
  for _, bufnr in ipairs(api.nvim_list_bufs()) do
    local name = api.nvim_buf_get_name(bufnr)
    if api.nvim_buf_is_loaded(bufnr) and name ~= '' and git.normalize(name) == path then
      return api.nvim_buf_get_lines(bufnr, 0, -1, false)
    end
  end
  return fn.filereadable(path) == 1 and fn.readfile(path) or {}
end

---The label git writes after a marker e.g. `HEAD` in `<<<<<<< HEAD`
---@param line string?
---@return string
local function marker_label(line)
  local label = vim.trim(((line or ''):gsub('^[<>]+', '')))
  return label ~= '' and label or '?'
end

---One item per conflict in every conflicted file
---@return GitConflictPickerItem[]
function M.items()
  local git_conflict = require('git-conflict')
  local internal = git_conflict._internal
  local items = {}
  for _, path in ipairs(git_conflict.conflicted_files()) do
    local positions = internal.file_positions(path)
    local lines = #positions > 0 and file_lines(path) or {}
    for i, pos in ipairs(positions) do
      local current = marker_label(lines[pos.current.range_start + 1])
      local incoming = marker_label(lines[pos.incoming.range_end + 1])
      table.insert(items, {
        filename = path,
        lnum = pos.current.range_start + 1,
        col = 1,
        text = fmt('conflict %d/%d: %s <-> %s', i, #positions, current, incoming),
      })
    end
    if #positions == 0 then
      table.insert(items, { filename = path, lnum = 1, col = 1, text = 'conflicted file' })
    end
  end
  return items
end

---@param item GitConflictPickerItem
local function jump(item)
  vim.cmd.edit(fn.fnameescape(item.filename))
  pcall(api.nvim_win_set_cursor, 0, { item.lnum, 0 })
end

---@param items GitConflictPickerItem[]
local function pick_snacks(items)
  local snacks_items = vim.tbl_map(
    function(item)
      return {
        text = fn.fnamemodify(item.filename, ':~:.') .. ' ' .. item.text,
        file = item.filename,
        pos = { item.lnum, 0 },
        line = item.text,
      }
    end,
    items
  )
  require('snacks').picker.pick({
    title = TITLE,
    items = snacks_items,
    format = 'file',
    preview = 'file',
  })
end

---@param items GitConflictPickerItem[]
local function pick_telescope(items)
  local pickers = require('telescope.pickers')
  local finders = require('telescope.finders')
  local make_entry = require('telescope.make_entry')
  local conf = require('telescope.config').values
  pickers
    .new({}, {
      prompt_title = TITLE,
      finder = finders.new_table({ results = items, entry_maker = make_entry.gen_from_quickfix() }),
      previewer = conf.qflist_previewer({}),
      sorter = conf.generic_sorter({}),
    })
    :find()
end

---fzf-lua picks from the quickfix list, a new list is pushed so the user's list is kept
---@param items GitConflictPickerItem[]
local function pick_fzf_lua(items)
  fn.setqflist({}, ' ', { title = TITLE, items = items })
  require('fzf-lua').quickfix()
end

---@param items GitConflictPickerItem[]
local function pick_select(items)
  vim.ui.select(items, {
    prompt = TITLE,
    format_item = function(item)
      return fmt('%s:%d %s', fn.fnamemodify(item.filename, ':~:.'), item.lnum, item.text)
    end,
  }, function(item)
    if item then jump(item) end
  end)
end

local PICKERS = {
  snacks = { module = 'snacks', pick = pick_snacks },
  telescope = { module = 'telescope', pick = pick_telescope },
  ['fzf-lua'] = { module = 'fzf-lua', pick = pick_fzf_lua },
  select = { pick = pick_select },
}

---@param name string
---@return boolean
local function available(name)
  local picker = PICKERS[name]
  if not picker then return false end
  if not picker.module then return true end
  return package.loaded[picker.module] ~= nil or pcall(require, picker.module)
end

---@return GitConflictPicker
local function detect()
  for _, name in ipairs({ 'snacks', 'telescope', 'fzf-lua' }) do
    if available(name) then return name end
  end
  return 'select'
end

---@param name GitConflictPicker?
function M.pick(name)
  local items = M.items()
  if #items == 0 then return utils.notify('No conflicts found', 'info') end
  if name and not available(name) then
    utils.notify(fmt('Picker %s is not available, using vim.ui.select', name), 'warn')
    name = 'select'
  end
  PICKERS[name or detect()].pick(items)
end

return M
