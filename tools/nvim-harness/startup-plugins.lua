-- Which plugins are loaded once the editor is sitting at the dashboard.
--
-- lazy.nvim's whole argument is that a plugin loads when it is first needed.
-- A plugin that loads at startup is either deliberate -- a colourscheme, a
-- statusline, the picker the dashboard is drawn by -- or an accident, and the
-- difference is invisible: the editor looks the same either way and simply
-- takes longer to open.
--
-- The list is compared against expected-startup-plugins.txt, so an accident
-- shows up as a name nobody put there.
local stats = require("lazy").stats()
local loaded = {}
for name, plugin in pairs(require("lazy.core.config").plugins) do
  if plugin._.loaded then
    loaded[#loaded + 1] = name
  end
end
table.sort(loaded)
local out = {
  ("count %d of %d"):format(stats.loaded, stats.count),
  ("startup_ms %.1f"):format(stats.startuptime),
}
for _, name in ipairs(loaded) do
  out[#out + 1] = "  " .. name
end
vim.fn.writefile(out, vim.env.PROBE_OUT)
