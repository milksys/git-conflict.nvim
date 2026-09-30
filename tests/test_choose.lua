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

T['detects conflict'] = function()
  dir = H.simple_repo()
  H.open(child, dir, 'conflicted.lua')
  eq(child.lua_get('require("git-conflict").conflict_count()'), 1)
end

T['choose'] = MiniTest.new_set({
  parametrize = {
    { 'ours', { 'local value = 5 + 7', 'print(value)' } },
    { 'theirs', { 'local value = 1 - 1', 'print(value)' } },
    { 'both', { 'local value = 5 + 7', 'local value = 1 - 1', 'print(value)' } },
    { 'none', { 'print(value)' } },
  },
})

T['choose']['resolves side'] = function(side, expected)
  dir = H.simple_repo()
  H.open(child, dir, 'conflicted.lua')
  child.api.nvim_win_set_cursor(0, { 1, 0 })
  child.lua('require("git-conflict").choose(...)', { side })
  eq(H.lines(child), expected)
  eq(child.lua_get('require("git-conflict").conflict_count()'), 0)
end

T['choose base with diff3'] = function()
  dir = H.simple_repo({ diff3 = true })
  H.open(child, dir, 'conflicted.lua')
  child.api.nvim_win_set_cursor(0, { 1, 0 })
  child.lua('require("git-conflict").choose("base")')
  eq(H.lines(child), { 'local value = 1 + 1', 'print(value)' })
end

T['choose outside of a conflict does nothing'] = function()
  dir = H.simple_repo()
  H.open(child, dir, 'conflicted.lua')
  local before = H.lines(child)
  child.api.nvim_win_set_cursor(0, { #before, 0 })
  child.lua('require("git-conflict").choose("ours")')
  eq(H.lines(child), before)
end

T['default mappings resolve conflict'] = function()
  dir = H.simple_repo()
  H.open(child, dir, 'conflicted.lua')
  child.api.nvim_win_set_cursor(0, { 1, 0 })
  child.type_keys('co')
  eq(H.lines(child), { 'local value = 5 + 7', 'print(value)' })
end

T['navigation'] = function()
  dir = H.two_conflict_repo()
  H.open(child, dir, 'file.txt')
  eq(child.lua_get('require("git-conflict").conflict_count()'), 2)
  local lines = H.lines(child)
  local starts = {}
  for i, l in ipairs(lines) do
    if l:match('^<<<<<<<') then table.insert(starts, i) end
  end
  child.api.nvim_win_set_cursor(0, { 1, 0 })
  child.lua('require("git-conflict").find_next("ours")')
  eq(child.api.nvim_win_get_cursor(0)[1], starts[2])
  -- wraps around
  child.lua('require("git-conflict").find_next("ours")')
  eq(child.api.nvim_win_get_cursor(0)[1], starts[1])
  child.lua('require("git-conflict").find_prev("ours")')
  eq(child.api.nvim_win_get_cursor(0)[1], starts[2])
end

T['quickfix lists conflicts'] = function()
  dir = H.simple_repo()
  H.open(child, dir, 'conflicted.lua')
  child.cmd('GitConflictListQf')
  local items = child.fn.getqflist()
  eq(#items > 0, true)
end

return T
