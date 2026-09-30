local H = require('tests.helpers')
local eq = MiniTest.expect.equality

local child = H.new_child()
local dir

local T = MiniTest.new_set({
  hooks = {
    pre_case = function() child.restart({ '-u', 'scripts/minimal_init.lua' }) end,
    post_case = function() H.cleanup(dir) end,
    post_once = child.stop,
  },
})

local function label_texts()
  local ns = child.api.nvim_create_namespace('git-conflict')
  local texts = {}
  for _, mark in ipairs(child.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })) do
    if mark[4].virt_text then table.insert(texts, mark[4].virt_text[1][1]) end
  end
  return texts
end

local function marks_with(key)
  local ns = child.api.nvim_create_namespace('git-conflict')
  return vim.tbl_filter(
    function(mark) return mark[4][key] ~= nil end,
    child.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })
  )
end

local function wait_ms(ms) child.lua(('vim.wait(%d, function() return false end)'):format(ms)) end

-----------------------------------------------------------------------------//
-- Operation labels
-----------------------------------------------------------------------------//

T['labels'] = MiniTest.new_set()

T['labels']['merge'] = function()
  dir = H.simple_repo()
  H.open(child, dir, 'conflicted.lua')
  eq(label_texts(), { '(Current changes: main)', '(Incoming changes: theirs)' })
end

T['labels']['rebase'] = function()
  dir = H.simple_repo({ operation = 'rebase' })
  H.open(child, dir, 'conflicted.lua')
  eq(label_texts(), {
    '(Current changes: rebasing onto main)',
    '(Incoming changes: your commit from theirs)',
  })
end

T['labels']['cherry-pick'] = function()
  dir = H.simple_repo({ operation = 'cherry-pick' })
  H.open(child, dir, 'conflicted.lua')
  local texts = label_texts()
  eq(texts[1], '(Current changes: main)')
  eq(texts[2]:match('^%(Incoming changes: cherry%-picking %x+%)$') ~= nil, true)
end

T['labels']['can be disabled'] = function()
  dir = H.simple_repo({ operation = 'rebase' })
  H.open(child, dir, 'conflicted.lua', { operation_labels = false })
  eq(label_texts(), { '(Current changes)', '(Incoming changes)' })
end

-----------------------------------------------------------------------------//
-- conflict-marker-size
-----------------------------------------------------------------------------//

T['conflict-marker-size attribute'] = function()
  local attrs = '*.txt conflict-marker-size=10\n'
  dir = H.make_repo({
    ['.gitattributes'] = { base = attrs, ours = attrs, theirs = attrs },
    ['file.txt'] = { base = 'a\n', ours = 'b\n', theirs = 'c\n' },
  })
  H.open(child, dir, 'file.txt')
  eq(H.lines(child)[1], '<<<<<<<<<< HEAD')
  eq(child.lua_get('require("git-conflict").conflict_count()'), 1)
  child.api.nvim_win_set_cursor(0, { 1, 0 })
  child.lua('require("git-conflict").choose("theirs")')
  eq(H.lines(child), { 'c' })
end

-----------------------------------------------------------------------------//
-- Word diff
-----------------------------------------------------------------------------//

T['word diff'] = MiniTest.new_set()

T['word diff']['highlights the changed words'] = function()
  dir = H.simple_repo()
  H.open(child, dir, 'conflicted.lua')
  -- line 2 is "local value = 5 + 7" and line 4 is "local value = 1 - 1"
  local marks = vim.tbl_map(
    function(m) return { m[2], m[3], m[4].end_col, m[4].hl_group } end,
    vim.tbl_filter(
      function(m) return m[4].hl_group:match('Text$') ~= nil end,
      marks_with('hl_group')
    )
  )
  table.sort(marks, function(a, b) return a[1] < b[1] end)
  eq(marks, {
    { 1, 14, 19, 'GitConflictCurrentText' },
    { 3, 14, 19, 'GitConflictIncomingText' },
  })
end

T['word diff']['can be disabled'] = function()
  dir = H.simple_repo()
  H.open(child, dir, 'conflicted.lua', { word_diff = false })
  eq(
    vim.tbl_filter(
      function(m) return m[4].hl_group:match('Text$') ~= nil end,
      marks_with('hl_group')
    ),
    {}
  )
end

-----------------------------------------------------------------------------//
-- Both reversed
-----------------------------------------------------------------------------//

