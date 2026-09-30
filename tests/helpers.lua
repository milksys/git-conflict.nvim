local H = {}

local function run(cmd, cwd)
  -- Isolate fixtures from the user's global git config (e.g. merge.conflictStyle)
  local env = { GIT_CONFIG_GLOBAL = '/dev/null', GIT_CONFIG_NOSYSTEM = '1' }
  local res = vim.system(cmd, { cwd = cwd, text = true, env = env }):wait()
  return res
end

local function git(dir, ...)
  local res = run({ 'git', '-c', 'user.name=test', '-c', 'user.email=test@test', ... }, dir)
  return res
end

local function write(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local f = assert(io.open(path, 'wb'))
  f:write(content)
  f:close()
end

---Create a temporary git repo in which every file in `files` is in a conflicted state
---@param files table<string, {base: string, ours: string, theirs: string}>
---@param opts? {diff3?: boolean, operation?: 'merge'|'rebase'|'cherry-pick'}
---@return string dir absolute (realpath) path to the repo
function H.make_repo(files, opts)
  opts = opts or {}
  local dir = vim.uv.fs_realpath(vim.uv.os_tmpdir()) .. ('/gc-%d'):format(vim.uv.hrtime())
  vim.fn.mkdir(dir, 'p')
  git(dir, 'init', '-q', '-b', 'main')
  if opts.diff3 then git(dir, 'config', 'merge.conflictStyle', 'diff3') end

  local function commit_side(side, msg)
    for name, spec in pairs(files) do
      write(dir .. '/' .. name, spec[side])
    end
    git(dir, 'add', '-A')
    git(dir, 'commit', '-qm', msg)
  end

  commit_side('base', 'base')
  git(dir, 'checkout', '-qb', 'theirs')
  commit_side('theirs', 'theirs')
  git(dir, 'checkout', '-q', 'main')
  commit_side('ours', 'ours')
  if opts.operation == 'rebase' then
    -- replay the "theirs" branch onto main
    git(dir, 'checkout', '-q', 'theirs')
    git(dir, 'rebase', 'main')
  elseif opts.operation == 'cherry-pick' then
    git(dir, 'cherry-pick', 'theirs')
  else
    git(dir, 'merge', 'theirs')
  end
  return dir
end

H.git = git

---A simple single-conflict repo with `conflicted.lua`
---@param opts? {diff3?: boolean}
function H.simple_repo(opts)
  return H.make_repo({
    ['conflicted.lua'] = {
      base = 'local value = 1 + 1\nprint(value)\n',
      ours = 'local value = 5 + 7\nprint(value)\n',
      theirs = 'local value = 1 - 1\nprint(value)\n',
    },
  }, opts)
end

---Two separate conflicts in one file
function H.two_conflict_repo(opts)
  local base = { 'a', '1', '2', '3', '4', '5', '6', 'b', '' }
  local ours = vim.deepcopy(base)
  local theirs = vim.deepcopy(base)
  ours[1], theirs[1] = 'a-ours', 'a-theirs'
  ours[8], theirs[8] = 'b-ours', 'b-theirs'
  return H.make_repo({
    ['file.txt'] = {
      base = table.concat(base, '\n'),
      ours = table.concat(ours, '\n'),
      theirs = table.concat(theirs, '\n'),
    },
  }, opts)
end

---@return table child MiniTest child
function H.new_child()
  local child = MiniTest.new_child_neovim()
  child.start({ '-u', 'scripts/minimal_init.lua' })
  return child
end

---Wait inside the child until `expr` (lua expression string) is truthy, redrawing on each poll
---so that the decoration provider runs
function H.wait_for(child, expr, timeout)
  local ok = child.lua(([[
    return vim.wait(%d, function()
      vim.cmd('redraw!')
      return (%s) and true or false
    end, 20)
  ]]):format(timeout or 3000, expr))
  if not ok then error('Timed out waiting for: ' .. expr) end
end

H.HAS_MARKS =
  "#vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace('git-conflict'), 0, -1, {}) > 0"

---Setup the plugin in the child, cd into `dir` and open `file`, waiting until conflicts are parsed
function H.open(child, dir, file, config, opts)
  opts = opts or {}
  child.cmd('cd ' .. vim.fn.fnameescape(dir))
  child.lua('require("git-conflict").setup(...)', { config or {} })
  child.cmd('edit ' .. vim.fn.fnameescape(file))
  if opts.wait ~= false then H.wait_for(child, H.HAS_MARKS) end
end

function H.lines(child, buf) return child.api.nvim_buf_get_lines(buf or 0, 0, -1, false) end

function H.cleanup(dir)
  if dir then vim.fn.delete(dir, 'rf') end
end

return H
