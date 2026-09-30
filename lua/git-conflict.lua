local M = {}

local color = require('git-conflict.colors')
local utils = require('git-conflict.utils')
local parser = require('git-conflict.parser')
local git = require('git-conflict.git')

local fn = vim.fn
local api = vim.api
local fmt = string.format
local map = vim.keymap.set
-----------------------------------------------------------------------------//
-- REFERENCES:
-----------------------------------------------------------------------------//
-- Detecting the state of a git repository based on files in the .git directory.
-- https://stackoverflow.com/questions/49774200/how-to-tell-if-my-git-repo-is-in-a-conflict
-- git diff commands to git a list of conflicted files
-- https://stackoverflow.com/questions/3065650/whats-the-simplest-way-to-list-conflicted-files-in-git
-- Advanced merging
-- https://git-scm.com/book/en/v2/Git-Tools-Advanced-Merging

-----------------------------------------------------------------------------//
-- Types
-----------------------------------------------------------------------------//

---@alias ConflictSide "'ours'"|"'theirs'"|"'both'"|"'base'"|"'none'"

--- @class ConflictHighlights
--- @field current string
--- @field incoming string
--- @field ancestor string?

--- @class Range
--- @field range_start integer
--- @field range_end integer
--- @field content_start integer
--- @field content_end integer

--- @class ConflictPosition
--- @field incoming Range
--- @field middle Range
--- @field current Range
--- @field ancestor Range|{}

--- @class ConflictBufferCache
--- @field root string root of the repository the file belongs to
--- @field positions ConflictPosition[]?
--- @field tick integer?
--- @field bufnr integer?
--- @field has_conflict boolean? whether the last parse found conflicts

--- @class GitConflictMappings
--- @field ours string
--- @field theirs string
--- @field none string
--- @field both string
--- @field next string
--- @field prev string

--- @class GitConflictConfig
--- @field default_mappings GitConflictMappings|false
--- @field default_commands boolean
--- @field disable_diagnostics boolean
--- @field list_opener string|function
--- @field highlights ConflictHighlights
--- @field debug boolean

--- @class GitConflictUserConfig
--- @field default_mappings? boolean|GitConflictMappings
--- @field default_commands? boolean
--- @field disable_diagnostics? boolean
--- @field list_opener? string|function
--- @field highlights? ConflictHighlights
--- @field debug? boolean

-----------------------------------------------------------------------------//
-- Constants
-----------------------------------------------------------------------------//
local SIDES = {
  OURS = 'ours',
  THEIRS = 'theirs',
  BOTH = 'both',
  BASE = 'base',
  NONE = 'none',
}

-- A mapping between the internal names and the display names
local name_map = {
  ours = 'current',
  theirs = 'incoming',
  base = 'ancestor',
  both = 'both',
  none = 'none',
}

local CURRENT_HL = 'GitConflictCurrent'
local INCOMING_HL = 'GitConflictIncoming'
local ANCESTOR_HL = 'GitConflictAncestor'
local CURRENT_LABEL_HL = 'GitConflictCurrentLabel'
local INCOMING_LABEL_HL = 'GitConflictIncomingLabel'
local ANCESTOR_LABEL_HL = 'GitConflictAncestorLabel'
local PRIORITY = vim.hl.priorities.user
local NAMESPACE = api.nvim_create_namespace('git-conflict')
local AUGROUP_NAME = 'GitConflictCommands'

-- Files in the git directory whose changes can mean the set of conflicted files changed
local GITDIR_EVENTS = {
  index = true,
  MERGE_HEAD = true,
  REBASE_HEAD = true,
  CHERRY_PICK_HEAD = true,
  REVERT_HEAD = true,
  AUTO_MERGE = true,
  ['rebase-merge'] = true,
  ['rebase-apply'] = true,
}
local WATCH_DEBOUNCE_MS = 200
local INSERT_DEBOUNCE_MS = 100

local DEFAULT_CURRENT_BG_COLOR = 4218238 -- #405d7e
local DEFAULT_INCOMING_BG_COLOR = 3229523 -- #314753
local DEFAULT_ANCESTOR_BG_COLOR = 6824314 -- #68217A
-----------------------------------------------------------------------------//