T['both_reverse puts theirs first'] = function()
  dir = H.simple_repo()
  H.open(child, dir, 'conflicted.lua')
  child.api.nvim_win_set_cursor(0, { 1, 0 })
  child.cmd('GitConflictChooseBothReverse')
  eq(H.lines(child), { 'local value = 1 - 1', 'local value = 5 + 7', 'print(value)' })
end

-----------------------------------------------------------------------------//
-- Dot repeat
-----------------------------------------------------------------------------//

T['choosing can be repeated with dot'] = function()
  dir = H.two_conflict_repo()
  H.open(child, dir, 'file.txt')
  child.api.nvim_win_set_cursor(0, { 1, 0 })
  child.type_keys('ct')
  eq(child.lua_get('require("git-conflict").conflict_count()'), 1)
  child.type_keys(']x', '.')
  local lines = H.lines(child)
  eq(child.lua_get('require("git-conflict").conflict_count()'), 0)
  eq({ lines[1], lines[8] }, { 'a-theirs', 'b-theirs' })
end

T['dot repeat works on an empty line'] = function()
  dir = H.make_repo({
    ['file.txt'] = { base = 'x\n', ours = '\n', theirs = 'y\n' },
  })
  H.open(child, dir, 'file.txt')
  -- line 2 is the empty "ours" content line
  child.api.nvim_win_set_cursor(0, { 2, 0 })
  child.type_keys('ct')
  eq(H.lines(child), { 'y' })
end

-----------------------------------------------------------------------------//
-- File navigation
-----------------------------------------------------------------------------//

local function three_files()
  return H.make_repo({
    ['a.txt'] = { base = 'x\n', ours = 'a-ours\n', theirs = 'a-theirs\n' },
    ['b.txt'] = { base = 'x\n', ours = 'b-ours\n', theirs = 'b-theirs\n' },
    ['c.txt'] = { base = 'pre\nx\n', ours = 'pre\nc-ours\n', theirs = 'pre\nc-theirs\n' },
  })
end

local function current_file() return child.lua_get('vim.fn.expand("%:t")') end

T['file navigation'] = MiniTest.new_set()

T['file navigation']['moves between conflicted files and wraps'] = function()
  dir = three_files()
  H.open(child, dir, 'a.txt')
  H.wait_for(child, '#require("git-conflict").conflicted_files() == 3')
  child.cmd('GitConflictNextFile')
  eq(current_file(), 'b.txt')
  eq(child.api.nvim_win_get_cursor(0)[1], 1)
  child.type_keys(']X')
  eq(current_file(), 'c.txt')
  -- the cursor is placed on the conflict
  eq(child.api.nvim_win_get_cursor(0)[1], 2)
  child.type_keys(']X')
  eq(current_file(), 'a.txt')
  child.type_keys('[X')
  eq(current_file(), 'c.txt')
end

T['file navigation']['still works once the buffer is resolved'] = function()
  dir = three_files()
  H.open(child, dir, 'a.txt')
  H.wait_for(child, '#require("git-conflict").conflicted_files() == 3')
  child.cmd('%GitConflictChooseOurs')
  eq(child.lua_get('vim.fn.maparg("co", "n")'), '')
  child.type_keys(']X')
  eq(current_file(), 'b.txt')
end

T['file navigation']['with no other files'] = function()
  dir = H.simple_repo()
  H.open(child, dir, 'conflicted.lua')
  child.cmd('GitConflictNextFile')
  eq(current_file(), 'conflicted.lua')
end

-----------------------------------------------------------------------------//
-- Status
-----------------------------------------------------------------------------//

T['status'] = function()
  dir = three_files()
  H.open(child, dir, 'a.txt')
  H.wait_for(child, '#require("git-conflict").conflicted_files() == 3')
  eq(child.lua_get('require("git-conflict").status()'), { buffer = 1, files = 3 })
  child.cmd('%GitConflictChooseOurs')
  eq(child.lua_get('require("git-conflict").status()'), { buffer = 0, files = 3 })
  child.cmd('enew')
  eq(child.lua_get('require("git-conflict").status()'), { buffer = 0, files = 3 })
end

-----------------------------------------------------------------------------//
-- Staging once resolved
-----------------------------------------------------------------------------//

local function unmerged(repo)
  return vim.trim(H.git(repo, 'diff', '--name-only', '--diff-filter=U').stdout)
end

T['on_file_resolved'] = MiniTest.new_set()

