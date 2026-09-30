local M = {}

local health = vim.health

function M.check()
  health.start('git-conflict.nvim')

  if vim.fn.has('nvim-0.11') == 1 then
    health.ok('Neovim ' .. tostring(vim.version()))
  else
    health.error('Neovim 0.11 or newer is required')
  end

  if vim.fn.executable('git') == 0 then
    health.error('`git` executable not found')
    return
  end
  local version = vim.system({ 'git', '--version' }, { text = true }):wait()
  health.ok(vim.trim(version.stdout or 'git'))

  local style = vim.system({ 'git', 'config', 'merge.conflictStyle' }, { text = true }):wait()
  style = vim.trim(style.stdout or '')
  if style == 'diff3' or style == 'zdiff3' then
    health.ok(('merge.conflictStyle = %s (base sections available)'):format(style))
  else
    health.info(
      'merge.conflictStyle is not diff3/zdiff3, `GitConflictChooseBase` needs the base section.'
        .. ' Enable it with `git config --global merge.conflictStyle zdiff3`'
    )
  end

  local ok, git_conflict = pcall(require, 'git-conflict')
  if not ok then return health.error('Failed to load git-conflict: ' .. git_conflict) end
  if vim.fn.exists(':GitConflictListQf') == 0 and git_conflict.get_config().default_commands then
    return health.warn('setup() has not been called')
  end

  local mappings = git_conflict.get_config().default_mappings
  if mappings then
    for name, lhs in pairs(mappings) do
      local existing = vim.fn.maparg(lhs, 'n', false, true)
      if not vim.tbl_isempty(existing) and existing.buffer ~= 1 then
        health.warn(
          ('Default mapping `%s` (%s) shadows the global mapping: %s'):format(
            lhs,
            name,
            existing.desc or existing.rhs or '<Lua callback>'
          )
        )
      end
    end
  end
end

return M
