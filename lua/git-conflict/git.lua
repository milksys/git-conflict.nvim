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

return M
