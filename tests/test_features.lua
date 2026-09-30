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

T['choose_all'] = MiniTest.new_set({
  parametrize = { { 'ours' }, { 'theirs' } },
})

T['choose_all']['resolves every conflict'] = function(side)
  dir = H.two_conflict_repo()
  H.open(child, dir, 'file.txt')
  child.lua('require("git-conflict").choose_all(...)', { side })
  local lines = H.lines(child)
  eq({ lines[1], lines[8] }, { 'a-' .. side, 'b-' .. side })
  eq(child.lua_get('require("git-conflict").conflict_count()'), 0)
end

T['bang command resolves every conflict'] = function()
  dir = H.two_conflict_repo()
  H.open(child, dir, 'file.txt')
  child.api.nvim_win_set_cursor(0, { 1, 0 })
  child.cmd('GitConflictChooseTheirs!')
  local lines = H.lines(child)
  eq({ lines[1], lines[8] }, { 'a-theirs', 'b-theirs' })
end

T['choose_all base without diff3 changes nothing'] = function()
  dir = H.two_conflict_repo()
  H.open(child, dir, 'file.txt')
  local before = H.lines(child)
  child.lua('require("git-conflict").choose_all("base")')
  eq(H.lines(child), before)
end

T['choose cursor'] = MiniTest.new_set({
  parametrize = {
    -- 1-based line in the diff3 conflict:
    -- 1 <<<<<<<, 2 ours, 3 |||||||, 4 base, 5 =======, 6 theirs, 7 >>>>>>>
    { 1, 'local value = 5 + 7' },
    { 2, 'local value = 5 + 7' },
    { 4, 'local value = 1 + 1' },
    { 6, 'local value = 1 - 1' },
    { 7, 'local value = 1 - 1' },
  },
})

T['choose cursor']['keeps the section under the cursor'] = function(line, expected)
  dir = H.simple_repo({ diff3 = true })
  H.open(child, dir, 'conflicted.lua')
  child.api.nvim_win_set_cursor(0, { line, 0 })
  child.cmd('GitConflictChooseCursor')
  eq(H.lines(child), { expected, 'print(value)' })
end

T['choose cursor on the separator does nothing'] = function()
  dir = H.simple_repo()
  H.open(child, dir, 'conflicted.lua')
  local before = H.lines(child)
  child.api.nvim_win_set_cursor(0, { 3, 0 })
  child.lua('require("git-conflict").choose("cursor")')
  eq(H.lines(child), before)
end

T['merge --abort fires GitConflictResolved'] = function()
  dir = H.simple_repo()
  child.lua([[
    _G.resolved = 0
    vim.api.nvim_create_autocmd('User', {
      pattern = 'GitConflictResolved',
      callback = function() _G.resolved = _G.resolved + 1 end,
    })
  ]])
  H.open(child, dir, 'conflicted.lua')
  H.git(dir, 'merge', '--abort')
  child.cmd('checktime')
  H.wait_for(child, '_G.resolved == 1')
  H.wait_for(child, 'not (' .. H.HAS_MARKS .. ')')
end

T['middle marker is highlighted'] = function()
  dir = H.simple_repo()
  H.open(child, dir, 'conflicted.lua')
  local ns = child.api.nvim_create_namespace('git-conflict')
  local marks = child.api.nvim_buf_get_extmarks(0, ns, { 2, 0 }, { 2, 0 }, { details = true })
  eq(marks[1][4].line_hl_group, 'GitConflictMiddleLabel')
end

T['keymap hints in labels'] = function()
  dir = H.simple_repo()
  H.open(child, dir, 'conflicted.lua', { show_keymap_hints = true })
  local ns = child.api.nvim_create_namespace('git-conflict')
  local first = child.api.nvim_buf_get_extmarks(0, ns, 0, 0, { details = true })[1]
  eq(first[4].virt_text[1][1], '(Current changes)  [co] ours  [cb] both  [c0] none')
end

T['checkhealth runs'] = function()
  dir = H.simple_repo()
  H.open(child, dir, 'conflicted.lua')
  child.cmd('checkhealth git-conflict')
  local text = table.concat(H.lines(child), '\n')
  eq(text:find('git%-conflict%.nvim') ~= nil, true)
  eq(text:find('ERROR') == nil, true)
end

return T