--- @type GitConflictMappings
local DEFAULT_MAPPINGS = {
  ours = 'co',
  theirs = 'ct',
  none = 'c0',
  both = 'cb',
  next = ']x',
  prev = '[x',
}

--- @type GitConflictConfig
local config = {
  debug = false,
  default_mappings = DEFAULT_MAPPINGS,
  default_commands = true,
  disable_diagnostics = false,
  list_opener = 'copen',
  highlights = {
    current = 'DiffText',
    incoming = 'DiffAdd',
    ancestor = nil,
  },
}

---@param bufnr integer
---@return string?
local function buf_path(bufnr)
  local name = api.nvim_buf_get_name(bufnr)
  if name == '' then return end
  return git.normalize(name)
end

--- Files that git reports as conflicted, keyed by their normalised absolute path.
--- Buffer numbers can also be used as keys.
--- @type table<string|integer, ConflictBufferCache>
local visited_buffers = setmetatable({}, {
  __index = function(t, k)
    if type(k) == 'number' then
      local path = buf_path(k == 0 and api.nvim_get_current_buf() or k)
      return path and rawget(t, path)
    end
  end,
})

---@class RepoWatcher
---@field root string
---@field gitdir string
---@field handle uv.uv_fs_event_t?
---@field refresh function
---@field close_timer function

--- Repositories being watched, keyed by work tree root
---@type table<string, RepoWatcher>
local repos = {}

-----------------------------------------------------------------------------//
-- Highlights
-----------------------------------------------------------------------------//

---Highlight the content lines of a section
---@param bufnr integer
---@param hl string
---@param range Range
local function hl_content(bufnr, hl, range)
  if not range.content_start or range.content_end < range.content_start then return end
  api.nvim_buf_set_extmark(bufnr, NAMESPACE, range.content_start, 0, {
    hl_group = hl,
    hl_eol = true,
    hl_mode = 'combine',
    end_row = range.content_end + 1,
    priority = PRIORITY,
  })
end

---Highlight a marker line across the full window width and append a description after it
---@param bufnr integer
---@param hl_group string
---@param lnum integer
---@param description string
local function draw_section_label(bufnr, hl_group, lnum, description)
  api.nvim_buf_set_extmark(bufnr, NAMESPACE, lnum, 0, {
    line_hl_group = hl_group,
    virt_text = { { description, hl_group } },
    virt_text_pos = 'eol',
    priority = PRIORITY,
  })
end

---Highlight each part of a git conflict i.e. the incoming changes vs the current/HEAD changes
---@param bufnr integer
---@param positions ConflictPosition[]
local function highlight_conflicts(bufnr, positions)
  M.clear(bufnr)
  for _, position in ipairs(positions) do
    draw_section_label(bufnr, CURRENT_LABEL_HL, position.current.range_start, '(Current changes)')
    hl_content(bufnr, CURRENT_HL, position.current)
    if not vim.tbl_isempty(position.ancestor) then
      draw_section_label(bufnr, ANCESTOR_LABEL_HL, position.ancestor.range_start, '(Base changes)')
      hl_content(bufnr, ANCESTOR_HL, position.ancestor)
    end
    hl_content(bufnr, INCOMING_HL, position.incoming)
    draw_section_label(bufnr, INCOMING_LABEL_HL, position.incoming.range_end, '(Incoming changes)')
  end
end

