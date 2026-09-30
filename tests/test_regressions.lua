local H = require('tests.helpers')
local eq = MiniTest.expect.equality

local child = H.new_child()
local dir

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ '-u', 'scripts/minimal_init.lua' })
      -- Record any deprecation warnings raised during the test
      child.lua([[
        _G.deprecations = {}
        local orig = vim.deprecate
        vim.deprecate = function(name, ...)
          table.insert(_G.deprecations, name)
          return orig(name, ...)
        end
      ]])
    end,
    post_case = function()
      eq(child.lua_get('_G.deprecations'), {})
      H.cleanup(dir)
    end,
    post_once = child.stop,
  },
})

T['commands'] = MiniTest.new_set({
  parametrize = {
    { 'GitConflictChooseOurs', { 'local value = 5 + 7', 'print(value)' } },
    { 'GitConflictChooseTheirs', { 'local value = 1 - 1', 'print(value)' } },
    { 'GitConflictChooseBoth', { 'local value = 5 + 7', 'local value = 1 - 1', 'print(value)' } },
    { 'GitConflictChooseNone', { 'print(value)' } },
  },
})

-- https://github.com/akinsho/git-conflict.nvim/issues/103
T['commands']['resolve conflict'] = function(cmd, expected)
  dir = H.simple_repo()
  H.open(child, dir, 'conflicted.lua')
  child.api.nvim_win_set_cursor(0, { 1, 0 })
  child.cmd(cmd)
  eq(H.lines(child), expected)
end

T['GitConflictNextConflict command moves cursor'] = function()
  dir = H.two_conflict_repo()
  H.open(child, dir, 'file.txt')
  child.api.nvim_win_set_cursor(0, { 1, 0 })
  child.cmd('GitConflictNextConflict')
  eq(child.api.nvim_win_get_cursor(0)[1] > 1, true)
end

T['conflict_count before the buffer is drawn'] = function()
  dir = H.simple_repo()
  H.open(child, dir, 'conflicted.lua', {}, { wait = false })
  -- wait until git reported the file but without forcing a redraw
  child.lua('vim.wait(2000, function() return false end, 50)')
  eq(child.lua_get('require("git-conflict").conflict_count()'), 1)
end

-- https://github.com/akinsho/git-conflict.nvim/issues/91
T['find_next before the buffer is drawn'] = function()
  dir = H.two_conflict_repo()
  H.open(child, dir, 'file.txt', {}, { wait = false })
  child.lua('vim.wait(2000, function() return false end, 50)')
  child.api.nvim_win_set_cursor(0, { 1, 0 })
  child.lua('require("git-conflict").find_next("ours")')
  eq(child.api.nvim_win_get_cursor(0)[1] > 1, true)
end

T['choose base without diff3 does not error'] = function()
  dir = H.simple_repo()
  H.open(child, dir, 'conflicted.lua')
  local before = H.lines(child)
  child.api.nvim_win_set_cursor(0, { 1, 0 })
  child.lua('require("git-conflict").choose("base")')
  eq(H.lines(child), before)
end

-- https://github.com/akinsho/git-conflict.nvim/issues/119
T['disable_diagnostics toggles diagnostics'] = function()
  dir = H.simple_repo()
  H.open(child, dir, 'conflicted.lua', { disable_diagnostics = true })
  eq(child.lua_get('vim.diagnostic.is_enabled({ bufnr = 0 })'), false)
  child.api.nvim_win_set_cursor(0, { 1, 0 })
  child.lua('require("git-conflict").choose("ours")')
  eq(child.lua_get('vim.diagnostic.is_enabled({ bufnr = 0 })'), true)
end

T['debug_watchers works'] = function()
  dir = H.simple_repo()
  H.open(child, dir, 'conflicted.lua')
  child.lua('require("git-conflict").debug_watchers()')
end

return T
