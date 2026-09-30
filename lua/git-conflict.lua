local M = {}

local color = require('git-conflict.colors')
local utils = require('git-conflict.utils')
local parser = require('git-conflict.parser')
local git = require('git-conflict.git')
local worddiff = require('git-conflict.worddiff')

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

---@alias ConflictSide "'ours'"|"'theirs'"|"'both'"|"'both_reverse'"|"'base'"|"'none'"|"'cursor'"

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
--- @field had_markers boolean? whether conflict markers were ever found in the buffer
--- @field marker_size integer? value of the `conflict-marker-size` attribute

--- @class GitConflictMappings
--- @field ours string
--- @field theirs string
--- @field none string
--- @field both string
--- @field both_reverse string?
--- @field next string
--- @field prev string
--- @field next_file string
--- @field prev_file string

---@alias GitConflictFileResolvedAction "'stage'"|"'prompt'"|fun(bufnr: integer, path: string)

---@alias GitConflictPicker "'snacks'"|"'telescope'"|"'fzf-lua'"|"'select'"

--- @class GitConflictConfig
--- @field default_mappings GitConflictMappings|false
--- @field default_commands boolean
--- @field disable_diagnostics boolean
--- @field list_opener string|function
--- @field highlights ConflictHighlights
--- @field show_keymap_hints boolean
--- @field word_diff boolean
--- @field operation_labels boolean
--- @field hide_ancestor boolean
--- @field on_file_resolved GitConflictFileResolvedAction?
--- @field picker GitConflictPicker?
--- @field debug boolean

--- @class GitConflictUserConfig
--- @field default_mappings? boolean|GitConflictMappings
--- @field default_commands? boolean
--- @field disable_diagnostics? boolean
--- @field list_opener? string|function
--- @field highlights? ConflictHighlights
--- @field show_keymap_hints? boolean
--- @field word_diff? boolean
--- @field operation_labels? boolean
--- @field hide_ancestor? boolean
--- @field on_file_resolved? GitConflictFileResolvedAction
--- @field picker? GitConflictPicker
--- @field debug? boolean

-----------------------------------------------------------------------------//
-- Constants
-----------------------------------------------------------------------------//
local SIDES = {
  OURS = 'ours',
  THEIRS = 'theirs',
  BOTH = 'both',
  BOTH_REVERSE = 'both_reverse',
  BASE = 'base',
  NONE = 'none',
  CURSOR = 'cursor',
}

-- A mapping between the internal names and the display names
local name_map = {
  ours = 'current',
  theirs = 'incoming',
  base = 'ancestor',
  both = 'both',
  both_reverse = 'both_reverse',
  none = 'none',
  cursor = 'cursor',
}

local CURRENT_HL = 'GitConflictCurrent'
local INCOMING_HL = 'GitConflictIncoming'
local ANCESTOR_HL = 'GitConflictAncestor'
local CURRENT_LABEL_HL = 'GitConflictCurrentLabel'
local INCOMING_LABEL_HL = 'GitConflictIncomingLabel'
local ANCESTOR_LABEL_HL = 'GitConflictAncestorLabel'
local MIDDLE_LABEL_HL = 'GitConflictMiddleLabel'
local CURRENT_TEXT_HL = 'GitConflictCurrentText'
local INCOMING_TEXT_HL = 'GitConflictIncomingText'
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
-- Skip the word diff for very large conflicts
local WORD_DIFF_MAX_LINES = 500

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
  next_file = ']X',
  prev_file = '[X',
}

--- @type GitConflictConfig
local config = {
  debug = false,
  default_mappings = DEFAULT_MAPPINGS,
  default_commands = true,
  disable_diagnostics = false,
  list_opener = 'copen',
  show_keymap_hints = false,
  word_diff = true,
  operation_labels = true,
  hide_ancestor = false,
  on_file_resolved = nil,
  picker = nil,
  highlights = {
    current = 'DiffText',
    incoming = 'DiffAdd',
    ancestor = nil,
  },
}