---Derive the colour of the section label highlights based on each sections highlights
---@param highlights ConflictHighlights
local function set_highlights(highlights)
  local current_bg = utils.get_hl(highlights.current).bg or DEFAULT_CURRENT_BG_COLOR
  local incoming_bg = utils.get_hl(highlights.incoming).bg or DEFAULT_INCOMING_BG_COLOR
  local ancestor_bg = utils.get_hl(highlights.ancestor).bg or DEFAULT_ANCESTOR_BG_COLOR
  local current_label_bg = color.shade_color(current_bg, 60)
  local incoming_label_bg = color.shade_color(incoming_bg, 60)
  local ancestor_label_bg = color.shade_color(ancestor_bg, 60)
  api.nvim_set_hl(0, CURRENT_HL, { background = current_bg, bold = true, default = true })
  api.nvim_set_hl(0, INCOMING_HL, { background = incoming_bg, bold = true, default = true })
  api.nvim_set_hl(0, ANCESTOR_HL, { background = ancestor_bg, bold = true, default = true })
  api.nvim_set_hl(0, CURRENT_LABEL_HL, { background = current_label_bg, default = true })
  api.nvim_set_hl(0, INCOMING_LABEL_HL, { background = incoming_label_bg, default = true })
  api.nvim_set_hl(0, ANCESTOR_LABEL_HL, { background = ancestor_label_bg, default = true })
end

-----------------------------------------------------------------------------//
-- Buffer state
-----------------------------------------------------------------------------//

---@param bufnr integer
---@param has_conflict boolean
local function fire_event(bufnr, has_conflict)
  local pattern = has_conflict and 'GitConflictDetected' or 'GitConflictResolved'
  api.nvim_exec_autocmds('User', { pattern = pattern, data = { bufnr = bufnr } })
end

---Mark a buffer as no longer conflicted
---@param bufnr integer?
---@param entry ConflictBufferCache
local function reset_buffer(bufnr, entry)
  if bufnr and api.nvim_buf_is_valid(bufnr) then
    M.clear(bufnr)
    if entry.has_conflict then fire_event(bufnr, false) end
  end
  entry.positions, entry.tick, entry.has_conflict = nil, nil, nil
end

---Parse the buffer for conflict markers, highlight them and fire events if the state changed
---@param bufnr integer
local function parse_buffer(bufnr)
  if bufnr == 0 then bufnr = api.nvim_get_current_buf() end
  local entry = visited_buffers[bufnr]
  if not entry or not api.nvim_buf_is_loaded(bufnr) or not utils.is_valid_buf(bufnr) then return end
  local positions = parser.detect(api.nvim_buf_get_lines(bufnr, 0, -1, false))
  local has_conflict = #positions > 0
  entry.bufnr = bufnr
  entry.tick = api.nvim_buf_get_changedtick(bufnr)
  entry.positions = positions

  if has_conflict then
    highlight_conflicts(bufnr, positions)
  else
    M.clear(bufnr)
  end
  local had_conflict = entry.has_conflict
  entry.has_conflict = has_conflict
  -- only notify on a state change, and don't report a buffer that was never conflicted as resolved
  if has_conflict ~= (had_conflict or false) then fire_event(bufnr, has_conflict) end
end

---Parse the buffer if it changed since it was last parsed
---@param bufnr integer?
local function process(bufnr)
  bufnr = (not bufnr or bufnr == 0) and api.nvim_get_current_buf() or bufnr
  local entry = visited_buffers[bufnr]
  if not entry then return end
  if entry.bufnr == bufnr and entry.tick == api.nvim_buf_get_changedtick(bufnr) then return end
  parse_buffer(bufnr)
end

---@param path string
---@return integer?
local function find_loaded_buf(path)
  for _, bufnr in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(bufnr) and buf_path(bufnr) == path then return bufnr end
  end
end

-----------------------------------------------------------------------------//
-- Git
-----------------------------------------------------------------------------//

---Refresh the list of conflicted files for a repository
---@param root string
local function fetch_conflicts(root)
  git.get_conflicted_files(root, function(files)
    if not files then return end
    local prefix = root .. '/'
    for path, entry in pairs(visited_buffers) do
      if entry.root == root and not files[path] then
        reset_buffer(entry.bufnr or find_loaded_buf(path), entry)
        visited_buffers[path] = nil
      end
    end
    for path in pairs(files) do
      if vim.startswith(path, prefix) and not rawget(visited_buffers, path) then
        visited_buffers[path] = { root = root }
        local bufnr = find_loaded_buf(path)
        if bufnr then parse_buffer(bufnr) end
      end
    end
  end)
end

