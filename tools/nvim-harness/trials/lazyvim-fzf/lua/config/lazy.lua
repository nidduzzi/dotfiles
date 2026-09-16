-- Bootstrap lazy.nvim and load LazyVim plus this trial's own specs.
local lazypath = vim.fn.stdpath 'data' .. '/lazy/lazy.nvim'
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  vim.fn.system {
    'git',
    'clone',
    '--filter=blob:none',
    'https://github.com/folke/lazy.nvim.git',
    '--branch=stable',
    lazypath,
  }
end
vim.opt.rtp:prepend(lazypath)

require('lazy').setup {
  spec = {
    { 'LazyVim/LazyVim', import = 'lazyvim.plugins' },
    -- Swaps snacks.picker out for fzf-lua. Everything else stays LazyVim stock.
    { import = 'lazyvim.plugins.extras.editor.fzf' },
    { import = 'plugins' },
  },
  defaults = { lazy = false, version = false },
  install = { colorscheme = { 'tokyonight', 'habamax' } },
  checker = { enabled = false },
  change_detection = { notify = false },
  performance = {
    rtp = {
      disabled_plugins = { 'gzip', 'tarPlugin', 'tohtml', 'tutor', 'zipPlugin' },
    },
  },
}
