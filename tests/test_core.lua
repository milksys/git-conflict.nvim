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

local function count_markers(lines)
  local n = 0
  for _, l in ipairs(lines) do
    if l:match('^<<<<<<<') then n = n + 1 end
  end
  return n
end

local function marker_lines(lines)
  local res = {}
  for i, l in ipairs(lines) do
    if l:match('^<<<<<<<') then table.insert(res, i) end
  end
  return res
end

T['visual selection only resolves conflicts fully inside it'] = function()
  dir = H.two_conflict_repo()
  H.open(child, dir, 'file.txt')
  local starts = marker_lines(H.lines(child))
  -- select only the first conflict (its start up to the line before the second one)
  child.api.nvim_win_set_cursor(0, { starts[1], 0 })
  child.type_keys('V', tostring(starts[2] - starts[1] - 1), 'j', 'co')
  local lines = H.lines(child)
  eq(count_markers(lines), 1)
  eq(lines[1], 'a-ours')
  eq(child.fn.mode(), 'n')
end

T['visual selection over both conflicts'] = function()
  dir = H.two_conflict_repo()
  H.open(child, dir, 'file.txt')
  child.type_keys('ggVG', 'ct')
  local lines = H.lines(child)
  eq(count_markers(lines), 0)
  eq(lines[1], 'a-theirs')
  eq(lines[8], 'b-theirs')
end

T['range command'] = function()
  dir = H.two_conflict_repo()
  H.open(child, dir, 'file.txt')
  child.cmd('%GitConflictChooseOurs')
  local lines = H.lines(child)
  eq(count_markers(lines), 0)
  eq({ lines[1], lines[8] }, { 'a-ours', 'b-ours' })
end

T['mappings are removed once resolved'] = function()
  dir = H.simple_repo()
  H.open(child, dir, 'conflicted.lua')
  local function has_map(mode, lhs)
    return child.lua_get(('vim.fn.maparg(%q, %q, false, true).buffer == 1'):format(lhs, mode))
  end
  for _, lhs in ipairs({ 'co', 'ct', 'cb', 'c0', ']x', '[x' }) do
    eq(has_map('n', lhs), true)
  end
  eq(has_map('x', 'co'), true)
  child.api.nvim_win_set_cursor(0, { 1, 0 })
  child.lua('require("git-conflict").choose("ours")')
  for _, lhs in ipairs({ 'co', 'ct', 'cb', 'c0', ']x', '[x' }) do
    eq(has_map('n', lhs), false)
  end
  eq(has_map('x', 'co'), false)
end

T['events fire once per state change with bufnr'] = function()
  dir = H.two_conflict_repo()
  child.lua([[
    _G.events = {}
    vim.api.nvim_create_autocmd('User', {
      pattern = { 'GitConflictDetected', 'GitConflictResolved' },
      callback = function(args) table.insert(_G.events, { args.match, args.data.bufnr }) end,
    })
  ]])
  H.open(child, dir, 'file.txt', { default_mappings = false })
  local buf = child.api.nvim_get_current_buf()
  -- editing while still conflicted must not re-fire
  child.type_keys('Goextra<Esc>')
  child.lua('vim.wait(200, function() return false end)')
  child.cmd('%GitConflictChooseOurs')
  eq(child.lua_get('_G.events'), { { 'GitConflictDetected', buf }, { 'GitConflictResolved', buf } })
end

T['highlights go to the parsed buffer, not the current one'] = function()
  dir = H.simple_repo()
  H.open(child, dir, 'conflicted.lua')
  local conflicted = child.api.nvim_get_current_buf()
  child.cmd('vnew')
  local scratch = child.api.nvim_get_current_buf()
  -- change the conflicted buffer from the other window
  child.lua('vim.api.nvim_buf_set_lines(...)', { conflicted, -1, -1, false, { 'appended' } })
  child.lua('require("git-conflict").conflict_count(...)', { conflicted })
  local ns = child.api.nvim_create_namespace('git-conflict')
  eq(#child.api.nvim_buf_get_extmarks(scratch, ns, 0, -1, {}), 0)
  eq(#child.api.nvim_buf_get_extmarks(conflicted, ns, 0, -1, {}) > 0, true)
end

T['works when started from a subdirectory'] = function()
  dir = H.make_repo({
    ['sub/dir/file.txt'] = { base = 'a\n', ours = 'b\n', theirs = 'c\n' },
  })
  H.open(child, dir .. '/sub', 'dir/file.txt')
  eq(child.lua_get('require("git-conflict").conflict_count()'), 1)
end

T['non-ascii file names'] = function()
  dir = H.make_repo({ ['한글 파일.txt'] = { base = 'a\n', ours = 'b\n', theirs = 'c\n' } })
  H.open(child, dir, '한글 파일.txt')
  eq(child.lua_get('require("git-conflict").conflict_count()'), 1)
end

T['symlinked path to the repository'] = function()
  dir = H.simple_repo()
  local link = dir .. '-link'
  vim.uv.fs_symlink(dir, link)
  H.open(child, link, 'conflicted.lua')
  eq(child.lua_get('require("git-conflict").conflict_count()'), 1)
  vim.uv.fs_unlink(link)
end

T['conflicts already open are highlighted when git reports them'] = function()
  dir = H.simple_repo()
  child.cmd('cd ' .. dir)
  -- open the file before setting up the plugin (e.g. lazy loading)
  child.cmd('edit conflicted.lua')
  child.lua('require("git-conflict").setup()')
  H.wait_for(child, H.HAS_MARKS)
end

T['git add clears the conflict state'] = function()
  dir = H.simple_repo()
  H.open(child, dir, 'conflicted.lua', { disable_diagnostics = true })
  eq(child.lua_get('vim.diagnostic.is_enabled({ bufnr = 0 })'), false)
  -- the markers are still in the file but git considers it resolved
  H.git(dir, 'add', 'conflicted.lua')
  H.wait_for(child, 'not (' .. H.HAS_MARKS .. ')')
  eq(child.lua_get('vim.diagnostic.is_enabled({ bufnr = 0 })'), true)
  eq(child.lua_get('vim.fn.maparg("co", "n", false, true).buffer'), vim.NIL)
end

T['quickfix is sorted and includes unopened files'] = function()
  dir = H.make_repo({
    ['b.txt'] = { base = 'a\n', ours = 'b\n', theirs = 'c\n' },
    ['a.txt'] = { base = 'a\n', ours = 'b\n', theirs = 'c\n' },
  })
  H.open(child, dir, 'b.txt')
  H.wait_for(child, 'vim.fn.exists(":GitConflictListQf") == 2')
  child.cmd('GitConflictListQf')
  local items = child.lua_get([[vim.tbl_map(function(i)
    return { vim.fn.fnamemodify(vim.fn.bufname(i.bufnr), ':t'), i.lnum, i.text }
  end, vim.fn.getqflist())]])
  eq(items, {
    { 'a.txt', 1, 'current change' },
    { 'a.txt', 4, 'incoming change' },
    { 'b.txt', 1, 'current change' },
    { 'b.txt', 4, 'incoming change' },
  })
end

T['labels do not depend on window width'] = function()
  dir = H.simple_repo()
  H.open(child, dir, 'conflicted.lua')
  local ns = child.api.nvim_create_namespace('git-conflict')
  local marks = child.api.nvim_buf_get_extmarks(0, ns, 0, 0, { details = true })
  eq(marks[1][4].line_hl_group, 'GitConflictCurrentLabel')
  eq(marks[1][4].virt_text[1][1], '(Current changes)')
end

return T