---@param repo RepoWatcher
local function stop_watcher(repo)
  if repo.handle and not repo.handle:is_closing() then
    repo.handle:stop()
    repo.handle:close()
  end
  repo.close_timer()
end

---Start watching the git directory of the repository so that changes to the index
---(e.g. `git add`, `git merge --abort`) are picked up
---@param repo RepoWatcher
local function start_watcher(repo)
  local handle = vim.uv.new_fs_event()
  if not handle then return end
  -- Only the git directory itself is watched (not recursively) since watching all of
  -- `.git/objects` is extremely expensive in large repositories
  local ok, err = handle:start(repo.gitdir, {}, function(err, filename)
    if err then
      return vim.schedule(
        function() utils.notify(fmt('Error watching %s: %s', repo.gitdir, err), 'error') end
      )
    end
    if filename and not GITDIR_EVENTS[filename] then return end
    if config.debug then
      vim.schedule(
        function() utils.notify(fmt('%s changed in %s', filename, repo.gitdir), 'info') end
      )
    end
    repo.refresh()
  end)
  if not ok then
    handle:close()
    if config.debug then utils.notify(fmt('Failed to watch %s: %s', repo.gitdir, err), 'warn') end
    return
  end
  repo.handle = handle
end

---Track the repository containing `dir`, fetching its conflicted files
---@param dir string
local function track_repo(dir)
  if dir == '' or not vim.fs.root(dir, '.git') then return end
  git.get_repo(dir, function(info)
    if not info then return end
    local repo = repos[info.root]
    if repo then return repo.refresh() end
    local refresh, close_timer = utils.debounce(
      WATCH_DEBOUNCE_MS,
      function() fetch_conflicts(info.root) end
    )
    repo = { root = info.root, gitdir = info.gitdir, refresh = refresh, close_timer = close_timer }
    repos[info.root] = repo
    start_watcher(repo)
    fetch_conflicts(info.root)
  end)
end

---@param bufnr integer
local function track_buffer(bufnr)
  if not api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= '' then return end
  local name = api.nvim_buf_get_name(bufnr)
  local dir = name ~= '' and vim.fs.dirname(name) or fn.getcwd()
  if fn.isdirectory(dir) == 0 then return end
  track_repo(dir)
end

-----------------------------------------------------------------------------//
-- Positions
-----------------------------------------------------------------------------//

---@param bufnr integer
---@return ConflictPosition[]
local function get_positions(bufnr)
  process(bufnr)
  local entry = visited_buffers[bufnr]
  return entry and entry.positions or {}
end

---@param positions ConflictPosition[]
---@param line integer 0-based
---@return ConflictPosition?
local function position_at(positions, line)
  for _, position in ipairs(positions) do
    if position.current.range_start <= line and position.incoming.range_end >= line then
      return position
    end
  end
end

---@param position ConflictPosition?
---@param side ConflictSide?
local function set_cursor(position, side)
  if not position then return end
  local target = side == SIDES.THEIRS and position.incoming or position.current
  api.nvim_win_set_cursor(0, { target.range_start + 1, 0 })
end

-----------------------------------------------------------------------------//
-- Resolving
-----------------------------------------------------------------------------//

---@param bufnr integer
---@param range Range
---@return string[]
local function content_lines(bufnr, range)
  if range.content_end < range.content_start then return {} end
  return api.nvim_buf_get_lines(bufnr, range.content_start, range.content_end + 1, false)
end

---Replace the conflict with the lines of the chosen side
---@param bufnr integer
---@param position ConflictPosition
---@param side ConflictSide
local function resolve(bufnr, position, side)
  local lines
  if side == SIDES.OURS or side == SIDES.THEIRS or side == SIDES.BASE then
    lines = content_lines(bufnr, position[name_map[side]])
  elseif side == SIDES.BOTH then
    lines = content_lines(bufnr, position.current)
    vim.list_extend(lines, content_lines(bufnr, position.incoming))
  else
    lines = {}
  end
  local first, last = position.current.range_start, position.incoming.range_end + 1
  api.nvim_buf_set_lines(bufnr, first, last, false, lines)
