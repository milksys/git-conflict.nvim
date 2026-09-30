-----------------------------------------------------------------------------//
-- Git helpers
-----------------------------------------------------------------------------//
local M = {}

---Normalise a path so that paths coming from git and from buffer names can be compared
---i.e. resolve symlinks (e.g. /tmp -> /private/tmp on macOS) and separators
---@param path string
---@return string
function M.normalize(path) return vim.fs.normalize(vim.uv.fs_realpath(path) or path) end

---Run a git command asynchronously; `callback` is called on the main loop with the stdout
---or nil if the command failed.
---@param args string[]
---@param callback fun(stdout: string?, stderr: string?)
function M.run(args, callback)
  local cmd = { 'git', '-c', 'core.quotePath=false' }
  vim.list_extend(cmd, args)
  local ok, err = pcall(vim.system, cmd, { text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then return callback(nil, res.stderr) end
      callback(res.stdout)
    end)
  end)
  if not ok then vim.schedule(function() callback(nil, err) end) end
end

---@class GitRepo
---@field root string absolute path of the work tree
---@field gitdir string absolute path of the git directory (may differ for worktrees)

---Resolve the repository containing `dir`
---@param dir string
---@param callback fun(repo: GitRepo?)
function M.get_repo(dir, callback)
  M.run({ '-C', dir, 'rev-parse', '--show-toplevel', '--absolute-git-dir' }, function(out)
    if not out then return callback(nil) end
    local lines = vim.split(vim.trim(out), '\n', { plain = true })
    if #lines < 2 then return callback(nil) end
    callback({ root = M.normalize(lines[1]), gitdir = M.normalize(lines[2]) })
  end)
end

---List the absolute paths of all conflicted (unmerged) files in the repository
---@param root string
---@param callback fun(files: table<string, boolean>?)
function M.get_conflicted_files(root, callback)
  M.run({ '-C', root, 'diff', '--name-only', '--diff-filter=U', '-z' }, function(out)
    if not out then return callback(nil) end
    local files = {}
    for _, rel in ipairs(vim.split(out, '\0', { plain = true, trimempty = true })) do
      files[M.normalize(root .. '/' .. rel)] = true
    end
    callback(files)
  end)
end

---Read the `conflict-marker-size` attribute of each file
---@param root string
---@param paths string[] absolute paths
---@param callback fun(sizes: table<string, integer>) sizes of the files that set the attribute
function M.get_marker_sizes(root, paths, callback)
  if #paths == 0 then return callback({}) end
  local args = { '-C', root, 'check-attr', '-z', 'conflict-marker-size', '--' }
  vim.list_extend(args, paths)
  M.run(args, function(out)
    local sizes = {}
    local fields = vim.split(out or '', '\0', { plain = true })
    -- output is a sequence of <path> NUL <attribute> NUL <value> NUL
    for i = 1, #fields - 2, 3 do
      local size = tonumber(fields[i + 2])
      local path = fields[i]
      -- paths are printed as they were given, so relative ones are relative to the root
      if not (vim.startswith(path, '/') or path:match('^%a:[/\\]')) then
        path = root .. '/' .. path
      end
      if size and size > 0 then sizes[M.normalize(path)] = size end
    end
    callback(sizes)
  end)
end

---@param path string
---@return string?
local function read_file(path)
  local f = io.open(path, 'r')
  if not f then return end
  local content = f:read('*a')
  f:close()
  return vim.trim(content)
end

---@param path string
---@return boolean
local function exists(path) return vim.uv.fs_stat(path) ~= nil end

---@class GitOperation
---@field kind "'merge'"|"'rebase'"|"'cherry-pick'"|"'revert'"
---@field current string? name of what the current (ours) side is
---@field incoming string? name of what the incoming (theirs) side is

---@param sha string?
---@return string?
local function short(sha) return sha and sha:sub(1, 8) or nil end

---Work out which operation (if any) is in progress in the repository, this matters since e.g.
---during a rebase "ours" is the branch being rebased onto and "theirs" is your own commit
---@param root string
---@param gitdir string
---@param callback fun(op: GitOperation?)
function M.get_operation(root, gitdir, callback)
  local head = read_file(gitdir .. '/HEAD')
  local branch = head and head:match('^ref: refs/heads/(.+)$')

  local rebase_dir = exists(gitdir .. '/rebase-merge') and gitdir .. '/rebase-merge'
    or exists(gitdir .. '/rebase-apply') and gitdir .. '/rebase-apply'
  if rebase_dir then
    local head_name = read_file(rebase_dir .. '/head-name')
    local incoming = head_name and head_name:gsub('^refs/heads/', '') or nil
    local onto = read_file(rebase_dir .. '/onto')
    if not onto then return callback({ kind = 'rebase', incoming = incoming }) end
    return M.run({ '-C', root, 'name-rev', '--name-only', '--no-undefined', onto }, function(name)
      name = name and vim.trim(name) or nil
      -- strip the "remotes/" prefix name-rev adds for remote tracking branches
      if name then name = name:gsub('^remotes/', '') end
      callback({ kind = 'rebase', current = name or short(onto), incoming = incoming })
    end)
  end

  if exists(gitdir .. '/MERGE_HEAD') then
    local msg = read_file(gitdir .. '/MERGE_MSG') or ''
    local incoming = msg:match("^Merge branch '([^']+)'")
      or msg:match("^Merge remote%-tracking branch '([^']+)'")
      or msg:match("^Merge tag '([^']+)'")
      or msg:match("^Merge commit '([^']+)'")
    return callback({ kind = 'merge', current = branch, incoming = incoming })
  end
  if exists(gitdir .. '/CHERRY_PICK_HEAD') then
    local sha = read_file(gitdir .. '/CHERRY_PICK_HEAD')
    return callback({ kind = 'cherry-pick', current = branch, incoming = short(sha) })
  end
  if exists(gitdir .. '/REVERT_HEAD') then
    local sha = read_file(gitdir .. '/REVERT_HEAD')
    return callback({ kind = 'revert', current = branch, incoming = short(sha) })
  end
  callback(nil)
end

---Stage a file
---@param root string
---@param path string
---@param callback fun(ok: boolean, err: string?)
function M.stage(root, path, callback)
  M.run({ '-C', root, 'add', '--', path }, function(out, err) callback(out ~= nil, err) end)
end

return M
