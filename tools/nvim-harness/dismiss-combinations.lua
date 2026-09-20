-- What one press of the dismiss key closes, with things open on top of things.
--
-- Every feature passed on its own. The holes were all combinations: the
-- debugger UI is six windows and the key did nothing in front of it, a
-- terminal in a split did nothing, and a diff view owns its tab so closing
-- one of its windows left the rest. See DECISIONS 31 and 32.
--
-- Writes one line per case to $DISMISS_OUT:
--
--   <case> opened=<what was on screen> after=<what is left>

local dismiss = require("util.dismiss")

---@return string
local function windows()
  local names = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    local filetype = vim.bo[buf].filetype
    names[#names + 1] = filetype ~= "" and filetype or (vim.bo[buf].buftype ~= "" and vim.bo[buf].buftype or "file")
  end
  table.sort(names)
  return table.concat(names, ",")
end

---@param name string
---@param open fun()
---@return string
local function case(name, open)
  open()
  vim.wait(3000)
  local opened = windows()

  dismiss.dismiss()
  vim.wait(2000)

  return ("%s opened=%s after=%s"):format(name, opened, windows())
end

vim.cmd.edit(assert(vim.env.DISMISS_FILE))
vim.wait(3000)

local out = { "start " .. windows() }

out[#out + 1] = case("picker", function()
  Snacks.picker.files()
end)

out[#out + 1] = case("explorer", function()
  Snacks.explorer()
end)

out[#out + 1] = case("terminal", function()
  Snacks.terminal()
end)

out[#out + 1] = case("trouble", function()
  vim.cmd("Trouble diagnostics open")
end)

out[#out + 1] = case("quickfix", function()
  vim.fn.setqflist({ { filename = vim.api.nvim_buf_get_name(0), lnum = 1, text = "something" } })
  vim.cmd("copen")
end)

out[#out + 1] = case("grug-far", function()
  vim.cmd("GrugFar")
end)

out[#out + 1] = case("debugger", function()
  require("lazy").load({ plugins = { "nvim-dap-ui" } })
  pcall(function()
    require("dapui").open()
  end)
end)

-- The file has to survive all of it: a key that closes the buffer you are
-- working in is worse than one that does nothing.
out[#out + 1] = "end " .. windows()

vim.fn.writefile(out, assert(vim.env.DISMISS_OUT))