end

---Resolve every conflict in `positions` with `side`
---@param bufnr integer
---@param positions ConflictPosition[]
---@param side ConflictSide
local function resolve_all(bufnr, positions, side)
  if #positions == 0 then return end
  if side == SIDES.BASE then
    for _, position in ipairs(positions) do
      if vim.tbl_isempty(position.ancestor) then
        return utils.notify('No base section found, is merge.conflictStyle set to diff3?', 'warn')
      end
    end
  end
  -- resolve from the bottom up so earlier positions stay valid
  for i = #positions, 1, -1 do
    resolve(bufnr, positions[i], side)
  end
  parse_buffer(bufnr)
end

---@return integer? start 1-based line of the start of the visual selection
---@return integer? finish
local function get_visual_range()
  local mode = fn.mode()
  if mode ~= 'v' and mode ~= 'V' and mode ~= '\22' then return end
  local start, finish = fn.line('v'), fn.line('.')
  if start > finish then
    start, finish = finish, start
  end
  api.nvim_cmd({ cmd = 'normal', args = { '\27' }, bang = true }, {})
  return start, finish
end

---@class GitConflictChooseOpts
---@field range? {[1]: integer, [2]: integer} 1-based inclusive line range

---Select the changes to keep. In visual mode or when a range is given, every conflict that is
---entirely inside the range is resolved, otherwise the conflict under the cursor.
---@param side ConflictSide
---@param opts GitConflictChooseOpts?
function M.choose(side, opts)
  if not name_map[side] then return end
  local bufnr = api.nvim_get_current_buf()
  local start, finish
  if opts and opts.range then
    start, finish = opts.range[1], opts.range[2]
  else
    start, finish = get_visual_range()
  end
  local positions = get_positions(bufnr)

  if start and finish then
    local selected = vim.tbl_filter(
      function(pos)
        return pos.current.range_start >= start - 1 and pos.incoming.range_end <= finish - 1
      end,
      positions
    )
    return resolve_all(bufnr, selected, side)
  end

  local position = position_at(positions, api.nvim_win_get_cursor(0)[1] - 1)
  if position then resolve_all(bufnr, { position }, side) end
end

---@param side ConflictSide?
function M.find_next(side)
  local positions = get_positions(api.nvim_get_current_buf())
  local line = api.nvim_win_get_cursor(0)[1] - 1
  for _, position in ipairs(positions) do
    if line < position.current.range_start then return set_cursor(position, side) end
  end
  set_cursor(positions[1], side)
end