local state = {
  -- whether the base section of diff3 conflicts is currently hidden
  ancestor_hidden = false,
  -- the side used by the last choose so that it can be repeated with `.`
  ---@type ConflictSide?
  repeat_side = nil,
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
---@field operation GitOperation?

--- Repositories being watched, keyed by work tree root
---@type table<string, RepoWatcher>
local repos = {}

---The root of the repository a buffer belongs to, if it is tracked
---@param bufnr integer
---@return string?
local function repo_root_of(bufnr)
  local entry = visited_buffers[bufnr]
  if entry then return entry.root end
  local path = buf_path(bufnr)
  if not path then return end
  local best
  for root in pairs(repos) do
    if vim.startswith(path, root .. '/') and (not best or #root > #best) then best = root end
  end
  return best
end

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
---@param description string?
local function draw_section_label(bufnr, hl_group, lnum, description)
  api.nvim_buf_set_extmark(bufnr, NAMESPACE, lnum, 0, {
    line_hl_group = hl_group,
    virt_text = description and { { description, hl_group } } or nil,
    virt_text_pos = description and 'eol' or nil,
    priority = PRIORITY,
  })
end

---@param description string
---@param hints {[1]: string, [2]: string}[] pairs of mapping name and description
---@return string
local function with_hints(description, hints)
  local mappings = config.default_mappings
  if not config.show_keymap_hints or not mappings then return description end
  local parts = { description }
  for _, hint in ipairs(hints) do
    local lhs = mappings[hint[1]]
    if lhs and lhs ~= '' then table.insert(parts, fmt('[%s] %s', lhs, hint[2])) end
  end
  return table.concat(parts, '  ')
end

---Describe each side taking into account the operation in progress since e.g. during a rebase
---"current" is the upstream branch and "incoming" is your own commit
---@param root string?
---@return string current, string incoming
local function section_descriptions(root)
  local current, incoming = 'Current changes', 'Incoming changes'
  local op = config.operation_labels and root and repos[root] and repos[root].operation
  if op then
    if op.kind == 'rebase' then
      current = fmt('%s: rebasing onto %s', current, op.current or 'upstream')
      incoming = op.incoming and fmt('%s: your commit from %s', incoming, op.incoming)
        or fmt('%s: your commit', incoming)
    else
      if op.current then current = fmt('%s: %s', current, op.current) end
      if op.kind == 'merge' and op.incoming then
        incoming = fmt('%s: %s', incoming, op.incoming)
      elseif op.kind == 'cherry-pick' then
        incoming = fmt('%s: cherry-picking %s', incoming, op.incoming or 'commit')
      elseif op.kind == 'revert' then
        incoming = fmt('%s: reverting %s', incoming, op.incoming or 'commit')
      end
    end
  end
  return '(' .. current .. ')', '(' .. incoming .. ')'
end

---Highlight the words that differ between the current and incoming sections
---@param bufnr integer
---@param position ConflictPosition
---@param lines string[] all lines of the buffer
local function highlight_word_diff(bufnr, position, lines)
  local current, incoming = position.current, position.incoming
  local a = vim.list_slice(lines, current.content_start + 1, current.content_end + 1)
  local b = vim.list_slice(lines, incoming.content_start + 1, incoming.content_end + 1)
  if #a > WORD_DIFF_MAX_LINES or #b > WORD_DIFF_MAX_LINES then return end
  local a_ranges, b_ranges = worddiff.compute(a, b)
  local function mark(ranges, start, hl)
    for _, r in ipairs(ranges) do
      api.nvim_buf_set_extmark(bufnr, NAMESPACE, start + r.line - 1, r.col_start, {
        end_col = r.col_end,
        hl_group = hl,
        priority = PRIORITY + 1,
      })
    end
  end
  mark(a_ranges, current.content_start, CURRENT_TEXT_HL)
  mark(b_ranges, incoming.content_start, INCOMING_TEXT_HL)
end

---Set a window local 'conceallevel' for the buffer in every window showing it, since concealed
---lines are only hidden when 'conceallevel' is non-zero. The original value is restored when
---nothing needs to be concealed anymore.
---@param bufnr integer
---@param needed boolean
local function sync_conceal(bufnr, needed)
  for _, win in ipairs(fn.win_findbuf(bufnr)) do
    local saved = vim.w[win].git_conflict_conceallevel
    if needed and not saved and vim.wo[win].conceallevel == 0 then
      vim.w[win].git_conflict_conceallevel = vim.wo[win].conceallevel
      vim.wo[win][0].conceallevel = 2
    elseif not needed and saved then
      vim.wo[win][0].conceallevel = saved
      vim.w[win].git_conflict_conceallevel = nil
    end
  end
end

---Highlight each part of a git conflict i.e. the incoming changes vs the current/HEAD changes
---@param bufnr integer
---@param positions ConflictPosition[]
---@param lines string[] all lines of the buffer
---@param root string? repository root, used to describe the operation in progress
local function highlight_conflicts(bufnr, positions, lines, root)
  api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)
  local current_description, incoming_description = section_descriptions(root)
  local current_label = with_hints(current_description, {
    { 'ours', 'ours' },
    { 'both', 'both' },
    { 'both_reverse', 'both reversed' },
    { 'none', 'none' },
  })
  local incoming_label = with_hints(incoming_description, { { 'theirs', 'theirs' } })
  local conceal = false
  for _, position in ipairs(positions) do
    draw_section_label(bufnr, CURRENT_LABEL_HL, position.current.range_start, current_label)
    hl_content(bufnr, CURRENT_HL, position.current)
    local ancestor = position.ancestor
    if ancestor.range_start then
      if state.ancestor_hidden then
        conceal = true
        api.nvim_buf_set_extmark(bufnr, NAMESPACE, ancestor.range_start, 0, {
          end_row = ancestor.range_end,
          conceal_lines = '',
        })
      end
      draw_section_label(bufnr, ANCESTOR_LABEL_HL, ancestor.range_start, '(Base changes)')
      hl_content(bufnr, ANCESTOR_HL, ancestor)
    end
    draw_section_label(bufnr, MIDDLE_LABEL_HL, position.middle.range_start)
    hl_content(bufnr, INCOMING_HL, position.incoming)
    draw_section_label(bufnr, INCOMING_LABEL_HL, position.incoming.range_end, incoming_label)
    if config.word_diff then highlight_word_diff(bufnr, position, lines) end
  end
  sync_conceal(bufnr, conceal)
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
  local function set(name, val)
    api.nvim_set_hl(0, name, vim.tbl_extend('force', val, { default = true }))
  end
  set(CURRENT_HL, { background = current_bg, bold = true })
  set(INCOMING_HL, { background = incoming_bg, bold = true })
  set(ANCESTOR_HL, { background = ancestor_bg, bold = true })
  set(CURRENT_LABEL_HL, { background = current_label_bg })
  set(INCOMING_LABEL_HL, { background = incoming_label_bg })
  set(ANCESTOR_LABEL_HL, { background = ancestor_label_bg })
  set(MIDDLE_LABEL_HL, { link = 'NonText' })
  set(CURRENT_TEXT_HL, { background = color.contrast(current_bg, 100), bold = true })
  set(INCOMING_TEXT_HL, { background = color.contrast(incoming_bg, 100), bold = true })
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

local clear_buffer_mappings

---Mark a buffer as no longer conflicted according to git
---@param bufnr integer?
---@param entry ConflictBufferCache
local function reset_buffer(bufnr, entry)
  if bufnr and api.nvim_buf_is_valid(bufnr) then
    M.clear(bufnr)
    if entry.has_conflict then fire_event(bufnr, false) end
    clear_buffer_mappings(bufnr, 'file')
  end
  entry.positions, entry.tick, entry.has_conflict = nil, nil, nil
end

---Parse the buffer for conflict markers, highlight them and fire events if the state changed
---@param bufnr integer
local function parse_buffer(bufnr)
  if bufnr == 0 then bufnr = api.nvim_get_current_buf() end
  local entry = visited_buffers[bufnr]
  if not entry or not api.nvim_buf_is_loaded(bufnr) or not utils.is_valid_buf(bufnr) then return end
  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local positions = parser.detect(lines, entry.marker_size)
  local has_conflict = #positions > 0
  entry.bufnr = bufnr
  entry.tick = api.nvim_buf_get_changedtick(bufnr)
  entry.positions = positions

  if has_conflict then
    entry.had_markers = true
    highlight_conflicts(bufnr, positions, lines, entry.root)
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

---Force every loaded conflicted buffer to be parsed and highlighted again
---@param root string? only buffers of this repository
local function refresh_highlights(root)
  for _, entry in pairs(visited_buffers) do
    if entry.bufnr and (not root or entry.root == root) and api.nvim_buf_is_loaded(entry.bufnr) then
      parse_buffer(entry.bufnr)
    end
  end
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

---Refresh the operation in progress and the list of conflicted files for a repository
---@param root string
local function fetch_conflicts(root)
  local repo = repos[root]
  local function update_operation(done)
    if not repo then return done() end
    git.get_operation(root, repo.gitdir, function(op)
      local changed = not vim.deep_equal(op, repo.operation)
      repo.operation = op
      done(changed)
    end)
  end

  update_operation(function(operation_changed)
    git.get_conflicted_files(root, function(files)
      if not files then return end
      local prefix = root .. '/'
      for path, entry in pairs(visited_buffers) do
        if entry.root == root and not files[path] then
          reset_buffer(entry.bufnr or find_loaded_buf(path), entry)
          visited_buffers[path] = nil
        end
      end
      local added = {}
      for path in pairs(files) do
        if vim.startswith(path, prefix) and not rawget(visited_buffers, path) then
          visited_buffers[path] = { root = root }
          table.insert(added, path)
        end
      end
      if operation_changed then refresh_highlights(root) end
      if #added == 0 then return end
      git.get_marker_sizes(root, added, function(sizes)
        for _, path in ipairs(added) do
          local entry = rawget(visited_buffers, path)
          if entry then
            entry.marker_size = sizes[path]
            local bufnr = find_loaded_buf(path)
            if bufnr then parse_buffer(bufnr) end
          end
        end
      end)
    end)
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

---The conflicts of a file whether or not it is loaded
---@param path string
---@return ConflictPosition[]
local function file_positions(path)
  local entry = visited_buffers[path]
  if not entry then return {} end
  local bufnr = entry.bufnr or find_loaded_buf(path)
  if bufnr and api.nvim_buf_is_loaded(bufnr) then return get_positions(bufnr) end
  if fn.filereadable(path) == 0 then return {} end
  return parser.detect(fn.readfile(path), entry.marker_size)
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

---@param position ConflictPosition
---@return boolean
local function has_base(position) return position.ancestor.content_start ~= nil end

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

---Work out which side of the conflict the cursor is in
---@param position ConflictPosition
---@param line integer 0-based
---@return ConflictSide?
local function side_at(position, line)
  if line < position.middle.range_start then
    local ancestor = position.ancestor
    if ancestor.range_start and line >= ancestor.range_start then return SIDES.BASE end
    return SIDES.OURS
  elseif line > position.middle.range_start then
    return SIDES.THEIRS
  end
end

---The lines that replace the conflict when choosing `side`
---@param bufnr integer
---@param position ConflictPosition
---@param side ConflictSide
---@return string[]
local function side_lines(bufnr, position, side)
  if side == SIDES.OURS or side == SIDES.THEIRS or side == SIDES.BASE then
    return content_lines(bufnr, position[name_map[side]])
  elseif side == SIDES.BOTH then
    local lines = content_lines(bufnr, position.current)
    return vim.list_extend(lines, content_lines(bufnr, position.incoming))
  elseif side == SIDES.BOTH_REVERSE then
    local lines = content_lines(bufnr, position.incoming)
    return vim.list_extend(lines, content_lines(bufnr, position.current))
  end
  return {}
end

---Resolve every conflict in `positions` with `side`
---@param bufnr integer
---@param positions ConflictPosition[]
---@param side ConflictSide
local function resolve_all(bufnr, positions, side)
  if #positions == 0 then return end
  if side == SIDES.BASE then
    for _, position in ipairs(positions) do
      if not has_base(position) then
        return utils.notify('No base section found, is merge.conflictStyle set to diff3?', 'warn')
      end
    end
  end
  -- resolve from the bottom up so earlier positions stay valid
  for i = #positions, 1, -1 do
    local position = positions[i]
    local lines = side_lines(bufnr, position, side)
    local first, last = position.current.range_start, position.incoming.range_end + 1
    api.nvim_buf_set_lines(bufnr, first, last, false, lines)
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
    if side == SIDES.CURSOR then return end
    local selected = vim.tbl_filter(
      function(pos)
        return pos.current.range_start >= start - 1 and pos.incoming.range_end <= finish - 1
      end,
      positions
    )
    return resolve_all(bufnr, selected, side)
  end

  local line = api.nvim_win_get_cursor(0)[1] - 1
  local position = position_at(positions, line)
  if not position then return end
  if side == SIDES.CURSOR then
    side = side_at(position, line)
    if not side then
      return utils.notify('Move the cursor into the section you want to keep', 'warn')
    end
  end
  resolve_all(bufnr, { position }, side)
end

---Resolve every conflict in the current buffer with the same side
---@param side ConflictSide
function M.choose_all(side)
  if not name_map[side] or side == SIDES.CURSOR then return end
  local bufnr = api.nvim_get_current_buf()
  resolve_all(bufnr, get_positions(bufnr), side)
end

---Used as 'operatorfunc' so that choosing a side can be repeated with `.`
function M._choose_repeat()
  if state.repeat_side then M.choose(state.repeat_side) end
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

---Paths of the files git reports as conflicted, sorted
---@param root string? only files of this repository
---@return string[]
function M.conflicted_files(root)
  local paths = {}
  for path, entry in pairs(visited_buffers) do
    if not root or entry.root == root then table.insert(paths, path) end
  end
  table.sort(paths)
  return paths
end

---@param reverse boolean
local function find_file(reverse)
  local bufnr = api.nvim_get_current_buf()
  local current = buf_path(bufnr) or ''
  local files = vim.tbl_filter(
    function(path) return path ~= current end,
    M.conflicted_files(repo_root_of(bufnr))
  )
  if #files == 0 then return utils.notify('No other conflicted files', 'info') end
  local target = reverse and files[#files] or files[1]
  if reverse then
    for i = #files, 1, -1 do
      if files[i] < current then
        target = files[i]
        break
      end
    end
  else
    for _, path in ipairs(files) do
      if path > current then
        target = path
        break
      end
    end
  end
  local ok, err = pcall(vim.cmd.edit, fn.fnameescape(target))
  if not ok then
    return utils.notify(err --[[@as string]], 'error')
  end
  local positions = get_positions(api.nvim_get_current_buf())
  set_cursor(reverse and positions[#positions] or positions[1])
end

---Open the next conflicted file (in path order) at its first conflict
function M.find_next_file() find_file(false) end

---Open the previous conflicted file (in path order) at its last conflict
function M.find_prev_file() find_file(true) end

---Show or hide the base section of diff3 conflicts
---@param hidden boolean? defaults to toggling
function M.toggle_ancestor(hidden)
  if hidden == nil then hidden = not state.ancestor_hidden end
  state.ancestor_hidden = hidden
  refresh_highlights()
end

-----------------------------------------------------------------------------//
-- Mappings
-----------------------------------------------------------------------------//

---A normal mode mapping that chooses `side` and can be repeated with `.`
---@param side ConflictSide
local function repeatable_choose(side)
  return function()
    state.repeat_side = side
    vim.o.operatorfunc = "v:lua.require'git-conflict'._choose_repeat"
    return 'g@_'
  end
end

local function set_plug_mappings()
  local function plug(modes, name, func, desc, opts)
    local o =
      vim.tbl_extend('force', { silent = true, desc = 'Git Conflict: ' .. desc }, opts or {})
    map(modes, '<Plug>(' .. name .. ')', func, o)
  end
  local function choose_plug(side, name, desc)
    plug('n', name, repeatable_choose(side), desc, { expr = true })
    plug('x', name, function() M.choose(side) end, desc)
  end
  choose_plug('ours', 'git-conflict-ours', 'Choose Ours')
  choose_plug('theirs', 'git-conflict-theirs', 'Choose Theirs')
  choose_plug('both', 'git-conflict-both', 'Choose Both')
  choose_plug('both_reverse', 'git-conflict-both-reverse', 'Choose Both (Theirs First)')
  choose_plug('base', 'git-conflict-base', 'Choose Base')
  choose_plug('none', 'git-conflict-none', 'Choose None')
  plug('n', 'git-conflict-cursor', repeatable_choose('cursor'), 'Choose Side Under Cursor', {
    expr = true,
  })
  plug('n', 'git-conflict-next-conflict', function() M.find_next() end, 'Next Conflict')
  plug('n', 'git-conflict-prev-conflict', function() M.find_prev() end, 'Previous Conflict')
  plug('n', 'git-conflict-next-file', M.find_next_file, 'Next Conflicted File')
  plug('n', 'git-conflict-prev-file', M.find_prev_file, 'Previous Conflicted File')
  plug('n', 'git-conflict-preview', function() M.preview() end, 'Preview Resolution')
end

---@alias MappingGroup "'chunk'"|"'file'"

-- Mappings to resolve and move between conflicts only exist while the buffer has conflict
-- markers, the mappings to move between files remain until git considers the file resolved
---@type table<MappingGroup, {[1]: string|string[], [2]: string, [3]: string, [4]: string}[]>
local MAPPING_GROUPS = {
  chunk = {
    { { 'n', 'x' }, 'ours', '<Plug>(git-conflict-ours)', 'Choose Ours' },
    { { 'n', 'x' }, 'theirs', '<Plug>(git-conflict-theirs)', 'Choose Theirs' },
    { { 'n', 'x' }, 'both', '<Plug>(git-conflict-both)', 'Choose Both' },
    { { 'n', 'x' }, 'both_reverse', '<Plug>(git-conflict-both-reverse)', 'Choose Both Reverse' },
    { { 'n', 'x' }, 'none', '<Plug>(git-conflict-none)', 'Choose None' },
    { 'n', 'prev', '<Plug>(git-conflict-prev-conflict)', 'Previous Conflict' },
    { 'n', 'next', '<Plug>(git-conflict-next-conflict)', 'Next Conflict' },
  },
  file = {
    { 'n', 'next_file', '<Plug>(git-conflict-next-file)', 'Next Conflicted File' },
    { 'n', 'prev_file', '<Plug>(git-conflict-prev-file)', 'Previous Conflicted File' },
  },
}

---@param bufnr integer
---@param group MappingGroup
local function setup_buffer_mappings(bufnr, group)
  local mappings = config.default_mappings
  local var = 'git_conflict_mappings_' .. group
  if not mappings or vim.b[bufnr][var] then return end
  local set = {}
  for _, spec in ipairs(MAPPING_GROUPS[group]) do
    local modes, lhs = spec[1], mappings[spec[2]]
    if lhs and lhs ~= '' then
      map(
        modes,
        lhs,
        spec[3],
        { silent = true, buffer = bufnr, desc = 'Git Conflict: ' .. spec[4] }
      )
      for _, mode in ipairs(type(modes) == 'table' and modes or { modes }) do
        table.insert(set, { mode, lhs })
      end
    end
  end
  vim.b[bufnr][var] = set
end

---@param bufnr integer
---@param group MappingGroup
function clear_buffer_mappings(bufnr, group)
  local var = 'git_conflict_mappings_' .. group
  local set = vim.b[bufnr][var]
  if not set then return end
  for _, m in ipairs(set) do
    pcall(vim.keymap.del, m[1], m[2], { buffer = bufnr })
  end
  vim.b[bufnr][var] = nil
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

  -- `:GitConflictChooseOurs!` resolves every conflict in the buffer
  local function choose_cmd(side)
    return function(args)
      if args.bang then return M.choose_all(side) end
      M.choose(side, args.range > 0 and { range = { args.line1, args.line2 } } or nil)
    end
  end
  local choose_opts = { nargs = 0, range = true, bang = true }
  command('GitConflictChooseOurs', choose_cmd('ours'), choose_opts)
  command('GitConflictChooseTheirs', choose_cmd('theirs'), choose_opts)
  command('GitConflictChooseBoth', choose_cmd('both'), choose_opts)
  command('GitConflictChooseBothReverse', choose_cmd('both_reverse'), choose_opts)
  command('GitConflictChooseBase', choose_cmd('base'), choose_opts)
  command('GitConflictChooseNone', choose_cmd('none'), choose_opts)
  command('GitConflictChooseCursor', function() M.choose('cursor') end, { nargs = 0 })
  command('GitConflictNextConflict', function() M.find_next() end, { nargs = 0 })
  command('GitConflictPrevConflict', function() M.find_prev() end, { nargs = 0 })
  command('GitConflictNextFile', M.find_next_file, { nargs = 0 })
  command('GitConflictPrevFile', M.find_prev_file, { nargs = 0 })
  command('GitConflictToggleAncestor', function() M.toggle_ancestor() end, { nargs = 0 })
  command('GitConflictPreview', function() M.preview() end, { nargs = 0 })
  command('GitConflictPick', function() M.pick() end, { nargs = 0 })
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

---Run the `on_file_resolved` action once a file no longer has any conflict markers and is saved
---@param bufnr integer
local function on_write(bufnr)
  local action = config.on_file_resolved
  local entry = visited_buffers[bufnr]
  if not action or not entry or entry.has_conflict ~= false or not entry.had_markers then return end
  local path = buf_path(bufnr) --[[@as string]]
  if type(action) == 'function' then return action(bufnr, path) end

  local name = fn.fnamemodify(path, ':~:.')
  local function stage()
    git.stage(entry.root, path, function(ok, err)
      if not ok then return utils.notify(fmt('Failed to stage %s: %s', name, err), 'error') end
      local remaining = #M.conflicted_files(entry.root) - 1
      local suffix = remaining > 0 and fmt(' (%d conflicted files remaining)', remaining) or ''
      utils.notify(fmt('Staged %s%s', name, suffix), 'info')
      local repo = repos[entry.root]
      if repo then repo.refresh() end
    end)
  end
  if action == 'stage' then return stage() end
  if action == 'prompt' then
    vim.ui.select(
      { 'Yes', 'No' },
      { prompt = fmt('All conflicts in %s are resolved. Stage it?', name) },
      function(choice)
        if choice == 'Yes' then stage() end
      end
    )
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
  state.ancestor_hidden = config.hide_ancestor

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

  api.nvim_create_autocmd('BufWinEnter', {
    group = group,
    callback = function(args)
      process(args.buf)
      -- a new window showing the buffer needs 'conceallevel' set as well
      local entry = visited_buffers[args.buf]
      if entry and entry.has_conflict and state.ancestor_hidden then parse_buffer(args.buf) end
    end,
  })

  api.nvim_create_autocmd('TextChanged', {
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

  api.nvim_create_autocmd('BufWritePost', {
    group = group,
    callback = function(args) on_write(args.buf) end,
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
      setup_buffer_mappings(bufnr, 'chunk')
      setup_buffer_mappings(bufnr, 'file')
    end,
  })

  api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'GitConflictResolved',
    callback = function(args)
      local bufnr = args.data and args.data.bufnr or api.nvim_get_current_buf()
      if config.disable_diagnostics then vim.diagnostic.enable(true, { bufnr = bufnr }) end
      clear_buffer_mappings(bufnr, 'chunk')
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
  for _, path in ipairs(M.conflicted_files()) do
    local positions = file_positions(path)
    local item = { filename = path, type = 'E', valid = 1 }
    if #positions > 0 then
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
  bufnr = (not bufnr or bufnr == 0) and api.nvim_get_current_buf() or bufnr
  api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)
  sync_conceal(bufnr, false)
end

---@return GitConflictConfig
function M.get_config() return config end

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

---The conflicts in a buffer, positions are 0-based line numbers
---@param bufnr integer?
---@return ConflictPosition[]
function M.get_conflicts(bufnr)
  bufnr = (not bufnr or bufnr == 0) and api.nvim_get_current_buf() or bufnr
  if not api.nvim_buf_is_valid(bufnr) then return {} end
  return vim.deepcopy(get_positions(bufnr))
end

---@class GitConflictStatus
---@field buffer integer number of conflicts in the buffer
---@field files integer number of conflicted files in the buffer's repository (or in all
---repositories when the buffer isn't in one)

---Conflict counts, e.g. for a statusline
---@param bufnr integer?
---@return GitConflictStatus
function M.status(bufnr)
  bufnr = (not bufnr or bufnr == 0) and api.nvim_get_current_buf() or bufnr
  return { buffer = M.conflict_count(bufnr), files = #M.conflicted_files(repo_root_of(bufnr)) }
end

---Preview the result of each way of resolving the conflict under the cursor
function M.preview() require('git-conflict.preview').open() end

---Pick a conflict from every conflicted file with snacks, telescope, fzf-lua or vim.ui.select
---@param picker GitConflictPicker?
function M.pick(picker) require('git-conflict.picker').pick(picker or config.picker) end

--- Internals shared with the preview and picker modules
M._internal = {
  SIDES = SIDES,
  HIGHLIGHTS = { current = CURRENT_HL, incoming = INCOMING_HL, ancestor = ANCESTOR_HL },
  get_positions = get_positions,
  file_positions = file_positions,
  position_at = position_at,
  side_lines = side_lines,
  has_base = has_base,
  resolve_all = resolve_all,
}

return M
