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

--- What is on screen, ignoring notifications.
---
--- A notification is transient and arrives unasked --- a language server
--- warning on a runner with no language servers, for instance --- so counting
--- one as something the key failed to close makes the gate report on the
--- weather. The dismiss key does hide them, on the rung below the panels.
---@return string
local function windows()
  local names = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    local filetype = vim.bo[buf].filetype
    if not filetype:match("^snacks_notif") then
      names[#names + 1] = filetype ~= "" and filetype or (vim.bo[buf].buftype ~= "" and vim.bo[buf].buftype or "file")
    end
  end
  table.sort(names)
  return table.concat(names, ",")
end

--- Wait for the screen to stop being what it was.
---
--- A fixed sleep is a guess about the slowest machine that will ever run
--- this. The debugger UI took longer than three seconds on a CI runner, and
--- the press that followed landed before there was anything to close.
---@param was string
---@param timeout integer
local function until_different(was, timeout)
  vim.wait(timeout, function()
    return windows() ~= was
  end, 100)
end

---@param name string
---@param open fun()
---@return string
local function case(name, open)
  -- Cleared first: a notification left over from the case before would be
  -- what this one's press closes, and the panel would still be there.
  pcall(function()
    Snacks.notifier.hide()
  end)
  vim.wait(300)

  local before = windows()
  open()
  until_different(before, 15000)
  local opened = windows()

  dismiss.dismiss()
  until_different(opened, 8000)

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
  -- Diagnostics of its own, rather than a language server's: a runner may
  -- have no server for this file, and then Trouble opens nothing and the
  -- press that follows proves nothing.
  vim.diagnostic.set(vim.api.nvim_create_namespace("dismiss-combinations"), 0, {
    {
      lnum = 0,
      col = 0,
      message = "something to list",
      severity = vim.diagnostic.severity.WARN,
    },
  })
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