---@param side ConflictSide?
function M.find_prev(side)
  local positions = get_positions(api.nvim_get_current_buf())
  local line = api.nvim_win_get_cursor(0)[1] - 1
  for i = #positions, 1, -1 do
    if line > positions[i].current.range_start then return set_cursor(positions[i], side) end
  end
  set_cursor(positions[#positions], side)
end

-----------------------------------------------------------------------------//
-- Mappings
-----------------------------------------------------------------------------//

local function set_plug_mappings()
  local function plug(modes, name, func, desc)
    map(modes, '<Plug>(' .. name .. ')', func, { silent = true, desc = 'Git Conflict: ' .. desc })
  end
  plug({ 'n', 'x' }, 'git-conflict-ours', function() M.choose('ours') end, 'Choose Ours')
  plug({ 'n', 'x' }, 'git-conflict-theirs', function() M.choose('theirs') end, 'Choose Theirs')
  plug({ 'n', 'x' }, 'git-conflict-both', function() M.choose('both') end, 'Choose Both')
  plug({ 'n', 'x' }, 'git-conflict-base', function() M.choose('base') end, 'Choose Base')
  plug({ 'n', 'x' }, 'git-conflict-none', function() M.choose('none') end, 'Choose None')
  plug('n', 'git-conflict-next-conflict', function() M.find_next() end, 'Next Conflict')
  plug('n', 'git-conflict-prev-conflict', function() M.find_prev() end, 'Previous Conflict')
end

---@param bufnr integer
local function setup_buffer_mappings(bufnr)
  local mappings = config.default_mappings
  if not mappings or vim.b[bufnr].git_conflict_mappings then return end
  local set = {}
  local function buf_map(modes, lhs, rhs, desc)
    if not lhs or lhs == '' then return end
    map(modes, lhs, rhs, { silent = true, buffer = bufnr, desc = 'Git Conflict: ' .. desc })
    for _, mode in ipairs(type(modes) == 'table' and modes or { modes }) do
      table.insert(set, { mode, lhs })
    end
  end

  buf_map({ 'n', 'x' }, mappings.ours, '<Plug>(git-conflict-ours)', 'Choose Ours')
  buf_map({ 'n', 'x' }, mappings.theirs, '<Plug>(git-conflict-theirs)', 'Choose Theirs')
  buf_map({ 'n', 'x' }, mappings.both, '<Plug>(git-conflict-both)', 'Choose Both')
  buf_map({ 'n', 'x' }, mappings.none, '<Plug>(git-conflict-none)', 'Choose None')
  buf_map('n', mappings.prev, '<Plug>(git-conflict-prev-conflict)', 'Previous Conflict')
  buf_map('n', mappings.next, '<Plug>(git-conflict-next-conflict)', 'Next Conflict')
  vim.b[bufnr].git_conflict_mappings = set
end

---@param bufnr integer
local function clear_buffer_mappings(bufnr)
  local set = vim.b[bufnr].git_conflict_mappings
  if not set then return end
  for _, m in ipairs(set) do
    pcall(vim.keymap.del, m[1], m[2], { buffer = bufnr })
  end
  vim.b[bufnr].git_conflict_mappings = nil
end

-----------------------------------------------------------------------------//
-- Commands
-----------------------------------------------------------------------------//

local function set_commands()
  local command = api.nvim_create_user_command
  command('GitConflictRefresh', function()
    for root in pairs(repos) do
      fetch_conflicts(root)
    end
    track_buffer(api.nvim_get_current_buf())
  end, { nargs = 0 })
  command('GitConflictListQf', function()
    M.conflicts_to_qf_items(function(items)
      if #items > 0 then
        fn.setqflist(items, 'r')
        if type(config.list_opener) == 'function' then
          config.list_opener()
        else
          vim.cmd(config.list_opener)
        end
      end
    end)
  end, { nargs = 0 })

  local function choose_cmd(side)
    return function(args)
      M.choose(side, args.range > 0 and { range = { args.line1, args.line2 } } or nil)
    end
  end
  command('GitConflictChooseOurs', choose_cmd('ours'), { nargs = 0, range = true })
  command('GitConflictChooseTheirs', choose_cmd('theirs'), { nargs = 0, range = true })
  command('GitConflictChooseBoth', choose_cmd('both'), { nargs = 0, range = true })
  command('GitConflictChooseBase', choose_cmd('base'), { nargs = 0, range = true })
  command('GitConflictChooseNone', choose_cmd('none'), { nargs = 0, range = true })
  command('GitConflictNextConflict', function() M.find_next() end, { nargs = 0 })
  command('GitConflictPrevConflict', function() M.find_prev() end, { nargs = 0 })
end

-----------------------------------------------------------------------------//
-- Setup
-----------------------------------------------------------------------------//

local function stop_all_watchers()
  for root, repo in pairs(repos) do
    stop_watcher(repo)
    repos[root] = nil
  end
end

---@param user_config GitConflictUserConfig?
function M.setup(user_config)
  if fn.executable('git') <= 0 then
    return vim.schedule(
      function()
        utils.notify('You need to have git installed in order to use this plugin', 'error', true)
      end
    )
  end

  local _user_config = user_config or {}
  if _user_config.default_mappings == true then _user_config.default_mappings = DEFAULT_MAPPINGS end
  config = vim.tbl_deep_extend('force', config, _user_config)

  set_highlights(config.highlights)
  if config.default_commands then set_commands() end
  set_plug_mappings()

  local group = api.nvim_create_augroup(AUGROUP_NAME, { clear = true })
  api.nvim_create_autocmd('ColorScheme', {
    group = group,
    callback = function() set_highlights(config.highlights) end,
  })

  api.nvim_create_autocmd({ 'VimEnter', 'DirChanged' }, {
    group = group,
    callback = function() track_repo(fn.getcwd()) end,
  })

  api.nvim_create_autocmd({ 'BufReadPost', 'SessionLoadPost', 'FocusGained' }, {
    group = group,
    callback = function(args) track_buffer(args.buf) end,
  })

  api.nvim_create_autocmd({ 'BufWinEnter', 'TextChanged' }, {
    group = group,
    callback = function(args) process(args.buf) end,
  })

  local process_insert, close_insert_timer = utils.debounce(INSERT_DEBOUNCE_MS, function(bufnr)
    if api.nvim_buf_is_valid(bufnr) then process(bufnr) end
  end)
  api.nvim_create_autocmd({ 'TextChangedI', 'TextChangedP' }, {
    group = group,
    callback = function(args)
      if visited_buffers[args.buf] then process_insert(args.buf) end
    end,
  })

  api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      stop_all_watchers()
      close_insert_timer()
    end,
  })

  api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'GitConflictDetected',
    callback = function(args)
      local bufnr = args.data and args.data.bufnr or api.nvim_get_current_buf()
      if config.disable_diagnostics then vim.diagnostic.enable(false, { bufnr = bufnr }) end
      setup_buffer_mappings(bufnr)
    end,
  })

  api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'GitConflictResolved',
    callback = function(args)
      local bufnr = args.data and args.data.bufnr or api.nvim_get_current_buf()
      if config.disable_diagnostics then vim.diagnostic.enable(true, { bufnr = bufnr }) end
      clear_buffer_mappings(bufnr)
    end,
  })

  -- Pick up the repository if setup is called after startup (e.g. lazy loaded)
  if vim.v.vim_did_enter == 1 then
    track_repo(fn.getcwd())
    track_buffer(api.nvim_get_current_buf())
  end