T['on_file_resolved']['stage'] = function()
  dir = H.simple_repo()
  H.open(child, dir, 'conflicted.lua', { on_file_resolved = 'stage' })
  child.api.nvim_win_set_cursor(0, { 1, 0 })
  -- saving while conflicts remain does not stage
  child.cmd('write')
  wait_ms(200)
  eq(unmerged(dir), 'conflicted.lua')
  child.lua('require("git-conflict").choose("ours")')
  child.cmd('write')
  H.wait_for(child, '#require("git-conflict").conflicted_files() == 0')
  eq(unmerged(dir), '')
end

T['on_file_resolved']['prompt'] = function()
  dir = H.simple_repo()
  child.lua([[
    _G.prompts = {}
    vim.ui.select = function(choices, opts, cb)
      table.insert(_G.prompts, opts.prompt)
      cb(_G.answer)
    end
  ]])
  H.open(child, dir, 'conflicted.lua', { on_file_resolved = 'prompt' })
  child.api.nvim_win_set_cursor(0, { 1, 0 })
  child.lua('require("git-conflict").choose("ours")')
  child.lua('_G.answer = "No"')
  child.cmd('write')
  wait_ms(200)
  eq(unmerged(dir), 'conflicted.lua')
  child.lua('_G.answer = "Yes"')
  child.cmd('write')
  H.wait_for(child, '#require("git-conflict").conflicted_files() == 0')
  eq(child.lua_get('_G.prompts'), {
    'All conflicts in conflicted.lua are resolved. Stage it?',
    'All conflicts in conflicted.lua are resolved. Stage it?',
  })
end

T['on_file_resolved']['function'] = function()
  dir = H.simple_repo()
  child.lua([[
    require('git-conflict').setup({
      on_file_resolved = function(bufnr, path) _G.called = { bufnr, vim.fs.basename(path) } end,
    })
  ]])
  -- setup is called again with no options which keeps the callback
  H.open(child, dir, 'conflicted.lua')
  child.api.nvim_win_set_cursor(0, { 1, 0 })
  child.lua('require("git-conflict").choose("ours")')
  child.cmd('write')
  eq(child.lua_get('_G.called'), { child.api.nvim_get_current_buf(), 'conflicted.lua' })
  -- nothing is staged by the plugin itself
  eq(unmerged(dir), 'conflicted.lua')
end

-----------------------------------------------------------------------------//
-- Hiding the ancestor
-----------------------------------------------------------------------------//

T['hide ancestor'] = MiniTest.new_set()

