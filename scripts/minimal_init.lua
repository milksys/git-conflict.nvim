-- Minimal init used both by `make test` and by the child Neovim processes in tests
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.opt.rtp:prepend(vim.fn.getcwd() .. '/deps/mini.nvim')
vim.o.swapfile = false
vim.o.shadafile = 'NONE'

if #vim.api.nvim_list_uis() == 0 then
  require('mini.test').setup({
    collect = {
      find_files = function() return vim.fn.globpath('tests', '**/test_*.lua', true, true) end,
    },
  })
end