end

-----------------------------------------------------------------------------//
-- Quickfix
-----------------------------------------------------------------------------//

--- Convert the conflicts detected via git into a list of quickfix entries.
---@param callback fun(items: table[])
function M.conflicts_to_qf_items(callback)
  local items = {}
  local paths = vim.tbl_keys(visited_buffers)
  table.sort(paths)
  for _, path in ipairs(paths) do
    local entry = visited_buffers[path]
    local positions = entry.positions
    if not positions and fn.filereadable(path) == 1 then
      positions = parser.detect(fn.readfile(path))
    end
    local item = { filename = path, type = 'E', valid = 1 }
    if positions and #positions > 0 then
      for _, pos in ipairs(positions) do
        for _, section in ipairs({ 'current', 'ancestor', 'incoming' }) do
          local range = pos[section]
          if range.range_start then
            local text = section .. ' change'
            local next_item = { lnum = range.range_start + 1, col = 1, text = text }
            table.insert(items, vim.tbl_extend('force', item, next_item))
          end
        end
      end
    else
      table.insert(items, vim.tbl_extend('force', item, { lnum = 1, text = 'git conflict' }))
    end
  end
  callback(items)
end

-----------------------------------------------------------------------------//
-- API
-----------------------------------------------------------------------------//

---@param bufnr integer?
function M.clear(bufnr)
  if bufnr and not api.nvim_buf_is_valid(bufnr) then return end
  api.nvim_buf_clear_namespace(bufnr or 0, NAMESPACE, 0, -1)
end

function M.debug_watchers()
  vim.print(
    vim.tbl_map(
      function(repo)
        return { gitdir = repo.gitdir, active = repo.handle and repo.handle:is_active() or false }
      end,
      repos
    )
  )
end

---Returns the amount of conflicts in a given buffer
---@param bufnr integer?
---@return integer
function M.conflict_count(bufnr)
  bufnr = (not bufnr or bufnr == 0) and api.nvim_get_current_buf() or bufnr
  if not api.nvim_buf_is_valid(bufnr) then return 0 end
  return #get_positions(bufnr)
end

return M