T['hide ancestor']['toggles concealing the base section'] = function()
  dir = H.simple_repo({ diff3 = true })
  H.open(child, dir, 'conflicted.lua')
  eq(#marks_with('conceal_lines'), 0)
  eq(child.wo.conceallevel, 0)
  child.cmd('GitConflictToggleAncestor')
  local marks = marks_with('conceal_lines')
  eq(#marks, 1)
  -- the "|||||||" marker and the base content (0-based rows 2 and 3)
  eq({ marks[1][2], marks[1][4].end_row }, { 2, 3 })
  eq(child.wo.conceallevel, 2)
  -- the concealed lines are not drawn
  child.api.nvim_win_set_cursor(0, { 1, 0 })
  child.cmd('redraw')
  local screen = child.lua_get([[(function()
    local rows = {}
    for row = 1, 6 do
      local line = {}
      for col = 1, 7 do table.insert(line, vim.fn.screenstring(row, col)) end
      table.insert(rows, vim.trim(table.concat(line)))
    end
    return rows
  end)()]])
  eq(screen[3], '=======')
  child.cmd('GitConflictToggleAncestor')
  eq(#marks_with('conceal_lines'), 0)
  eq(child.wo.conceallevel, 0)
end

T['hide ancestor']['config option and restore on resolve'] = function()
  dir = H.simple_repo({ diff3 = true })
  H.open(child, dir, 'conflicted.lua', { hide_ancestor = true })
  eq(#marks_with('conceal_lines'), 1)
  eq(child.wo.conceallevel, 2)
  child.api.nvim_win_set_cursor(0, { 1, 0 })
  child.lua('require("git-conflict").choose("ours")')
  eq(child.wo.conceallevel, 0)
end

-----------------------------------------------------------------------------//
-- Picker
-----------------------------------------------------------------------------//

T['picker'] = MiniTest.new_set()

T['picker']['vim.ui.select fallback'] = function()
  dir = three_files()
  child.lua([[
    vim.ui.select = function(items, opts, cb)
      _G.picked = vim.tbl_map(opts.format_item, items)
      cb(items[3])
    end
  ]])
  H.open(child, dir, 'a.txt', { picker = 'select' })
  H.wait_for(child, '#require("git-conflict").conflicted_files() == 3')
  child.cmd('GitConflictPick')
  eq(child.lua_get('_G.picked'), {
    'a.txt:1 conflict 1/1: HEAD <-> theirs',
    'b.txt:1 conflict 1/1: HEAD <-> theirs',
    'c.txt:2 conflict 1/1: HEAD <-> theirs',
  })
  eq(current_file(), 'c.txt')
  eq(child.api.nvim_win_get_cursor(0)[1], 2)
end

T['picker']['detects fzf-lua'] = function()
  dir = H.simple_repo()
  child.lua([[
    package.loaded['snacks'] = nil
    package.preload['snacks'] = function() error('not installed') end
    package.preload['telescope'] = function() error('not installed') end
    package.loaded['fzf-lua'] = {
      quickfix = function() _G.qf = vim.fn.getqflist({ title = 1, items = 1 }) end,
    }
  ]])
  H.open(child, dir, 'conflicted.lua')
  child.lua('require("git-conflict").pick()')
  eq(child.lua_get('_G.qf.title'), 'Git Conflicts')
  eq(child.lua_get('#_G.qf.items'), 1)
end

T['picker']['snacks receives file items'] = function()
  dir = H.simple_repo()
  child.lua([[
    package.loaded['snacks'] = { picker = { pick = function(opts) _G.snacks_opts = opts end } }
  ]])
  H.open(child, dir, 'conflicted.lua', { picker = 'snacks' })
  child.cmd('GitConflictPick')
  local opts = child.lua_get('_G.snacks_opts')
  eq(opts.format, 'file')
  eq(#opts.items, 1)
  eq(vim.fs.basename(opts.items[1].file), 'conflicted.lua')
  eq(opts.items[1].pos, { 1, 0 })
end

-----------------------------------------------------------------------------//
-- Preview
-----------------------------------------------------------------------------//

T['preview'] = MiniTest.new_set()

local function float_lines()
  return child.lua_get([[(function()
    local win = vim.api.nvim_get_current_win()
    assert(vim.api.nvim_win_get_config(win).relative ~= '', 'not a float')
    return {
      title = vim.api.nvim_win_get_config(win).title[1][1],
      lines = vim.api.nvim_buf_get_lines(0, 0, -1, false),
    }
  end)()]])
end

T['preview']['cycles through the results and applies one'] = function()
  dir = H.make_repo({
    ['file.txt'] = {
      base = 'before\nx\nafter\n',
      ours = 'before\nours\nafter\n',
      theirs = 'before\ntheirs\nafter\n',
    },
  })
  H.open(child, dir, 'file.txt')
  local src = child.api.nvim_get_current_win()
  child.api.nvim_win_set_cursor(0, { 2, 0 })
  child.cmd('GitConflictPreview')
  eq(float_lines(), { title = ' ours (1/5) ', lines = { 'before', 'ours', 'after' } })
  child.type_keys('<Tab>')
  eq(float_lines(), { title = ' theirs (2/5) ', lines = { 'before', 'theirs', 'after' } })
  child.type_keys('<Tab>')
  eq(float_lines().lines, { 'before', 'ours', 'theirs', 'after' })
  child.type_keys('<Tab>')
  eq(float_lines().lines, { 'before', 'theirs', 'ours', 'after' })
  child.type_keys('<Tab>')
  eq(float_lines(), { title = ' none (5/5) ', lines = { 'before', 'after' } })
  child.type_keys('<S-Tab>', '<S-Tab>', '<S-Tab>', '<CR>')
  eq(child.api.nvim_get_current_win(), src)
  eq(H.lines(child), { 'before', 'theirs', 'after' })
end

T['preview']['includes base with diff3 and closes with q'] = function()
  dir = H.simple_repo({ diff3 = true })
  H.open(child, dir, 'conflicted.lua')
  local before = H.lines(child)
  child.api.nvim_win_set_cursor(0, { 1, 0 })
  child.cmd('GitConflictPreview')
  eq(float_lines().title, ' ours (1/6) ')
  child.type_keys('<S-Tab>', '<S-Tab>')
  eq(float_lines().title, ' base (5/6) ')
  child.type_keys('q')
  eq(#child.api.nvim_list_wins(), 1)
  eq(H.lines(child), before)
end

T['preview']['outside of a conflict'] = function()
  dir = H.simple_repo()
  H.open(child, dir, 'conflicted.lua')
  child.api.nvim_win_set_cursor(0, { 6, 0 })
  child.cmd('GitConflictPreview')
  eq(#child.api.nvim_list_wins(), 1)
end

return T
